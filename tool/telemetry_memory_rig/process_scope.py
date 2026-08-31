#!/usr/bin/env python3
"""Authorize and contain macOS build processes by kernel session identity.

A launch authority is created only after a caller has established a new-session
leader behind its own launch barrier.  Containment signals processes solely
because their immutable kernel identity belongs to an authorized session; argv,
environment markers, paths, cwd, and open vnode file descriptors are evidence
for foreign-reference detection, never signaling authority.
"""

from __future__ import annotations

import argparse
import ctypes
from dataclasses import dataclass, replace
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import stat
import struct
import subprocess
import sys
import time
from types import ModuleType
from typing import Any


MARKER_NAME = "TELLTALE_GATE_C_PROCESS_SCOPE"
AUDIT_MARKER_NAME = "TELLTALE_GATE_C_PROCESS_SCOPE_AUDIT"
AUTHORITY_VERSION = 2
REFERENCE_AUTHORITY_VERSION = 1
REFERENCE_AUTHORITY_KIND = "source-guard-reference-exemption"
EVIDENCE_VERSION = 3
POLL_SECONDS = 0.05
PROC_PIDLISTFDS = 1
PROC_PIDTBSDINFO = 3
PROC_PIDFDVNODEPATHINFO = 2
PROC_PIDVNODEPATHINFO = 9
PROC_FDTYPE_VNODE = 1
PROC_ALL_PIDS = 1
MAXPATHLEN = 1024
LSOF_PATH = Path("/usr/sbin/lsof")
LSOF_RETRIES = 3
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
LAUNCH_ID_PATTERN = re.compile(r"[0-9a-f]{32}\Z")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}\Z")


def _capture_lsof_seal() -> dict[str, object]:
    canonical = LSOF_PATH.resolve(strict=True)
    status = os.lstat(LSOF_PATH)
    if (
        canonical != LSOF_PATH
        or not stat.S_ISREG(status.st_mode)
        or status.st_uid != 0
        or status.st_nlink != 1
        or stat.S_IMODE(status.st_mode) != 0o755
    ):
        raise RuntimeError("/usr/sbin/lsof filesystem identity is unsafe")
    environment = {"LC_ALL": "C", "PATH": "/usr/bin:/bin"}
    verify = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(LSOF_PATH)],
        check=False,
        capture_output=True,
        text=True,
        env=environment,
        timeout=5,
    )
    details = subprocess.run(
        ["/usr/bin/codesign", "-dv", "--verbose=4", str(LSOF_PATH)],
        check=False,
        capture_output=True,
        text=True,
        env=environment,
        timeout=5,
    )
    requirement = subprocess.run(
        ["/usr/bin/codesign", "-d", "-r-", str(LSOF_PATH)],
        check=False,
        capture_output=True,
        text=True,
        env=environment,
        timeout=5,
    )
    combined = details.stdout + details.stderr
    requirement_text = requirement.stdout + requirement.stderr
    identifier_match = re.search(r"(?m)^Identifier=(.+)$", combined)
    cdhash_match = re.search(r"(?m)^CDHash=([0-9a-f]{40})$", combined)
    authorities = re.findall(r"(?m)^Authority=(.+)$", combined)
    designated_match = re.search(r"(?m)^designated => (.+)$", requirement_text)
    if (
        verify.returncode != 0
        or details.returncode != 0
        or requirement.returncode != 0
        or identifier_match is None
        or identifier_match.group(1) != "com.apple.lsof"
        or cdhash_match is None
        or authorities
        != [
            "macOS Software Signing",
            "Apple Code Signing Certification Authority",
            "Apple Root CA",
        ]
        or designated_match is None
        or designated_match.group(1) != 'identifier "com.apple.lsof" and anchor apple'
    ):
        raise RuntimeError("/usr/sbin/lsof Apple code-signing identity is invalid")
    return {
        "path": str(LSOF_PATH),
        "sha256": hashlib.sha256(LSOF_PATH.read_bytes()).hexdigest(),
        "device": status.st_dev,
        "inode": status.st_ino,
        "size": status.st_size,
        "mtimeNs": status.st_mtime_ns,
        "mode": stat.S_IMODE(status.st_mode),
        "uid": status.st_uid,
        "gid": status.st_gid,
        "nlink": status.st_nlink,
        "codesignVerified": True,
        "identifier": identifier_match.group(1),
        "cdhash": cdhash_match.group(1),
        "authorities": authorities,
        "designatedRequirement": designated_match.group(1),
    }


LSOF_SEAL = _capture_lsof_seal()
LSOF_SHA256 = str(LSOF_SEAL["sha256"])


def _load_process_identity() -> ModuleType:
    path = Path(__file__).resolve().parent.parent / "ble_test_rig/process_identity.py"
    specification = importlib.util.spec_from_file_location(
        "telltale_darwin_process_identity",
        path,
    )
    if specification is None or specification.loader is None:
        raise RuntimeError(f"could not load process identity helper: {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


PROCESS_IDENTITY = _load_process_identity()


class _ProcBsdInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_int32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


@dataclass(frozen=True)
class ProcessIdentity:
    pid: int
    ppid: int
    pgid: int
    sid: int
    uid: int
    start_sec: int
    start_usec: int

    def as_dict(self) -> dict[str, int]:
        return {
            "pid": self.pid,
            "ppid": self.ppid,
            "pgid": self.pgid,
            "sid": self.sid,
            "uid": self.uid,
            "startSec": self.start_sec,
            "startUsec": self.start_usec,
        }


@dataclass(frozen=True)
class ProcessRecord:
    identity: ProcessIdentity
    executable: str
    argv: tuple[str, ...]
    environment: dict[str, str]
    state: int
    cwd: str | None = None
    root: str | None = None
    open_vnode_paths: tuple[str, ...] = ()
    inspection_errors: tuple[str, ...] = ()
    vnode_evidence_method: str | None = None
    vnode_evidence_complete: bool = False

    @property
    def pid(self) -> int:
        return self.identity.pid

    @property
    def ppid(self) -> int:
        return self.identity.ppid

    def as_dict(self) -> dict[str, object]:
        return {
            "identity": self.identity.as_dict(),
            "state": self.state,
            "executable": self.executable,
            "argv": list(self.argv),
            "environmentSha256": hashlib.sha256(
                json.dumps(
                    self.environment,
                    sort_keys=True,
                    separators=(",", ":"),
                ).encode("utf-8")
            ).hexdigest(),
            "cwd": self.cwd,
            "root": self.root,
            "openVnodePaths": list(self.open_vnode_paths),
            "inspectionErrors": list(self.inspection_errors),
            "vnodeEvidenceMethod": self.vnode_evidence_method,
            "vnodeEvidenceComplete": self.vnode_evidence_complete,
        }


def _libc() -> Any:
    return ctypes.CDLL(None, use_errno=True)


def _raise_errno(operation: str, pid: int) -> None:
    error = ctypes.get_errno() or errno.EIO
    raise ProcessLookupError(error, f"{operation} pid={pid}: {os.strerror(error)}")


def _bsd_identity(pid: int) -> tuple[ProcessIdentity, int]:
    if pid <= 1:
        raise ValueError("pid must be greater than one")
    info = _ProcBsdInfo()
    length = _libc().proc_pidinfo(
        pid,
        PROC_PIDTBSDINFO,
        0,
        ctypes.byref(info),
        ctypes.sizeof(info),
    )
    if length != ctypes.sizeof(info):
        _raise_errno("PROC_PIDTBSDINFO", pid)
    try:
        sid = os.getsid(pid)
    except OSError as error:
        raise ProcessLookupError(error.errno, str(error)) from error
    identity = ProcessIdentity(
        pid=int(info.pbi_pid),
        ppid=int(info.pbi_ppid),
        pgid=int(info.pbi_pgid),
        sid=sid,
        uid=int(info.pbi_uid),
        start_sec=int(info.pbi_start_tvsec),
        start_usec=int(info.pbi_start_tvusec),
    )
    if identity.pid != pid or min(identity.start_sec, identity.start_usec) < 0:
        raise RuntimeError(f"invalid PROC_PIDTBSDINFO identity for pid={pid}")
    return identity, int(info.pbi_status)


def _zombie_identity(pid: int, expected_sid: int) -> tuple[ProcessIdentity, int]:
    """Read an unreaped Darwin child without relying on getsid(2)."""

    if pid <= 1 or expected_sid <= 1:
        raise ValueError("unsafe zombie PID or SID")
    info = _ProcBsdInfo()
    length = _libc().proc_pidinfo(
        pid,
        PROC_PIDTBSDINFO,
        0,
        ctypes.byref(info),
        ctypes.sizeof(info),
    )
    if length != ctypes.sizeof(info):
        _raise_errno("PROC_PIDTBSDINFO zombie", pid)
    identity = ProcessIdentity(
        pid=int(info.pbi_pid),
        ppid=int(info.pbi_ppid),
        pgid=int(info.pbi_pgid),
        sid=expected_sid,
        uid=int(info.pbi_uid),
        start_sec=int(info.pbi_start_tvsec),
        start_usec=int(info.pbi_start_tvusec),
    )
    if identity.pid != pid or min(identity.start_sec, identity.start_usec) < 0:
        raise RuntimeError(f"invalid zombie identity for pid={pid}")
    return identity, int(info.pbi_status)


def _kernel_snapshot(pid: int) -> tuple[str, tuple[str, ...], dict[str, str]]:
    libc = _libc()
    mib = (ctypes.c_int * 3)(
        PROCESS_IDENTITY.CTL_KERN,
        PROCESS_IDENTITY.KERN_PROCARGS2,
        pid,
    )
    size = ctypes.c_size_t()
    if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0:
        _raise_errno("KERN_PROCARGS2 size", pid)
    buffer = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0) != 0:
        _raise_errno("KERN_PROCARGS2 read", pid)
    argv, environment = PROCESS_IDENTITY._split_procargs(buffer.raw[: size.value])
    path_buffer = ctypes.create_string_buffer(PROCESS_IDENTITY.PROC_PIDPATHINFO_MAXSIZE)
    length = libc.proc_pidpath(pid, path_buffer, len(path_buffer))
    if length <= 0:
        _raise_errno("proc_pidpath", pid)
    return os.path.realpath(os.fsdecode(path_buffer.value)), argv, environment


