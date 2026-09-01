#!/usr/bin/env python3
"""Run one long command while fail-closed supervising a live macOS guard."""

import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import select
import signal
import stat
import subprocess
import sys


POLL_SECONDS = 0.05


def load_process_scope_helper():
    path = pathlib.Path(__file__).resolve().with_name("process_scope.py")
    specification = importlib.util.spec_from_file_location(
        "telltale_gate_c_process_scope",
        path,
    )
    if specification is None or specification.loader is None:
        raise RuntimeError(f"could not load process-scope helper: {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


def load_scoped_command_helper():
    path = pathlib.Path(__file__).resolve().with_name("scoped_command.py")
    specification = importlib.util.spec_from_file_location(
        "telltale_gate_c_scoped_command",
        path,
    )
    if specification is None or specification.loader is None:
        raise RuntimeError(f"could not load scoped-command helper: {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


class SupervisorSignal(Exception):
    pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--guard-pid", type=int, required=True)
    parser.add_argument("--guard-ready", type=pathlib.Path, required=True)
    parser.add_argument("--guard-result", type=pathlib.Path, required=True)
    parser.add_argument("--guard-nonce", required=True)
    parser.add_argument("--log", type=pathlib.Path, required=True)
    parser.add_argument("--result", type=pathlib.Path, required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--cwd", type=pathlib.Path, required=True)
    parser.add_argument("--term-ms", type=int, default=5000)
    parser.add_argument("--kill-ms", type=int, default=5000)
    parser.add_argument("--scope-authority", required=True, type=pathlib.Path)
    parser.add_argument(
        "--scope-reference-authority",
        type=pathlib.Path,
        action="append",
        default=[],
    )
    parser.add_argument("--scope-evidence", required=True, type=pathlib.Path)
    parser.add_argument("--scope-owner-root-pid", required=True, type=int)
    parser.add_argument("--scope-wrapper", required=True, type=pathlib.Path)
    parser.add_argument("--scope-wrapper-sha256", required=True)
    parser.add_argument("--scope-freeze-ms", type=int, default=5000)
    parser.add_argument("--scope-term-ms", type=int, default=5000)
    parser.add_argument("--scope-kill-ms", type=int, default=5000)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if not args.command:
        parser.error("a command is required after --")
    if (
        args.guard_pid <= 1
        or min(
            args.term_ms,
            args.kill_ms,
            args.scope_freeze_ms,
            args.scope_term_ms,
            args.scope_kill_ms,
        )
        < 0
    ):
        parser.error("unsafe PID or timeout")
    if args.scope_owner_root_pid <= 1:
        parser.error("process-scope owner PID is unsafe")
    if len(args.guard_nonce) != 32 or any(
        character not in "0123456789abcdef" for character in args.guard_nonce
    ):
        parser.error("guard nonce is not canonical")
    return args


def require_new_owned_file(path: pathlib.Path, label: str) -> int:
    parent = path.parent.resolve(strict=True)
    parent_status = os.lstat(parent)
    if not pathlib.Path(parent).is_dir() or parent_status.st_uid != os.getuid():
        raise RuntimeError(f"unsafe {label} parent")
    return os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)


def validate_cwd(path: pathlib.Path) -> pathlib.Path:
    if not path.is_absolute():
        raise RuntimeError("command cwd is not absolute")
    canonical = path.resolve(strict=True)
    if canonical != path:
        raise RuntimeError("command cwd is not canonical")
    current = pathlib.Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        status = os.lstat(current)
        if stat.S_ISLNK(status.st_mode):
            raise RuntimeError(f"command cwd contains a symlink: {current}")
    status = os.lstat(path)
    if not stat.S_ISDIR(status.st_mode) or status.st_uid != os.getuid():
        raise RuntimeError("command cwd is unsafe")
    return canonical


def write_result(path: pathlib.Path, value: dict[str, object]) -> None:
    descriptor = require_new_owned_file(path, "result")
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        json.dump(value, output, sort_keys=True, separators=(",", ":"))
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())


def scope_termination_label(scope: dict[str, object]) -> str:
    if scope.get("killSentProcesses"):
        return "killed"
    if scope.get("termSentProcesses"):
        return "terminated"
    return "natural_exit"


def validate_guard(args: argparse.Namespace) -> select.kqueue:
    if args.guard_result.exists() or args.guard_result.is_symlink():
        raise RuntimeError("source-tree guard already produced a terminal result")
    ready_status = os.lstat(args.guard_ready)
    if (
        not stat.S_ISREG(ready_status.st_mode)
        or ready_status.st_nlink != 1
        or ready_status.st_uid != os.getuid()
        or ready_status.st_mode & 0o022
    ):
        raise RuntimeError("source-tree guard readiness evidence is unsafe")
    ready = json.loads(args.guard_ready.read_text(encoding="utf-8"))
    if ready.get("pid") != args.guard_pid or ready.get("nonce") != args.guard_nonce:
        raise RuntimeError("source-tree guard readiness identity mismatch")
    queue = select.kqueue()
    event = select.kevent(
        args.guard_pid,
        filter=select.KQ_FILTER_PROC,
        flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
        fflags=select.KQ_NOTE_EXIT,
    )
    queue.control([event], 0, 0)
    if queue.control([], 1, 0) or args.guard_result.exists():
        queue.close()
        raise RuntimeError("source-tree guard exited before command launch")
    return queue


def main() -> int:
    args = parse_args()
    command_cwd: pathlib.Path | None = None
    result: dict[str, object] = {
        "version": 1,
        "label": args.label,
        "guardPid": args.guard_pid,
        "guardExitObserved": False,
        "commandExitCode": None,
        "termination": "not_started",
        "scopeTermination": "not_configured",
        "status": "supervisor_error",
    }
    child: subprocess.Popen[bytes] | None = None
    queue: select.kqueue | None = None
    log_descriptor: int | None = None
    exit_code = 1
    received_signal: int | None = None
    scoped_command = None
    process_scope = None
    observed_exit: int | None = None
    child_reaped = False
    containment_succeeded = False
    authority = None

    def interrupt(signum: int, _frame: object) -> None:
        nonlocal received_signal
        if received_signal is not None:
            return
        received_signal = signum
        for contained_signal in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(contained_signal, signal.SIG_IGN)
        raise SupervisorSignal(f"received signal {signum}")

    previous_handlers = {
        signum: signal.signal(signum, interrupt)
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    }
    try:
        command_cwd = validate_cwd(args.cwd)
        queue = validate_guard(args)
        log_descriptor = require_new_owned_file(args.log, "log")
        contained_signals = {signal.SIGINT, signal.SIGTERM, signal.SIGHUP}
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, contained_signals)
        try:
            scoped_command = load_scoped_command_helper()
            child, authority = scoped_command.launch_authorized_child(
                args.command,
                cwd=command_cwd,
                environment=os.environ.copy(),
                authority_path=args.scope_authority,
                owner_root_pid=args.scope_owner_root_pid,
                wrapper_path=args.scope_wrapper,
                wrapper_sha256=args.scope_wrapper_sha256,
                stdout=log_descriptor,
                stderr=subprocess.STDOUT,
            )
            result["childPid"] = child.pid
            result["childPgid"] = child.pid
            result["scopeAuthority"] = authority
            result["scopeAuthoritySha256"] = hashlib.sha256(
                args.scope_authority.read_bytes()
            ).hexdigest()
            result["termination"] = "none"
        finally:
            # A pending runner cleanup signal is delivered only after the
            # spawned session is fully recorded and therefore containable.
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        while True:
            if queue.control([], 1, POLL_SECONDS):
                result["guardExitObserved"] = True
                result["status"] = "guard_exited"
                observed_exit = scoped_command.observe_child_exit(child, nohang=True)
                result["commandExitCode"] = observed_exit
                exit_code = 70
                break
            command_exit = scoped_command.observe_child_exit(child, nohang=True)
            if command_exit is None:
                continue
            observed_exit = command_exit
            # Prefer a guard failure that raced the command's terminal event.
            if queue.control([], 1, 0) or args.guard_result.exists():
                result["guardExitObserved"] = True
                result["status"] = "guard_exited"
                result["commandExitCode"] = command_exit
                exit_code = 70
                break
            result["commandExitCode"] = command_exit
            if command_exit == 0:
                result["status"] = "completed"
                result["termination"] = "natural_exit"
                exit_code = 0
            else:
                result["status"] = "command_failed"
                result["termination"] = "natural_exit"
                exit_code = command_exit if 0 < command_exit < 126 else 1
            break
    except BaseException as error:
        result["error"] = f"{type(error).__name__}: {error}"
        exit_code = 128 + received_signal if received_signal is not None else 1
    finally:
        if args.scope_authority is not None:
            try:
                if not args.scope_authority.exists():
                    raise RuntimeError("sandbox launch authority was not created")
                process_scope = load_process_scope_helper()
                scope_result = process_scope.contain_and_write(
                    [args.scope_authority],
                    args.scope_evidence,
                    freeze_ms=args.scope_freeze_ms,
                    term_ms=args.scope_term_ms,
                    kill_ms=args.scope_kill_ms,
                    reference_authority_paths=args.scope_reference_authority,
                )
                result["scopeTermination"] = scope_result
                result["scopeEvidenceSha256"] = hashlib.sha256(
                    args.scope_evidence.read_bytes()
                ).hexdigest()
                scope_termination = scope_termination_label(scope_result)
                if (
                    result["termination"] != "natural_exit"
                    or scope_termination != "natural_exit"
                ):
                    result["termination"] = scope_termination
                if result["status"] == "completed" and scope_result.get(
                    "stoppedProcesses"
                ):
                    result["status"] = "orphaned_session"
                    exit_code = 71
                if scope_result.get("status") != "quiescent":
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
        if child is not None and args.scope_authority.exists():
            try:
                if scoped_command is None:
                    scoped_command = load_scoped_command_helper()
                if containment_succeeded:
                    reaped_exit = scoped_command.reap_child(
                        child,
                        observed_exit,
                        timeout=2,
                    )
                else:
                    if authority is None:
                        raise RuntimeError("sandbox launch authority is unavailable")
                    if process_scope is None:
                        process_scope = load_process_scope_helper()
                    reaped_exit = scoped_command.contain_failure_reap(
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
        if log_descriptor is not None:
            os.close(log_descriptor)
            result["logSha256"] = hashlib.sha256(args.log.read_bytes()).hexdigest()
        if queue is not None:
            queue.close()
        try:
            write_result(args.result, result)
        except BaseException as error:
            print(f"guarded command result write failed: {error}", file=sys.stderr)
            exit_code = 1
        for signum, previous in previous_handlers.items():
            signal.signal(signum, previous)
        if child is not None and args.scope_authority.exists() and not child_reaped:
            raise RuntimeError("authorized child was not reaped after containment")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
