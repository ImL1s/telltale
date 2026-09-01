#!/usr/bin/env python3
"""Fail closed when a Gate C build input changes while the gate is running."""

from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import dataclasses
import hashlib
import json
import os
import pathlib
import queue
import re
import signal
import stat
import subprocess
import sys
import threading
import time
import types
from typing import Iterable

sys.dont_write_bytecode = True


def _load_tree_manifest() -> object:
    """Compile the sealed sibling source without consulting bytecode caches."""

    source = pathlib.Path(__file__).resolve(strict=True).with_name(
        "tree_manifest.py"
    )
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(source, flags)
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_uid != os.getuid()
            or before.st_mode & 0o022
        ):
            raise RuntimeError(f"unsafe tree-manifest helper: {source}")
        chunks: list[bytes] = []
        while chunk := os.read(descriptor, 1024 * 1024):
            chunks.append(chunk)
        after = os.fstat(descriptor)
        current = os.stat(source, follow_symlinks=False)
        def identity(value):
            return (
                value.st_dev,
                value.st_ino,
                value.st_mode,
                value.st_size,
                value.st_mtime_ns,
                value.st_ctime_ns,
            )
        if identity(before) != identity(after) or identity(after) != identity(current):
            raise RuntimeError(f"tree-manifest helper changed while loading: {source}")
        source_bytes = b"".join(chunks)
    finally:
        os.close(descriptor)

    name = "telltale_gate_c_tree_manifest"
    module = types.ModuleType(name)
    module.__file__ = str(source)
    module.__package__ = ""
    sys.modules[name] = module
    try:
        code = compile(source_bytes, str(source), "exec", dont_inherit=True)
        exec(code, module.__dict__)
    except BaseException:
        sys.modules.pop(name, None)
        raise
    return module


tree_manifest = _load_tree_manifest()


GLOBAL_FLAGS = frozenset({"NoOp", "PlatformSpecific", "Overflow"})
INTEGRITY_FAILURE_FLAGS = frozenset({"PlatformSpecific", "Overflow"})
PATH_MATERIAL_FLAGS = frozenset(
    {
        "Created",
        "Updated",
        "Removed",
        "Renamed",
        "MovedFrom",
        "MovedTo",
        "Link",
        "CloseWrite",
        "ItemCloned",
        "OwnerModified",
        "AttributeModified",
        "FSEventsUnspecified",
    }
)
PATH_BENIGN_FLAGS = frozenset({"IsFile", "IsDir", "IsSymLink"})
KNOWN_FLAGS = GLOBAL_FLAGS | PATH_MATERIAL_FLAGS | PATH_BENIGN_FLAGS
MATERIAL_FLAGS = PATH_MATERIAL_FLAGS
EXACT_DOC_ALLOWLIST = frozenset(tree_manifest.EXCLUDED_DOCUMENTATION)
RESULT_VERSION = 3
BOOTSTRAP_QUIET_SECONDS = 0.3
BOOTSTRAP_TIMEOUT_SECONDS = 5.0
CANARY_CREATE_RETRY_SECONDS = 0.2
CANARY_REMOVE_RETRY_SECONDS = 0.15
CANARY_REMOVE_TOGGLE_SECONDS = 0.05
STOP_DRAIN_QUIET_SECONDS = 0.3
STOP_DRAIN_HARD_SECONDS = 2.0
NONCE = re.compile(r"^[0-9a-f]{32}$")
_EXTERNAL_TERMINATION = threading.Event()

DARWIN_EVENT_FLAG_NAMES = {
    0x00000001: "MustScanSubDirs",
    0x00000002: "UserDropped",
    0x00000004: "KernelDropped",
    0x00000008: "EventIdsWrapped",
    0x00000010: "HistoryDone",
    0x00000020: "RootChanged",
    0x00000040: "Mount",
    0x00000080: "Unmount",
    0x00000100: "ItemCreated",
    0x00000200: "ItemRemoved",
    0x00000400: "ItemInodeMetaMod",
    0x00000800: "ItemRenamed",
    0x00001000: "ItemModified",
    0x00002000: "ItemFinderInfoMod",
    0x00004000: "ItemChangeOwner",
    0x00008000: "ItemXattrMod",
    0x00010000: "ItemIsFile",
    0x00020000: "ItemIsDir",
    0x00040000: "ItemIsSymlink",
    0x00080000: "OwnEvent",
    0x00100000: "ItemIsHardlink",
    0x00200000: "ItemIsLastHardlink",
    0x00400000: "ItemCloned",
}
DARWIN_KNOWN_FLAG_MASK = sum(DARWIN_EVENT_FLAG_NAMES)
DARWIN_INTEGRITY_FAILURE_FLAGS = frozenset(
    {
        "MustScanSubDirs",
        "UserDropped",
        "KernelDropped",
        "EventIdsWrapped",
        "HistoryDone",
        "RootChanged",
        "Mount",
        "Unmount",
    }
)
DARWIN_INTEGRITY_RAW_MASK = sum(
    flag
    for flag, name in DARWIN_EVENT_FLAG_NAMES.items()
    if name in DARWIN_INTEGRITY_FAILURE_FLAGS
)
DARWIN_STREAM_CREATE_FLAGS = (
    0x00000002  # NoDefer
    | 0x00000004  # WatchRoot
    | 0x00000010  # FileEvents
    | 0x00000020  # MarkSelf
)
PURE_ITEM_CLONED_FILE_FLAGS = 0x00400000 | 0x00010000
CLONE_RECONCILIATION_POLICY = "sealed-manifest-pure-item-cloned-v2"
MAX_BASELINE_MANIFEST_BYTES = 64 * 1024 * 1024
MAX_BASELINE_MANIFEST_ENTRIES = 50_000
MAX_BASELINE_UNIQUE_FILE_BYTES = 4 * 1024 * 1024 * 1024
MAX_BASELINE_XATTR_BYTES = 64 * 1024 * 1024
MAX_BASELINE_SIDECAR_BYTES = 64 * 1024 * 1024


@dataclasses.dataclass(frozen=True)
class DarwinFSEventRecord:
    path: str
    raw_flags: int
    event_id: int
    callback_batch_sequence: int
    callback_record_sequence: int

    def to_raw_json(self) -> dict[str, object]:
        return {
            "recordType": "raw-darwin-fsevents",
            "epoch_us": time.time_ns() // 1_000,
            "path": self.path,
            "rawFlags": self.raw_flags,
            "rawFlagsHex": f"0x{self.raw_flags:08x}",
            "eventId": self.event_id,
            "callbackBatchSequence": self.callback_batch_sequence,
            "callbackRecordSequence": self.callback_record_sequence,
        }


@dataclasses.dataclass(frozen=True)
class FileFingerprint:
    sha256: str
    device: int
    inode: int
    mode: int
    link_count: int
    uid: int
    gid: int
    size: int
    mtime_ns: int
    ctime_ns: int
    birthtime_ns: int | None
    flags: int | None
    xattrs: tuple[tuple[str, int, str], ...]

    def to_json(self) -> dict[str, object]:
        return {
            "sha256": self.sha256,
            "device": self.device,
            "inode": self.inode,
            "mode": self.mode,
            "linkCount": self.link_count,
            "uid": self.uid,
            "gid": self.gid,
            "size": self.size,
            "mtimeNs": self.mtime_ns,
            "ctimeNs": self.ctime_ns,
            "birthtimeNs": self.birthtime_ns,
            "fileFlags": self.flags,
            "xattrs": [
                {"name": name, "bytes": size, "sha256": digest}
                for name, size, digest in self.xattrs
            ],
        }


@dataclasses.dataclass(frozen=True)
class BaselineManifestEntry:
    logical_id: str
    namespace: str
    sha256: str

    def to_json(self) -> dict[str, str]:
        return {
            "logicalId": self.logical_id,
            "namespace": self.namespace,
            "sha256": self.sha256,
        }


@dataclasses.dataclass(frozen=True)
class CloneBaselineRecord:
    canonical_path: pathlib.Path
    event_scope: str
    manifest_entries: tuple[BaselineManifestEntry, ...]
    fingerprint: FileFingerprint

    def to_json(self) -> dict[str, object]:
        return {
            "canonicalPath": str(self.canonical_path),
            "eventScope": self.event_scope,
            "manifestEntries": [entry.to_json() for entry in self.manifest_entries],
            "fingerprint": self.fingerprint.to_json(),
        }