def _absolute_strings(data: bytes) -> tuple[str, ...]:
    values: list[str] = []
    for match in re.finditer(rb"/[^\0]{0,1023}\0", data):
        raw = match.group(0)[:-1]
        try:
            value = raw.decode("utf-8", errors="surrogateescape")
        except UnicodeError:
            continue
        if value not in values:
            values.append(value)
    return tuple(values)


def _kernel_fd_inventory(pid: int) -> tuple[tuple[int, int], ...]:
    libc = _libc()
    needed = libc.proc_pidinfo(pid, PROC_PIDLISTFDS, 0, None, 0)
    if needed <= 0:
        _raise_errno("PROC_PIDLISTFDS size", pid)
    fd_buffer = ctypes.create_string_buffer(needed)
    fd_length = libc.proc_pidinfo(
        pid,
        PROC_PIDLISTFDS,
        0,
        fd_buffer,
        len(fd_buffer),
    )
    if fd_length <= 0 or fd_length % 8 != 0:
        _raise_errno("PROC_PIDLISTFDS read", pid)
    return tuple(
        struct.unpack_from("iI", fd_buffer.raw, offset)
        for offset in range(0, fd_length, 8)
    )


def _kernel_vnode_paths(
    pid: int,
    fd_inventory: tuple[tuple[int, int], ...] | None = None,
) -> tuple[str | None, str | None, tuple[str, ...]]:
    libc = _libc()
    vnode_buffer = ctypes.create_string_buffer(8192)
    vnode_length = libc.proc_pidinfo(
        pid,
        PROC_PIDVNODEPATHINFO,
        0,
        vnode_buffer,
        len(vnode_buffer),
    )
    if vnode_length <= 0:
        _raise_errno("PROC_PIDVNODEPATHINFO", pid)
    vnode_paths = _absolute_strings(vnode_buffer.raw[:vnode_length])
    cwd = vnode_paths[0] if vnode_paths else None
    root = vnode_paths[1] if len(vnode_paths) > 1 else None

    inventory = _kernel_fd_inventory(pid) if fd_inventory is None else fd_inventory
    open_paths: list[str] = []
    for fd, fd_type in inventory:
        if fd_type != PROC_FDTYPE_VNODE:
            continue
        path_buffer = ctypes.create_string_buffer(4096)
        path_length = libc.proc_pidfdinfo(
            pid,
            fd,
            PROC_PIDFDVNODEPATHINFO,
            path_buffer,
            len(path_buffer),
        )
        if path_length <= 0:
            current = ctypes.get_errno()
            if current in (errno.ENOENT, errno.EBADF):
                continue
            _raise_errno("PROC_PIDFDVNODEPATHINFO", pid)
        for value in _absolute_strings(path_buffer.raw[:path_length]):
            if value not in open_paths:
                open_paths.append(value)
    return cwd, root, tuple(open_paths)


def _assert_lsof_identity() -> None:
    canonical = LSOF_PATH.resolve(strict=True)
    status = os.lstat(LSOF_PATH)
    if (
        canonical != LSOF_PATH
        or not stat.S_ISREG(status.st_mode)
        or status.st_dev != LSOF_SEAL["device"]
        or status.st_ino != LSOF_SEAL["inode"]
        or status.st_size != LSOF_SEAL["size"]
        or status.st_mtime_ns != LSOF_SEAL["mtimeNs"]
        or stat.S_IMODE(status.st_mode) != LSOF_SEAL["mode"]
        or status.st_uid != LSOF_SEAL["uid"]
        or status.st_gid != LSOF_SEAL["gid"]
        or status.st_nlink != LSOF_SEAL["nlink"]
        or hashlib.sha256(LSOF_PATH.read_bytes()).hexdigest() != LSOF_SHA256
    ):
        raise RuntimeError("sealed /usr/sbin/lsof identity changed")


def _parse_lsof_output(
    raw: bytes,
    expected_pid: int,
    expected_fds: dict[int, int],
) -> tuple[str | None, str | None, tuple[str, ...]]:
    observed_pids: set[int] = set()
    observed_fds: set[int] = set()
    absolute_named_fds: set[int] = set()
    paths: list[str] = []
    cwd: str | None = None
    root: str | None = None
    current_fd: str | None = None
    for raw_field in raw.split(b"\0"):
        field = raw_field.lstrip(b"\n")
        if not field:
            continue
        tag = chr(field[0])
        value = field[1:].decode("utf-8", errors="surrogateescape")
        if tag == "p":
            if not value.isdigit():
                raise RuntimeError("lsof returned an invalid PID field")
            observed_pids.add(int(value))
        elif tag == "f":
            current_fd = value
            match = re.match(r"([0-9]+)", value)
            if match is not None:
                observed_fds.add(int(match.group(1)))
        elif tag == "n" and value.startswith("/"):
            if current_fd == "cwd":
                cwd = value
            elif current_fd == "rtd":
                root = value
            if value not in paths:
                paths.append(value)
            if current_fd is not None:
                match = re.fullmatch(r"([0-9]+)[A-Za-z]*", current_fd)
                if match is not None:
                    absolute_named_fds.add(int(match.group(1)))
    if observed_pids != {expected_pid}:
        raise RuntimeError("lsof PID binding is incomplete")
    if observed_fds != set(expected_fds):
        raise BlockingIOError(
            errno.EAGAIN,
            "lsof numeric file descriptors differ from the kernel inventory",
        )
    expected_vnodes = {
        fd for fd, fd_type in expected_fds.items() if fd_type == PROC_FDTYPE_VNODE
    }
    if not expected_vnodes.issubset(absolute_named_fds):
        raise RuntimeError("lsof omitted an absolute vnode file-descriptor path")
    return cwd, root, tuple(paths)


def _lsof_vnode_paths(
    pid: int, expected: ProcessIdentity
) -> tuple[str | None, str | None, tuple[str, ...]]:
    last_error: BaseException | None = None
    for _attempt in range(LSOF_RETRIES):
        try:
            before, before_state = _bsd_identity(pid)
            if before_state == 5 or not _identity_equal(before, expected):
                raise ProcessLookupError(errno.ESRCH, "process identity changed")
            before_fds = _kernel_fd_inventory(pid)
            _assert_lsof_identity()
            completed = subprocess.run(
                [
                    str(LSOF_PATH),
                    "-nP",
                    "-a",
                    "-p",
                    str(pid),
                    "-F0pcfnt",
                ],
                check=False,
                capture_output=True,
                env={"LC_ALL": "C", "PATH": "/usr/bin:/bin"},
                timeout=5,
            )
            if completed.returncode != 0:
                raise RuntimeError(
                    f"sealed lsof failed pid={pid} exit={completed.returncode}"
                )
            if completed.stderr:
                raise RuntimeError(f"sealed lsof wrote stderr pid={pid}")
            value = _parse_lsof_output(
                completed.stdout,
                pid,
                dict(before_fds),
            )
            _assert_lsof_identity()
            after, after_state = _bsd_identity(pid)
            after_fds = _kernel_fd_inventory(pid)
            if after_state == 5 or not _identity_equal(before, after):
                raise ProcessLookupError(errno.ESRCH, "process identity changed")
            if before_fds != after_fds:
                raise BlockingIOError(errno.EAGAIN, "file descriptor inventory changed")
            return value
        except BlockingIOError as error:
            last_error = error
            time.sleep(POLL_SECONDS)
    raise RuntimeError(f"lsof fallback did not reach a stable snapshot: {last_error}")


def _vnode_paths_complete(
    pid: int, expected: ProcessIdentity
) -> tuple[str | None, str | None, tuple[str, ...], str]:
    inventory = _kernel_fd_inventory(pid)
    try:
        cwd, root, paths = _kernel_vnode_paths(pid, inventory)
        return cwd, root, paths, "libproc"
    except ProcessLookupError as error:
        if error.errno not in (errno.EPERM, errno.EACCES):
            raise
    cwd, root, paths = _lsof_vnode_paths(pid, expected)
    return cwd, root, paths, "sealed-lsof"


def _process_rows() -> dict[int, tuple[int, str]]:
    completed = subprocess.run(
        ["/bin/ps", "-axo", "pid=,uid=,state="],
        check=True,
        capture_output=True,
        text=True,
        env={"LC_ALL": "C", "PATH": "/usr/bin:/bin"},
    )
    rows: dict[int, tuple[int, str]] = {}
    for line in completed.stdout.splitlines():
        fields = line.split(maxsplit=2)
        if len(fields) != 3 or not fields[0].isdigit() or not fields[1].isdigit():
            raise RuntimeError("could not parse process inventory")
        pid, uid = map(int, fields[:2])
        if pid in rows:
            raise RuntimeError("process inventory contains a duplicate PID")
        rows[pid] = (uid, fields[2])
    return rows


