#!/usr/bin/env python3
"""Independent, fail-closed validation of Gate C process-scope evidence."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import sys
from types import ModuleType
from typing import Any


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
AUDIT_SCOPE_KEYS = SCOPE_KEYS | {"mode"}
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
GUARDED_RESULT_KEYS = frozenset(
    {
        "version",
        "label",
        "guardPid",
        "guardExitObserved",
        "commandExitCode",
        "termination",
        "scopeTermination",
        "status",
        "childPid",
        "childPgid",
        "scopeAuthority",
        "scopeAuthoritySha256",
        "scopeEvidenceSha256",
        "logSha256",
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
ROOT_KEYS = frozenset(
    {
        "gradleUserHome",
        "isolatedUserRoot",
        "home",
        "sandboxRunTemp",
        "kotlinProjectPersistentDir",
        "kotlinDaemonRunFilesDir",
    }
)
INSPECTION_KEYS = frozenset({"complete", "lsof", "fallbackProcesses"})
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
TOKEN = re.compile(r"[0-9a-f]{32}\Z")
GATE_CUTS = (
    "allocated",
    "sourceverified",
    "handedoffbeforeplatform",
    "platforminvoked",
    "pendingresult",
    "neverresult",
    "realpluginmirror",
)
BOOTSTRAP_SCOPED_LABELS = frozenset(
    {"gradle-version", "flutter-version", "dart-version"}
)
REQUIRED_NON_GATE_LABELS = frozenset(
    {
        *BOOTSTRAP_SCOPED_LABELS,
        "fixture-generator",
        "android-toolchain-build",
        "android-toolchain-lint-model",
        "telemetry-memory-measure",
    }
)


class ValidationError(ValueError):
    """Evidence failed an outer, semantic process-scope check."""


def _reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValidationError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def _load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_bytes(), object_pairs_hook=_reject_duplicates)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValidationError(f"{label} JSON is unreadable") from error
    if not isinstance(value, dict):
        raise ValidationError(f"{label} must be an object")
    return value


def _sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _private_file(path: Path, label: str) -> Path:
    try:
        canonical = path.resolve(strict=True)
        status = os.lstat(path)
    except OSError as error:
        raise ValidationError(f"{label} is unavailable") from error
    if (
        not path.is_absolute()
        or canonical != path
        or not stat.S_ISREG(status.st_mode)
        or status.st_uid != os.getuid()
        or stat.S_IMODE(status.st_mode) != 0o600
        or status.st_nlink != 1
    ):
        raise ValidationError(f"{label} filesystem identity is unsafe")
    return canonical


def _child_environment_path(authority_path: Path) -> Path:
    suffix = ".process-authority.json"
    if not authority_path.name.endswith(suffix):
        raise ValidationError("launch authority evidence path is invalid")
    return authority_path.with_name(
        authority_path.name[: -len(suffix)] + ".child-environment.json"
    )


def _canonical_json_sha256(value: object) -> str:
    payload = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(payload).hexdigest()


def _validate_child_environment(
    authority_path: Path,
    authority: dict[str, Any],
) -> Path:
    path = _child_environment_path(authority_path)
    _private_file(path, "child-environment evidence")
    value = _load_json(path, "child-environment evidence")
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
        raise ValidationError("child-environment actual names are invalid")
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
        or SHA256.fullmatch(value.get("producerPlannedEnvironmentValuesSha256", ""))
        is None
        or value.get("plannedNamesMatchBarrier") is not True
        or value.get("valuesObserved") is not False
        or value.get("postBarrierAddedNames")
        != ["FLUTTER_ALREADY_LOCKED", "JAVA_TOOL_OPTIONS", "TMPDIR"]
        or value.get("credentialNamesAssertedAbsent")
        != sorted(CHILD_ENVIRONMENT_CREDENTIAL_NAMES)
        or value.get("forbiddenCredentialNamesPresent") != []
    ):
        raise ValidationError("child-environment evidence binding is invalid")
    return path


def _component(prepared: dict[str, Any], name: str) -> dict[str, Any]:
    components = prepared.get("components")
    value = components.get(name) if isinstance(components, dict) else None
    if (
        not isinstance(value, dict)
        or not isinstance(value.get("path"), str)
        or SHA256.fullmatch(value.get("sha256", "")) is None
    ):
        raise ValidationError(f"prepared component is invalid: {name}")
    path = Path(value["path"])
    if path.resolve(strict=True) != path or _sha(path) != value["sha256"]:
        raise ValidationError(f"prepared component changed: {name}")
    return value


def _expected_roots(prepared: dict[str, Any]) -> dict[str, str]:
    paths = prepared.get("paths")
    if not isinstance(paths, dict):
        raise ValidationError("prepared paths are missing")
    try:
        result = {
            "gradleUserHome": paths["gradle_home"],
            "isolatedUserRoot": paths["isolated_root"],
            "home": os.fspath(Path(paths["isolated_root"]) / "home"),
            "sandboxRunTemp": paths["run_temp"],
            "kotlinProjectPersistentDir": os.fspath(
                Path(paths["run_temp"]) / "kotlin-project-persistent"
            ),
            "kotlinDaemonRunFilesDir": os.fspath(
                Path(paths["run_temp"]) / "kotlin-daemon"
            ),
        }
    except (KeyError, TypeError) as error:
        raise ValidationError("prepared process-scope roots are incomplete") from error
    if any(
        not isinstance(item, str) or not Path(item).is_absolute()
        for item in result.values()
    ):
        raise ValidationError("prepared process-scope roots are invalid")
    return result


def _valid_identity(value: object) -> bool:
    return (
        isinstance(value, dict)
        and set(value) == IDENTITY_KEYS
        and all(type(value[key]) is int for key in IDENTITY_KEYS)
        and value["uid"] == os.getuid()
        and min(value["pid"], value["pgid"], value["sid"], value["startSec"]) > 0
        and value["ppid"] >= 0
        and 0 <= value["startUsec"] <= 999_999
    )


def _valid_record(value: object) -> bool:
    return (
        isinstance(value, dict)
        and set(value) == PROCESS_RECORD_KEYS
        and _valid_identity(value.get("identity"))
        and type(value.get("state")) is int
        and isinstance(value.get("executable"), str)
        and isinstance(value.get("argv"), list)
        and all(isinstance(item, str) and "\0" not in item for item in value["argv"])
        and SHA256.fullmatch(value.get("environmentSha256", "")) is not None
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


def _load_process_scope(prepared: dict[str, Any], rig_root: Path) -> ModuleType:
    fingerprint = _component(prepared, "processScope")
    expected = (rig_root / "process_scope.py").resolve(strict=True)
    if Path(fingerprint["path"]) != expected:
        raise ValidationError(
            "prepared process-scope helper path is not the tested helper"
        )
    name = f"outer_bound_process_scope_{fingerprint['sha256']}"
    spec = importlib.util.spec_from_file_location(name, expected)
    if spec is None or spec.loader is None:
        raise ValidationError("could not load tested process-scope helper")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException as error:
        raise ValidationError(
            "tested process-scope helper could not recapture lsof"
        ) from error
    return module


def _validate_authority(
    value: dict[str, Any],
    prepared: dict[str, Any],
    expected_roots: dict[str, str],
    expected_cwds: set[str],
) -> None:
    wrapper = _component(prepared, "wrapper")
    if (
        set(value) != AUTHORITY_KEYS
        or value.get("version") != 2
        or TOKEN.fullmatch(value.get("launchId", "")) is None
        or not all(
            _valid_identity(value.get(key))
            for key in ("ownerRoot", "supervisor", "leader")
        )
        or value["leader"]["pid"] != value["leader"]["pgid"]
        or value["leader"]["pid"] != value["leader"]["sid"]
        or value["leader"]["ppid"] != value["supervisor"]["pid"]
        or value.get("wrapper")
        != {"path": wrapper["path"], "sha256": wrapper["sha256"]}
        or value.get("roots") != expected_roots
        or value.get("cwd") not in expected_cwds
    ):
        raise ValidationError("launch authority is invalid")


def _ordered_records(
    scope: dict[str, Any], field: str, sessions: set[int]
) -> list[dict[str, Any]]:
    records = scope.get(field)
    if (
        not isinstance(records, list)
        or not all(_valid_record(item) for item in records)
        or [item["identity"]["pid"] for item in records]
        != sorted({item["identity"]["pid"] for item in records})
        or any(item["identity"]["sid"] not in sessions for item in records)
    ):
        raise ValidationError(f"invalid or unauthorized process records: {field}")
    return records


def _record_map(records: list[dict[str, Any]]) -> dict[int, dict[str, Any]]:
    return {item["identity"]["pid"]: item for item in records}


def _validate_scope_common(
    scope: dict[str, Any],
    authorities: list[tuple[Path, dict[str, Any]]],
    references: list[tuple[Path, dict[str, Any]]],
    expected_roots: dict[str, str],
    lsof_seal: dict[str, Any],
    *,
    audit_only: bool = False,
) -> None:
    expected_authority_entries = [
        {"path": os.fspath(path), "sha256": _sha(path), "launchId": value["launchId"]}
        for path, value in authorities
    ]
    expected_reference_entries = [
        {
            "path": os.fspath(path),
            "sha256": _sha(path),
            "exemptionId": value["exemptionId"],
        }
        for path, value in references
    ]
    sessions = {value["leader"]["sid"] for _, value in authorities}
    expected_sessions = [] if audit_only else sorted(sessions)
    expected_keys = AUDIT_SCOPE_KEYS if audit_only else SCOPE_KEYS
    expected_marker = (
        "TELLTALE_GATE_C_PROCESS_SCOPE_AUDIT"
        if audit_only
        else "TELLTALE_GATE_C_PROCESS_SCOPE"
    )
    inspection = scope.get("referenceInspection")
    if (
        set(scope) != expected_keys
        or scope.get("version") != 3
        or scope.get("status") != "quiescent"
        or scope.get("marker") != expected_marker
        or (audit_only and scope.get("mode") != "audit-only")
        or scope.get("ownerRoot") != authorities[0][1]["ownerRoot"]
        or any(
            value["ownerRoot"] != authorities[0][1]["ownerRoot"]
            for _, value in authorities
        )
        or scope.get("roots") != expected_roots
        or scope.get("authorities") != expected_authority_entries
        or scope.get("referenceAuthorities") != expected_reference_entries
        or scope.get("authorizedSessions") != expected_sessions
        or type(scope.get("startedMonotonicNs")) is not int
        or type(scope.get("endedMonotonicNs")) is not int
        or scope["endedMonotonicNs"] < scope["startedMonotonicNs"]
        or scope.get("remainingOwnedProcesses") != []
        or scope.get("foreignProcesses") != []
        or scope.get("inspectionLimitations") != []
        or not isinstance(inspection, dict)
        or set(inspection) != INSPECTION_KEYS
        or inspection.get("complete") is not True
        or inspection.get("lsof") != lsof_seal
    ):
        raise ValidationError(
            "process-scope quiescence or live lsof binding is invalid"
        )
    if audit_only and any(
        scope.get(field) != []
        for field in (
            "stoppedProcesses",
            "termSentProcesses",
            "killSentProcesses",
        )
    ):
        raise ValidationError("audit-only process scope contains signal records")
    stopped = _ordered_records(scope, "stoppedProcesses", sessions)
    term = _ordered_records(scope, "termSentProcesses", sessions)
    _ordered_records(scope, "killSentProcesses", sessions)
    stopped_by_pid = _record_map(stopped)
    term_by_pid = _record_map(term)
    if any(stopped_by_pid.get(pid) != record for pid, record in term_by_pid.items()):
        raise ValidationError("TERM records are not an exact subset of stopped records")
    fallback = inspection.get("fallbackProcesses")
    known = {item["identity"]["pid"]: item["identity"] for item in stopped}
    for exempt in scope.get("referenceExemptProcesses", []):
        if isinstance(exempt, dict) and isinstance(exempt.get("process"), dict):
            identity = exempt["process"].get("identity")
            if _valid_identity(identity):
                known[identity["pid"]] = identity
    invalid_fallback = (
        not isinstance(fallback, list)
        or not all(_valid_identity(item) for item in fallback)
        or [item["pid"] for item in fallback]
        != sorted({item["pid"] for item in fallback})
    )
    if not audit_only:
        invalid_fallback = invalid_fallback or any(
            known.get(item["pid"]) != item for item in fallback
        )
    if invalid_fallback:
        raise ValidationError("fallback process identities are invalid or unbound")


def _validate_reference(
    path: Path,
    reference: dict[str, Any],
    evidence_dir: Path,
    prepared: dict[str, Any],
    rig_root: Path,
    expected_roots: dict[str, str],
    *,
    bootstrap: bool = False,
) -> None:
    python = _component(prepared, "python")
    program = (rig_root / "source_tree_guard.py").resolve(strict=True)
    prefix = "bootstrap-" if bootstrap else ""
    ready = evidence_dir / f"{prefix}source-tree-guard-ready.json"
    stop = evidence_dir / f"{prefix}source-tree-guard.stop"
    result = evidence_dir / f"{prefix}source-tree-guard-result.json"
    readiness = reference.get("readiness")
    if (
        set(reference) != REFERENCE_AUTHORITY_KEYS
        or reference.get("version") != 1
        or reference.get("kind") != "source-guard-reference-exemption"
        or TOKEN.fullmatch(reference.get("exemptionId", "")) is None
        or not _valid_identity(reference.get("ownerRoot"))
        or not _valid_identity(reference.get("subject"))
        or reference["subject"]["ppid"] != reference["ownerRoot"]["pid"]
        or reference.get("executable")
        != {"path": python["path"], "sha256": python["sha256"]}
        or reference.get("program")
        != {"path": os.fspath(program), "sha256": _sha(program)}
        or reference.get("roots") != expected_roots
        or not isinstance(reference.get("allowedRootKeys"), list)
        or not reference["allowedRootKeys"]
        or reference["allowedRootKeys"] != sorted(set(reference["allowedRootKeys"]))
        or not set(reference["allowedRootKeys"]).issubset(ROOT_KEYS)
        or not isinstance(readiness, dict)
        or set(readiness) != {"path", "sha256", "nonce", "stopPath", "resultPath"}
        or readiness.get("path") != os.fspath(ready)
        or readiness.get("stopPath") != os.fspath(stop)
        or readiness.get("resultPath") != os.fspath(result)
        or TOKEN.fullmatch(readiness.get("nonce", "")) is None
        or readiness.get("sha256") != _sha(ready)
    ):
        raise ValidationError("source-guard reference authority is invalid")
    ready_value = _load_json(ready, "source-guard readiness")
    if (
        ready_value.get("pid") != reference["subject"]["pid"]
        or ready_value.get("nonce") != readiness["nonce"]
    ):
        raise ValidationError("source-guard readiness identity is invalid")
    argv = reference.get("argv")
    if (
        not isinstance(argv, list)
        or len(argv) < 5
        or any(not isinstance(item, str) or "\0" in item for item in argv)
        or argv[0] != python["path"]
        or argv[1:4] != ["-I", "-S", "-B"]
        or argv[4] != os.fspath(program)
    ):
        raise ValidationError("source-guard reference argv is invalid")
    paths = prepared["paths"]
    toolchain = _load_json(
        evidence_dir / "android-toolchain.roots.post.json",
        "Android toolchain roots",
    )
    common_toolchains = [
        paths["android_sdk_root"],
        toolchain.get("jdkRoot"),
    ]
    isolated = Path(paths["isolated_root"])
    settings = os.fspath(isolated / "xdg-config" / "settings")
    python_root = os.fspath(Path(sys.base_prefix).resolve(strict=True))
    if bootstrap:
        toolchains = [*common_toolchains, settings, python_root]
    else:
        toolchains = [
            *common_toolchains,
            toolchain.get("gradleRoot"),
            settings,
            os.fspath(isolated / "android-user-home" / "debug.keystore"),
            python_root,
        ]
    if any(
        not isinstance(value, str) or not Path(value).is_absolute()
        for value in toolchains
    ):
        raise ValidationError("source-guard toolchain roots are invalid")
    events = isolated / f"{prefix}source-tree-guard-events.jsonl"
    baseline = (
        evidence_dir / f"tested-files.{('bootstrap' if bootstrap else 'pre')}.sha256"
    )
    sidecar = evidence_dir / f"{prefix}source-tree-guard-baseline.json"
    exact_argv = [
        reference["executable"]["path"],
        "-I",
        "-S",
        "-B",
        reference["program"]["path"],
        "--root",
        paths["app_root"],
        "--expected-flutter-root",
        paths["flutter_root"],
    ]
    for value in toolchains:
        exact_argv.extend(("--toolchain-root", value))
    exact_argv.extend(
        (
            "--backend",
            "darwin-fsevents",
            "--stop-file",
            os.fspath(stop),
            "--ready-file",
            os.fspath(ready),
            "--events-file",
            os.fspath(events),
            "--result-file",
            os.fspath(result),
            "--baseline-manifest",
            os.fspath(baseline),
            "--baseline-sidecar",
            os.fspath(sidecar),
            "--nonce",
            readiness["nonce"],
        )
    )
    if argv != exact_argv:
        raise ValidationError(
            "source-guard reference argv is not the exact producer command"
        )
    authority_name = (
        "bootstrap-source-guard.reference-authority.json"
        if bootstrap
        else "source-guard.reference-authority.json"
    )
    expected_path = (
        evidence_dir / "process-scope-reference-authorities" / authority_name
    )
    if _private_file(path, "source-guard reference authority") != expected_path:
        raise ValidationError("source-guard reference authority path is invalid")


def _validate_exemptions(
    scope: dict[str, Any], references: list[tuple[Path, dict[str, Any]]]
) -> None:
    expected = {value["exemptionId"]: value for _, value in references}
    exempt = scope.get("referenceExemptProcesses")
    if (
        not isinstance(exempt, list)
        or len(exempt) != len(expected)
        or [item.get("exemptionId") for item in exempt]
        != sorted(expected, key=lambda key: expected[key]["subject"]["pid"])
    ):
        raise ValidationError("source-guard reference exemptions are incomplete")
    for item in exempt:
        authority = (
            expected.get(item.get("exemptionId")) if isinstance(item, dict) else None
        )
        reasons = item.get("reasons") if isinstance(item, dict) else None
        record = item.get("process") if isinstance(item, dict) else None
        if (
            authority is None
            or set(item) != {"exemptionId", "process", "reasons"}
            or not _valid_record(record)
            or record["identity"] != authority["subject"]
            or record["executable"] != authority["executable"]["path"]
            or record["argv"] != authority["argv"]
            or not isinstance(reasons, list)
            or not reasons
            or reasons != sorted(set(reasons))
            or any(not isinstance(reason, str) for reason in reasons)
        ):
            raise ValidationError("source-guard reference exemption is invalid")
        observable_reasons: set[str] = set()
        roots = {key: Path(value) for key, value in authority["roots"].items()}

        def referenced_roots(value: str) -> set[str]:
            matches: set[str] = set()
            for key, root in roots.items():
                root_text = os.fspath(root)
                if (
                    value == root_text
                    or value.startswith(root_text + os.sep)
                    or root_text in value
                ):
                    matches.add(key)
            return matches

        for argument in record["argv"]:
            observable_reasons.update(
                f"argv:{key}" for key in referenced_roots(argument)
            )
        for label in ("cwd", "root"):
            value = record[label]
            if value is not None:
                observable_reasons.update(
                    f"{label}:{key}" for key in referenced_roots(value)
                )
        for value in record["openVnodePaths"]:
            observable_reasons.update(
                f"openFd:{key}" for key in referenced_roots(value)
            )
        evidence_non_env = {
            reason for reason in reasons if not reason.startswith("env:")
        }
        if "marker" in reasons or evidence_non_env != observable_reasons:
            raise ValidationError(
                "source-guard exemption observable reasons are inconsistent"
            )
        root_reasons = {
            reason.rsplit(":", 1)[-1]
            for reason in reasons
            if reason.rsplit(":", 1)[-1] in ROOT_KEYS
        }
        valid_reason = re.compile(
            r"(?:argv|cwd|root|openFd):(?:"
            + "|".join(sorted(ROOT_KEYS))
            + r")\Z|env:[^:]+:(?:"
            + "|".join(sorted(ROOT_KEYS))
            + r")\Z"
        )
        if any(
            valid_reason.fullmatch(reason) is None for reason in reasons
        ) or root_reasons != set(authority["allowedRootKeys"]):
            raise ValidationError(
                "source-guard exemption reasons exceed its allowed roots"
            )


def validate_scoped_command(
    evidence_dir: Path,
    label: str,
    expected_status: str,
    prepared: dict[str, Any],
    rig_root: Path,
) -> dict[str, Any]:
    """Validate one Gate seed/recovery scoped-command evidence triplet."""

    evidence_dir = Path(evidence_dir)
    rig_root = Path(rig_root)
    if expected_status not in {"completed", "command_failed"}:
        raise ValidationError("unsupported scoped-command status")
    authority_path = (
        evidence_dir / "process-scope-authorities" / f"{label}.process-authority.json"
    )
    scope_path = evidence_dir / f"{label}.process-scope.json"
    result_path = evidence_dir / f"{label}.scoped-command.json"
    _private_file(authority_path, "scoped launch authority")
    authority = _load_json(authority_path, "scoped launch authority")
    scope = _load_json(scope_path, "scoped process evidence")
    result = _load_json(result_path, "scoped command result")
    if prepared.get("version") != 1 or prepared.get("status") != "prepared":
        raise ValidationError("prepared evidence status is invalid")
    roots = _expected_roots(prepared)
    app_root = prepared["paths"]["app_root"]
    expected_cwd = (
        os.fspath(Path(app_root) / "android") if label == "gradle-version" else app_root
    )
    _validate_authority(authority, prepared, roots, {expected_cwd})
    _validate_child_environment(authority_path, authority)
    reference_entries = scope.get("referenceAuthorities")
    if not isinstance(reference_entries, list) or len(reference_entries) != 1:
        raise ValidationError(
            "scoped command must have exactly one reference authority"
        )
    reference_path = Path(reference_entries[0].get("path", ""))
    reference = _load_json(reference_path, "source-guard reference authority")
    _validate_reference(
        reference_path,
        reference,
        evidence_dir,
        prepared,
        rig_root,
        roots,
        bootstrap=label in BOOTSTRAP_SCOPED_LABELS,
    )
    module = _load_process_scope(prepared, rig_root)
    lsof = getattr(module, "LSOF_SEAL", None)
    if not isinstance(lsof, dict):
        raise ValidationError("tested process-scope helper has no live lsof seal")
    if (
        reference["ownerRoot"] != authority["ownerRoot"]
        or reference["subject"]["sid"] == authority["leader"]["sid"]
    ):
        raise ValidationError("source-guard reference overlaps launch authority")
    _validate_scope_common(
        scope, [(authority_path, authority)], [(reference_path, reference)], roots, lsof
    )
    _validate_exemptions(scope, [(reference_path, reference)])
    if (
        set(result) != SCOPED_RESULT_KEYS
        or result.get("version") != 1
        or result.get("label") != label
        or result.get("status") != expected_status
        or type(result.get("commandExitCode")) is not int
        or (expected_status == "completed" and result["commandExitCode"] != 0)
        or (expected_status == "command_failed" and result["commandExitCode"] == 0)
        or result.get("authority") != authority
        or result.get("scopeTermination") != scope
        or result.get("authoritySha256") != _sha(authority_path)
        or result.get("scopeEvidenceSha256") != _sha(scope_path)
        or result.get("childPid") != authority["leader"]["pid"]
    ):
        raise ValidationError("scoped-command result binding is invalid")
    return {
        "label": label,
        "status": expected_status,
        "authorizedSessions": scope["authorizedSessions"],
    }


def validate_guarded_command(
    evidence_dir: Path,
    label: str,
    prepared: dict[str, Any],
    rig_root: Path,
) -> dict[str, Any]:
    """Validate one successful source-guard-supervised toolchain command."""

    if label not in {"android-toolchain-build", "android-toolchain-lint-model"}:
        raise ValidationError("unsupported guarded-command label")
    evidence_dir = Path(evidence_dir)
    rig_root = Path(rig_root)
    authority_path = (
        evidence_dir / "process-scope-authorities" / f"{label}.process-authority.json"
    )
    scope_path = evidence_dir / f"{label}-process-scope.json"
    result_path = evidence_dir / f"{label}-supervision.json"
    log_path = evidence_dir / f"{label}.log"
    for path, name in (
        (authority_path, "guarded launch authority"),
        (scope_path, "guarded process scope"),
        (result_path, "guarded result"),
        (log_path, "guarded log"),
    ):
        _private_file(path, name)
    authority = _load_json(authority_path, "guarded launch authority")
    scope = _load_json(scope_path, "guarded process scope")
    result = _load_json(result_path, "guarded result")
    if prepared.get("version") != 1 or prepared.get("status") != "prepared":
        raise ValidationError("prepared evidence status is invalid")
    roots = _expected_roots(prepared)
    app_root = prepared["paths"]["app_root"]
    expected_cwd = (
        app_root if label.endswith("build") else os.fspath(Path(app_root) / "android")
    )
    _validate_authority(authority, prepared, roots, {expected_cwd})
    _validate_child_environment(authority_path, authority)
    reference_entries = scope.get("referenceAuthorities")
    if not isinstance(reference_entries, list) or len(reference_entries) != 1:
        raise ValidationError(
            "guarded command must have exactly one reference authority"
        )
    reference_path = Path(reference_entries[0].get("path", ""))
    reference = _load_json(reference_path, "source-guard reference authority")
    _validate_reference(
        reference_path, reference, evidence_dir, prepared, rig_root, roots
    )
    module = _load_process_scope(prepared, rig_root)
    lsof = getattr(module, "LSOF_SEAL", None)
    if not isinstance(lsof, dict):
        raise ValidationError("tested process-scope helper has no live lsof seal")
    if (
        reference["ownerRoot"] != authority["ownerRoot"]
        or reference["subject"]["sid"] == authority["leader"]["sid"]
    ):
        raise ValidationError("source-guard reference overlaps launch authority")
    _validate_scope_common(
        scope, [(authority_path, authority)], [(reference_path, reference)], roots, lsof
    )
    _validate_exemptions(scope, [(reference_path, reference)])
    if (
        set(result) != GUARDED_RESULT_KEYS
        or result.get("version") != 1
        or result.get("label") != label
        or result.get("guardPid") != reference["subject"]["pid"]
        or result.get("guardExitObserved") is not False
        or result.get("commandExitCode") != 0
        or result.get("termination") != "natural_exit"
        or result.get("status") != "completed"
        or result.get("childPid") != authority["leader"]["pid"]
        or result.get("childPgid") != authority["leader"]["pgid"]
        or result.get("scopeAuthority") != authority
        or result.get("scopeAuthoritySha256") != _sha(authority_path)
        or result.get("scopeTermination") != scope
        or result.get("scopeEvidenceSha256") != _sha(scope_path)
        or result.get("logSha256") != _sha(log_path)
        or reference["readiness"]["nonce"]
        != _load_json(
            evidence_dir / "source-tree-guard-ready.json", "source guard readiness"
        ).get("nonce")
    ):
        raise ValidationError("guarded-command result binding is invalid")
    return {"label": label, "status": "completed", "guardPid": result["guardPid"]}


def validate_final_cleanup(
    evidence_dir: Path,
    result: dict[str, Any],
    prepared: dict[str, Any],
    rig_root: Path,
) -> dict[str, Any]:
    """Validate the unique final, reference-free process-scope cleanup cut."""

    evidence_dir = Path(evidence_dir)
    if prepared.get("version") != 1 or prepared.get("status") != "prepared":
        raise ValidationError("prepared evidence status is invalid")
    candidates = sorted(evidence_dir.glob("gradle-process-scope-cleanup-*.json"))
    digest = result.get("processScopeCleanupSha256")
    if (
        len(candidates) != 1
        or SHA256.fullmatch(digest or "") is None
        or _sha(candidates[0]) != digest
    ):
        raise ValidationError(
            "final process-scope cleanup file or digest is not unique"
        )
    scope = _load_json(candidates[0], "final process-scope cleanup")
    roots = _expected_roots(prepared)
    authority_entries = scope.get("authorities")
    if not isinstance(authority_entries, list) or not authority_entries:
        raise ValidationError("final cleanup has no launch authorities")
    authorities: list[tuple[Path, dict[str, Any]]] = []
    app_root = prepared["paths"]["app_root"]
    expected_cwds = {app_root, os.fspath(Path(app_root) / "android")}
    authority_dir = evidence_dir / "process-scope-authorities"
    expected_labels = set(REQUIRED_NON_GATE_LABELS)
    for cut in GATE_CUTS:
        phase = "realpluginmirror" if cut == "realpluginmirror" else "seed"
        expected_labels.add(f"gate-{phase}-{cut}")
        expected_labels.add(f"gate-recover-{cut}")
    expected_authority_paths = [
        authority_dir / f"{label}.process-authority.json"
        for label in sorted(expected_labels)
    ]
    preflight = evidence_dir / "android-sdk-sandbox-probe.process-authority.json"
    expected_authority_paths.append(preflight)
    expected_authority_paths.sort(key=os.fspath)
    if [
        Path(entry.get("path", "")) for entry in authority_entries
    ] != expected_authority_paths:
        raise ValidationError("final cleanup authority set is incomplete")
    for entry in authority_entries:
        if not isinstance(entry, dict) or set(entry) != {"path", "sha256", "launchId"}:
            raise ValidationError("final cleanup authority entry is invalid")
        path = Path(entry["path"])
        canonical = _private_file(path, "final cleanup launch authority")
        if not (
            canonical == preflight
            or (
                canonical.parent == authority_dir
                and canonical.name.endswith(".process-authority.json")
            )
        ):
            raise ValidationError("final cleanup authority path is outside evidence")
        authority = _load_json(path, "final cleanup launch authority")
        _validate_authority(authority, prepared, roots, expected_cwds)
        _validate_child_environment(path, authority)
        authorities.append((path, authority))
    if len({path for path, _ in authorities}) != len(authorities):
        raise ValidationError("final cleanup repeats a launch authority")
    expected_environment_paths = {
        _child_environment_path(path) for path, _ in authorities
    }
    actual_environment_paths = {
        path for path in evidence_dir.rglob("*.child-environment.json")
    }
    if actual_environment_paths != expected_environment_paths:
        raise ValidationError("child-environment evidence set is incomplete or extra")
    module = _load_process_scope(prepared, Path(rig_root))
    lsof = getattr(module, "LSOF_SEAL", None)
    if not isinstance(lsof, dict):
        raise ValidationError("tested process-scope helper has no live lsof seal")
    _validate_scope_common(
        scope,
        authorities,
        [],
        roots,
        lsof,
        audit_only=True,
    )
    if (
        scope.get("referenceAuthorities") != []
        or scope.get("referenceExemptProcesses") != []
    ):
        raise ValidationError("final cleanup must be reference-free")
    return {
        "status": "quiescent",
        "path": os.fspath(candidates[0]),
        "sha256": digest,
        "authorizedSessions": scope["authorizedSessions"],
    }
