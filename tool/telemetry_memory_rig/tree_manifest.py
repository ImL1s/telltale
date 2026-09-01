#!/usr/bin/env python3
"""Write and verify the Android rig's source and toolchain input manifest."""

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
import dataclasses
from collections.abc import Callable


INCLUDED_DIRECTORIES = (
    ".dart_tool/lib",
    "lib",
    "integration_test",
    "test",
    "assets",
    "tool/telemetry_memory_rig",
    "android/app/src",
    "android/gradle/wrapper",
)
INCLUDED_FILES = (
    ".flutter-plugins-dependencies",
    ".dart_tool/package_config.json",
    ".dart_tool/package_graph.json",
    ".dart_tool/native_assets.yaml",
    ".metadata",
    "analysis_options.yaml",
    "pubspec.yaml",
    "pubspec.lock",
    "android/app/build.gradle.kts",
    "android/build.gradle.kts",
    "android/gradle.properties",
    "android/gradle/verification-metadata.xml",
    "android/local.properties",
    "android/gradlew",
    "android/gradlew.bat",
    "android/settings.gradle.kts",
)
LOCAL_IGNORED_PARTS = {"__pycache__"}
IGNORED_SUFFIXES = {".pyc", ".pyo"}
EXCLUDED_DOCUMENTATION = {
    "tool/telemetry_memory_rig/GATE_C_BLOCKERS.md",
    "tool/telemetry_memory_rig/README.md",
}
EXTERNAL_IGNORED_PARTS = {
    ".cxx",
    ".dart_tool",
    ".git",
    ".gradle",
    ".idea",
    ".kotlin",
    "__pycache__",
    "_out",
    "benchmark",
    "benchmarks",
    "build",
    "coverage",
    "doc",
    "docs",
    "example",
    "examples",
    "out",
    "test",
    "tests",
}
EXTERNAL_IGNORED_SEGMENT_SEQUENCES: tuple[tuple[str, ...], ...] = ()
TOOLCHAIN_DIRECTORIES = (
    "bin/internal",
    "packages/flutter_tools",
    "bin/cache/dart-sdk/lib",
    "bin/cache/dart-sdk/bin/snapshots",
    "bin/cache/artifacts/engine/common",
    "bin/cache/artifacts/engine/android-arm",
    "bin/cache/artifacts/engine/android-arm64",
    "bin/cache/artifacts/engine/android-x64",
    "bin/cache/artifacts/engine/android-x86",
    "bin/cache/artifacts/engine/darwin-x64/shader_lib",
    "bin/cache/artifacts/material_fonts",
)
TOOLCHAIN_FILES = (
    "bin/flutter",
    "bin/dart",
    "bin/internal/engine.version",
    "bin/cache/engine.stamp",
    "bin/cache/engine.realm",
    "bin/cache/flutter.version.json",
    "bin/cache/flutter_tools.snapshot",
    "bin/cache/flutter_tools.stamp",
    "packages/flutter_tools/.dart_tool/package_config.json",
    "bin/cache/dart-sdk/bin/dart",
    "bin/cache/dart-sdk/bin/dartaotruntime",
    "bin/cache/dart-sdk/version",
    "bin/cache/artifacts/engine/darwin-x64/const_finder.dart.snapshot",
    "bin/cache/artifacts/engine/darwin-x64/flutter_tester",
    "bin/cache/artifacts/engine/darwin-x64/font-subset",
    "bin/cache/artifacts/engine/darwin-x64/frontend_server_aot.dart.snapshot",
    "bin/cache/artifacts/engine/darwin-x64/gen_snapshot_arm64",
    "bin/cache/artifacts/engine/darwin-x64/gen_snapshot_x64",
    "bin/cache/artifacts/engine/darwin-x64/icudtl.dat",
    "bin/cache/artifacts/engine/darwin-x64/impellerc",
    "bin/cache/artifacts/engine/darwin-x64/isolate_snapshot.bin",
    "bin/cache/artifacts/engine/darwin-x64/libpath_ops.dylib",
    "bin/cache/artifacts/engine/darwin-x64/libtessellator.dylib",
    "bin/cache/artifacts/engine/darwin-x64/vm_isolate_snapshot.bin",
)
LINE = re.compile(r"^([0-9a-f]{64})  (.+)$")
PACKAGE_NAME = re.compile(r"^[a-z_][a-z0-9_]*$")
SHA256_TEXT = re.compile(r"^[0-9a-f]{64}$")
MAX_EVIDENCE_BYTES = 32 * 1024 * 1024


@dataclasses.dataclass(frozen=True)
class ManifestPathBinding:
    """Bind one canonical manifest identity to its absolute source file."""

    logical_id: str
    path: pathlib.Path
    namespace: str


def _has_control_characters(value: str) -> bool:
    return any(ord(character) < 32 or ord(character) == 127 for character in value)


def _file_identity(value: os.stat_result) -> tuple[int, int, int, int, int, int, int]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def _is_within(path: pathlib.Path, parent: pathlib.Path) -> bool:
    return path == parent or parent in path.parents


def _has_symlink_component(path: pathlib.Path) -> bool:
    absolute = pathlib.Path(os.path.abspath(path))
    current = pathlib.Path(absolute.anchor)
    for part in absolute.parts[1:]:
        current /= part
        if current.is_symlink():
            return True
    return False


def _safe_directory(path: pathlib.Path, label: str) -> pathlib.Path:
    if _has_control_characters(str(path)) or _has_symlink_component(path):
        raise ValueError(f"unsafe or symlinked {label}: {path}")
    resolved = path.resolve(strict=True)
    if not resolved.is_dir():
        raise ValueError(f"{label} is not a directory: {path}")
    return resolved


def _confined_path_without_symlinks(
    path: pathlib.Path,
    *,
    boundary: pathlib.Path,
    label: str,
) -> pathlib.Path:
    """Return a lexical path only when every existing component is confined."""
    canonical_boundary = boundary.resolve(strict=True)
    candidate = pathlib.Path(os.path.abspath(path))
    if not _is_within(candidate, canonical_boundary):
        raise ValueError(f"{label} escapes its declared root: {path}")

    current = canonical_boundary
    for part in candidate.relative_to(canonical_boundary).parts:
        current /= part
        try:
            mode = current.lstat().st_mode
        except FileNotFoundError:
            break
        if stat.S_ISLNK(mode):
            if current == candidate:
                raise ValueError(f"symlink {label} is not allowed: {current}")
            raise ValueError(f"symlink ancestor in {label} is not allowed: {current}")

    resolved = candidate.resolve(strict=False)
    if not _is_within(resolved, canonical_boundary):
        raise ValueError(f"{label} resolves outside its declared root: {path}")
    return candidate


