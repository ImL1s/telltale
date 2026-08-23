#!/usr/bin/env python3
"""Start pinned Ircama on loopback instead of its all-interface default."""

from __future__ import annotations

import os
from pathlib import Path
import signal
import sys


def _terminate(signum: int, _frame: object) -> None:
    # Ircama's batch-mode loop does not reliably leave on SIGTERM by itself.
    # CI and the local controller need a bounded, waitable direct child rather
    # than an emulator that survives cleanup until it is force-killed.
    raise SystemExit(128 + signum)


def configure_ircama_runtime(
    interpreter: object,
    argv: list[str],
) -> list[str]:
    """Put Ircama's daemon state inside the controller's private directory."""
    if len(argv) < 3 or argv[0] != "--pid-directory":
        raise ValueError("--pid-directory and emulator arguments are required")
    state = Path(argv[1])
    if not state.is_absolute() or state.is_symlink() or not state.is_dir():
        raise ValueError("Ircama PID directory must be a private directory")
    metadata = state.stat()
    if metadata.st_uid != os.geteuid() or metadata.st_mode & 0o077:
        raise ValueError("Ircama PID directory must be private and owner-only")

    directory = f"{state}{os.sep}"
    interpreter.DAEMON_PIDFILE_DIR_ROOT = directory
    interpreter.DAEMON_PIDFILE_DIR_NON_ROOT = directory
    interpreter.DAEMON_PIDFILE = "ircama.pid"
    interpreter.DAEMON_DIR = str(state)
    interpreter.DAEMON_UMASK = 0o077
    return argv[2:]


def run(argv: list[str] | None = None) -> None:
    import elm.elm
    import elm.interpreter

    args = sys.argv[1:] if argv is None else argv
    try:
        emulator_args = configure_ircama_runtime(elm.interpreter, args)
    except ValueError as error:
        raise SystemExit(str(error)) from error
    # Ircama 3.0.5 otherwise binds "" (0.0.0.0). The BLE bridge is the only
    # intended client, so exposing the single-session emulator to the LAN would
    # let an unrelated peer alter its state and invalidate the rig evidence.
    elm.elm.NETWORK_INTERFACES = "127.0.0.1"
    signal.signal(signal.SIGTERM, _terminate)
    sys.argv = [sys.argv[0], *emulator_args]
    elm.interpreter.main()


if __name__ == "__main__":
    run()
