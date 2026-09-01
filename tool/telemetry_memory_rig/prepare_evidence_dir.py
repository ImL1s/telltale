#!/usr/bin/env python3
"""Create confined, owner-only Gate C evidence directories.

The helper intentionally accepts only three fixed layouts.  It never chmods an
existing path and never removes anything:

* ``default`` creates ``.omx/logs/telemetry-memory-rig-*``.
* ``wrapper-create`` creates
  ``.omx/evidence/telemetry-v1/oracles/final/memory-gate-c-*``.
* ``wrapper-runner`` validates a wrapper-created directory and creates a fresh
  ``telemetry-memory-rig-*`` child inside it.

Successful CLI invocations print exactly one canonical absolute path.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import stat
import tempfile


DEFAULT_PARENT = pathlib.PurePosixPath(".omx/logs")
WRAPPER_PARENT = pathlib.PurePosixPath(
    ".omx/evidence/telemetry-v1/oracles/final"
)
RUNNER_PREFIX = "telemetry-memory-rig-"
WRAPPER_PREFIX = "memory-gate-c-"
ALLOWED_WRAPPER_PRELUDE = frozenset(
    {
        "runner.log",
        "wrapper-before-state.txt",
        "wrapper-identity.txt",
    }
)
# tempfile.mkdtemp() may begin its random suffix with an underscore.
SAFE_SUFFIX = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9._-]*$")


def _has_control(value: str) -> bool:
    return any(ord(character) < 32 or ord(character) == 127 for character in value)


def _lexical_absolute(path: pathlib.Path, label: str) -> pathlib.Path:
    text = os.fspath(path)
    if not text or _has_control(text):
        raise ValueError(f"control character or empty {label}: {text!r}")
    return pathlib.Path(os.path.abspath(text))


def _lstat(path: pathlib.Path, label: str) -> os.stat_result:
    try:
        metadata = path.lstat()
    except FileNotFoundError as error:
        raise ValueError(f"missing {label}: {path}") from error
    if stat.S_ISLNK(metadata.st_mode):
        raise ValueError(f"symlinked {label}: {path}")
    return metadata


def _validate_owned_directory(
    path: pathlib.Path,
    label: str,
    *,
    exact_private_mode: bool = False,
) -> None:
    metadata = _lstat(path, label)
    if not stat.S_ISDIR(metadata.st_mode):
        raise ValueError(f"{label} is not a directory: {path}")
    if metadata.st_uid != os.getuid():
        raise ValueError(f"wrong owner for {label}: {path}")
    mode = stat.S_IMODE(metadata.st_mode)
    if exact_private_mode:
        if mode != 0o700:
            raise ValueError(f"unsafe mode for {label}: {path} ({mode:o})")
    elif mode & 0o022:
        raise ValueError(f"group/world-writable {label}: {path} ({mode:o})")


def _validate_no_symlink_chain(path: pathlib.Path, label: str) -> None:
    """Reject symlinks and non-directories in every existing component."""
    absolute = _lexical_absolute(path, label)
    current = pathlib.Path(absolute.anchor)
    for part in absolute.parts[1:]:
        current /= part
        metadata = _lstat(current, label)
        if not stat.S_ISDIR(metadata.st_mode):
            raise ValueError(f"{label} is not a directory: {current}")


def _validate_descendant_chain(
    root: pathlib.Path,
    path: pathlib.Path,
    label: str,
) -> None:
    relative = path.relative_to(root)
    current = root
    _validate_owned_directory(current, label)
    for part in relative.parts:
        current /= part
        _validate_owned_directory(current, label)


def _app_root(path: pathlib.Path) -> pathlib.Path:
    root = _lexical_absolute(path, "app root")
    _validate_no_symlink_chain(root, "app root ancestor")
    _validate_owned_directory(root, "app root")
    return root


def _confined(root: pathlib.Path, candidate: pathlib.Path, label: str) -> pathlib.Path:
    absolute = _lexical_absolute(candidate, label)
    if os.path.commonpath((os.fspath(root), os.fspath(absolute))) != os.fspath(root):
        raise ValueError(f"{label} escapes app root: {candidate}")
    return absolute


def _ensure_parent(root: pathlib.Path, relative: pathlib.PurePosixPath) -> pathlib.Path:
    current = root
    for part in relative.parts:
        if part in {"", ".", ".."} or _has_control(part):
            raise ValueError(f"unsafe evidence parent component: {part!r}")
        current /= part
        try:
            current.mkdir(mode=0o700)
        except FileExistsError:
            _validate_owned_directory(current, "evidence parent")
        else:
            _validate_owned_directory(
                current,
                "created evidence parent",
                exact_private_mode=True,
            )
    return current


def _fresh_child(parent: pathlib.Path, prefix: str) -> pathlib.Path:
    _validate_owned_directory(parent, "evidence parent")
    created = pathlib.Path(tempfile.mkdtemp(prefix=prefix, dir=parent))
    _validate_owned_directory(
        created,
        "created evidence directory",
        exact_private_mode=True,
    )
    return created


def create_default_runner(app_root: pathlib.Path) -> pathlib.Path:
    root = _app_root(app_root)
    parent = _ensure_parent(root, DEFAULT_PARENT)
    return _fresh_child(parent, RUNNER_PREFIX)


def create_wrapper_outer(app_root: pathlib.Path) -> pathlib.Path:
    root = _app_root(app_root)
    parent = _ensure_parent(root, WRAPPER_PARENT)
    return _fresh_child(parent, WRAPPER_PREFIX)


def _validate_prelude_file(path: pathlib.Path) -> None:
    metadata = _lstat(path, "wrapper prelude file")
    if not stat.S_ISREG(metadata.st_mode):
        raise ValueError(f"wrapper prelude entry is not a regular file: {path}")
    if metadata.st_uid != os.getuid():
        raise ValueError(f"wrong owner for wrapper prelude file: {path}")
    if metadata.st_nlink != 1:
        raise ValueError(f"hardlinked wrapper prelude file: {path}")
    mode = stat.S_IMODE(metadata.st_mode)
    if mode & 0o077:
        raise ValueError(f"unsafe mode for wrapper prelude file: {path} ({mode:o})")


def _validate_wrapper_outer(root: pathlib.Path, outer: pathlib.Path) -> pathlib.Path:
    candidate = _confined(root, outer, "wrapper evidence directory")
    expected_parent = root.joinpath(*WRAPPER_PARENT.parts)
    if candidate.parent != expected_parent or not candidate.name.startswith(WRAPPER_PREFIX):
        raise ValueError(f"unsupported wrapper evidence path: {candidate}")
    suffix = candidate.name.removeprefix(WRAPPER_PREFIX)
    if SAFE_SUFFIX.fullmatch(suffix) is None:
        raise ValueError(f"unsafe wrapper evidence leaf: {candidate.name}")
    _validate_descendant_chain(root, candidate.parent, "wrapper evidence ancestor")
    _validate_owned_directory(
        candidate,
        "wrapper evidence directory",
        exact_private_mode=True,
    )
    for entry in candidate.iterdir():
        if _has_control(entry.name) or entry.name not in ALLOWED_WRAPPER_PRELUDE:
            raise ValueError(f"unexpected wrapper evidence entry: {entry}")
        _validate_prelude_file(entry)
    return candidate


def create_wrapper_runner(
    app_root: pathlib.Path,
    outer: pathlib.Path,
) -> pathlib.Path:
    root = _app_root(app_root)
    validated_outer = _validate_wrapper_outer(root, outer)
    return _fresh_child(validated_outer, RUNNER_PREFIX)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("default", "wrapper-create"):
        child = subparsers.add_parser(command)
        child.add_argument("--app-root", required=True, type=pathlib.Path)
    child = subparsers.add_parser("wrapper-runner")
    child.add_argument("--app-root", required=True, type=pathlib.Path)
    child.add_argument("--outer", required=True, type=pathlib.Path)
    return parser


def main() -> int:
    arguments = _parser().parse_args()
    if arguments.command == "default":
        result = create_default_runner(arguments.app_root)
    elif arguments.command == "wrapper-create":
        result = create_wrapper_outer(arguments.app_root)
    else:
        result = create_wrapper_runner(arguments.app_root, arguments.outer)
    print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