@dataclasses.dataclass(frozen=True)
class CloneBaseline:
    records: dict[pathlib.Path, CloneBaselineRecord]
    manifest_sha256: str
    sidecar_path: pathlib.Path
    sidecar_sha256: str
    sidecar_bytes: int
    manifest_entry_count: int
    unique_regular_file_bytes: int
    total_xattr_bytes: int
    namespace_entry_counts: dict[str, int]
    event_scope_file_counts: dict[str, int]

    @property
    def unique_regular_file_count(self) -> int:
        return len(self.records)


def decode_darwin_flags(raw_flags: int) -> tuple[str, ...]:
    unknown = raw_flags & ~DARWIN_KNOWN_FLAG_MASK
    if unknown:
        raise RuntimeError(
            f"unknown Darwin FSEvents flag bits: 0x{unknown:08x} "
            f"(raw=0x{raw_flags:08x})"
        )
    native_names = {
        name for flag, name in DARWIN_EVENT_FLAG_NAMES.items() if raw_flags & flag
    }
    failures = native_names.intersection(DARWIN_INTEGRITY_FAILURE_FLAGS)
    if failures:
        raise RuntimeError(
            "Darwin FSEvents integrity failure flags: "
            f"{sorted(failures)} (raw=0x{raw_flags:08x})"
        )
    mapped: set[str] = set()
    if "ItemCreated" in native_names:
        mapped.add("Created")
    if "ItemRemoved" in native_names:
        mapped.add("Removed")
    if "ItemRenamed" in native_names:
        mapped.add("Renamed")
    if "ItemModified" in native_names:
        mapped.add("Updated")
    if {"ItemInodeMetaMod", "ItemFinderInfoMod", "ItemXattrMod"}.intersection(native_names):
        mapped.add("AttributeModified")
    if "ItemChangeOwner" in native_names:
        mapped.add("OwnerModified")
    if {"ItemIsHardlink", "ItemIsLastHardlink"}.intersection(native_names):
        mapped.add("Link")
    if "ItemCloned" in native_names:
        mapped.add("ItemCloned")
    if "ItemIsFile" in native_names:
        mapped.add("IsFile")
    if "ItemIsDir" in native_names:
        mapped.add("IsDir")
    if "ItemIsSymlink" in native_names:
        mapped.add("IsSymLink")
    if not mapped:
        mapped.add("FSEventsUnspecified")
    return tuple(sorted(mapped))


def _is_suppressible_internal_sink_event(
    record: DarwinFSEventRecord,
    canonical_events_file: pathlib.Path,
) -> bool:
    if not record.raw_flags & 0x00080000:  # OwnEvent
        return False
    if record.raw_flags & ~DARWIN_KNOWN_FLAG_MASK:
        return False
    if record.raw_flags & DARWIN_INTEGRITY_RAW_MASK:
        return False
    try:
        callback_path = pathlib.Path(record.path).resolve(strict=True)
    except OSError:
        return False
    return callback_path == canonical_events_file


def _require_native_events_sink_outside_watch_roots(
    events_file: pathlib.Path,
    native_watch_roots: Iterable[pathlib.Path],
) -> None:
    canonical_events_file = events_file.parent.resolve(strict=True) / events_file.name
    for root in native_watch_roots:
        canonical_root = root.resolve(strict=True)
        if canonical_events_file == canonical_root or canonical_events_file.is_relative_to(
            canonical_root
        ):
            raise ValueError(
                "native FSEvents ledger must be outside every watch root: "
                f"{canonical_events_file} is within {canonical_root}"
            )


@dataclasses.dataclass(frozen=True)
class WatchPlan:
    root: pathlib.Path
    local_directories: tuple[pathlib.Path, ...]
    exact_files: frozenset[pathlib.Path]
    package_roots: tuple[pathlib.Path, ...]
    toolchain_roots: tuple[pathlib.Path, ...]

    @property
    def watch_paths(self) -> tuple[pathlib.Path, ...]:
        return _compact_roots(
            (*self.local_directories, *self.exact_files, *self.package_roots,
             *self.toolchain_roots)
        )


@dataclasses.dataclass(frozen=True)
class ClassifiedEvent:
    path: str
    flags: tuple[str, ...]
    included: bool
    material: bool
    scope: str | None
    ignored_reason: str | None
    clone_reconciliation: dict[str, object] | None = None

    @property
    def violates(self) -> bool:
        return self.included and self.material

    def to_json(self) -> dict[str, object]:
        value = {
            "epoch_us": time.time_ns() // 1_000,
            "path": self.path,
            "flags": list(self.flags),
            "included": self.included,
            "material": self.material,
            "scope": self.scope,
            "ignoredReason": self.ignored_reason,
            "violates": self.violates,
        }
        if self.clone_reconciliation is not None:
            value["cloneReconciliation"] = self.clone_reconciliation
        return value


def _absolute(path: pathlib.Path) -> pathlib.Path:
    return pathlib.Path(os.path.abspath(os.fspath(path)))


def _fingerprint_identity(value: os.stat_result) -> tuple[int, ...]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_nlink,
        value.st_uid,
        value.st_gid,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
        getattr(value, "st_flags", 0),
        int(getattr(value, "st_birthtime", 0) * 1_000_000_000),
    )


def _is_group_or_world_writable_by_current_process(
    metadata: os.stat_result,
) -> bool:
    if metadata.st_mode & stat.S_IWOTH:
        return True
    current_groups = {os.getegid(), *os.getgroups()}
    return bool(metadata.st_mode & stat.S_IWGRP) and metadata.st_gid in current_groups


def _read_xattr_fingerprints(
    descriptor: int,
    path: pathlib.Path,
) -> tuple[tuple[str, int, str], ...]:
    try:
        if hasattr(os, "listxattr") and hasattr(os, "getxattr"):
            names_and_values = [
                (
                    os.fsencode(name),
                    os.getxattr(descriptor, name),
                )
                for name in sorted(os.listxattr(descriptor))
            ]
        elif sys.platform == "darwin":
            libc = ctypes.CDLL(None, use_errno=True)
            libc.flistxattr.argtypes = [
                ctypes.c_int,
                ctypes.c_void_p,
                ctypes.c_size_t,
                ctypes.c_int,
            ]
            libc.flistxattr.restype = ctypes.c_ssize_t
            libc.fgetxattr.argtypes = [
                ctypes.c_int,
                ctypes.c_char_p,
                ctypes.c_void_p,
                ctypes.c_size_t,
                ctypes.c_uint32,
                ctypes.c_int,
            ]
            libc.fgetxattr.restype = ctypes.c_ssize_t
            name_bytes = libc.flistxattr(descriptor, None, 0, 0)
            if name_bytes < 0:
                raise OSError(ctypes.get_errno(), "flistxattr size failed")
            if name_bytes == 0:
                names_and_values = []
            else:
                name_buffer = ctypes.create_string_buffer(name_bytes)
                written = libc.flistxattr(
                    descriptor,
                    name_buffer,
                    name_bytes,
                    0,
                )
                if written != name_bytes:
                    raise OSError(ctypes.get_errno(), "flistxattr changed while reading")
                names = sorted(
                    name
                    for name in name_buffer.raw[:written].split(b"\0")
                    if name
                )
                names_and_values = []
                for name in names:
                    value_bytes = libc.fgetxattr(
                        descriptor,
                        name,
                        None,
                        0,
                        0,
                        0,
                    )
                    if value_bytes < 0:
                        raise OSError(ctypes.get_errno(), "fgetxattr size failed")
                    value_buffer = ctypes.create_string_buffer(max(value_bytes, 1))
                    value_written = libc.fgetxattr(
                        descriptor,
                        name,
                        value_buffer,
                        value_bytes,
                        0,
                        0,
                    )
                    if value_written != value_bytes:
                        raise OSError(
                            ctypes.get_errno(),
                            "getxattr changed while reading",
                        )
                    names_and_values.append(
                        (name, value_buffer.raw[:value_written])
                    )
        else:
            raise OSError("extended-attribute API is unavailable")
        values = []
        for name, value in names_and_values:
            values.append(
                (
                    f"hex:{name.hex()}",
                    len(value),
                    hashlib.sha256(value).hexdigest(),
                )
            )
        return tuple(values)
    except OSError as error:
        raise ValueError(f"could not fingerprint extended attributes: {path}") from error


