#!/usr/bin/env python3
"""Verify exact macOS process identity for the local BLE test rig.

The shell controller must never signal a PID solely because a pidfile still
contains that number.  This helper reads the kernel's NUL-delimited argv and
environment, resolves the executable path, and includes the process start time
in a stable fingerprint so PID reuse fails closed.
"""

from __future__ import annotations

from dataclasses import dataclass
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys


CTL_KERN = 1
KERN_PROCARGS2 = 49
PROC_PIDPATHINFO_MAXSIZE = 4096
TOKEN_PATTERN = re.compile(r"[0-9a-f]{32}\Z")


@dataclass(frozen=True)
class ProcessSnapshot:
    executable: str
    argv: tuple[str, ...]
    environment: dict[str, str]
    started: str

    @property
    def fingerprint(self) -> str:
        payload = json.dumps(
            {
                "argv": self.argv,
                "executable": self.executable,
                "started": self.started,
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        return hashlib.sha256(payload).hexdigest()


def _python_process_executable(venv: Path) -> str:
    """Return the executable path macOS reports for a framework Python."""
    resolved_python = Path(os.path.realpath(venv / "bin/python"))
    python_app = (
        resolved_python.parent.parent
        / "Resources/Python.app/Contents/MacOS/Python"
    )
    return os.path.realpath(python_app if python_app.exists() else resolved_python)


def _split_procargs(data: bytes) -> tuple[tuple[str, ...], dict[str, str]]:
    if len(data) < struct.calcsize("i"):
        raise RuntimeError("KERN_PROCARGS2 returned a truncated buffer")
    argc = struct.unpack_from("i", data)[0]
    if argc <= 0:
        raise RuntimeError("KERN_PROCARGS2 returned an invalid argc")

    offset = struct.calcsize("i")
    executable_end = data.find(b"\0", offset)
    if executable_end < 0:
        raise RuntimeError("KERN_PROCARGS2 omitted the executable terminator")
    offset = executable_end + 1
    while offset < len(data) and data[offset] == 0:
        offset += 1

    argv: list[str] = []
    for _ in range(argc):
        end = data.find(b"\0", offset)
        if end < 0:
            raise RuntimeError("KERN_PROCARGS2 omitted an argv terminator")
        argv.append(data[offset:end].decode("utf-8", errors="surrogateescape"))
        offset = end + 1

    while offset < len(data) and data[offset] == 0:
        offset += 1
    environment: dict[str, str] = {}
    while offset < len(data):
        end = data.find(b"\0", offset)
        if end < 0 or end == offset:
            break
        entry = data[offset:end].decode("utf-8", errors="surrogateescape")
        if "=" in entry:
            key, value = entry.split("=", 1)
            environment[key] = value
        offset = end + 1
    return tuple(argv), environment


def snapshot_process(pid: int) -> ProcessSnapshot:
    if sys.platform != "darwin":
        raise RuntimeError("exact BLE rig process identity requires macOS")
    if pid <= 0:
        raise ValueError("pid must be positive")

    libc = ctypes.CDLL(None, use_errno=True)
    mib = (ctypes.c_int * 3)(CTL_KERN, KERN_PROCARGS2, pid)
    size = ctypes.c_size_t()
    if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0:
        raise ProcessLookupError(ctypes.get_errno(), os.strerror(ctypes.get_errno()))
    buffer = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0) != 0:
        raise ProcessLookupError(ctypes.get_errno(), os.strerror(ctypes.get_errno()))
    argv, environment = _split_procargs(buffer.raw[: size.value])

    path_buffer = ctypes.create_string_buffer(PROC_PIDPATHINFO_MAXSIZE)
    length = libc.proc_pidpath(pid, path_buffer, len(path_buffer))
    if length <= 0:
        raise ProcessLookupError(ctypes.get_errno(), os.strerror(ctypes.get_errno()))
    executable = os.path.realpath(os.fsdecode(path_buffer.value))

    completed = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "lstart="],
        check=False,
        capture_output=True,
        text=True,
        env={"LC_ALL": "C", "PATH": "/usr/bin:/bin"},
    )
    started = completed.stdout.strip()
    if completed.returncode != 0 or not started:
        raise ProcessLookupError(f"could not read start time for pid {pid}")
    return ProcessSnapshot(executable, argv, environment, started)