def _read_local_properties(root: pathlib.Path) -> dict[str, str]:
    properties: dict[str, str] = {}
    path = root / "android/local.properties"
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith(("#", "!")):
            continue
        if "=" not in line:
            raise ValueError(f"unsupported local.properties line {number}")
        key, value = (part.strip() for part in line.split("=", 1))
        if not key or not value or key in properties or _has_control_characters(value):
            raise ValueError(f"invalid local.properties line {number}")
        properties[key] = value
    return properties


def flutter_sdk_root(root: pathlib.Path) -> pathlib.Path:
    value = _read_local_properties(root).get("flutter.sdk")
    if value is None:
        raise ValueError("flutter.sdk is missing from android/local.properties")
    candidate = pathlib.Path(value)
    if not candidate.is_absolute():
        raise ValueError("flutter.sdk must be an absolute canonical path")
    return _safe_directory(candidate, "Flutter SDK root")


def android_sdk_root(root: pathlib.Path) -> pathlib.Path:
    value = _read_local_properties(root).get("sdk.dir")
    if value is None:
        raise ValueError("sdk.dir is missing from android/local.properties")
    candidate = pathlib.Path(value)
    if not candidate.is_absolute():
        raise ValueError("sdk.dir must be an absolute canonical path")
    return _safe_directory(candidate, "Android SDK root")


def pub_cache_root() -> pathlib.Path:
    candidate = pathlib.Path(
        os.environ.get("PUB_CACHE", pathlib.Path.home() / ".pub-cache")
    )
    if not candidate.is_absolute():
        raise ValueError("PUB_CACHE must be absolute")
    return _safe_directory(candidate, "Dart pub cache root")


def _is_local_ignored(relative: pathlib.PurePosixPath) -> bool:
    return (
        bool(LOCAL_IGNORED_PARTS.intersection(relative.parts))
        or relative.as_posix() in EXCLUDED_DOCUMENTATION
        or any(relative.name.endswith(suffix) for suffix in IGNORED_SUFFIXES)
    )


def external_ignored_reason(relative: pathlib.PurePosixPath) -> str | None:
    parts = relative.parts
    if EXTERNAL_IGNORED_PARTS.intersection(parts) or any(
        parts[index : index + len(sequence)] == sequence
        for sequence in EXTERNAL_IGNORED_SEGMENT_SEQUENCES
        for index in range(len(parts) - len(sequence) + 1)
    ):
        return "generated-package-directory"
    if any(relative.name.endswith(suffix) for suffix in IGNORED_SUFFIXES):
        return "generated-package-suffix"
    return None


def _is_external_ignored(relative: pathlib.PurePosixPath) -> bool:
    return external_ignored_reason(relative) is not None


def _package_root(config: pathlib.Path, root_uri: str) -> pathlib.Path:
    if _has_control_characters(root_uri):
        raise ValueError("package root URI contains control characters")
    parsed = urllib.parse.urlparse(root_uri)
    if parsed.query or parsed.fragment or parsed.params:
        raise ValueError(f"non-canonical package root URI: {root_uri}")
    if parsed.scheme == "file":
        if parsed.netloc not in {"", "localhost"}:
            raise ValueError(f"unsupported package root URI: {root_uri}")
        candidate = pathlib.Path(urllib.parse.unquote(parsed.path))
        if not candidate.is_absolute():
            raise ValueError(f"file package root URI is not absolute: {root_uri}")
    elif parsed.scheme == "":
        if parsed.netloc:
            raise ValueError(f"unsupported package root URI: {root_uri}")
        candidate = config.parent / urllib.parse.unquote(parsed.path)
    else:
        raise ValueError(f"unsupported package root URI: {root_uri}")
    return _safe_directory(candidate, "package root")


