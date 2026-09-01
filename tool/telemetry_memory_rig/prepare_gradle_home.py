#!/usr/bin/env python3
"""Prepare an isolated Gradle user home from the checked-in wrapper contract."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import stat
import urllib.parse


EXPECTED_KEYS = frozenset(
    {
        "distributionBase",
        "distributionPath",
        "zipStoreBase",
        "zipStorePath",
        "distributionUrl",
        "distributionSha256Sum",
    }
)
SHA256 = re.compile(r"^[0-9a-f]{64}$")
FILENAME = re.compile(r"^gradle-[0-9]+(?:\.[0-9]+)*(?:-[a-z0-9.-]+)?-(?:all|bin)\.zip$")
SAFE_RELATIVE = re.compile(r"^[A-Za-z0-9._/-]+$")
VERSION = 1


def _has_control(value: str) -> bool:
    return any(ord(character) < 32 or ord(character) == 127 for character in value)


def _has_symlink_component(path: pathlib.Path) -> bool:
    absolute = pathlib.Path(os.path.abspath(path))
    current = pathlib.Path(absolute.anchor)
    for part in absolute.parts[1:]:
        current /= part
        if current.is_symlink():
            return True
    return False


def _regular_file(path: pathlib.Path, label: str) -> pathlib.Path:
    if _has_control(str(path)) or _has_symlink_component(path):
        raise ValueError(f"unsafe or symlinked {label}: {path}")
    resolved = path.resolve(strict=True)
    mode = os.stat(resolved, follow_symlinks=False).st_mode
    if not stat.S_ISREG(mode):
        raise ValueError(f"{label} is not a regular file: {path}")
    return resolved


def _directory(path: pathlib.Path, label: str) -> pathlib.Path:
    if _has_control(str(path)) or _has_symlink_component(path):
        raise ValueError(f"unsafe or symlinked {label}: {path}")
    resolved = path.resolve(strict=True)
    if not resolved.is_dir():
        raise ValueError(f"{label} is not a directory: {path}")
    return resolved


def _decode_property(value: str, number: int) -> str:
    output: list[str] = []
    index = 0
    while index < len(value):
        character = value[index]
        if character != "\\":
            output.append(character)
            index += 1
            continue
        index += 1
        if index >= len(value) or value[index] not in {":", "=", "\\"}:
            raise ValueError(f"unsupported property escape on line {number}")
        output.append(value[index])
        index += 1
    decoded = "".join(output)
    if _has_control(decoded):
        raise ValueError(f"control character in property on line {number}")
    return decoded


def parse_wrapper_properties(path: pathlib.Path) -> dict[str, str]:
    path = _regular_file(path, "wrapper properties")
    properties: dict[str, str] = {}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if _has_control(raw):
            raise ValueError(f"control character on wrapper properties line {number}")
        line = raw.strip()
        if not line or line.startswith(("#", "!")):
            continue
        if line.endswith("\\") or "=" not in line:
            raise ValueError(f"unsupported wrapper properties line {number}")
        raw_key, raw_value = line.split("=", 1)
        key = _decode_property(raw_key.strip(), number)
        value = _decode_property(raw_value.strip(), number)
        if not key or not value or key in properties:
            raise ValueError(f"invalid or duplicate wrapper property on line {number}")
        properties[key] = value
    if set(properties) != EXPECTED_KEYS:
        raise ValueError(
            "wrapper properties schema mismatch: "
            f"missing={sorted(EXPECTED_KEYS - properties.keys())} "
            f"extra={sorted(properties.keys() - EXPECTED_KEYS)}"
        )
    return properties


def _safe_relative(value: str, label: str) -> pathlib.PurePosixPath:
    path = pathlib.PurePosixPath(value)
    if (
        SAFE_RELATIVE.fullmatch(value) is None
        or path.is_absolute()
        or not path.parts
        or ".." in path.parts
        or "." in path.parts
    ):
        raise ValueError(f"unsafe {label}: {value}")
    return path


def _base36(value: int) -> str:
    alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"
    if value == 0:
        return "0"
    output = ""
    while value:
        value, remainder = divmod(value, 36)
        output = alphabet[remainder] + output
    return output


def distribution_key(url: str) -> str:
    # Gradle wrapper PathAssembler.getHash(): MD5 URI.toString() bytes,
    # positive BigInteger, then lower-case radix 36. The accepted URL is ASCII,
    # so Java's default-charset getBytes() and ASCII encoding are identical.
    digest = hashlib.md5(url.encode("ascii")).digest()  # noqa: S324 - protocol identity, not security
    return _base36(int.from_bytes(digest, "big", signed=False))


def wrapper_contract(path: pathlib.Path) -> dict[str, object]:
    value = parse_wrapper_properties(path)
    if value["distributionBase"] != "GRADLE_USER_HOME":
        raise ValueError("distributionBase must be GRADLE_USER_HOME")
    if value["zipStoreBase"] != "GRADLE_USER_HOME":
        raise ValueError("zipStoreBase must be GRADLE_USER_HOME")
    distribution_path = _safe_relative(value["distributionPath"], "distributionPath")
    zip_path = _safe_relative(value["zipStorePath"], "zipStorePath")
    if distribution_path != zip_path:
        raise ValueError("distributionPath and zipStorePath must be identical")

    url = value["distributionUrl"]
    parsed = urllib.parse.urlsplit(url)
    filename = pathlib.PurePosixPath(parsed.path).name
    if (
        parsed.scheme != "https"
        or parsed.netloc != "services.gradle.org"
        or parsed.path != f"/distributions/{filename}"
        or parsed.query
        or parsed.fragment
        or FILENAME.fullmatch(filename) is None
        or urllib.parse.urlunsplit(parsed) != url
    ):
        raise ValueError(f"unsupported Gradle distribution URL: {url}")
    digest = value["distributionSha256Sum"]
    if SHA256.fullmatch(digest) is None:
        raise ValueError("distributionSha256Sum must be 64 lowercase hexadecimal characters")
    base_name = filename.removesuffix(".zip")
    key = distribution_key(url)
    relative_zip = zip_path / base_name / key / filename
    return {
        "url": url,
        "sha256": digest,
        "filename": filename,
        "distributionKey": key,
        "relativeZip": relative_zip,
    }


def _cached_candidates(cache_root: pathlib.Path, filename: str) -> list[pathlib.Path]:
    cache_root = _directory(cache_root, "cache root")
    candidates: list[pathlib.Path] = []
    for directory_text, directories, files in os.walk(cache_root, followlinks=False):
        directory = pathlib.Path(directory_text)
        for name in [*directories, *files]:
            child = directory / name
            if _has_control(name) or child.is_symlink():
                raise ValueError(f"unsafe symlink or control character in cache root: {child}")
        if filename in files:
            candidates.append(_regular_file(directory / filename, "cached distribution"))
    if len(candidates) > 1:
        raise ValueError(f"multiple cached Gradle distributions found: {candidates}")
    return candidates


def _copy_verified(source: pathlib.Path, destination: pathlib.Path, expected: str) -> str:
    if not hasattr(os, "O_NOFOLLOW"):
        raise RuntimeError("O_NOFOLLOW is required to verify cached distributions")
    flags = os.O_RDONLY | os.O_NOFOLLOW
    descriptor = os.open(source, flags)
    temporary = destination.with_name(f".{destination.name}.{os.getpid()}.tmp")
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise ValueError("cached distribution is not a regular file")
        digest = hashlib.sha256()
        output = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            while chunk := os.read(descriptor, 1024 * 1024):
                digest.update(chunk)
                view = memoryview(chunk)
                while view:
                    written = os.write(output, view)
                    if written <= 0:
                        raise OSError("short write while copying cached distribution")
                    view = view[written:]
            os.fsync(output)
        finally:
            os.close(output)
        after = os.fstat(descriptor)
        current = os.stat(source, follow_symlinks=False)
        def identity(item: os.stat_result) -> tuple[int, int, int, int, int, int]:
            return (
                item.st_dev,
                item.st_ino,
                item.st_mode,
                item.st_size,
                item.st_mtime_ns,
                item.st_ctime_ns,
            )
        if identity(before) != identity(after) or identity(after) != identity(current):
            raise ValueError("cached distribution changed while copying")
        actual = digest.hexdigest()
        if actual != expected:
            raise ValueError(
                f"cached distribution SHA-256 mismatch: expected={expected} actual={actual}"
            )
        os.replace(temporary, destination)
        return actual
    finally:
        os.close(descriptor)
        temporary.unlink(missing_ok=True)


def _write_evidence(path: pathlib.Path, value: dict[str, object]) -> None:
    if path.exists() or path.is_symlink():
        raise ValueError(f"stale evidence path exists: {path}")
    if _has_control(str(path)):
        raise ValueError("evidence path contains control characters")
    parent = _directory(path.parent, "evidence parent")
    path = parent / path.name
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def prepare(
    *,
    wrapper_properties: pathlib.Path,
    destination: pathlib.Path,
    evidence: pathlib.Path,
    cache_root: pathlib.Path | None,
) -> dict[str, object]:
    contract = wrapper_contract(wrapper_properties)
    if _has_control(str(destination)) or destination.exists() or destination.is_symlink():
        raise ValueError(f"destination must be a fresh non-symlink path: {destination}")
    parent = _directory(destination.parent, "destination parent")
    destination = parent / destination.name
    os.mkdir(destination, 0o700)
    try:
        relative_zip = contract["relativeZip"]
        assert isinstance(relative_zip, pathlib.PurePosixPath)
        target = destination.joinpath(*relative_zip.parts)
        cached: pathlib.Path | None = None
        if cache_root is not None:
            candidates = _cached_candidates(cache_root, str(contract["filename"]))
            cached = candidates[0] if candidates else None
        actual_sha: str | None = None
        if cached is not None:
            target.parent.mkdir(parents=True, mode=0o700)
            actual_sha = _copy_verified(cached, target, str(contract["sha256"]))
        result: dict[str, object] = {
            "version": VERSION,
            "source": "cache" if cached is not None else "download",
            "distributionUrl": contract["url"],
            "distributionSha256": contract["sha256"],
            "distributionKey": contract["distributionKey"],
            "cachedZip": str(cached) if cached is not None else None,
            "copiedSha256": actual_sha,
            "gradleUserHome": str(destination),
            "destinationZip": str(target),
            "gradleUserHomeMode": "0700",
        }
        _write_evidence(evidence, result)
        return result
    except Exception:
        shutil.rmtree(destination)
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--wrapper-properties", type=pathlib.Path, required=True)
    parser.add_argument("--destination", type=pathlib.Path, required=True)
    parser.add_argument("--evidence", type=pathlib.Path, required=True)
    parser.add_argument("--cache-root", type=pathlib.Path)
    args = parser.parse_args()
    prepare(
        wrapper_properties=args.wrapper_properties,
        destination=args.destination,
        evidence=args.evidence,
        cache_root=args.cache_root,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
