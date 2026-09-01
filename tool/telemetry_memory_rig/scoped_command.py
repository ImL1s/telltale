#!/usr/bin/env python3
"""Launch one sandbox wrapper behind a sealed macOS session barrier."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import select
import signal
import stat
import subprocess
import sys
import time
from types import ModuleType
from typing import BinaryIO


LAUNCH_MARKER = "TELLTALE_GATE_C_PROCESS_SCOPE"
RELEASE_FD = "TELLTALE_GATE_C_LAUNCH_RELEASE_FD"
READY_FD = "TELLTALE_GATE_C_LAUNCH_READY_FD"
LAUNCH_ID_PATTERN = re.compile(r"[0-9a-f]{32}\Z")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
POLL_SECONDS = 0.05
CHILD_ENVIRONMENT_READY_HEADER = "TELLTALE_GATE_C_CHILD_ENVIRONMENT_V1"
CHILD_ENVIRONMENT_READY_MAX_BYTES = 8192
CHILD_ENVIRONMENT_SCHEMA = "telltale-gate-c-child-environment-names-v2"
CHILD_ENVIRONMENT_VERSION = 2
CHILD_ENVIRONMENT_POST_BARRIER_ADDED_NAMES = (
    "FLUTTER_ALREADY_LOCKED",
    "JAVA_TOOL_OPTIONS",
    "TMPDIR",
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
CHILD_ENVIRONMENT_RUNTIME_NAMES = frozenset({LAUNCH_MARKER, RELEASE_FD, READY_FD})
# Audit-only assertions over the already filtered name set. These names never
# participate in filtering, environment construction, or signal authority.
CREDENTIAL_ABSENCE_ASSERTION_NAMES = frozenset(
    {
        "ARBITRARY_SECRET",
        "HF_TOKEN",
        "OP_SERVICE_ACCOUNT_TOKEN",
        "SSH_AUTH_SOCK",
    }
)
FIXED_SYSTEM_PATH = ("/usr/bin", "/bin", "/usr/sbin", "/sbin")


def _translated_waitid_status(observed: object) -> int:
    if observed.si_code == os.CLD_EXITED:
        return int(observed.si_status)
    if observed.si_code in {os.CLD_KILLED, os.CLD_DUMPED}:
        return -int(observed.si_status)
    raise RuntimeError("child waitid status is not terminal")


def observe_child_exit(
    child: subprocess.Popen[bytes],
    *,
    nohang: bool = False,
) -> int | None:
    """Observe terminal status without reaping the session-leader anchor."""

    options = os.WEXITED | os.WNOWAIT | (os.WNOHANG if nohang else 0)
    while True:
        try:
            observed = os.waitid(os.P_PID, child.pid, options)
        except InterruptedError:
            continue
        break
    if observed is None:
        return None
    if observed.si_pid != child.pid:
        raise RuntimeError("waitid returned the wrong child")
    return _translated_waitid_status(observed)


def reap_child(
    child: subprocess.Popen[bytes],
    observed_exit: int | None,
    *,
    timeout: float | None = None,
) -> int:
    """Perform the sole reap and bind it to the earlier WNOWAIT observation."""

    reaped = child.wait(timeout=timeout)
    if observed_exit is not None and reaped != observed_exit:
        raise RuntimeError("child exit status changed between observation and reap")
    return reaped


def contain_failure_reap(
    child: subprocess.Popen[bytes],
    authority: dict[str, object],
    process_scope: ModuleType,
    observed_exit: int | None,
) -> int:
    """Boundedly reap, signaling only the sealed exact direct child."""

    terminal = observed_exit
    if terminal is None:
        terminal = observe_child_exit(child, nohang=True)
    if terminal is not None:
        return reap_child(child, terminal, timeout=2)
    leader = process_scope._identity_from_dict(authority["leader"], "leader")
    supervisor = process_scope._identity_from_dict(
        authority["supervisor"],
        "supervisor",
    )
    current = process_scope._record_for_pid(os.getpid())
    candidate = process_scope._record_for_pid(child.pid, leader)
    if (
        supervisor.pid != os.getpid()
        or current is None
        or not process_scope._identity_equal(current.identity, supervisor)
        or leader.ppid != supervisor.pid
        or candidate is None
        or not process_scope._identity_equal(candidate.identity, leader)
    ):
        try:
            return reap_child(child, None, timeout=0.2)
        except subprocess.TimeoutExpired as error:
            raise RuntimeError(
                "containment failed and live child identity is not signal-authorized"
            ) from error
    if not process_scope._signal_exact(candidate, signal.SIGKILL):
        raise RuntimeError("containment-failure child changed identity before SIGKILL")
    return reap_child(child, None, timeout=2)


def _load_process_scope() -> ModuleType:
    path = Path(__file__).resolve().with_name("process_scope.py")
    specification = importlib.util.spec_from_file_location(
        "telltale_gate_c_session_scope",
        path,
    )
    if specification is None or specification.loader is None:
        raise RuntimeError(f"could not load process-scope helper: {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


def _new_owned_file(path: Path, label: str) -> int:
    parent = path.parent.resolve(strict=True)
    parent_status = os.lstat(parent)
    if (
        path.parent != parent
        or stat.S_ISLNK(parent_status.st_mode)
        or not stat.S_ISDIR(parent_status.st_mode)
        or parent_status.st_uid != os.getuid()
        or parent_status.st_mode & 0o022
    ):
        raise RuntimeError(f"unsafe {label} parent")
    return os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )


def _write_json(path: Path, value: dict[str, object], label: str) -> None:
    descriptor = _new_owned_file(path, label)
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        json.dump(value, output, sort_keys=True, separators=(",", ":"))
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())


def _canonical_directory(path: Path, label: str) -> Path:
    if not path.is_absolute():
        raise RuntimeError(f"{label} is not absolute")
    canonical = path.resolve(strict=True)
    if canonical != path:
        raise RuntimeError(f"{label} is not canonical")
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        if stat.S_ISLNK(os.lstat(current).st_mode):
            raise RuntimeError(f"{label} contains a symlink: {current}")
    metadata = os.lstat(path)
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or metadata.st_mode & 0o022
    ):
        raise RuntimeError(f"{label} is unsafe")
    return canonical


def roots_from_environment(environment: dict[str, str]) -> dict[str, Path]:
    prefix = "TELLTALE_GATE_C_SANDBOX_"
    required = {
        "gradleUserHome": prefix + "GRADLE_HOME",
        "isolatedUserRoot": prefix + "ISOLATED_ROOT",
        "sandboxRunTemp": prefix + "RUN_TEMP",
    }
    raw = {name: environment.get(variable, "") for name, variable in required.items()}
    raw["home"] = environment.get("HOME", "")
    if any(not value for value in raw.values()):
        raise RuntimeError("sandbox launch roots are incomplete")
    roots = {
        name: _canonical_directory(Path(value), name) for name, value in raw.items()
    }
    roots["kotlinProjectPersistentDir"] = _canonical_directory(
        roots["sandboxRunTemp"] / "kotlin-project-persistent",
        "Kotlin project persistent directory",
    )
    roots["kotlinDaemonRunFilesDir"] = _canonical_directory(
        roots["sandboxRunTemp"] / "kotlin-daemon",
        "Kotlin daemon run-files directory",
    )
    if (
        roots["home"].parent != roots["isolatedUserRoot"]
        or roots["sandboxRunTemp"].parent != roots["isolatedUserRoot"]
    ):
        raise RuntimeError("sandbox launch root topology is invalid")
    return roots


def _read_ready(
    descriptor: int,
    timeout_ms: int,
    expected_launch_id: str,
    expected_environment_names: list[str],
) -> None:
    if LAUNCH_ID_PATTERN.fullmatch(expected_launch_id) is None:
        raise ValueError("expected sandbox wrapper launch ID is invalid")
    expected = (
        CHILD_ENVIRONMENT_READY_HEADER
        + "\n"
        + f"launchId={expected_launch_id}\n"
        + "".join(f"{name}\n" for name in expected_environment_names)
        + ".\n"
    ).encode("ascii")
    if len(expected) > CHILD_ENVIRONMENT_READY_MAX_BYTES:
        raise RuntimeError("sandbox wrapper launch-barrier expectation is too large")
    deadline = time.monotonic() + timeout_ms / 1000
    payload = bytearray()
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("sandbox wrapper did not reach the launch barrier")
        ready, _, _ = select.select([descriptor], [], [], remaining)
        if ready != [descriptor]:
            raise TimeoutError("sandbox wrapper did not reach the launch barrier")
        chunk = os.read(descriptor, 4096)
        if not chunk:
            break
        payload.extend(chunk)
        if len(payload) > CHILD_ENVIRONMENT_READY_MAX_BYTES:
            raise RuntimeError("sandbox wrapper launch-barrier payload is too large")
    if bytes(payload) != expected:
        raise RuntimeError(
            "sandbox wrapper launch-barrier environment report is invalid"
        )


def _child_environment(
    environment: dict[str, str], command_cwd: Path
) -> dict[str, str]:
    """Build the fixed, name-by-name environment allowed across the barrier."""

    child = {
        name: environment[name]
        for name in sorted(CHILD_ENVIRONMENT_ALLOWED_NAMES)
        if name not in {"LANG", "LC_ALL", "PATH", "PWD"}
        if name in environment
    }
    path_parts: list[str] = []
    if environment.get("JAVA_HOME"):
        path_parts.append(os.fspath(Path(environment["JAVA_HOME"]) / "bin"))
    if environment.get("ANDROID_SDK_ROOT"):
        path_parts.append(
            os.fspath(Path(environment["ANDROID_SDK_ROOT"]) / "platform-tools")
        )
    path_parts.extend(FIXED_SYSTEM_PATH)
    child.update(
        {
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": ":".join(path_parts),
            "PWD": os.fspath(command_cwd),
        }
    )
    return child


def _canonical_json_sha256(value: object) -> str:
    payload = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _child_environment_evidence(
    environment: dict[str, str], launch_id: str
) -> dict[str, object]:
    allowed_names = sorted(
        CHILD_ENVIRONMENT_ALLOWED_NAMES | CHILD_ENVIRONMENT_RUNTIME_NAMES
    )
    actual_names = sorted(environment)
    return {
        "schema": CHILD_ENVIRONMENT_SCHEMA,
        "version": CHILD_ENVIRONMENT_VERSION,
        "launchId": launch_id,
        "allowedNames": allowed_names,
        "allowedNamesSha256": _canonical_json_sha256(allowed_names),
        "actualNames": actual_names,
        "actualNamesSha256": _canonical_json_sha256(actual_names),
        "actualNamesObservationPoint": "cooperative-sealed-wrapper-pre-release-barrier-v1",
        # The barrier reports exported names only. This digest commits the
        # producer's planned values; it is not evidence that the wrapper or
        # kernel observed those values.
        "producerPlannedEnvironmentValuesSha256": _canonical_json_sha256(environment),
        "plannedNamesMatchBarrier": True,
        "valuesObserved": False,
        # The sealed wrapper adds these only after the name-only barrier has
        # been authorized and released. They are intentionally absent from
        # actualNames, which is exclusively the barrier-time observation.
        "postBarrierAddedNames": list(CHILD_ENVIRONMENT_POST_BARRIER_ADDED_NAMES),
        "credentialNamesAssertedAbsent": sorted(CREDENTIAL_ABSENCE_ASSERTION_NAMES),
        "forbiddenCredentialNamesPresent": sorted(
            set(environment) & CREDENTIAL_ABSENCE_ASSERTION_NAMES
        ),
    }


def child_environment_evidence_path(authority_path: Path) -> Path:
    suffix = ".process-authority.json"
    if authority_path.name.endswith(suffix):
        name = authority_path.name[: -len(suffix)] + ".child-environment.json"
    else:
        name = authority_path.name + ".child-environment.json"
    return authority_path.with_name(name)


def _terminate_blocked_child(
    child: subprocess.Popen[bytes],
    process_scope: ModuleType,
    expected_record: object | None,
) -> None:
    """Reap a barrier-blocked wrapper without group or PID-only signaling."""

    child.poll()
    if child.returncode is not None:
        return
    try:
        child.wait(timeout=0.5)
        return
    except subprocess.TimeoutExpired:
        pass
    record = expected_record
    if record is None:
        record = process_scope._record_for_pid(child.pid)
    if record is None:
        try:
            child.wait(timeout=0.5)
            return
        except subprocess.TimeoutExpired as error:
            raise RuntimeError(
                "unsealed sandbox child identity disappeared without reaping"
            ) from error
    identity = record.identity
    if (
        record.pid != child.pid
        or identity.uid != os.getuid()
        or identity.ppid != os.getpid()
        or not (identity.pid == identity.pgid == identity.sid)
    ):
        raise RuntimeError("unsealed sandbox child identity is unsafe")
    if not process_scope._signal_exact(record, signal.SIGKILL):
        try:
            child.wait(timeout=0.5)
            return
        except subprocess.TimeoutExpired as error:
            raise RuntimeError(
                "unsealed sandbox child changed identity without reaping"
            ) from error
    try:
        child.wait(timeout=2)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError("unsealed sandbox child survived SIGKILL") from error


def launch_authorized_child(
    command: list[str],
    *,
    cwd: Path,
    environment: dict[str, str],
    authority_path: Path,
    owner_root_pid: int,
    wrapper_path: Path,
    wrapper_sha256: str,
    stdout: int | BinaryIO | None = None,
    stderr: int | BinaryIO | None = None,
    barrier_timeout_ms: int = 5000,
) -> tuple[subprocess.Popen[bytes], dict[str, object]]:
    if min(owner_root_pid, barrier_timeout_ms) <= 0:
        raise ValueError("unsafe owner PID or barrier timeout")
    if SHA256_PATTERN.fullmatch(wrapper_sha256) is None:
        raise ValueError("wrapper SHA-256 is invalid")
    wrapper = wrapper_path.resolve(strict=True)
    if wrapper != wrapper_path or not command or Path(command[0]) != wrapper:
        raise RuntimeError("sandbox command does not use the sealed wrapper")
    if any(name in environment for name in (LAUNCH_MARKER, RELEASE_FD, READY_FD)):
        raise RuntimeError("ambient sandbox launch authority is not allowed")
    command_cwd = _canonical_directory(cwd, "command cwd")
    roots = roots_from_environment(environment)
    process_scope = _load_process_scope()
    launch_id = os.urandom(16).hex()
    if LAUNCH_ID_PATTERN.fullmatch(launch_id) is None:
        raise AssertionError("generated launch ID is not canonical")

    release_read, release_write = os.pipe()
    ready_read, ready_write = os.pipe()
    child: subprocess.Popen[bytes] | None = None
    blocked_record: object | None = None
    released = False
    try:
        child_environment = _child_environment(environment, command_cwd)
        child_environment.update(
            {
                LAUNCH_MARKER: launch_id,
                RELEASE_FD: str(release_read),
                READY_FD: str(ready_write),
            }
        )
        child = subprocess.Popen(
            command,
            cwd=command_cwd,
            env=child_environment,
            stdin=subprocess.DEVNULL,
            stdout=stdout,
            stderr=stderr,
            start_new_session=True,
            pass_fds=(release_read, ready_write),
        )
        os.close(release_read)
        release_read = -1
        os.close(ready_write)
        ready_write = -1
        _read_ready(
            ready_read,
            barrier_timeout_ms,
            launch_id,
            sorted(child_environment),
        )
        blocked_record = process_scope._record_for_pid(child.pid)
        if blocked_record is None:
            raise RuntimeError("sandbox wrapper identity disappeared at launch barrier")
        signal_authority = process_scope.create_launch_authority(
            child_pid=child.pid,
            owner_root_pid=owner_root_pid,
            launch_id=launch_id,
            wrapper_path=wrapper,
            wrapper_sha256=wrapper_sha256,
            command_cwd=command_cwd,
            roots=roots,
            authority_path=authority_path,
        )
        environment_evidence = _child_environment_evidence(child_environment, launch_id)
        _write_json(
            child_environment_evidence_path(authority_path),
            environment_evidence,
            "child-environment evidence",
        )
        authority = signal_authority
        written = os.write(release_write, b"G")
        if written != 1:
            raise RuntimeError("sandbox launch barrier release was incomplete")
        released = True
        return child, authority
    except BaseException:
        if release_write >= 0:
            os.close(release_write)
            release_write = -1
        if child is not None:
            _terminate_blocked_child(child, process_scope, blocked_record)
        raise
    finally:
        for descriptor in (release_read, release_write, ready_read, ready_write):
            if descriptor >= 0:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
        if child is not None and not released and child.poll() is None:
            _terminate_blocked_child(child, process_scope, blocked_record)


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--authority", required=True, type=Path)
    parser.add_argument("--reference-authority", type=Path, action="append", default=[])
    parser.add_argument("--scope-evidence", required=True, type=Path)
    parser.add_argument("--result", required=True, type=Path)
    parser.add_argument("--label", required=True)
    parser.add_argument("--cwd", required=True, type=Path)
    parser.add_argument("--owner-root-pid", required=True, type=int)
    parser.add_argument("--wrapper", required=True, type=Path)
    parser.add_argument("--wrapper-sha256", required=True)
    parser.add_argument("--barrier-ms", type=int, default=5000)
    parser.add_argument("--freeze-ms", type=int, default=5000)
    parser.add_argument("--term-ms", type=int, default=5000)
    parser.add_argument("--kill-ms", type=int, default=5000)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if not args.command:
        parser.error("a sandbox command is required after --")
    if (
        not re.fullmatch(r"[a-z0-9][a-z0-9-]*", args.label)
        or min(
            args.owner_root_pid,
            args.barrier_ms,
            args.freeze_ms,
            args.term_ms,
            args.kill_ms,
        )
        <= 0
    ):
        parser.error("unsafe label, PID, or timeout")
    return args


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    result: dict[str, object] = {
        "version": 1,
        "label": args.label,
        "status": "supervisor_error",
        "commandExitCode": None,
        "authority": None,
        "scopeTermination": None,
    }
    child: subprocess.Popen[bytes] | None = None
    authority_written = False
    received_signal: int | None = None
    observed_exit: int | None = None
    child_reaped = False
    containment_succeeded = False
    process_scope: ModuleType | None = None
    exit_code = 1

    class SupervisorSignal(Exception):
        pass

    def interrupt(signum: int, _frame: object) -> None:
        nonlocal received_signal
        if received_signal is None:
            received_signal = signum
        raise SupervisorSignal(f"received signal {signum}")

    previous_handlers = {
        signum: signal.signal(signum, interrupt)
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    }
    try:
        contained_signals = {signal.SIGINT, signal.SIGTERM, signal.SIGHUP}
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, contained_signals)
        try:
            child, authority = launch_authorized_child(
                args.command,
                cwd=args.cwd,
                environment=os.environ.copy(),
                authority_path=args.authority,
                owner_root_pid=args.owner_root_pid,
                wrapper_path=args.wrapper,
                wrapper_sha256=args.wrapper_sha256,
                barrier_timeout_ms=args.barrier_ms,
            )
            authority_written = True
        finally:
            # Deliver cleanup signals only after the released session is bound
            # to an authority that the finally block can contain.
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        result["authority"] = authority
        result["authoritySha256"] = hashlib.sha256(
            args.authority.read_bytes()
        ).hexdigest()
        result["childPid"] = child.pid
        command_exit = observe_child_exit(child)
        if command_exit is None:
            raise RuntimeError("blocking waitid returned no child status")
        observed_exit = command_exit
        result["commandExitCode"] = command_exit
        result["status"] = "completed" if command_exit == 0 else "command_failed"
        exit_code = command_exit if 0 <= command_exit < 126 else 1
    except BaseException as error:
        result["error"] = f"{type(error).__name__}: {error}"
        exit_code = 128 + received_signal if received_signal is not None else 1
    finally:
        if authority_written:
            try:
                process_scope = _load_process_scope()
                scope = process_scope.contain_and_write(
                    [args.authority],
                    args.scope_evidence,
                    freeze_ms=args.freeze_ms,
                    term_ms=args.term_ms,
                    kill_ms=args.kill_ms,
                    reference_authority_paths=args.reference_authority,
                )
                result["scopeTermination"] = scope
                result["scopeEvidenceSha256"] = hashlib.sha256(
                    args.scope_evidence.read_bytes()
                ).hexdigest()
                if scope.get("status") != "quiescent":
                    result["statusBeforeScopeFailure"] = result["status"]
                    result["status"] = "scope_containment_failed"
                    exit_code = 72
                else:
                    containment_succeeded = True
            except BaseException as error:
                result["scopeTermination"] = {
                    "status": "error",
                    "error": f"{type(error).__name__}: {error}",
                }
                result["statusBeforeScopeFailure"] = result["status"]
                result["status"] = "scope_containment_failed"
                exit_code = 72
        if child is not None and authority_written:
            try:
                if containment_succeeded:
                    reaped_exit = reap_child(child, observed_exit, timeout=2)
                else:
                    if process_scope is None:
                        process_scope = _load_process_scope()
                    reaped_exit = contain_failure_reap(
                        child,
                        authority,
                        process_scope,
                        observed_exit,
                    )
                child_reaped = True
                if result["commandExitCode"] is None:
                    result["commandExitCode"] = reaped_exit
            except BaseException as error:
                result["reapError"] = f"{type(error).__name__}: {error}"
                result["statusBeforeReapFailure"] = result["status"]
                result["status"] = "scope_containment_failed"
                exit_code = 72
        try:
            _write_json(args.result, result, "scoped-command result")
        except BaseException as error:
            print(f"scoped-command result write failed: {error}", file=sys.stderr)
            exit_code = 1
        for signum, previous in previous_handlers.items():
            signal.signal(signum, previous)
        if child is not None and authority_written and not child_reaped:
            raise RuntimeError("authorized child was not reaped after containment")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
