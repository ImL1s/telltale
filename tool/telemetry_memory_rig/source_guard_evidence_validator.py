#!/usr/bin/env python3
"""Fail-closed validation for a completed Darwin source-tree guard."""

from __future__ import annotations

import ctypes
import hashlib
import json
import os
import pathlib
import stat
import sys
from typing import Any


POLICY = "sealed-manifest-pure-item-cloned-v2"
MAX_JSON_BYTES = 64 * 1024 * 1024
MAX_MANIFEST_BYTES = 32 * 1024 * 1024
MAX_LEDGER_BYTES = 256 * 1024 * 1024
MAX_MANIFEST_ENTRIES = 50_000

ATTESTATION_FIELDS = (
    "baselineManifestPath",
    "baselineManifestSha256",
    "baselineSidecarPath",
    "baselineSidecarSha256",
    "baselineSidecarBytes",
    "baselineManifestEntryCount",
    "baselineUniqueRegularFileCount",
    "baselineUniqueRegularFileBytes",
    "baselineTotalXattrBytes",
    "baselineNamespaceEntryCounts",
    "baselineEventScopeFileCounts",
)
READY_KEYS = {
    "version",
    "nonce",
    "pid",
    "watcherPid",
    "watcherBackend",
    "startedEpochUs",
    "bootstrapEventCount",
    "canaryCreatedObserved",
    "canaryRemovedObserved",
    "canaryWriteAttemptCount",
    "canaryDeleteAttemptCount",
    "watchPaths",
    "nativeFSEventsWatchRoots",
    "suppressedInternalSinkEventCount",
    "cloneReconciliationPolicy",
    *ATTESTATION_FIELDS,
}
RESULT_KEYS = {
    "version",
    "nonce",
    "status",
    "watcherBackend",
    "startedEpochUs",
    "endedEpochUs",
    "readyWritten",
    "stopRequestedEpochUs",
    "bootstrapEventCount",
    "canaryCreatedObserved",
    "canaryRemovedObserved",
    "canaryWriteAttemptCount",
    "canaryDeleteAttemptCount",
    "observedEventCount",
    "violatingEventCount",
    "rawCallbackRecordCount",
    "classifiedEventCount",
    "fatalRawRecordCount",
    "suppressedInternalSinkEventCount",
    "cloneObservedNoDeltaEventCount",
    "cloneReconciliationPolicy",
    *ATTESTATION_FIELDS,
    "finalQueuedRecordCount",
    "guardError",
    "watcherStderr",
    "watcherTermination",
}
TERMINATION_KEYS = {
    "termSent",
    "killSent",
    "exitCode",
    "contained",
    "flushSyncRequested",
    "flushSyncCompleted",
    "drainedSentinelEmitted",
    "drainedSentinelObserved",
}
SIDECAR_KEYS = {
    "version",
    "policy",
    "manifestPath",
    "manifestSha256",
    "manifestEntryCount",
    "uniqueRegularFileCount",
    "uniqueRegularFileBytes",
    "totalXattrBytes",
    "namespaceEntryCounts",
    "eventScopeFileCounts",
    "records",
}
RAW_KEYS = {
    "recordType",
    "epoch_us",
    "path",
    "rawFlags",
    "rawFlagsHex",
    "eventId",
    "callbackBatchSequence",
    "callbackRecordSequence",
}
CLASSIFIED_KEYS = {
    "recordType",
    "epoch_us",
    "path",
    "flags",
    "included",
    "material",
    "scope",
    "ignoredReason",
    "violates",
    "eventId",
    "callbackBatchSequence",
    "callbackRecordSequence",
}
FINGERPRINT_KEYS = {
    "sha256",
    "device",
    "inode",
    "mode",
    "linkCount",
    "uid",
    "gid",
    "size",
    "mtimeNs",
    "ctimeNs",
    "birthtimeNs",
    "fileFlags",
    "xattrs",
}
INTEGER_FINGERPRINT_FIELDS = (
    "device",
    "inode",
    "mode",
    "linkCount",
    "uid",
    "gid",
    "size",
    "mtimeNs",
    "ctimeNs",
)
NAMESPACES = {"local", "package", "flutterToolPackage", "flutterToolchain"}
EVENT_SCOPES = {"exact-file", "local-directory", "external-package", "toolchain"}
MATERIAL_FLAGS = {
    "Created",
    "Removed",
    "Renamed",
    "MovedFrom",
    "MovedTo",
    "Updated",
    "Link",
    "CloseWrite",
    "ItemCloned",
    "OwnerModified",
    "AttributeModified",
    "FSEventsUnspecified",
}
DARWIN_FLAGS = {
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
INTEGRITY_FLAGS = {
    "MustScanSubDirs",
    "UserDropped",
    "KernelDropped",
    "EventIdsWrapped",
    "HistoryDone",
    "RootChanged",
    "Mount",
    "Unmount",
}


class EvidenceValidationError(ValueError):
    """Raised when source-guard evidence is incomplete or inconsistent."""


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise EvidenceValidationError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _loads(data: bytes, label: str) -> Any:
    try:
        return json.loads(
            data.decode("utf-8", errors="strict"),
            object_pairs_hook=_reject_duplicate_keys,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceValidationError(f"{label} is not strict JSON: {error}") from error


def _read_regular(
    path: pathlib.Path, maximum: int, label: str
) -> tuple[pathlib.Path, bytes]:
    try:
        canonical = path.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise EvidenceValidationError(f"{label} path is unsafe: {error}") from error
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(canonical, flags)
    except OSError as error:
        raise EvidenceValidationError(
            f"{label} could not be opened: {error}"
        ) from error
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_uid != os.getuid()
            or before.st_mode & 0o022
            or before.st_size < 1
            or before.st_size > maximum
        ):
            raise EvidenceValidationError(f"{label} metadata is unsafe")
        chunks: list[bytes] = []
        total = 0
        while chunk := os.read(descriptor, min(1024 * 1024, maximum + 1 - total)):
            chunks.append(chunk)
            total += len(chunk)
            if total > maximum:
                raise EvidenceValidationError(f"{label} exceeds byte bound")
        after = os.fstat(descriptor)
        current = os.stat(canonical, follow_symlinks=False)

        def identity(item: os.stat_result) -> tuple[int, ...]:
            return (
                item.st_dev,
                item.st_ino,
                item.st_mode,
                item.st_nlink,
                item.st_size,
                item.st_mtime_ns,
                item.st_ctime_ns,
            )

        if identity(before) != identity(after) or identity(after) != identity(current):
            raise EvidenceValidationError(f"{label} changed while reading")
        return canonical, b"".join(chunks)
    finally:
        os.close(descriptor)


def _read_json(
    path: pathlib.Path, label: str
) -> tuple[pathlib.Path, dict[str, Any], bytes]:
    canonical, data = _read_regular(path, MAX_JSON_BYTES, label)
    value = _loads(data, label)
    if not isinstance(value, dict):
        raise EvidenceValidationError(f"{label} must be an object")
    return canonical, value, data


def _valid_sha256(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def _require_int(value: Any, label: str, *, minimum: int = 0) -> int:
    if type(value) is not int or value < minimum:
        raise EvidenceValidationError(f"{label} must be an integer >= {minimum}")
    return value


def _namespace(logical_id: str) -> str:
    if logical_id.startswith("@package/"):
        return "package"
    if logical_id.startswith("@flutter-tool-package/"):
        return "flutterToolPackage"
    if logical_id.startswith("@toolchain/"):
        return "flutterToolchain"
    if logical_id.startswith("@"):
        raise EvidenceValidationError("manifest namespace is unknown")
    return "local"


def _valid_fingerprint(value: Any) -> bool:
    if not isinstance(value, dict) or set(value) != FINGERPRINT_KEYS:
        return False
    if not _valid_sha256(value["sha256"]):
        return False
    if any(
        type(value[field]) is not int or value[field] < 0
        for field in INTEGER_FINGERPRINT_FIELDS
    ):
        return False
    if (
        value["inode"] < 1
        or value["mode"] & 0o170000 != 0o100000
        or value["mode"] & 0o002
        or (value["mode"] & 0o020 and value["gid"] in {os.getegid(), *os.getgroups()})
        or value["linkCount"] != 1
        or value["uid"] != os.getuid()
    ):
        return False
    for field in ("birthtimeNs", "fileFlags"):
        if value[field] is not None and (
            type(value[field]) is not int or value[field] < 0
        ):
            return False
    xattrs = value["xattrs"]
    if not isinstance(xattrs, list):
        return False
    names: list[str] = []
    for item in xattrs:
        if not isinstance(item, dict) or set(item) != {"name", "bytes", "sha256"}:
            return False
        name = item["name"]
        suffix = name[4:] if isinstance(name, str) and name.startswith("hex:") else ""
        if (
            not suffix
            or len(suffix) % 2
            or any(character not in "0123456789abcdef" for character in suffix)
            or type(item["bytes"]) is not int
            or item["bytes"] < 0
            or not _valid_sha256(item["sha256"])
        ):
            return False
        names.append(name)
    return names == sorted(names) and len(names) == len(set(names))


def _capture_live_fingerprint(path: pathlib.Path) -> dict[str, Any]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise EvidenceValidationError(
            f"baseline file cannot be opened: {path}"
        ) from error
    try:
        before = os.fstat(descriptor)
        digest = hashlib.sha256()
        while chunk := os.read(descriptor, 1024 * 1024):
            digest.update(chunk)
        names_and_values: list[tuple[bytes, bytes]]
        try:
            if hasattr(os, "listxattr") and hasattr(os, "getxattr"):
                names_and_values = [
                    (os.fsencode(name), os.getxattr(descriptor, name))
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
                    written = libc.flistxattr(descriptor, name_buffer, name_bytes, 0)
                    if written != name_bytes:
                        raise OSError(ctypes.get_errno(), "flistxattr changed")
                    names_and_values = []
                    for name in sorted(
                        item for item in name_buffer.raw[:written].split(b"\0") if item
                    ):
                        value_bytes = libc.fgetxattr(descriptor, name, None, 0, 0, 0)
                        if value_bytes < 0:
                            raise OSError(ctypes.get_errno(), "fgetxattr size failed")
                        value_buffer = ctypes.create_string_buffer(max(value_bytes, 1))
                        value_written = libc.fgetxattr(
                            descriptor, name, value_buffer, value_bytes, 0, 0
                        )
                        if value_written != value_bytes:
                            raise OSError(ctypes.get_errno(), "fgetxattr changed")
                        names_and_values.append(
                            (name, value_buffer.raw[:value_written])
                        )
            else:
                raise OSError("extended attribute API is unavailable")
        except OSError as error:
            raise EvidenceValidationError(
                f"baseline file xattrs cannot be fingerprinted: {path}"
            ) from error
        xattrs = [
            {
                "name": f"hex:{name.hex()}",
                "bytes": len(value),
                "sha256": hashlib.sha256(value).hexdigest(),
            }
            for name, value in names_and_values
        ]
        after = os.fstat(descriptor)
        current = os.stat(path, follow_symlinks=False)

        def identity(item: os.stat_result) -> tuple[int, ...]:
            return (
                item.st_dev,
                item.st_ino,
                item.st_mode,
                item.st_nlink,
                item.st_uid,
                item.st_gid,
                item.st_size,
                item.st_mtime_ns,
                item.st_ctime_ns,
                getattr(item, "st_flags", 0),
            )

        if identity(before) != identity(after) or identity(after) != identity(current):
            raise EvidenceValidationError(
                f"baseline file changed while reading: {path}"
            )
        birthtime = getattr(after, "st_birthtime", None)
        return {
            "sha256": digest.hexdigest(),
            "device": after.st_dev,
            "inode": after.st_ino,
            "mode": after.st_mode,
            "linkCount": after.st_nlink,
            "uid": after.st_uid,
            "gid": after.st_gid,
            "size": after.st_size,
            "mtimeNs": after.st_mtime_ns,
            "ctimeNs": after.st_ctime_ns,
            "birthtimeNs": (
                int(birthtime * 1_000_000_000) if birthtime is not None else None
            ),
            "fileFlags": getattr(after, "st_flags", None),
            "xattrs": xattrs,
        }
    finally:
        os.close(descriptor)


def _load_baseline(
    manifest_path: pathlib.Path, sidecar_path: pathlib.Path
) -> tuple[dict[str, dict[str, Any]], dict[str, Any]]:
    manifest, manifest_bytes = _read_regular(
        manifest_path, MAX_MANIFEST_BYTES, "baseline manifest"
    )
    try:
        source = manifest_bytes.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise EvidenceValidationError(
            "baseline manifest is not strict UTF-8"
        ) from error
    entries: dict[str, tuple[str, str]] = {}
    order: list[str] = []
    for number, line in enumerate(source.splitlines(), 1):
        if len(line) < 67 or line[64:66] != "  " or not _valid_sha256(line[:64]):
            raise EvidenceValidationError(f"baseline manifest line {number} is invalid")
        logical_id = line[66:]
        pure = pathlib.PurePosixPath(logical_id)
        if (
            not logical_id
            or pure.is_absolute()
            or ".." in pure.parts
            or any(
                ord(character) < 32 or ord(character) == 127 for character in logical_id
            )
            or logical_id in entries
        ):
            raise EvidenceValidationError("manifest logical ID is unsafe or duplicate")
        entries[logical_id] = (line[:64], _namespace(logical_id))
        order.append(logical_id)
        if len(entries) > MAX_MANIFEST_ENTRIES:
            raise EvidenceValidationError("baseline manifest exceeds entry bound")
    if (
        not entries
        or order != sorted(order)
        or source != "".join(f"{entries[item][0]}  {item}\n" for item in order)
    ):
        raise EvidenceValidationError("baseline manifest is empty or non-canonical")
    manifest_sha = hashlib.sha256(manifest_bytes).hexdigest()

    sidecar, payload, sidecar_bytes = _read_json(sidecar_path, "baseline sidecar")
    canonical_json = (
        json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode()
    if sidecar_bytes != canonical_json or set(payload) != SIDECAR_KEYS:
        raise EvidenceValidationError(
            "baseline sidecar is not canonical exact schema v1"
        )
    if (
        payload["version"] != 1
        or type(payload["version"]) is not int
        or payload["policy"] != POLICY
        or payload["manifestPath"] != str(manifest)
        or payload["manifestSha256"] != manifest_sha
    ):
        raise EvidenceValidationError("baseline sidecar identity is invalid")
    records = payload["records"]
    if not isinstance(records, list) or not records:
        raise EvidenceValidationError("baseline sidecar records are empty")
    records_by_path: dict[str, dict[str, Any]] = {}
    logical_seen: set[str] = set()
    namespace_counts: dict[str, int] = {}
    scope_counts: dict[str, int] = {}
    unique_bytes = 0
    xattr_bytes = 0
    ordered_paths: list[str] = []
    for record in records:
        if not isinstance(record, dict) or set(record) != {
            "canonicalPath",
            "eventScope",
            "manifestEntries",
            "fingerprint",
        }:
            raise EvidenceValidationError("baseline sidecar record schema is invalid")
        path_text = record["canonicalPath"]
        try:
            canonical_path = pathlib.Path(path_text).resolve(strict=True)
        except (TypeError, OSError, RuntimeError) as error:
            raise EvidenceValidationError("baseline record path is invalid") from error
        if (
            str(canonical_path) != path_text
            or path_text in records_by_path
            or not canonical_path.is_file()
        ):
            raise EvidenceValidationError(
                "baseline record path is non-canonical or duplicate"
            )
        scope = record["eventScope"]
        aliases = record["manifestEntries"]
        fingerprint = record["fingerprint"]
        if (
            scope not in EVENT_SCOPES
            or not isinstance(aliases, list)
            or not aliases
            or not _valid_fingerprint(fingerprint)
        ):
            raise EvidenceValidationError("baseline record content is invalid")
        if _capture_live_fingerprint(canonical_path) != fingerprint:
            raise EvidenceValidationError("baseline record no longer matches live file")
        logical_ids: list[str] = []
        alias_digests: set[str] = set()
        for alias in aliases:
            if not isinstance(alias, dict) or set(alias) != {
                "logicalId",
                "namespace",
                "sha256",
            }:
                raise EvidenceValidationError("baseline alias schema is invalid")
            logical_id = alias["logicalId"]
            expected = entries.get(logical_id)
            if (
                expected is None
                or logical_id in logical_seen
                or alias["namespace"] not in NAMESPACES
                or (alias["sha256"], alias["namespace"]) != expected
            ):
                raise EvidenceValidationError("baseline manifest coverage is invalid")
            logical_seen.add(logical_id)
            logical_ids.append(logical_id)
            alias_digests.add(alias["sha256"])
            namespace_counts[alias["namespace"]] = (
                namespace_counts.get(alias["namespace"], 0) + 1
            )
        if (
            logical_ids != sorted(logical_ids)
            or len(alias_digests) != 1
            or fingerprint["sha256"] not in alias_digests
        ):
            raise EvidenceValidationError("baseline aliases do not bind fingerprint")
        records_by_path[path_text] = record
        ordered_paths.append(path_text)
        unique_bytes += fingerprint["size"]
        xattr_bytes += sum(item["bytes"] for item in fingerprint["xattrs"])
        scope_counts[scope] = scope_counts.get(scope, 0) + 1
    if ordered_paths != sorted(ordered_paths) or logical_seen != set(entries):
        raise EvidenceValidationError("baseline records are unordered or incomplete")
    counts = {
        "manifestEntryCount": len(entries),
        "uniqueRegularFileCount": len(records),
        "uniqueRegularFileBytes": unique_bytes,
        "totalXattrBytes": xattr_bytes,
        "namespaceEntryCounts": dict(sorted(namespace_counts.items())),
        "eventScopeFileCounts": dict(sorted(scope_counts.items())),
    }
    for field, expected in counts.items():
        if type(payload[field]) is not type(expected) or payload[field] != expected:
            raise EvidenceValidationError(f"baseline sidecar {field} is invalid")
    attestation = {
        "baselineManifestPath": str(manifest),
        "baselineManifestSha256": manifest_sha,
        "baselineSidecarPath": str(sidecar),
        "baselineSidecarSha256": hashlib.sha256(sidecar_bytes).hexdigest(),
        "baselineSidecarBytes": len(sidecar_bytes),
        "baselineManifestEntryCount": counts["manifestEntryCount"],
        "baselineUniqueRegularFileCount": counts["uniqueRegularFileCount"],
        "baselineUniqueRegularFileBytes": counts["uniqueRegularFileBytes"],
        "baselineTotalXattrBytes": counts["totalXattrBytes"],
        "baselineNamespaceEntryCounts": counts["namespaceEntryCounts"],
        "baselineEventScopeFileCounts": counts["eventScopeFileCounts"],
    }
    return records_by_path, attestation


def _require_attestation(
    value: dict[str, Any], expected: dict[str, Any], label: str
) -> None:
    for field in ATTESTATION_FIELDS:
        if (
            type(value[field]) is not type(expected[field])
            or value[field] != expected[field]
        ):
            raise EvidenceValidationError(f"{label} {field} does not match baseline")


def _decode_flags(raw_flags: Any) -> list[str]:
    known_mask = sum(DARWIN_FLAGS)
    if type(raw_flags) is not int or raw_flags < 0 or raw_flags & ~known_mask:
        raise EvidenceValidationError("raw Darwin flags are invalid")
    native = {name for flag, name in DARWIN_FLAGS.items() if raw_flags & flag}
    if native & INTEGRITY_FLAGS:
        raise EvidenceValidationError("raw Darwin flags contain integrity failure")
    normalized: set[str] = set()
    for native_name, name in (
        ("ItemCreated", "Created"),
        ("ItemRemoved", "Removed"),
        ("ItemRenamed", "Renamed"),
        ("ItemModified", "Updated"),
        ("ItemChangeOwner", "OwnerModified"),
        ("ItemCloned", "ItemCloned"),
        ("ItemIsFile", "IsFile"),
        ("ItemIsDir", "IsDir"),
        ("ItemIsSymlink", "IsSymLink"),
    ):
        if native_name in native:
            normalized.add(name)
    if native & {"ItemInodeMetaMod", "ItemFinderInfoMod", "ItemXattrMod"}:
        normalized.add("AttributeModified")
    if native & {"ItemIsHardlink", "ItemIsLastHardlink"}:
        normalized.add("Link")
    if not normalized:
        normalized.add("FSEventsUnspecified")
    return sorted(normalized)


def _record_key(record: dict[str, Any]) -> tuple[int, int]:
    return (
        _require_int(
            record["callbackBatchSequence"], "callback batch sequence", minimum=1
        ),
        _require_int(
            record["callbackRecordSequence"], "callback record sequence", minimum=1
        ),
    )


def _load_ledger(path: pathlib.Path) -> list[dict[str, Any]]:
    _, data = _read_regular(path, MAX_LEDGER_BYTES, "source guard ledger")
    records: list[dict[str, Any]] = []
    for line_number, line in enumerate(data.splitlines(keepends=True), 1):
        if not line.endswith(b"\n"):
            raise EvidenceValidationError("source guard ledger has unterminated line")
        record = _loads(line, f"source guard ledger line {line_number}")
        if not isinstance(record, dict):
            raise EvidenceValidationError("source guard ledger record is not an object")
        record_type = record.get("recordType")
        expected = RAW_KEYS if record_type == "raw-darwin-fsevents" else CLASSIFIED_KEYS
        if record_type not in {"raw-darwin-fsevents", "classified-darwin-fsevents"}:
            raise EvidenceValidationError("source guard ledger record type is invalid")
        if "cloneReconciliation" in record:
            if record_type != "classified-darwin-fsevents":
                raise EvidenceValidationError("raw record has clone reconciliation")
            expected = expected | {"cloneReconciliation"}
        if set(record) != expected:
            raise EvidenceValidationError(
                "source guard ledger record schema is invalid"
            )
        records.append(record)
    return records


def _validate_paths(value: Any, label: str) -> list[str]:
    if not isinstance(value, list) or not value:
        raise EvidenceValidationError(f"{label} must be a nonempty list")
    paths: list[str] = []
    for item in value:
        if (
            not isinstance(item, str)
            or not pathlib.Path(item).is_absolute()
            or any(ord(character) < 32 or ord(character) == 127 for character in item)
            or os.path.normpath(item) != item
        ):
            raise EvidenceValidationError(f"{label} contains an invalid path")
        candidate = pathlib.Path(item)
        missing_parts: list[str] = []
        while not os.path.lexists(candidate):
            if candidate.parent == candidate:
                raise EvidenceValidationError(f"{label} has no existing ancestor")
            missing_parts.append(candidate.name)
            candidate = candidate.parent
        try:
            canonical_ancestor = candidate.resolve(strict=True)
        except (OSError, RuntimeError) as error:
            raise EvidenceValidationError(f"{label} contains an unsafe path") from error
        canonical = canonical_ancestor.joinpath(*reversed(missing_parts))
        if str(canonical) != item:
            raise EvidenceValidationError(f"{label} contains a non-canonical path")
        paths.append(item)
    expected = sorted(
        set(paths), key=lambda item: (len(pathlib.Path(item).parts), item)
    )
    if paths != expected:
        raise EvidenceValidationError(f"{label} is not canonical ordered and unique")
    return paths


def validate_completed_guard_evidence(
    result_path: str | os.PathLike[str],
    events_path: str | os.PathLike[str],
    ready_path: str | os.PathLike[str],
    baseline_manifest_path: str | os.PathLike[str],
    sidecar_path: str | os.PathLike[str],
) -> dict[str, Any]:
    """Validate a cleanly stopped guard and return a compact verified summary."""

    _, result, _ = _read_json(pathlib.Path(result_path), "source guard result")
    _, ready, _ = _read_json(pathlib.Path(ready_path), "source guard readiness")
    if set(result) != RESULT_KEYS or set(ready) != READY_KEYS:
        raise EvidenceValidationError("source guard ready/result schema is not exact")
    records_by_path, attestation = _load_baseline(
        pathlib.Path(baseline_manifest_path), pathlib.Path(sidecar_path)
    )
    _require_attestation(ready, attestation, "source guard readiness")
    _require_attestation(result, attestation, "source guard result")
    if any(ready[field] != result[field] for field in ATTESTATION_FIELDS):
        raise EvidenceValidationError("ready/result baseline attestations differ")

    if (
        type(ready["version"]) is not int
        or ready["version"] != 3
        or type(result["version"]) is not int
        or result["version"] != 3
        or not isinstance(ready["nonce"], str)
        or len(ready["nonce"]) != 32
        or any(character not in "0123456789abcdef" for character in ready["nonce"])
        or result["nonce"] != ready["nonce"]
        or ready["watcherBackend"] != "darwin-fsevents"
        or result["watcherBackend"] != ready["watcherBackend"]
        or ready["cloneReconciliationPolicy"] != POLICY
        or result["cloneReconciliationPolicy"] != POLICY
    ):
        raise EvidenceValidationError("source guard ready/result identity is invalid")
    _require_int(ready["pid"], "guard pid", minimum=1)
    _require_int(ready["watcherPid"], "watcher pid", minimum=1)
    watch_paths = _validate_paths(ready["watchPaths"], "watch paths")
    native_roots = _validate_paths(
        ready["nativeFSEventsWatchRoots"], "native watch roots"
    )
    if any(
        not any(
            pathlib.Path(watch_path).is_relative_to(pathlib.Path(native_root))
            for native_root in native_roots
        )
        for watch_path in watch_paths
    ):
        raise EvidenceValidationError(
            "native watch roots do not cover declared watch paths"
        )

    started = _require_int(result["startedEpochUs"], "started timestamp", minimum=1)
    stopped = _require_int(
        result["stopRequestedEpochUs"], "stop timestamp", minimum=started
    )
    ended = _require_int(result["endedEpochUs"], "ended timestamp", minimum=stopped)
    if ready["startedEpochUs"] != started:
        raise EvidenceValidationError("ready/result start timestamps differ")
    stable_ready_fields = (
        "bootstrapEventCount",
        "canaryCreatedObserved",
        "canaryRemovedObserved",
        "canaryWriteAttemptCount",
        "canaryDeleteAttemptCount",
    )
    if any(ready[field] != result[field] for field in stable_ready_fields):
        raise EvidenceValidationError("ready/result bootstrap evidence differs")
    for field in (
        "bootstrapEventCount",
        "canaryWriteAttemptCount",
        "canaryDeleteAttemptCount",
    ):
        _require_int(result[field], field)
    if (
        result["canaryCreatedObserved"] is not True
        or result["canaryRemovedObserved"] is not True
        or result["canaryWriteAttemptCount"] < 1
        or result["canaryDeleteAttemptCount"] < 1
    ):
        raise EvidenceValidationError("source guard canary proof is incomplete")
    ready_suppressed = _require_int(
        ready["suppressedInternalSinkEventCount"], "ready suppressed count"
    )
    result_suppressed = _require_int(
        result["suppressedInternalSinkEventCount"], "result suppressed count"
    )
    if result_suppressed < ready_suppressed:
        raise EvidenceValidationError("suppressed event count regressed")

    ledger = _load_ledger(pathlib.Path(events_path))
    raw_by_key: dict[tuple[int, int], dict[str, Any]] = {}
    classified_by_key: dict[tuple[int, int], dict[str, Any]] = {}
    last_epoch = started
    violating = 0
    clone_no_delta = 0
    for record in ledger:
        epoch = _require_int(record["epoch_us"], "ledger timestamp", minimum=started)
        if epoch < last_epoch or epoch > ended:
            raise EvidenceValidationError(
                "ledger timestamps are unordered or out of result bounds"
            )
        last_epoch = epoch
        key = _record_key(record)
        target = (
            raw_by_key
            if record["recordType"] == "raw-darwin-fsevents"
            else classified_by_key
        )
        if key in target:
            raise EvidenceValidationError("duplicate ledger record key")
        target[key] = record
        if record["recordType"] == "raw-darwin-fsevents":
            raw_flags = record["rawFlags"]
            _decode_flags(raw_flags)
            if record["rawFlagsHex"] != f"0x{raw_flags:08x}":
                raise EvidenceValidationError(
                    "raw flag hexadecimal encoding is invalid"
                )
            _require_int(record["eventId"], "raw event id")
            if not isinstance(record["path"], str) or not record["path"]:
                raise EvidenceValidationError("raw event path is invalid")
            continue
        if any(
            type(record[field]) is not bool
            for field in ("included", "material", "violates")
        ):
            raise EvidenceValidationError("classified booleans are invalid")
        _require_int(record["eventId"], "classified event id")
        if not isinstance(record["path"], str) or not record["path"]:
            raise EvidenceValidationError("classified event path is invalid")
        if record["violates"] != (record["included"] and record["material"]):
            raise EvidenceValidationError("classified violation invariant failed")
        if record["scope"] is not None and record["scope"] not in EVENT_SCOPES:
            raise EvidenceValidationError("classified scope is invalid")
        if record["ignoredReason"] is not None and not isinstance(
            record["ignoredReason"], str
        ):
            raise EvidenceValidationError("classified ignored reason is invalid")
        if record["included"] != (record["scope"] is not None):
            raise EvidenceValidationError("classified inclusion/scope binding failed")
        violating += int(record["violates"])

    if set(raw_by_key) != set(classified_by_key):
        raise EvidenceValidationError("raw/classified ledger pairing is incomplete")
    for key, classified in classified_by_key.items():
        raw = raw_by_key[key]
        normalized = _decode_flags(raw["rawFlags"])
        if (
            raw["eventId"] != classified["eventId"]
            or raw["path"] != classified["path"]
            or classified["flags"] != normalized
            or raw["epoch_us"] > classified["epoch_us"]
        ):
            raise EvidenceValidationError("raw/classified identity or flags differ")
        reconciliation = classified.get("cloneReconciliation")
        if reconciliation is None:
            if classified["material"] != bool(set(normalized) & MATERIAL_FLAGS):
                raise EvidenceValidationError("classified material flag is invalid")
            continue
        if not isinstance(reconciliation, dict):
            raise EvidenceValidationError("clone reconciliation is not an object")
        status_value = reconciliation.get("status")
        if (
            raw["rawFlags"] != 0x00410000
            or normalized != ["IsFile", "ItemCloned"]
            or classified["included"] is not True
            or reconciliation.get("policy") != POLICY
        ):
            raise EvidenceValidationError("clone reconciliation envelope is invalid")
        if status_value == "clone-baseline-missing":
            valid = (
                set(reconciliation) == {"policy", "status"}
                and classified["material"] is True
                and classified["violates"] is True
            )
        else:
            baseline_record = records_by_path.get(classified["path"])
            expected_keys = {
                "policy",
                "status",
                "baselineCanonicalPath",
                "baselineEventScope",
                "baselineManifestEntries",
                "baseline",
                "current",
            }
            binding = (
                set(reconciliation) == expected_keys
                and baseline_record is not None
                and classified["scope"] == baseline_record["eventScope"]
                and reconciliation["baselineCanonicalPath"]
                == baseline_record["canonicalPath"]
                and reconciliation["baselineEventScope"]
                == baseline_record["eventScope"]
                and reconciliation["baselineManifestEntries"]
                == baseline_record["manifestEntries"]
                and reconciliation["baseline"] == baseline_record["fingerprint"]
                and _valid_fingerprint(reconciliation["current"])
            )
            if status_value == "clone-observed-delta":
                valid = (
                    binding
                    and classified["material"] is True
                    and classified["violates"] is True
                    and reconciliation["current"] != reconciliation["baseline"]
                )
            elif status_value == "clone-observed-no-delta":
                valid = (
                    binding
                    and classified["material"] is False
                    and classified["violates"] is False
                    and reconciliation["current"] == reconciliation["baseline"]
                )
                clone_no_delta += int(valid)
            else:
                valid = False
        if not valid:
            raise EvidenceValidationError("clone reconciliation proof is invalid")

    raw_count = len(raw_by_key)
    classified_count = len(classified_by_key)
    counters = {
        "rawCallbackRecordCount": raw_count,
        "classifiedEventCount": classified_count,
        "fatalRawRecordCount": 0,
        "cloneObservedNoDeltaEventCount": clone_no_delta,
        "violatingEventCount": violating,
    }
    for field, expected in counters.items():
        if type(result[field]) is not int or result[field] != expected:
            raise EvidenceValidationError(
                f"result counter {field} does not match ledger"
            )
    bootstrap = _require_int(result["bootstrapEventCount"], "bootstrap count")
    observed = _require_int(result["observedEventCount"], "observed count")
    final_queued = _require_int(result["finalQueuedRecordCount"], "final queued count")
    if (
        observed != classified_count - bootstrap
        or bootstrap > classified_count
        or final_queued > classified_count
    ):
        raise EvidenceValidationError("result derived counters are invalid")

    termination = result["watcherTermination"]
    if not isinstance(termination, dict) or set(termination) != TERMINATION_KEYS:
        raise EvidenceValidationError("watcher termination schema is invalid")
    if (
        result["status"] != "stopped"
        or result["readyWritten"] is not True
        or result["guardError"] is not None
        or result["watcherStderr"] != ""
        or violating != 0
        or any(termination[field] is not False for field in ("termSent", "killSent"))
        or termination["exitCode"] != 0
        or termination["contained"] is not True
        or termination["flushSyncRequested"] is not True
        or termination["flushSyncCompleted"] is not True
        or termination["drainedSentinelEmitted"] is not True
        or termination["drainedSentinelObserved"] is not True
    ):
        raise EvidenceValidationError(
            "source guard did not prove a clean unchanged stop"
        )
    return {
        "status": "stopped",
        "observedEventCount": observed,
        "baselineUniqueRegularFileCount": attestation["baselineUniqueRegularFileCount"],
        "unchangedTreeVerified": True,
    }