def _capture_file_fingerprint(path: pathlib.Path) -> FileFingerprint:
    canonical = _absolute(path)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(canonical, flags)
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_uid != os.getuid()
            or _is_group_or_world_writable_by_current_process(before)
        ):
            raise ValueError(f"unsafe clone-baseline file: {canonical}")
        xattrs_before = _read_xattr_fingerprints(descriptor, canonical)
        digest = hashlib.sha256()
        while chunk := os.read(descriptor, 1024 * 1024):
            digest.update(chunk)
        after = os.fstat(descriptor)
        current = os.stat(canonical, follow_symlinks=False)
        xattrs_after = _read_xattr_fingerprints(descriptor, canonical)
        if (
            _fingerprint_identity(before) != _fingerprint_identity(after)
            or _fingerprint_identity(after) != _fingerprint_identity(current)
            or xattrs_before != xattrs_after
        ):
            raise ValueError(
                f"clone-baseline file changed while fingerprinting: {canonical}"
            )
        birthtime = getattr(after, "st_birthtime", None)
        return FileFingerprint(
            sha256=digest.hexdigest(),
            device=after.st_dev,
            inode=after.st_ino,
            mode=after.st_mode,
            link_count=after.st_nlink,
            uid=after.st_uid,
            gid=after.st_gid,
            size=after.st_size,
            mtime_ns=after.st_mtime_ns,
            ctime_ns=after.st_ctime_ns,
            birthtime_ns=(
                int(birthtime * 1_000_000_000)
                if birthtime is not None
                else None
            ),
            flags=getattr(after, "st_flags", None),
            xattrs=xattrs_after,
        )
    finally:
        os.close(descriptor)


def _read_safe_baseline_manifest(
    path: pathlib.Path,
) -> tuple[list[tuple[str, str]], str]:
    canonical = _absolute(path)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(canonical, flags)
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_uid != os.getuid()
            or before.st_mode & 0o022
            or before.st_size > MAX_BASELINE_MANIFEST_BYTES
        ):
            raise ValueError(f"unsafe clone-baseline manifest: {canonical}")
        data = bytearray()
        digest = hashlib.sha256()
        while chunk := os.read(descriptor, 1024 * 1024):
            data.extend(chunk)
            digest.update(chunk)
            if len(data) > MAX_BASELINE_MANIFEST_BYTES:
                raise ValueError(f"oversized clone-baseline manifest: {canonical}")
        after = os.fstat(descriptor)
        current = os.stat(canonical, follow_symlinks=False)
        if (
            _fingerprint_identity(before) != _fingerprint_identity(after)
            or _fingerprint_identity(after) != _fingerprint_identity(current)
        ):
            raise ValueError(
                f"clone-baseline manifest changed while reading: {canonical}"
            )
        try:
            text = bytes(data).decode("utf-8", errors="strict")
        except UnicodeDecodeError as error:
            raise ValueError(f"invalid clone-baseline manifest: {canonical}") from error
    finally:
        os.close(descriptor)

    entries: list[tuple[str, str]] = []
    seen: set[str] = set()
    for number, line in enumerate(text.splitlines(), 1):
        match = tree_manifest.LINE.fullmatch(line)
        if match is None:
            raise ValueError(f"invalid clone-baseline manifest line {number}")
        file_digest, relative = match.groups()
        pure = pathlib.PurePosixPath(relative)
        if (
            pure.is_absolute()
            or ".." in pure.parts
            or any(ord(character) < 32 or ord(character) == 127 for character in relative)
            or relative in seen
        ):
            raise ValueError(f"unsafe or duplicate clone-baseline path: {relative}")
        seen.add(relative)
        entries.append((file_digest, relative))
    if entries != sorted(entries, key=lambda item: item[1]):
        raise ValueError("clone-baseline manifest paths are not canonical")
    return entries, digest.hexdigest()


