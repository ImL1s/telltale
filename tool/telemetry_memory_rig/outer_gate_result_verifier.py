#!/usr/bin/env python3
"""Fail-closed consumer for a completed Gate C runner evidence directory."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import stat
import sys
import tarfile
from collections.abc import Sequence
from pathlib import Path
from typing import Any, cast


SHA256_RE = re.compile(r"[0-9a-f]{64}")
MANIFEST_NAME = "RUN_SHA256SUMS"
RESULT_NAME = "runner-result.json"
CUTS = [
    "allocated",
    "sourceVerified",
    "handedOffBeforePlatform",
    "platformInvoked",
    "pendingResult",
    "neverResult",
    "realPluginMirror",
]
SHA_EVIDENCE_PATHS = {
    "summarySha256": "summary.json",
    "testedTreeManifestSha256": "tested-files.post.sha256",
    "sourceTreeGuardResultSha256": "source-tree-guard-result.json",
    "bootstrapSourceTreeGuardResultSha256": "bootstrap-source-tree-guard-result.json",
    "androidToolchainManifestSha256": "android-toolchain.post.sha256",
    "androidToolchainRootsSha256": "android-toolchain.roots.post.json",
    "androidToolchainDiscoverySha256": "android-toolchain.discovery.json",
    "externalNativeCacheCleanupPreSha256": "external-native-cache-cleanup.pre.json",
    "externalNativeCacheCleanupPostSha256": "external-native-cache-cleanup.post.json",
    "flutterGradleGeneratedCleanupPreSha256": "flutter-gradle-generated-cleanup.pre.json",
    "flutterGradleGeneratedCleanupPostSha256": "flutter-gradle-generated-cleanup.post.json",
    "generatedInputCleanupSha256": "generated-input-cleanup.json",
    "nativeCacheFreshnessValidationSha256": "native-cache-freshness-validated.json",
    "androidSdkSandboxPrepareSha256": "android-sdk-sandbox.prepare.json",
    "androidSdkSandboxPostSha256": "android-sdk-sandbox.post.json",
}
SHA_COMPONENT_PATHS = {
    "androidSdkSandboxProfileSha256": "android_sdk_write_deny.sb",
    "androidSdkSandboxWrapperSha256": "android_sdk_sandbox_exec.sh",
    "androidSdkSandboxProbeSha256": "android_sdk_sandbox_probe.py",
    "androidSdkSandboxPreflightSha256": "android_sdk_sandbox_preflight.py",
    "processScopeHelperSha256": "process_scope.py",
    "scopedCommandHelperSha256": "scoped_command.py",
}
SYSTEM_SANDBOX_EXEC = Path("/usr/bin/sandbox-exec")
SHA_SYSTEM_COMPONENT_PATHS = {
    "androidSdkSandboxExecSha256": SYSTEM_SANDBOX_EXEC,
}
SHA_KEYS = tuple(
    list(SHA_EVIDENCE_PATHS)
    + ["pythonExecutableSha256"]
    + list(SHA_COMPONENT_PATHS)
    + list(SHA_SYSTEM_COMPONENT_PATHS)
    + ["processScopeCleanupSha256"]
)
RESULT_KEYS = {
    "version",
    "result",
    *SHA_KEYS,
    "cuts",
    "cleanupVerified",
}
SCOPE_KEYS = {
    "version",
    "status",
    "marker",
    "ownerRoot",
    "roots",
    "authorities",
    "referenceAuthorities",
    "authorizedSessions",
    "startedMonotonicNs",
    "endedMonotonicNs",
    "stoppedProcesses",
    "termSentProcesses",
    "killSentProcesses",
    "remainingOwnedProcesses",
    "foreignProcesses",
    "referenceExemptProcesses",
    "inspectionLimitations",
    "referenceInspection",
}
AUDIT_SCOPE_KEYS = SCOPE_KEYS | {"mode"}
PREPARED_KEYS = {
    "version",
    "status",
    "paths",
    "components",
    "sandboxExec",
    "androidSdk",
    "probe",
    "sessionProof",
}
POST_KEYS = {
    "version",
    "status",
    "preparedEvidenceSha256",
    "paths",
    "components",
    "sandboxExec",
    "androidSdk",
    "sessionProof",
}
CHILD_ENVIRONMENT_KEYS = {
    "schema",
    "version",
    "launchId",
    "allowedNames",
    "allowedNamesSha256",
    "actualNames",
    "actualNamesSha256",
    "actualNamesObservationPoint",
    "producerPlannedEnvironmentValuesSha256",
    "plannedNamesMatchBarrier",
    "valuesObserved",
    "postBarrierAddedNames",
    "credentialNamesAssertedAbsent",
    "forbiddenCredentialNamesPresent",
}
CHILD_ENVIRONMENT_ALLOWED_NAMES = {
    "ANDROID_HOME",
    "ANDROID_SDK_ROOT",
    "ANDROID_USER_HOME",
    "GRADLE_USER_HOME",
    "HOME",
    "JAVA_HOME",
    "LANG",
    "LC_ALL",
    "ORG_GRADLE_PROJECT_telltaleGateCRigDebug",
    "PATH",
    "PWD",
    "PUB_CACHE",
    "TELLTALE_GATE_C_FLUTTER_ROOT",
    "TELLTALE_GATE_C_JDK_ROOT",
    "TELLTALE_GATE_C_LAUNCH_READY_FD",
    "TELLTALE_GATE_C_LAUNCH_RELEASE_FD",
    "TELLTALE_GATE_C_PROCESS_SCOPE",
    "TELLTALE_GATE_C_SANDBOX_ANDROID_SDK_ROOT",
    "TELLTALE_GATE_C_SANDBOX_APP_ROOT",
    "TELLTALE_GATE_C_SANDBOX_FLUTTER_ROOT",
    "TELLTALE_GATE_C_SANDBOX_GRADLE_HOME",
    "TELLTALE_GATE_C_SANDBOX_ISOLATED_ROOT",
    "TELLTALE_GATE_C_SANDBOX_PROFILE",
    "TELLTALE_GATE_C_SANDBOX_PUB_CACHE",
    "TELLTALE_GATE_C_SANDBOX_RUN_TEMP",
    "XDG_CONFIG_HOME",
}
CHILD_ENVIRONMENT_RUNTIME_NAMES = {
    "TELLTALE_GATE_C_PROCESS_SCOPE",
    "TELLTALE_GATE_C_LAUNCH_RELEASE_FD",
    "TELLTALE_GATE_C_LAUNCH_READY_FD",
}
CHILD_ENVIRONMENT_CREDENTIAL_NAMES = {
    "ARBITRARY_SECRET",
    "HF_TOKEN",
    "OP_SERVICE_ACCOUNT_TOKEN",
    "SSH_AUTH_SOCK",
}
PREPARED_PATH_KEYS = {
    "app_root",
    "flutter_root",
    "pub_cache",
    "gradle_home",
    "isolated_root",
    "run_temp",
    "android_sdk_root",
    "host_home",
}
PREPARED_COMPONENT_PATHS = {
    "profile": "android_sdk_write_deny.sb",
    "wrapper": "android_sdk_sandbox_exec.sh",
    "probe": "android_sdk_sandbox_probe.py",
    "processScope": "process_scope.py",
    "scopedCommand": "scoped_command.py",
}
EQUAL_EVIDENCE_PAIRS = (
    ("tested-files.pre.sha256", "tested-files.post.sha256"),
    ("android-toolchain.pre.sha256", "android-toolchain.post.sha256"),
    ("android-toolchain.roots.json", "android-toolchain.roots.post.json"),
    (
        "android-sdk-sandbox-components.pre.sha256",
        "android-sdk-sandbox-components.post.sha256",
    ),
    ("flutter-settings.pre.sha256", "flutter-settings.post.sha256"),
    ("android-debug-keystore.pre.sha256", "android-debug-keystore.post.sha256"),
    ("python-executable.pre.sha256", "python-executable.post.sha256"),
    (
        "isolated-gradle-properties.pre.sha256",
        "isolated-gradle-properties.post.sha256",
    ),
)
GATE_MANIFEST_KEYS = {
    "version",
    "runToken",
    "cut",
    "id",
    "sourceKind",
    "state",
    "sourceFileName",
    "ledgerFileName",
    "sourceBytes",
    "sourceFingerprint",
    "result",
    "platformCalls",
    "platformSemantic",
    "pendingObservationMs",
    "archiveSha256",
    "sourceSha256",
    "ledgerSha256",
}
GATE_RECONSTRUCTION_KEYS = {
    "version",
    "runToken",
    "cut",
    "archiveSha256",
    "sourceSha256",
    "ledgerSha256",
    "platformCalls",
    "platformSemantic",
    "pendingObservationMs",
    "postRecoveryInventorySha256",
    "classification",
    "verified",
}
RETAINED_GATE_CUTS = set(CUTS) - {"allocated", "sourceVerified"}


class VerificationError(RuntimeError):
    """The evidence cannot prove the claimed Gate C result."""


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise VerificationError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def _canonical_directory(path: Path, *, private: bool) -> Path:
    try:
        canonical = path.resolve(strict=True)
        metadata = os.lstat(path)
    except OSError as error:
        raise VerificationError(f"unavailable directory: {path}") from error
    if canonical != path.absolute() or not stat.S_ISDIR(metadata.st_mode):
        raise VerificationError(f"symlinked or non-directory path: {path}")
    if metadata.st_uid != os.getuid():
        raise VerificationError(f"foreign-owned directory: {path}")
    if private and stat.S_IMODE(metadata.st_mode) != 0o700:
        raise VerificationError(f"non-private evidence directory: {path}")
    return canonical


def _canonical_regular(path: Path, *, private: bool) -> Path:
    try:
        canonical = path.resolve(strict=True)
    except OSError as error:
        raise VerificationError(f"unavailable file: {path}") from error
    if canonical != path.absolute():
        raise VerificationError(f"symlinked file path: {path}")
    descriptor = _open_regular(canonical, private=private)
    os.close(descriptor)
    return canonical


def _open_regular(path: Path, *, private: bool) -> int:
    try:
        metadata = os.lstat(path)
    except OSError as error:
        raise VerificationError(f"unavailable file: {path}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise VerificationError(f"symlinked or non-regular file: {path}")
    if metadata.st_uid != os.getuid() or metadata.st_nlink != 1:
        raise VerificationError(f"unsafe file ownership/link count: {path}")
    if (private and metadata.st_mode & 0o077) or metadata.st_mode & 0o022:
        raise VerificationError(f"unsafe file mode: {path}")
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise VerificationError(f"could not safely open file: {path}") from error
    opened = os.fstat(descriptor)
    if (
        not stat.S_ISREG(opened.st_mode)
        or (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino)
        or opened.st_uid != metadata.st_uid
        or opened.st_nlink != 1
    ):
        os.close(descriptor)
        raise VerificationError(f"file changed while opening: {path}")
    return descriptor


def _read_regular(path: Path, *, private: bool) -> bytes:
    descriptor = _open_regular(path, private=private)
    try:
        before = os.fstat(descriptor)
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
        after.st_dev,
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
    ) or sum(map(len, chunks)) != after.st_size:
        raise VerificationError(f"file changed while reading: {path}")
    return b"".join(chunks)


def _sha256_file(path: Path, *, private: bool) -> str:
    return hashlib.sha256(_read_regular(path, private=private)).hexdigest()


def _safe_relative_path(text: str) -> str:
    if (
        not text.startswith("./")
        or "\\" in text
        or any(ord(character) < 32 or ord(character) == 127 for character in text)
    ):
        raise VerificationError(f"unsafe manifest path: {text!r}")
    relative = text[2:]
    parts = relative.split("/")
    if not relative or any(part in {"", ".", ".."} for part in parts):
        raise VerificationError(f"non-canonical manifest path: {text!r}")
    return relative


def _walk_regular_files(root: Path) -> list[str]:
    regular: list[str] = []

    def visit(directory: Path, relative_parent: str) -> None:
        try:
            entries = sorted(os.scandir(directory), key=lambda entry: entry.name)
        except OSError as error:
            raise VerificationError(
                f"could not inspect evidence: {directory}"
            ) from error
        for entry in entries:
            if any(
                ord(character) < 32 or ord(character) == 127 for character in entry.name
            ):
                raise VerificationError(
                    f"control character in evidence name: {entry.name!r}"
                )
            relative = (
                f"{relative_parent}/{entry.name}" if relative_parent else entry.name
            )
            try:
                metadata = entry.stat(follow_symlinks=False)
            except OSError as error:
                raise VerificationError(
                    f"could not inspect evidence entry: {entry.path}"
                ) from error
            path = Path(entry.path)
            if stat.S_ISLNK(metadata.st_mode):
                raise VerificationError(f"symlink in evidence tree: {path}")
            if metadata.st_uid != os.getuid():
                raise VerificationError(f"foreign-owned evidence entry: {path}")
            if stat.S_ISDIR(metadata.st_mode):
                if stat.S_IMODE(metadata.st_mode) != 0o700:
                    raise VerificationError(f"non-private evidence directory: {path}")
                visit(path, relative)
            elif stat.S_ISREG(metadata.st_mode):
                if metadata.st_nlink != 1 or metadata.st_mode & 0o077:
                    raise VerificationError(f"unsafe evidence file metadata: {path}")
                regular.append(relative)
            else:
                raise VerificationError(f"special file in evidence tree: {path}")

    visit(root, "")
    return regular


def _parse_manifest(raw: bytes) -> list[tuple[str, str]]:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise VerificationError("manifest is not UTF-8") from error
    if not text or not text.endswith("\n") or "\r" in text:
        raise VerificationError("manifest must be non-empty canonical LF text")
    parsed: list[tuple[str, str]] = []
    for line in text.splitlines():
        if len(line) < 69 or line[64:68] != "  ./":
            raise VerificationError(f"invalid manifest line: {line!r}")
        digest = line[:64]
        if SHA256_RE.fullmatch(digest) is None:
            raise VerificationError(f"invalid manifest digest: {digest!r}")
        parsed.append((_safe_relative_path(line[66:]), digest))
    paths = [path for path, _ in parsed]
    if paths != sorted(paths) or len(paths) != len(set(paths)):
        raise VerificationError("manifest paths are not strictly sorted and unique")
    return parsed


def _load_json(path: Path) -> dict[str, Any]:
    raw = _read_regular(path, private=True)
    try:
        value = json.loads(raw, object_pairs_hook=_reject_duplicate_keys)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise VerificationError(f"invalid JSON: {path}") from error
    if not isinstance(value, dict):
        raise VerificationError(f"JSON root is not an object: {path}")
    return value


def _child_environment_path(authority_path: Path) -> Path:
    suffix = ".process-authority.json"
    if not authority_path.name.endswith(suffix):
        raise VerificationError("process authority evidence path is invalid")
    return authority_path.with_name(
        authority_path.name[: -len(suffix)] + ".child-environment.json"
    )


def _canonical_json_sha256(value: object) -> str:
    payload = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(payload).hexdigest()


def _verify_child_environment(
    authority_path: Path,
    authority: dict[str, Any],
) -> Path:
    path = _child_environment_path(authority_path)
    value = _load_json(path)
    actual_names = value.get("actualNames")
    if (
        not isinstance(actual_names, list)
        or any(
            not isinstance(name, str)
            or re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name) is None
            for name in actual_names
        )
        or actual_names != sorted(set(actual_names))
    ):
        raise VerificationError("child-environment actual names are invalid")
    allowed_names = sorted(CHILD_ENVIRONMENT_ALLOWED_NAMES)
    if (
        set(value) != CHILD_ENVIRONMENT_KEYS
        or value.get("schema") != "telltale-gate-c-child-environment-names-v2"
        or value.get("version") != 2
        or value.get("launchId") != authority.get("launchId")
        or value.get("allowedNames") != allowed_names
        or value.get("allowedNamesSha256") != _canonical_json_sha256(allowed_names)
        or not set(actual_names).issubset(CHILD_ENVIRONMENT_ALLOWED_NAMES)
        or not CHILD_ENVIRONMENT_RUNTIME_NAMES.issubset(actual_names)
        or value.get("actualNamesSha256") != _canonical_json_sha256(actual_names)
        or value.get("actualNamesObservationPoint")
        != "cooperative-sealed-wrapper-pre-release-barrier-v1"
        or SHA256_RE.fullmatch(value.get("producerPlannedEnvironmentValuesSha256", ""))
        is None
        or value.get("plannedNamesMatchBarrier") is not True
        or value.get("valuesObserved") is not False
        or value.get("postBarrierAddedNames")
        != ["FLUTTER_ALREADY_LOCKED", "JAVA_TOOL_OPTIONS", "TMPDIR"]
        or value.get("credentialNamesAssertedAbsent")
        != sorted(CHILD_ENVIRONMENT_CREDENTIAL_NAMES)
        or value.get("forbiddenCredentialNamesPresent") != []
    ):
        raise VerificationError("child-environment evidence binding is invalid")
    return path


def _load_trusted_module(path: Path, name: str) -> Any:
    """Load a component only after its exact path/digest was verified."""

    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise VerificationError(f"could not load validated component: {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    try:
        specification.loader.exec_module(module)
    except BaseException as error:
        sys.modules.pop(name, None)
        raise VerificationError(
            f"validated component could not load: {path}"
        ) from error
    return module


def _canonical_path_text(value: object, label: str) -> Path:
    if (
        not isinstance(value, str)
        or not value
        or any(ord(character) < 32 or ord(character) == 127 for character in value)
    ):
        raise VerificationError(f"invalid {label} path")
    path = Path(value)
    if not path.is_absolute() or Path(os.path.realpath(path)) != path:
        raise VerificationError(f"non-canonical {label} path: {path}")
    return path


def _require_deleted_path(path: Path, label: str) -> None:
    _canonical_path_text(str(path), label)
    if path.exists() or path.is_symlink():
        raise VerificationError(f"disposable {label} survived cleanup: {path}")


def _is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
    except ValueError:
        return False
    return True


def _verify_sandbox_semantics(
    evidence: Path,
    app_root: Path,
    rig_root: Path,
    python: Path,
    sandbox_exec: Path,
    result: dict[str, Any],
) -> tuple[dict[str, Any], Any]:
    preflight_path = rig_root / "android_sdk_sandbox_preflight.py"
    preflight = _load_trusted_module(
        preflight_path,
        f"telltale_outer_preflight_{os.getpid()}",
    )
    prepared_path = evidence / "android-sdk-sandbox.prepare.json"
    post_path = evidence / "android-sdk-sandbox.post.json"
    try:
        prepared = preflight.read_prepared_evidence(
            prepared_path,
            result["androidSdkSandboxPrepareSha256"],
        )
    except (OSError, UnicodeError, TypeError, ValueError) as error:
        raise VerificationError(
            "Android SDK sandbox prepared evidence is invalid"
        ) from error
    if (
        set(prepared) != PREPARED_KEYS | {"evidenceSha256"}
        or prepared.get("version") != 1
        or prepared.get("status") != "prepared"
    ):
        raise VerificationError("Android SDK sandbox prepared schema is not exact")

    paths_value = prepared.get("paths")
    if not isinstance(paths_value, dict) or set(paths_value) != PREPARED_PATH_KEYS:
        raise VerificationError("Android SDK sandbox prepared paths are invalid")
    paths = {
        name: _canonical_path_text(value, f"prepared {name}")
        for name, value in paths_value.items()
    }
    if paths["app_root"] != app_root:
        raise VerificationError("Android SDK sandbox app-root binding is invalid")
    if paths["host_home"] != Path.home().resolve(strict=True):
        raise VerificationError("Android SDK sandbox host-home binding is invalid")
    if paths["run_temp"].parent != paths["isolated_root"]:
        raise VerificationError("Android SDK sandbox run-temp topology is invalid")
    for name in (
        "app_root",
        "flutter_root",
        "pub_cache",
        "android_sdk_root",
        "host_home",
    ):
        try:
            if (
                preflight.validate_directory(paths[name], f"prepared {name}")
                != paths[name]
            ):
                raise ValueError(name)
        except (OSError, ValueError) as error:
            raise VerificationError(
                f"persistent prepared root changed: {name}"
            ) from error
    for name in ("gradle_home", "isolated_root", "run_temp"):
        _require_deleted_path(paths[name], name)
    if any(
        _is_within(paths["android_sdk_root"], paths[name])
        or _is_within(paths[name], paths["android_sdk_root"])
        for name in (
            "app_root",
            "flutter_root",
            "pub_cache",
            "gradle_home",
            "isolated_root",
            "run_temp",
        )
    ):
        raise VerificationError("Android SDK overlaps a sandbox write root")

    components = prepared.get("components")
    expected_component_paths = {
        name: rig_root / relative for name, relative in PREPARED_COMPONENT_PATHS.items()
    }
    expected_component_paths.update(
        {
            "preflight": preflight_path,
            "python": python,
        }
    )
    if not isinstance(components, dict) or set(components) != set(
        expected_component_paths
    ):
        raise VerificationError("Android SDK sandbox prepared components are invalid")
    try:
        for name, expected_path in expected_component_paths.items():
            fingerprint = components.get(name)
            if not isinstance(fingerprint, dict) or fingerprint.get("path") != str(
                expected_path
            ):
                raise ValueError(name)
            preflight._same_fingerprint(
                fingerprint,
                f"outer component changed ({name})",
            )
    except (OSError, UnicodeError, TypeError, ValueError) as error:
        raise VerificationError(
            "Android SDK sandbox component binding changed"
        ) from error

    sandbox_value = prepared.get("sandboxExec")
    try:
        actual_sandbox = preflight.codesign_identity(sandbox_exec)
    except (OSError, UnicodeError, TypeError, ValueError) as error:
        raise VerificationError(
            "system sandbox-exec identity could not be verified"
        ) from error
    if sandbox_value != actual_sandbox:
        raise VerificationError("system sandbox-exec identity changed")

    android_sdk = prepared.get("androidSdk")
    known_packages = (
        android_sdk.get("knownPackages") if isinstance(android_sdk, dict) else None
    )
    expected_known_packages = paths["android_sdk_root"] / ".knownPackages"
    if (
        not isinstance(android_sdk, dict)
        or set(android_sdk) != {"knownPackages"}
        or not isinstance(known_packages, dict)
        or known_packages.get("path") != str(expected_known_packages)
    ):
        raise VerificationError("Android SDK .knownPackages binding is invalid")
    try:
        preflight._same_fingerprint(
            known_packages,
            "outer Android SDK .knownPackages changed",
        )
        preflight.validate_probe_result(prepared.get("probe"))
    except (OSError, UnicodeError, ValueError) as error:
        raise VerificationError(
            "Android SDK sandbox enforcement proof is invalid"
        ) from error

    session = prepared.get("sessionProof")
    expected_session_paths = {
        "authority": evidence / "android-sdk-sandbox-probe.process-authority.json",
        "environment": evidence / "android-sdk-sandbox-probe.child-environment.json",
        "scope": evidence / "android-sdk-sandbox-probe.process-scope.json",
        "result": evidence / "android-sdk-sandbox-probe.scoped-command.json",
    }
    if not isinstance(session, dict) or set(session) != {
        "authority",
        "environment",
        "scope",
        "result",
        "referenceAuthorities",
    }:
        raise VerificationError("Android SDK sandbox session proof is invalid")
    try:
        for name, expected_path in expected_session_paths.items():
            fingerprint = session.get(name)
            if not isinstance(fingerprint, dict) or fingerprint.get("path") != str(
                expected_path
            ):
                raise ValueError(name)
            preflight._same_fingerprint(
                fingerprint,
                f"outer session proof changed ({name})",
            )
        references = session.get("referenceAuthorities")
        if not isinstance(references, list) or len(references) != 1:
            raise ValueError("referenceAuthorities")
        reference_paths: list[Path] = []
        for index, fingerprint in enumerate(references):
            if not isinstance(fingerprint, dict):
                raise ValueError(f"referenceAuthorities[{index}]")
            reference_path = _canonical_path_text(
                fingerprint.get("path"),
                f"referenceAuthorities[{index}]",
            )
            if not _is_within(reference_path, evidence):
                raise ValueError(f"referenceAuthorities[{index}]")
            preflight._same_fingerprint(
                fingerprint,
                f"outer reference proof changed ({index})",
            )
            reference_paths.append(reference_path)
        authority = _load_json(expected_session_paths["authority"])
        _verify_child_environment(expected_session_paths["authority"], authority)
        owner = authority.get("ownerRoot")
        if not preflight._valid_identity(owner):
            raise ValueError("ownerRoot")
        owner_identity = cast(dict[str, Any], owner)
        preflight.validate_session_result(
            authority_path=expected_session_paths["authority"],
            scope_path=expected_session_paths["scope"],
            result_path=expected_session_paths["result"],
            roots={name: Path(value) for name, value in paths_value.items()},
            components={
                name: Path(value["path"]) for name, value in components.items()
            },
            owner_root_pid=owner_identity["pid"],
            reference_authority_paths=reference_paths,
        )
    except (OSError, UnicodeError, TypeError, ValueError, VerificationError) as error:
        raise VerificationError(
            "Android SDK sandbox session proof is invalid"
        ) from error

    post = _load_json(post_path)
    if (
        set(post) != POST_KEYS
        or post.get("version") != 1
        or post.get("status") != "verified"
        or post.get("preparedEvidenceSha256")
        != result["androidSdkSandboxPrepareSha256"]
        or any(
            post.get(field) != prepared.get(field)
            for field in (
                "paths",
                "components",
                "sandboxExec",
                "androidSdk",
                "sessionProof",
            )
        )
    ):
        raise VerificationError("Android SDK sandbox post attestation is invalid")
    return prepared, preflight


def _verify_equal_evidence_pairs(evidence: Path) -> None:
    for before_name, after_name in EQUAL_EVIDENCE_PAIRS:
        before = _read_regular(evidence / before_name, private=True)
        after = _read_regular(evidence / after_name, private=True)
        if before != after:
            raise VerificationError(
                f"pre/post restoration evidence differs: {before_name}, {after_name}"
            )


def _parse_build_manifest(path: Path, label: str) -> dict[str, str]:
    raw = _read_regular(path, private=True)
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise VerificationError(f"{label} is not UTF-8") from error
    if not text or not text.endswith("\n") or "\r" in text:
        raise VerificationError(f"{label} is not canonical LF text")
    entries: list[tuple[str, str]] = []
    for number, line in enumerate(text.splitlines(), 1):
        if len(line) < 67 or line[64:66] != "  ":
            raise VerificationError(f"{label} line {number} is invalid")
        digest = line[:64]
        logical = line[66:]
        pure = Path(logical)
        if (
            SHA256_RE.fullmatch(digest) is None
            or not logical
            or logical.startswith("/")
            or "\\" in logical
            or ".." in pure.parts
            or any(
                ord(character) < 32 or ord(character) == 127 for character in logical
            )
        ):
            raise VerificationError(f"{label} line {number} is unsafe")
        entries.append((logical, digest))
    logical_paths = [logical for logical, _ in entries]
    if logical_paths != sorted(logical_paths) or len(logical_paths) != len(
        set(logical_paths)
    ):
        raise VerificationError(f"{label} paths are not sorted and unique")
    return dict(entries)


def _verify_tested_tree_and_summary(
    evidence: Path,
    app_root: Path,
    rig_root: Path,
    prepared: dict[str, Any],
) -> None:
    tested_manifest_path = evidence / "tested-files.post.sha256"
    tested = _parse_build_manifest(tested_manifest_path, "tested tree manifest")
    required_helpers = {
        "tool/telemetry_memory_rig/tree_manifest.py": rig_root / "tree_manifest.py",
        "tool/telemetry_memory_rig/analyze_pss.py": rig_root / "analyze_pss.py",
        "tool/telemetry_memory_rig/source_tree_guard.py": (
            rig_root / "source_tree_guard.py"
        ),
        "tool/telemetry_memory_rig/source_guard_evidence_validator.py": (
            rig_root / "source_guard_evidence_validator.py"
        ),
        "tool/telemetry_memory_rig/outer_toolchain_cleanup_validator.py": (
            rig_root / "outer_toolchain_cleanup_validator.py"
        ),
        "tool/telemetry_memory_rig/outer_process_scope_validator.py": (
            rig_root / "outer_process_scope_validator.py"
        ),
    }
    for logical, path in required_helpers.items():
        if tested.get(logical) != _sha256_file(path, private=False):
            raise VerificationError(f"tested tree does not bind helper: {logical}")

    tree_manifest = _load_trusted_module(
        required_helpers["tool/telemetry_memory_rig/tree_manifest.py"],
        f"telltale_outer_tree_manifest_{os.getpid()}",
    )
    try:
        tree_manifest.verify_manifest(
            app_root,
            tested_manifest_path,
            expected_flutter_root=Path(prepared["paths"]["flutter_root"]),
        )
    except (OSError, UnicodeError, TypeError, ValueError) as error:
        raise VerificationError(
            "tested tree no longer matches the sealed manifest"
        ) from error

    analyzer = _load_trusted_module(
        required_helpers["tool/telemetry_memory_rig/analyze_pss.py"],
        f"telltale_outer_analyze_pss_{os.getpid()}",
    )
    try:
        actual_summary = analyzer.analyze(
            str(evidence / "pss.tsv"),
            str(evidence / "flutter-measure.log"),
        )
    except (OSError, UnicodeError, TypeError, ValueError) as error:
        raise VerificationError("memory summary could not be recomputed") from error
    if _load_json(evidence / "summary.json") != actual_summary:
        raise VerificationError("memory summary does not match raw measured evidence")


def _read_private_text(path: Path) -> str:
    raw = _read_regular(path, private=True)
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise VerificationError(f"evidence text is not UTF-8: {path}") from error
    if "\r" in text:
        raise VerificationError(f"evidence text is not canonical LF text: {path}")
    return text


def _parse_key_value_text(path: Path) -> dict[str, str]:
    text = _read_private_text(path)
    if not text or not text.endswith("\n"):
        raise VerificationError(f"key/value evidence is not canonical: {path}")
    value: dict[str, str] = {}
    for number, line in enumerate(text.splitlines(), 1):
        if "=" not in line:
            raise VerificationError(
                f"key/value evidence line is invalid: {path}:{number}"
            )
        key, item = line.split("=", 1)
        if (
            not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", key.strip())
            or key.strip() in value
        ):
            raise VerificationError(
                f"key/value evidence key is invalid: {path}:{number}"
            )
        value[key.strip()] = item.strip()
    return value


def _verify_shasum_record(path: Path, target: Path, expected_digest: str) -> None:
    expected = f"{expected_digest}  {target}\n"
    if _read_private_text(path) != expected:
        raise VerificationError(f"checksum evidence is not exact: {path}")


def _verify_gate_driver_exit(path: Path, *, recovery: bool) -> None:
    value = _parse_key_value_text(path)
    expected_keys = {
        "version",
        "label",
        "pid",
        "start_monotonic_ns",
        "end_monotonic_ns",
        "elapsed_ms",
        "natural_timeout_ms",
        "term_timeout_ms",
        "kill_timeout_ms",
        "natural_exit_observed",
        "term_sent",
        "kill_sent",
        "forced_host_termination",
        "outcome",
        "exit_code",
        "clock_failure",
        "clock_failure_stage",
    }
    numeric_keys = {
        "pid",
        "start_monotonic_ns",
        "end_monotonic_ns",
        "elapsed_ms",
        "natural_timeout_ms",
        "term_timeout_ms",
        "kill_timeout_ms",
        "exit_code",
    }
    if set(value) != expected_keys or any(
        re.fullmatch(r"-?[0-9]+", value.get(key, "")) is None for key in numeric_keys
    ):
        raise VerificationError(f"Gate C driver-exit evidence is invalid: {path}")
    numbers = {key: int(value[key]) for key in numeric_keys}
    expected_timeouts = (120000, 5000, 5000) if recovery else (30000, 2000, 2000)
    if (
        value["version"] != "1"
        or value["label"]
        != ("gate-recovery-driver" if recovery else "gate-seed-driver")
        or numbers["pid"] < 1
        or numbers["end_monotonic_ns"] < numbers["start_monotonic_ns"]
        or numbers["elapsed_ms"]
        != (numbers["end_monotonic_ns"] - numbers["start_monotonic_ns"]) // 1_000_000
        or (
            numbers["natural_timeout_ms"],
            numbers["term_timeout_ms"],
            numbers["kill_timeout_ms"],
        )
        != expected_timeouts
        or value["natural_exit_observed"] != "true"
        or value["term_sent"] != "false"
        or value["kill_sent"] != "false"
        or value["forced_host_termination"] != "none"
        or value["outcome"] != "natural_exit"
        or value["clock_failure"] != "false"
        or value["clock_failure_stage"] != "none"
        or (numbers["exit_code"] != 0 if recovery else numbers["exit_code"] == 0)
    ):
        raise VerificationError(f"Gate C driver exit was not clean and bounded: {path}")


def _verify_gate_scoped_result(evidence: Path, label: str, status: str) -> None:
    authority_path = (
        evidence / "process-scope-authorities" / f"{label}.process-authority.json"
    )
    scope_path = evidence / f"{label}.process-scope.json"
    result_path = evidence / f"{label}.scoped-command.json"
    authority = _load_json(authority_path)
    scope = _load_json(scope_path)
    result = _load_json(result_path)
    references = scope.get("referenceAuthorities")
    exemptions = scope.get("referenceExemptProcesses")
    expected_keys = {
        "version",
        "label",
        "status",
        "commandExitCode",
        "authority",
        "scopeTermination",
        "authoritySha256",
        "childPid",
        "scopeEvidenceSha256",
    }
    if (
        set(result) != expected_keys
        or result.get("version") != 1
        or result.get("label") != label
        or result.get("status") != status
        or result.get("authority") != authority
        or result.get("scopeTermination") != scope
        or result.get("authoritySha256") != _sha256_file(authority_path, private=True)
        or result.get("scopeEvidenceSha256") != _sha256_file(scope_path, private=True)
        or type(result.get("childPid")) is not int
        or result["childPid"] != authority.get("leader", {}).get("pid")
        or type(result.get("commandExitCode")) is not int
        or (status == "completed" and result["commandExitCode"] != 0)
        or (status == "command_failed" and result["commandExitCode"] == 0)
        or scope.get("status") != "quiescent"
        or scope.get("remainingOwnedProcesses") != []
        or scope.get("foreignProcesses") != []
        or scope.get("inspectionLimitations") != []
        or not isinstance(references, list)
        or len(references) != 1
        or not isinstance(exemptions, list)
        or len(exemptions) != 1
    ):
        raise VerificationError(f"Gate C scoped command is invalid: {label}")

    entry = references[0]
    if (
        not isinstance(entry, dict)
        or set(entry) != {"path", "sha256", "exemptionId"}
        or not isinstance(entry.get("sha256"), str)
        or SHA256_RE.fullmatch(entry["sha256"]) is None
        or not isinstance(entry.get("exemptionId"), str)
        or re.fullmatch(r"[0-9a-f]{32}", entry["exemptionId"]) is None
    ):
        raise VerificationError(f"Gate C reference authority is invalid: {label}")
    reference_path = _canonical_path_text(
        entry.get("path"),
        f"Gate C {label} reference authority",
    )
    if (
        not _is_within(reference_path, evidence)
        or _sha256_file(reference_path, private=True) != entry["sha256"]
    ):
        raise VerificationError(f"Gate C reference authority seal is invalid: {label}")
    reference = _load_json(reference_path)
    reference_keys = {
        "version",
        "kind",
        "exemptionId",
        "ownerRoot",
        "subject",
        "executable",
        "program",
        "argv",
        "readiness",
        "roots",
        "allowedRootKeys",
    }
    subject = reference.get("subject")
    readiness = reference.get("readiness")
    if (
        set(reference) != reference_keys
        or reference.get("version") != 1
        or reference.get("kind") != "source-guard-reference-exemption"
        or reference.get("exemptionId") != entry["exemptionId"]
        or reference.get("ownerRoot") != authority.get("ownerRoot")
        or reference.get("roots") != scope.get("roots")
        or not isinstance(subject, dict)
        or subject.get("uid") != os.getuid()
        or subject.get("ppid") != reference.get("ownerRoot", {}).get("pid")
        or not isinstance(reference.get("allowedRootKeys"), list)
        or not reference["allowedRootKeys"]
        or reference["allowedRootKeys"] != sorted(set(reference["allowedRootKeys"]))
        or not isinstance(readiness, dict)
        or set(readiness) != {"path", "sha256", "nonce", "stopPath", "resultPath"}
        or not isinstance(readiness.get("sha256"), str)
        or SHA256_RE.fullmatch(readiness["sha256"]) is None
        or re.fullmatch(r"[0-9a-f]{32}", str(readiness.get("nonce", ""))) is None
    ):
        raise VerificationError(
            f"Gate C reference authority binding is invalid: {label}"
        )
    for seal_name in ("executable", "program"):
        seal = reference.get(seal_name)
        if (
            not isinstance(seal, dict)
            or set(seal) != {"path", "sha256"}
            or not isinstance(seal.get("sha256"), str)
            or SHA256_RE.fullmatch(seal["sha256"]) is None
        ):
            raise VerificationError(f"Gate C reference {seal_name} is invalid: {label}")
        sealed_path = _canonical_path_text(
            seal.get("path"),
            f"Gate C reference {seal_name}",
        )
        if _sha256_file(sealed_path, private=False) != seal["sha256"]:
            raise VerificationError(f"Gate C reference {seal_name} changed: {label}")
    argv = reference.get("argv")
    if (
        not isinstance(argv, list)
        or len(argv) < 5
        or any(not isinstance(item, str) for item in argv)
        or argv[0] != reference["executable"]["path"]
        or argv[1:4] != ["-I", "-S", "-B"]
        or argv[4] != reference["program"]["path"]
    ):
        raise VerificationError(f"Gate C reference argv is invalid: {label}")
    ready_path = _canonical_path_text(
        readiness["path"],
        f"Gate C {label} reference readiness",
    )
    if (
        not _is_within(ready_path, evidence)
        or _sha256_file(ready_path, private=True) != readiness["sha256"]
    ):
        raise VerificationError(f"Gate C reference readiness changed: {label}")
    ready = _load_json(ready_path)
    if (
        ready.get("pid") != subject.get("pid")
        or ready.get("nonce") != readiness["nonce"]
    ):
        raise VerificationError(f"Gate C reference readiness is invalid: {label}")
    exemption = exemptions[0]
    if (
        not isinstance(exemption, dict)
        or set(exemption) != {"exemptionId", "process", "reasons"}
        or exemption.get("exemptionId") != entry["exemptionId"]
        or not isinstance(exemption.get("process"), dict)
        or exemption["process"].get("identity") != subject
        or not isinstance(exemption.get("reasons"), list)
        or not exemption["reasons"]
        or exemption["reasons"] != sorted(set(exemption["reasons"]))
        or any(not isinstance(reason, str) for reason in exemption["reasons"])
    ):
        raise VerificationError(f"Gate C reference exemption is invalid: {label}")


def _verify_plugin_mirror(
    cut_dir: Path,
    ack_process_pid: int,
    source_bytes: bytes,
    ledger: dict[str, Any],
) -> None:
    plugin = cut_dir / "plugin-observed"
    listing = _read_private_text(plugin / "listing.txt")
    match = re.fullmatch(r"cache/share_plus/([^/\s]+) ([0-9]+)\n", listing)
    if match is None or int(match.group(2)) != len(source_bytes):
        raise VerificationError("real-plugin mirror listing is invalid")
    plugin_name = match.group(1)
    if _load_json(plugin / "ledger-at-observation.json") != ledger:
        raise VerificationError("real-plugin observed ledger changed")
    parity = _parse_key_value_text(plugin / "parity.txt")
    source_sha = hashlib.sha256(source_bytes).hexdigest()
    if (
        set(parity) != {"staged_sha256", "plugin_sha256", "bytes", "process"}
        or parity.get("staged_sha256") != source_sha
        or parity.get("plugin_sha256") != source_sha
        or parity.get("bytes") != str(len(source_bytes))
        or parity.get("process") != str(ack_process_pid)
    ):
        raise VerificationError("real-plugin mirror parity is invalid")

    mirror = plugin / "mirror.tar"
    try:
        with tarfile.open(mirror, "r:") as stream:
            members = stream.getmembers()
            roots = [member for member in members if member.isdir()]
            files = [member for member in members if member.isfile()]
            if (
                len(members) != 2
                or len(roots) != 1
                or roots[0].name.rstrip("/") != "share_plus"
                or len(files) != 1
                or files[0].name != f"share_plus/{plugin_name}"
                or files[0].issym()
                or files[0].islnk()
            ):
                raise VerificationError("real-plugin mirror archive is unsafe")
            extracted = stream.extractfile(files[0])
            if extracted is None or extracted.read() != source_bytes:
                raise VerificationError("real-plugin mirror archive bytes changed")
    except (OSError, tarfile.TarError) as error:
        raise VerificationError("real-plugin mirror archive is invalid") from error
    _verify_shasum_record(
        plugin / "mirror.sha256",
        mirror,
        _sha256_file(mirror, private=True),
    )


def _verify_gate_cut_semantics(evidence: Path, rig_root: Path) -> None:
    helper_path = rig_root / "gate_c_validate.py"
    tested = _parse_build_manifest(
        evidence / "tested-files.post.sha256",
        "tested tree manifest",
    )
    logical_helper = "tool/telemetry_memory_rig/gate_c_validate.py"
    if tested.get(logical_helper) != _sha256_file(helper_path, private=False):
        raise VerificationError("tested tree does not bind Gate C validator")
    gate = _load_trusted_module(
        helper_path,
        f"telltale_outer_gate_c_validate_{os.getpid()}",
    )
    identity = _parse_key_value_text(evidence / "identity.txt")
    serial = identity.get("serial")
    package = identity.get("package")
    if not serial or package != "com.cbstudio.telltale.rig":
        raise VerificationError("Gate C identity does not bind the rig package/device")

    cuts_root = _canonical_directory(evidence / "cuts", private=True)
    if sorted(path.name for path in cuts_root.iterdir()) != sorted(CUTS):
        raise VerificationError("Gate C cut directory set is not exact")
    for cut in CUTS:
        cut_dir = _canonical_directory(cuts_root / cut, private=True)
        fresh = _parse_key_value_text(cut_dir / "fresh-install-precondition.txt")
        expected_fresh_keys = {
            "serial",
            "device_state",
            "rig_path_before",
            "rig_pid_before",
            "force_stop",
            "uninstall",
            "rig_path_after",
            "rig_pid_after",
        }
        before_path = fresh.get("rig_path_before")
        before_pid = fresh.get("rig_pid_before")
        if (
            set(fresh) != expected_fresh_keys
            or fresh.get("serial") != serial
            or fresh.get("device_state") != "device"
            or fresh.get("rig_path_after") != "absent"
            or fresh.get("rig_pid_after") != "absent"
            or before_path is None
            or before_pid is None
            or (
                before_path != "absent"
                and not before_path.startswith("package:/data/app/")
            )
            or (
                before_pid != "absent"
                and re.fullmatch(r"[1-9][0-9]*", before_pid) is None
            )
            or (before_path == "absent" and before_pid != "absent")
            or fresh.get("force_stop")
            != ("not-needed" if before_pid == "absent" else "success")
            or fresh.get("uninstall")
            != ("not-needed" if before_path == "absent" else "success")
        ):
            raise VerificationError(
                f"Gate C fresh-install precondition is invalid: {cut}"
            )
        ack_path = cut_dir / "ack.json"
        ack = _load_json(ack_path)
        token = ack.get("runToken")
        if not isinstance(token, str):
            raise VerificationError(f"Gate C token is invalid: {cut}")
        try:
            gate.validate_ack(ack, cut)
            pre_inspected = gate.inspect_archive(
                cut_dir / "pre-kill-app-staging.tar",
                ack,
                cut,
            )
            post_inspected = gate.inspect_archive(
                cut_dir / "post-kill-app-staging.tar",
                ack,
                cut,
            )
            pre_actual = gate.build_manifest(
                cut_dir / "pre-kill-app-staging.tar",
                ack_path,
                token,
                cut,
            )
            post_actual = gate.build_manifest(
                cut_dir / "post-kill-app-staging.tar",
                ack_path,
                token,
                cut,
            )
        except Exception as error:
            raise VerificationError(
                f"Gate C archive evidence is invalid: {cut}"
            ) from error
        pre_manifest = _load_json(cut_dir / "pre-kill-manifest.json")
        restore = _load_json(cut_dir / "restore-manifest.json")
        if (
            set(pre_manifest) != GATE_MANIFEST_KEYS
            or set(restore) != GATE_MANIFEST_KEYS
            or pre_manifest != pre_actual
            or restore != post_actual
            or any(
                pre_manifest[key] != restore[key]
                for key in (
                    "sourceSha256",
                    "ledgerSha256",
                    "sourceBytes",
                    "sourceFingerprint",
                )
            )
            or pre_inspected["source"] != post_inspected["source"]
            or pre_inspected["ledger"] != post_inspected["ledger"]
        ):
            raise VerificationError(f"Gate C pre/post archive parity is invalid: {cut}")
        expected_post_hashes = (
            f"{restore['sourceSha256']}  {restore['sourceFileName']}\n"
            f"{restore['ledgerSha256']}  {restore['ledgerFileName']}\n"
        )
        if (
            _read_private_text(cut_dir / "post-kill-files.sha256")
            != expected_post_hashes
        ):
            raise VerificationError(f"Gate C post-kill file seal is invalid: {cut}")

        ledger_bytes = post_inspected["ledger"]
        source_bytes = post_inspected["source"]
        expected_staging_lines = sorted(
            (
                f"cache/telltale-app-shares/{restore['sourceFileName']} {len(source_bytes)}\n",
                f"cache/telltale-app-shares/{restore['ledgerFileName']} {len(ledger_bytes)}\n",
            )
        )
        pre_staging = _read_private_text(cut_dir / "pre-kill-app-staging.txt")
        if (
            not pre_staging.endswith("\n")
            or len(pre_staging.splitlines(keepends=True)) != 2
            or sorted(pre_staging.splitlines(keepends=True)) != expected_staging_lines
        ):
            raise VerificationError(f"Gate C pre-kill staging is invalid: {cut}")
        if (
            _read_regular(cut_dir / "pre-kill-ledger.json", private=True)
            != ledger_bytes
        ):
            raise VerificationError(f"Gate C pre-kill ledger changed: {cut}")
        pre_source = cut_dir / "pre-kill-source.bin"
        if cut == "allocated":
            if pre_source.exists() or pre_source.is_symlink():
                raise VerificationError("allocated cut fabricated source parity")
        else:
            if _read_regular(pre_source, private=True) != source_bytes:
                raise VerificationError(f"Gate C pre-kill source changed: {cut}")
            if _read_private_text(cut_dir / "pre-kill-source-parity.txt") != (
                f"bytes={len(source_bytes)}\nfingerprint={ack['fingerprint']}\n"
            ):
                raise VerificationError(f"Gate C pre-kill FNV parity is invalid: {cut}")

        ack_process = _parse_key_value_text(cut_dir / "ack-process-identity.txt")
        try:
            ack_pid = int(ack_process.get("pid", ""))
            ack_uid = int(ack_process.get("uid", ""))
        except ValueError as error:
            raise VerificationError(
                f"Gate C ack process identity is invalid: {cut}"
            ) from error
        if (
            ack_pid < 1
            or ack_uid < 1
            or ack_process.get("package") != package
            or package not in ack_process.get("cmdline", "")
            or not ack_process.get("package_path", "").startswith("package:/data/app/")
        ):
            raise VerificationError(f"Gate C ack process identity is invalid: {cut}")
        force = _parse_key_value_text(cut_dir / "force-stop-command.txt")
        expected_force_keys = {
            "before_epoch_ns",
            "command",
            "exit_code",
            "after_epoch_ns",
            "before_pid",
            "before_uid",
            "before_cmdline",
            "after_pid",
        }
        try:
            force_before = int(force.get("before_epoch_ns", ""))
            force_after = int(force.get("after_epoch_ns", ""))
        except ValueError as error:
            raise VerificationError(
                f"Gate C force-stop evidence is invalid: {cut}"
            ) from error
        if (
            set(force) != expected_force_keys
            or force_before < 1
            or force_after < force_before
            or force.get("command") != f"adb -s {serial} shell am force-stop {package}"
            or force.get("exit_code") != "0"
            or force.get("before_pid") != str(ack_pid)
            or force.get("before_uid") != str(ack_uid)
            or force.get("before_cmdline") != ack_process.get("cmdline")
            or force.get("after_pid") != ""
        ):
            raise VerificationError(f"Gate C force-stop evidence is invalid: {cut}")

        _verify_gate_driver_exit(cut_dir / "seed-driver-exit.txt", recovery=False)
        _verify_gate_driver_exit(cut_dir / "recovery-driver-exit.txt", recovery=True)
        seed_phase = "realpluginmirror" if cut == "realPluginMirror" else "seed"
        _verify_gate_scoped_result(
            evidence,
            f"gate-{seed_phase}-{cut.lower()}",
            "command_failed",
        )
        _verify_gate_scoped_result(
            evidence,
            f"gate-recover-{cut.lower()}",
            "completed",
        )

        recovery_process = _parse_key_value_text(
            cut_dir / "recovery-process-identity.txt"
        )
        if (
            set(recovery_process)
            != {"pid", "uid", "package", "cmdline", "package_path"}
            or re.fullmatch(r"[1-9][0-9]*", recovery_process.get("pid", "")) is None
            or re.fullmatch(r"[1-9][0-9]*", recovery_process.get("uid", "")) is None
            or recovery_process.get("package") != package
            or package not in recovery_process.get("cmdline", "")
            or not recovery_process.get("package_path", "").startswith(
                "package:/data/app/"
            )
        ):
            raise VerificationError(
                f"Gate C recovery process identity is invalid: {cut}"
            )

        raw_inventory = _read_private_text(cut_dir / "post-recovery-app-staging.txt")
        if _read_regular(
            cut_dir / "post-recovery-app-staging.stderr",
            private=True,
        ):
            raise VerificationError(
                f"Gate C recovery inventory probe emitted stderr: {cut}"
            )
        raw_lines = raw_inventory.splitlines(keepends=True)
        if any(not line.endswith("\n") for line in raw_lines) or len(raw_lines) != len(
            set(raw_lines)
        ):
            raise VerificationError(f"Gate C raw recovery inventory is invalid: {cut}")
        inventory = cut_dir / "post-recovery-inventory.canonical"
        inventory_bytes = _read_regular(inventory, private=True)
        if inventory_bytes != "".join(sorted(raw_lines)).encode():
            raise VerificationError(
                f"Gate C canonical recovery inventory is not sorted raw evidence: {cut}"
            )
        inventory_sha = hashlib.sha256(inventory_bytes).hexdigest()
        _verify_shasum_record(
            cut_dir / "post-recovery-inventory.sha256",
            inventory,
            inventory_sha,
        )
        retained = cut in RETAINED_GATE_CUTS
        expected_inventory = ""
        if retained:
            expected_inventory = "".join(expected_staging_lines)
        if inventory_bytes != expected_inventory.encode():
            raise VerificationError(f"Gate C recovery inventory is invalid: {cut}")

        reconstruction = _load_json(cut_dir / "reconstruction.json")
        expected_reconstruction = {
            "version": 1,
            "runToken": restore["runToken"],
            "cut": restore["cut"],
            "archiveSha256": restore["archiveSha256"],
            "sourceSha256": restore["sourceSha256"],
            "ledgerSha256": restore["ledgerSha256"],
            "platformCalls": restore["platformCalls"],
            "platformSemantic": restore["platformSemantic"],
            "pendingObservationMs": restore["pendingObservationMs"],
            "postRecoveryInventorySha256": inventory_sha,
            "classification": "retained" if retained else "cleaned",
            "verified": True,
        }
        if (
            set(reconstruction) != GATE_RECONSTRUCTION_KEYS
            or reconstruction != expected_reconstruction
        ):
            raise VerificationError(f"Gate C reconstruction is invalid: {cut}")

        if retained:
            post_ledger = cut_dir / "post-recovery-ledger.json"
            post_source = cut_dir / "post-recovery-source.bin"
            if (
                _read_regular(post_ledger, private=True) != ledger_bytes
                or _read_regular(post_source, private=True) != source_bytes
            ):
                raise VerificationError(f"Gate C retained bytes changed: {cut}")
            expected_recovery_sha = (
                f"{restore['ledgerSha256']}  {post_ledger}\n"
                f"{restore['sourceSha256']}  {post_source}\n"
            )
            if (
                _read_private_text(cut_dir / "post-recovery.sha256")
                != expected_recovery_sha
            ):
                raise VerificationError(
                    f"Gate C retained SHA evidence is invalid: {cut}"
                )
            if _read_private_text(cut_dir / "post-recovery-fnv.txt") != (
                f"bytes={len(source_bytes)}\nfingerprint={ack['fingerprint']}\n"
            ):
                raise VerificationError(
                    f"Gate C retained FNV evidence is invalid: {cut}"
                )
        for log_name, markers in (
            (
                "seed.log",
                (
                    "TELLTALE_GATE_C_COMMAND_READY",
                    f"TELLTALE_GATE_C_CUT_READY token={token} cut={cut}",
                ),
            ),
            (
                "recovery.log",
                (
                    f"TELLTALE_GATE_C_RESTORE_READY token={token}",
                    f"TELLTALE_GATE_C_RECOVERY_VERIFIED token={token} cut={cut}",
                ),
            ),
        ):
            log = _read_private_text(cut_dir / log_name)
            if any(marker not in log for marker in markers):
                raise VerificationError(f"Gate C driver markers are incomplete: {cut}")

        plugin = cut_dir / "plugin-observed"
        if cut == "realPluginMirror":
            ledger = _load_json(cut_dir / "post-recovery-ledger.json")
            _verify_plugin_mirror(cut_dir, ack_pid, source_bytes, ledger)
        elif plugin.exists() or plugin.is_symlink():
            raise VerificationError(f"unexpected plugin mirror evidence: {cut}")


def _validate_cleanup_record(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != {
        "version",
        "packageRoots",
        "packageRootsChecked",
        "removed",
    }:
        raise VerificationError(f"{label} schema is invalid")
    if type(value.get("version")) is not int or value.get("version") != 1:
        raise VerificationError(f"{label} schema is invalid")
    raw_roots = value.get("packageRoots")
    if not isinstance(raw_roots, list) or not raw_roots:
        raise VerificationError(f"{label} package roots are invalid")
    roots = [_canonical_path_text(item, f"{label} package root") for item in raw_roots]
    if (
        roots != sorted(set(roots), key=str)
        or type(value.get("packageRootsChecked")) is not int
        or value.get("packageRootsChecked") != len(roots)
    ):
        raise VerificationError(f"{label} package roots are incomplete")
    removed = value.get("removed")
    if not isinstance(removed, list):
        raise VerificationError(f"{label} removal records are invalid")
    removed_paths: list[Path] = []
    for item in removed:
        if (
            not isinstance(item, dict)
            or set(item) != {"bytes", "files", "path"}
            or type(item.get("bytes")) is not int
            or item["bytes"] < 0
            or type(item.get("files")) is not int
            or item["files"] < 0
        ):
            raise VerificationError(f"{label} removal record is invalid")
        path = _canonical_path_text(item.get("path"), f"{label} removal")
        if path.name != ".cxx" or not any(_is_within(path, root) for root in roots):
            raise VerificationError(f"{label} removal escaped package roots")
        if path.exists() or path.is_symlink():
            raise VerificationError(f"{label} removed cache survived: {path}")
        removed_paths.append(path)
    if removed_paths != sorted(set(removed_paths), key=str):
        raise VerificationError(f"{label} removals are duplicate or unsorted")
    return value


def _validate_flutter_gradle_generated_cleanup(
    value: object,
    label: str,
    flutter_root: Path,
) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != {
        "version",
        "checked",
        "removed",
    }:
        raise VerificationError(f"{label} schema is invalid")
    if type(value.get("version")) is not int or value.get("version") != 1:
        raise VerificationError(f"{label} schema is invalid")
    gradle_root = flutter_root / "packages/flutter_tools/gradle"
    expected = [
        gradle_root / ".gradle",
        gradle_root / "build",
        gradle_root / ".kotlin",
    ]
    checked = value.get("checked")
    if (
        not isinstance(checked, list)
        or [_canonical_path_text(item, f"{label} checked path") for item in checked]
        != expected
    ):
        raise VerificationError(f"{label} checked roots are incomplete")
    removed = value.get("removed")
    if not isinstance(removed, list):
        raise VerificationError(f"{label} removal records are invalid")
    removed_paths: list[Path] = []
    for item in removed:
        if (
            not isinstance(item, dict)
            or set(item) != {"bytes", "files", "path"}
            or type(item.get("bytes")) is not int
            or item["bytes"] < 0
            or type(item.get("files")) is not int
            or item["files"] < 0
        ):
            raise VerificationError(f"{label} removal record is invalid")
        path = _canonical_path_text(item.get("path"), f"{label} removal")
        if path not in expected:
            raise VerificationError(f"{label} removal escaped generated roots")
        removed_paths.append(path)
    if len(removed_paths) != len(set(removed_paths)) or removed_paths != [
        path for path in expected if path in removed_paths
    ]:
        raise VerificationError(f"{label} removals are duplicate or out of order")
    if any(path.exists() or path.is_symlink() for path in expected):
        raise VerificationError(f"{label} generated state survived cleanup")
    return value


def _validate_toolchain_roots(value: object, label: str) -> dict[str, Any]:
    keys = {
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
    if (
        not isinstance(value, dict)
        or set(value) != keys
        or type(value.get("version")) is not int
        or value.get("version") != 1
    ):
        raise VerificationError(f"{label} schema is invalid")
    for name in ("sdkRoot", "jdkRoot", "adb", "gradleRoot"):
        _canonical_path_text(value.get(name), f"{label} {name}")
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
        return component_order.get(kind, 99), item

    if (
        not isinstance(components, list)
        or not components
        or any(not isinstance(item, str) for item in components)
        or len(components) != len(set(components))
        or components != sorted(components, key=component_key)
        or "platform-tools" not in components
        or any(
            not item or item.startswith("/") or ".." in Path(item).parts
            for item in components
        )
    ):
        raise VerificationError(f"{label} components are invalid")
    for name in (
        "watchRoots",
        "discoveryModels",
        "nativeCacheRoots",
        "nativeModelSourcePaths",
    ):
        raw = value.get(name)
        if not isinstance(raw, list):
            raise VerificationError(f"{label} {name} is invalid")
        paths = [_canonical_path_text(item, f"{label} {name}") for item in raw]
        if paths != sorted(set(paths), key=str):
            raise VerificationError(f"{label} {name} is duplicate or unsorted")
    model_sha = value.get("discoveryModelSha256")
    if (
        not isinstance(model_sha, dict)
        or set(model_sha) != set(value["discoveryModels"])
        or any(
            not isinstance(item, str) or SHA256_RE.fullmatch(item) is None
            for item in model_sha.values()
        )
    ):
        raise VerificationError(f"{label} discovery model digests are invalid")
    return value


def _verify_cleanup_and_toolchain_semantics(
    evidence: Path,
    prepared: dict[str, Any],
    rig_root: Path,
) -> None:
    paths = prepared["paths"]
    flutter_root = _canonical_path_text(paths["flutter_root"], "prepared Flutter root")
    _validate_flutter_gradle_generated_cleanup(
        _load_json(evidence / "flutter-gradle-generated-cleanup.pre.json"),
        "pre-build Flutter Gradle generated cleanup",
        flutter_root,
    )
    _validate_flutter_gradle_generated_cleanup(
        _load_json(evidence / "flutter-gradle-generated-cleanup.post.json"),
        "post-build Flutter Gradle generated cleanup",
        flutter_root,
    )
    generated = _load_json(evidence / "generated-input-cleanup.json")
    expected_generated = [
        "build",
        "android/.gradle",
        ".dart_tool/flutter_build",
        ".dart_tool/hooks_runner",
        ".dart_tool/test",
    ]
    if (
        set(generated) != {"version", "checked", "removed"}
        or type(generated.get("version")) is not int
        or generated.get("version") != 1
        or generated.get("checked") != expected_generated
        or not isinstance(generated.get("removed"), list)
        or any(not isinstance(item, str) for item in generated["removed"])
        or len(generated["removed"]) != len(set(generated["removed"]))
        or any(item not in expected_generated for item in generated["removed"])
    ):
        raise VerificationError("generated input cleanup evidence is invalid")

    cleanup_pre = _validate_cleanup_record(
        _load_json(evidence / "external-native-cache-cleanup.pre.json"),
        "pre-build external native cleanup",
    )
    cleanup_post = _validate_cleanup_record(
        _load_json(evidence / "external-native-cache-cleanup.post.json"),
        "post-build external native cleanup",
    )
    if cleanup_pre["packageRoots"] != cleanup_post["packageRoots"]:
        raise VerificationError("external native cleanup package roots changed")

    _parse_build_manifest(
        evidence / "android-toolchain.post.sha256",
        "Android toolchain manifest",
    )

    discovery = _validate_toolchain_roots(
        _load_json(evidence / "android-toolchain.discovery.json"),
        "Android toolchain discovery",
    )
    final_roots = _validate_toolchain_roots(
        _load_json(evidence / "android-toolchain.roots.post.json"),
        "Android toolchain roots",
    )
    if (
        discovery["sdkRoot"] != paths["android_sdk_root"]
        or final_roots["sdkRoot"] != paths["android_sdk_root"]
        or discovery["adb"]
        != str(Path(paths["android_sdk_root"]) / "platform-tools" / "adb")
        or final_roots["adb"] != discovery["adb"]
        or final_roots["jdkRoot"] != discovery["jdkRoot"]
        or final_roots["gradleRoot"] != discovery["gradleRoot"]
        or final_roots["components"] != discovery["components"]
        or final_roots["discoveryModels"] != []
        or final_roots["discoveryModelSha256"] != {}
        or final_roots["nativeCacheRoots"] != []
        or final_roots["nativeModelSourcePaths"] != []
    ):
        raise VerificationError("Android toolchain roots do not bind discovery")

    app_root = _canonical_path_text(paths["app_root"], "prepared app root")
    local_cache_root = app_root / "build/.cxx"
    native_roots = [
        _canonical_path_text(item, "Android discovery native cache root")
        for item in discovery["nativeCacheRoots"]
    ]
    local_native_roots = [path for path in native_roots if path == local_cache_root]
    external_native_roots = [path for path in native_roots if path != local_cache_root]
    package_roots = [
        _canonical_path_text(item, "external native cleanup package root")
        for item in cleanup_pre["packageRoots"]
    ]
    if not native_roots or any(
        not any(_is_within(path, package) for package in package_roots)
        for path in external_native_roots
    ):
        raise VerificationError(
            "Android discovery native caches are outside the cleanup scope"
        )

    freshness = _load_json(evidence / "native-cache-freshness-validated.json")
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
        != _sha256_file(
            evidence / "external-native-cache-cleanup.pre.json",
            private=True,
        )
        or freshness.get("generatedCleanupEvidenceSha256")
        != _sha256_file(evidence / "generated-input-cleanup.json", private=True)
        or freshness.get("discoveryEvidenceSha256")
        != _sha256_file(evidence / "android-toolchain.discovery.json", private=True)
        or freshness.get("nativeCacheRoots") != discovery["nativeCacheRoots"]
        or freshness.get("nativeModelSourcePaths")
        != discovery["nativeModelSourcePaths"]
        or type(freshness.get("localNativeCacheRoots")) is not int
        or freshness.get("localNativeCacheRoots") != len(local_native_roots)
        or type(freshness.get("externalNativeCacheRoots")) is not int
        or freshness.get("externalNativeCacheRoots") != len(external_native_roots)
    ):
        raise VerificationError("native cache freshness evidence is invalid")

    tested = _parse_build_manifest(
        evidence / "tested-files.post.sha256",
        "tested tree manifest",
    )
    logical_helper = "tool/telemetry_memory_rig/outer_toolchain_cleanup_validator.py"
    helper_path = rig_root / "outer_toolchain_cleanup_validator.py"
    if tested.get(logical_helper) != _sha256_file(helper_path, private=False):
        raise VerificationError("tested tree does not bind toolchain cleanup validator")
    helper = _load_trusted_module(
        helper_path,
        f"telltale_outer_toolchain_cleanup_{os.getpid()}",
    )
    try:
        report = helper.verify_toolchain_cleanup(
            evidence,
            prepared,
            app_root=Path(prepared["paths"]["app_root"]),
        )
    except Exception as error:
        raise VerificationError(
            "toolchain and cleanup evidence failed semantic verification"
        ) from error
    if (
        type(report.manifest_entries) is not int
        or report.manifest_entries <= 0
        or type(report.live_reverified_entries) is not int
        or report.live_reverified_entries <= 0
        or type(report.gradle_attested_entries) is not int
        or report.gradle_attested_entries <= 0
        or type(report.discovery_models) is not int
        or report.discovery_models < 2
        or type(report.external_native_roots) is not int
        or report.external_native_roots != len(external_native_roots)
        or type(report.cleanup_attempt) is not int
        or report.cleanup_attempt <= 0
        or report.cleanup_scope != "inner-run-device-state-only"
        or report.gradle_scope != "pre-post-attestation-only-after-required-deletion"
    ):
        raise VerificationError("toolchain cleanup proof scope is invalid")


def _verify_source_guard_semantics(
    evidence: Path,
    rig_root: Path,
    prepared: dict[str, Any],
) -> None:
    tested = _parse_build_manifest(
        evidence / "tested-files.post.sha256",
        "tested tree manifest",
    )
    helper_paths = {
        "tool/telemetry_memory_rig/source_guard_evidence_validator.py": (
            rig_root / "source_guard_evidence_validator.py"
        ),
        "tool/telemetry_memory_rig/source_tree_guard.py": (
            rig_root / "source_tree_guard.py"
        ),
    }
    for logical, path in helper_paths.items():
        if tested.get(logical) != _sha256_file(path, private=False):
            raise VerificationError(f"tested tree does not bind helper: {logical}")
    validator = _load_trusted_module(
        helper_paths["tool/telemetry_memory_rig/source_guard_evidence_validator.py"],
        f"telltale_outer_source_guard_validator_{os.getpid()}",
    )
    source_guard = _load_trusted_module(
        helper_paths["tool/telemetry_memory_rig/source_tree_guard.py"],
        f"telltale_outer_source_tree_guard_{os.getpid()}",
    )

    identity = _parse_key_value_text(evidence / "identity.txt")
    paths = prepared["paths"]
    app_root = _canonical_directory(Path(paths["app_root"]), private=False)
    flutter_root = _canonical_directory(Path(paths["flutter_root"]), private=False)
    sdk_root = _canonical_directory(Path(paths["android_sdk_root"]), private=False)
    if identity.get("android_sdk_root") != str(sdk_root):
        raise VerificationError("source guard Android SDK identity is invalid")
    jdk_root = _canonical_directory(
        _canonical_path_text(identity.get("jdk_root"), "source guard JDK"),
        private=False,
    )
    python_runtime_root = _canonical_directory(
        _canonical_path_text(
            identity.get("python_runtime_root"),
            "source guard Python runtime",
        ),
        private=False,
    )
    isolated_root = _canonical_path_text(
        paths["isolated_root"],
        "source guard deleted isolated root",
    )
    settings_path = _canonical_path_text(
        str(isolated_root / "xdg-config/settings"),
        "source guard deleted Flutter settings",
    )
    debug_keystore = _canonical_path_text(
        str(isolated_root / "android-user-home/debug.keystore"),
        "source guard deleted debug keystore",
    )
    gradle_home = _canonical_path_text(
        paths["gradle_home"],
        "source guard deleted Gradle home",
    )
    gradle_distribution = _canonical_path_text(
        identity.get("gradle_distribution_root"),
        "source guard deleted Gradle distribution",
    )
    if (
        not _is_within(settings_path, isolated_root)
        or not _is_within(debug_keystore, isolated_root)
        or not _is_within(gradle_distribution, gradle_home)
        or any(
            path.exists() or path.is_symlink()
            for path in (
                isolated_root,
                settings_path,
                debug_keystore,
                gradle_home,
                gradle_distribution,
            )
        )
    ):
        raise VerificationError("source guard deleted-root topology is invalid")

    def verify_deleted_file_attestation(prefix: str, expected: Path) -> None:
        text = _read_private_text(evidence / f"{prefix}.post.sha256")
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)\n", text)
        if (
            match is None
            or Path(match.group(2)) != expected
            or _read_private_text(evidence / f"{prefix}.pre.sha256") != text
        ):
            raise VerificationError(
                f"source guard deleted input attestation is invalid: {prefix}"
            )

    verify_deleted_file_attestation("flutter-settings", settings_path)
    verify_deleted_file_attestation("android-debug-keystore", debug_keystore)

    surviving_common = (
        sdk_root,
        jdk_root,
        python_runtime_root,
    )
    phases = (
        (
            "bootstrap-source-tree-guard",
            evidence / "tested-files.bootstrap.sha256",
            evidence / "bootstrap-source-tree-guard-baseline.json",
            (settings_path,),
            frozenset({settings_path}),
        ),
        (
            "source-tree-guard",
            evidence / "tested-files.pre.sha256",
            evidence / "source-tree-guard-baseline.json",
            (settings_path, gradle_distribution, debug_keystore),
            frozenset({settings_path, debug_keystore}),
        ),
    )
    for prefix, baseline, sidecar, deleted_roots, deleted_files in phases:
        ready_path = evidence / f"{prefix}-ready.json"
        result_path = evidence / f"{prefix}-result.json"
        events_path = evidence / f"{prefix}-events.jsonl"
        try:
            summary = validator.validate_completed_guard_evidence(
                result_path,
                events_path,
                ready_path,
                baseline,
                sidecar,
            )
        except Exception as error:
            raise VerificationError(
                f"{prefix} evidence failed semantic verification"
            ) from error
        if (
            set(summary)
            != {
                "status",
                "observedEventCount",
                "baselineUniqueRegularFileCount",
                "unchangedTreeVerified",
            }
            or summary.get("status") != "stopped"
            or type(summary.get("observedEventCount")) is not int
            or summary["observedEventCount"] < 0
            or type(summary.get("baselineUniqueRegularFileCount")) is not int
            or summary["baselineUniqueRegularFileCount"] <= 0
            or summary.get("unchangedTreeVerified") is not True
        ):
            raise VerificationError(f"{prefix} verified summary is invalid")

        ready = _load_json(ready_path)
        try:
            plan = source_guard.build_watch_plan(
                app_root,
                surviving_common,
                expected_flutter_root=flutter_root,
            )
            expected_watch = source_guard._compact_roots(
                (*plan.watch_paths, *deleted_roots)
            )
            expected_watch_paths = [str(path) for path in expected_watch]
            expected_native_roots = [
                str(path)
                for path in source_guard._compact_roots(
                    (path.parent if path in deleted_files or path.is_file() else path)
                    for path in expected_watch
                )
            ]
        except (OSError, RuntimeError, TypeError, ValueError) as error:
            raise VerificationError(
                f"{prefix} watch plan could not be recomputed"
            ) from error
        if (
            ready.get("watchPaths") != expected_watch_paths
            or ready.get("nativeFSEventsWatchRoots") != expected_native_roots
            or any(
                sidecar == watched or _is_within(sidecar, Path(watched))
                for watched in expected_watch_paths
            )
        ):
            raise VerificationError(f"{prefix} watch plan is incomplete")

        preservation = _load_json(evidence / f"{prefix}-ledger-preservation.json")
        if (
            set(preservation) != {"version", "status", "destination", "bytes", "sha256"}
            or preservation.get("version") != 1
            or preservation.get("status") != "preserved"
            or preservation.get("destination") != str(events_path)
            or type(preservation.get("bytes")) is not int
            or preservation["bytes"] != events_path.stat().st_size
            or preservation.get("sha256") != _sha256_file(events_path, private=True)
        ):
            raise VerificationError(f"{prefix} ledger preservation is invalid")


def _verify_final_scope(
    evidence: Path,
    result: dict[str, Any],
    prepared: dict[str, Any],
    preflight: Any,
) -> None:
    cleanup_paths = sorted(evidence.glob("gradle-process-scope-cleanup-*.json"))
    if len(cleanup_paths) != 1:
        raise VerificationError("final process-scope cleanup evidence is not unique")
    cleanup = cleanup_paths[0]
    if _sha256_file(cleanup, private=True) != result["processScopeCleanupSha256"]:
        raise VerificationError("final process-scope cleanup digest mismatch")
    scope = _load_json(cleanup)
    inspection = scope.get("referenceInspection")
    expected_roots = {
        "gradleUserHome": prepared["paths"]["gradle_home"],
        "isolatedUserRoot": prepared["paths"]["isolated_root"],
        "home": str(Path(prepared["paths"]["isolated_root"]) / "home"),
        "sandboxRunTemp": prepared["paths"]["run_temp"],
        "kotlinProjectPersistentDir": str(
            Path(prepared["paths"]["run_temp"]) / "kotlin-project-persistent"
        ),
        "kotlinDaemonRunFilesDir": str(
            Path(prepared["paths"]["run_temp"]) / "kotlin-daemon"
        ),
    }
    owner = scope.get("ownerRoot")
    authorities = scope.get("authorities")
    if (
        set(scope) != AUDIT_SCOPE_KEYS
        or scope.get("version") != 3
        or scope.get("status") != "quiescent"
        or scope.get("mode") != "audit-only"
        or scope.get("marker") != "TELLTALE_GATE_C_PROCESS_SCOPE_AUDIT"
        or not preflight._valid_identity(owner)
        or scope.get("roots") != expected_roots
        or not isinstance(authorities, list)
        or not authorities
        or scope.get("referenceAuthorities") != []
        or scope.get("authorizedSessions") != []
        or type(scope.get("startedMonotonicNs")) is not int
        or type(scope.get("endedMonotonicNs")) is not int
        or scope["endedMonotonicNs"] < scope["startedMonotonicNs"]
        or scope.get("remainingOwnedProcesses") != []
        or any(
            scope.get(field) != []
            for field in (
                "stoppedProcesses",
                "termSentProcesses",
                "killSentProcesses",
            )
        )
        or scope.get("foreignProcesses") != []
        or scope.get("referenceExemptProcesses") != []
        or scope.get("inspectionLimitations") != []
        or not isinstance(inspection, dict)
        or set(inspection) != {"complete", "lsof", "fallbackProcesses"}
        or inspection.get("complete") is not True
        or not isinstance(inspection.get("lsof"), dict)
        or not isinstance(inspection.get("fallbackProcesses"), list)
    ):
        raise VerificationError(
            "final process-scope cleanup is not exact and quiescent"
        )

    wrapper = prepared["components"]["wrapper"]
    authority_paths: list[Path] = []
    for entry in authorities:
        if (
            not isinstance(entry, dict)
            or set(entry) != {"path", "sha256", "launchId"}
            or not isinstance(entry.get("sha256"), str)
            or SHA256_RE.fullmatch(entry["sha256"]) is None
            or not isinstance(entry.get("launchId"), str)
            or re.fullmatch(r"[0-9a-f]{32}", entry["launchId"]) is None
        ):
            raise VerificationError("final process-scope authority entry is invalid")
        path = _canonical_path_text(entry["path"], "final process-scope authority")
        if (
            not _is_within(path, evidence)
            or not path.name.endswith(".process-authority.json")
            or _sha256_file(path, private=True) != entry["sha256"]
        ):
            raise VerificationError("final process-scope authority seal is invalid")
        authority = _load_json(path)
        leader = authority.get("leader")
        supervisor = authority.get("supervisor")
        leader_identity = cast(dict[str, Any], leader)
        supervisor_identity = cast(dict[str, Any], supervisor)
        cwd = _canonical_path_text(authority.get("cwd"), "authority cwd")
        if (
            set(authority) != preflight.AUTHORITY_KEYS
            or authority.get("version") != 2
            or authority.get("launchId") != entry["launchId"]
            or authority.get("ownerRoot") != owner
            or not preflight._valid_identity(supervisor)
            or not preflight._valid_identity(leader)
            or leader_identity["pid"] != leader_identity["pgid"]
            or leader_identity["pid"] != leader_identity["sid"]
            or leader_identity["ppid"] != supervisor_identity["pid"]
            or authority.get("roots") != expected_roots
            or authority.get("wrapper")
            != {"path": wrapper["path"], "sha256": wrapper["sha256"]}
            or not (
                cwd == Path(prepared["paths"]["app_root"])
                or _is_within(
                    cwd,
                    Path(prepared["paths"]["app_root"]),
                )
            )
        ):
            raise VerificationError("final process-scope authority is invalid")
        _verify_child_environment(path, authority)
        authority_paths.append(path)
    if len(authority_paths) != len(set(authority_paths)):
        raise VerificationError("final process-scope authorities are duplicate")
    expected_environment_paths = {
        _child_environment_path(path) for path in authority_paths
    }
    actual_environment_paths = {
        evidence / relative
        for relative in _walk_regular_files(evidence)
        if relative.endswith(".child-environment.json")
    }
    if actual_environment_paths != expected_environment_paths:
        raise VerificationError("child-environment evidence set is incomplete or extra")
    fallbacks = inspection["fallbackProcesses"]
    if not all(preflight._valid_identity(item) for item in fallbacks) or [
        item["pid"] for item in fallbacks
    ] != sorted({item["pid"] for item in fallbacks}):
        raise VerificationError("final process-scope fallback identities are invalid")
    try:
        preflight._validate_lsof_seal(inspection["lsof"])
    except (KeyError, TypeError, ValueError) as error:
        raise VerificationError("final process-scope lsof seal is invalid") from error


def _verify_process_scope_semantics(
    evidence: Path,
    rig_root: Path,
    prepared: dict[str, Any],
    result: dict[str, Any],
) -> None:
    tested = _parse_build_manifest(
        evidence / "tested-files.post.sha256",
        "tested tree manifest",
    )
    logical_helper = "tool/telemetry_memory_rig/outer_process_scope_validator.py"
    helper_path = rig_root / "outer_process_scope_validator.py"
    if tested.get(logical_helper) != _sha256_file(helper_path, private=False):
        raise VerificationError("tested tree does not bind process-scope validator")
    helper = _load_trusted_module(
        helper_path,
        f"telltale_outer_process_scope_{os.getpid()}",
    )
    for label in (
        "gradle-version",
        "flutter-version",
        "dart-version",
        "fixture-generator",
        "telemetry-memory-measure",
    ):
        try:
            summary = helper.validate_scoped_command(
                evidence,
                label,
                "completed",
                prepared,
                rig_root,
            )
        except Exception as error:
            raise VerificationError(
                f"required process scope failed semantic verification: {label}"
            ) from error
        if summary.get("label") != label or summary.get("status") != "completed":
            raise VerificationError(
                f"required process-scope summary is invalid: {label}"
            )
    identity = _parse_key_value_text(evidence / "identity.txt")
    if not identity.get("flutter_version") or not identity.get("dart_version"):
        raise VerificationError("sealed Flutter/Dart version output is missing")
    generator_log = _read_private_text(evidence / "fixture-generator.log")
    if (
        not any(
            "TELLTALE_MEMORY_HOST_FIXTURES_READY indexBytes=104857600" in line
            for line in generator_log.splitlines()
        )
        or re.search(r"(?m)^.*sessionBytes=2621[0-9]{4}.*$", generator_log) is None
    ):
        raise VerificationError("fixture-generator semantic proof is invalid")
    for label in ("android-toolchain-build", "android-toolchain-lint-model"):
        try:
            guarded = helper.validate_guarded_command(
                evidence,
                label,
                prepared,
                rig_root,
            )
        except Exception as error:
            raise VerificationError(
                f"guarded process scope failed semantic verification: {label}"
            ) from error
        if (
            set(guarded) != {"label", "status", "guardPid"}
            or guarded.get("label") != label
            or guarded.get("status") != "completed"
            or type(guarded.get("guardPid")) is not int
            or guarded["guardPid"] <= 1
        ):
            raise VerificationError(
                f"guarded process-scope summary is invalid: {label}"
            )
    for cut in CUTS:
        seed_phase = "realpluginmirror" if cut == "realPluginMirror" else "seed"
        commands = (
            (f"gate-{seed_phase}-{cut.lower()}", "command_failed"),
            (f"gate-recover-{cut.lower()}", "completed"),
        )
        for label, expected_status in commands:
            try:
                summary = helper.validate_scoped_command(
                    evidence,
                    label,
                    expected_status,
                    prepared,
                    rig_root,
                )
            except Exception as error:
                raise VerificationError(
                    f"Gate C process scope failed semantic verification: {label}"
                ) from error
            if (
                set(summary) != {"label", "status", "authorizedSessions"}
                or summary.get("label") != label
                or summary.get("status") != expected_status
                or not isinstance(summary.get("authorizedSessions"), list)
                or not summary["authorizedSessions"]
                or summary["authorizedSessions"]
                != sorted(set(summary["authorizedSessions"]))
                or any(
                    type(item) is not int or item <= 0
                    for item in summary["authorizedSessions"]
                )
            ):
                raise VerificationError(
                    f"Gate C process-scope summary is invalid: {label}"
                )
    try:
        final = helper.validate_final_cleanup(
            evidence,
            result,
            prepared,
            rig_root,
        )
    except Exception as error:
        raise VerificationError(
            "final process-scope cleanup failed semantic verification"
        ) from error
    if (
        set(final) != {"status", "path", "sha256", "authorizedSessions"}
        or final.get("status") != "quiescent"
        or final.get("sha256") != result["processScopeCleanupSha256"]
        or final.get("authorizedSessions") != []
    ):
        raise VerificationError("final process-scope verified summary is invalid")


def verify(
    evidence: Path,
    app_root: Path,
    python: Path,
    *,
    sandbox_exec: Path = SYSTEM_SANDBOX_EXEC,
) -> None:
    evidence = _canonical_directory(evidence, private=True)
    app_root = _canonical_directory(app_root, private=False)
    rig_root = _canonical_directory(
        app_root / "tool" / "telemetry_memory_rig", private=False
    )
    manifest_path = evidence / MANIFEST_NAME
    manifest = _parse_manifest(_read_regular(manifest_path, private=True))
    regular = _walk_regular_files(evidence)
    expected_paths = sorted(path for path in regular if path != MANIFEST_NAME)
    manifest_paths = [path for path, _ in manifest]
    if manifest_paths != expected_paths:
        raise VerificationError(
            "manifest path set does not exactly cover the evidence tree"
        )
    if RESULT_NAME not in manifest_paths:
        raise VerificationError("runner-result.json is not covered by the manifest")
    for relative, expected_digest in manifest:
        if _sha256_file(evidence / relative, private=True) != expected_digest:
            raise VerificationError(f"manifest digest mismatch: {relative}")

    result = _load_json(evidence / RESULT_NAME)
    if (
        set(result) != RESULT_KEYS
        or len(result) != 28
        or result.get("version") != 1
        or result.get("result") != "pass"
        or result.get("cleanupVerified") is not True
        or result.get("cuts") != CUTS
        or any(
            not isinstance(result.get(key), str)
            or SHA256_RE.fullmatch(result[key]) is None
            for key in SHA_KEYS
        )
    ):
        raise VerificationError("runner-result.json exact contract mismatch")
    for key, relative in SHA_EVIDENCE_PATHS.items():
        if _sha256_file(evidence / relative, private=True) != result[key]:
            raise VerificationError(f"runner-result evidence digest mismatch: {key}")
    python = _canonical_regular(python, private=False)
    if _sha256_file(python, private=False) != result["pythonExecutableSha256"]:
        raise VerificationError("runner-result Python executable digest mismatch")
    for key, relative in SHA_COMPONENT_PATHS.items():
        if _sha256_file(rig_root / relative, private=False) != result[key]:
            raise VerificationError(f"runner-result component digest mismatch: {key}")
    sandbox_exec = _canonical_regular(sandbox_exec, private=False)
    if (
        _sha256_file(sandbox_exec, private=False)
        != result["androidSdkSandboxExecSha256"]
    ):
        raise VerificationError(
            "runner-result system sandbox-exec digest mismatch: "
            "androidSdkSandboxExecSha256"
        )

    prepared, preflight = _verify_sandbox_semantics(
        evidence,
        app_root,
        rig_root,
        python,
        sandbox_exec,
        result,
    )
    _verify_equal_evidence_pairs(evidence)
    _verify_tested_tree_and_summary(evidence, app_root, rig_root, prepared)
    _verify_gate_cut_semantics(evidence, rig_root)
    _verify_process_scope_semantics(evidence, rig_root, prepared, result)
    _verify_cleanup_and_toolchain_semantics(evidence, prepared, rig_root)
    _verify_source_guard_semantics(evidence, rig_root, prepared)
    _verify_final_scope(evidence, result, prepared, preflight)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--app-root", type=Path, required=True)
    parser.add_argument("--python", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        verify(args.evidence, args.app_root, args.python)
    except (OSError, VerificationError) as error:
        print(f"outer Gate C result verification failed: {error}", file=sys.stderr)
        return 1
    print("outer_gate_result_verified=true")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
