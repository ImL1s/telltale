#!/usr/bin/env python3
"""Prepare and verify fail-closed Android SDK write-sandbox evidence."""

from __future__ import annotations

import argparse
import base64
import ctypes
import hashlib
import hmac
import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from typing import Any


SYSTEM_SANDBOX_EXEC = pathlib.Path("/usr/bin/sandbox-exec")
ENV_PREFIX = "TELLTALE_GATE_C_SANDBOX_"
FINGERPRINT_KEYS = frozenset(
    {
        "path",
        "sha256",
        "size",
        "mode",
        "uid",
        "gid",
        "nlink",
        "device",
        "inode",
        "mtimeNs",
        "ctimeNs",
        "xattrs",
    }
)
PATH_KEYS = frozenset(
    {
        "app_root",
        "flutter_root",
        "pub_cache",
        "gradle_home",
        "isolated_root",
        "run_temp",
        "android_sdk_root",
        "host_home",
    }
)
COMPONENT_KEYS = frozenset(
    {"profile", "wrapper", "probe", "python", "processScope", "scopedCommand"}
)
SESSION_PROOF_KEYS = frozenset(
    {"authority", "environment", "scope", "result", "referenceAuthorities"}
)
PREPARED_KEYS = frozenset(
    {
        "version",
        "status",
        "paths",
        "components",
        "sandboxExec",
        "androidSdk",
        "probe",
        "sessionProof",
    }
)
IDENTITY_KEYS = frozenset(
    {"pid", "ppid", "pgid", "sid", "uid", "startSec", "startUsec"}
)
AUTHORITY_KEYS = frozenset(
    {
        "version",
        "launchId",
        "ownerRoot",
        "supervisor",
        "leader",
        "wrapper",
        "roots",
        "cwd",
    }
)
REFERENCE_AUTHORITY_KEYS = frozenset(
    {
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
)
PROCESS_RECORD_KEYS = frozenset(
    {
        "identity",
        "state",
        "executable",
        "argv",
        "environmentSha256",
        "cwd",
        "root",
        "openVnodePaths",
        "inspectionErrors",
        "vnodeEvidenceMethod",
        "vnodeEvidenceComplete",
    }
)
SCOPE_KEYS = frozenset(
    {
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
)
SCOPED_RESULT_KEYS = frozenset(
    {
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
)
CHILD_ENVIRONMENT_KEYS = frozenset(
    {
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
)
CHILD_ENVIRONMENT_SCHEMA = "telltale-gate-c-child-environment-names-v2"
CHILD_ENVIRONMENT_ALLOWED_NAMES = frozenset(
    {
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
)
CHILD_ENVIRONMENT_RUNTIME_NAMES = frozenset(
    {
        "TELLTALE_GATE_C_PROCESS_SCOPE",
        "TELLTALE_GATE_C_LAUNCH_RELEASE_FD",
        "TELLTALE_GATE_C_LAUNCH_READY_FD",
    }
)
CHILD_ENVIRONMENT_CREDENTIAL_NAMES = frozenset(
    {"ARBITRARY_SECRET", "HF_TOKEN", "OP_SERVICE_ACCOUNT_TOKEN", "SSH_AUTH_SOCK"}
)
ENVIRONMENT_NAME_PATTERN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
AUTHORITY_ROOT_KEYS = frozenset(
    {
        "gradleUserHome",
        "isolatedUserRoot",
        "home",
        "sandboxRunTemp",
        "kotlinProjectPersistentDir",
        "kotlinDaemonRunFilesDir",
    }
)
LSOF_SEAL_KEYS = frozenset(
    {
        "path",
        "sha256",
        "device",
        "inode",
        "size",
        "mtimeNs",
        "mode",
        "uid",
        "gid",
        "nlink",
        "codesignVerified",
        "identifier",
        "cdhash",
        "authorities",
        "designatedRequirement",
    }
)


class _DuplicateJsonKeyError(ValueError):
    """Raised when evidence JSON contains an ambiguous object member."""


def _reject_duplicate_json_keys(
    pairs: list[tuple[str, Any]],
) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise _DuplicateJsonKeyError(f"duplicate key: {key!r}")
        value[key] = item
    return value


def _decode_evidence_json(payload: bytes | str, label: str) -> Any:
    """Decode evidence JSON while rejecting duplicate keys at every depth."""
    try:
        return json.loads(payload, object_pairs_hook=_reject_duplicate_json_keys)
    except (
        json.JSONDecodeError,
        UnicodeDecodeError,
        _DuplicateJsonKeyError,
    ) as error:
        raise ValueError(f"{label} JSON is invalid: {error}") from error


def _absolute(path: pathlib.Path, label: str) -> pathlib.Path:
    text = os.fspath(path)
    if not text or any(
        ord(character) < 32 or ord(character) == 127 for character in text
    ):
        raise ValueError(f"empty or control character in {label}: {text!r}")
    lexical = pathlib.Path(os.path.abspath(text))
    try:
        if stat.S_ISLNK(lexical.lstat().st_mode):
            raise ValueError(f"symlink in {label}: {lexical}")
    except FileNotFoundError:
        pass
    # macOS exposes /var and /tmp through system-owned compatibility symlinks.
    # Canonicalize those before checking the remaining component chain.
    return pathlib.Path(os.path.realpath(lexical))


def _reject_symlink_chain(path: pathlib.Path, label: str) -> None:
    current = pathlib.Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        metadata = current.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise ValueError(f"symlink in {label}: {current}")


def validate_directory(path: pathlib.Path, label: str) -> pathlib.Path:
    absolute = _absolute(path, label)
    _reject_symlink_chain(absolute, label)
    metadata = absolute.lstat()
    if not stat.S_ISDIR(metadata.st_mode):
        raise ValueError(f"{label} is not a directory: {absolute}")
    if stat.S_IMODE(metadata.st_mode) & 0o022:
        raise ValueError(f"group/world-writable {label}: {absolute}")
    return absolute


def validate_regular_file(path: pathlib.Path, label: str) -> pathlib.Path:
    absolute = _absolute(path, label)
    _reject_symlink_chain(absolute, label)
    metadata = absolute.lstat()
    if not stat.S_ISREG(metadata.st_mode):
        raise ValueError(f"{label} is not a regular file: {absolute}")
    if metadata.st_nlink != 1:
        raise ValueError(f"hardlinked {label}: {absolute}")
    if stat.S_IMODE(metadata.st_mode) & 0o022:
        raise ValueError(f"group/world-writable {label}: {absolute}")
    return absolute


def validate_executable(path: pathlib.Path, label: str) -> pathlib.Path:
    absolute = validate_regular_file(path, label)
    if not os.access(absolute, os.X_OK):
        raise ValueError(f"{label} is not executable: {absolute}")
    return absolute


def validate_read_only_root(
    protected_root: pathlib.Path,
    label: str,
    write_roots: list[pathlib.Path],
) -> None:
    protected_text = os.path.realpath(protected_root)
    for fixed in ("/private/tmp", "/dev"):
        fixed_text = os.path.realpath(fixed)
        if os.path.commonpath((protected_text, fixed_text)) in {
            protected_text,
            fixed_text,
        }:
            raise ValueError(
                f"{label} overlaps profile write root: {protected_root} and {fixed}"
            )
    for root in write_roots:
        root_text = os.path.realpath(root)
        common = os.path.commonpath((protected_text, root_text))
        if common in {protected_text, root_text}:
            raise ValueError(
                f"{label} overlaps write root: {protected_root} and {root}"
            )


def validate_disjoint_sdk(
    sdk_root: pathlib.Path, write_roots: list[pathlib.Path]
) -> None:
    validate_read_only_root(sdk_root, "Android SDK", write_roots)


def file_fingerprint(path: pathlib.Path) -> dict[str, Any]:
    absolute = validate_regular_file(path, "fingerprinted file")
    metadata = absolute.lstat()
    xattrs = []
    for name, value in _xattrs(absolute):
        xattrs.append(
            {"name": name, "valueBase64": base64.b64encode(value).decode("ascii")}
        )
    return {
        "path": os.fspath(absolute),
        "sha256": hashlib.sha256(absolute.read_bytes()).hexdigest(),
        "size": metadata.st_size,
        "mode": stat.S_IMODE(metadata.st_mode),
        "uid": metadata.st_uid,
        "gid": metadata.st_gid,
        "nlink": metadata.st_nlink,
        "device": metadata.st_dev,
        "inode": metadata.st_ino,
        "mtimeNs": metadata.st_mtime_ns,
        "ctimeNs": metadata.st_ctime_ns,
        "xattrs": xattrs,
    }


def child_environment_evidence_path(authority_path: pathlib.Path) -> pathlib.Path:
    suffix = ".process-authority.json"
    if authority_path.name.endswith(suffix):
        name = authority_path.name[: -len(suffix)] + ".child-environment.json"
    else:
        name = authority_path.name + ".child-environment.json"
    return authority_path.with_name(name)


def _canonical_json_sha256(value: object) -> str:
    payload = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(payload).hexdigest()


def validate_child_environment_evidence(
    authority_path: pathlib.Path,
    launch_id: str,
) -> pathlib.Path:
    path = validate_regular_file(
        child_environment_evidence_path(authority_path),
        "child-environment evidence",
    )
    metadata = path.lstat()
    if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o600:
        raise ValueError("child-environment evidence is not private and owner-bound")
    value = _decode_evidence_json(path.read_bytes(), "child-environment evidence")
    if not isinstance(value, dict) or set(value) != CHILD_ENVIRONMENT_KEYS:
        raise ValueError("child-environment evidence schema is invalid")
    allowed_names = value.get("allowedNames")
    actual_names = value.get("actualNames")
    if (
        not isinstance(actual_names, list)
        or any(
            not isinstance(name, str)
            or ENVIRONMENT_NAME_PATTERN.fullmatch(name) is None
            for name in actual_names
        )
        or actual_names != sorted(set(actual_names))
    ):
        raise ValueError("child-environment actual names are invalid")
    if (
        value.get("schema") != CHILD_ENVIRONMENT_SCHEMA
        or value.get("version") != 2
        or value.get("launchId") != launch_id
        or allowed_names != sorted(CHILD_ENVIRONMENT_ALLOWED_NAMES)
        or not set(actual_names).issubset(CHILD_ENVIRONMENT_ALLOWED_NAMES)
        or not CHILD_ENVIRONMENT_RUNTIME_NAMES.issubset(actual_names)
        or value.get("allowedNamesSha256") != _canonical_json_sha256(allowed_names)
        or value.get("actualNamesSha256") != _canonical_json_sha256(actual_names)
        or value.get("actualNamesObservationPoint")
        != "cooperative-sealed-wrapper-pre-release-barrier-v1"
        or re.fullmatch(
            r"[0-9a-f]{64}", value.get("producerPlannedEnvironmentValuesSha256", "")
        )
        is None
        or value.get("plannedNamesMatchBarrier") is not True
        or value.get("valuesObserved") is not False
        or value.get("postBarrierAddedNames")
        != ["FLUTTER_ALREADY_LOCKED", "JAVA_TOOL_OPTIONS", "TMPDIR"]
        or value.get("credentialNamesAssertedAbsent")
        != sorted(CHILD_ENVIRONMENT_CREDENTIAL_NAMES)
        or value.get("forbiddenCredentialNamesPresent") != []
    ):
        raise ValueError("child-environment evidence binding is invalid")
    return path


def _xattrs(path: pathlib.Path) -> list[tuple[str, bytes]]:
    """Read macOS xattrs without depending on optional Python os bindings."""
    libc = ctypes.CDLL(None, use_errno=True)
    libc.listxattr.argtypes = [
        ctypes.c_char_p,
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.c_int,
    ]
    libc.listxattr.restype = ctypes.c_ssize_t
    libc.getxattr.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.c_uint32,
        ctypes.c_int,
    ]
    libc.getxattr.restype = ctypes.c_ssize_t
    encoded = os.fsencode(path)
    size = libc.listxattr(encoded, None, 0, 0)
    if size < 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), path)
    if size == 0:
        return []
    names_buffer = ctypes.create_string_buffer(size)
    actual = libc.listxattr(encoded, names_buffer, size, 0)
    if actual < 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), path)
    names = sorted(name for name in names_buffer.raw[:actual].split(b"\0") if name)
    values: list[tuple[str, bytes]] = []
    for name in names:
        value_size = libc.getxattr(encoded, name, None, 0, 0, 0)
        if value_size < 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error), path)
        value_buffer = ctypes.create_string_buffer(value_size)
        if value_size:
            value_actual = libc.getxattr(encoded, name, value_buffer, value_size, 0, 0)
            if value_actual < 0:
                error = ctypes.get_errno()
                raise OSError(error, os.strerror(error), path)
            value = value_buffer.raw[:value_actual]
        else:
            value = b""
        values.append((os.fsdecode(name), value))
    return values