def _collect_package_roots(
    config: pathlib.Path,
    *,
    approved_roots: tuple[pathlib.Path, ...],
    excluded_roots: tuple[pathlib.Path, ...] = (),
) -> list[tuple[str, pathlib.Path]]:
    value = json.loads(config.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("unsupported Dart package config schema")
    packages = value.get("packages")
    if value.get("configVersion") != 2 or not isinstance(packages, list):
        raise ValueError("unsupported Dart package config schema")
    selected: list[tuple[str, pathlib.Path]] = []
    seen_names: set[str] = set()
    for package in packages:
        if not isinstance(package, dict):
            raise ValueError("invalid Dart package config entry")
        name = package.get("name")
        root_uri = package.get("rootUri")
        if (
            not isinstance(name, str)
            or PACKAGE_NAME.fullmatch(name) is None
            or name in seen_names
            or not isinstance(root_uri, str)
        ):
            raise ValueError("invalid or duplicate Dart package config identity")
        seen_names.add(name)
        package_root = _package_root(config, root_uri)
        if not any(_is_within(package_root, approved) for approved in approved_roots):
            raise ValueError(f"unapproved external package root: {name}")
        if package_root not in excluded_roots:
            selected.append((name, package_root))
    return sorted(selected, key=lambda item: item[0])


def collect_external_roots(
    root: pathlib.Path,
    *,
    flutter_root: pathlib.Path | None = None,
) -> list[tuple[str, pathlib.Path]]:
    root = root.resolve(strict=True)
    config = root / ".dart_tool/package_config.json"
    flutter_root = flutter_root or flutter_sdk_root(root)
    return _collect_package_roots(
        config,
        approved_roots=(root, flutter_root, pub_cache_root()),
        excluded_roots=(root,),
    )


def clean_external_native_build_caches(
    root: pathlib.Path,
    evidence: pathlib.Path,
    *,
    expected_flutter_root: pathlib.Path | None = None,
) -> None:
    """Remove pre-existing package-local .cxx state before a sealed build."""

    def fail_walk(error: OSError) -> None:
        raise ValueError(
            f"could not enumerate external native cache: {error.filename}"
        ) from error

    root = root.resolve(strict=True)
    flutter_root = bound_flutter_root(root, expected_flutter_root)
    package_roots = {
        package_root
        for _, package_root in (
            *collect_external_roots(root, flutter_root=flutter_root),
            *collect_flutter_tool_roots(root, flutter_root=flutter_root),
        )
    }
    removed: list[dict[str, object]] = []
    for package_root in sorted(package_roots, key=lambda path: str(path)):
        package_metadata = os.lstat(package_root)
        if (
            not stat.S_ISDIR(package_metadata.st_mode)
            or stat.S_ISLNK(package_metadata.st_mode)
            or package_metadata.st_uid != os.getuid()
            or package_metadata.st_mode & 0o022
        ):
            raise ValueError(f"unsafe external package root: {package_root}")
        caches = _discover_external_native_caches(package_root)
        for cache in caches:
            file_count = 0
            byte_count = 0
            for directory_text, directories, files in os.walk(
                cache,
                topdown=True,
                followlinks=False,
                onerror=fail_walk,
            ):
                directory = pathlib.Path(directory_text)
                for name in directories:
                    path = directory / name
                    metadata = os.lstat(path)
                    if (
                        stat.S_ISLNK(metadata.st_mode)
                        or not stat.S_ISDIR(metadata.st_mode)
                        or metadata.st_uid != os.getuid()
                    ):
                        raise ValueError(
                            f"unsafe external native cache directory: {path}"
                        )
                for name in files:
                    path = directory / name
                    metadata = os.lstat(path)
                    if (
                        stat.S_ISLNK(metadata.st_mode)
                        or not stat.S_ISREG(metadata.st_mode)
                        or metadata.st_uid != os.getuid()
                    ):
                        raise ValueError(f"unsafe external native cache file: {path}")
                    file_count += 1
                    byte_count += metadata.st_size
            if not shutil.rmtree.avoids_symlink_attacks:
                raise ValueError(
                    "platform does not support symlink-safe native cache cleanup"
                )
            shutil.rmtree(cache)
            if cache.exists() or cache.is_symlink():
                raise ValueError(
                    f"external native build cache survived cleanup: {cache}"
                )
            removed.append(
                {
                    "bytes": byte_count,
                    "files": file_count,
                    "path": str(cache),
                }
            )
        if _discover_external_native_caches(package_root):
            raise ValueError(
                f"external native build cache survived scan: {package_root}"
            )

    output = _confined_path_without_symlinks(
        evidence,
        boundary=root,
        label="native cache cleanup evidence",
    )
    if output.exists() or output.is_symlink():
        raise ValueError(f"stale native cache cleanup evidence: {output}")
    parent = _safe_directory(output.parent, "native cache cleanup evidence parent")
    parent_metadata = os.lstat(parent)
    if parent_metadata.st_uid != os.getuid() or parent_metadata.st_mode & 0o077:
        raise ValueError(f"unsafe native cache cleanup evidence parent: {parent}")
    payload = (
        json.dumps(
            {
                "packageRoots": [
                    str(path)
                    for path in sorted(package_roots, key=lambda path: str(path))
                ],
                "packageRootsChecked": len(package_roots),
                "removed": removed,
                "version": 1,
            },
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    )
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(output, flags, 0o600)
    try:
        os.write(descriptor, payload.encode("utf-8"))
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def clean_flutter_gradle_generated_state(
    root: pathlib.Path,
    evidence: pathlib.Path,
    *,
    expected_flutter_root: pathlib.Path | None = None,
) -> None:
    """Remove generated Flutter Gradle plugin state before a sealed build."""

    def fail_walk(error: OSError) -> None:
        raise ValueError(
            f"could not enumerate Flutter Gradle generated state: {error.filename}"
        ) from error

    if not shutil.rmtree.avoids_symlink_attacks:
        raise ValueError(
            "platform does not support symlink-safe Flutter Gradle generated "
            "state cleanup"
        )

    root = root.resolve(strict=True)
    flutter_root = bound_flutter_root(root, expected_flutter_root)
    gradle_root = _safe_directory(
        flutter_root / "packages/flutter_tools/gradle",
        "Flutter Gradle plugin root",
    )
    gradle_metadata = os.lstat(gradle_root)
    if (
        gradle_metadata.st_uid != os.getuid()
        or gradle_metadata.st_mode & 0o022
        or gradle_metadata.st_mode & stat.S_IRUSR == 0
        or gradle_metadata.st_mode & stat.S_IWUSR == 0
        or gradle_metadata.st_mode & stat.S_IXUSR == 0
    ):
        raise ValueError(f"unsafe Flutter Gradle plugin root: {gradle_root}")

    output = _confined_path_without_symlinks(
        evidence,
        boundary=root,
        label="Flutter Gradle generated cleanup evidence",
    )
    if output.exists() or output.is_symlink():
        raise ValueError(f"stale Flutter Gradle generated cleanup evidence: {output}")
    parent = _safe_directory(
        output.parent,
        "Flutter Gradle generated cleanup evidence parent",
    )
    parent_metadata = os.lstat(parent)
    if (
        parent_metadata.st_uid != os.getuid()
        or stat.S_IMODE(parent_metadata.st_mode) != 0o700
    ):
        raise ValueError(
            f"unsafe Flutter Gradle generated cleanup evidence parent: {parent}"
        )

    checked = [
        gradle_root / name
        for name in (
            ".gradle",
            "build",
            ".kotlin",
        )
    ]
    removed: list[dict[str, object]] = []
    for candidate in checked:
        generated = _confined_path_without_symlinks(
            candidate,
            boundary=gradle_root,
            label="Flutter Gradle generated directory",
        )
        try:
            root_metadata = os.lstat(generated)
        except FileNotFoundError:
            continue
        if (
            stat.S_ISLNK(root_metadata.st_mode)
            or not stat.S_ISDIR(root_metadata.st_mode)
            or root_metadata.st_uid != os.getuid()
            or root_metadata.st_mode & 0o022
            or root_metadata.st_mode & stat.S_IRUSR == 0
            or root_metadata.st_mode & stat.S_IWUSR == 0
            or root_metadata.st_mode & stat.S_IXUSR == 0
        ):
            raise ValueError(f"unsafe Flutter Gradle generated directory: {generated}")

        file_count = 0
        byte_count = 0
        for directory_text, directories, files in os.walk(
            generated,
            topdown=True,
            followlinks=False,
            onerror=fail_walk,
        ):
            directory = pathlib.Path(directory_text)
            directory_metadata = os.lstat(directory)
            if (
                stat.S_ISLNK(directory_metadata.st_mode)
                or not stat.S_ISDIR(directory_metadata.st_mode)
                or directory_metadata.st_uid != os.getuid()
                or directory_metadata.st_mode & 0o022
                or directory_metadata.st_mode & stat.S_IRUSR == 0
                or directory_metadata.st_mode & stat.S_IWUSR == 0
                or directory_metadata.st_mode & stat.S_IXUSR == 0
            ):
                raise ValueError(
                    f"unsafe Flutter Gradle generated directory: {directory}"
                )
            if not _is_within(directory, generated):
                raise ValueError(
                    f"Flutter Gradle generated directory escapes its root: {directory}"
                )
            for name in directories:
                path = directory / name
                metadata = os.lstat(path)
                if (
                    stat.S_ISLNK(metadata.st_mode)
                    or not stat.S_ISDIR(metadata.st_mode)
                    or metadata.st_uid != os.getuid()
                    or metadata.st_mode & 0o022
                    or metadata.st_mode & stat.S_IRUSR == 0
                    or metadata.st_mode & stat.S_IWUSR == 0
                    or metadata.st_mode & stat.S_IXUSR == 0
                ):
                    raise ValueError(
                        f"unsafe Flutter Gradle generated directory: {path}"
                    )
            for name in files:
                path = directory / name
                metadata = os.lstat(path)
                if (
                    stat.S_ISLNK(metadata.st_mode)
                    or not stat.S_ISREG(metadata.st_mode)
                    or metadata.st_uid != os.getuid()
                    or metadata.st_mode & 0o022
                    or metadata.st_mode & stat.S_IRUSR == 0
                ):
                    raise ValueError(f"unsafe Flutter Gradle generated file: {path}")
                file_count += 1
                byte_count += metadata.st_size

        current_metadata = os.lstat(generated)
        if _file_identity(root_metadata) != _file_identity(current_metadata):
            raise ValueError(
                "Flutter Gradle generated directory changed while enumerating: "
                f"{generated}"
            )
        shutil.rmtree(generated)
        if generated.exists() or generated.is_symlink():
            raise ValueError(
                f"Flutter Gradle generated state survived cleanup: {generated}"
            )
        removed.append(
            {
                "bytes": byte_count,
                "files": file_count,
                "path": str(generated),
            }
        )

    payload = (
        json.dumps(
            {
                "checked": [str(path) for path in checked],
                "removed": removed,
                "version": 1,
            },
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    )
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(output, flags, 0o600)
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) != 0o600
        ):
            raise ValueError(
                f"unsafe Flutter Gradle generated cleanup evidence: {output}"
            )
        os.write(descriptor, payload.encode("utf-8"))
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _read_json_regular_file(path: pathlib.Path, label: str) -> tuple[object, str]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_uid != os.getuid()
            or before.st_size > MAX_EVIDENCE_BYTES
        ):
            raise ValueError(f"unsafe {label}: {path}")
        data = bytearray()
        digest = hashlib.sha256()
        while chunk := os.read(descriptor, 1024 * 1024):
            data.extend(chunk)
            digest.update(chunk)
            if len(data) > MAX_EVIDENCE_BYTES:
                raise ValueError(f"oversized {label}: {path}")
        after = os.fstat(descriptor)
        current = os.stat(path, follow_symlinks=False)
        if _file_identity(before) != _file_identity(after) or _file_identity(
            after
        ) != _file_identity(current):
            raise ValueError(f"{label} changed while reading: {path}")
        try:
            return json.loads(data), digest.hexdigest()
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ValueError(f"invalid {label}: {path}") from error
    finally:
        os.close(descriptor)


