#!/usr/bin/env python3
"""Discover, hash, and verify the Android rig's external build toolchain.

Android SDK component roots and the Gradle distribution are hashed completely.
For the JDK, only runtime/compiler inputs used by Gradle are hashed: ``bin``,
``conf``, ``lib``, and the top-level ``release`` file.  The ``roots`` command
still emits the JDK root so a live watcher can reject changes anywhere below it.

Discovery mode consumes Gradle-generated lint and CXX models.  A caller that
does not want generated-model discovery can instead pass a complete repeated
``--component-root`` list using SDK-relative component roots.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import stat
import sys
import tempfile
import xml.etree.ElementTree as element_tree
from dataclasses import dataclass
from typing import Any, Iterable, Mapping, Sequence


MANIFEST_LINE = re.compile(r"^([0-9a-f]{64})  (.+)$")
PLATFORM_COMPONENT = re.compile(r"^platforms/android-([1-9][0-9]*)$")
VERSION_COMPONENT = re.compile(r"^(build-tools|ndk|cmake)/([0-9][A-Za-z0-9._+-]*)$")
GRADLE_DIRECTORY = re.compile(r"^gradle-[0-9][A-Za-z0-9._+-]*$")
JDK_DIRECTORIES = ("bin", "conf", "lib")
JDK_FILES = ("release",)
REQUIRED_COMPONENT_KINDS = {
    "platforms",
    "build-tools",
    "ndk",
    "cmake",
    "platform-tools",
}
MAX_MODEL_BYTES = 16 * 1024 * 1024
MAX_MANIFEST_BYTES = 128 * 1024 * 1024


@dataclass(frozen=True)
class ModelRecord:
    synthetic: str
    path: pathlib.Path
    digest: str


@dataclass(frozen=True)
class ToolchainLayout:
    root: pathlib.Path
    sdk_root: pathlib.Path
    jdk_root: pathlib.Path
    adb: pathlib.Path
    gradle_root: pathlib.Path
    components: tuple[str, ...]
    model_records: tuple[ModelRecord, ...]
    native_cache_roots: tuple[pathlib.Path, ...]
    native_model_source_paths: tuple[pathlib.Path, ...]

    @property
    def component_roots(self) -> tuple[pathlib.Path, ...]:
        return tuple(self.sdk_root / component for component in self.components)

    @property
    def watch_roots(self) -> tuple[pathlib.Path, ...]:
        return tuple(
            sorted(
                (*self.component_roots, self.jdk_root, self.gradle_root),
                key=str,
            )
        )


def _has_control_characters(value: str) -> bool:
    return any(ord(character) < 32 or ord(character) == 127 for character in value)


def _identity(value: os.stat_result) -> tuple[int, int, int, int, int, int, int]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def _has_symlink_component(path: pathlib.Path) -> bool:
    absolute = pathlib.Path(os.path.abspath(os.fspath(path)))
    current = pathlib.Path(absolute.anchor)
    for part in absolute.parts[1:]:
        current /= part
        if current.is_symlink():
            return True
    return False


def _safe_directory(path: pathlib.Path, label: str) -> pathlib.Path:
    if not path.is_absolute():
        raise ValueError(f"{label} must be absolute")
    if _has_control_characters(os.fspath(path)):
        raise ValueError(f"{label} contains a control character")
    if _has_symlink_component(path):
        raise ValueError(f"symlinked {label} is not allowed: {path}")
    resolved = path.resolve(strict=True)
    if not resolved.is_dir():
        raise ValueError(f"{label} is not a directory: {path}")
    return resolved


def _sha256_file(path: pathlib.Path, *, maximum_bytes: int | None = None) -> str:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise ValueError(f"manifest input is not a regular file: {path}")
        if before.st_nlink != 1:
            raise ValueError(f"hard-linked manifest input is not allowed: {path}")
        if maximum_bytes is not None and before.st_size > maximum_bytes:
            raise ValueError(f"manifest input is too large: {path}")
        digest = hashlib.sha256()
        while chunk := os.read(descriptor, 1024 * 1024):
            digest.update(chunk)
        after = os.fstat(descriptor)
        current = os.stat(path, follow_symlinks=False)
        if _identity(before) != _identity(after) or _identity(after) != _identity(
            current
        ):
            raise ValueError(f"manifest input changed while hashing: {path}")
        return digest.hexdigest()
    finally:
        os.close(descriptor)


def _read_regular_file(path: pathlib.Path, maximum_bytes: int) -> tuple[bytes, str]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise ValueError(f"input is not a regular file: {path}")
        if before.st_nlink != 1:
            raise ValueError(f"hard-linked input is not allowed: {path}")
        if before.st_size > maximum_bytes:
            raise ValueError(f"input is too large: {path}")
        data = bytearray()
        digest = hashlib.sha256()
        while chunk := os.read(descriptor, min(1024 * 1024, maximum_bytes + 1)):
            data.extend(chunk)
            digest.update(chunk)
            if len(data) > maximum_bytes:
                raise ValueError(f"input is too large: {path}")
        after = os.fstat(descriptor)
        current = os.stat(path, follow_symlinks=False)
        if _identity(before) != _identity(after) or _identity(after) != _identity(
            current
        ):
            raise ValueError(f"input changed while reading: {path}")
        return bytes(data), digest.hexdigest()
    finally:
        os.close(descriptor)


def _safe_regular_file(
    path: pathlib.Path, label: str, *, executable: bool = False
) -> pathlib.Path:
    if not path.is_absolute():
        raise ValueError(f"{label} must be absolute")
    if _has_control_characters(os.fspath(path)):
        raise ValueError(f"{label} contains a control character")
    if _has_symlink_component(path):
        raise ValueError(f"symlinked {label} is not allowed: {path}")
    resolved = path.resolve(strict=True)
    status = os.stat(resolved, follow_symlinks=False)
    if not stat.S_ISREG(status.st_mode):
        raise ValueError(f"{label} is not a regular file: {path}")
    if status.st_nlink != 1:
        raise ValueError(f"hard-linked {label} is not allowed: {path}")
    if executable and not os.access(resolved, os.X_OK):
        raise ValueError(f"{label} is not executable: {path}")
    return resolved


def _read_local_properties(root: pathlib.Path) -> tuple[dict[str, str], pathlib.Path]:
    path = _safe_regular_file(
        root / "android/local.properties", "android/local.properties"
    )
    data, _ = _read_regular_file(path, 1024 * 1024)
    text = data.decode("utf-8")
    properties: dict[str, str] = {}
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith(("#", "!")):
            continue
        if "=" not in line:
            raise ValueError(f"unsupported local.properties line {number}")
        key, value = (part.strip() for part in line.split("=", 1))
        if _has_control_characters(key) or _has_control_characters(value):
            raise ValueError(
                f"local.properties line {number} contains a control character"
            )
        if not key or not value or key in properties:
            raise ValueError(f"invalid or duplicate local.properties line {number}")
        properties[key] = value
    return properties, path


def _component_kind(component: str) -> str:
    if PLATFORM_COMPONENT.fullmatch(component):
        return "platforms"
    match = VERSION_COMPONENT.fullmatch(component)
    if match is not None:
        return match.group(1)
    if component == "platform-tools":
        return component
    raise ValueError(f"unsupported Android SDK component root: {component}")


def _validate_component_text(component: str) -> str:
    if _has_control_characters(component):
        raise ValueError("Android SDK component root contains a control character")
    pure = pathlib.PurePosixPath(component)
    if (
        pure.is_absolute()
        or pure.as_posix() != component
        or ".." in pure.parts
        or "." in pure.parts
        or "\\" in component
    ):
        raise ValueError(f"Android SDK component root is not canonical: {component}")
    _component_kind(component)
    return component


def _component_sort_key(component: str) -> tuple[int, str]:
    order = {
        "platforms": 0,
        "build-tools": 1,
        "ndk": 2,
        "cmake": 3,
        "platform-tools": 4,
    }
    return order[_component_kind(component)], component


def _validate_component_set(
    sdk_root: pathlib.Path, components: Iterable[str]
) -> tuple[str, ...]:
    raw = list(components)
    if len(raw) != len(set(raw)):
        raise ValueError("duplicate Android SDK component root")
    canonical = tuple(
        sorted(
            (_validate_component_text(value) for value in raw), key=_component_sort_key
        )
    )
    kinds = {_component_kind(component) for component in canonical}
    missing = sorted(REQUIRED_COMPONENT_KINDS - kinds)
    if missing:
        raise ValueError(
            f"missing required Android SDK component kinds: {', '.join(missing)}"
        )
    for component in canonical:
        _safe_directory(
            sdk_root / pathlib.PurePosixPath(component),
            f"Android SDK component {component}",
        )
    return canonical


def _relative_to(
    path: pathlib.Path, root: pathlib.Path, label: str
) -> pathlib.PurePosixPath:
    try:
        relative = path.relative_to(root)
    except ValueError as error:
        raise ValueError(
            f"{label} is outside expected Android SDK root: {path}"
        ) from error
    return pathlib.PurePosixPath(relative.as_posix())


def _component_from_model_path(
    raw: str,
    sdk_root: pathlib.Path,
    *,
    allowed_kinds: set[str],
) -> tuple[str, pathlib.Path]:
    if _has_control_characters(raw):
        raise ValueError("Android SDK model path contains a control character")
    candidate = pathlib.Path(raw)
    if not candidate.is_absolute():
        raise ValueError(f"Android SDK model path must be absolute: {raw}")
    lexical = pathlib.Path(os.path.abspath(candidate))
    relative = _relative_to(lexical, sdk_root, "Android SDK model path")
    parts = relative.parts
    if len(parts) >= 2 and parts[0] in {"platforms", "build-tools", "ndk", "cmake"}:
        component = f"{parts[0]}/{parts[1]}"
    elif parts and parts[0] == "platform-tools":
        component = "platform-tools"
    else:
        raise ValueError(f"unsupported Android SDK model path: {raw}")
    component = _validate_component_text(component)
    if _component_kind(component) not in allowed_kinds:
        raise ValueError(f"unsupported Android SDK model path: {raw}")
    component_root = _safe_directory(
        sdk_root / pathlib.PurePosixPath(component),
        f"Android SDK component {component}",
    )
    resolved = candidate.resolve(strict=True)
    _relative_to(resolved, component_root, "Android SDK model path")
    return component, resolved


def _model_paths(
    root: pathlib.Path, pattern: str, label: str
) -> tuple[pathlib.Path, ...]:
    paths: list[pathlib.Path] = []
    for candidate in root.glob(pattern):
        if not candidate.is_file():
            continue
        paths.append(_safe_regular_file(candidate, label))
    return tuple(sorted(set(paths), key=str))


def _model_record(
    root: pathlib.Path, kind: str, path: pathlib.Path, digest: str
) -> ModelRecord:
    relative = pathlib.PurePosixPath(path.relative_to(root / "build").as_posix())
    synthetic = f"@discovery-model/{kind}/{relative}"
    if (
        _has_control_characters(synthetic)
        or ".." in pathlib.PurePosixPath(synthetic).parts
    ):
        raise ValueError(f"unsafe generated model path: {path}")
    return ModelRecord(synthetic=synthetic, path=path, digest=digest)


def _parse_lint_models(
    root: pathlib.Path, sdk_root: pathlib.Path
) -> tuple[set[str], list[ModelRecord]]:
    paths = _model_paths(
        root,
        "build/**/intermediates/lint_model/**/module.xml",
        "Android lint model",
    )
    if not paths:
        raise ValueError("no generated Android lint module models were found")
    components: set[str] = set()
    records: list[ModelRecord] = []
    for path in paths:
        data, digest = _read_regular_file(path, MAX_MODEL_BYTES)
        try:
            document = element_tree.fromstring(data)
        except element_tree.ParseError as error:
            raise ValueError(f"invalid Android lint model {path}: {error}") from error
        if document.tag != "lint-module" or document.get("format") != "1":
            raise ValueError(f"unsupported Android lint model format: {path}")
        compile_target = document.get("compileTarget")
        boot_class_path = document.get("bootClassPath")
        if (
            compile_target is None
            or re.fullmatch(r"android-[1-9][0-9]*", compile_target) is None
        ):
            raise ValueError(f"invalid compileTarget in Android lint model: {path}")
        if boot_class_path is None or not boot_class_path:
            raise ValueError(f"missing bootClassPath in Android lint model: {path}")
        expected_platform = f"platforms/{compile_target}"
        model_components: set[str] = set()
        for raw in boot_class_path.split(os.pathsep):
            if not raw:
                raise ValueError(
                    f"empty bootClassPath entry in Android lint model: {path}"
                )
            component, resolved = _component_from_model_path(
                raw,
                sdk_root,
                allowed_kinds={"platforms", "build-tools"},
            )
            _safe_regular_file(resolved, "Android lint boot class path")
            model_components.add(component)
        if expected_platform not in model_components:
            raise ValueError(
                f"compileTarget and bootClassPath disagree in Android lint model: {path}"
            )
        if not any(
            _component_kind(value) == "build-tools" for value in model_components
        ):
            raise ValueError(f"Android lint model does not bind build-tools: {path}")
        components.update(model_components)
        records.append(_model_record(root, "lint", path, digest))
    return components, records


def _mapping(value: Any, label: str) -> Mapping[str, Any]:
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise ValueError(f"invalid object in CXX model: {label}")
    return value


def _string(value: Mapping[str, Any], key: str, label: str) -> str:
    result = value.get(key)
    if not isinstance(result, str) or not result or _has_control_characters(result):
        raise ValueError(f"invalid {key} in CXX model: {label}")
    return result


def _parse_cxx_models(
    root: pathlib.Path, sdk_root: pathlib.Path
) -> tuple[
    set[str],
    list[ModelRecord],
    set[pathlib.Path],
    set[pathlib.Path],
]:
    paths = _model_paths(
        root,
        "build/**/intermediates/cxx/**/build_model.json",
        "Android CXX build model",
    )
    if not paths:
        raise ValueError("no generated Android CXX build models were found")
    components: set[str] = set()
    records: list[ModelRecord] = []
    native_cache_roots: set[pathlib.Path] = set()
    native_model_source_paths: set[pathlib.Path] = set()
    for path in paths:
        data, digest = _read_regular_file(path, MAX_MODEL_BYTES)
        try:
            value = json.loads(data)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ValueError(
                f"invalid Android CXX build model {path}: {error}"
            ) from error
        top = _mapping(value, str(path))
        variant = _mapping(top.get("variant"), f"{path}:variant")
        module = _mapping(variant.get("module"), f"{path}:variant.module")
        project = _mapping(module.get("project"), f"{path}:variant.module.project")
        cmake = _mapping(module.get("cmake"), f"{path}:variant.module.cmake")

        native_cache_root = _safe_directory(
            pathlib.Path(_string(module, "cxxFolder", str(path))),
            "CXX model native cache root",
        )
        native_cache_metadata = os.stat(native_cache_root, follow_symlinks=False)
        if (
            native_cache_root.name != ".cxx"
            or native_cache_metadata.st_uid != os.getuid()
            or native_cache_metadata.st_mode & 0o022
        ):
            raise ValueError(f"unsafe CXX model native cache root: {path}")
        native_build_folder = _safe_directory(
            pathlib.Path(_string(top, "cxxBuildFolder", str(path))),
            "CXX model native build folder",
        )
        native_build_metadata = os.stat(native_build_folder, follow_symlinks=False)
        if (
            native_build_folder == native_cache_root
            or not native_build_folder.is_relative_to(native_cache_root)
            or native_build_metadata.st_uid != os.getuid()
            or native_build_metadata.st_mode & 0o022
        ):
            raise ValueError(
                f"CXX model build folder escapes native cache root: {path}"
            )
        native_cache_roots.add(native_cache_root)

        module_root = _safe_directory(
            pathlib.Path(_string(module, "moduleRootFolder", str(path))),
            "CXX model module root",
        )
        module_build_file = _safe_regular_file(
            pathlib.Path(_string(module, "moduleBuildFile", str(path))),
            "CXX model module build file",
        )
        if not module_build_file.is_relative_to(module_root):
            raise ValueError(f"CXX model module build file escapes module root: {path}")
        make_file = _safe_regular_file(
            pathlib.Path(_string(module, "makeFile", str(path))),
            "CXX model make file",
        )
        native_model_source_paths.update((module_build_file, make_file))

        model_sdk = _safe_directory(
            pathlib.Path(_string(project, "sdkFolder", str(path))),
            "CXX model Android SDK root",
        )
        if model_sdk != sdk_root:
            raise ValueError(f"CXX model Android SDK root mismatch: {path}")

        ndk_component, ndk_root = _component_from_model_path(
            _string(module, "ndkFolder", str(path)),
            sdk_root,
            allowed_kinds={"ndk"},
        )
        before_component, before_root = _component_from_model_path(
            _string(module, "ndkFolderBeforeSymLinking", str(path)),
            sdk_root,
            allowed_kinds={"ndk"},
        )
        if (
            ndk_root != sdk_root / ndk_component
            or before_root != ndk_root
            or before_component != ndk_component
        ):
            raise ValueError(f"CXX model NDK roots disagree: {path}")
        if _string(module, "ndkVersion", str(path)) != ndk_component.split("/", 1)[1]:
            raise ValueError(f"CXX model NDK version mismatch: {path}")
        toolchain_component, toolchain_file = _component_from_model_path(
            _string(module, "cmakeToolchainFile", str(path)),
            sdk_root,
            allowed_kinds={"ndk"},
        )
        if toolchain_component != ndk_component:
            raise ValueError(
                f"CXX model toolchain file is outside selected NDK: {path}"
            )
        _safe_regular_file(toolchain_file, "CXX model CMake toolchain file")

        cmake_component, cmake_executable = _component_from_model_path(
            _string(cmake, "cmakeExe", str(path)),
            sdk_root,
            allowed_kinds={"cmake"},
        )
        ninja_component, ninja_executable = _component_from_model_path(
            _string(module, "ninjaExe", str(path)),
            sdk_root,
            allowed_kinds={"cmake"},
        )
        if cmake_component != ninja_component:
            raise ValueError(f"CXX model CMake and Ninja roots disagree: {path}")
        if cmake_executable.name != "cmake" or ninja_executable.name != "ninja":
            raise ValueError(
                f"CXX model has unexpected CMake or Ninja executable: {path}"
            )
        _safe_regular_file(
            cmake_executable, "CXX model CMake executable", executable=True
        )
        _safe_regular_file(
            ninja_executable, "CXX model Ninja executable", executable=True
        )
        components.update((ndk_component, cmake_component))
        records.append(_model_record(root, "cxx", path, digest))
    return components, records, native_cache_roots, native_model_source_paths


def discover_components(
    root: pathlib.Path, sdk_root: pathlib.Path
) -> tuple[
    tuple[str, ...],
    tuple[ModelRecord, ...],
    tuple[pathlib.Path, ...],
    tuple[pathlib.Path, ...],
]:
    lint_components, lint_records = _parse_lint_models(root, sdk_root)
    (
        cxx_components,
        cxx_records,
        native_cache_roots,
        native_model_source_paths,
    ) = _parse_cxx_models(root, sdk_root)
    components = lint_components | cxx_components | {"platform-tools"}
    canonical = _validate_component_set(sdk_root, components)
    records = tuple(
        sorted((*lint_records, *cxx_records), key=lambda item: item.synthetic)
    )
    if len(records) != len({record.synthetic for record in records}):
        raise ValueError("duplicate generated Android model path")
    return (
        canonical,
        records,
        tuple(sorted(native_cache_roots, key=str)),
        tuple(sorted(native_model_source_paths, key=str)),
    )


def resolve_layout(
    root: pathlib.Path,
    *,
    expected_sdk_root: pathlib.Path,
    expected_jdk_root: pathlib.Path,
    expected_adb: pathlib.Path,
    expected_gradle_root: pathlib.Path,
    component_roots: Sequence[str] = (),
) -> ToolchainLayout:
    root = _safe_directory(root, "app root")
    sdk_root = _safe_directory(expected_sdk_root, "expected Android SDK root")
    jdk_root = _safe_directory(expected_jdk_root, "expected JDK root")
    gradle_root = _safe_directory(
        expected_gradle_root, "expected Gradle distribution root"
    )
    if GRADLE_DIRECTORY.fullmatch(gradle_root.name) is None:
        raise ValueError(
            f"unexpected Gradle distribution directory name: {gradle_root.name}"
        )

    properties, _ = _read_local_properties(root)
    configured = properties.get("sdk.dir")
    if configured is None:
        raise ValueError("sdk.dir is missing from android/local.properties")
    if _has_control_characters(configured):
        raise ValueError("sdk.dir contains a control character")
    configured_path = pathlib.Path(configured)
    if not configured_path.is_absolute():
        raise ValueError("sdk.dir must be an absolute canonical path")
    configured_sdk = _safe_directory(
        configured_path, "android/local.properties sdk.dir"
    )
    if configured_sdk != sdk_root:
        raise ValueError(
            "android/local.properties sdk.dir does not match the expected SDK root"
        )

    adb = _safe_regular_file(expected_adb, "expected adb", executable=True)
    canonical_adb = _safe_regular_file(
        sdk_root / "platform-tools/adb",
        "Android SDK platform-tools adb",
        executable=True,
    )
    if adb != canonical_adb:
        raise ValueError("expected adb does not match Android SDK platform-tools/adb")

    for directory in JDK_DIRECTORIES:
        _safe_directory(jdk_root / directory, f"JDK runtime directory {directory}")
    for relative in JDK_FILES:
        _safe_regular_file(jdk_root / relative, f"JDK runtime input {relative}")
    _safe_regular_file(jdk_root / "bin/java", "JDK java executable", executable=True)
    _safe_regular_file(
        gradle_root / "bin/gradle", "Gradle distribution executable", executable=True
    )

    if component_roots:
        components = _validate_component_set(sdk_root, component_roots)
        records: tuple[ModelRecord, ...] = ()
        native_cache_roots: tuple[pathlib.Path, ...] = ()
        native_model_source_paths: tuple[pathlib.Path, ...] = ()
    else:
        (
            components,
            records,
            native_cache_roots,
            native_model_source_paths,
        ) = discover_components(root, sdk_root)
    if "platform-tools" not in components:
        raise ValueError("Android SDK component set does not include platform-tools")

    return ToolchainLayout(
        root=root,
        sdk_root=sdk_root,
        jdk_root=jdk_root,
        adb=adb,
        gradle_root=gradle_root,
        components=components,
        model_records=records,
        native_cache_roots=native_cache_roots,
        native_model_source_paths=native_model_source_paths,
    )


def _safe_symlink_digest(path: pathlib.Path, component_root: pathlib.Path) -> str:
    before = os.lstat(path)
    if not stat.S_ISLNK(before.st_mode):
        raise ValueError(f"expected symlink changed type: {path}")
    target = os.readlink(path)
    if _has_control_characters(target) or pathlib.Path(target).is_absolute():
        raise ValueError(f"unsafe symlink in Android component: {path}")
    try:
        resolved = (path.parent / target).resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise ValueError(f"unsafe symlink in Android component: {path}") from error
    try:
        resolved.relative_to(component_root)
    except ValueError as error:
        raise ValueError(f"unsafe symlink escapes Android component: {path}") from error
    after = os.lstat(path)
    if _identity(before) != _identity(after):
        raise ValueError(f"symlink changed while hashing: {path}")
    return hashlib.sha256(b"symlink\0" + target.encode("utf-8")).hexdigest()


def _hash_tree(
    base: pathlib.Path,
    synthetic_root: str,
    *,
    allow_confined_symlinks: bool,
) -> list[tuple[str, str]]:
    entries: list[tuple[str, str]] = []

    def visit(directory: pathlib.Path) -> None:
        before = os.stat(directory, follow_symlinks=False)
        if not stat.S_ISDIR(before.st_mode):
            raise ValueError(f"toolchain tree input is not a directory: {directory}")
        with os.scandir(directory) as iterator:
            children = sorted(iterator, key=lambda item: item.name)
        for child in children:
            if _has_control_characters(child.name):
                raise ValueError(
                    f"toolchain tree path contains a control character: {child.path}"
                )
            path = pathlib.Path(child.path)
            status = os.lstat(path)
            relative = pathlib.PurePosixPath(path.relative_to(base).as_posix())
            synthetic = f"{synthetic_root}/{relative}"
            if stat.S_ISDIR(status.st_mode):
                visit(path)
            elif stat.S_ISREG(status.st_mode):
                entries.append((_sha256_file(path), synthetic))
            elif stat.S_ISLNK(status.st_mode):
                if not allow_confined_symlinks:
                    raise ValueError(
                        f"symlink in sealed toolchain tree is not allowed: {path}"
                    )
                entries.append((_safe_symlink_digest(path, base), synthetic))
            else:
                raise ValueError(
                    f"unsupported file type in sealed toolchain tree: {path}"
                )
        after = os.stat(directory, follow_symlinks=False)
        if _identity(before) != _identity(after):
            raise ValueError(f"toolchain directory changed while hashing: {directory}")

    visit(base)
    return entries


def _binding_digest(label: str, value: str) -> str:
    return hashlib.sha256(
        f"telltale-android-toolchain-v1\0{label}\0{value}".encode()
    ).hexdigest()


def build_entries(layout: ToolchainLayout) -> list[tuple[str, str]]:
    properties_path = layout.root / "android/local.properties"
    entries: list[tuple[str, str]] = [
        (
            _binding_digest("sdk-root", str(layout.sdk_root)),
            "@binding/android-sdk-root",
        ),
        (_binding_digest("jdk-root", str(layout.jdk_root)), "@binding/jdk-root"),
        (_binding_digest("adb", str(layout.adb)), "@binding/adb"),
        (
            _binding_digest("gradle-root", str(layout.gradle_root)),
            "@binding/gradle-root",
        ),
        (
            _binding_digest("components", "\n".join(layout.components)),
            "@binding/android-sdk-components",
        ),
        (_sha256_file(properties_path), "@binding/android-local-properties"),
    ]
    for record in layout.model_records:
        current = _sha256_file(record.path, maximum_bytes=MAX_MODEL_BYTES)
        if current != record.digest:
            raise ValueError(
                f"generated Android model changed after discovery: {record.path}"
            )
        entries.append((current, record.synthetic))
    for component, component_root in zip(
        layout.components, layout.component_roots, strict=True
    ):
        entries.extend(
            _hash_tree(
                component_root,
                f"@toolchain/android-sdk/{component}",
                # Google's NDK archive intentionally contains relative aliases
                # (clang -> clang-19, python3 -> python3.11, and similar).
                # Other SDK packages are sealed with the stricter no-link rule.
                allow_confined_symlinks=_component_kind(component) == "ndk",
            )
        )
    for relative in JDK_DIRECTORIES:
        entries.extend(
            _hash_tree(
                layout.jdk_root / relative,
                f"@toolchain/jdk/{relative}",
                allow_confined_symlinks=False,
            )
        )
    for relative in JDK_FILES:
        entries.append(
            (_sha256_file(layout.jdk_root / relative), f"@toolchain/jdk/{relative}")
        )
    entries.extend(
        _hash_tree(
            layout.gradle_root,
            "@toolchain/gradle",
            allow_confined_symlinks=False,
        )
    )
    entries.sort(key=lambda item: item[1])
    paths = [relative for _, relative in entries]
    if len(paths) != len(set(paths)):
        raise ValueError("duplicate synthetic Android toolchain manifest path")
    return entries


def _safe_manifest_output(path: pathlib.Path) -> pathlib.Path:
    if not path.is_absolute():
        path = pathlib.Path(os.path.abspath(path))
    if _has_control_characters(os.fspath(path)) or _has_symlink_component(path.parent):
        raise ValueError(f"unsafe manifest output path: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError(f"unsafe manifest output path: {path}")
    return path


def write_manifest(layout: ToolchainLayout, manifest: pathlib.Path) -> None:
    manifest = _safe_manifest_output(manifest)
    entries = build_entries(layout)
    descriptor, temporary_text = tempfile.mkstemp(
        prefix=f".{manifest.name}.", suffix=".tmp", dir=manifest.parent
    )
    temporary = pathlib.Path(temporary_text)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as output:
            for digest, relative in entries:
                output.write(f"{digest}  {relative}\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, manifest)
    finally:
        temporary.unlink(missing_ok=True)


def read_manifest(path: pathlib.Path) -> list[tuple[str, str]]:
    path = _safe_regular_file(path, "Android toolchain manifest")
    data, _ = _read_regular_file(path, MAX_MANIFEST_BYTES)
    text = data.decode("utf-8")
    entries: list[tuple[str, str]] = []
    seen: set[str] = set()
    for number, line in enumerate(text.splitlines(), 1):
        match = MANIFEST_LINE.fullmatch(line)
        if match is None:
            raise ValueError(f"invalid Android toolchain manifest line {number}")
        digest, relative = match.groups()
        pure = pathlib.PurePosixPath(relative)
        if (
            pure.is_absolute()
            or ".." in pure.parts
            or _has_control_characters(relative)
            or relative in seen
        ):
            raise ValueError(
                f"unsafe or duplicate Android toolchain manifest path: {relative}"
            )
        seen.add(relative)
        entries.append((digest, relative))
    if entries != sorted(entries, key=lambda item: item[1]):
        raise ValueError("Android toolchain manifest paths are not canonical")
    return entries


def verify_manifest(layout: ToolchainLayout, manifest: pathlib.Path) -> None:
    expected = read_manifest(manifest)
    actual = build_entries(layout)
    if actual != expected:
        expected_by_path = {relative: digest for digest, relative in expected}
        actual_by_path = {relative: digest for digest, relative in actual}
        changed = sorted(
            relative
            for relative in expected_by_path.keys() | actual_by_path.keys()
            if expected_by_path.get(relative) != actual_by_path.get(relative)
        )
        detail = ", ".join(changed[:5])
        if len(changed) > 5:
            detail += f", ... ({len(changed)} total)"
        raise ValueError(f"Android toolchain manifest mismatch: {detail}")


def roots_json(layout: ToolchainLayout) -> str:
    value = {
        "version": 1,
        "sdkRoot": str(layout.sdk_root),
        "jdkRoot": str(layout.jdk_root),
        "adb": str(layout.adb),
        "gradleRoot": str(layout.gradle_root),
        "components": list(layout.components),
        "watchRoots": [str(path) for path in layout.watch_roots],
        "discoveryModels": [str(record.path) for record in layout.model_records],
        "discoveryModelSha256": {
            str(record.path): record.digest for record in layout.model_records
        },
        "nativeCacheRoots": [str(path) for path in layout.native_cache_roots],
        "nativeModelSourcePaths": [
            str(path) for path in layout.native_model_source_paths
        ],
    }
    return (
        json.dumps(value, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
        + "\n"
    )


def _add_common_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--root", type=pathlib.Path, required=True)
    parser.add_argument("--expected-sdk-root", type=pathlib.Path, required=True)
    parser.add_argument("--expected-jdk-root", type=pathlib.Path, required=True)
    parser.add_argument("--expected-adb", type=pathlib.Path, required=True)
    parser.add_argument("--expected-gradle-root", type=pathlib.Path, required=True)
    parser.add_argument(
        "--component-root",
        action="append",
        default=[],
        help="SDK-relative component root; repeat with the complete set to skip model discovery",
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("write", "verify", "roots"):
        command = commands.add_parser(name)
        _add_common_arguments(command)
        if name in {"write", "verify"}:
            command.add_argument("--manifest", type=pathlib.Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        layout = resolve_layout(
            arguments.root,
            expected_sdk_root=arguments.expected_sdk_root,
            expected_jdk_root=arguments.expected_jdk_root,
            expected_adb=arguments.expected_adb,
            expected_gradle_root=arguments.expected_gradle_root,
            component_roots=arguments.component_root,
        )
        if arguments.command == "write":
            write_manifest(layout, arguments.manifest)
        elif arguments.command == "verify":
            verify_manifest(layout, arguments.manifest)
        elif arguments.command == "roots":
            sys.stdout.write(roots_json(layout))
        else:  # pragma: no cover - argparse constrains this value.
            raise AssertionError(f"unexpected command: {arguments.command}")
        return 0
    except (OSError, UnicodeError, ValueError) as error:
        print(f"android toolchain manifest: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
