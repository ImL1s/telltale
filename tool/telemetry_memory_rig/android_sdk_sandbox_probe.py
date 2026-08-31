#!/usr/bin/env python3
"""Exercise the Gate C sandbox without mutating the real Android SDK."""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import pathlib
import stat
import subprocess
import sys


def _denied(label: str, operation) -> dict[str, object]:
    try:
        operation()
    except PermissionError as error:
        return {"denied": True, "errno": error.errno, "operation": label}
    except OSError as error:
        return {
            "denied": error.errno in {1, 13, 30},
            "errno": error.errno,
            "operation": label,
        }
    return {"denied": False, "errno": None, "operation": label}


def _attempt_create(path: pathlib.Path) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.close(descriptor)


def _set_xattr(path: pathlib.Path) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    libc.setxattr.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.c_uint32,
        ctypes.c_int,
    ]
    libc.setxattr.restype = ctypes.c_int
    value = b"denied"
    buffer = ctypes.create_string_buffer(value)
    result = libc.setxattr(
        os.fsencode(path), b"user.telltale", buffer, len(value), 0, 0
    )
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), path)


def _descendant(arguments: argparse.Namespace) -> int:
    denied = _denied("descendant-create", lambda: _attempt_create(arguments.denied))
    value: dict[str, object] = {"depth": arguments.depth, "write": denied}
    if arguments.depth < 2:
        completed = subprocess.run(
            [
                sys.executable,
                "-I",
                "-S",
                "-B",
                str(pathlib.Path(__file__).resolve()),
                "descendant",
                "--denied",
                str(arguments.denied.with_name(f"grandchild-{arguments.depth}")),
                "--depth",
                str(arguments.depth + 1),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        value["childReturnCode"] = completed.returncode
        value["child"] = json.loads(completed.stdout) if completed.returncode == 0 else None
    print(json.dumps(value, sort_keys=True, separators=(",", ":")))
    return 0 if denied["denied"] else 1


def _probe(arguments: argparse.Namespace) -> int:
    denied_root = arguments.denied_root
    allowed_root = arguments.allowed_root
    known_packages = arguments.known_packages
    readable = denied_root / "readable"
    delete_target = denied_root / "delete-target"
    rename_source = denied_root / "rename-source"
    chmod_target = denied_root / "chmod-target"
    xattr_target = denied_root / "xattr-target"

    read_value = readable.read_text(encoding="utf-8")
    operations = [
        _denied("write", lambda: readable.write_text("changed", encoding="utf-8")),
        _denied("open-write", lambda: os.close(os.open(readable, os.O_WRONLY))),
        _denied("create", lambda: _attempt_create(denied_root / "created")),
        _denied("delete", delete_target.unlink),
        _denied("rename", lambda: rename_source.rename(denied_root / "renamed")),
        _denied("chmod", lambda: chmod_target.chmod(0o644)),
        _denied("xattr", lambda: _set_xattr(xattr_target)),
    ]
    sdk_open = _denied(
        "sdk-open-write",
        lambda: os.close(os.open(known_packages, os.O_WRONLY)),
    )
    allowed = allowed_root / "allowed-write"
    allowed.write_text("allowed\n", encoding="utf-8")
    child = subprocess.run(
        [
            sys.executable,
            "-I",
            "-S",
            "-B",
            str(pathlib.Path(__file__).resolve()),
            "descendant",
            "--denied",
            str(denied_root / "child-created"),
            "--depth",
            "1",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    child_value = json.loads(child.stdout) if child.returncode == 0 else None
    denied_state_unchanged = (
        readable.read_text(encoding="utf-8") == "readable\n"
        and delete_target.exists()
        and rename_source.exists()
        and not (denied_root / "renamed").exists()
        and not (denied_root / "created").exists()
        and stat.S_IMODE(chmod_target.stat().st_mode) == 0o600
        and not (denied_root / "child-created").exists()
        and not (denied_root / "grandchild-1").exists()
    )
    success = (
        read_value == "readable\n"
        and all(item["denied"] for item in operations)
        and sdk_open["denied"]
        and allowed.read_text(encoding="utf-8") == "allowed\n"
        and child.returncode == 0
        and child_value is not None
        and child_value["write"]["denied"]
        and child_value["child"]["write"]["denied"]
        and denied_state_unchanged
    )
    value = {
        "allowedWrite": success and allowed.exists(),
        "child": child_value,
        "deniedOperations": operations,
        "deniedStateUnchanged": denied_state_unchanged,
        "readSucceeded": read_value == "readable\n",
        "sdkOpenWrite": sdk_open,
        "status": "passed" if success else "failed",
        "version": 1,
    }
    print(json.dumps(value, sort_keys=True, separators=(",", ":")))
    return 0 if success else 1


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    probe = subparsers.add_parser("probe")
    probe.add_argument("--denied-root", required=True, type=pathlib.Path)
    probe.add_argument("--allowed-root", required=True, type=pathlib.Path)
    probe.add_argument("--known-packages", required=True, type=pathlib.Path)
    descendant = subparsers.add_parser("descendant")
    descendant.add_argument("--denied", required=True, type=pathlib.Path)
    descendant.add_argument("--depth", required=True, type=int)
    return parser


def main() -> int:
    arguments = _parser().parse_args()
    return _probe(arguments) if arguments.command == "probe" else _descendant(arguments)


if __name__ == "__main__":
    raise SystemExit(main())
