#!/usr/bin/env python3
"""Fail-closed outer validation for Gate C toolchain and inner cleanup evidence.

The isolated Gradle distribution is deliberately deleted before the inner runner
writes ``runner-result.json``.  Consequently the outer verifier can re-hash the
surviving SDK/JDK/model inputs, but can only prove the deleted Gradle tree by the
byte-identical pre/post manifest attestation produced while the source guard was
live.  ``ValidationReport`` makes that boundary explicit.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any


SHA256 = re.compile(r"[0-9a-f]{64}")
COMPONENT = re.compile(
    r"(?:platforms/android-[1-9][0-9]*|"
    r"(?:build-tools|ndk|cmake)/[0-9][A-Za-z0-9._+-]*|platform-tools)"
)
MAX_JSON_BYTES = 16 * 1024 * 1024
MAX_MANIFEST_BYTES = 128 * 1024 * 1024
ROOT_KEYS = {
    "version",
    "sdkRoot",
    "jdkRoot",
    "adb",
    "gradleRoot",
    "components",
    "watchRoots",
    "discoveryModels",
    "discoveryModelSha256",
    "nativeCacheRoots",
    "nativeModelSourcePaths",
}
GENERATED_SCOPES = [
    "build",
    "android/.gradle",
    ".dart_tool/flutter_build",
    ".dart_tool/hooks_runner",
    ".dart_tool/test",
]
SNAPSHOT_KEYS = {
    "serial",
    "device_state",
    "rig_path",
    "rig_pid",
    "field_path",
    "field_pid",
    "font_scale",
    "accelerometer_rotation",
    "user_rotation",
}


class ValidationError(RuntimeError):
    """The supplied evidence does not prove the requested property."""


@dataclass(frozen=True)
class ValidationReport:
    manifest_entries: int
    live_reverified_entries: int
    gradle_attested_entries: int
    discovery_models: int
    external_native_roots: int
    cleanup_attempt: int
    cleanup_scope: str = "inner-run-device-state-only"
    gradle_scope: str = "pre-post-attestation-only-after-required-deletion"


def _duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValidationError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _read_file(path: Path, maximum: int) -> bytes:
    try:
        before = os.lstat(path)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_uid != os.getuid()
            or before.st_size > maximum
        ):
            raise ValidationError(f"unsafe evidence file: {path}")
        data = path.read_bytes()
        after = os.lstat(path)
    except OSError as error:
        raise ValidationError(f"unavailable evidence file: {path}") from error
    identity = lambda item: (  # noqa: E731 - compact immutable stat comparison
        item.st_dev,
        item.st_ino,
        item.st_mode,
        item.st_nlink,
        item.st_size,
        item.st_mtime_ns,
        item.st_ctime_ns,
    )
    if identity(before) != identity(after) or len(data) != before.st_size:
        raise ValidationError(f"evidence file changed while reading: {path}")
    return data


def _json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(
            _read_file(path, MAX_JSON_BYTES), object_pairs_hook=_duplicates
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValidationError(f"invalid JSON evidence: {path}") from error
    if not isinstance(value, dict):
        raise ValidationError(f"JSON evidence root is not an object: {path}")
    return value


def _sha(path: Path) -> str:
    return hashlib.sha256(_read_file(path, MAX_MANIFEST_BYTES)).hexdigest()


def _canonical_path(value: object, label: str) -> Path:
    if (
        not isinstance(value, str)
        or not value
        or any(ord(character) < 32 or ord(character) == 127 for character in value)
    ):
        raise ValidationError(f"invalid {label}")
    path = Path(value)
    if (
        not path.is_absolute()
        or Path(os.path.abspath(path)) != path
        or Path(os.path.realpath(path)) != path
    ):
        raise ValidationError(f"non-canonical {label}: {path}")
    return path


def _within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return True


def _path_list(value: object, label: str, *, empty: bool = False) -> list[Path]:
    if not isinstance(value, list) or (not empty and not value):
        raise ValidationError(f"{label} is not a valid path list")
    paths = [_canonical_path(item, label) for item in value]
    if paths != sorted(set(paths), key=str):
        raise ValidationError(f"{label} is duplicate or unsorted")
    return paths


def _validate_roots(value: object, label: str, *, discovery: bool) -> dict[str, Any]:
    if (
        not isinstance(value, dict)
        or set(value) != ROOT_KEYS
        or type(value.get("version")) is not int
        or value.get("version") != 1
    ):
        raise ValidationError(f"{label} schema is invalid")
    roots = {
        key: _canonical_path(value.get(key), f"{label} {key}")
        for key in ("sdkRoot", "jdkRoot", "adb", "gradleRoot")
    }
    components = value.get("components")
    component_order = {
        "platforms": 0,
        "build-tools": 1,
        "ndk": 2,
        "cmake": 3,
        "platform-tools": 4,
    }

    def component_key(item: str) -> tuple[int, str]:
        kind = item if item == "platform-tools" else item.split("/", 1)[0]
        return component_order[kind], item

    if (
        not isinstance(components, list)
        or not components
        or any(not isinstance(item, str) for item in components)
        or len(components) != len(set(components))
        or any(COMPONENT.fullmatch(item) is None for item in components)
        or components != sorted(components, key=component_key)
        or "platform-tools" not in components
    ):
        raise ValidationError(f"{label} components are invalid")
    expected_watch = sorted(
        [
            *(roots["sdkRoot"] / item for item in components),
            roots["jdkRoot"],
            roots["gradleRoot"],
        ],
        key=str,
    )
    watch = _path_list(value.get("watchRoots"), f"{label} watchRoots")
    if watch != expected_watch:
        raise ValidationError(f"{label} watchRoots do not exactly bind components")
    models = _path_list(
        value.get("discoveryModels"), f"{label} discoveryModels", empty=not discovery
    )
    model_sha = value.get("discoveryModelSha256")
    if (
        not isinstance(model_sha, dict)
        or set(model_sha) != {str(path) for path in models}
        or any(
            not isinstance(item, str) or SHA256.fullmatch(item) is None
            for item in model_sha.values()
        )
    ):
        raise ValidationError(f"{label} discovery model digest coverage is invalid")
    native_roots = _path_list(
        value.get("nativeCacheRoots"), f"{label} nativeCacheRoots", empty=not discovery
    )
    native_sources = _path_list(
        value.get("nativeModelSourcePaths"),
        f"{label} nativeModelSourcePaths",
        empty=not discovery,
    )
    if not discovery and (models or model_sha or native_roots or native_sources):
        raise ValidationError(f"{label} retained discovery-only paths")
    return value


def _validate_cleanup(value: object, label: str) -> dict[str, Any]:
    keys = {"version", "packageRoots", "packageRootsChecked", "removed"}
    if (
        not isinstance(value, dict)
        or set(value) != keys
        or type(value.get("version")) is not int
        or value.get("version") != 1
    ):
        raise ValidationError(f"{label} schema is invalid")
    roots = _path_list(value.get("packageRoots"), f"{label} packageRoots")
    if type(value.get("packageRootsChecked")) is not int or value.get(
        "packageRootsChecked"
    ) != len(roots):
        raise ValidationError(f"{label} package root count is invalid")
    removed = value.get("removed")
    if not isinstance(removed, list):
        raise ValidationError(f"{label} removed records are invalid")
    paths: list[Path] = []
    for record in removed:
        if (
            not isinstance(record, dict)
            or set(record) != {"bytes", "files", "path"}
            or type(record.get("bytes")) is not int
            or record["bytes"] < 0
            or type(record.get("files")) is not int
            or record["files"] < 0
        ):
            raise ValidationError(f"{label} removal record is invalid")
        path = _canonical_path(record.get("path"), f"{label} removed path")
        if path.name != ".cxx" or not any(_within(path, root) for root in roots):
            raise ValidationError(f"{label} removal is out of scope: {path}")
        if path.exists() or path.is_symlink():
            raise ValidationError(f"{label} removed cache survived: {path}")
        paths.append(path)
    if paths != sorted(set(paths), key=str):
        raise ValidationError(f"{label} removals are duplicate or unsorted")
    return value


def _manifest(path: Path) -> list[tuple[str, str]]:
    raw = _read_file(path, MAX_MANIFEST_BYTES)
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValidationError("Android toolchain manifest is not UTF-8") from error
    if not text or not text.endswith("\n") or "\r" in text:
        raise ValidationError("Android toolchain manifest is not canonical LF text")
    result: list[tuple[str, str]] = []
    for line in text.splitlines():
        if len(line) < 67 or line[64:66] != "  " or SHA256.fullmatch(line[:64]) is None:
            raise ValidationError("Android toolchain manifest line is invalid")
        logical = line[66:]
        pure = PurePosixPath(logical)
        if (
            pure.is_absolute()
            or ".." in pure.parts
            or any(ord(c) < 32 for c in logical)
        ):
            raise ValidationError("Android toolchain manifest path is unsafe")
        result.append((line[:64], logical))
    logicals = [logical for _, logical in result]
    if logicals != sorted(set(logicals)):
        raise ValidationError("Android toolchain manifest paths are not canonical")
    required = {
        "@binding/android-sdk-root",
        "@binding/jdk-root",
        "@binding/adb",
        "@binding/gradle-root",
        "@binding/android-sdk-components",
        "@binding/android-local-properties",
    }
    if not required.issubset(logicals):
        raise ValidationError("Android toolchain manifest bindings are incomplete")
    for prefix in ("@toolchain/android-sdk/", "@toolchain/jdk/", "@toolchain/gradle/"):
        if not any(item.startswith(prefix) for item in logicals):
            raise ValidationError(f"Android toolchain manifest lacks {prefix} coverage")
    return result


def _binding(label: str, value: str) -> str:
    return hashlib.sha256(
        f"telltale-android-toolchain-v1\0{label}\0{value}".encode()
    ).hexdigest()


def _live_digest(path: Path, component_root: Path | None = None) -> str:
    try:
        status = os.lstat(path)
    except OSError as error:
        raise ValidationError(f"manifest input disappeared: {path}") from error
    if stat.S_ISLNK(status.st_mode):
        target = os.readlink(path)
        if (
            component_root is None
            or Path(target).is_absolute()
            or any(ord(c) < 32 for c in target)
        ):
            raise ValidationError(f"unsafe manifest symlink: {path}")
        try:
            resolved = (path.parent / target).resolve(strict=True)
            resolved.relative_to(component_root)
        except (OSError, ValueError) as error:
            raise ValidationError(
                f"manifest symlink escapes component: {path}"
            ) from error
        return hashlib.sha256(b"symlink\0" + target.encode()).hexdigest()
    return _sha(path)


def _reverify_manifest(
    entries: list[tuple[str, str]], roots: dict[str, Any], app_root: Path
) -> tuple[int, int]:
    by_name = {logical: digest for digest, logical in entries}
    expected_bindings = {
        "@binding/android-sdk-root": _binding("sdk-root", roots["sdkRoot"]),
        "@binding/jdk-root": _binding("jdk-root", roots["jdkRoot"]),
        "@binding/adb": _binding("adb", roots["adb"]),
        "@binding/gradle-root": _binding("gradle-root", roots["gradleRoot"]),
        "@binding/android-sdk-components": _binding(
            "components", "\n".join(roots["components"])
        ),
    }
    if any(by_name.get(name) != digest for name, digest in expected_bindings.items()):
        raise ValidationError("Android toolchain manifest binding digest mismatch")
    local_properties = app_root / "android/local.properties"
    if by_name["@binding/android-local-properties"] != _sha(local_properties):
        raise ValidationError("Android local.properties manifest digest mismatch")

    live = len(expected_bindings) + 1
    gradle = 0
    sdk_root = Path(roots["sdkRoot"])
    jdk_root = Path(roots["jdkRoot"])
    gradle_root = Path(roots["gradleRoot"])
    if gradle_root.exists() or gradle_root.is_symlink():
        raise ValidationError("disposable Gradle distribution survived final cleanup")
    for digest, logical in entries:
        if logical.startswith("@binding/"):
            continue
        if logical.startswith("@discovery-model/"):
            # Exact model paths/digests are checked from discovery evidence below.
            continue
        if logical.startswith("@toolchain/gradle/"):
            gradle += 1
            continue
        if logical.startswith("@toolchain/jdk/"):
            path = jdk_root / logical.removeprefix("@toolchain/jdk/")
            component_root = None
        elif logical.startswith("@toolchain/android-sdk/"):
            relative = logical.removeprefix("@toolchain/android-sdk/")
            component = next(
                (
                    item
                    for item in roots["components"]
                    if relative == item or relative.startswith(f"{item}/")
                ),
                None,
            )
            if component is None:
                raise ValidationError("manifest Android SDK path escapes components")
            path = sdk_root / relative
            component_root = sdk_root / component
        else:
            raise ValidationError(
                f"unknown Android toolchain manifest namespace: {logical}"
            )
        if _live_digest(path, component_root) != digest:
            raise ValidationError(
                f"live Android toolchain manifest mismatch: {logical}"
            )
        live += 1
    if gradle == 0:
        raise ValidationError("deleted Gradle manifest attestation is empty")
    return live, gradle


def _key_values(path: Path, expected: set[str]) -> dict[str, str]:
    try:
        text = _read_file(path, MAX_JSON_BYTES).decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValidationError(f"non-UTF-8 line evidence: {path}") from error
    if not text.endswith("\n") or "\r" in text:
        raise ValidationError(f"non-canonical line evidence: {path}")
    result: dict[str, str] = {}
    for line in text.splitlines():
        if "=" not in line:
            raise ValidationError(f"invalid line evidence: {path}")
        key, value = line.split("=", 1)
        if key in result:
            raise ValidationError(f"duplicate line evidence key: {key}")
        result[key] = value
    if set(result) != expected:
        raise ValidationError(f"line evidence schema is invalid: {path}")
    return result


def _verify_inner_cleanup(evidence: Path) -> int:
    cleanup_paths = sorted(evidence.glob("final-cleanup*.txt"))
    if not cleanup_paths:
        raise ValidationError("final cleanup evidence is missing")
    successful: list[tuple[Path, dict[str, str]]] = []
    attempts: list[int] = []
    expected = {
        "cleanup_attempt",
        "rig_removal_evidence",
        "rig_path_after",
        "rig_pid_after",
        "field_path_unchanged",
        "field_pid_unchanged",
        "settings_unchanged",
        "cleanup_verified",
    }
    for path in cleanup_paths:
        record = _key_values(path, expected)
        try:
            record_attempt = int(record["cleanup_attempt"])
        except ValueError as error:
            raise ValidationError("cleanup attempt is not numeric") from error
        suffix = "" if record_attempt == 1 else f".retry-{record_attempt}"
        if record_attempt < 1 or path.name != f"final-cleanup{suffix}.txt":
            raise ValidationError("cleanup attempt filename binding is invalid")
        attempts.append(record_attempt)
        if record["cleanup_verified"] == "true":
            successful.append((path, record))
        elif record["cleanup_verified"] != "false":
            raise ValidationError("cleanup_verified is not boolean")
    if len(successful) != 1:
        raise ValidationError("inner run does not have exactly one successful cleanup")
    if sorted(attempts) != list(range(1, max(attempts) + 1)):
        raise ValidationError("inner cleanup attempt sequence is incomplete")
    cleanup_path, cleanup = successful[0]
    try:
        attempt = int(cleanup["cleanup_attempt"])
    except ValueError as error:
        raise ValidationError("cleanup attempt is not numeric") from error
    suffix = "" if attempt == 1 else f".retry-{attempt}"
    if cleanup_path.name != f"final-cleanup{suffix}.txt" or attempt < 1:
        raise ValidationError("cleanup attempt filename binding is invalid")
    if attempt != max(attempts):
        raise ValidationError("successful cleanup was not the final attempt")
    if (
        cleanup["rig_removal_evidence"] != f"final-rig-removal{suffix}.txt"
        or cleanup["rig_path_after"] != "absent"
        or cleanup["rig_pid_after"] != "absent"
        or cleanup["field_path_unchanged"] != "true"
        or cleanup["field_pid_unchanged"] != "true"
        or cleanup["settings_unchanged"] != "true"
    ):
        raise ValidationError("successful inner cleanup semantics are invalid")
    removal = _key_values(
        evidence / cleanup["rig_removal_evidence"],
        {
            "serial",
            "device_state",
            "rig_path_before",
            "rig_pid_before",
            "force_stop",
            "uninstall",
            "rig_path_after",
            "rig_pid_after",
        },
    )
    if (
        removal["device_state"] != "device"
        or removal["rig_path_after"] != "absent"
        or removal["rig_pid_after"] != "absent"
        or removal["force_stop"] not in {"success", "not-needed"}
        or removal["uninstall"] not in {"success", "not-needed"}
    ):
        raise ValidationError("rig removal evidence is invalid")
    before = _key_values(evidence / "before-state.txt", SNAPSHOT_KEYS)
    after = _key_values(evidence / f"after-state{suffix}.txt", SNAPSHOT_KEYS)
    if before["device_state"] != "device" or after["device_state"] != "device":
        raise ValidationError("device snapshot is not online")
    if before["serial"] != after["serial"] or after["serial"] != removal["serial"]:
        raise ValidationError("cleanup device serial changed")
    if after["rig_path"] != "absent" or after["rig_pid"] != "absent":
        raise ValidationError("rig package survived inner cleanup")
    for key in (
        "field_path",
        "field_pid",
        "font_scale",
        "accelerometer_rotation",
        "user_rotation",
    ):
        if before[key] != after[key]:
            raise ValidationError(f"inner cleanup changed device state: {key}")
    return attempt


def verify_toolchain_cleanup(
    evidence_dir: Path | str,
    prepared: dict[str, Any],
    *,
    app_root: Path | str | None = None,
) -> ValidationReport:
    """Validate toolchain/cleanup evidence and return its explicit proof scope."""

    evidence = Path(evidence_dir).resolve(strict=True)
    if not evidence.is_dir():
        raise ValidationError("evidence path is not a directory")
    paths = prepared.get("paths") if isinstance(prepared, dict) else None
    if not isinstance(paths, dict):
        raise ValidationError("prepared evidence paths are missing")
    prepared_app = _canonical_path(paths.get("app_root"), "prepared app root")
    root = Path(app_root).resolve(strict=True) if app_root is not None else prepared_app
    if root != prepared_app:
        raise ValidationError("app root does not match prepared evidence")
    sdk = _canonical_path(paths.get("android_sdk_root"), "prepared Android SDK root")

    discovery = _validate_roots(
        _json(evidence / "android-toolchain.discovery.json"),
        "Android toolchain discovery",
        discovery=True,
    )
    final = _validate_roots(
        _json(evidence / "android-toolchain.roots.post.json"),
        "final Android toolchain roots",
        discovery=False,
    )
    if _read_file(
        evidence / "android-toolchain.roots.json", MAX_JSON_BYTES
    ) != _read_file(evidence / "android-toolchain.roots.post.json", MAX_JSON_BYTES):
        raise ValidationError("Android toolchain pre/post root attestations differ")
    binding_keys = (
        "sdkRoot",
        "jdkRoot",
        "adb",
        "gradleRoot",
        "components",
        "watchRoots",
    )
    if any(discovery[key] != final[key] for key in binding_keys):
        raise ValidationError("discovery and final Android toolchain roots disagree")
    if discovery["sdkRoot"] != str(sdk) or discovery["adb"] != str(
        sdk / "platform-tools/adb"
    ):
        raise ValidationError("Android toolchain does not bind prepared SDK")

    models = [Path(item) for item in discovery["discoveryModels"]]
    lint = [
        path
        for path in models
        if "/intermediates/lint_model/" in path.as_posix() and path.name == "module.xml"
    ]
    cxx = [
        path
        for path in models
        if "/intermediates/cxx/" in path.as_posix() and path.name == "build_model.json"
    ]
    build_root = root / "build"
    if not lint or not cxx or any(not _within(path, build_root) for path in models):
        raise ValidationError(
            "discovery models do not include exact fresh lint and CXX sources"
        )
    for model in models:
        if _sha(model) != discovery["discoveryModelSha256"][str(model)]:
            raise ValidationError(f"discovery model digest mismatch: {model}")

    pre_cleanup = _validate_cleanup(
        _json(evidence / "external-native-cache-cleanup.pre.json"), "pre cleanup"
    )
    post_cleanup = _validate_cleanup(
        _json(evidence / "external-native-cache-cleanup.post.json"), "post cleanup"
    )
    if pre_cleanup["packageRoots"] != post_cleanup["packageRoots"]:
        raise ValidationError("native cleanup package roots changed")
    generated = _json(evidence / "generated-input-cleanup.json")
    if (
        set(generated) != {"version", "checked", "removed"}
        or type(generated.get("version")) is not int
        or generated.get("version") != 1
        or generated.get("checked") != GENERATED_SCOPES
        or not isinstance(generated.get("removed"), list)
        or any(not isinstance(item, str) for item in generated["removed"])
        or len(generated["removed"]) != len(set(generated["removed"]))
        or any(item not in GENERATED_SCOPES for item in generated["removed"])
    ):
        raise ValidationError("generated input cleanup evidence is invalid")

    native_roots = [Path(item) for item in discovery["nativeCacheRoots"]]
    local = [path for path in native_roots if path == build_root / ".cxx"]
    external = [path for path in native_roots if path != build_root / ".cxx"]
    package_roots = [Path(item) for item in pre_cleanup["packageRoots"]]
    if any(
        not any(_within(path, package) for package in package_roots)
        for path in external
    ):
        raise ValidationError(
            "native cache roots are not local or scoped external roots"
        )
    post_removed = {record["path"] for record in post_cleanup["removed"]}
    if not {str(path) for path in external}.issubset(post_removed):
        raise ValidationError(
            "post cleanup does not cover every discovered external cache"
        )
    source_paths = [Path(item) for item in discovery["nativeModelSourcePaths"]]
    if not source_paths or any(
        not path.exists() or path.is_symlink() for path in source_paths
    ):
        raise ValidationError("native model source paths are unavailable after the run")

    freshness = _json(evidence / "native-cache-freshness-validated.json")
    if (
        set(freshness)
        != {
            "version",
            "result",
            "cleanupEvidenceSha256",
            "generatedCleanupEvidenceSha256",
            "discoveryEvidenceSha256",
            "localNativeCacheRoots",
            "externalNativeCacheRoots",
            "nativeCacheRoots",
            "nativeModelSourcePaths",
        }
        or type(freshness.get("version")) is not int
        or freshness.get("version") != 1
        or freshness.get("result") != "pass"
        or freshness.get("cleanupEvidenceSha256")
        != _sha(evidence / "external-native-cache-cleanup.pre.json")
        or freshness.get("generatedCleanupEvidenceSha256")
        != _sha(evidence / "generated-input-cleanup.json")
        or freshness.get("discoveryEvidenceSha256")
        != _sha(evidence / "android-toolchain.discovery.json")
        or type(freshness.get("localNativeCacheRoots")) is not int
        or freshness.get("localNativeCacheRoots") != len(local)
        or type(freshness.get("externalNativeCacheRoots")) is not int
        or freshness.get("externalNativeCacheRoots") != len(external)
        or freshness.get("nativeCacheRoots") != discovery["nativeCacheRoots"]
        or freshness.get("nativeModelSourcePaths")
        != discovery["nativeModelSourcePaths"]
    ):
        raise ValidationError("native cache freshness attestation is invalid")

    pre_manifest = evidence / "android-toolchain.pre.sha256"
    post_manifest = evidence / "android-toolchain.post.sha256"
    if _read_file(pre_manifest, MAX_MANIFEST_BYTES) != _read_file(
        post_manifest, MAX_MANIFEST_BYTES
    ):
        raise ValidationError("Android toolchain pre/post manifests differ")
    entries = _manifest(post_manifest)
    live, gradle = _reverify_manifest(entries, final, root)

    result = _json(evidence / "runner-result.json")
    digest_bindings = {
        "androidToolchainManifestSha256": post_manifest,
        "androidToolchainRootsSha256": evidence / "android-toolchain.roots.post.json",
        "androidToolchainDiscoverySha256": evidence
        / "android-toolchain.discovery.json",
        "externalNativeCacheCleanupPreSha256": evidence
        / "external-native-cache-cleanup.pre.json",
        "externalNativeCacheCleanupPostSha256": evidence
        / "external-native-cache-cleanup.post.json",
        "generatedInputCleanupSha256": evidence / "generated-input-cleanup.json",
        "nativeCacheFreshnessValidationSha256": evidence
        / "native-cache-freshness-validated.json",
    }
    if result.get("result") != "pass" or result.get("cleanupVerified") is not True:
        raise ValidationError("runner result does not claim a successful cleanup")
    for key, path in digest_bindings.items():
        if result.get(key) != _sha(path):
            raise ValidationError(f"runner result digest mismatch: {key}")

    attempt = _verify_inner_cleanup(evidence)
    return ValidationReport(
        manifest_entries=len(entries),
        live_reverified_entries=live,
        gradle_attested_entries=gradle,
        discovery_models=len(models),
        external_native_roots=len(external),
        cleanup_attempt=attempt,
    )