def _write_baseline_sidecar(
    path: pathlib.Path,
    payload: dict[str, object],
    plan: WatchPlan,
) -> tuple[pathlib.Path, str, int]:
    if not path.is_absolute():
        raise ValueError("clone-baseline sidecar path must be absolute")
    lexical = _absolute(path)
    resolved_parent = lexical.parent.resolve(strict=True)
    if lexical.parent != resolved_parent:
        raise ValueError(f"symlinked clone-baseline sidecar parent: {lexical.parent}")
    canonical = resolved_parent / lexical.name
    if canonical.exists() or canonical.is_symlink():
        raise ValueError(f"stale clone-baseline sidecar: {canonical}")
    parent = canonical.parent.resolve(strict=True)
    parent_metadata = os.stat(parent, follow_symlinks=False)
    if (
        not stat.S_ISDIR(parent_metadata.st_mode)
        or parent_metadata.st_uid != os.getuid()
        or parent_metadata.st_mode & 0o022
    ):
        raise ValueError(f"unsafe clone-baseline sidecar parent: {parent}")
    for watched in plan.watch_paths:
        if watched.is_dir() and _is_within(canonical, watched):
            raise ValueError(
                f"clone-baseline sidecar is inside a watch root: {canonical}"
            )
        if canonical == watched:
            raise ValueError(
                f"clone-baseline sidecar aliases a watched file: {canonical}"
            )
    encoded = (
        json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode("utf-8")
    if len(encoded) > MAX_BASELINE_SIDECAR_BYTES:
        raise ValueError("clone-baseline sidecar exceeds byte bound")
    temporary = canonical.with_name(f".{canonical.name}.{os.getpid()}.tmp")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(temporary, flags, 0o600)
    try:
        written = 0
        while written < len(encoded):
            written += os.write(descriptor, encoded[written:])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.replace(temporary, canonical)
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    directory_descriptor = os.open(parent, directory_flags)
    try:
        os.fsync(directory_descriptor)
    finally:
        os.close(directory_descriptor)

    expected_sha = hashlib.sha256(encoded).hexdigest()
    descriptor = os.open(canonical, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_uid != os.getuid()
            or before.st_mode & 0o077
            or before.st_size != len(encoded)
        ):
            raise ValueError(f"unsafe published clone-baseline sidecar: {canonical}")
        digest = hashlib.sha256()
        observed_bytes = 0
        while chunk := os.read(descriptor, 1024 * 1024):
            observed_bytes += len(chunk)
            digest.update(chunk)
        after = os.fstat(descriptor)
        current = os.stat(canonical, follow_symlinks=False)
        if (
            _fingerprint_identity(before) != _fingerprint_identity(after)
            or _fingerprint_identity(after) != _fingerprint_identity(current)
            or observed_bytes != len(encoded)
            or digest.hexdigest() != expected_sha
        ):
            raise ValueError(
                f"clone-baseline sidecar changed during publication: {canonical}"
            )
    finally:
        os.close(descriptor)
    return canonical, expected_sha, len(encoded)


def _load_manifest_clone_baseline(
    plan: WatchPlan,
    manifest: pathlib.Path,
    sidecar: pathlib.Path,
) -> CloneBaseline:
    entries, manifest_sha = _read_safe_baseline_manifest(manifest)
    if len(entries) > MAX_BASELINE_MANIFEST_ENTRIES:
        raise ValueError("clone-baseline manifest exceeds entry bound")
    manifest_digests = {logical_id: digest for digest, logical_id in entries}
    bindings = tree_manifest.collect_manifest_path_bindings(
        plan.root,
        expected_flutter_root=tree_manifest.flutter_sdk_root(plan.root),
    )
    binding_ids = {binding.logical_id for binding in bindings}
    if binding_ids != set(manifest_digests):
        missing = sorted(set(manifest_digests).difference(binding_ids))[:5]
        added = sorted(binding_ids.difference(manifest_digests))[:5]
        raise ValueError(
            "clone-baseline manifest mapping mismatch: "
            f"missing={missing} added={added}"
        )

    grouped: dict[pathlib.Path, list[BaselineManifestEntry]] = {}
    for binding in bindings:
        path = binding.path
        digest = manifest_digests[binding.logical_id]
        grouped.setdefault(path, []).append(
            BaselineManifestEntry(binding.logical_id, binding.namespace, digest)
        )

    records: dict[pathlib.Path, CloneBaselineRecord] = {}
    unique_bytes = 0
    total_xattr_bytes = 0
    namespace_counts: dict[str, int] = {}
    event_scope_counts: dict[str, int] = {}
    for path in sorted(grouped, key=str):
        aliases = tuple(sorted(grouped[path], key=lambda entry: entry.logical_id))
        alias_digests = {entry.sha256 for entry in aliases}
        if len(alias_digests) != 1:
            raise ValueError(f"conflicting clone-baseline alias digests: {path}")
        if path.resolve(strict=True) != path:
            raise ValueError(f"symlinked clone-baseline path: {path}")
        classified = classify_event(plan, str(path), ("IsFile",))
        if not classified.included or classified.scope is None:
            raise ValueError(f"unwatched clone-baseline path: {path}")
        fingerprint = _capture_file_fingerprint(path)
        if fingerprint.sha256 != next(iter(alias_digests)):
            raise ValueError(f"clone-baseline content digest mismatch: {path}")
        unique_bytes += fingerprint.size
        total_xattr_bytes += sum(size for _, size, _ in fingerprint.xattrs)
        if unique_bytes > MAX_BASELINE_UNIQUE_FILE_BYTES:
            raise ValueError("clone-baseline unique content exceeds byte bound")
        if total_xattr_bytes > MAX_BASELINE_XATTR_BYTES:
            raise ValueError("clone-baseline xattrs exceed byte bound")
        for entry in aliases:
            namespace_counts[entry.namespace] = (
                namespace_counts.get(entry.namespace, 0) + 1
            )
        event_scope_counts[classified.scope] = (
            event_scope_counts.get(classified.scope, 0) + 1
        )
        records[path] = CloneBaselineRecord(
            canonical_path=path,
            event_scope=classified.scope,
            manifest_entries=aliases,
            fingerprint=fingerprint,
        )

    payload: dict[str, object] = {
        "version": 1,
        "policy": CLONE_RECONCILIATION_POLICY,
        "manifestPath": str(_absolute(manifest)),
        "manifestSha256": manifest_sha,
        "manifestEntryCount": len(entries),
        "uniqueRegularFileCount": len(records),
        "uniqueRegularFileBytes": unique_bytes,
        "totalXattrBytes": total_xattr_bytes,
        "namespaceEntryCounts": dict(sorted(namespace_counts.items())),
        "eventScopeFileCounts": dict(sorted(event_scope_counts.items())),
        "records": [record.to_json() for record in records.values()],
    }
    sidecar_path, sidecar_sha, sidecar_bytes = _write_baseline_sidecar(
        sidecar,
        payload,
        plan,
    )
    return CloneBaseline(
        records=records,
        manifest_sha256=manifest_sha,
        sidecar_path=sidecar_path,
        sidecar_sha256=sidecar_sha,
        sidecar_bytes=sidecar_bytes,
        manifest_entry_count=len(entries),
        unique_regular_file_bytes=unique_bytes,
        total_xattr_bytes=total_xattr_bytes,
        namespace_entry_counts=dict(sorted(namespace_counts.items())),
        event_scope_file_counts=dict(sorted(event_scope_counts.items())),
    )


def _load_local_clone_baseline(
    plan: WatchPlan,
    manifest: pathlib.Path,
) -> tuple[dict[pathlib.Path, FileFingerprint], str]:
    """Compatibility helper for tests; production must attest a sidecar."""

    entries, manifest_sha = _read_safe_baseline_manifest(manifest)
    records: dict[pathlib.Path, FileFingerprint] = {}
    for digest, logical_id in entries:
        if logical_id.startswith("@"):
            continue
        path = plan.root / pathlib.PurePosixPath(logical_id)
        classified = classify_event(plan, str(path), ("IsFile",))
        if not classified.included or classified.scope is None:
            raise ValueError(f"unwatched local clone-baseline path: {path}")
        fingerprint = _capture_file_fingerprint(path)
        if fingerprint.sha256 != digest:
            raise ValueError(f"clone-baseline content digest mismatch: {path}")
        records[path] = fingerprint
    return records, manifest_sha


def _reconcile_item_cloned_event(
    event: ClassifiedEvent,
    record: DarwinFSEventRecord,
    baseline: dict[pathlib.Path, CloneBaselineRecord | FileFingerprint],
) -> ClassifiedEvent:
    if (
        not event.included
        or tuple(event.flags) != ("IsFile", "ItemCloned")
        or record.raw_flags != PURE_ITEM_CLONED_FILE_FLAGS
    ):
        return event
    path = _absolute(pathlib.Path(event.path))
    stored = baseline.get(path)
    if stored is None:
        return dataclasses.replace(
            event,
            clone_reconciliation={
                "policy": CLONE_RECONCILIATION_POLICY,
                "status": "clone-baseline-missing",
            },
        )
    if isinstance(stored, CloneBaselineRecord):
        expected = stored.fingerprint
        manifest_entries = [entry.to_json() for entry in stored.manifest_entries]
        event_scope = stored.event_scope
    else:  # Kept only for unit-level compatibility; production never uses it.
        expected = stored
        manifest_entries = []
        event_scope = event.scope
    current = _capture_file_fingerprint(path)
    status = (
        "clone-observed-no-delta"
        if current == expected
        else "clone-observed-delta"
    )
    reconciliation: dict[str, object] = {
        "policy": CLONE_RECONCILIATION_POLICY,
        "status": status,
        "baselineCanonicalPath": str(path),
        "baselineEventScope": event_scope,
        "baselineManifestEntries": manifest_entries,
        "baseline": expected.to_json(),
        "current": current.to_json(),
    }
    if current != expected:
        return dataclasses.replace(
            event,
            clone_reconciliation=reconciliation,
        )
    return dataclasses.replace(
        event,
        material=False,
        clone_reconciliation=reconciliation,
    )


def _is_within(path: pathlib.Path, root: pathlib.Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def _compact_roots(paths: Iterable[pathlib.Path]) -> tuple[pathlib.Path, ...]:
    selected: list[pathlib.Path] = []
    for path in sorted({_absolute(path) for path in paths}, key=lambda item: (len(item.parts), str(item))):
        if not any(_is_within(path, parent) for parent in selected):
            selected.append(path)
    return tuple(selected)


def build_watch_plan(
    root: pathlib.Path,
    extra_toolchain_roots: Iterable[pathlib.Path] = (),
    expected_flutter_root: pathlib.Path | None = None,
) -> WatchPlan:
    root = root.resolve(strict=True)
    local_directories = tuple(
        (root / relative).resolve(strict=True)
        for relative in tree_manifest.INCLUDED_DIRECTORIES
    )
    flutter_root = tree_manifest.bound_flutter_root(root, expected_flutter_root)
    exact_files = frozenset(
        (root / relative).resolve(strict=True)
        for relative in tree_manifest.INCLUDED_FILES
    ).union(
        (flutter_root / relative).resolve(strict=True)
        for relative in tree_manifest.TOOLCHAIN_FILES
    )
    package_roots = tuple(
        path
        for _, path in (
            *tree_manifest.collect_external_roots(root),
            *tree_manifest.collect_flutter_tool_roots(root),
        )
    )
    resolved_toolchains = tuple(
        sorted(
            {
                (flutter_root / relative).resolve(strict=True)
                for relative in tree_manifest.TOOLCHAIN_DIRECTORIES
            }.union(
                path.resolve(strict=True) for path in extra_toolchain_roots
            ),
            key=str,
        )
    )
    return WatchPlan(
        root=root,
        local_directories=local_directories,
        exact_files=exact_files,
        package_roots=package_roots,
        toolchain_roots=resolved_toolchains,
    )


def _ignored_local(relative: pathlib.PurePosixPath) -> str | None:
    if tree_manifest.LOCAL_IGNORED_PARTS.intersection(relative.parts):
        return "generated-local-directory"
    if any(relative.name.endswith(suffix) for suffix in tree_manifest.IGNORED_SUFFIXES):
        return "generated-local-suffix"
    if relative.as_posix() in EXACT_DOC_ALLOWLIST:
        return "exact-doc-allowlist"
    return None


def _ignored_external(relative: pathlib.PurePosixPath) -> str | None:
    return tree_manifest.external_ignored_reason(relative)


def classify_event(plan: WatchPlan, path_text: str, flags: Iterable[str]) -> ClassifiedEvent:
    path = _absolute(pathlib.Path(path_text))
    normalized_flags = tuple(sorted(set(flags)))
    if not normalized_flags:
        raise ValueError("fswatch event has no flags")
    unknown_flags = set(normalized_flags).difference(KNOWN_FLAGS)
    if unknown_flags:
        raise ValueError(f"unknown fswatch event flags: {sorted(unknown_flags)}")
    integrity_failures = set(normalized_flags).intersection(INTEGRITY_FAILURE_FLAGS)
    if integrity_failures:
        raise RuntimeError(
            "fswatch reported integrity failure flags: "
            f"{sorted(integrity_failures)}"
        )
    material = bool(MATERIAL_FLAGS.intersection(normalized_flags))

    if path in plan.exact_files:
        return ClassifiedEvent(str(path), normalized_flags, True, material, "exact-file", None)

    for directory in plan.local_directories:
        if _is_within(path, directory):
            relative = pathlib.PurePosixPath(path.relative_to(plan.root).as_posix())
            ignored = _ignored_local(relative)
            return ClassifiedEvent(
                str(path), normalized_flags, ignored is None, material,
                "local-directory", ignored,
            )

    for package_root in plan.package_roots:
        if _is_within(path, package_root):
            relative = pathlib.PurePosixPath(path.relative_to(package_root).as_posix())
            ignored = _ignored_external(relative)
            return ClassifiedEvent(
                str(path), normalized_flags, ignored is None, material,
                "external-package", ignored,
            )

    for toolchain_root in plan.toolchain_roots:
        if _is_within(path, toolchain_root):
            return ClassifiedEvent(
                str(path), normalized_flags, True, material, "toolchain", None
            )

    return ClassifiedEvent(
        str(path), normalized_flags, False, material, None, "outside-watch-plan"
    )


def _write_json(path: pathlib.Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def _append_event(path: pathlib.Path, event: ClassifiedEvent) -> None:
    _append_json_record(path, event.to_json())


def _append_json_record(path: pathlib.Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(value, sort_keys=True) + "\n")
        stream.flush()
        os.fsync(stream.fileno())


def _persist_darwin_record(
    path: pathlib.Path,
    plan: WatchPlan,
    record: DarwinFSEventRecord,
    clone_baseline: dict[
        pathlib.Path, CloneBaselineRecord | FileFingerprint
    ] | None = None,
) -> ClassifiedEvent:
    # This write intentionally precedes decoding and semantic classification.
    # Unknown or integrity-failure flags therefore remain inspectable evidence.
    _append_json_record(path, record.to_raw_json())
    flags = decode_darwin_flags(record.raw_flags)
    event = classify_event(plan, record.path, flags)
    if clone_baseline is not None:
        event = _reconcile_item_cloned_event(event, record, clone_baseline)
    classified = event.to_json()
    classified.update(
        {
            "recordType": "classified-darwin-fsevents",
            "eventId": record.event_id,
            "callbackBatchSequence": record.callback_batch_sequence,
            "callbackRecordSequence": record.callback_record_sequence,
        }
    )
    _append_json_record(path, classified)
    return event


def _read_records(stream, output: queue.Queue[tuple[str, bytes | str | None]]) -> None:
    buffer = b""
    try:
        while True:
            chunk = os.read(stream.fileno(), 4096)
            if not chunk:
                break
            buffer += chunk
            while b"\0" in buffer:
                record, buffer = buffer.split(b"\0", 1)
                if record:
                    output.put(("record", record))
        if buffer:
            output.put(
                (
                    "error",
                    "unterminated fswatch record at EOF: "
                    + repr(buffer[:256]),
                )
            )
    except Exception as error:
        output.put(("error", f"{type(error).__name__}: {error}"))
    finally:
        output.put(("eof", None))


def _read_stderr(stream, chunks: list[bytes], errors: list[str]) -> None:
    try:
        while True:
            chunk = os.read(stream.fileno(), 4096)
            if not chunk:
                break
            if sum(map(len, chunks)) < 65536:
                chunks.append(chunk[: 65536 - sum(map(len, chunks))])
    except Exception as error:
        errors.append(f"{type(error).__name__}: {error}")


def _stop_process(process: subprocess.Popen[bytes], timeout_seconds: float) -> dict[str, object]:
    term_sent = False
    kill_sent = False
    if process.poll() is None:
        try:
            process.terminate()
            term_sent = True
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            try:
                process.kill()
                kill_sent = True
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=timeout_seconds)
            except subprocess.TimeoutExpired:
                pass
    return {
        "termSent": term_sent,
        "killSent": kill_sent,
        "exitCode": process.returncode,
        "contained": process.poll() is not None,
    }


class _FSEventStreamContext(ctypes.Structure):
    _fields_ = [
        ("version", ctypes.c_long),
        ("info", ctypes.c_void_p),
        ("retain", ctypes.c_void_p),
        ("release", ctypes.c_void_p),
        ("copyDescription", ctypes.c_void_p),
    ]


_FSEVENT_CALLBACK = ctypes.CFUNCTYPE(
    None,
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.c_void_p,
    ctypes.POINTER(ctypes.c_uint32),
    ctypes.POINTER(ctypes.c_uint64),
)


class DarwinFSEventsWatcher:
    """Small stdlib-only FSEvents adapter retaining the native callback record."""

    def __init__(
        self,
        paths: Iterable[pathlib.Path],
        records: queue.Queue[tuple[str, object | None]],
    ) -> None:
        if sys.platform != "darwin":
            raise RuntimeError("darwin-fsevents backend requires macOS")
        self._paths = tuple(str(path) for path in paths)
        self._records = records
        self._started = threading.Event()
        self._flush_requested = threading.Event()
        self._drained = threading.Event()
        self._sentinel_emitted = threading.Event()
        self._ended = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._startup_error: str | None = None
        self._runloop: int | None = None
        self._cf = None
        self._batch_sequence = 0
        self._record_sequence = 0

    @property
    def pid(self) -> int:
        return os.getpid()

    def start(self, timeout_seconds: float) -> None:
        self._thread.start()
        if not self._started.wait(timeout_seconds):
            raise RuntimeError("Darwin FSEvents watcher did not start within the bound")
        if self._startup_error is not None:
            raise RuntimeError(self._startup_error)

    def poll(self) -> int | None:
        return 0 if self._started.is_set() and not self._thread.is_alive() else None

    def flush_and_stop(self, timeout_seconds: float) -> dict[str, object]:
        self._flush_requested.set()
        if self._runloop is not None and self._cf is not None:
            self._cf.CFRunLoopWakeUp(ctypes.c_void_p(self._runloop))
        drained = self._drained.wait(timeout_seconds)
        self._thread.join(timeout_seconds)
        return {
            "termSent": False,
            "killSent": False,
            "exitCode": 0 if not self._thread.is_alive() else None,
            "contained": not self._thread.is_alive(),
            "flushSyncRequested": True,
            "flushSyncCompleted": drained,
            "drainedSentinelEmitted": self._sentinel_emitted.is_set(),
        }

    def _run(self) -> None:
        core_services = None
        stream = None
        path_strings: list[int] = []
        paths_array = None
        try:
            core_services = ctypes.CDLL(
                "/System/Library/Frameworks/CoreServices.framework/CoreServices"
            )
            cf = ctypes.CDLL(
                "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
            )
            self._cf = cf
            cf.CFStringCreateWithCString.restype = ctypes.c_void_p
            cf.CFStringCreateWithCString.argtypes = [
                ctypes.c_void_p,
                ctypes.c_char_p,
                ctypes.c_uint32,
            ]
            cf.CFArrayCreate.restype = ctypes.c_void_p
            cf.CFArrayCreate.argtypes = [
                ctypes.c_void_p,
                ctypes.POINTER(ctypes.c_void_p),
                ctypes.c_long,
                ctypes.c_void_p,
            ]
            cf.CFRunLoopGetCurrent.restype = ctypes.c_void_p
            cf.CFRunLoopRunInMode.restype = ctypes.c_int32
            cf.CFRunLoopRunInMode.argtypes = [ctypes.c_void_p, ctypes.c_double, ctypes.c_bool]
            cf.CFRunLoopWakeUp.restype = None
            cf.CFRunLoopWakeUp.argtypes = [ctypes.c_void_p]
            cf.CFRelease.restype = None
            cf.CFRelease.argtypes = [ctypes.c_void_p]

            core_services.FSEventStreamCreate.restype = ctypes.c_void_p
            core_services.FSEventStreamCreate.argtypes = [
                ctypes.c_void_p,
                _FSEVENT_CALLBACK,
                ctypes.POINTER(_FSEventStreamContext),
                ctypes.c_void_p,
                ctypes.c_uint64,
                ctypes.c_double,
                ctypes.c_uint32,
            ]
            core_services.FSEventStreamScheduleWithRunLoop.argtypes = [
                ctypes.c_void_p,
                ctypes.c_void_p,
                ctypes.c_void_p,
            ]
            core_services.FSEventStreamScheduleWithRunLoop.restype = None
            core_services.FSEventStreamStart.argtypes = [ctypes.c_void_p]
            core_services.FSEventStreamStart.restype = ctypes.c_bool
            for name in (
                "FSEventStreamFlushSync",
                "FSEventStreamStop",
                "FSEventStreamInvalidate",
                "FSEventStreamRelease",
            ):
                getattr(core_services, name).argtypes = [ctypes.c_void_p]
                getattr(core_services, name).restype = None

            for path in self._paths:
                value = cf.CFStringCreateWithCString(
                    None,
                    os.fsencode(path),
                    0x08000100,
                )
                if not value:
                    raise RuntimeError(f"CFString creation failed for watch path: {path}")
                path_strings.append(value)
            values = (ctypes.c_void_p * len(path_strings))(*path_strings)
            paths_array = cf.CFArrayCreate(None, values, len(path_strings), None)
            if not paths_array:
                raise RuntimeError("CFArray creation failed for watch paths")

            def callback(
                _stream,
                _info,
                count,
                event_paths,
                event_flags,
                event_ids,
            ):
                try:
                    self._batch_sequence += 1
                    paths = ctypes.cast(event_paths, ctypes.POINTER(ctypes.c_char_p))
                    for index in range(count):
                        self._record_sequence += 1
                        raw_path = paths[index]
                        if raw_path is None:
                            raise RuntimeError("FSEvents callback supplied a null path")
                        self._records.put(
                            (
                                "record",
                                DarwinFSEventRecord(
                                    path=os.fsdecode(raw_path),
                                    raw_flags=int(event_flags[index]),
                                    event_id=int(event_ids[index]),
                                    callback_batch_sequence=self._batch_sequence,
                                    callback_record_sequence=self._record_sequence,
                                ),
                            )
                        )
                except Exception as error:
                    self._records.put(
                        ("error", f"native callback failed: {type(error).__name__}: {error}")
                    )

            self._callback = _FSEVENT_CALLBACK(callback)
            context = _FSEventStreamContext(0, None, None, None, None)
            stream = core_services.FSEventStreamCreate(
                None,
                self._callback,
                ctypes.byref(context),
                paths_array,
                0xFFFFFFFFFFFFFFFF,
                0.05,
                DARWIN_STREAM_CREATE_FLAGS,
            )
            if not stream:
                raise RuntimeError("FSEventStreamCreate failed")
            runloop = cf.CFRunLoopGetCurrent()
            if not runloop:
                raise RuntimeError("CFRunLoopGetCurrent failed")
            self._runloop = runloop
            default_mode = ctypes.c_void_p.in_dll(cf, "kCFRunLoopDefaultMode").value
            core_services.FSEventStreamScheduleWithRunLoop(
                stream,
                runloop,
                default_mode,
            )
            if not core_services.FSEventStreamStart(stream):
                raise RuntimeError("FSEventStreamStart failed")
            self._started.set()
            while not self._flush_requested.is_set():
                cf.CFRunLoopRunInMode(default_mode, 0.05, True)
            core_services.FSEventStreamFlushSync(stream)
            core_services.FSEventStreamStop(stream)
            self._records.put(("drained", None))
            self._sentinel_emitted.set()
            self._drained.set()
        except Exception as error:
            message = f"{type(error).__name__}: {error}"
            if not self._started.is_set():
                self._startup_error = message
                self._started.set()
            self._records.put(("error", message))
        finally:
            if stream and core_services is not None:
                core_services.FSEventStreamInvalidate(stream)
                core_services.FSEventStreamRelease(stream)
            if paths_array and self._cf is not None:
                self._cf.CFRelease(paths_array)
            if self._cf is not None:
                for value in path_strings:
                    self._cf.CFRelease(value)
            self._ended.set()


def run_guard(
    *,
    plan: WatchPlan,
    fswatch: pathlib.Path | None,
    backend: str = "fswatch",
    stop_file: pathlib.Path,
    ready_file: pathlib.Path,
    events_file: pathlib.Path,
    result_file: pathlib.Path,
    baseline_manifest: pathlib.Path | None,
    baseline_sidecar: pathlib.Path | None,
    stop_timeout_seconds: float,
    nonce: str,
) -> int:
    if NONCE.fullmatch(nonce) is None:
        raise ValueError("nonce must be exactly 32 lowercase hexadecimal characters")
    if stop_file.exists():
        raise ValueError(f"stop file must not exist before guard startup: {stop_file}")
    stale_candidates = [ready_file, events_file, result_file]
    if baseline_sidecar is not None:
        stale_candidates.append(baseline_sidecar)
    stale = [path for path in stale_candidates if path.exists() or path.is_symlink()]
    if stale:
        raise ValueError(f"stale guard output exists: {[str(path) for path in stale]}")
    _EXTERNAL_TERMINATION.clear()
    started_us = time.time_ns() // 1_000
    events_file.parent.mkdir(parents=True, exist_ok=True)
    native_watch_roots: tuple[pathlib.Path, ...] = ()
    clone_baseline: dict[pathlib.Path, CloneBaselineRecord] = {}
    baseline_state: CloneBaseline | None = None
    baseline_manifest_sha: str | None = None
    if backend == "darwin-fsevents":
        if baseline_manifest is None:
            raise ValueError(
                "darwin-fsevents backend requires --baseline-manifest"
            )
        if baseline_sidecar is None:
            raise ValueError(
                "darwin-fsevents backend requires --baseline-sidecar"
            )
        native_watch_roots = _compact_roots(
            path if path.is_dir() else path.parent for path in plan.watch_paths
        )
        _require_native_events_sink_outside_watch_roots(
            events_file,
            native_watch_roots,
        )
    events_file.touch(exist_ok=False)
    canonical_events_file = events_file.resolve(strict=True)
    records: queue.Queue[tuple[str, object | None]] = queue.Queue()
    process: subprocess.Popen[bytes] | None = None
    native_watcher: DarwinFSEventsWatcher | None = None
    reader: threading.Thread | None = None
    stderr_chunks: list[bytes] = []
    stderr_errors: list[str] = []
    stderr_reader: threading.Thread | None = None
    if backend == "fswatch":
        if fswatch is None:
            raise ValueError("fswatch backend requires --fswatch")
        command = [
            str(fswatch),
            "--recursive",
            "--latency=0.1",
            "--print0",
            "--format=%p\t%f",
            *(str(path) for path in plan.watch_paths),
        ]
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert process.stdout is not None
        assert process.stderr is not None
        reader = threading.Thread(target=_read_records, args=(process.stdout, records), daemon=True)
        stderr_reader = threading.Thread(
            target=_read_stderr,
            args=(process.stderr, stderr_chunks, stderr_errors),
            daemon=True,
        )
        reader.start()
        stderr_reader.start()
    elif backend == "darwin-fsevents":
        native_watcher = DarwinFSEventsWatcher(native_watch_roots, records)
        native_watcher.start(BOOTSTRAP_TIMEOUT_SECONDS)
    else:
        raise ValueError(f"unsupported watcher backend: {backend}")
    bootstrap_events = 0
    observed = 0
    violating = 0
    raw_callback_records = 0
    classified_events = 0
    fatal_raw_records = 0
    suppressed_internal_sink_events = 0
    clone_observed_no_delta_events = 0
    final_queued = 0
    stop_requested_us: int | None = None
    ready_written = False
    status = "starting"
    guard_error: str | None = None
    canary = (
        plan.root
        / "tool/telemetry_memory_rig/__pycache__"
        / f"source-tree-guard-canary-{nonce}.pyc"
    )
    canary.parent.mkdir(parents=True, exist_ok=True)
    canary_created_seen = False
    canary_removed_seen = False
    canary_write_attempts = 0
    canary_delete_attempts = 0
    next_canary_action = time.monotonic()
    bootstrap_deadline = time.monotonic() + BOOTSTRAP_TIMEOUT_SECONDS
    quiet_deadline = time.monotonic() + BOOTSTRAP_QUIET_SECONDS
    native_termination: dict[str, object] | None = None
    native_drained_observed = False
    native_drain_deadline: float | None = None

    def decode(raw: object | None) -> ClassifiedEvent | None:
        nonlocal raw_callback_records, classified_events, fatal_raw_records
        nonlocal suppressed_internal_sink_events
        if isinstance(raw, DarwinFSEventRecord):
            if _is_suppressible_internal_sink_event(
                raw,
                canonical_events_file,
            ):
                suppressed_internal_sink_events += 1
                return None
            raw_callback_records += 1
            try:
                event = _persist_darwin_record(
                    events_file,
                    plan,
                    raw,
                    clone_baseline,
                )
            except Exception:
                fatal_raw_records += 1
                raise
            classified_events += 1
            return event
        if not isinstance(raw, bytes):
            raise ValueError("fswatch record is not bytes")
        decoded = raw.decode("utf-8", errors="strict")
        if "\t" not in decoded:
            raise ValueError(f"invalid fswatch record: {decoded!r}")
        path_text, flag_text = decoded.rsplit("\t", 1)
        return classify_event(plan, path_text, flag_text.split())

    def persist(raw: object | None) -> bool:
        nonlocal observed, violating, clone_observed_no_delta_events
        event = decode(raw)
        if event is None:
            return False
        if not isinstance(raw, DarwinFSEventRecord):
            _append_event(events_file, event)
        observed += 1
        if (
            event.clone_reconciliation is not None
            and event.clone_reconciliation.get("status")
            == "clone-observed-no-delta"
        ):
            clone_observed_no_delta_events += 1
        if event.violates:
            violating += 1
        return event.violates

    try:
        while True:
            now = time.monotonic()
            if _EXTERNAL_TERMINATION.is_set():
                status = "terminated-before-ready"
                break
            if stop_file.exists():
                status = "stop-requested-before-ready"
                break
            watcher_exited = (
                process.poll() is not None
                if process is not None
                else native_watcher is not None and native_watcher.poll() is not None
            )
            if watcher_exited:
                status = "watcher-exited-before-ready"
                break
            if now >= bootstrap_deadline:
                status = "bootstrap-never-quiesced"
                break
            if canary_created_seen and canary_removed_seen and now >= quiet_deadline:
                status = "running"
                break
            if now >= next_canary_action and not canary_created_seen:
                canary_write_attempts += 1
                canary.write_bytes(
                    f"{nonce}:{canary_write_attempts}".encode("ascii")
                )
                next_canary_action = now + CANARY_CREATE_RETRY_SECONDS
            elif now >= next_canary_action and not canary_removed_seen:
                if canary.exists():
                    canary.unlink()
                    canary_delete_attempts += 1
                    next_canary_action = now + CANARY_REMOVE_RETRY_SECONDS
                else:
                    canary_write_attempts += 1
                    canary.write_bytes(
                        f"{nonce}:{canary_write_attempts}".encode("ascii")
                    )
                    next_canary_action = now + CANARY_REMOVE_TOGGLE_SECONDS
            try:
                kind, raw = records.get(timeout=0.05)
            except queue.Empty:
                continue
            if kind == "error":
                raise RuntimeError(f"stdout reader failed: {raw}")
            if kind == "eof":
                raise RuntimeError("stdout reader reached EOF before ready")
            event = decode(raw)
            if event is None:
                continue
            bootstrap_events += 1
            quiet_deadline = time.monotonic() + BOOTSTRAP_QUIET_SECONDS
            if pathlib.Path(event.path) == canary:
                if {"Created", "Updated"}.intersection(event.flags):
                    canary_created_seen = True
                if {"Removed", "Renamed", "MovedFrom", "MovedTo"}.intersection(event.flags):
                    canary_removed_seen = True
            if canary_created_seen and canary.exists():
                canary.unlink(missing_ok=True)
                canary_delete_attempts += 1
                next_canary_action = time.monotonic() + CANARY_REMOVE_RETRY_SECONDS

        if status == "running":
            if native_watcher is not None:
                assert baseline_manifest is not None
                assert baseline_sidecar is not None
                captured_baseline = _load_manifest_clone_baseline(
                    plan,
                    baseline_manifest,
                    baseline_sidecar,
                )
                baseline_state = captured_baseline
                baseline_manifest_sha = baseline_state.manifest_sha256
                # Fingerprinting a large exact manifest takes measurable time.
                # Drain and quiesce everything queued during that window before
                # publishing readiness, so a post-fingerprint mutation cannot
                # race ahead of its already-captured FSEvents record.
                capture_quiet_deadline = (
                    time.monotonic() + BOOTSTRAP_QUIET_SECONDS
                )
                capture_hard_deadline = (
                    time.monotonic() + BOOTSTRAP_TIMEOUT_SECONDS
                )
                while time.monotonic() < capture_quiet_deadline:
                    if time.monotonic() >= capture_hard_deadline:
                        raise RuntimeError(
                            "baseline-capture events never quiesced"
                        )
                    if _EXTERNAL_TERMINATION.is_set() or stop_file.exists():
                        raise RuntimeError(
                            "guard stopped during baseline-capture drain"
                        )
                    if native_watcher.poll() is not None:
                        raise RuntimeError(
                            "native watcher exited during baseline-capture drain"
                        )
                    try:
                        kind, raw = records.get(timeout=0.05)
                    except queue.Empty:
                        continue
                    capture_quiet_deadline = (
                        time.monotonic() + BOOTSTRAP_QUIET_SECONDS
                    )
                    if kind == "error":
                        raise RuntimeError(f"stdout reader failed: {raw}")
                    if kind in {"eof", "drained"}:
                        raise RuntimeError(
                            "native watcher ended during baseline-capture drain"
                        )
                    if persist(raw):
                        raise RuntimeError(
                            "material event observed during baseline capture"
                        )
                clone_baseline = captured_baseline.records
            _write_json(
                ready_file,
                {
                    "version": RESULT_VERSION,
                    "nonce": nonce,
                    "pid": os.getpid(),
                    "watcherPid": (
                        process.pid if process is not None else native_watcher.pid
                    ),
                    "watcherBackend": backend,
                    "startedEpochUs": started_us,
                    "bootstrapEventCount": bootstrap_events,
                    "canaryCreatedObserved": canary_created_seen,
                    "canaryRemovedObserved": canary_removed_seen,
                    "canaryWriteAttemptCount": canary_write_attempts,
                    "canaryDeleteAttemptCount": canary_delete_attempts,
                    "watchPaths": [str(path) for path in plan.watch_paths],
                    "nativeFSEventsWatchRoots": (
                        [str(path) for path in native_watch_roots]
                        if native_watcher is not None
                        else None
                    ),
                    "suppressedInternalSinkEventCount": (
                        suppressed_internal_sink_events
                    ),
                    "cloneReconciliationPolicy": (
                        CLONE_RECONCILIATION_POLICY
                        if native_watcher is not None
                        else None
                    ),
                    "baselineManifestPath": (
                        str(_absolute(baseline_manifest))
                        if baseline_manifest is not None
                        else None
                    ),
                    "baselineManifestSha256": baseline_manifest_sha,
                    "baselineSidecarPath": (
                        str(baseline_state.sidecar_path)
                        if baseline_state is not None
                        else None
                    ),
                    "baselineSidecarSha256": (
                        baseline_state.sidecar_sha256
                        if baseline_state is not None
                        else None
                    ),
                    "baselineSidecarBytes": (
                        baseline_state.sidecar_bytes
                        if baseline_state is not None
                        else 0
                    ),
                    "baselineManifestEntryCount": (
                        baseline_state.manifest_entry_count
                        if baseline_state is not None
                        else 0
                    ),
                    "baselineUniqueRegularFileCount": (
                        baseline_state.unique_regular_file_count
                        if baseline_state is not None
                        else 0
                    ),
                    "baselineUniqueRegularFileBytes": (
                        baseline_state.unique_regular_file_bytes
                        if baseline_state is not None
                        else 0
                    ),
                    "baselineTotalXattrBytes": (
                        baseline_state.total_xattr_bytes
                        if baseline_state is not None
                        else 0
                    ),
                    "baselineNamespaceEntryCounts": (
                        baseline_state.namespace_entry_counts
                        if baseline_state is not None
                        else {}
                    ),
                    "baselineEventScopeFileCounts": (
                        baseline_state.event_scope_file_counts
                        if baseline_state is not None
                        else {}
                    ),
                },
            )
            ready_written = True

        drain_quiet_deadline: float | None = None
        drain_hard_deadline: float | None = None
        while True:
            if status != "running":
                break
            now = time.monotonic()
            if _EXTERNAL_TERMINATION.is_set():
                status = "guard-terminated"
                break
            if stop_requested_us is None and stop_file.exists():
                stop_requested_us = time.time_ns() // 1_000
                if native_watcher is not None:
                    native_termination = native_watcher.flush_and_stop(
                        stop_timeout_seconds
                    )
                    native_drain_deadline = (
                        time.monotonic() + stop_timeout_seconds
                    )
                else:
                    drain_quiet_deadline = now + STOP_DRAIN_QUIET_SECONDS
                    drain_hard_deadline = now + STOP_DRAIN_HARD_SECONDS
            if stop_requested_us is not None and native_watcher is None:
                assert drain_quiet_deadline is not None
                assert drain_hard_deadline is not None
                if now >= drain_hard_deadline or now >= drain_quiet_deadline:
                    status = "stopped"
                    break
            try:
                kind, raw = records.get(timeout=0.05)
            except queue.Empty:
                if (
                    native_drain_deadline is not None
                    and time.monotonic() >= native_drain_deadline
                ):
                    status = "guard-error"
                    guard_error = (
                        "native watcher did not deliver drained sentinel "
                        "within the bound"
                    )
                    break
                watcher_exited = (
                    process.poll() is not None
                    if process is not None
                    else native_watcher is not None and native_watcher.poll() is not None
                )
                if watcher_exited:
                    if native_watcher is None:
                        status = "watcher-exited"
                    else:
                        status = "guard-error"
                        guard_error = (
                            "native watcher exited before drained sentinel"
                        )
                    break
                continue
            if kind == "error":
                raise RuntimeError(f"stdout reader failed: {raw}")
            if kind == "eof":
                raise RuntimeError("stdout reader reached EOF while watcher was required")
            if kind == "drained":
                if stop_requested_us is None:
                    raise RuntimeError("native watcher drained without a stop request")
                native_drained_observed = True
                status = "stopped"
                break
            # The stop file can appear while the queue read is blocked.  Bind
            # its timestamp before classifying the just-dequeued record so a
            # post-stop violation cannot omit the stop-request evidence.
            if stop_requested_us is None and stop_file.exists():
                stop_requested_us = time.time_ns() // 1_000
                if native_watcher is not None:
                    native_termination = native_watcher.flush_and_stop(
                        stop_timeout_seconds
                    )
                    native_drain_deadline = (
                        time.monotonic() + stop_timeout_seconds
                    )
                else:
                    drain_quiet_deadline = time.monotonic() + STOP_DRAIN_QUIET_SECONDS
                    drain_hard_deadline = time.monotonic() + STOP_DRAIN_HARD_SECONDS
            if stop_requested_us is not None and native_watcher is None:
                drain_quiet_deadline = time.monotonic() + STOP_DRAIN_QUIET_SECONDS
            if persist(raw):
                status = "source-changed"
                break
    except Exception as error:  # Evidence must survive malformed watcher output too.
        status = "guard-error"
        guard_error = f"{type(error).__name__}: {error}"
    finally:
        canary.unlink(missing_ok=True)

    if process is not None:
        termination = _stop_process(process, stop_timeout_seconds)
    else:
        assert native_watcher is not None
        termination = native_termination or native_watcher.flush_and_stop(
            stop_timeout_seconds
        )
    if reader is not None:
        reader.join(timeout=stop_timeout_seconds)
    if stderr_reader is not None:
        stderr_reader.join(timeout=stop_timeout_seconds)
    if (reader is not None and reader.is_alive()) or (
        stderr_reader is not None and stderr_reader.is_alive()
    ):
        status = "guard-error"
        guard_error = "watcher reader thread did not terminate within the bound"
    while True:
        try:
            kind, raw = records.get_nowait()
        except queue.Empty:
            break
        if kind == "record":
            final_queued += 1
            try:
                if persist(raw):
                    status = "source-changed"
            except Exception as error:
                status = "guard-error"
                guard_error = f"{type(error).__name__}: {error}"
        elif kind == "error":
            status = "guard-error"
            guard_error = f"stdout reader failed: {raw}"
        elif kind == "drained":
            native_drained_observed = True

    if native_watcher is not None:
        termination["drainedSentinelObserved"] = native_drained_observed

    ended_us = time.time_ns() // 1_000
    stderr_text = b"".join(stderr_chunks).decode("utf-8", errors="replace")
    if stderr_errors:
        stderr_text += "\n" + "\n".join(stderr_errors)
    result = {
        "version": RESULT_VERSION,
        "nonce": nonce,
        "status": status,
        "watcherBackend": backend,
        "startedEpochUs": started_us,
        "endedEpochUs": ended_us,
        "readyWritten": ready_written,
        "stopRequestedEpochUs": stop_requested_us,
        "bootstrapEventCount": bootstrap_events,
        "canaryCreatedObserved": canary_created_seen,
        "canaryRemovedObserved": canary_removed_seen,
        "canaryWriteAttemptCount": canary_write_attempts,
        "canaryDeleteAttemptCount": canary_delete_attempts,
        "observedEventCount": observed,
        "violatingEventCount": violating,
        "rawCallbackRecordCount": raw_callback_records,
        "classifiedEventCount": classified_events,
        "fatalRawRecordCount": fatal_raw_records,
        "suppressedInternalSinkEventCount": suppressed_internal_sink_events,
        "cloneObservedNoDeltaEventCount": clone_observed_no_delta_events,
        "cloneReconciliationPolicy": (
            CLONE_RECONCILIATION_POLICY
            if native_watcher is not None
            else None
        ),
        "baselineManifestPath": (
            str(_absolute(baseline_manifest))
            if baseline_manifest is not None
            else None
        ),
        "baselineManifestSha256": baseline_manifest_sha,
        "baselineSidecarPath": (
            str(baseline_state.sidecar_path)
            if baseline_state is not None
            else None
        ),
        "baselineSidecarSha256": (
            baseline_state.sidecar_sha256
            if baseline_state is not None
            else None
        ),
        "baselineSidecarBytes": (
            baseline_state.sidecar_bytes if baseline_state is not None else 0
        ),
        "baselineManifestEntryCount": (
            baseline_state.manifest_entry_count if baseline_state is not None else 0
        ),
        "baselineUniqueRegularFileCount": (
            baseline_state.unique_regular_file_count
            if baseline_state is not None
            else 0
        ),
        "baselineUniqueRegularFileBytes": (
            baseline_state.unique_regular_file_bytes
            if baseline_state is not None
            else 0
        ),
        "baselineTotalXattrBytes": (
            baseline_state.total_xattr_bytes if baseline_state is not None else 0
        ),
        "baselineNamespaceEntryCounts": (
            baseline_state.namespace_entry_counts if baseline_state is not None else {}
        ),
        "baselineEventScopeFileCounts": (
            baseline_state.event_scope_file_counts
            if baseline_state is not None
            else {}
        ),
        "finalQueuedRecordCount": final_queued,
        "guardError": guard_error,
        "watcherStderr": stderr_text,
        "watcherTermination": termination,
    }
    _write_json(result_file, result)
    if not termination["contained"]:
        return 4
    if status == "stopped" and guard_error is None and ready_written:
        return 0
    return 2


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=pathlib.Path, required=True)
    parser.add_argument("--expected-flutter-root", type=pathlib.Path)
    parser.add_argument("--toolchain-root", type=pathlib.Path, action="append", default=[])
    parser.add_argument(
        "--backend",
        choices=("fswatch", "darwin-fsevents"),
        default="fswatch",
    )
    parser.add_argument("--fswatch", type=pathlib.Path, default=pathlib.Path("fswatch"))
    parser.add_argument("--stop-file", type=pathlib.Path, required=True)
    parser.add_argument("--ready-file", type=pathlib.Path, required=True)
    parser.add_argument("--events-file", type=pathlib.Path, required=True)
    parser.add_argument("--result-file", type=pathlib.Path, required=True)
    parser.add_argument("--baseline-manifest", type=pathlib.Path)
    parser.add_argument("--baseline-sidecar", type=pathlib.Path)
    parser.add_argument("--nonce", required=True)
    parser.add_argument("--stop-timeout-seconds", type=float, default=2.0)
    args = parser.parse_args()
    if args.stop_timeout_seconds <= 0:
        parser.error("--stop-timeout-seconds must be positive")
    def request_stop(_signum, _frame):
        _EXTERNAL_TERMINATION.set()

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)
    try:
        plan = build_watch_plan(
            args.root,
            args.toolchain_root,
            args.expected_flutter_root,
        )
        return run_guard(
            plan=plan,
            fswatch=args.fswatch if args.backend == "fswatch" else None,
            backend=args.backend,
            stop_file=args.stop_file,
            ready_file=args.ready_file,
            events_file=args.events_file,
            result_file=args.result_file,
            baseline_manifest=args.baseline_manifest,
            baseline_sidecar=args.baseline_sidecar,
            stop_timeout_seconds=args.stop_timeout_seconds,
            nonce=args.nonce,
        )
    except Exception as error:
        print(f"source-tree guard failed: {error}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
