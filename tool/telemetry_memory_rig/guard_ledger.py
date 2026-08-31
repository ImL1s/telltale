#!/usr/bin/env python3
"""Safely preserve a stopped source-guard ledger outside its live watch roots."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import stat
import tempfile


ALLOWED_LEDGER_NAMES = frozenset(
    {
        "bootstrap-source-tree-guard-events.jsonl",
        "source-tree-guard-events.jsonl",
    }
)


def _canonical_private_directory(path: pathlib.Path, label: str) -> pathlib.Path:
    lexical = pathlib.Path(os.path.abspath(os.fspath(path)))
    try:
        canonical = lexical.resolve(strict=True)
    except OSError as error:
        raise ValueError(f"missing {label}: {lexical}") from error
    if canonical != lexical:
        raise ValueError(f"symlinked {label}: {lexical}")
    metadata = canonical.lstat()
    if not stat.S_ISDIR(metadata.st_mode):
        raise ValueError(f"{label} is not a directory: {canonical}")
    if metadata.st_uid != os.getuid():
        raise ValueError(f"wrong owner for {label}: {canonical}")
    mode = stat.S_IMODE(metadata.st_mode)
    if mode != 0o700:
        raise ValueError(f"unsafe mode for {label}: {canonical} ({mode:o})")
    return canonical


def _lexical_child(
    path: pathlib.Path,
    parent: pathlib.Path,
    label: str,
) -> pathlib.Path:
    candidate = pathlib.Path(os.path.abspath(os.fspath(path)))
    if candidate.parent != parent:
        raise ValueError(f"{label} is not a direct child of {parent}: {candidate}")
    if candidate.name not in ALLOWED_LEDGER_NAMES:
        raise ValueError(f"unsupported {label} name: {candidate.name}")
    return candidate


def _private_regular_file(path: pathlib.Path, label: str) -> os.stat_result:
    try:
        metadata = path.lstat()
    except FileNotFoundError as error:
        raise ValueError(f"missing {label}: {path}") from error
    _validate_private_regular_metadata(metadata, path, label)
    return metadata


def _validate_private_regular_metadata(
    metadata: os.stat_result,
    path: pathlib.Path,
    label: str,
) -> None:
    if stat.S_ISLNK(metadata.st_mode):
        raise ValueError(f"symlinked {label}: {path}")
    if not stat.S_ISREG(metadata.st_mode):
        raise ValueError(f"{label} is not a regular file: {path}")
    if metadata.st_uid != os.getuid():
        raise ValueError(f"wrong owner for {label}: {path}")
    if metadata.st_nlink != 1:
        raise ValueError(f"hardlinked {label}: {path}")
    mode = stat.S_IMODE(metadata.st_mode)
    if mode != 0o600:
        raise ValueError(f"unsafe mode for {label}: {path} ({mode:o})")


def _stable_file_fields(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_uid,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _hash_file(path: pathlib.Path) -> tuple[int, str]:
    digest = hashlib.sha256()
    size = 0
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        before = os.fstat(descriptor)
        _validate_private_regular_metadata(before, path, "guard ledger")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            while chunk := stream.read(64 * 1024):
                size += len(chunk)
                digest.update(chunk)
        after = os.fstat(descriptor)
        if _stable_file_fields(before) != _stable_file_fields(after):
            raise ValueError("guard ledger changed during hashing")
    finally:
        os.close(descriptor)
    current = _private_regular_file(path, "guard ledger")
    if _stable_file_fields(after) != _stable_file_fields(current):
        raise ValueError("guard ledger identity changed after hashing")
    if size != after.st_size:
        raise ValueError("guard ledger hash size mismatch")
    return size, digest.hexdigest()


def _result(status: str, path: pathlib.Path) -> dict[str, object]:
    metadata = _private_regular_file(path, "preserved guard ledger")
    size, sha256 = _hash_file(path)
    if size != metadata.st_size:
        raise ValueError("preserved guard ledger size changed during validation")
    return {
        "version": 1,
        "status": status,
        "destination": str(path),
        "bytes": size,
        "sha256": sha256,
    }


def preserve_guard_ledger(
    *,
    live: pathlib.Path,
    destination: pathlib.Path,
    temp_root: pathlib.Path,
    evidence_root: pathlib.Path,
) -> dict[str, object]:
    """Copy a stopped private ledger atomically, then remove its live copy."""
    temp_parent = _canonical_private_directory(temp_root, "temporary ledger root")
    evidence_parent = _canonical_private_directory(evidence_root, "evidence root")
    live_path = _lexical_child(live, temp_parent, "live guard ledger")
    destination_path = _lexical_child(
        destination,
        evidence_parent,
        "preserved guard ledger",
    )
    if live_path.name != destination_path.name:
        raise ValueError("live and preserved guard ledger names differ")

    live_exists = os.path.lexists(live_path)
    destination_exists = os.path.lexists(destination_path)
    if not live_exists:
        if not destination_exists:
            raise ValueError("guard ledger is absent from live and evidence roots")
        return _result("already-preserved", destination_path)

    live_metadata = _private_regular_file(live_path, "live guard ledger")
    if destination_exists:
        existing = _result("recovered-existing", destination_path)
        live_size, live_hash = _hash_file(live_path)
        if existing["bytes"] != live_size or existing["sha256"] != live_hash:
            raise ValueError("live and preserved guard ledgers differ")
        live_path.unlink()
        temp_descriptor = os.open(temp_parent, os.O_RDONLY)
        try:
            os.fsync(temp_descriptor)
        finally:
            os.close(temp_descriptor)
        return existing

    descriptor, temporary_text = tempfile.mkstemp(
        prefix=f".{destination_path.name}.",
        suffix=".tmp",
        dir=evidence_parent,
    )
    temporary = pathlib.Path(temporary_text)
    source_descriptor = -1
    try:
        os.fchmod(descriptor, 0o600)
        source_descriptor = os.open(
            live_path,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
        )
        source_before = os.fstat(source_descriptor)
        _validate_private_regular_metadata(
            source_before,
            live_path,
            "open live guard ledger",
        )
        if _stable_file_fields(source_before) != _stable_file_fields(live_metadata):
            raise ValueError("live guard ledger identity changed before copy")
        digest = hashlib.sha256()
        copied = 0
        while chunk := os.read(source_descriptor, 64 * 1024):
            view = memoryview(chunk)
            while view:
                written = os.write(descriptor, view)
                if written <= 0:
                    raise OSError("guard ledger copy made no progress")
                view = view[written:]
            copied += len(chunk)
            digest.update(chunk)
        source_after = os.fstat(source_descriptor)
        if _stable_file_fields(source_before) != _stable_file_fields(source_after):
            raise ValueError("live guard ledger changed during copy")
        if copied != source_after.st_size:
            raise ValueError("live guard ledger copy size mismatch")
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        temporary_size, temporary_hash = _hash_file(temporary)
        if temporary_size != copied or temporary_hash != digest.hexdigest():
            raise ValueError("temporary guard ledger content mismatch")
        status = "preserved"
        try:
            os.link(temporary, destination_path, follow_symlinks=False)
        except FileExistsError:
            existing = _result("converged-existing", destination_path)
            if existing["bytes"] != copied or existing["sha256"] != digest.hexdigest():
                raise ValueError("concurrent preserved guard ledger differs")
            status = "converged-existing"
        temporary.unlink()
        evidence_descriptor = os.open(evidence_parent, os.O_RDONLY)
        try:
            os.fsync(evidence_descriptor)
        finally:
            os.close(evidence_descriptor)
        result = _result(status, destination_path)
        if result["bytes"] != copied or result["sha256"] != digest.hexdigest():
            raise ValueError("preserved guard ledger content mismatch")
        live_path.unlink()
        temp_descriptor = os.open(temp_parent, os.O_RDONLY)
        try:
            os.fsync(temp_descriptor)
        finally:
            os.close(temp_descriptor)
        return result
    finally:
        if source_descriptor >= 0:
            os.close(source_descriptor)
        if descriptor >= 0:
            os.close(descriptor)
        temporary.unlink(missing_ok=True)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", required=True, type=pathlib.Path)
    parser.add_argument("--destination", required=True, type=pathlib.Path)
    parser.add_argument("--temp-root", required=True, type=pathlib.Path)
    parser.add_argument("--evidence-root", required=True, type=pathlib.Path)
    return parser


def main() -> int:
    arguments = _parser().parse_args()
    result = preserve_guard_ledger(
        live=arguments.live,
        destination=arguments.destination,
        temp_root=arguments.temp_root,
        evidence_root=arguments.evidence_root,
    )
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