def _identity_equal(left: ProcessIdentity, right: ProcessIdentity) -> bool:
    return (
        left.pid,
        left.uid,
        left.sid,
        left.start_sec,
        left.start_usec,
    ) == (
        right.pid,
        right.uid,
        right.sid,
        right.start_sec,
        right.start_usec,
    )


def _confirmed_gone_or_changed(pid: int, expected: ProcessIdentity) -> bool:
    try:
        actual, state = _bsd_identity(pid)
    except ProcessLookupError as error:
        if error.errno in (errno.ESRCH, errno.ENOENT):
            return True
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        except PermissionError:
            pass
        raise RuntimeError(
            f"could not revalidate live process identity pid={pid}"
        ) from error
    return state == 5 or not _identity_equal(expected, actual)


def _record_for_pid(
    pid: int,
    expected: ProcessIdentity | None = None,
) -> ProcessRecord | None:
    try:
        identity, state = _bsd_identity(pid)
    except ProcessLookupError as error:
        if expected is not None and _confirmed_gone_or_changed(pid, expected):
            return None
        rows = _process_rows()
        row = rows.get(pid)
        if row is None or row[1].startswith("Z"):
            return None
        raise RuntimeError(
            f"could not inspect live process identity pid={pid}"
        ) from error
    if expected is not None and not _identity_equal(expected, identity):
        return None
    if state == 5:
        return None
    try:
        executable, argv, environment = _kernel_snapshot(pid)
        cwd, root, open_paths, vnode_method = _vnode_paths_complete(pid, identity)
    except (OSError, RuntimeError) as error:
        if _confirmed_gone_or_changed(pid, identity):
            return None
        raise RuntimeError(f"could not inspect live process pid={pid}") from error
    return ProcessRecord(
        identity=identity,
        executable=executable,
        argv=argv,
        environment=environment,
        state=state,
        cwd=cwd,
        root=root,
        open_vnode_paths=open_paths,
        vnode_evidence_method=vnode_method,
        vnode_evidence_complete=True,
    )


def _all_records() -> dict[int, ProcessRecord]:
    records = _identity_inventory()
    for pid, basic in tuple(records.items()):
        errors: list[str] = []
        try:
            executable, argv, environment = _kernel_snapshot(pid)
        except (OSError, RuntimeError) as error:
            if _confirmed_gone_or_changed(pid, basic.identity):
                records.pop(pid, None)
                continue
            errors.append(f"processEvidence:{type(error).__name__}:{error}")
            records[pid] = replace(basic, inspection_errors=tuple(errors))
            continue
        try:
            cwd, root, open_paths, vnode_method = _vnode_paths_complete(
                pid, basic.identity
            )
        except (OSError, RuntimeError) as error:
            if _confirmed_gone_or_changed(pid, basic.identity):
                records.pop(pid, None)
                continue
            cwd, root, open_paths = None, None, ()
            vnode_method = None
            errors.append(f"vnodeEvidence:{type(error).__name__}:{error}")
        records[pid] = replace(
            basic,
            executable=executable,
            argv=argv,
            environment=environment,
            cwd=cwd,
            root=root,
            open_vnode_paths=open_paths,
            inspection_errors=tuple(errors),
            vnode_evidence_method=vnode_method,
            vnode_evidence_complete=not errors,
        )
    return records


def _identity_inventory() -> dict[int, ProcessRecord]:
    records: dict[int, ProcessRecord] = {}
    for pid, (uid, state_text) in _process_rows().items():
        if pid <= 1 or uid != os.getuid() or state_text.startswith("Z"):
            continue
        try:
            process_identity, state = _bsd_identity(pid)
        except ProcessLookupError as error:
            if error.errno in (errno.ESRCH, errno.ENOENT):
                continue
            raise RuntimeError(f"could not inventory live process pid={pid}") from error
        if state == 5:
            continue
        records[pid] = ProcessRecord(
            identity=process_identity,
            executable="",
            argv=(),
            environment={},
            state=state,
        )
    return records


def _canonical_owned_directory(path: Path, label: str) -> Path:
    if not path.is_absolute():
        raise ValueError(f"{label} is not absolute")
    canonical = path.resolve(strict=True)
    if canonical != path:
        raise ValueError(f"{label} is not canonical")
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        status = os.lstat(current)
        if stat.S_ISLNK(status.st_mode):
            raise ValueError(f"{label} contains a symlink: {current}")
    status = os.lstat(path)
    if (
        not stat.S_ISDIR(status.st_mode)
        or status.st_uid != os.getuid()
        or status.st_mode & 0o022
    ):
        raise ValueError(f"{label} is not a private owned directory")
    return canonical


def _canonical_regular_file(path: Path, label: str) -> Path:
    if not path.is_absolute():
        raise ValueError(f"{label} is not absolute")
    canonical = path.resolve(strict=True)
    if canonical != path:
        raise ValueError(f"{label} is not canonical")
    status = os.lstat(path)
    if (
        not stat.S_ISREG(status.st_mode)
        or status.st_nlink != 1
        or status.st_mode & 0o022
    ):
        raise ValueError(f"{label} filesystem identity is unsafe")
    return canonical


def _canonical_private_file(path: Path, label: str) -> Path:
    canonical = _canonical_regular_file(path, label)
    status = os.lstat(canonical)
    if status.st_uid != os.getuid() or stat.S_IMODE(status.st_mode) != 0o600:
        raise ValueError(f"{label} ownership or mode is unsafe")
    return canonical


def _canonical_absent_path(path: Path, label: str) -> Path:
    if not path.is_absolute():
        raise ValueError(f"{label} is not absolute")
    parent = path.parent.resolve(strict=True)
    if parent != path.parent:
        raise ValueError(f"{label} parent is not canonical")
    _canonical_owned_directory(parent, f"{label} parent")
    canonical = parent / path.name
    if canonical.exists() or canonical.is_symlink():
        raise ValueError(f"{label} already exists")
    return canonical


def _is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
    except ValueError:
        return False
    return True


def _validate_roots(roots: dict[str, Path]) -> dict[str, Path]:
    if set(roots) != ROOT_KEYS:
        raise ValueError("authority roots have unexpected keys")
    canonical = {
        key: _canonical_owned_directory(Path(value), key)
        for key, value in roots.items()
    }
    if not _is_within(canonical["home"], canonical["isolatedUserRoot"]):
        raise ValueError("home is outside isolatedUserRoot")
    if not _is_within(canonical["sandboxRunTemp"], canonical["isolatedUserRoot"]):
        raise ValueError("sandboxRunTemp is outside isolatedUserRoot")
    for key in ("kotlinProjectPersistentDir", "kotlinDaemonRunFilesDir"):
        if canonical[key].parent != canonical["sandboxRunTemp"]:
            raise ValueError(f"{key} is not a direct sandboxRunTemp child")
    if canonical["kotlinProjectPersistentDir"] == canonical["kotlinDaemonRunFilesDir"]:
        raise ValueError("Kotlin runtime roots overlap")
    return canonical


def _identity_from_dict(value: object, label: str) -> ProcessIdentity:
    if not isinstance(value, dict) or set(value) != {
        "pid",
        "ppid",
        "pgid",
        "sid",
        "uid",
        "startSec",
        "startUsec",
    }:
        raise ValueError(f"invalid {label} identity schema")
    if any(type(value[key]) is not int for key in value):
        raise ValueError(f"invalid {label} identity values")
    identity = ProcessIdentity(
        pid=value["pid"],
        ppid=value["ppid"],
        pgid=value["pgid"],
        sid=value["sid"],
        uid=value["uid"],
        start_sec=value["startSec"],
        start_usec=value["startUsec"],
    )
    if (
        min(identity.pid, identity.pgid, identity.sid, identity.start_sec) <= 0
        or identity.ppid < 0
        or identity.uid < 0
        or not 0 <= identity.start_usec <= 999_999
    ):
        raise ValueError(f"invalid {label} identity")
    return identity


def _ancestor_chain(records: dict[int, ProcessRecord], pid: int) -> set[int]:
    chain: set[int] = set()
    while pid > 1 and pid not in chain:
        chain.add(pid)
        record = records.get(pid)
        if record is None:
            break
        pid = record.ppid
    return chain