def write_evidence(path: pathlib.Path, value: dict[str, Any]) -> None:
    absolute = _absolute(path, "evidence output")
    parent = validate_directory(absolute.parent, "evidence output parent")
    payload = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
    descriptor = os.open(absolute, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(descriptor, payload)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    directory = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
    if absolute.read_bytes() != payload:
        raise ValueError(f"evidence reread mismatch: {absolute}")


def read_prepared_evidence(
    path: pathlib.Path,
    expected_sha256: str,
) -> dict[str, Any]:
    """Authenticate the exact prepared bytes before decoding any JSON."""
    prepared_path = validate_regular_file(path, "prepared evidence")
    if re.fullmatch(r"[0-9a-f]{64}", expected_sha256) is None:
        raise ValueError("prepared evidence expected digest is invalid")
    prepared_bytes = prepared_path.read_bytes()
    actual_sha256 = hashlib.sha256(prepared_bytes).hexdigest()
    if not hmac.compare_digest(actual_sha256, expected_sha256):
        raise ValueError("prepared evidence digest mismatch")
    prepared = _decode_evidence_json(prepared_bytes, "prepared evidence")
    if not isinstance(prepared, dict):
        raise ValueError("prepared evidence JSON is not an object")
    if set(prepared) != PREPARED_KEYS:
        raise ValueError("prepared evidence schema is invalid")
    prepared["evidenceSha256"] = expected_sha256
    return prepared


def codesign_identity(binary: pathlib.Path) -> dict[str, Any]:
    fingerprint = file_fingerprint(binary)
    verify = subprocess.run(
        [
            "/usr/bin/codesign",
            "--verify",
            "--strict",
            "--test-requirement",
            '=identifier "com.apple.sandbox-exec" and anchor apple',
            "--verbose=4",
            os.fspath(binary),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if verify.returncode != 0:
        raise ValueError(
            f"sandbox-exec code signature verification failed: {verify.stderr}"
        )
    display = subprocess.run(
        ["/usr/bin/codesign", "-d", "--verbose=4", os.fspath(binary)],
        capture_output=True,
        text=True,
        check=False,
    )
    details = display.stdout + display.stderr
    identifier = re.search(r"(?m)^Identifier=(\S+)$", details)
    cd_hash = re.search(r"(?m)^CDHash=(\S+)$", details)
    if display.returncode != 0 or identifier is None or cd_hash is None:
        raise ValueError("sandbox-exec signature lacks Identifier or CDHash")
    if identifier.group(1) != "com.apple.sandbox-exec":
        raise ValueError(
            f"sandbox-exec has unexpected identifier: {identifier.group(1)}"
        )
    return {
        **fingerprint,
        "verified": True,
        "identifier": identifier.group(1),
        "cdHash": cd_hash.group(1),
    }


def _component_fingerprints(
    paths: dict[str, pathlib.Path],
) -> dict[str, dict[str, Any]]:
    return {name: file_fingerprint(path) for name, path in sorted(paths.items())}


def _same_fingerprint(
    expected: dict[str, Any],
    label: str,
    *,
    extra_keys: frozenset[str] = frozenset(),
) -> None:
    if not isinstance(expected, dict) or set(expected) != FINGERPRINT_KEYS | extra_keys:
        raise ValueError(f"{label} fingerprint schema is invalid")
    actual = file_fingerprint(pathlib.Path(expected["path"]))
    expected_fingerprint = {key: expected[key] for key in FINGERPRINT_KEYS}
    if actual != expected_fingerprint:
        raise ValueError(f"{label}: {expected['path']}")


def _valid_identity(value: object) -> bool:
    return (
        isinstance(value, dict)
        and set(value) == IDENTITY_KEYS
        and all(type(value[key]) is int for key in IDENTITY_KEYS)
        and value["uid"] == os.getuid()
        and value["ppid"] >= 0
        and 0 <= value["startUsec"] <= 999_999
        and min(
            value["pid"],
            value["pgid"],
            value["sid"],
            value["uid"] + 1,
            value["startSec"],
            value["startUsec"] + 1,
        )
        > 0
    )


def _valid_process_record(value: object) -> bool:
    return (
        isinstance(value, dict)
        and set(value) == PROCESS_RECORD_KEYS
        and _valid_identity(value.get("identity"))
        and type(value.get("state")) is int
        and isinstance(value.get("executable"), str)
        and isinstance(value.get("argv"), list)
        and all(isinstance(item, str) for item in value["argv"])
        and re.fullmatch(r"[0-9a-f]{64}", value.get("environmentSha256", ""))
        is not None
        and (value.get("cwd") is None or isinstance(value["cwd"], str))
        and (value.get("root") is None or isinstance(value["root"], str))
        and isinstance(value.get("openVnodePaths"), list)
        and all(
            isinstance(item, str) and item.startswith("/")
            for item in value["openVnodePaths"]
        )
        and value.get("inspectionErrors") == []
        and value.get("vnodeEvidenceMethod") in {"libproc", "sealed-lsof"}
        and value.get("vnodeEvidenceComplete") is True
    )


def _validate_lsof_seal(value: object) -> None:
    if (
        not isinstance(value, dict)
        or set(value) != LSOF_SEAL_KEYS
        or value.get("path") != "/usr/sbin/lsof"
        or re.fullmatch(r"[0-9a-f]{64}", value.get("sha256", "")) is None
        or any(
            type(value.get(key)) is not int
            for key in (
                "device",
                "inode",
                "size",
                "mtimeNs",
                "mode",
                "uid",
                "gid",
                "nlink",
            )
        )
        or value.get("mode") != 0o755
        or value.get("uid") != 0
        or value.get("nlink") != 1
        or value.get("codesignVerified") is not True
        or value.get("identifier") != "com.apple.lsof"
        or re.fullmatch(r"[0-9a-f]{40}", value.get("cdhash", "")) is None
        or value.get("authorities")
        != [
            "macOS Software Signing",
            "Apple Code Signing Certification Authority",
            "Apple Root CA",
        ]
        or value.get("designatedRequirement")
        != 'identifier "com.apple.lsof" and anchor apple'
    ):
        raise ValueError("process-scope lsof seal is invalid")


def validate_session_result(
    *,
    authority_path: pathlib.Path,
    scope_path: pathlib.Path,
    result_path: pathlib.Path,
    roots: dict[str, pathlib.Path],
    components: dict[str, pathlib.Path],
    owner_root_pid: int,
    reference_authority_paths: list[pathlib.Path],
) -> None:
    authority_bytes = authority_path.read_bytes()
    scope_bytes = scope_path.read_bytes()
    authority = _decode_evidence_json(authority_bytes, "sandbox probe authority")
    scope = _decode_evidence_json(scope_bytes, "sandbox probe process-scope")
    result = _decode_evidence_json(
        result_path.read_bytes(),
        "sandbox probe scoped-command result",
    )
    expected_roots = {
        "gradleUserHome": os.fspath(roots["gradle_home"]),
        "isolatedUserRoot": os.fspath(roots["isolated_root"]),
        "home": os.fspath(roots["isolated_root"] / "home"),
        "sandboxRunTemp": os.fspath(roots["run_temp"]),
        "kotlinProjectPersistentDir": os.fspath(
            roots["run_temp"] / "kotlin-project-persistent"
        ),
        "kotlinDaemonRunFilesDir": os.fspath(roots["run_temp"] / "kotlin-daemon"),
    }
    if (
        not isinstance(authority, dict)
        or set(authority) != AUTHORITY_KEYS
        or authority.get("version") != 2
        or re.fullmatch(r"[0-9a-f]{32}", authority.get("launchId", "")) is None
        or not _valid_identity(authority.get("ownerRoot"))
        or not _valid_identity(authority.get("supervisor"))
        or not _valid_identity(authority.get("leader"))
        or authority["ownerRoot"]["pid"] != owner_root_pid
        or authority["leader"]["pid"] != authority["leader"]["pgid"]
        or authority["leader"]["pid"] != authority["leader"]["sid"]
        or authority["leader"]["ppid"] != authority["supervisor"]["pid"]
        or authority.get("wrapper")
        != {
            "path": os.fspath(components["wrapper"]),
            "sha256": hashlib.sha256(components["wrapper"].read_bytes()).hexdigest(),
        }
        or set(authority.get("roots", {})) != AUTHORITY_ROOT_KEYS
        or authority.get("roots") != expected_roots
        or authority.get("cwd") != os.fspath(roots["app_root"])
    ):
        raise ValueError("sandbox probe authority is invalid")
    validate_child_environment_evidence(authority_path, authority["launchId"])
    authority_entry = {
        "path": os.fspath(authority_path),
        "sha256": hashlib.sha256(authority_bytes).hexdigest(),
        "launchId": authority["launchId"],
    }
    reference_authorities: list[dict[str, Any]] = []
    reference_entries: list[dict[str, str]] = []
    for reference_path in reference_authority_paths:
        evidence_dir = authority_path.parent
        expected_reference_path = (
            evidence_dir
            / "process-scope-reference-authorities"
            / "bootstrap-source-guard.reference-authority.json"
        )
        if reference_path != expected_reference_path:
            raise ValueError("sandbox probe reference authority path is invalid")
        reference_bytes = reference_path.read_bytes()
        reference = _decode_evidence_json(
            reference_bytes,
            "sandbox probe reference authority",
        )
        if (
            not isinstance(reference, dict)
            or set(reference) != REFERENCE_AUTHORITY_KEYS
            or reference.get("version") != 1
            or reference.get("kind") != "source-guard-reference-exemption"
            or re.fullmatch(r"[0-9a-f]{32}", reference.get("exemptionId", "")) is None
            or not _valid_identity(reference.get("ownerRoot"))
            or not _valid_identity(reference.get("subject"))
            or reference["ownerRoot"] != authority["ownerRoot"]
            or reference["ownerRoot"]["pid"] != owner_root_pid
            or reference["subject"]["ppid"] != owner_root_pid
            or reference["subject"]["sid"] == authority["leader"]["sid"]
            or reference.get("roots") != expected_roots
            or set(reference.get("roots", {})) != AUTHORITY_ROOT_KEYS
            or not isinstance(reference.get("allowedRootKeys"), list)
            or not reference["allowedRootKeys"]
            or reference["allowedRootKeys"] != sorted(set(reference["allowedRootKeys"]))
            or not set(reference["allowedRootKeys"]).issubset(AUTHORITY_ROOT_KEYS)
        ):
            raise ValueError("sandbox probe reference authority is invalid")
        for key in ("executable", "program"):
            seal = reference.get(key)
            if (
                not isinstance(seal, dict)
                or set(seal) != {"path", "sha256"}
                or re.fullmatch(r"[0-9a-f]{64}", seal.get("sha256", "")) is None
                or pathlib.Path(seal.get("path", "")).resolve(strict=True)
                != pathlib.Path(seal["path"])
                or hashlib.sha256(pathlib.Path(seal["path"]).read_bytes()).hexdigest()
                != seal["sha256"]
            ):
                raise ValueError(f"sandbox probe reference {key} seal is invalid")
        expected_program = components["processScope"].parent / "source_tree_guard.py"
        if reference["executable"] != {
            "path": os.fspath(components["python"]),
            "sha256": hashlib.sha256(components["python"].read_bytes()).hexdigest(),
        } or reference["program"] != {
            "path": os.fspath(expected_program),
            "sha256": hashlib.sha256(expected_program.read_bytes()).hexdigest(),
        }:
            raise ValueError(
                "sandbox probe reference executable or program is untrusted"
            )
        readiness = reference.get("readiness")
        expected_ready = evidence_dir / "bootstrap-source-tree-guard-ready.json"
        expected_stop = evidence_dir / "bootstrap-source-tree-guard.stop"
        expected_result = evidence_dir / "bootstrap-source-tree-guard-result.json"
        if (
            not isinstance(readiness, dict)
            or set(readiness) != {"path", "sha256", "nonce", "stopPath", "resultPath"}
            or re.fullmatch(r"[0-9a-f]{64}", readiness.get("sha256", "")) is None
            or re.fullmatch(r"[0-9a-f]{32}", readiness.get("nonce", "")) is None
            or readiness.get("path") != os.fspath(expected_ready)
            or readiness.get("stopPath") != os.fspath(expected_stop)
            or readiness.get("resultPath") != os.fspath(expected_result)
            or hashlib.sha256(
                pathlib.Path(readiness.get("path", "")).read_bytes()
            ).hexdigest()
            != readiness["sha256"]
        ):
            raise ValueError("sandbox probe reference readiness is invalid")
        ready = _decode_evidence_json(
            pathlib.Path(readiness["path"]).read_bytes(),
            "sandbox probe reference readiness",
        )
        if (
            not isinstance(ready, dict)
            or ready.get("pid") != reference["subject"]["pid"]
            or ready.get("nonce") != readiness["nonce"]
        ):
            raise ValueError("sandbox probe reference readiness binding is invalid")
        argv = reference.get("argv")
        if (
            not isinstance(argv, list)
            or any(not isinstance(item, str) or "\0" in item for item in argv)
            or argv[0] != reference["executable"]["path"]
            or argv[1:4] != ["-I", "-S", "-B"]
            or argv[4] != reference["program"]["path"]
        ):
            raise ValueError("sandbox probe reference argv is invalid")
        isolated_root = roots["isolated_root"]
        expected_settings = isolated_root / "xdg-config" / "settings"
        expected_events = isolated_root / "bootstrap-source-tree-guard-events.jsonl"
        expected_baseline = evidence_dir / "tested-files.bootstrap.sha256"
        expected_sidecar = evidence_dir / "bootstrap-source-tree-guard-baseline.json"
        # The preflight interface does not separately carry the JDK root.  Bind its
        # producer slot to a canonical extant path, then seal the complete ordered
        # command around it.  All other option values are independently derived.
        jdk_index = 12
        if len(argv) <= jdk_index:
            raise ValueError("sandbox probe reference argv is incomplete")
        try:
            jdk_root = pathlib.Path(argv[jdk_index]).resolve(strict=True)
        except (OSError, RuntimeError, ValueError) as error:
            raise ValueError("sandbox probe reference JDK root is invalid") from error
        if os.fspath(jdk_root) != argv[jdk_index]:
            raise ValueError("sandbox probe reference JDK root is not canonical")
        exact_argv = [
            reference["executable"]["path"],
            "-I",
            "-S",
            "-B",
            reference["program"]["path"],
            "--root",
            os.fspath(roots["app_root"]),
            "--expected-flutter-root",
            os.fspath(roots["flutter_root"]),
            "--toolchain-root",
            os.fspath(roots["android_sdk_root"]),
            "--toolchain-root",
            os.fspath(jdk_root),
            "--toolchain-root",
            os.fspath(expected_settings),
            "--toolchain-root",
            os.fspath(pathlib.Path(sys.base_prefix).resolve(strict=True)),
            "--backend",
            "darwin-fsevents",
            "--stop-file",
            os.fspath(expected_stop),
            "--ready-file",
            os.fspath(expected_ready),
            "--events-file",
            os.fspath(expected_events),
            "--result-file",
            os.fspath(expected_result),
            "--baseline-manifest",
            os.fspath(expected_baseline),
            "--baseline-sidecar",
            os.fspath(expected_sidecar),
            "--nonce",
            readiness["nonce"],
        ]
        if argv != exact_argv:
            raise ValueError(
                "sandbox probe reference argv is not the exact producer command"
            )
        reference_authorities.append(reference)
        reference_entries.append(
            {
                "path": os.fspath(reference_path),
                "sha256": hashlib.sha256(reference_bytes).hexdigest(),
                "exemptionId": reference["exemptionId"],
            }
        )
    if not isinstance(scope, dict) or set(scope) != SCOPE_KEYS:
        raise ValueError("sandbox probe process-scope schema is invalid")
    for field in ("stoppedProcesses", "termSentProcesses", "killSentProcesses"):
        records = scope.get(field)
        if (
            not isinstance(records, list)
            or not all(_valid_process_record(item) for item in records)
            or [item["identity"]["pid"] for item in records]
            != sorted({item["identity"]["pid"] for item in records})
        ):
            raise ValueError(f"sandbox probe process records are invalid: {field}")
    authorized_sessions = {authority["leader"]["sid"]}
    stopped_by_pid = {
        item["identity"]["pid"]: item for item in scope["stoppedProcesses"]
    }
    term_by_pid = {item["identity"]["pid"]: item for item in scope["termSentProcesses"]}
    if any(
        item["identity"]["uid"] != os.getuid()
        or item["identity"]["sid"] not in authorized_sessions
        for field in ("stoppedProcesses", "termSentProcesses", "killSentProcesses")
        for item in scope[field]
    ):
        raise ValueError("sandbox probe process record session is unauthorized")
    if any(stopped_by_pid.get(pid) != record for pid, record in term_by_pid.items()):
        raise ValueError("sandbox probe TERM records are not stopped-record subsets")
    inspection = scope.get("referenceInspection")
    if (
        scope.get("version") != 3
        or scope.get("status") != "quiescent"
        or scope.get("marker") != "TELLTALE_GATE_C_PROCESS_SCOPE"
        or scope.get("ownerRoot") != authority["ownerRoot"]
        or scope.get("roots") != expected_roots
        or scope.get("authorities") != [authority_entry]
        or scope.get("referenceAuthorities") != reference_entries
        or scope.get("authorizedSessions") != [authority["leader"]["sid"]]
        or type(scope.get("startedMonotonicNs")) is not int
        or type(scope.get("endedMonotonicNs")) is not int
        or scope["endedMonotonicNs"] < scope["startedMonotonicNs"]
        or scope.get("remainingOwnedProcesses") != []
        or scope.get("foreignProcesses") != []
        or scope.get("inspectionLimitations") != []
        or not isinstance(inspection, dict)
        or set(inspection) != {"complete", "lsof", "fallbackProcesses"}
        or inspection.get("complete") is not True
        or not isinstance(inspection.get("fallbackProcesses"), list)
        or not all(_valid_identity(item) for item in inspection["fallbackProcesses"])
        or [item["pid"] for item in inspection["fallbackProcesses"]]
        != sorted({item["pid"] for item in inspection["fallbackProcesses"]})
    ):
        raise ValueError("sandbox probe process-scope binding is invalid")
    exempt_processes = scope.get("referenceExemptProcesses")
    expected_subjects = {
        reference["exemptionId"]: reference["subject"]
        for reference in reference_authorities
    }
    references_by_id = {
        reference["exemptionId"]: reference for reference in reference_authorities
    }
    if (
        not isinstance(exempt_processes, list)
        or len(exempt_processes) != len(reference_authorities)
        or [item.get("exemptionId") for item in exempt_processes]
        != sorted(expected_subjects, key=lambda key: expected_subjects[key]["pid"])
    ):
        raise ValueError("sandbox probe reference exemptions are incomplete")
    for item in exempt_processes:
        reference = (
            references_by_id.get(item.get("exemptionId"))
            if isinstance(item, dict)
            else None
        )
        process = item.get("process") if isinstance(item, dict) else None
        reasons = item.get("reasons") if isinstance(item, dict) else None
        if (
            not isinstance(item, dict)
            or set(item) != {"exemptionId", "process", "reasons"}
            or reference is None
            or not _valid_process_record(process)
            or process["identity"] != expected_subjects[item["exemptionId"]]
            or process["executable"] != reference["executable"]["path"]
            or process["argv"] != reference["argv"]
            or not isinstance(reasons, list)
            or not reasons
            or reasons != sorted(set(reasons))
            or any(not isinstance(reason, str) for reason in reasons)
        ):
            raise ValueError("sandbox probe reference exemption record is invalid")
        observable_reasons: set[str] = set()

        def referenced_roots(value: str) -> set[str]:
            matches: set[str] = set()
            for key, root in expected_roots.items():
                if value == root or value.startswith(root + os.sep) or root in value:
                    matches.add(key)
            return matches

        for argument in process["argv"]:
            observable_reasons.update(
                f"argv:{key}" for key in referenced_roots(argument)
            )
        for label in ("cwd", "root"):
            value = process[label]
            if value is not None:
                observable_reasons.update(
                    f"{label}:{key}" for key in referenced_roots(value)
                )
        for value in process["openVnodePaths"]:
            observable_reasons.update(
                f"openFd:{key}" for key in referenced_roots(value)
            )
        evidence_non_env = {
            reason for reason in reasons if not reason.startswith("env:")
        }
        root_reasons = {
            reason.rsplit(":", maxsplit=1)[-1]
            for reason in reasons
            if reason.rsplit(":", maxsplit=1)[-1] in AUTHORITY_ROOT_KEYS
        }
        reason_pattern = re.compile(
            r"(?:argv|cwd|root|openFd):(?:"
            + "|".join(sorted(AUTHORITY_ROOT_KEYS))
            + r")\Z|env:[^:]+:(?:"
            + "|".join(sorted(AUTHORITY_ROOT_KEYS))
            + r")\Z"
        )
        if (
            "marker" in reasons
            or evidence_non_env != observable_reasons
            or any(reason_pattern.fullmatch(reason) is None for reason in reasons)
            or root_reasons != set(reference["allowedRootKeys"])
        ):
            raise ValueError("sandbox probe reference exemption reasons are invalid")
    known_identities = {
        item["identity"]["pid"]: item["identity"] for item in scope["stoppedProcesses"]
    }
    known_identities.update(
        {
            item["process"]["identity"]["pid"]: item["process"]["identity"]
            for item in exempt_processes
        }
    )
    if any(
        known_identities.get(identity["pid"]) != identity
        for identity in inspection["fallbackProcesses"]
    ):
        raise ValueError("sandbox probe fallback identity is unbound")
    _validate_lsof_seal(inspection["lsof"])
    if (
        not isinstance(result, dict)
        or set(result) != SCOPED_RESULT_KEYS
        or result.get("version") != 1
        or result.get("label") != "android-sdk-sandbox-probe"
        or result.get("status") != "completed"
        or result.get("commandExitCode") != 0
        or result.get("authority") != authority
        or result.get("scopeTermination") != scope
        or result.get("authoritySha256") != authority_entry["sha256"]
        or result.get("childPid") != authority["leader"]["pid"]
        or result.get("scopeEvidenceSha256") != hashlib.sha256(scope_bytes).hexdigest()
    ):
        raise ValueError("sandbox probe scoped-command result is invalid")


def verify_prepared(prepared: dict[str, Any]) -> dict[str, Any]:
    if (
        set(prepared) != PREPARED_KEYS | {"evidenceSha256"}
        or prepared.get("version") != 1
        or prepared.get("status") != "prepared"
    ):
        raise ValueError("unsupported or unsuccessful prepared evidence")
    paths = prepared.get("paths")
    if not isinstance(paths, dict) or set(paths) != PATH_KEYS:
        raise ValueError("prepared path set is invalid")
    for name, value in paths.items():
        if not isinstance(value, str) or validate_directory(
            pathlib.Path(value), f"prepared {name}"
        ) != pathlib.Path(value):
            raise ValueError(f"prepared path is invalid: {name}")
    components = prepared.get("components")
    if not isinstance(components, dict) or set(components) != COMPONENT_KEYS:
        raise ValueError("prepared component set is invalid")
    for name, expected in components.items():
        _same_fingerprint(expected, f"component changed ({name})")
    sandbox_exec = prepared.get("sandboxExec")
    _same_fingerprint(
        sandbox_exec,
        "sandbox-exec changed",
        extra_keys=frozenset({"verified", "identifier", "cdHash"}),
    )
    if (
        sandbox_exec.get("verified") is not True
        or sandbox_exec.get("identifier") != "com.apple.sandbox-exec"
        or re.fullmatch(r"[0-9a-f]+", sandbox_exec.get("cdHash", "")) is None
    ):
        raise ValueError("sandbox-exec signed identity is invalid")
    android_sdk = prepared.get("androidSdk")
    if not isinstance(android_sdk, dict) or set(android_sdk) != {"knownPackages"}:
        raise ValueError("prepared Android SDK evidence is invalid")
    _same_fingerprint(
        android_sdk["knownPackages"],
        "Android SDK .knownPackages changed",
    )
    session_proof = prepared.get("sessionProof")
    if not isinstance(session_proof, dict) or set(session_proof) != SESSION_PROOF_KEYS:
        raise ValueError("prepared session proof is invalid")
    for name in ("authority", "environment", "scope", "result"):
        expected = session_proof.get(name)
        _same_fingerprint(expected, f"session proof changed ({name})")
    reference_fingerprints = session_proof.get("referenceAuthorities")
    if not isinstance(reference_fingerprints, list) or not reference_fingerprints:
        raise ValueError("prepared reference authorities are missing")
    for index, expected in enumerate(reference_fingerprints):
        _same_fingerprint(
            expected,
            f"session proof changed (referenceAuthorities[{index}])",
        )
    authority_path = pathlib.Path(session_proof["authority"]["path"])
    expected_environment_path = child_environment_evidence_path(authority_path)
    if pathlib.Path(session_proof["environment"]["path"]) != expected_environment_path:
        raise ValueError("prepared child-environment evidence path is invalid")
    authority = _decode_evidence_json(
        authority_path.read_bytes(),
        "prepared session proof authority",
    )
    owner_root = authority.get("ownerRoot") if isinstance(authority, dict) else None
    if not _valid_identity(owner_root):
        raise ValueError("prepared session proof owner root is invalid")
    validate_session_result(
        authority_path=authority_path,
        scope_path=pathlib.Path(session_proof["scope"]["path"]),
        result_path=pathlib.Path(session_proof["result"]["path"]),
        roots={name: pathlib.Path(value) for name, value in paths.items()},
        components={
            name: pathlib.Path(value["path"]) for name, value in components.items()
        },
        owner_root_pid=owner_root["pid"],
        reference_authority_paths=[
            pathlib.Path(item["path"]) for item in reference_fingerprints
        ],
    )
    validate_probe_result(prepared.get("probe"))
    return {
        "version": 1,
        "status": "verified",
        "preparedEvidenceSha256": prepared.get("evidenceSha256"),
        "components": components,
        "sandboxExec": sandbox_exec,
        "androidSdk": android_sdk,
        "paths": paths,
        "sessionProof": session_proof,
    }


def _validate_denied_operation(value: object, expected: str) -> None:
    if (
        not isinstance(value, dict)
        or set(value) != {"denied", "errno", "operation"}
        or value.get("denied") is not True
        or type(value.get("errno")) is not int
        or value.get("errno") not in {1, 13, 30}
        or value.get("operation") != expected
    ):
        raise ValueError(f"sandbox probe denial is invalid: {expected}")


def validate_probe_result(value: object) -> None:
    required = {
        "allowedWrite",
        "child",
        "deniedOperations",
        "deniedStateUnchanged",
        "readSucceeded",
        "sdkOpenWrite",
        "status",
        "version",
    }
    if (
        not isinstance(value, dict)
        or set(value) != required
        or value.get("version") != 1
        or value.get("status") != "passed"
    ):
        raise ValueError("sandbox probe did not report version 1 passed")
    if value.get("readSucceeded") is not True:
        raise ValueError("sandbox probe read did not succeed")
    if value.get("allowedWrite") is not True:
        raise ValueError("sandbox probe allowed write did not succeed")
    if value.get("deniedStateUnchanged") is not True:
        raise ValueError("sandbox probe denied fixture state changed")
    _validate_denied_operation(value.get("sdkOpenWrite"), "sdk-open-write")
    operations = value.get("deniedOperations")
    expected = ["write", "open-write", "create", "delete", "rename", "chmod", "xattr"]
    if not isinstance(operations, list) or len(operations) != len(expected):
        raise ValueError("sandbox probe denied operations are missing")
    for item, operation in zip(operations, expected, strict=True):
        _validate_denied_operation(item, operation)
    child = value.get("child")
    if (
        not isinstance(child, dict)
        or set(child) != {"depth", "write", "childReturnCode", "child"}
        or child.get("depth") != 1
        or child.get("childReturnCode") != 0
    ):
        raise ValueError("sandbox probe child did not inherit denial")
    _validate_denied_operation(child.get("write"), "descendant-create")
    grandchild = child.get("child")
    if (
        not isinstance(grandchild, dict)
        or set(grandchild) != {"depth", "write"}
        or grandchild.get("depth") != 2
    ):
        raise ValueError("sandbox probe grandchild did not inherit denial")
    _validate_denied_operation(grandchild.get("write"), "descendant-create")


def _prepare(arguments: argparse.Namespace) -> dict[str, Any]:
    if arguments.owner_root_pid <= 1:
        raise ValueError("process-scope owner root PID is unsafe")
    roots = {
        name: validate_directory(getattr(arguments, name), name.replace("_", " "))
        for name in (
            "app_root",
            "flutter_root",
            "pub_cache",
            "gradle_home",
            "isolated_root",
            "run_temp",
            "android_sdk_root",
            "host_home",
        )
    }
    write_roots = [
        roots[name]
        for name in (
            "app_root",
            "pub_cache",
            "gradle_home",
            "isolated_root",
            "run_temp",
        )
    ]
    validate_read_only_root(
        roots["android_sdk_root"],
        "Android SDK",
        [*write_roots, roots["flutter_root"]],
    )
    validate_read_only_root(
        roots["flutter_root"],
        "Flutter SDK",
        [*write_roots, roots["android_sdk_root"]],
    )
    components = {
        "profile": validate_regular_file(arguments.profile, "sandbox profile"),
        "wrapper": validate_executable(arguments.wrapper, "sandbox wrapper"),
        "probe": validate_regular_file(arguments.probe, "sandbox probe"),
        "python": validate_executable(arguments.python, "Python executable"),
        "processScope": validate_regular_file(
            arguments.process_scope,
            "process-scope helper",
        ),
        "scopedCommand": validate_regular_file(
            arguments.scoped_command,
            "scoped-command helper",
        ),
    }
    sandbox_exec = validate_executable(SYSTEM_SANDBOX_EXEC, "system sandbox-exec")
    known_packages = validate_regular_file(
        roots["android_sdk_root"] / ".knownPackages",
        "Android SDK .knownPackages",
    )
    known_before = file_fingerprint(known_packages)
    component_before = _component_fingerprints(components)
    sandbox_before = codesign_identity(sandbox_exec)

    denied_root = pathlib.Path(
        tempfile.mkdtemp(prefix=".telltale-sdk-denied-", dir=roots["host_home"])
    )
    allowed_root = pathlib.Path(
        tempfile.mkdtemp(prefix="telltale-sdk-allowed-", dir=roots["run_temp"])
    )
    denied_root.chmod(0o700)
    allowed_root.chmod(0o700)
    for name in (
        "readable",
        "delete-target",
        "rename-source",
        "chmod-target",
        "xattr-target",
    ):
        path = denied_root / name
        path.write_text(
            "readable\n" if name == "readable" else f"{name}\n", encoding="utf-8"
        )
        path.chmod(0o600)
    environment = os.environ.copy()
    environment.update(
        {
            ENV_PREFIX + "PROFILE": os.fspath(components["profile"]),
            ENV_PREFIX + "APP_ROOT": os.fspath(roots["app_root"]),
            ENV_PREFIX + "FLUTTER_ROOT": os.fspath(roots["flutter_root"]),
            ENV_PREFIX + "PUB_CACHE": os.fspath(roots["pub_cache"]),
            ENV_PREFIX + "GRADLE_HOME": os.fspath(roots["gradle_home"]),
            ENV_PREFIX + "ISOLATED_ROOT": os.fspath(roots["isolated_root"]),
            ENV_PREFIX + "RUN_TEMP": os.fspath(roots["run_temp"]),
            ENV_PREFIX + "ANDROID_SDK_ROOT": os.fspath(roots["android_sdk_root"]),
        }
    )
    authority_path = arguments.output.with_name(
        "android-sdk-sandbox-probe.process-authority.json"
    )
    scope_path = arguments.output.with_name(
        "android-sdk-sandbox-probe.process-scope.json"
    )
    session_result_path = arguments.output.with_name(
        "android-sdk-sandbox-probe.scoped-command.json"
    )
    try:
        reference_arguments = [
            item
            for path in arguments.reference_authority
            for item in ("--reference-authority", os.fspath(path))
        ]
        completed = subprocess.run(
            [
                os.fspath(components["python"]),
                "-I",
                "-S",
                "-B",
                os.fspath(components["scopedCommand"]),
                "--authority",
                os.fspath(authority_path),
                "--scope-evidence",
                os.fspath(scope_path),
                "--result",
                os.fspath(session_result_path),
                "--label",
                "android-sdk-sandbox-probe",
                "--cwd",
                os.fspath(roots["app_root"]),
                "--owner-root-pid",
                str(arguments.owner_root_pid),
                "--wrapper",
                os.fspath(components["wrapper"]),
                "--wrapper-sha256",
                component_before["wrapper"]["sha256"],
                *reference_arguments,
                "--",
                os.fspath(components["wrapper"]),
                "--",
                os.fspath(components["python"]),
                "-I",
                "-S",
                "-B",
                os.fspath(components["probe"]),
                "probe",
                "--denied-root",
                os.fspath(denied_root),
                "--allowed-root",
                os.fspath(allowed_root),
                "--known-packages",
                os.fspath(known_packages),
            ],
            env=environment,
            cwd=roots["app_root"],
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )
        if completed.returncode != 0:
            raise ValueError(
                f"sandbox probe failed: {completed.stdout}\n{completed.stderr}"
            )
        probe_result = _decode_evidence_json(completed.stdout, "sandbox probe output")
        validate_probe_result(probe_result)
        validate_session_result(
            authority_path=authority_path,
            scope_path=scope_path,
            result_path=session_result_path,
            roots=roots,
            components=components,
            owner_root_pid=arguments.owner_root_pid,
            reference_authority_paths=arguments.reference_authority,
        )
        known_after = file_fingerprint(known_packages)
        if known_after != known_before:
            raise ValueError("Android SDK .knownPackages changed during sandbox probe")
        for name, expected in component_before.items():
            _same_fingerprint(expected, f"component changed during probe ({name})")
        _same_fingerprint(
            sandbox_before,
            "sandbox-exec changed during probe",
            extra_keys=frozenset({"verified", "identifier", "cdHash"}),
        )
    finally:
        shutil.rmtree(denied_root, ignore_errors=False)
        shutil.rmtree(allowed_root, ignore_errors=False)
    return {
        "version": 1,
        "status": "prepared",
        "paths": {name: os.fspath(path) for name, path in sorted(roots.items())},
        "components": component_before,
        "sandboxExec": sandbox_before,
        "androidSdk": {"knownPackages": known_before},
        "probe": probe_result,
        "sessionProof": {
            "authority": file_fingerprint(authority_path),
            "environment": file_fingerprint(
                child_environment_evidence_path(authority_path)
            ),
            "scope": file_fingerprint(scope_path),
            "result": file_fingerprint(session_result_path),
            "referenceAuthorities": [
                file_fingerprint(path) for path in arguments.reference_authority
            ],
        },
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    prepare = subparsers.add_parser("prepare")
    for name in (
        "app-root",
        "flutter-root",
        "pub-cache",
        "gradle-home",
        "isolated-root",
        "run-temp",
        "android-sdk-root",
        "host-home",
        "profile",
        "wrapper",
        "probe",
        "python",
        "process-scope",
        "scoped-command",
        "output",
    ):
        prepare.add_argument(f"--{name}", required=True, type=pathlib.Path)
    prepare.add_argument("--owner-root-pid", required=True, type=int)
    prepare.add_argument(
        "--reference-authority", required=True, action="append", type=pathlib.Path
    )
    verify = subparsers.add_parser("verify")
    verify.add_argument("--prepared-evidence", required=True, type=pathlib.Path)
    verify.add_argument("--expected-prepared-sha256", required=True)
    verify.add_argument("--output", required=True, type=pathlib.Path)
    return parser


def main() -> int:
    arguments = _parser().parse_args()
    if arguments.command == "prepare":
        value = _prepare(arguments)
        write_evidence(arguments.output, value)
    else:
        prepared = read_prepared_evidence(
            arguments.prepared_evidence,
            arguments.expected_prepared_sha256,
        )
        value = verify_prepared(prepared)
        write_evidence(arguments.output, value)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