def _canonical_string_paths(value: object, label: str) -> list[pathlib.Path]:
    if not isinstance(value, list) or not value:
        raise ValueError(f"{label} must be a non-empty list")
    paths: list[pathlib.Path] = []
    for raw in value:
        if not isinstance(raw, str) or not raw or _has_control_characters(raw):
            raise ValueError(f"invalid {label} path")
        path = pathlib.Path(raw)
        if not path.is_absolute() or pathlib.Path(os.path.abspath(path)) != path:
            raise ValueError(f"non-canonical {label} path: {raw}")
        paths.append(path)
    if paths != sorted(set(paths), key=str):
        raise ValueError(f"duplicate or unsorted {label}")
    return paths


def verify_native_cache_freshness(
    root: pathlib.Path,
    cleanup_evidence: pathlib.Path,
    generated_cleanup_evidence: pathlib.Path,
    discovery_evidence: pathlib.Path,
    output: pathlib.Path,
    *,
    expected_flutter_root: pathlib.Path | None = None,
) -> None:
    """Bind fresh CXX model caches to the pre-build cleanup scope."""

    root = root.resolve(strict=True)
    flutter_root = bound_flutter_root(root, expected_flutter_root)

    expected_package_roots = sorted(
        {
            package_root
            for _, package_root in (
                *collect_external_roots(root, flutter_root=flutter_root),
                *collect_flutter_tool_roots(root, flutter_root=flutter_root),
            )
        },
        key=str,
    )
    cleanup_path = _confined_path_without_symlinks(
        cleanup_evidence,
        boundary=root,
        label="external native cache cleanup evidence",
    )
    cleanup, cleanup_sha = _read_json_regular_file(
        cleanup_path,
        "external native cache cleanup evidence",
    )
    if not isinstance(cleanup, dict) or set(cleanup) != {
        "packageRoots",
        "packageRootsChecked",
        "removed",
        "version",
    }:
        raise ValueError("unexpected external native cache cleanup evidence schema")
    package_roots = _canonical_string_paths(
        cleanup.get("packageRoots"),
        "external native cache package roots",
    )
    if (
        type(cleanup.get("version")) is not int
        or cleanup.get("version") != 1
        or type(cleanup.get("packageRootsChecked")) is not int
        or cleanup.get("packageRootsChecked") != len(package_roots)
        or package_roots != expected_package_roots
    ):
        raise ValueError("external native cache cleanup package roots are incomplete")
    for package_root in package_roots:
        if (
            _safe_directory(package_root, "external native cache package root")
            != package_root
        ):
            raise ValueError(f"non-canonical external package root: {package_root}")

    removed = cleanup.get("removed")
    if not isinstance(removed, list):
        raise ValueError("invalid external native cache removal records")
    removed_paths: list[pathlib.Path] = []
    for record in removed:
        if (
            not isinstance(record, dict)
            or set(record) != {"bytes", "files", "path"}
            or type(record.get("bytes")) is not int
            or record["bytes"] < 0
            or type(record.get("files")) is not int
            or record["files"] < 0
            or not isinstance(record.get("path"), str)
        ):
            raise ValueError("invalid external native cache removal record")
        cache = pathlib.Path(record["path"])
        if (
            not cache.is_absolute()
            or pathlib.Path(os.path.abspath(cache)) != cache
            or cache.name != ".cxx"
            or not any(
                cache.is_relative_to(package_root) for package_root in package_roots
            )
        ):
            raise ValueError(f"unscoped external native cache removal: {cache}")
        removed_paths.append(cache)
    if removed_paths != sorted(set(removed_paths), key=str):
        raise ValueError("duplicate or unsorted external native cache removals")

    generated_path = _confined_path_without_symlinks(
        generated_cleanup_evidence,
        boundary=root,
        label="generated input cleanup evidence",
    )
    generated, generated_sha = _read_json_regular_file(
        generated_path,
        "generated input cleanup evidence",
    )
    expected_generated_scopes = [
        "build",
        "android/.gradle",
        ".dart_tool/flutter_build",
        ".dart_tool/hooks_runner",
        ".dart_tool/test",
    ]
    if (
        not isinstance(generated, dict)
        or set(generated) != {"checked", "removed", "version"}
        or type(generated.get("version")) is not int
        or generated.get("version") != 1
        or generated.get("checked") != expected_generated_scopes
        or not isinstance(generated.get("removed"), list)
        or any(value not in expected_generated_scopes for value in generated["removed"])
        or len(generated["removed"]) != len(set(generated["removed"]))
    ):
        raise ValueError("generated input cleanup evidence is incomplete")

    discovery_path = _confined_path_without_symlinks(
        discovery_evidence,
        boundary=root,
        label="Android toolchain discovery evidence",
    )
    discovery, discovery_sha = _read_json_regular_file(
        discovery_path,
        "Android toolchain discovery evidence",
    )
    if (
        not isinstance(discovery, dict)
        or type(discovery.get("version")) is not int
        or discovery.get("version") != 1
    ):
        raise ValueError("invalid Android toolchain discovery evidence")
    native_cache_roots = _canonical_string_paths(
        discovery.get("nativeCacheRoots"),
        "native cache roots",
    )
    local_cache_root = root / "build/.cxx"
    local_count = 0
    external_count = 0
    for cache in native_cache_roots:
        canonical = _safe_directory(cache, "fresh native cache root")
        metadata = os.stat(canonical, follow_symlinks=False)
        if (
            canonical != cache
            or cache.name != ".cxx"
            or metadata.st_uid != os.getuid()
            or metadata.st_mode & 0o022
        ):
            raise ValueError(f"unsafe fresh native cache root: {cache}")
        if cache == local_cache_root:
            local_count += 1
        elif any(cache.is_relative_to(package_root) for package_root in package_roots):
            external_count += 1
        else:
            raise ValueError(f"unscoped fresh native cache root: {cache}")

    approved_source_paths = {
        *collect_paths(root),
        *(path for _, path in collect_external_paths(root, flutter_root=flutter_root)),
        *(path for _, path in collect_toolchain_paths(root, flutter_root=flutter_root)),
        *(
            path
            for _, path in collect_flutter_tool_paths(root, flutter_root=flutter_root)
        ),
    }
    native_source_paths = _canonical_string_paths(
        discovery.get("nativeModelSourcePaths"),
        "native model source paths",
    )
    for source in native_source_paths:
        boundaries = [
            candidate
            for candidate in (root, flutter_root, *package_roots)
            if source.is_relative_to(candidate)
        ]
        if not boundaries:
            raise ValueError(f"CXX model source is outside every sealed root: {source}")
        canonical = _confined_path_without_symlinks(
            source,
            boundary=max(boundaries, key=lambda candidate: len(candidate.parts)),
            label="native model source",
        )
        if canonical != source or source not in approved_source_paths:
            raise ValueError(
                f"CXX model source is not sealed by the tree manifest: {source}"
            )

    model_paths = discovery.get("discoveryModels")
    model_sha = discovery.get("discoveryModelSha256")
    if (
        not isinstance(model_paths, list)
        or not model_paths
        or len(model_paths) != len(set(model_paths))
        or not isinstance(model_sha, dict)
        or set(model_sha) != set(model_paths)
        or any(
            not isinstance(digest, str) or SHA256_TEXT.fullmatch(digest) is None
            for digest in model_sha.values()
        )
    ):
        raise ValueError("Android discovery model digest coverage is incomplete")
    if local_count + external_count != len(native_cache_roots):
        raise ValueError("fresh Android discovery native cache scope is incomplete")
    for raw in model_paths:
        if not isinstance(raw, str):
            raise ValueError("invalid Android discovery model path")
        model = _confined_path_without_symlinks(
            pathlib.Path(raw),
            boundary=root / "build",
            label="Android discovery model",
        )
        if not model.is_file() or _sha256(model) != model_sha[raw]:
            raise ValueError(f"Android discovery model changed after parsing: {model}")

    output_path = _confined_path_without_symlinks(
        output,
        boundary=root,
        label="native cache freshness validation evidence",
    )
    if output_path.exists() or output_path.is_symlink():
        raise ValueError(f"stale native cache freshness evidence: {output_path}")
    parent = _safe_directory(
        output_path.parent, "native cache freshness evidence parent"
    )
    parent_metadata = os.lstat(parent)
    if parent_metadata.st_uid != os.getuid() or parent_metadata.st_mode & 0o077:
        raise ValueError(f"unsafe native cache freshness evidence parent: {parent}")
    payload = (
        json.dumps(
            {
                "cleanupEvidenceSha256": cleanup_sha,
                "discoveryEvidenceSha256": discovery_sha,
                "externalNativeCacheRoots": external_count,
                "generatedCleanupEvidenceSha256": generated_sha,
                "localNativeCacheRoots": local_count,
                "nativeCacheRoots": [str(path) for path in native_cache_roots],
                "nativeModelSourcePaths": [str(path) for path in native_source_paths],
                "result": "pass",
                "version": 1,
            },
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    )
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(output_path, flags, 0o600)
    try:
        os.write(descriptor, payload.encode("utf-8"))
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _discover_external_native_caches(
    package_root: pathlib.Path,
) -> list[pathlib.Path]:
    caches: list[pathlib.Path] = []

    def fail_walk(error: OSError) -> None:
        raise ValueError(
            f"could not enumerate external package directory: {error.filename}"
        ) from error

    for directory_text, directories, _ in os.walk(
        package_root,
        topdown=True,
        followlinks=False,
        onerror=fail_walk,
    ):
        directory = pathlib.Path(directory_text)
        directory_metadata = os.lstat(directory)
        if (
            stat.S_ISLNK(directory_metadata.st_mode)
            or not stat.S_ISDIR(directory_metadata.st_mode)
            or directory_metadata.st_uid != os.getuid()
            or directory_metadata.st_mode & stat.S_IRUSR == 0
            or directory_metadata.st_mode & stat.S_IXUSR == 0
        ):
            raise ValueError(f"unsafe external package directory: {directory}")
        traversable: list[str] = []
        for name in directories:
            path = directory / name
            metadata = os.lstat(path)
            if name == ".cxx":
                if stat.S_ISLNK(metadata.st_mode):
                    raise ValueError(f"symlink external native build cache: {path}")
                if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid():
                    raise ValueError(f"unsafe external native build cache: {path}")
                caches.append(
                    _confined_path_without_symlinks(
                        path,
                        boundary=package_root,
                        label="external native build cache",
                    )
                )
            elif not stat.S_ISLNK(metadata.st_mode):
                if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid():
                    raise ValueError(f"unsafe external package directory: {path}")
                traversable.append(name)
        directories[:] = traversable
    return sorted(caches, key=lambda path: str(path))


def collect_flutter_tool_roots(
    root: pathlib.Path,
    *,
    flutter_root: pathlib.Path | None = None,
) -> list[tuple[str, pathlib.Path]]:
    root = root.resolve(strict=True)
    flutter_root = flutter_root or flutter_sdk_root(root)
    config = flutter_root / "packages/flutter_tools/.dart_tool/package_config.json"
    return _collect_package_roots(
        config,
        approved_roots=(root, flutter_root, pub_cache_root()),
    )


def _collect_tree(
    base: pathlib.Path,
    *,
    boundary: pathlib.Path,
    ignored: Callable[[pathlib.PurePosixPath], bool],
    label: str,
) -> list[pathlib.Path]:
    selected: list[pathlib.Path] = []

    def fail_walk(error: OSError) -> None:
        raise ValueError(f"could not enumerate {label}: {error.filename}") from error

    for directory_text, directories, files in os.walk(
        base,
        topdown=True,
        followlinks=False,
        onerror=fail_walk,
    ):
        directory = _confined_path_without_symlinks(
            pathlib.Path(directory_text),
            boundary=boundary,
            label=label,
        )
        before = os.stat(directory, follow_symlinks=False)
        if (
            not stat.S_ISDIR(before.st_mode)
            or before.st_mode & stat.S_IRUSR == 0
            or before.st_mode & stat.S_IXUSR == 0
        ):
            raise ValueError(f"unsafe or unenumerable {label}: {directory}")

        traversable: list[str] = []
        for name in directories:
            path = directory / name
            relative = pathlib.PurePosixPath(path.relative_to(base).as_posix())
            if ignored(relative):
                continue
            path = _confined_path_without_symlinks(
                path,
                boundary=boundary,
                label=label,
            )
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
                raise ValueError(
                    f"symlink or special {label} is not allowed: {relative}"
                )
            traversable.append(name)
        directories[:] = traversable

        for name in files:
            path = directory / name
            relative = pathlib.PurePosixPath(path.relative_to(base).as_posix())
            if ignored(relative):
                continue
            path = _confined_path_without_symlinks(
                path,
                boundary=boundary,
                label=label,
            )
            mode = path.lstat().st_mode
            if stat.S_ISREG(mode):
                selected.append(path)
                continue
            if stat.S_ISLNK(mode):
                raise ValueError(f"symlink {label} is not allowed: {relative}")
            raise ValueError(f"special file {label} is not allowed: {relative}")

        after = os.stat(directory, follow_symlinks=False)
        if (
            before.st_dev,
            before.st_ino,
            before.st_mode,
            before.st_mtime_ns,
            before.st_ctime_ns,
        ) != (
            after.st_dev,
            after.st_ino,
            after.st_mode,
            after.st_mtime_ns,
            after.st_ctime_ns,
        ):
            raise ValueError(f"{label} changed while enumerating: {directory}")
    return selected


def collect_external_paths(
    root: pathlib.Path,
    *,
    flutter_root: pathlib.Path | None = None,
) -> list[tuple[str, pathlib.Path]]:
    selected: list[tuple[str, pathlib.Path]] = []
    for name, package_root in collect_external_roots(
        root,
        flutter_root=flutter_root,
    ):
        for path in _collect_tree(
            package_root,
            boundary=package_root,
            ignored=_is_external_ignored,
            label=f"package input {name}",
        ):
            relative = pathlib.PurePosixPath(path.relative_to(package_root).as_posix())
            selected.append((f"@package/{name}/{relative}", path))
    return sorted(selected, key=lambda item: item[0])


def collect_flutter_tool_paths(
    root: pathlib.Path,
    *,
    flutter_root: pathlib.Path | None = None,
) -> list[tuple[str, pathlib.Path]]:
    selected: list[tuple[str, pathlib.Path]] = []
    for name, package_root in collect_flutter_tool_roots(
        root,
        flutter_root=flutter_root,
    ):
        for path in _collect_tree(
            package_root,
            boundary=package_root,
            ignored=_is_external_ignored,
            label=f"Flutter tool package input {name}",
        ):
            relative = pathlib.PurePosixPath(path.relative_to(package_root).as_posix())
            selected.append((f"@flutter-tool-package/{name}/{relative}", path))
    return sorted(selected, key=lambda item: item[0])


def collect_toolchain_paths(
    root: pathlib.Path,
    *,
    flutter_root: pathlib.Path | None = None,
) -> list[tuple[str, pathlib.Path]]:
    root = root.resolve(strict=True)
    flutter_root = flutter_root or flutter_sdk_root(root)
    selected: list[tuple[str, pathlib.Path]] = []
    for relative_text in TOOLCHAIN_FILES:
        path = _confined_path_without_symlinks(
            flutter_root / relative_text,
            boundary=flutter_root,
            label=f"Flutter toolchain input {relative_text}",
        )
        if not path.is_file():
            raise ValueError(
                f"missing or unsafe Flutter toolchain input: {relative_text}"
            )
        selected.append((f"@toolchain/flutter/{relative_text}", path))
    for relative_text in TOOLCHAIN_DIRECTORIES:
        directory = _safe_directory(
            flutter_root / relative_text,
            f"Flutter toolchain input directory {relative_text}",
        )
        for path in _collect_tree(
            directory,
            boundary=flutter_root,
            ignored=_is_external_ignored,
            label=f"Flutter toolchain input {relative_text}",
        ):
            relative = path.relative_to(flutter_root).as_posix()
            selected.append((f"@toolchain/flutter/{relative}", path))
    return sorted(set(selected), key=lambda item: item[0])


def collect_paths(root: pathlib.Path) -> list[pathlib.Path]:
    root = root.resolve(strict=True)
    _validate_native_assets(root)
    selected: set[pathlib.Path] = set()
    for relative_text in INCLUDED_FILES:
        path = _confined_path_without_symlinks(
            root / relative_text,
            boundary=root,
            label=f"build input {relative_text}",
        )
        if not path.is_file():
            raise ValueError(f"missing or unsafe build input: {relative_text}")
        selected.add(path)
    for relative_text in INCLUDED_DIRECTORIES:
        directory = _confined_path_without_symlinks(
            root / relative_text,
            boundary=root,
            label=f"build input directory {relative_text}",
        )
        if not directory.is_dir():
            raise ValueError(
                f"missing or unsafe build input directory: {relative_text}"
            )
        for path in _collect_tree(
            directory,
            boundary=root,
            ignored=lambda relative: _is_local_ignored(
                pathlib.PurePosixPath(relative_text) / relative
            ),
            label=f"build input {relative_text}",
        ):
            selected.add(path)
    return sorted(selected, key=lambda path: path.relative_to(root).as_posix())


def _validate_native_assets(root: pathlib.Path) -> None:
    mapping = root / ".dart_tool/native_assets.yaml"
    text = "\n".join(
        line
        for line in mapping.read_text(encoding="utf-8").splitlines()
        if not line.lstrip().startswith("#")
    )
    try:
        value = json.loads(text)
    except json.JSONDecodeError as error:
        raise ValueError("invalid Dart native-assets mapping") from error
    assets = value.get("native-assets") if isinstance(value, dict) else None
    if value.get("format-version") != [1, 0, 0] or not isinstance(assets, dict):
        raise ValueError("unsupported Dart native-assets mapping schema")
    boundary = _safe_directory(
        root / ".dart_tool/lib",
        "Dart native-assets directory",
    )
    for target, packages in assets.items():
        if not isinstance(target, str) or not target or not isinstance(packages, dict):
            raise ValueError("invalid Dart native-assets target")
        for package, location in packages.items():
            if (
                not isinstance(package, str)
                or not package.startswith("package:")
                or not isinstance(location, list)
                or len(location) != 2
                or location[0] != "absolute"
                or not isinstance(location[1], str)
                or not pathlib.Path(location[1]).is_absolute()
            ):
                raise ValueError("invalid Dart native-assets location")
            path = _confined_path_without_symlinks(
                pathlib.Path(location[1]),
                boundary=boundary,
                label=f"Dart native asset {package}",
            )
            if not path.is_file():
                raise ValueError(f"missing Dart native asset: {package}")


def _sha256(path: pathlib.Path) -> str:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise ValueError(f"manifest input is not a regular file: {path}")
        if before.st_nlink != 1:
            raise ValueError(f"hardlinked manifest input is not allowed: {path}")
        digest = hashlib.sha256()
        while chunk := os.read(descriptor, 1024 * 1024):
            digest.update(chunk)
        after = os.fstat(descriptor)
        current = os.stat(path, follow_symlinks=False)
        if _file_identity(before) != _file_identity(after) or _file_identity(
            after
        ) != _file_identity(current):
            raise ValueError(f"manifest input changed while hashing: {path}")
        return digest.hexdigest()
    finally:
        os.close(descriptor)


def bound_flutter_root(
    root: pathlib.Path,
    expected_flutter_root: pathlib.Path | None,
) -> pathlib.Path:
    configured = flutter_sdk_root(root)
    if expected_flutter_root is None:
        return configured
    expected = _safe_directory(expected_flutter_root, "expected Flutter SDK root")
    if configured != expected:
        raise ValueError(
            "android/local.properties Flutter SDK root does not match the expected "
            f"toolchain: configured={configured} expected={expected}"
        )
    return expected


def build_entries(
    root: pathlib.Path,
    *,
    expected_flutter_root: pathlib.Path | None = None,
) -> list[tuple[str, str]]:
    root = root.resolve(strict=True)
    flutter_root = bound_flutter_root(root, expected_flutter_root)
    entries = [
        (_sha256(binding.path), binding.logical_id)
        for binding in collect_manifest_path_bindings(
            root,
            expected_flutter_root=flutter_root,
        )
    ]
    if flutter_sdk_root(root) != flutter_root:
        raise ValueError("android/local.properties Flutter SDK changed while hashing")
    entries.sort(key=lambda item: item[1])
    if len(entries) != len({relative for _, relative in entries}):
        raise ValueError("duplicate synthetic build-input path")
    return entries


def collect_manifest_path_bindings(
    root: pathlib.Path,
    *,
    expected_flutter_root: pathlib.Path | None = None,
) -> list[ManifestPathBinding]:
    """Return the single canonical mapping used to hash and guard the manifest."""

    root = root.resolve(strict=True)
    flutter_root = bound_flutter_root(root, expected_flutter_root)
    bindings = [
        ManifestPathBinding(
            logical_id=path.relative_to(root).as_posix(),
            path=path,
            namespace="local",
        )
        for path in collect_paths(root)
    ]
    bindings.extend(
        ManifestPathBinding(synthetic, path, "package")
        for synthetic, path in collect_external_paths(
            root,
            flutter_root=flutter_root,
        )
    )
    bindings.extend(
        ManifestPathBinding(synthetic, path, "flutterToolchain")
        for synthetic, path in collect_toolchain_paths(
            root,
            flutter_root=flutter_root,
        )
    )
    bindings.extend(
        ManifestPathBinding(synthetic, path, "flutterToolPackage")
        for synthetic, path in collect_flutter_tool_paths(
            root,
            flutter_root=flutter_root,
        )
    )
    bindings.sort(key=lambda binding: binding.logical_id)
    logical_ids = [binding.logical_id for binding in bindings]
    if len(logical_ids) != len(set(logical_ids)):
        raise ValueError("duplicate synthetic build-input path")
    for binding in bindings:
        if (
            not binding.path.is_absolute()
            or binding.path.resolve(strict=True) != binding.path
        ):
            raise ValueError(f"non-canonical manifest input path: {binding.logical_id}")
    if flutter_sdk_root(root) != flutter_root:
        raise ValueError("android/local.properties Flutter SDK changed while mapping")
    return bindings


def write_manifest(
    root: pathlib.Path,
    output: pathlib.Path,
    *,
    expected_flutter_root: pathlib.Path | None = None,
) -> None:
    entries = build_entries(
        root,
        expected_flutter_root=expected_flutter_root,
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.{os.getpid()}.tmp")
    temporary.write_text(
        "".join(f"{digest}  {relative}\n" for digest, relative in entries),
        encoding="utf-8",
    )
    os.replace(temporary, output)


def read_manifest(path: pathlib.Path) -> list[tuple[str, str]]:
    entries: list[tuple[str, str]] = []
    seen: set[str] = set()
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        match = LINE.fullmatch(line)
        if match is None:
            raise ValueError(f"invalid tree manifest line {number}")
        digest, relative = match.groups()
        pure = pathlib.PurePosixPath(relative)
        if (
            pure.is_absolute()
            or ".." in pure.parts
            or _has_control_characters(relative)
            or relative in seen
        ):
            raise ValueError(f"unsafe or duplicate tree manifest path: {relative}")
        seen.add(relative)
        entries.append((digest, relative))
    if entries != sorted(entries, key=lambda item: item[1]):
        raise ValueError("tree manifest paths are not canonical")
    return entries


def verify_manifest(
    root: pathlib.Path,
    manifest: pathlib.Path,
    *,
    expected_flutter_root: pathlib.Path | None = None,
) -> None:
    expected = read_manifest(manifest)
    actual = build_entries(
        root,
        expected_flutter_root=expected_flutter_root,
    )
    if expected != actual:
        expected_map = {relative: digest for digest, relative in expected}
        actual_map = {relative: digest for digest, relative in actual}
        added = sorted(actual_map.keys() - expected_map.keys())
        removed = sorted(expected_map.keys() - actual_map.keys())
        changed = sorted(
            path
            for path in expected_map.keys() & actual_map.keys()
            if expected_map[path] != actual_map[path]
        )
        raise ValueError(
            "tested tree changed during the live rig: "
            f"added={added} removed={removed} changed={changed}"
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "command",
        choices=(
            "write",
            "verify",
            "flutter-root",
            "android-sdk-root",
            "clean-external-native-caches",
            "clean-flutter-gradle-generated-state",
            "verify-native-cache-freshness",
        ),
    )
    parser.add_argument("--root", type=pathlib.Path, required=True)
    parser.add_argument("--manifest", type=pathlib.Path)
    parser.add_argument("--evidence", type=pathlib.Path)
    parser.add_argument("--cleanup-evidence", type=pathlib.Path)
    parser.add_argument("--generated-cleanup-evidence", type=pathlib.Path)
    parser.add_argument("--discovery", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path)
    parser.add_argument("--expected-flutter-root", type=pathlib.Path)
    args = parser.parse_args()
    if args.command in {"flutter-root", "android-sdk-root"}:
        if (
            args.manifest is not None
            or args.evidence is not None
            or args.cleanup_evidence is not None
            or args.generated_cleanup_evidence is not None
            or args.discovery is not None
            or args.output is not None
            or args.expected_flutter_root is not None
        ):
            parser.error(
                f"{args.command} does not accept --manifest or --expected-flutter-root"
            )
        resolver = (
            flutter_sdk_root if args.command == "flutter-root" else android_sdk_root
        )
        print(resolver(args.root))
        return
    if args.command == "clean-external-native-caches":
        if (
            args.manifest is not None
            or args.evidence is None
            or args.cleanup_evidence is not None
            or args.generated_cleanup_evidence is not None
            or args.discovery is not None
            or args.output is not None
        ):
            parser.error(
                "clean-external-native-caches requires --evidence and rejects --manifest"
            )
        clean_external_native_build_caches(
            args.root,
            args.evidence,
            expected_flutter_root=args.expected_flutter_root,
        )
        return
    if args.command == "clean-flutter-gradle-generated-state":
        if (
            args.manifest is not None
            or args.evidence is None
            or args.cleanup_evidence is not None
            or args.generated_cleanup_evidence is not None
            or args.discovery is not None
            or args.output is not None
        ):
            parser.error(
                "clean-flutter-gradle-generated-state requires --evidence and "
                "rejects --manifest"
            )
        clean_flutter_gradle_generated_state(
            args.root,
            args.evidence,
            expected_flutter_root=args.expected_flutter_root,
        )
        return
    if args.command == "verify-native-cache-freshness":
        if (
            args.manifest is not None
            or args.evidence is not None
            or args.cleanup_evidence is None
            or args.generated_cleanup_evidence is None
            or args.discovery is None
            or args.output is None
        ):
            parser.error(
                "verify-native-cache-freshness requires --cleanup-evidence, "
                "--generated-cleanup-evidence, --discovery, and --output"
            )
        verify_native_cache_freshness(
            args.root,
            args.cleanup_evidence,
            args.generated_cleanup_evidence,
            args.discovery,
            args.output,
            expected_flutter_root=args.expected_flutter_root,
        )
        return
    if any(
        value is not None
        for value in (
            args.evidence,
            args.cleanup_evidence,
            args.generated_cleanup_evidence,
            args.discovery,
            args.output,
        )
    ):
        parser.error(f"{args.command} does not accept evidence arguments")
    if args.manifest is None:
        parser.error(f"{args.command} requires --manifest")
    if args.command == "write":
        write_manifest(
            args.root,
            args.manifest,
            expected_flutter_root=args.expected_flutter_root,
        )
    else:
        verify_manifest(
            args.root,
            args.manifest,
            expected_flutter_root=args.expected_flutter_root,
        )


if __name__ == "__main__":
    main()