def _is_descendant(records: dict[int, ProcessRecord], pid: int, ancestor: int) -> bool:
    return ancestor in _ancestor_chain(records, pid) and pid != ancestor


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _write_exclusive_json(path: Path, value: dict[str, object]) -> None:
    parent = path.parent.resolve(strict=True)
    parent_status = os.lstat(parent)
    if (
        path.parent != parent
        or not stat.S_ISDIR(parent_status.st_mode)
        or parent_status.st_uid != os.getuid()
        or stat.S_IMODE(parent_status.st_mode) != 0o700
    ):
        raise ValueError("output parent is unsafe")
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        if stat.S_IMODE(os.fstat(descriptor).st_mode) != 0o600:
            raise ValueError("output mode is unsafe")
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            descriptor = -1
            json.dump(value, output, sort_keys=True, separators=(",", ":"))
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def create_launch_authority(
    *,
    child_pid: int,
    owner_root_pid: int,
    launch_id: str,
    wrapper_path: Path,
    wrapper_sha256: str,
    command_cwd: Path,
    roots: dict[str, Path],
    authority_path: Path,
) -> dict[str, object]:
    if LAUNCH_ID_PATTERN.fullmatch(launch_id) is None:
        raise ValueError("invalid launchId")
    wrapper = Path(wrapper_path)
    if wrapper != wrapper.resolve(strict=True) or not wrapper.is_file():
        raise ValueError("wrapper is not a canonical file")
    if (
        _sha256(wrapper) != wrapper_sha256
        or re.fullmatch(r"[0-9a-f]{64}", wrapper_sha256) is None
    ):
        raise ValueError("wrapper digest mismatch")
    cwd = _canonical_owned_directory(Path(command_cwd), "command cwd")
    canonical_roots = _validate_roots(roots)
    records = _identity_inventory()
    current = _record_for_pid(os.getpid())
    child = _record_for_pid(child_pid)
    owner = _record_for_pid(owner_root_pid)
    if current is None or child is None or owner is None:
        raise RuntimeError("launch authority identity disappeared")
    if child.ppid != os.getpid() or child.identity.uid != os.getuid():
        raise ValueError("leader is not a direct owned child of the supervisor")
    if not (child.pid == child.identity.pgid == child.identity.sid):
        raise ValueError("leader is not a fresh process-group and session leader")
    if owner_root_pid == os.getpid() or owner_root_pid not in _ancestor_chain(
        records, os.getpid()
    ):
        raise ValueError("owner root is not an exact live supervisor ancestor")
    expected_zsh = os.path.realpath("/bin/zsh")
    if (
        child.executable != expected_zsh
        or len(child.argv) < 3
        or os.path.realpath(child.argv[0]) != expected_zsh
        or child.argv[1] != "-f"
        or Path(child.argv[2]) != wrapper
    ):
        raise ValueError("leader argv/executable do not prove the exact zsh wrapper")
    value: dict[str, object] = {
        "version": AUTHORITY_VERSION,
        "launchId": launch_id,
        "ownerRoot": owner.identity.as_dict(),
        "supervisor": current.identity.as_dict(),
        "leader": child.identity.as_dict(),
        "wrapper": {"path": str(wrapper), "sha256": wrapper_sha256},
        "roots": {key: str(canonical_roots[key]) for key in sorted(ROOT_KEYS)},
        "cwd": str(cwd),
    }
    _write_exclusive_json(authority_path, value)
    return value


def _file_seal(path: Path, label: str) -> dict[str, str]:
    canonical = _canonical_regular_file(Path(path), label)
    return {"path": str(canonical), "sha256": _sha256(canonical)}


def _readiness_seal(
    *,
    path: Path,
    subject_pid: int,
    nonce: str,
    stop_path: Path,
    result_path: Path,
) -> dict[str, str]:
    if LAUNCH_ID_PATTERN.fullmatch(nonce) is None:
        raise ValueError("reference readiness nonce is invalid")
    canonical = _canonical_private_file(Path(path), "reference readiness")
    raw = canonical.read_bytes()
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError("reference readiness JSON is invalid") from error
    if (
        not isinstance(value, dict)
        or value.get("pid") != subject_pid
        or value.get("nonce") != nonce
    ):
        raise ValueError("reference readiness identity is invalid")
    stop = _canonical_absent_path(Path(stop_path), "reference stop path")
    result = _canonical_absent_path(Path(result_path), "reference result path")
    return {
        "path": str(canonical),
        "sha256": hashlib.sha256(raw).hexdigest(),
        "nonce": nonce,
        "stopPath": str(stop),
        "resultPath": str(result),
    }


def _reason_root_keys(reasons: list[str]) -> list[str]:
    keys = {
        reason.rsplit(":", maxsplit=1)[-1]
        for reason in reasons
        if reason != "marker" and reason.rsplit(":", maxsplit=1)[-1] in ROOT_KEYS
    }
    return sorted(keys)


def create_reference_authority(
    *,
    subject_pid: int,
    owner_root_pid: int,
    exemption_id: str,
    program_path: Path,
    program_sha256: str,
    readiness_path: Path,
    readiness_nonce: str,
    stop_path: Path,
    result_path: Path,
    roots: dict[str, Path],
    authority_path: Path,
) -> dict[str, object]:
    """Seal one already-ready source guard as reference-only authority.

    This authority can suppress foreign-reference classification for exactly
    one immutable guard identity.  It is deliberately separate from launch
    authority and is never consulted when selecting processes to signal.
    """

    if LAUNCH_ID_PATTERN.fullmatch(exemption_id) is None:
        raise ValueError("invalid exemptionId")
    if subject_pid <= 1 or owner_root_pid <= 1:
        raise ValueError("unsafe reference subject or owner PID")
    canonical_roots = _validate_roots(roots)
    program = _canonical_regular_file(Path(program_path), "reference program")
    if (
        SHA256_PATTERN.fullmatch(program_sha256) is None
        or _sha256(program) != program_sha256
    ):
        raise ValueError("reference program digest mismatch")

    records = _identity_inventory()
    current = _record_for_pid(os.getpid())
    subject = _record_for_pid(subject_pid)
    owner = _record_for_pid(owner_root_pid)
    if current is None or subject is None or owner is None:
        raise RuntimeError("reference authority identity disappeared")
    if owner_root_pid == os.getpid() or owner_root_pid not in _ancestor_chain(
        records, os.getpid()
    ):
        raise ValueError(
            "reference owner root is not an exact live authorizer ancestor"
        )
    if (
        subject.ppid != owner_root_pid
        or subject.identity.uid != os.getuid()
        or owner.identity.uid != os.getuid()
        or subject.identity.sid == subject_pid
    ):
        raise ValueError("reference subject is not an owned direct guard child")
    if (
        subject.executable != current.executable
        or not subject.argv
        or subject.argv[0] != subject.executable
        or len(subject.argv) < 5
        or tuple(subject.argv[1:4]) != ("-I", "-S", "-B")
        or Path(subject.argv[4]) != program
    ):
        raise ValueError("reference subject executable or program argv is invalid")
    executable = _file_seal(Path(subject.executable), "reference executable")
    readiness = _readiness_seal(
        path=readiness_path,
        subject_pid=subject_pid,
        nonce=readiness_nonce,
        stop_path=stop_path,
        result_path=result_path,
    )
    reasons = _reference_reasons(subject, canonical_roots, set())
    allowed_root_keys = _reason_root_keys(reasons)
    if not allowed_root_keys:
        raise ValueError("reference subject does not reference a protected root")
    value: dict[str, object] = {
        "version": REFERENCE_AUTHORITY_VERSION,
        "kind": REFERENCE_AUTHORITY_KIND,
        "exemptionId": exemption_id,
        "ownerRoot": owner.identity.as_dict(),
        "subject": subject.identity.as_dict(),
        "executable": executable,
        "program": {"path": str(program), "sha256": program_sha256},
        "argv": list(subject.argv),
        "readiness": readiness,
        "roots": {key: str(canonical_roots[key]) for key in sorted(ROOT_KEYS)},
        "allowedRootKeys": allowed_root_keys,
    }
    _write_exclusive_json(authority_path, value)
    return value


def _load_authority(path: Path) -> tuple[dict[str, object], str]:
    canonical = path.resolve(strict=True)
    if canonical != path or not path.is_file() or path.is_symlink():
        raise ValueError("authority path is unsafe")
    status = os.lstat(path)
    if status.st_uid != os.getuid() or stat.S_IMODE(status.st_mode) != 0o600:
        raise ValueError("authority ownership or mode is unsafe")
    raw = path.read_bytes()
    value = json.loads(raw)
    required = {
        "version",
        "launchId",
        "ownerRoot",
        "supervisor",
        "leader",
        "wrapper",
        "roots",
        "cwd",
    }
    if not isinstance(value, dict) or set(value) != required:
        raise ValueError("invalid authority schema")
    if value["version"] != AUTHORITY_VERSION or not isinstance(value["launchId"], str):
        raise ValueError("invalid authority version or launchId")
    if LAUNCH_ID_PATTERN.fullmatch(value["launchId"]) is None:
        raise ValueError("invalid authority launchId")
    owner = _identity_from_dict(value["ownerRoot"], "ownerRoot")
    supervisor = _identity_from_dict(value["supervisor"], "supervisor")
    leader = _identity_from_dict(value["leader"], "leader")
    if (
        owner.uid != os.getuid()
        or supervisor.uid != os.getuid()
        or leader.uid != os.getuid()
    ):
        raise ValueError("authority identities are not owned by the current uid")
    wrapper = value["wrapper"]
    if not isinstance(wrapper, dict) or set(wrapper) != {"path", "sha256"}:
        raise ValueError("invalid authority wrapper")
    wrapper_path = Path(wrapper["path"])
    if (
        wrapper_path != wrapper_path.resolve(strict=True)
        or _sha256(wrapper_path) != wrapper["sha256"]
    ):
        raise ValueError("authority wrapper changed")
    roots_value = value["roots"]
    if not isinstance(roots_value, dict) or any(
        not isinstance(item, str) for item in roots_value.values()
    ):
        raise ValueError("invalid authority roots")
    canonical_roots = _validate_roots(
        {key: Path(item) for key, item in roots_value.items()}
    )
    cwd = _canonical_owned_directory(Path(value["cwd"]), "authority cwd")
    normalized = dict(value)
    normalized["ownerRoot"] = owner.as_dict()
    normalized["supervisor"] = supervisor.as_dict()
    normalized["leader"] = leader.as_dict()
    normalized["roots"] = {key: str(canonical_roots[key]) for key in sorted(ROOT_KEYS)}
    normalized["cwd"] = str(cwd)
    return normalized, hashlib.sha256(raw).hexdigest()