def matches_rig_process(
    snapshot: ProcessSnapshot,
    *,
    name: str,
    token: str,
    here: Path,
    venv: Path,
    app: Path,
    state: Path,
    port: int,
) -> bool:
    if TOKEN_PATTERN.fullmatch(token) is None:
        return False
    if name == "emulator":
        expected_executable = _python_process_executable(venv)
        argv = snapshot.argv
        return (
            snapshot.executable == expected_executable
            and len(argv) == 9
            and argv[0] == expected_executable
            and argv[1] == str(here / "emulator_entrypoint.py")
            and argv[2] == "--pid-directory"
            and os.path.normpath(argv[3]) == os.path.normpath(state)
            and argv[4:] == ("-d", "-n", str(port), "-s", "car")
            and snapshot.environment.get("TELLTALE_RIG_TOKEN") == token
        )
    if name == "bridge":
        # BleHost is a copied framework-Python launcher. macOS reports the
        # framework's Python.app executable after it starts, not the copied
        # bundle path, while argv still proves the exact bridge entry point.
        expected_executable = _python_process_executable(venv)
        argv = snapshot.argv
        return (
            snapshot.executable == expected_executable
            and len(argv) == 10
            and os.path.realpath(argv[0]) == expected_executable
            and argv[1] == "-u"
            and argv[2] == str(here / "bridge.py")
            and argv[3].isdigit()
            and int(argv[3]) > 0
            and os.path.normpath(argv[4]) == os.path.normpath(state / "bridge.pid")
            and argv[5].isdigit()
            and argv[6].isdigit()
            and argv[7].isdigit()
            and argv[8] == token
            and os.path.normpath(argv[9]) == os.path.normpath(state.parent)
        )
    return False


def ownership_token(snapshot: ProcessSnapshot, *, name: str) -> str | None:
    """Extract a candidate token without treating it as proof of ownership."""
    if name == "emulator":
        token = snapshot.environment.get("TELLTALE_RIG_TOKEN", "")
    elif name == "bridge" and len(snapshot.argv) == 10:
        token = snapshot.argv[8]
    else:
        return None
    return token if TOKEN_PATTERN.fullmatch(token) is not None else None


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    discover = bool(args and args[0] == "--discover")
    if discover:
        args = args[1:]
        if len(args) != 7:
            raise SystemExit(
                "usage: process_identity.py --discover NAME PID HERE VENV APP "
                "STATE PORT"
            )
        name, pid_text, here, venv, app, state, port_text = args
        try:
            snapshot = snapshot_process(int(pid_text))
            token = ownership_token(snapshot, name=name)
            matched = token is not None and matches_rig_process(
                snapshot,
                name=name,
                token=token,
                here=Path(here),
                venv=Path(venv),
                app=Path(app),
                state=Path(state),
                port=int(port_text),
            )
        except (OSError, RuntimeError, ValueError):
            return 1
        if not matched or token is None:
            return 1
        print(f"{token} {snapshot.fingerprint}")
        return 0
    if len(args) not in (8, 9):
        raise SystemExit(
            "usage: process_identity.py NAME PID TOKEN HERE VENV APP STATE PORT "
            "[EXPECTED_FINGERPRINT]"
        )
    name, pid_text, token, here, venv, app, state, port_text, *expected = args
    try:
        snapshot = snapshot_process(int(pid_text))
        matched = matches_rig_process(
            snapshot,
            name=name,
            token=token,
            here=Path(here),
            venv=Path(venv),
            app=Path(app),
            state=Path(state),
            port=int(port_text),
        )
    except (OSError, RuntimeError, ValueError):
        return 1
    if not matched:
        return 1
    fingerprint = snapshot.fingerprint
    if expected and expected[0] != fingerprint:
        return 1
    print(fingerprint)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