def _load_reference_authority(path: Path) -> tuple[dict[str, object], str]:
    canonical = _canonical_private_file(Path(path), "reference authority")
    raw = canonical.read_bytes()
    value = json.loads(raw)
    required = {
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
    if not isinstance(value, dict) or set(value) != required:
        raise ValueError("invalid reference authority schema")
    if (
        value.get("version") != REFERENCE_AUTHORITY_VERSION
        or value.get("kind") != REFERENCE_AUTHORITY_KIND
        or not isinstance(value.get("exemptionId"), str)
        or LAUNCH_ID_PATTERN.fullmatch(value["exemptionId"]) is None
    ):
        raise ValueError("invalid reference authority identity")
    owner = _identity_from_dict(value["ownerRoot"], "reference ownerRoot")
    subject = _identity_from_dict(value["subject"], "reference subject")
    if (
        owner.uid != os.getuid()
        or subject.uid != os.getuid()
        or subject.ppid != owner.pid
    ):
        raise ValueError("reference authority process binding is invalid")
    executable = value["executable"]
    program = value["program"]
    for label, seal in (("executable", executable), ("program", program)):
        if (
            not isinstance(seal, dict)
            or set(seal) != {"path", "sha256"}
            or not isinstance(seal.get("path"), str)
            or not isinstance(seal.get("sha256"), str)
            or SHA256_PATTERN.fullmatch(seal["sha256"]) is None
        ):
            raise ValueError(f"invalid reference {label} seal")
        sealed_path = _canonical_regular_file(Path(seal["path"]), f"reference {label}")
        if _sha256(sealed_path) != seal["sha256"]:
            raise ValueError(f"reference {label} changed")
    argv = value["argv"]
    if (
        not isinstance(argv, list)
        or len(argv) < 5
        or any(not isinstance(item, str) or "\x00" in item for item in argv)
        or argv[0] != executable["path"]
        or argv[1:4] != ["-I", "-S", "-B"]
        or argv[4] != program["path"]
    ):
        raise ValueError("invalid reference authority argv")
    readiness = value["readiness"]
    if not isinstance(readiness, dict) or set(readiness) != {
        "path",
        "sha256",
        "nonce",
        "stopPath",
        "resultPath",
    }:
        raise ValueError("invalid reference readiness schema")
    ready_path = _canonical_private_file(Path(readiness["path"]), "reference readiness")
    if (
        not isinstance(readiness.get("sha256"), str)
        or SHA256_PATTERN.fullmatch(readiness["sha256"]) is None
        or hashlib.sha256(ready_path.read_bytes()).hexdigest() != readiness["sha256"]
        or not isinstance(readiness.get("nonce"), str)
        or LAUNCH_ID_PATTERN.fullmatch(readiness["nonce"]) is None
    ):
        raise ValueError("reference readiness changed")
    ready_value = json.loads(ready_path.read_bytes())
    if (
        not isinstance(ready_value, dict)
        or ready_value.get("pid") != subject.pid
        or ready_value.get("nonce") != readiness["nonce"]
    ):
        raise ValueError("reference readiness identity changed")
    stop_path = _canonical_absent_path(
        Path(readiness["stopPath"]), "reference stop path"
    )
    result_path = _canonical_absent_path(
        Path(readiness["resultPath"]), "reference result path"
    )
    roots_value = value["roots"]
    if not isinstance(roots_value, dict) or any(
        not isinstance(item, str) for item in roots_value.values()
    ):
        raise ValueError("invalid reference roots")
    roots = _validate_roots({key: Path(item) for key, item in roots_value.items()})
    allowed = value["allowedRootKeys"]
    if (
        not isinstance(allowed, list)
        or not allowed
        or any(not isinstance(item, str) for item in allowed)
        or allowed != sorted(set(allowed))
        or not set(allowed).issubset(ROOT_KEYS)
    ):
        raise ValueError("invalid reference allowedRootKeys")
    normalized = dict(value)
    normalized["ownerRoot"] = owner.as_dict()
    normalized["subject"] = subject.as_dict()
    normalized["readiness"] = {
        **readiness,
        "path": str(ready_path),
        "stopPath": str(stop_path),
        "resultPath": str(result_path),
    }
    normalized["roots"] = {key: str(roots[key]) for key in sorted(ROOT_KEYS)}
    return normalized, hashlib.sha256(raw).hexdigest()


def verify_reference_authority(
    path: Path,
    *,
    owner_root_pid: int,
) -> dict[str, object]:
    authority, _digest = _load_reference_authority(path)
    records = _all_records()
    owner = _identity_from_dict(authority["ownerRoot"], "reference ownerRoot")
    subject = _identity_from_dict(authority["subject"], "reference subject")
    actual_owner = records.get(owner.pid)
    record = records.get(subject.pid)
    if owner.pid != owner_root_pid:
        raise RuntimeError("reference authority owner PID mismatch")
    if actual_owner is None or not _identity_equal(actual_owner.identity, owner):
        raise RuntimeError("reference authority ownerRoot identity changed")
    if owner.pid == os.getpid() or owner.pid not in _ancestor_chain(
        records, os.getpid()
    ):
        raise RuntimeError("reference authority ownerRoot is not a verifier ancestor")
    if record is None:
        raise RuntimeError("reference subject disappeared")
    if not _identity_equal(record.identity, subject):
        raise RuntimeError("reference subject PID was reused or session changed")
    if record.ppid != owner.pid or not _is_descendant(records, record.pid, owner.pid):
        raise RuntimeError("reference subject is no longer the direct owner child")
    if (
        record.executable != authority["executable"]["path"]
        or list(record.argv) != authority["argv"]
        or Path(record.argv[4]) != Path(authority["program"]["path"])
    ):
        raise RuntimeError("reference subject executable or argv changed")
    readiness = authority["readiness"]
    if Path(readiness["stopPath"]).exists() or Path(readiness["stopPath"]).is_symlink():
        raise RuntimeError("reference subject stop control appeared")
    if (
        Path(readiness["resultPath"]).exists()
        or Path(readiness["resultPath"]).is_symlink()
    ):
        raise RuntimeError("reference subject terminal result appeared")
    roots = {key: Path(value) for key, value in authority["roots"].items()}
    reasons = _reference_reasons(record, roots, set())
    if not reasons or not set(_reason_root_keys(reasons)).issubset(
        authority["allowedRootKeys"]
    ):
        raise RuntimeError("reference subject protected-root reasons changed")
    return authority


def _assert_authority_files_unchanged(
    entries: list[dict[str, object]],
) -> None:
    for entry in entries:
        path = Path(entry["path"])
        _value, digest = _load_authority(path)
        if digest != entry["sha256"]:
            raise RuntimeError(f"authority changed during containment: {path}")


def _assert_reference_authority_files_unchanged(
    entries: list[dict[str, object]],
) -> None:
    for entry in entries:
        path = Path(entry["path"])
        _value, digest = _load_reference_authority(path)
        if digest != entry["sha256"]:
            raise RuntimeError(
                f"reference authority changed during containment: {path}"
            )


def _path_references(value: str, roots: dict[str, Path]) -> list[str]:
    reasons: list[str] = []
    for key, root in roots.items():
        root_text = str(root)
        if (
            value == root_text
            or value.startswith(root_text + os.sep)
            or root_text in value
        ):
            reasons.append(key)
    return reasons


def _reference_reasons(
    record: ProcessRecord, roots: dict[str, Path], scopes: set[str]
) -> list[str]:
    reasons: set[str] = set()
    marker = record.environment.get(MARKER_NAME)
    if marker in scopes:
        reasons.add("marker")
    for argument in record.argv:
        reasons.update(f"argv:{key}" for key in _path_references(argument, roots))
    for name, value in record.environment.items():
        reasons.update(f"env:{name}:{key}" for key in _path_references(value, roots))
    for label, value in (("cwd", record.cwd), ("root", record.root)):
        if value is not None:
            reasons.update(f"{label}:{key}" for key in _path_references(value, roots))
    for value in record.open_vnode_paths:
        reasons.update(f"openFd:{key}" for key in _path_references(value, roots))
    return sorted(reasons)


def _reference_identity_key(
    identity: ProcessIdentity,
) -> tuple[int, int, int, int, int]:
    return (
        identity.pid,
        identity.uid,
        identity.sid,
        identity.start_sec,
        identity.start_usec,
    )


def _validate_live_reference_context(
    authorities: list[dict[str, object]],
    reference_authorities: list[dict[str, object]],
    records: dict[int, ProcessRecord],
    signal_sids: set[int] | None = None,
) -> dict[int, tuple[dict[str, object], ProcessRecord, list[str]]]:
    if not reference_authorities:
        return {}
    if signal_sids is None:
        signal_sids = {
            _identity_from_dict(authority["leader"], "leader").sid
            for authority in authorities
        }
    expected_owner = _identity_from_dict(authorities[0]["ownerRoot"], "ownerRoot")
    expected_roots = authorities[0]["roots"]
    matches: dict[int, tuple[dict[str, object], ProcessRecord, list[str]]] = {}
    identity_keys: set[tuple[int, int, int, int, int]] = set()
    for authority in reference_authorities:
        owner = _identity_from_dict(authority["ownerRoot"], "reference ownerRoot")
        subject = _identity_from_dict(authority["subject"], "reference subject")
        if (
            not _identity_equal(owner, expected_owner)
            or authority["roots"] != expected_roots
        ):
            raise RuntimeError("reference authority ownerRoot or roots mismatch")
        key = _reference_identity_key(subject)
        if key in identity_keys or subject.pid in matches:
            raise RuntimeError("duplicate reference authority subject")
        identity_keys.add(key)
        if subject.sid in signal_sids:
            raise RuntimeError(
                "reference subject overlaps an authorized signal session"
            )
        record = records.get(subject.pid)
        if record is None:
            raise RuntimeError("reference subject disappeared")
        if not _identity_equal(record.identity, subject):
            raise RuntimeError("reference subject PID was reused or session changed")
        if record.ppid != owner.pid or not _is_descendant(
            records, record.pid, owner.pid
        ):
            raise RuntimeError("reference subject is no longer the direct owner child")
        if (
            record.executable != authority["executable"]["path"]
            or list(record.argv) != authority["argv"]
            or Path(record.argv[4]) != Path(authority["program"]["path"])
        ):
            raise RuntimeError("reference subject executable or argv changed")
        readiness = authority["readiness"]
        if (
            Path(readiness["stopPath"]).exists()
            or Path(readiness["stopPath"]).is_symlink()
        ):
            raise RuntimeError("reference subject stop control appeared")
        if (
            Path(readiness["resultPath"]).exists()
            or Path(readiness["resultPath"]).is_symlink()
        ):
            raise RuntimeError("reference subject terminal result appeared")
        roots = {key: Path(value) for key, value in authority["roots"].items()}
        reasons = _reference_reasons(record, roots, set())
        observed_keys = _reason_root_keys(reasons)
        if not reasons or not set(observed_keys).issubset(authority["allowedRootKeys"]):
            raise RuntimeError("reference subject protected-root reasons changed")
        matches[subject.pid] = (authority, record, reasons)
    return matches


def _validate_live_authority_context(authorities: list[dict[str, object]]) -> None:
    records = _identity_inventory()
    current = records.get(os.getpid())
    if current is None:
        raise RuntimeError("containment helper identity disappeared")
    for authority in authorities:
        owner = _identity_from_dict(authority["ownerRoot"], "ownerRoot")
        supervisor = _identity_from_dict(authority["supervisor"], "supervisor")
        actual_owner = records.get(owner.pid)
        actual_supervisor = records.get(supervisor.pid)
        if actual_owner is None or not _identity_equal(actual_owner.identity, owner):
            raise RuntimeError("authority ownerRoot identity changed")
        if actual_supervisor is not None and not _identity_equal(
            actual_supervisor.identity, supervisor
        ):
            raise RuntimeError("authority supervisor PID was reused")
        if owner.pid == os.getpid() or owner.pid not in _ancestor_chain(
            records, os.getpid()
        ):
            raise RuntimeError("authority ownerRoot is not a helper ancestor")


def _has_unreaped_exit_anchor(
    authority: dict[str, object],
    records: dict[int, ProcessRecord],
) -> bool:
    """Prove that this exact supervisor still owns the exited leader zombie."""

    supervisor = _identity_from_dict(authority["supervisor"], "supervisor")
    leader = _identity_from_dict(authority["leader"], "leader")
    current = records.get(os.getpid())
    if (
        supervisor.pid != os.getpid()
        or current is None
        or not _identity_equal(current.identity, supervisor)
        or leader.ppid != supervisor.pid
        or not (leader.pid == leader.pgid == leader.sid)
    ):
        return False
    try:
        before_identity, before_state = _zombie_identity(leader.pid, leader.sid)
    except ProcessLookupError as error:
        if error.errno not in (errno.ESRCH, errno.ENOENT):
            return False
        before_identity = None
        before_state = 5
    except (OSError, ValueError):
        return False
    if before_identity is not None and (before_state != 5 or before_identity != leader):
        return False
    try:
        observed = os.waitid(
            os.P_PID,
            leader.pid,
            os.WEXITED | os.WNOHANG | os.WNOWAIT,
        )
    except ChildProcessError:
        return False
    if observed is None:
        return False
    if observed.si_pid != leader.pid or observed.si_code not in {
        os.CLD_EXITED,
        os.CLD_KILLED,
        os.CLD_DUMPED,
    }:
        return False
    if getattr(observed, "si_uid", 0) not in (0, leader.uid):
        return False
    try:
        after_identity, after_state = _zombie_identity(leader.pid, leader.sid)
    except ProcessLookupError as error:
        if error.errno not in (errno.ESRCH, errno.ENOENT):
            return False
        after_identity = None
        after_state = 5
    except (OSError, ValueError):
        return False
    if (before_identity is None) != (after_identity is None):
        return False
    if before_identity is None:
        # Darwin may make PROC_PIDTBSDINFO unavailable for a zombie.  The
        # successful WNOWAIT on this exact current supervisor's child still
        # proves that its PID remains unreaped and therefore cannot be reused.
        return True
    return (
        after_state == 5
        and after_identity == leader
        and after_identity == before_identity
    )


def _signal_exact(record: ProcessRecord, signum: int) -> bool:
    before = _record_for_pid(record.pid, record.identity)
    if before is None or not _identity_equal(before.identity, record.identity):
        return False
    try:
        os.kill(record.pid, signum)
    except ProcessLookupError as error:
        try:
            actual, state = _bsd_identity(record.pid)
        except ProcessLookupError as identity_error:
            if identity_error.errno in (errno.ESRCH, errno.ENOENT):
                return False
            raise RuntimeError(
                f"could not post-validate signaled process pid={record.pid}"
            ) from identity_error
        if state == 5:
            return False
        if not _identity_equal(actual, record.identity):
            raise RuntimeError(
                f"process identity changed across signal pid={record.pid}"
            ) from error
        raise RuntimeError(
            f"signal delivery failed for unchanged process pid={record.pid}"
        ) from error
    try:
        actual, state = _bsd_identity(record.pid)
    except ProcessLookupError as error:
        if error.errno in (errno.ESRCH, errno.ENOENT):
            return True
        raise RuntimeError(
            f"could not post-validate signaled process pid={record.pid}"
        ) from error
    if state == 5:
        return True
    if not _identity_equal(actual, record.identity):
        raise RuntimeError(f"process identity changed across signal pid={record.pid}")
    return True


def _classify(
    authorities: list[dict[str, object]],
    reference_authorities: list[dict[str, object]] | None = None,
    reference_failures: dict[int, tuple[ProcessIdentity, str]] | None = None,
) -> tuple[
    dict[int, ProcessRecord],
    dict[int, tuple[ProcessRecord, list[str]]],
    dict[int, ProcessRecord],
]:
    reference_authorities = (
        [] if reference_authorities is None else reference_authorities
    )
    records = _all_records()
    active_sids: set[int] = set()
    retired_sids: set[int] = set()
    unreaped_anchor_pids: set[int] = set()
    for authority in authorities:
        leader = _identity_from_dict(authority["leader"], "leader")
        live_leader = records.get(leader.pid)
        if (
            live_leader is not None
            and live_leader.state != 5
            and _identity_equal(live_leader.identity, leader)
        ):
            active_sids.add(leader.sid)
        elif _has_unreaped_exit_anchor(authority, records):
            active_sids.add(leader.sid)
            unreaped_anchor_pids.add(leader.pid)
        else:
            retired_sids.add(leader.sid)
    retired_sids -= active_sids
    leader_pids = {authority["leader"]["pid"] for authority in authorities}
    roots = {key: Path(value) for key, value in authorities[0]["roots"].items()}
    scopes = {str(authority["launchId"]) for authority in authorities}
    helper_ancestors = _ancestor_chain(records, os.getpid())
    try:
        reference_matches = _validate_live_reference_context(
            authorities,
            reference_authorities,
            records,
            active_sids,
        )
    except RuntimeError as error:
        if reference_failures is None:
            raise
        reference_matches = {}
        for authority in reference_authorities:
            subject = _identity_from_dict(authority["subject"], "reference subject")
            reference_failures[subject.pid] = (subject, str(error))
            record = records.get(subject.pid)
            if record is not None and _identity_equal(record.identity, subject):
                # A failed reference proof never upgrades its exact sealed
                # subject into signal authority, even if its SID collides.
                reference_matches[subject.pid] = (
                    authority,
                    record,
                    ["referenceValidationFailed"],
                )
    owned: dict[int, ProcessRecord] = {}
    foreign: dict[int, tuple[ProcessRecord, list[str]]] = {}
    exempt: dict[int, ProcessRecord] = {}
    for pid, record in records.items():
        if pid in helper_ancestors:
            exempt[pid] = record
            continue
        if pid in unreaped_anchor_pids:
            # A WNOWAIT-proven zombie preserves the session identity but can no
            # longer execute.  It authorizes containment of same-SID orphans;
            # it must not itself become a SIGSTOP target because a zombie can
            # never transition to the stopped state.
            exempt[pid] = record
            continue
        if pid in reference_matches:
            # Reference authority never grants signal authority.  Exact guard
            # identities are removed only from foreign-reference classification.
            exempt[pid] = record
            continue
        reasons = _reference_reasons(record, roots, scopes)
        if record.identity.uid == os.getuid() and record.identity.sid in active_sids:
            owned[pid] = record
            continue
        if record.identity.sid in retired_sids:
            reasons.append("retiredAuthorizedSession")
        escaped_session = any(
            _is_descendant(records, pid, leader) for leader in leader_pids
        )
        if escaped_session:
            reasons.append("authorizedLeaderDescendantChangedSession")
        if reasons or escaped_session:
            # Only the containment helper and its live ancestors are exempted
            # above.  Merely descending from the runner owner is not authority:
            # an unscoped sibling/child holding a protected root must block
            # deletion just like any other foreign same-UID process.
            foreign[pid] = (record, sorted(set(reasons)))
        else:
            exempt[pid] = record
    return owned, foreign, exempt


def _merge_foreign(
    target: dict[int, tuple[ProcessRecord, list[str]]],
    observed: dict[int, tuple[ProcessRecord, list[str]]],
) -> None:
    for pid, (record, reasons) in observed.items():
        previous = target.get(pid)
        if previous is None or not _identity_equal(
            previous[0].identity, record.identity
        ):
            target[pid] = (record, list(reasons))
            continue
        target[pid] = (record, sorted(set(previous[1]) | set(reasons)))


def _freeze_authorized(
    authorities: list[dict[str, object]],
    reference_authorities: list[dict[str, object]],
    timeout_ms: int,
    reference_failures: dict[int, tuple[ProcessIdentity, str]] | None = None,
) -> tuple[dict[int, ProcessRecord], dict[int, tuple[ProcessRecord, list[str]]]]:
    deadline = time.monotonic() + timeout_ms / 1000
    stopped: dict[int, ProcessRecord] = {}
    foreign: dict[int, tuple[ProcessRecord, list[str]]] = {}
    try:
        while True:
            owned, observed_foreign, _ = _classify(
                authorities, reference_authorities, reference_failures
            )
            _merge_foreign(foreign, observed_foreign)
            for record in owned.values():
                previous = stopped.get(record.pid)
                if previous is not None and _identity_equal(
                    previous.identity, record.identity
                ):
                    continue
                if _signal_exact(record, signal.SIGSTOP):
                    stopped[record.pid] = replace(record, state=record.state)
            confirmed, observed_foreign, _ = _classify(
                authorities, reference_authorities, reference_failures
            )
            _merge_foreign(foreign, observed_foreign)
            all_confirmed_stopped = all(
                pid in stopped
                and _identity_equal(stopped[pid].identity, record.identity)
                and record.state == 4
                for pid, record in confirmed.items()
            )
            if all_confirmed_stopped:
                # The confirming inventory proves every exact authorized
                # identity it observed has reached STOP.  Only after that proof
                # is complete may a fresh inventory close the enumeration race:
                # a child forked before its parent was observed stopped can be
                # absent from the confirming inventory, but must appear here and
                # (because it is not yet in ``stopped``) force another round.
                converged, observed_foreign, _ = _classify(
                    authorities, reference_authorities, reference_failures
                )
                _merge_foreign(foreign, observed_foreign)
                all_converged_stopped = all(
                    pid in stopped
                    and _identity_equal(stopped[pid].identity, record.identity)
                    and record.state == 4
                    for pid, record in converged.items()
                )
                if all_converged_stopped:
                    return stopped, foreign
            if time.monotonic() >= deadline:
                raise TimeoutError("authorized sessions could not be frozen")
            time.sleep(POLL_SECONDS)
    except BaseException:
        for record in stopped.values():
            _signal_exact(record, signal.SIGKILL)
            _signal_exact(record, signal.SIGCONT)
        raise


def _wait_authorized_empty(
    authorities: list[dict[str, object]],
    reference_authorities: list[dict[str, object]],
    timeout_ms: int,
    reference_failures: dict[int, tuple[ProcessIdentity, str]] | None = None,
) -> bool:
    deadline = time.monotonic() + timeout_ms / 1000
    while True:
        owned, _foreign, _exempt = _classify(
            authorities, reference_authorities, reference_failures
        )
        if not owned:
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(POLL_SECONDS)


def _contain(
    authorities: list[dict[str, object]],
    reference_authorities: list[dict[str, object]] | None = None,
    *,
    freeze_ms: int,
    term_ms: int,
    kill_ms: int,
) -> dict[str, object]:
    reference_authorities = (
        [] if reference_authorities is None else reference_authorities
    )
    reference_failures: dict[int, tuple[ProcessIdentity, str]] = {}
    stopped, foreign = _freeze_authorized(
        authorities,
        reference_authorities,
        freeze_ms,
        reference_failures,
    )
    term_sent: list[ProcessRecord] = []
    kill_sent: list[ProcessRecord] = []
    try:
        for record in stopped.values():
            if _signal_exact(record, signal.SIGTERM):
                term_sent.append(record)
        for record in stopped.values():
            _signal_exact(record, signal.SIGCONT)
        if not _wait_authorized_empty(
            authorities,
            reference_authorities,
            term_ms,
            reference_failures,
        ):
            survivors, observed_foreign, _ = _classify(
                authorities, reference_authorities, reference_failures
            )
            _merge_foreign(foreign, observed_foreign)
            for record in survivors.values():
                if _signal_exact(record, signal.SIGKILL):
                    kill_sent.append(record)
            if not _wait_authorized_empty(
                authorities,
                reference_authorities,
                kill_ms,
                reference_failures,
            ):
                remaining, observed_foreign, _ = _classify(
                    authorities, reference_authorities, reference_failures
                )
                _merge_foreign(foreign, observed_foreign)
                raise RuntimeError(
                    f"authorized sessions survived SIGKILL: {sorted(remaining)}"
                )
    except BaseException:
        for record in stopped.values():
            _signal_exact(record, signal.SIGKILL)
            _signal_exact(record, signal.SIGCONT)
        raise
    remaining, observed_foreign, exempt = _classify(
        authorities, reference_authorities, reference_failures
    )
    _merge_foreign(foreign, observed_foreign)
    inspected_records = {
        record.pid: record
        for record in (
            list(stopped.values())
            + list(remaining.values())
            + [item[0] for item in foreign.values()]
            + list(exempt.values())
        )
        if record.inspection_errors
    }
    if reference_failures:
        reference_matches = {}
    else:
        reference_matches = _validate_live_reference_context(
            authorities,
            reference_authorities,
            {**exempt, **remaining},
        )
    fallback_records = {
        record.pid: record
        for record in (
            list(stopped.values())
            + list(remaining.values())
            + [item[0] for item in foreign.values()]
            + [item[1] for item in reference_matches.values()]
        )
        if record.vnode_evidence_method == "sealed-lsof"
    }
    return {
        "stoppedProcesses": [
            record.as_dict()
            for record in sorted(stopped.values(), key=lambda item: item.pid)
        ],
        "termSentProcesses": [
            record.as_dict() for record in sorted(term_sent, key=lambda item: item.pid)
        ],
        "killSentProcesses": [
            record.as_dict() for record in sorted(kill_sent, key=lambda item: item.pid)
        ],
        "remainingOwnedProcesses": [
            record.as_dict()
            for record in sorted(remaining.values(), key=lambda item: item.pid)
        ],
        "foreignProcesses": [
            {"process": record.as_dict(), "reasons": reasons}
            for record, reasons in sorted(
                foreign.values(), key=lambda item: item[0].pid
            )
        ],
        "referenceExemptProcesses": [
            {
                "exemptionId": authority["exemptionId"],
                "process": record.as_dict(),
                "reasons": reasons,
            }
            for authority, record, reasons in sorted(
                reference_matches.values(), key=lambda item: item[1].pid
            )
        ],
        "inspectionLimitations": [
            {
                "identity": record.identity.as_dict(),
                "errors": list(record.inspection_errors),
            }
            for record in sorted(inspected_records.values(), key=lambda item: item.pid)
        ]
        + [
            {"identity": identity.as_dict(), "errors": [error]}
            for identity, error in sorted(
                reference_failures.values(), key=lambda item: item[0].pid
            )
        ],
        "referenceInspection": {
            "complete": not inspected_records and not reference_failures,
            "lsof": dict(LSOF_SEAL),
            "fallbackProcesses": [
                record.identity.as_dict()
                for record in sorted(
                    fallback_records.values(), key=lambda item: item.pid
                )
            ],
        },
    }


def write_evidence(path: Path, value: dict[str, object]) -> None:
    _write_exclusive_json(path, value)


def contain_and_write(
    authority_paths: list[Path],
    evidence: Path,
    *,
    freeze_ms: int,
    term_ms: int,
    kill_ms: int,
    reference_authority_paths: list[Path] | None = None,
) -> dict[str, object]:
    started_ns = time.monotonic_ns()
    authority_entries: list[dict[str, object]] = []
    authorities: list[dict[str, object]] = []
    reference_entries: list[dict[str, object]] = []
    reference_authorities: list[dict[str, object]] = []
    try:
        if not authority_paths:
            raise ValueError("at least one authority is required")
        for path in authority_paths:
            authority, digest = _load_authority(path)
            authorities.append(authority)
            authority_entries.append(
                {"path": str(path), "sha256": digest, "launchId": authority["launchId"]}
            )
        first = authorities[0]
        for authority in authorities[1:]:
            first_owner = _identity_from_dict(first["ownerRoot"], "ownerRoot")
            authority_owner = _identity_from_dict(authority["ownerRoot"], "ownerRoot")
            if (
                not _identity_equal(authority_owner, first_owner)
                or authority["roots"] != first["roots"]
            ):
                raise ValueError(
                    "authorities do not share the exact ownerRoot and roots"
                )
        for path in reference_authority_paths or []:
            reference_authority, digest = _load_reference_authority(path)
            reference_authorities.append(reference_authority)
            reference_entries.append(
                {
                    "path": str(path),
                    "sha256": digest,
                    "exemptionId": reference_authority["exemptionId"],
                }
            )
        if len({entry["exemptionId"] for entry in reference_entries}) != len(
            reference_entries
        ):
            raise ValueError("reference authorities contain duplicate exemptionIds")
        _validate_live_authority_context(authorities)
        contained = _contain(
            authorities,
            reference_authorities,
            freeze_ms=freeze_ms,
            term_ms=term_ms,
            kill_ms=kill_ms,
        )
        _assert_authority_files_unchanged(authority_entries)
        _assert_reference_authority_files_unchanged(reference_entries)
        contained.setdefault("inspectionLimitations", [])
        contained.setdefault("referenceExemptProcesses", [])
        contained.setdefault(
            "referenceInspection",
            {
                "complete": not contained["inspectionLimitations"],
                "lsof": dict(LSOF_SEAL),
                "fallbackProcesses": [],
            },
        )
        if contained["inspectionLimitations"]:
            status = "error"
        else:
            status = (
                "foreign_reference" if contained["foreignProcesses"] else "quiescent"
            )
        value: dict[str, object] = {
            "version": EVIDENCE_VERSION,
            "status": status,
            "marker": MARKER_NAME,
            "ownerRoot": first["ownerRoot"],
            "roots": first["roots"],
            "authorities": authority_entries,
            "referenceAuthorities": reference_entries,
            "authorizedSessions": sorted(
                {authority["leader"]["sid"] for authority in authorities}
            ),
            "startedMonotonicNs": started_ns,
            "endedMonotonicNs": time.monotonic_ns(),
            **contained,
        }
        if status == "error":
            value["error"] = "process reference inspection was incomplete"
    except BaseException as error:
        value = {
            "version": EVIDENCE_VERSION,
            "status": "error",
            "marker": MARKER_NAME,
            "authorities": authority_entries,
            "referenceAuthorities": reference_entries,
            "startedMonotonicNs": started_ns,
            "endedMonotonicNs": time.monotonic_ns(),
            "error": f"{type(error).__name__}: {error}",
            "stoppedProcesses": [],
            "termSentProcesses": [],
            "killSentProcesses": [],
            "remainingOwnedProcesses": [],
            "foreignProcesses": [],
            "referenceExemptProcesses": [],
            "inspectionLimitations": [],
            "referenceInspection": {
                "complete": False,
                "lsof": dict(LSOF_SEAL),
                "fallbackProcesses": [],
            },
        }
    write_evidence(evidence, value)
    return value


def audit_and_write(
    authority_paths: list[Path],
    evidence: Path,
) -> dict[str, object]:
    """Audit historical launch scopes without granting any signal authority."""

    started_ns = time.monotonic_ns()
    authority_entries: list[dict[str, object]] = []
    authorities: list[dict[str, object]] = []
    try:
        if not authority_paths:
            raise ValueError("at least one authority is required")
        for path in authority_paths:
            authority, digest = _load_authority(path)
            authorities.append(authority)
            authority_entries.append(
                {"path": str(path), "sha256": digest, "launchId": authority["launchId"]}
            )
        first = authorities[0]
        first_owner = _identity_from_dict(first["ownerRoot"], "ownerRoot")
        for authority in authorities[1:]:
            owner = _identity_from_dict(authority["ownerRoot"], "ownerRoot")
            if (
                not _identity_equal(owner, first_owner)
                or authority["roots"] != first["roots"]
            ):
                raise ValueError(
                    "authorities do not share the exact ownerRoot and roots"
                )
        records = _all_records()
        roots = {key: Path(value) for key, value in first["roots"].items()}
        scopes = {str(authority["launchId"]) for authority in authorities}
        helper_ancestors = _ancestor_chain(records, os.getpid())
        foreign: list[dict[str, object]] = []
        inspected: list[dict[str, object]] = []
        fallback: list[dict[str, int]] = []
        for pid, record in sorted(records.items()):
            if pid in helper_ancestors:
                continue
            reasons = _reference_reasons(record, roots, scopes)
            if reasons:
                foreign.append(
                    {"process": record.as_dict(), "reasons": sorted(set(reasons))}
                )
            if record.inspection_errors:
                inspected.append(
                    {
                        "identity": record.identity.as_dict(),
                        "errors": list(record.inspection_errors),
                    }
                )
            if record.vnode_evidence_method == "sealed-lsof":
                fallback.append(record.identity.as_dict())
        status = (
            "error" if inspected else ("foreign_reference" if foreign else "quiescent")
        )
        value: dict[str, object] = {
            "version": EVIDENCE_VERSION,
            "mode": "audit-only",
            "status": status,
            "marker": AUDIT_MARKER_NAME,
            "ownerRoot": first["ownerRoot"],
            "roots": first["roots"],
            "authorities": authority_entries,
            "referenceAuthorities": [],
            "authorizedSessions": [],
            "startedMonotonicNs": started_ns,
            "endedMonotonicNs": time.monotonic_ns(),
            "stoppedProcesses": [],
            "termSentProcesses": [],
            "killSentProcesses": [],
            "remainingOwnedProcesses": [],
            "foreignProcesses": foreign,
            "referenceExemptProcesses": [],
            "inspectionLimitations": inspected,
            "referenceInspection": {
                "complete": not inspected,
                "lsof": dict(LSOF_SEAL),
                "fallbackProcesses": fallback,
            },
        }
        if inspected:
            value["error"] = "process reference inspection was incomplete"
    except BaseException as error:
        value = {
            "version": EVIDENCE_VERSION,
            "mode": "audit-only",
            "status": "error",
            "marker": AUDIT_MARKER_NAME,
            "authorities": authority_entries,
            "referenceAuthorities": [],
            "authorizedSessions": [],
            "startedMonotonicNs": started_ns,
            "endedMonotonicNs": time.monotonic_ns(),
            "error": f"{type(error).__name__}: {error}",
            "stoppedProcesses": [],
            "termSentProcesses": [],
            "killSentProcesses": [],
            "remainingOwnedProcesses": [],
            "foreignProcesses": [],
            "referenceExemptProcesses": [],
            "inspectionLimitations": [],
            "referenceInspection": {
                "complete": False,
                "lsof": dict(LSOF_SEAL),
                "fallbackProcesses": [],
            },
        }
    write_evidence(evidence, value)
    return value


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    contain = subparsers.add_parser("contain")
    contain.add_argument("--authority", type=Path, action="append", required=True)
    contain.add_argument(
        "--reference-authority", type=Path, action="append", default=[]
    )
    contain.add_argument("--evidence", type=Path, required=True)
    contain.add_argument("--freeze-ms", type=int, default=5000)
    contain.add_argument("--term-ms", type=int, default=5000)
    contain.add_argument("--kill-ms", type=int, default=5000)
    audit = subparsers.add_parser("audit")
    audit.add_argument("--authority", type=Path, action="append", required=True)
    audit.add_argument("--evidence", type=Path, required=True)
    create_reference = subparsers.add_parser("create-reference")
    create_reference.add_argument("--subject-pid", type=int, required=True)
    create_reference.add_argument("--owner-root-pid", type=int, required=True)
    create_reference.add_argument("--exemption-id", required=True)
    create_reference.add_argument("--program", type=Path, required=True)
    create_reference.add_argument("--program-sha256", required=True)
    create_reference.add_argument("--readiness", type=Path, required=True)
    create_reference.add_argument("--nonce", required=True)
    create_reference.add_argument("--stop", type=Path, required=True)
    create_reference.add_argument("--result", type=Path, required=True)
    create_reference.add_argument("--gradle-user-home", type=Path, required=True)
    create_reference.add_argument("--isolated-user-root", type=Path, required=True)
    create_reference.add_argument("--home", type=Path, required=True)
    create_reference.add_argument("--sandbox-run-temp", type=Path, required=True)
    create_reference.add_argument(
        "--kotlin-project-persistent-dir", type=Path, required=True
    )
    create_reference.add_argument(
        "--kotlin-daemon-run-files-dir", type=Path, required=True
    )
    create_reference.add_argument("--output", type=Path, required=True)
    verify_reference = subparsers.add_parser("verify-reference")
    verify_reference.add_argument("--authority", type=Path, required=True)
    verify_reference.add_argument("--owner-root-pid", type=int, required=True)
    args = parser.parse_args(argv)
    if (
        args.command == "contain"
        and min(args.freeze_ms, args.term_ms, args.kill_ms) < 0
    ):
        parser.error("timeouts must be non-negative")
    if (
        args.command == "create-reference"
        and min(args.subject_pid, args.owner_root_pid) <= 1
    ):
        parser.error("reference PIDs must be greater than one")
    if args.command == "verify-reference" and args.owner_root_pid <= 1:
        parser.error("reference owner PID must be greater than one")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.command == "create-reference":
        roots = {
            "gradleUserHome": args.gradle_user_home,
            "isolatedUserRoot": args.isolated_user_root,
            "home": args.home,
            "sandboxRunTemp": args.sandbox_run_temp,
            "kotlinProjectPersistentDir": args.kotlin_project_persistent_dir,
            "kotlinDaemonRunFilesDir": args.kotlin_daemon_run_files_dir,
        }
        create_reference_authority(
            subject_pid=args.subject_pid,
            owner_root_pid=args.owner_root_pid,
            exemption_id=args.exemption_id,
            program_path=args.program,
            program_sha256=args.program_sha256,
            readiness_path=args.readiness,
            readiness_nonce=args.nonce,
            stop_path=args.stop,
            result_path=args.result,
            roots=roots,
            authority_path=args.output,
        )
        return 0
    if args.command == "verify-reference":
        verify_reference_authority(
            args.authority,
            owner_root_pid=args.owner_root_pid,
        )
        return 0
    if args.command == "audit":
        value = audit_and_write(args.authority, args.evidence)
        return 0 if value.get("status") == "quiescent" else 1
    value = contain_and_write(
        args.authority,
        args.evidence,
        freeze_ms=args.freeze_ms,
        term_ms=args.term_ms,
        kill_ms=args.kill_ms,
        reference_authority_paths=args.reference_authority,
    )
    return 0 if value.get("status") == "quiescent" else 1


if __name__ == "__main__":
    raise SystemExit(main())
