from __future__ import annotations

import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


HERE = Path(__file__).resolve().parent
HELPER = HERE / "process_scope.py"
LAUNCH_A = "a" * 32
LAUNCH_B = "b" * 32
SPECIFICATION = importlib.util.spec_from_file_location(
    "test_target_process_scope",
    HELPER,
)
if SPECIFICATION is None or SPECIFICATION.loader is None:
    raise RuntimeError(f"could not load {HELPER}")
PROCESS_SCOPE = importlib.util.module_from_spec(SPECIFICATION)
sys.modules[SPECIFICATION.name] = PROCESS_SCOPE
SPECIFICATION.loader.exec_module(PROCESS_SCOPE)


def identity(
    pid: int,
    *,
    ppid: int = 1,
    pgid: int | None = None,
    sid: int | None = None,
    uid: int | None = None,
    start: int | None = None,
):
    return PROCESS_SCOPE.ProcessIdentity(
        pid=pid,
        ppid=ppid,
        pgid=pid if pgid is None else pgid,
        sid=pid if sid is None else sid,
        uid=os.getuid() if uid is None else uid,
        start_sec=pid if start is None else start,
        start_usec=7,
    )


def record(
    pid: int,
    *,
    ppid: int = 1,
    sid: int | None = None,
    uid: int | None = None,
    argv: tuple[str, ...] = ("/bin/sleep", "60"),
    environment: dict[str, str] | None = None,
    cwd: str | None = None,
    root: str | None = "/",
    open_paths: tuple[str, ...] = (),
    state: int = 3,
    start: int | None = None,
):
    process_identity = identity(
        pid,
        ppid=ppid,
        pgid=sid,
        sid=sid,
        uid=uid,
        start=start,
    )
    return PROCESS_SCOPE.ProcessRecord(
        identity=process_identity,
        executable=argv[0],
        argv=argv,
        environment={} if environment is None else environment,
        state=state,
        cwd=cwd,
        root=root,
        open_vnode_paths=open_paths,
    )


class ProcessScopeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="gate-c-process-scope.")
        self.root = Path(self.temporary.name).resolve(strict=True)
        self.isolated = self.root / "isolated"
        self.home = self.isolated / "home"
        self.sandbox = self.isolated / "sandbox"
        self.kotlin_project = self.sandbox / "kotlin-project"
        self.kotlin_daemon = self.sandbox / "kotlin-daemon"
        self.gradle = self.root / "gradle"
        self.cwd = self.root / "cwd"
        for directory in (
            self.isolated,
            self.home,
            self.sandbox,
            self.kotlin_project,
            self.kotlin_daemon,
            self.gradle,
            self.cwd,
        ):
            directory.mkdir(mode=0o700)
        self.wrapper = self.root / "wrapper.zsh"
        self.wrapper.write_text("#!/bin/zsh\nexit 0\n", encoding="utf-8")
        self.wrapper.chmod(0o700)
        self.roots = {
            "gradleUserHome": self.gradle,
            "isolatedUserRoot": self.isolated,
            "home": self.home,
            "sandboxRunTemp": self.sandbox,
            "kotlinProjectPersistentDir": self.kotlin_project,
            "kotlinDaemonRunFilesDir": self.kotlin_daemon,
        }

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def authority(self, *, leader_pid: int = 200, sid: int = 200) -> dict:
        return {
            "version": 2,
            "launchId": LAUNCH_A,
            "ownerRoot": identity(100, ppid=1, sid=100).as_dict(),
            "supervisor": identity(150, ppid=100, sid=100).as_dict(),
            "leader": identity(
                leader_pid,
                ppid=150,
                pgid=sid,
                sid=sid,
            ).as_dict(),
            "wrapper": {
                "path": str(self.wrapper),
                "sha256": hashlib.sha256(self.wrapper.read_bytes()).hexdigest(),
            },
            "roots": {key: str(value) for key, value in sorted(self.roots.items())},
            "cwd": str(self.cwd),
        }

    def write_authority(self, name: str, value: dict | None = None) -> Path:
        path = self.root / name
        path.write_text(
            json.dumps(self.authority() if value is None else value),
            encoding="utf-8",
        )
        path.chmod(0o600)
        return path

    def create_reference_authority_fixture(
        self,
        *,
        subject_pid: int = 500,
        subject_start: int = 50,
        argv: tuple[str, ...] | None = None,
        readiness_pid: int | None = None,
        readiness_nonce: str = LAUNCH_B,
    ) -> tuple[dict, Path, dict[int, object]]:
        program = self.root / "source_tree_guard.py"
        program.write_text("raise SystemExit(0)\n", encoding="utf-8")
        program.chmod(0o600)
        readiness = self.root / "source-guard.ready.json"
        readiness.write_text(
            json.dumps(
                {
                    "version": 3,
                    "pid": subject_pid if readiness_pid is None else readiness_pid,
                    "nonce": readiness_nonce,
                }
            ),
            encoding="utf-8",
        )
        readiness.chmod(0o600)
        executable = os.path.realpath(sys.executable)
        subject_argv = argv or (
            executable,
            "-I",
            "-S",
            "-B",
            str(program),
            "--ready",
            str(readiness),
        )
        owner_pid = 100
        authorizer_parent_pid = 150
        current_pid = os.getpid()
        owner = record(owner_pid, sid=100)
        authorizer_parent = record(authorizer_parent_pid, ppid=owner_pid, sid=100)
        current = record(
            current_pid,
            ppid=authorizer_parent_pid,
            sid=os.getsid(0),
            argv=(executable, "process_scope.py"),
        )
        subject = record(
            subject_pid,
            ppid=owner_pid,
            sid=100,
            start=subject_start,
            argv=subject_argv,
            environment={"HOME": str(self.home)},
        )
        records = {
            owner_pid: owner,
            authorizer_parent_pid: authorizer_parent,
            current_pid: current,
            subject_pid: subject,
        }
        authority_path = self.root / "reference-authority.json"
        with (
            mock.patch.object(
                PROCESS_SCOPE, "_identity_inventory", return_value=records
            ),
            mock.patch.object(
                PROCESS_SCOPE,
                "_record_for_pid",
                side_effect=lambda pid: records.get(pid),
            ),
        ):
            value = PROCESS_SCOPE.create_reference_authority(
                subject_pid=subject_pid,
                owner_root_pid=owner_pid,
                exemption_id=LAUNCH_A,
                program_path=program,
                program_sha256=hashlib.sha256(program.read_bytes()).hexdigest(),
                readiness_path=readiness,
                readiness_nonce=readiness_nonce,
                stop_path=self.root / "source-guard.stop",
                result_path=self.root / "source-guard.result.json",
                roots=self.roots,
                authority_path=authority_path,
            )
        return value, authority_path, records

    def test_copied_marker_in_different_session_is_foreign_and_never_owned(
        self,
    ) -> None:
        copied = record(
            300,
            sid=300,
            environment={PROCESS_SCOPE.MARKER_NAME: LAUNCH_A},
        )
        records = {300: copied}
        with mock.patch.object(PROCESS_SCOPE, "_all_records", return_value=records):
            owned, foreign, _exempt = PROCESS_SCOPE._classify([self.authority()])

        self.assertNotIn(300, owned)
        self.assertIn("marker", foreign[300][1])

    def test_live_exact_leader_child_is_owned_without_marker(self) -> None:
        leader = record(200, ppid=150, sid=200)
        child = record(301, ppid=200, sid=200)
        with mock.patch.object(
            PROCESS_SCOPE,
            "_all_records",
            return_value={200: leader, 301: child},
        ):
            owned, foreign, _exempt = PROCESS_SCOPE._classify([self.authority()])

        self.assertIn(200, owned)
        self.assertIn(301, owned)
        self.assertEqual(foreign, {})

    def test_absent_leader_reused_session_is_foreign(self) -> None:
        reused_session = record(301, ppid=1, sid=200)
        with mock.patch.object(
            PROCESS_SCOPE,
            "_all_records",
            return_value={301: reused_session},
        ):
            owned, foreign, _exempt = PROCESS_SCOPE._classify([self.authority()])

        self.assertEqual(owned, {})
        self.assertIn("retiredAuthorizedSession", foreign[301][1])

    def test_mismatched_leader_identity_makes_session_foreign(self) -> None:
        reused_leader = record(200, ppid=150, sid=200, start=201)
        same_session_child = record(301, ppid=200, sid=200)
        with mock.patch.object(
            PROCESS_SCOPE,
            "_all_records",
            return_value={200: reused_leader, 301: same_session_child},
        ):
            owned, foreign, _exempt = PROCESS_SCOPE._classify([self.authority()])

        self.assertEqual(owned, {})
        self.assertIn("retiredAuthorizedSession", foreign[200][1])
        self.assertIn("retiredAuthorizedSession", foreign[301][1])

    def test_absent_leader_with_no_session_members_is_quiescent(self) -> None:
        with mock.patch.object(PROCESS_SCOPE, "_all_records", return_value={}):
            value = PROCESS_SCOPE._contain(
                [self.authority()],
                freeze_ms=100,
                term_ms=100,
                kill_ms=100,
            )

        self.assertEqual(value["remainingOwnedProcesses"], [])
        self.assertEqual(value["foreignProcesses"], [])

    def test_contain_never_signals_reused_retired_session(self) -> None:
        reused_session = record(301, ppid=1, sid=200)
        with (
            mock.patch.object(
                PROCESS_SCOPE,
                "_all_records",
                return_value={301: reused_session},
            ),
            mock.patch.object(PROCESS_SCOPE, "_signal_exact") as signal_exact,
        ):
            value = PROCESS_SCOPE._contain(
                [self.authority()],
                freeze_ms=100,
                term_ms=100,
                kill_ms=100,
            )

        signal_exact.assert_not_called()
        self.assertEqual(value["stoppedProcesses"], [])
        self.assertEqual(value["termSentProcesses"], [])
        self.assertEqual(value["killSentProcesses"], [])
        self.assertEqual(
            value["foreignProcesses"][0]["reasons"],
            ["retiredAuthorizedSession"],
        )

    def test_active_authority_wins_over_retired_authority_with_same_sid(self) -> None:
        active = self.authority(leader_pid=200, sid=200)
        retired = self.authority(leader_pid=201, sid=200)
        retired["launchId"] = LAUNCH_B
        leader = record(200, ppid=150, sid=200)
        child = record(301, ppid=200, sid=200)
        with mock.patch.object(
            PROCESS_SCOPE,
            "_all_records",
            return_value={200: leader, 301: child},
        ):
            owned, foreign, _exempt = PROCESS_SCOPE._classify([active, retired])

        self.assertEqual(set(owned), {200, 301})
        self.assertEqual(foreign, {})

    def test_unreaped_exit_anchor_authorizes_same_session_orphan(self) -> None:
        current_pid = os.getpid()
        authority = self.authority()
        supervisor = record(current_pid, ppid=100, sid=100)
        authority["supervisor"] = supervisor.identity.as_dict()
        authority["leader"] = identity(
            200,
            ppid=current_pid,
            pgid=200,
            sid=200,
        ).as_dict()
        orphan = record(301, ppid=1, sid=200)
        records = {current_pid: supervisor, 301: orphan}
        observed = SimpleNamespace(
            si_pid=200,
            si_code=os.CLD_EXITED,
            si_status=0,
        )
        with (
            mock.patch.object(PROCESS_SCOPE, "_all_records", return_value=records),
            mock.patch.object(
                PROCESS_SCOPE.os, "waitid", return_value=observed
            ) as waitid,
            mock.patch.object(
                PROCESS_SCOPE,
                "_zombie_identity",
                return_value=(identity(200, ppid=current_pid, sid=200), 5),
            ),
        ):
            owned, foreign, _exempt = PROCESS_SCOPE._classify([authority])

        self.assertEqual(set(owned), {301})
        self.assertEqual(foreign, {})
        waitid.assert_called_once_with(
            os.P_PID,
            200,
            os.WEXITED | os.WNOHANG | os.WNOWAIT,
        )

    def test_verified_zombie_anchor_is_not_itself_a_freeze_target(self) -> None:
        current_pid = os.getpid()
        authority = self.authority()
        supervisor = record(current_pid, ppid=100, sid=100)
        authority["supervisor"] = supervisor.identity.as_dict()
        authority["leader"] = identity(
            200,
            ppid=current_pid,
            pgid=200,
            sid=200,
        ).as_dict()
        zombie = record(200, ppid=current_pid, sid=200, state=5)
        orphan = record(301, ppid=1, sid=200)
        records = {current_pid: supervisor, 200: zombie, 301: orphan}
        with (
            mock.patch.object(PROCESS_SCOPE, "_all_records", return_value=records),
            mock.patch.object(
                PROCESS_SCOPE, "_has_unreaped_exit_anchor", return_value=True
            ) as has_anchor,
        ):
            owned, foreign, exempt = PROCESS_SCOPE._classify([authority])

        self.assertEqual(set(owned), {301})
        self.assertEqual(foreign, {})
        self.assertEqual(set(exempt), {current_pid, 200})
        has_anchor.assert_called_once_with(authority, records)

    def test_unreaped_exit_anchor_orphan_is_selected_for_signal(self) -> None:
        current_pid = os.getpid()
        authority = self.authority()
        supervisor = record(current_pid, ppid=100, sid=100)
        authority["supervisor"] = supervisor.identity.as_dict()
        authority["leader"] = identity(
            200,
            ppid=current_pid,
            pgid=200,
            sid=200,
        ).as_dict()
        orphan = record(301, ppid=1, sid=200)
        snapshots = [
            {current_pid: supervisor, 301: orphan},
            {current_pid: supervisor},
            {current_pid: supervisor},
        ]
        observed = SimpleNamespace(si_pid=200, si_code=os.CLD_EXITED, si_status=0)
        with (
            mock.patch.object(
                PROCESS_SCOPE,
                "_all_records",
                side_effect=lambda: (
                    snapshots.pop(0) if snapshots else {current_pid: supervisor}
                ),
            ),
            mock.patch.object(PROCESS_SCOPE.os, "waitid", return_value=observed),
            mock.patch.object(
                PROCESS_SCOPE,
                "_zombie_identity",
                return_value=(identity(200, ppid=current_pid, sid=200), 5),
            ),
            mock.patch.object(
                PROCESS_SCOPE, "_signal_exact", return_value=True
            ) as signal_exact,
        ):
            stopped, foreign = PROCESS_SCOPE._freeze_authorized(
                [authority],
                [],
                timeout_ms=100,
            )

        self.assertEqual(set(stopped), {301})
        self.assertEqual(foreign, {})
        signal_exact.assert_called_once_with(orphan, signal.SIGSTOP)

    def test_freeze_accepts_the_exact_post_signal_stopped_rescan(self) -> None:
        running = record(301, ppid=200, sid=200, state=2)
        stopped = record(301, ppid=200, sid=200, state=4)
        snapshots = [
            ({301: running}, {}, {}),
            ({301: stopped}, {}, {}),
            ({301: stopped}, {}, {}),
        ]
        with (
            mock.patch.object(
                PROCESS_SCOPE,
                "_classify",
                side_effect=snapshots,
            ),
            mock.patch.object(
                PROCESS_SCOPE, "_signal_exact", return_value=True
            ) as signal_exact,
            mock.patch.object(PROCESS_SCOPE.time, "monotonic", return_value=1.0),
        ):
            frozen, foreign = PROCESS_SCOPE._freeze_authorized(
                [self.authority()],
                [],
                timeout_ms=0,
            )

        self.assertEqual(frozen, {301: running})
        self.assertEqual(foreign, {})
        signal_exact.assert_called_once_with(running, signal.SIGSTOP)

    def test_freeze_stops_child_first_seen_after_parent_stop_confirmation(
        self,
    ) -> None:
        running_parent = record(301, ppid=200, sid=200, state=2)
        stopped_parent = record(301, ppid=200, sid=200, state=4)
        running_child = record(302, ppid=301, sid=200, state=2)
        stopped_child = record(302, ppid=301, sid=200, state=4)
        snapshots = [
            ({301: running_parent}, {}, {}),
            ({301: stopped_parent}, {}, {}),
            ({301: stopped_parent, 302: running_child}, {}, {}),
            ({301: stopped_parent, 302: running_child}, {}, {}),
            ({301: stopped_parent, 302: stopped_child}, {}, {}),
            ({301: stopped_parent, 302: stopped_child}, {}, {}),
        ]
        with (
            mock.patch.object(PROCESS_SCOPE, "_classify", side_effect=snapshots),
            mock.patch.object(
                PROCESS_SCOPE, "_signal_exact", return_value=True
            ) as signal_exact,
            mock.patch.object(
                PROCESS_SCOPE.time,
                "monotonic",
                side_effect=[1.0, 1.0, 1.0],
            ),
        ):
            frozen, foreign = PROCESS_SCOPE._freeze_authorized(
                [self.authority()],
                [],
                timeout_ms=1,
            )

        self.assertEqual(set(frozen), {301, 302})
        self.assertEqual(foreign, {})
        self.assertEqual(
            signal_exact.call_args_list,
            [
                mock.call(running_parent, signal.SIGSTOP),
                mock.call(running_child, signal.SIGSTOP),
            ],
        )

    def test_waitid_pid_match_with_reused_zombie_identity_is_retired(self) -> None:
        current_pid = os.getpid()
        authority = self.authority()
        supervisor = record(current_pid, ppid=100, sid=100)
        authority["supervisor"] = supervisor.identity.as_dict()
        authority["leader"] = identity(
            200,
            ppid=current_pid,
            pgid=200,
            sid=200,
            start=10,
        ).as_dict()
        reused = record(301, ppid=1, sid=200)
        records = {current_pid: supervisor, 301: reused}
        observed = SimpleNamespace(si_pid=200, si_code=os.CLD_EXITED, si_status=0)
        with (
            mock.patch.object(PROCESS_SCOPE, "_all_records", return_value=records),
            mock.patch.object(PROCESS_SCOPE.os, "waitid", return_value=observed),
            mock.patch.object(
                PROCESS_SCOPE,
                "_zombie_identity",
                return_value=(identity(200, ppid=current_pid, sid=200, start=11), 5),
            ),
        ):
            owned, foreign, _exempt = PROCESS_SCOPE._classify([authority])

        self.assertEqual(owned, {})
        self.assertIn("retiredAuthorizedSession", foreign[301][1])

    def test_zombie_anchor_rejects_wrong_lineage_and_snapshot_change(self) -> None:
        current_pid = os.getpid()
        authority = self.authority()
        supervisor = record(current_pid, ppid=100, sid=100)
        leader = identity(200, ppid=current_pid, pgid=200, sid=200)
        authority["supervisor"] = supervisor.identity.as_dict()
        authority["leader"] = leader.as_dict()
        reused = record(301, ppid=1, sid=200)
        records = {current_pid: supervisor, 301: reused}
        observed = SimpleNamespace(si_pid=200, si_code=os.CLD_EXITED, si_status=0)
        cases = {
            "wrong-ppid": [
                identity(200, ppid=current_pid + 1, pgid=200, sid=200),
            ],
            "wrong-pgid": [
                identity(200, ppid=current_pid, pgid=201, sid=200),
            ],
            "changed-after-waitid": [
                leader,
                identity(200, ppid=current_pid, pgid=200, sid=200, start=201),
            ],
        }
        for name, snapshots in cases.items():
            with (
                self.subTest(name=name),
                mock.patch.object(PROCESS_SCOPE, "_all_records", return_value=records),
                mock.patch.object(PROCESS_SCOPE.os, "waitid", return_value=observed),
                mock.patch.object(
                    PROCESS_SCOPE,
                    "_zombie_identity",
                    side_effect=[(item, 5) for item in snapshots],
                ),
                mock.patch.object(PROCESS_SCOPE, "_signal_exact") as signal_exact,
            ):
                owned, foreign, _exempt = PROCESS_SCOPE._classify([authority])
            self.assertEqual(owned, {})
            self.assertIn("retiredAuthorizedSession", foreign[301][1])
            signal_exact.assert_not_called()

    def test_zombie_anchor_rejects_invalid_wait_and_state_evidence(self) -> None:
        current_pid = os.getpid()
        authority = self.authority()
        supervisor = record(current_pid, ppid=100, sid=100)
        leader = identity(200, ppid=current_pid, pgid=200, sid=200)
        authority["supervisor"] = supervisor.identity.as_dict()
        authority["leader"] = leader.as_dict()
        records = {current_pid: supervisor}
        cases = (
            ("not-zombie", [(leader, 3)], None),
            ("no-wait-result", [(leader, 5)], None),
            (
                "wrong-wait-pid",
                [(leader, 5)],
                SimpleNamespace(si_pid=201, si_code=os.CLD_EXITED, si_status=0),
            ),
            (
                "nonterminal",
                [(leader, 5)],
                SimpleNamespace(si_pid=200, si_code=os.CLD_STOPPED, si_status=0),
            ),
            (
                "uid-mismatch",
                [(leader, 5)],
                SimpleNamespace(
                    si_pid=200,
                    si_uid=leader.uid + 1,
                    si_code=os.CLD_EXITED,
                    si_status=0,
                ),
            ),
            (
                "after-state-changed",
                [(leader, 5), (leader, 3)],
                SimpleNamespace(si_pid=200, si_code=os.CLD_EXITED, si_status=0),
            ),
        )
        for name, snapshots, observed in cases:
            with (
                self.subTest(name=name),
                mock.patch.object(
                    PROCESS_SCOPE,
                    "_zombie_identity",
                    side_effect=[item for item in snapshots],
                ),
                mock.patch.object(PROCESS_SCOPE.os, "waitid", return_value=observed),
            ):
                self.assertFalse(
                    PROCESS_SCOPE._has_unreaped_exit_anchor(authority, records)
                )

    @unittest.skipUnless(sys.platform == "darwin", "requires Darwin zombie identity")
    def test_real_unreaped_zombie_anchor_does_not_require_getsid(self) -> None:
        release_read, release_write = os.pipe()
        child = subprocess.Popen(
            [
                sys.executable,
                "-I",
                "-S",
                "-B",
                "-c",
                "import os,sys; os.read(int(sys.argv[1]), 1)",
                str(release_read),
            ],
            start_new_session=True,
            pass_fds=(release_read,),
        )
        os.close(release_read)
        try:
            leader_record = PROCESS_SCOPE._record_for_pid(child.pid)
            current = PROCESS_SCOPE._record_for_pid(os.getpid())
            self.assertIsNotNone(leader_record)
            self.assertIsNotNone(current)
            os.write(release_write, b"G")
            observed = os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOWAIT)
            self.assertEqual(observed.si_pid, child.pid)
            authority = self.authority(leader_pid=child.pid, sid=child.pid)
            authority["supervisor"] = current.identity.as_dict()
            authority["leader"] = leader_record.identity.as_dict()
            self.assertTrue(
                PROCESS_SCOPE._has_unreaped_exit_anchor(
                    authority,
                    {os.getpid(): current},
                )
            )
        finally:
            os.close(release_write)
            child.wait(timeout=2)

    def test_audit_ignores_reused_historical_sid_without_references(self) -> None:
        reused = record(301, ppid=1, sid=200)
        evidence = self.root / "audit.json"
        authority_path = self.write_authority("historical.json")
        with (
            mock.patch.object(
                PROCESS_SCOPE, "_all_records", return_value={301: reused}
            ),
            mock.patch.object(PROCESS_SCOPE, "_signal_exact") as signal_exact,
        ):
            value = PROCESS_SCOPE.audit_and_write([authority_path], evidence)

        signal_exact.assert_not_called()
        self.assertEqual(value["mode"], "audit-only")
        self.assertEqual(value["marker"], PROCESS_SCOPE.AUDIT_MARKER_NAME)
        self.assertEqual(value["status"], "quiescent")
        self.assertEqual(value["authorizedSessions"], [])

    def test_audit_retains_reused_sid_with_protected_root_reference(self) -> None:
        reused = record(
            301,
            ppid=1,
            sid=200,
            open_paths=(str(self.gradle / "daemon.lock"),),
        )
        evidence = self.root / "audit-reference.json"
        authority_path = self.write_authority("historical-reference.json")
        with mock.patch.object(
            PROCESS_SCOPE,
            "_all_records",
            return_value={301: reused},
        ):
            value = PROCESS_SCOPE.audit_and_write([authority_path], evidence)

        self.assertEqual(value["status"], "foreign_reference")
        self.assertIn(
            "openFd:gradleUserHome",
            value["foreignProcesses"][0]["reasons"],
        )

    def test_disappeared_reference_does_not_block_authorized_session_containment(
        self,
    ) -> None:
        authority = self.authority()
        leader = record(200, ppid=150, sid=200)
        child = record(301, ppid=200, sid=200)
        stopped_leader = PROCESS_SCOPE.replace(leader, state=4)
        stopped_child = PROCESS_SCOPE.replace(child, state=4)
        guard = record(
            500,
            ppid=100,
            sid=200,
            open_paths=(str(self.gradle / "guard.lock"),),
        )
        snapshots = [
            {200: leader, 301: child, 500: guard},
            {200: stopped_leader, 301: stopped_child, 500: guard},
            {200: stopped_leader, 301: stopped_child, 500: guard},
            {200: stopped_leader, 301: stopped_child, 500: guard},
            {200: stopped_leader, 301: stopped_child, 500: guard},
            {500: guard},
            {500: guard},
        ]
        reference = {
            "exemptionId": LAUNCH_B,
            "subject": identity(500, ppid=100, sid=200).as_dict(),
        }
        evidence = self.root / "reference-failure-containment.json"
        authority_path = self.root / "runtime-authority.json"
        reference_path = self.root / "runtime-reference.json"
        signals = []

        def signal_exact(item, signum):
            signals.append((item.pid, signum))
            return True

        with (
            mock.patch.object(
                PROCESS_SCOPE,
                "_load_authority",
                return_value=(authority, "a" * 64),
            ),
            mock.patch.object(
                PROCESS_SCOPE,
                "_load_reference_authority",
                return_value=(reference, "b" * 64),
            ),
            mock.patch.object(PROCESS_SCOPE, "_validate_live_authority_context"),
            mock.patch.object(
                PROCESS_SCOPE,
                "_validate_live_reference_context",
                side_effect=RuntimeError("reference subject disappeared"),
            ),
            mock.patch.object(
                PROCESS_SCOPE,
                "_all_records",
                side_effect=lambda: snapshots.pop(0) if snapshots else {500: guard},
            ),
            mock.patch.object(PROCESS_SCOPE, "_signal_exact", side_effect=signal_exact),
            mock.patch.object(PROCESS_SCOPE, "_assert_authority_files_unchanged"),
            mock.patch.object(
                PROCESS_SCOPE,
                "_assert_reference_authority_files_unchanged",
            ),
        ):
            value = PROCESS_SCOPE.contain_and_write(
                [authority_path],
                evidence,
                freeze_ms=100,
                term_ms=100,
                kill_ms=100,
                reference_authority_paths=[reference_path],
            )

        self.assertEqual(value["status"], "error")
        self.assertIs(value["referenceInspection"]["complete"], False)
        self.assertTrue(value["inspectionLimitations"])
        self.assertIn((301, signal.SIGSTOP), signals)
        self.assertIn((301, signal.SIGTERM), signals)
        self.assertNotIn(500, {pid for pid, _signum in signals})

    def test_setsid_descendant_is_foreign_and_never_owned(self) -> None:
        leader = record(200, ppid=150, sid=200)
        escaped = record(302, ppid=200, sid=302)
        with mock.patch.object(
            PROCESS_SCOPE,
            "_all_records",
            return_value={200: leader, 302: escaped},
        ):
            owned, foreign, _exempt = PROCESS_SCOPE._classify([self.authority()])

        self.assertNotIn(302, owned)
        self.assertIn("authorizedLeaderDescendantChangedSession", foreign[302][1])

    def test_foreign_reasons_survive_reparenting_after_leader_exit(self) -> None:
        candidate = record(302, ppid=200, sid=302)
        foreign = {
            302: (
                candidate,
                ["authorizedLeaderDescendantChangedSession", "marker"],
            )
        }
        reparented = record(302, ppid=1, sid=302)
        PROCESS_SCOPE._merge_foreign(foreign, {302: (reparented, ["marker"])})

        self.assertEqual(
            foreign[302][1],
            ["authorizedLeaderDescendantChangedSession", "marker"],
        )

    def test_environment_references_cover_home_gradle_kotlin_and_jvm_values(
        self,
    ) -> None:
        environment = {
            "GRADLE_USER_HOME": str(self.gradle),
            "HOME": str(self.home),
            "KOTLIN_RUN": str(self.kotlin_daemon),
            "JAVA_TOOL_OPTIONS": f"-Dkotlin.project.persistent.dir={self.kotlin_project}",
        }
        candidate = record(303, sid=303, environment=environment)
        reasons = PROCESS_SCOPE._reference_reasons(
            candidate,
            self.roots,
            {str(self.sandbox)},
        )

        self.assertIn("env:GRADLE_USER_HOME:gradleUserHome", reasons)
        self.assertIn("env:HOME:home", reasons)
        self.assertIn("env:KOTLIN_RUN:kotlinDaemonRunFilesDir", reasons)
        self.assertIn(
            "env:JAVA_TOOL_OPTIONS:kotlinProjectPersistentDir",
            reasons,
        )

    def test_cwd_root_and_open_vnode_references_are_detected(self) -> None:
        candidate = record(
            304,
            sid=304,
            cwd=str(self.sandbox / "work"),
            root=str(self.home),
            open_paths=(str(self.gradle / "caches"),),
        )
        reasons = PROCESS_SCOPE._reference_reasons(
            candidate,
            self.roots,
            {str(self.sandbox)},
        )

        self.assertIn("cwd:sandboxRunTemp", reasons)
        self.assertIn("root:home", reasons)
        self.assertIn("openFd:gradleUserHome", reasons)

    def test_different_uid_reference_is_foreign(self) -> None:
        candidate = record(
            305,
            sid=305,
            uid=os.getuid() + 1,
            argv=("/bin/tool", str(self.gradle)),
        )
        with mock.patch.object(
            PROCESS_SCOPE,
            "_all_records",
            return_value={305: candidate},
        ):
            owned, foreign, _exempt = PROCESS_SCOPE._classify([self.authority()])

        self.assertNotIn(305, owned)
        self.assertIn("argv:gradleUserHome", foreign[305][1])

    def test_different_uid_matching_authorized_sid_is_never_owned(self) -> None:
        candidate = record(
            309,
            sid=200,
            uid=os.getuid() + 1,
            environment={PROCESS_SCOPE.MARKER_NAME: LAUNCH_A},
        )
        with mock.patch.object(
            PROCESS_SCOPE,
            "_all_records",
            return_value={309: candidate},
        ):
            owned, foreign, _exempt = PROCESS_SCOPE._classify([self.authority()])

        self.assertNotIn(309, owned)
        self.assertIn(309, foreign)

    def test_unscoped_owner_descendant_reference_is_foreign(self) -> None:
        owner = record(100, ppid=1, sid=100)
        unscoped_child = record(
            314,
            ppid=100,
            sid=314,
            open_paths=(str(self.gradle / "daemon.lock"),),
        )
        helper = record(os.getpid(), ppid=100, sid=os.getsid(0))
        with mock.patch.object(
            PROCESS_SCOPE,
            "_all_records",
            return_value={100: owner, 314: unscoped_child, os.getpid(): helper},
        ):
            owned, foreign, exempt = PROCESS_SCOPE._classify([self.authority()])

        self.assertNotIn(314, owned)
        self.assertIn(314, foreign)
        self.assertIn("openFd:gradleUserHome", foreign[314][1])
        self.assertNotIn(314, exempt)

    def test_reference_authority_seals_exact_subject_program_and_readiness(
        self,
    ) -> None:
        value, authority_path, records = self.create_reference_authority_fixture()

        self.assertEqual(value["version"], 1)
        self.assertEqual(value["kind"], "source-guard-reference-exemption")
        self.assertEqual(value["subject"], records[500].identity.as_dict())
        self.assertEqual(value["argv"], list(records[500].argv))
        self.assertEqual(value["allowedRootKeys"], ["home", "isolatedUserRoot"])
        self.assertEqual(stat.S_IMODE(authority_path.stat().st_mode), 0o600)
        self.assertEqual(json.loads(authority_path.read_text()), value)

    def test_reference_authority_rejects_program_argv_mismatch(self) -> None:
        executable = os.path.realpath(sys.executable)
        with self.assertRaisesRegex(ValueError, "program argv"):
            self.create_reference_authority_fixture(
                argv=(executable, "-I", "-S", "-B", str(self.wrapper)),
            )

    def test_reference_authority_rejects_readiness_identity_mismatch(self) -> None:
        with self.assertRaisesRegex(ValueError, "readiness identity"):
            self.create_reference_authority_fixture(readiness_pid=501)

    def test_reference_authority_rejects_program_changed_after_sealing(self) -> None:
        value, authority_path, _records = self.create_reference_authority_fixture()
        Path(value["program"]["path"]).write_text(
            "raise SystemExit(7)\n",
            encoding="utf-8",
        )

        with self.assertRaisesRegex(ValueError, "program changed"):
            PROCESS_SCOPE._load_reference_authority(authority_path)

    def test_reference_authority_rejects_readiness_changed_after_sealing(self) -> None:
        value, authority_path, _records = self.create_reference_authority_fixture()
        Path(value["readiness"]["path"]).write_text(
            json.dumps({"version": 3, "pid": 500, "nonce": LAUNCH_B, "extra": True}),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(ValueError, "readiness changed"):
            PROCESS_SCOPE._load_reference_authority(authority_path)

    def test_reference_authority_requires_absent_stop_path(self) -> None:
        (self.root / "source-guard.stop").write_text("stop\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "stop path already exists"):
            self.create_reference_authority_fixture()

    def test_reference_authority_requires_absent_result_path(self) -> None:
        (self.root / "source-guard.result.json").write_text("{}\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "result path already exists"):
            self.create_reference_authority_fixture()

    def test_exact_reference_subject_is_exempt_but_never_owned(self) -> None:
        _value, authority_path, records = self.create_reference_authority_fixture()
        reference, _digest = PROCESS_SCOPE._load_reference_authority(authority_path)
        with mock.patch.object(PROCESS_SCOPE, "_all_records", return_value=records):
            owned, foreign, exempt = PROCESS_SCOPE._classify(
                [self.authority()],
                [reference],
            )

        self.assertNotIn(500, owned)
        self.assertNotIn(500, foreign)
        self.assertIn(500, exempt)

    def test_reference_subject_is_never_selected_for_a_signal(self) -> None:
        _value, authority_path, records = self.create_reference_authority_fixture()
        reference, _digest = PROCESS_SCOPE._load_reference_authority(authority_path)
        with (
            mock.patch.object(PROCESS_SCOPE, "_all_records", return_value=records),
            mock.patch.object(PROCESS_SCOPE, "_signal_exact") as signal_exact,
        ):
            stopped, foreign = PROCESS_SCOPE._freeze_authorized(
                [self.authority()],
                [reference],
                timeout_ms=100,
            )

        self.assertEqual(stopped, {})
        self.assertEqual(foreign, {})
        signal_exact.assert_not_called()

    def test_reference_subject_pid_reuse_is_fatal(self) -> None:
        _value, authority_path, records = self.create_reference_authority_fixture()
        reference, _digest = PROCESS_SCOPE._load_reference_authority(authority_path)
        records[500] = record(
            500,
            ppid=100,
            sid=100,
            start=51,
            argv=records[500].argv,
            environment={"HOME": str(self.home)},
        )
        with (
            mock.patch.object(PROCESS_SCOPE, "_all_records", return_value=records),
            self.assertRaisesRegex(RuntimeError, "PID was reused"),
        ):
            PROCESS_SCOPE._classify([self.authority()], [reference])

    def test_reference_subject_live_argv_change_is_fatal(self) -> None:
        _value, authority_path, records = self.create_reference_authority_fixture()
        reference, _digest = PROCESS_SCOPE._load_reference_authority(authority_path)
        records[500] = PROCESS_SCOPE.replace(
            records[500],
            argv=(*records[500].argv, "--mutated"),
        )
        with (
            mock.patch.object(PROCESS_SCOPE, "_all_records", return_value=records),
            self.assertRaisesRegex(RuntimeError, "argv changed"),
        ):
            PROCESS_SCOPE._classify([self.authority()], [reference])

    def test_reference_subject_live_stop_control_is_fatal(self) -> None:
        _value, authority_path, records = self.create_reference_authority_fixture()
        reference, _digest = PROCESS_SCOPE._load_reference_authority(authority_path)
        Path(reference["readiness"]["stopPath"]).write_text("stop\n", encoding="utf-8")
        with (
            mock.patch.object(PROCESS_SCOPE, "_all_records", return_value=records),
            self.assertRaisesRegex(RuntimeError, "stop control appeared"),
        ):
            PROCESS_SCOPE._classify([self.authority()], [reference])

    def test_reference_subject_live_terminal_result_is_fatal(self) -> None:
        _value, authority_path, records = self.create_reference_authority_fixture()
        reference, _digest = PROCESS_SCOPE._load_reference_authority(authority_path)
        Path(reference["readiness"]["resultPath"]).write_text("{}\n", encoding="utf-8")
        with (
            mock.patch.object(PROCESS_SCOPE, "_all_records", return_value=records),
            self.assertRaisesRegex(RuntimeError, "terminal result appeared"),
        ):
            PROCESS_SCOPE._classify([self.authority()], [reference])

    def test_reference_authority_root_mismatch_is_fatal(self) -> None:
        _value, authority_path, records = self.create_reference_authority_fixture()
        reference, _digest = PROCESS_SCOPE._load_reference_authority(authority_path)
        reference["roots"] = dict(reference["roots"])
        reference["roots"]["gradleUserHome"] = str(self.cwd)
        with (
            mock.patch.object(PROCESS_SCOPE, "_all_records", return_value=records),
            self.assertRaisesRegex(RuntimeError, "ownerRoot or roots mismatch"),
        ):
            PROCESS_SCOPE._classify([self.authority()], [reference])

    def test_reference_exemption_does_not_hide_an_unscoped_sibling(self) -> None:
        _value, authority_path, records = self.create_reference_authority_fixture()
        reference, _digest = PROCESS_SCOPE._load_reference_authority(authority_path)
        records[501] = record(
            501,
            ppid=100,
            sid=501,
            open_paths=(str(self.gradle / "daemon.lock"),),
        )
        with mock.patch.object(PROCESS_SCOPE, "_all_records", return_value=records):
            owned, foreign, exempt = PROCESS_SCOPE._classify(
                [self.authority()],
                [reference],
            )

        self.assertNotIn(501, owned)
        self.assertIn("openFd:gradleUserHome", foreign[501][1])
        self.assertNotIn(501, exempt)

    def test_signal_revalidates_same_kernel_identity_before_and_after(self) -> None:
        candidate = record(306, sid=200)
        with (
            mock.patch.object(
                PROCESS_SCOPE,
                "_record_for_pid",
                return_value=candidate,
            ) as inspect,
            mock.patch.object(
                PROCESS_SCOPE,
                "_bsd_identity",
                return_value=(candidate.identity, candidate.state),
            ) as post_inspect,
            mock.patch.object(os, "kill") as kill,
        ):
            self.assertTrue(PROCESS_SCOPE._signal_exact(candidate, signal.SIGTERM))

        inspect.assert_called_once_with(306, candidate.identity)
        post_inspect.assert_called_once_with(306)
        kill.assert_called_once_with(306, signal.SIGTERM)

    def test_reparented_same_immutable_identity_remains_signal_authorized(self) -> None:
        candidate = record(310, ppid=150, sid=200, start=20)
        reparented = record(310, ppid=1, sid=200, start=20)
        with (
            mock.patch.object(
                PROCESS_SCOPE,
                "_record_for_pid",
                side_effect=[reparented, reparented],
            ),
            mock.patch.object(os, "kill") as kill,
        ):
            self.assertTrue(PROCESS_SCOPE._signal_exact(candidate, signal.SIGTERM))
        kill.assert_called_once_with(310, signal.SIGTERM)

    def test_pid_identity_reuse_is_not_signaled(self) -> None:
        candidate = record(307, sid=200, start=10)
        reused = record(307, sid=200, start=11)
        with (
            mock.patch.object(PROCESS_SCOPE, "_record_for_pid", return_value=reused),
            mock.patch.object(os, "kill") as kill,
        ):
            self.assertFalse(PROCESS_SCOPE._signal_exact(candidate, signal.SIGKILL))
        kill.assert_not_called()

    def test_pid_identity_reuse_after_signal_is_fatal_not_disappearance(self) -> None:
        candidate = record(321, sid=200, start=10)
        reused_identity = identity(321, sid=200, start=11)
        with (
            mock.patch.object(
                PROCESS_SCOPE,
                "_record_for_pid",
                side_effect=[candidate, None],
            ),
            mock.patch.object(
                PROCESS_SCOPE,
                "_bsd_identity",
                return_value=(reused_identity, 3),
            ),
            mock.patch.object(os, "kill") as kill,
            self.assertRaisesRegex(RuntimeError, "identity changed across signal"),
        ):
            PROCESS_SCOPE._signal_exact(candidate, signal.SIGTERM)

        kill.assert_called_once_with(321, signal.SIGTERM)

    def test_authorized_session_inspection_failure_is_fatal_before_signal(
        self,
    ) -> None:
        candidate = record(312, sid=200)
        with (
            mock.patch.object(
                PROCESS_SCOPE,
                "_record_for_pid",
                side_effect=RuntimeError("inspection denied"),
            ),
            mock.patch.object(os, "kill") as kill,
            self.assertRaisesRegex(RuntimeError, "inspection denied"),
        ):
            PROCESS_SCOPE._signal_exact(candidate, signal.SIGKILL)
        kill.assert_not_called()

    def test_eperm_and_eio_evidence_reads_fail_closed_for_same_live_identity(
        self,
    ) -> None:
        process_identity = identity(308, sid=200)
        for error_number in (errno.EPERM, errno.EIO):
            with (
                self.subTest(error=error_number),
                mock.patch.object(
                    PROCESS_SCOPE,
                    "_bsd_identity",
                    side_effect=[(process_identity, 3), (process_identity, 3)],
                ),
                mock.patch.object(
                    PROCESS_SCOPE,
                    "_kernel_snapshot",
                    side_effect=ProcessLookupError(error_number, "denied"),
                ),
                self.assertRaisesRegex(RuntimeError, "could not inspect live process"),
            ):
                PROCESS_SCOPE._record_for_pid(308)

    def test_unrelated_vnode_eperm_is_explicit_limitation_not_inventory_abort(
        self,
    ) -> None:
        basic = record(311, sid=311)
        with (
            mock.patch.object(
                PROCESS_SCOPE,
                "_identity_inventory",
                return_value={311: basic},
            ),
            mock.patch.object(
                PROCESS_SCOPE,
                "_kernel_snapshot",
                return_value=("/bin/tool", ("/bin/tool",), {}),
            ),
            mock.patch.object(
                PROCESS_SCOPE,
                "_kernel_vnode_paths",
                side_effect=ProcessLookupError(errno.EPERM, "denied"),
            ),
            mock.patch.object(
                PROCESS_SCOPE,
                "_confirmed_gone_or_changed",
                return_value=False,
            ),
        ):
            records = PROCESS_SCOPE._all_records()

        self.assertIn(311, records)
        self.assertRegex(records[311].inspection_errors[0], "vnodeEvidence")

    def test_eperm_vnode_query_uses_complete_sealed_lsof_fallback(self) -> None:
        process_identity = identity(313, sid=313)
        with (
            mock.patch.object(
                PROCESS_SCOPE,
                "_kernel_fd_inventory",
                return_value=((3, PROCESS_SCOPE.PROC_FDTYPE_VNODE),),
            ),
            mock.patch.object(
                PROCESS_SCOPE,
                "_kernel_vnode_paths",
                side_effect=ProcessLookupError(errno.EPERM, "denied"),
            ),
            mock.patch.object(
                PROCESS_SCOPE,
                "_lsof_vnode_paths",
                return_value=("/cwd", "/", ("/cwd", "/tmp/open")),
            ) as fallback,
        ):
            cwd, root, paths, method = PROCESS_SCOPE._vnode_paths_complete(
                313, process_identity
            )

        fallback.assert_called_once_with(313, process_identity)
        self.assertEqual((cwd, root), ("/cwd", "/"))
        self.assertEqual(paths, ("/cwd", "/tmp/open"))
        self.assertEqual(method, "sealed-lsof")

    def test_lsof_fallback_binds_identity_fd_inventory_command_and_environment(
        self,
    ) -> None:
        process_identity = identity(314, sid=314)
        output = b"p314\0ctool\0\nfcwd\0tDIR\0n/cwd\0\nfrtd\0tDIR\0n/\0\nf3u\0tREG\0n/tmp/open\0"
        completed = subprocess.CompletedProcess([], 0, stdout=output, stderr=b"")
        with (
            mock.patch.object(
                PROCESS_SCOPE,
                "_bsd_identity",
                side_effect=[(process_identity, 3), (process_identity, 3)],
            ),
            mock.patch.object(
                PROCESS_SCOPE,
                "_kernel_fd_inventory",
                side_effect=[
                    ((3, PROCESS_SCOPE.PROC_FDTYPE_VNODE),),
                    ((3, PROCESS_SCOPE.PROC_FDTYPE_VNODE),),
                ],
            ),
            mock.patch.object(PROCESS_SCOPE, "_assert_lsof_identity") as sealed,
            mock.patch.object(subprocess, "run", return_value=completed) as run,
        ):
            value = PROCESS_SCOPE._lsof_vnode_paths(314, process_identity)

        self.assertEqual(value, ("/cwd", "/", ("/cwd", "/", "/tmp/open")))
        self.assertEqual(sealed.call_count, 2)
        run.assert_called_once_with(
            [
                "/usr/sbin/lsof",
                "-nP",
                "-a",
                "-p",
                "314",
                "-F0pcfnt",
            ],
            check=False,
            capture_output=True,
            env={"LC_ALL": "C", "PATH": "/usr/bin:/bin"},
            timeout=5,
        )

    def test_lsof_fallback_retries_bounded_fd_churn(self) -> None:
        process_identity = identity(315, sid=315)
        first = subprocess.CompletedProcess(
            [],
            0,
            stdout=b"p315\0ctool\0\nf3u\0tREG\0n/tmp/a\0",
            stderr=b"",
        )
        second = subprocess.CompletedProcess(
            [],
            0,
            stdout=b"p315\0ctool\0\nf4u\0tREG\0n/tmp/b\0",
            stderr=b"",
        )
        with (
            mock.patch.object(
                PROCESS_SCOPE,
                "_bsd_identity",
                side_effect=[(process_identity, 3)] * 4,
            ),
            mock.patch.object(
                PROCESS_SCOPE,
                "_kernel_fd_inventory",
                side_effect=[((3, 1),), ((4, 1),), ((4, 1),), ((4, 1),)],
            ),
            mock.patch.object(PROCESS_SCOPE, "_assert_lsof_identity"),
            mock.patch.object(subprocess, "run", side_effect=[first, second]) as run,
            mock.patch.object(PROCESS_SCOPE.time, "sleep"),
        ):
            value = PROCESS_SCOPE._lsof_vnode_paths(315, process_identity)

        self.assertEqual(value[2], ("/tmp/b",))
        self.assertEqual(run.call_count, 2)

    def test_lsof_fallback_fails_after_bounded_churn_retries(self) -> None:
        process_identity = identity(318, sid=318)
        incomplete = subprocess.CompletedProcess(
            [],
            0,
            stdout=b"p318\0ctool\0\nf4u\0tREG\0n/tmp/b\0",
            stderr=b"",
        )
        with (
            mock.patch.object(PROCESS_SCOPE, "LSOF_RETRIES", 2),
            mock.patch.object(
                PROCESS_SCOPE,
                "_bsd_identity",
                return_value=(process_identity, 3),
            ),
            mock.patch.object(
                PROCESS_SCOPE,
                "_kernel_fd_inventory",
                return_value=((3, 1),),
            ),
            mock.patch.object(PROCESS_SCOPE, "_assert_lsof_identity"),
            mock.patch.object(subprocess, "run", return_value=incomplete) as run,
            mock.patch.object(PROCESS_SCOPE.time, "sleep"),
            self.assertRaisesRegex(RuntimeError, "stable snapshot"),
        ):
            PROCESS_SCOPE._lsof_vnode_paths(318, process_identity)

        self.assertEqual(run.call_count, 2)

    def test_lsof_rejects_stderr_even_with_zero_exit(self) -> None:
        process_identity = identity(319, sid=319)
        completed = subprocess.CompletedProcess(
            [],
            0,
            stdout=b"p319\0ctool\0\nf3u\0tREG\0n/tmp/a\0",
            stderr=b"unexpected warning\n",
        )
        with (
            mock.patch.object(
                PROCESS_SCOPE,
                "_bsd_identity",
                return_value=(process_identity, 3),
            ),
            mock.patch.object(
                PROCESS_SCOPE,
                "_kernel_fd_inventory",
                return_value=((3, PROCESS_SCOPE.PROC_FDTYPE_VNODE),),
            ),
            mock.patch.object(PROCESS_SCOPE, "_assert_lsof_identity"),
            mock.patch.object(subprocess, "run", return_value=completed),
            self.assertRaisesRegex(RuntimeError, "wrote stderr"),
        ):
            PROCESS_SCOPE._lsof_vnode_paths(319, process_identity)

    def test_lsof_parser_requires_exact_fd_set_and_absolute_vnode_names(self) -> None:
        with self.assertRaisesRegex(BlockingIOError, "differ"):
            PROCESS_SCOPE._parse_lsof_output(
                b"p320\0ctool\0\nf3u\0tREG\0n/tmp/a\0\nf4u\0tREG\0n/tmp/b\0",
                320,
                {3: PROCESS_SCOPE.PROC_FDTYPE_VNODE},
            )
        with self.assertRaisesRegex(RuntimeError, "absolute vnode"):
            PROCESS_SCOPE._parse_lsof_output(
                b"p320\0ctool\0\nf3u\0tREG\0nrelative-name\0",
                320,
                {3: PROCESS_SCOPE.PROC_FDTYPE_VNODE},
            )

    def test_evidence_reports_sealed_lsof_fallback_and_completeness(self) -> None:
        fallback = record(317, sid=317)
        fallback = PROCESS_SCOPE.replace(
            fallback,
            vnode_evidence_method="sealed-lsof",
            vnode_evidence_complete=True,
        )
        with (
            mock.patch.object(
                PROCESS_SCOPE,
                "_freeze_authorized",
                return_value=({}, {}),
            ),
            mock.patch.object(
                PROCESS_SCOPE,
                "_classify",
                return_value=(
                    {},
                    {317: (fallback, ["cwd:home"])},
                    {},
                ),
            ),
        ):
            value = PROCESS_SCOPE._contain(
                [self.authority()],
                freeze_ms=1,
                term_ms=1,
                kill_ms=1,
            )

        inspection = value["referenceInspection"]
        self.assertTrue(inspection["complete"])
        self.assertEqual(inspection["lsof"]["path"], "/usr/sbin/lsof")
        self.assertRegex(inspection["lsof"]["sha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(inspection["lsof"]["identifier"], "com.apple.lsof")
        self.assertIs(inspection["lsof"]["codesignVerified"], True)
        self.assertRegex(inspection["lsof"]["cdhash"], r"^[0-9a-f]{40}$")
        self.assertEqual(
            inspection["lsof"]["designatedRequirement"],
            'identifier "com.apple.lsof" and anchor apple',
        )
        self.assertEqual(inspection["lsof"]["mode"], 0o755)
        self.assertEqual(inspection["lsof"]["nlink"], 1)
        self.assertEqual(inspection["fallbackProcesses"], [fallback.identity.as_dict()])

    def test_unreferenced_fallback_is_not_serialized_as_unbound_identity(self) -> None:
        fallback = PROCESS_SCOPE.replace(
            record(318, sid=1),
            vnode_evidence_method="sealed-lsof",
            vnode_evidence_complete=True,
        )
        with (
            mock.patch.object(
                PROCESS_SCOPE,
                "_freeze_authorized",
                return_value=({}, {}),
            ),
            mock.patch.object(
                PROCESS_SCOPE,
                "_classify",
                return_value=({}, {}, {318: fallback}),
            ),
        ):
            value = PROCESS_SCOPE._contain(
                [self.authority()],
                freeze_ms=1,
                term_ms=1,
                kill_ms=1,
            )

        self.assertTrue(value["referenceInspection"]["complete"])
        self.assertEqual(value["referenceInspection"]["fallbackProcesses"], [])

    def test_stopped_fallback_remains_bound_in_signal_scope_evidence(self) -> None:
        fallback = PROCESS_SCOPE.replace(
            record(319, sid=319),
            vnode_evidence_method="sealed-lsof",
            vnode_evidence_complete=True,
        )
        with (
            mock.patch.object(
                PROCESS_SCOPE,
                "_freeze_authorized",
                return_value=({319: fallback}, {}),
            ),
            mock.patch.object(PROCESS_SCOPE, "_signal_exact", return_value=False),
            mock.patch.object(
                PROCESS_SCOPE, "_wait_authorized_empty", return_value=True
            ),
            mock.patch.object(
                PROCESS_SCOPE,
                "_classify",
                return_value=({}, {}, {}),
            ),
        ):
            value = PROCESS_SCOPE._contain(
                [self.authority(leader_pid=319, sid=319)],
                freeze_ms=1,
                term_ms=1,
                kill_ms=1,
            )

        self.assertEqual(
            value["referenceInspection"]["fallbackProcesses"],
            [fallback.identity.as_dict()],
        )

    def test_reference_exempt_fallback_remains_exactly_bound(self) -> None:
        fallback = PROCESS_SCOPE.replace(
            record(321, sid=1),
            vnode_evidence_method="sealed-lsof",
            vnode_evidence_complete=True,
        )
        reference = {"exemptionId": LAUNCH_A}
        with (
            mock.patch.object(
                PROCESS_SCOPE,
                "_freeze_authorized",
                return_value=({}, {}),
            ),
            mock.patch.object(
                PROCESS_SCOPE,
                "_classify",
                return_value=({}, {}, {321: fallback}),
            ),
            mock.patch.object(
                PROCESS_SCOPE,
                "_validate_live_reference_context",
                return_value={
                    321: (reference, fallback, ["env:HOME:home"]),
                },
            ),
        ):
            value = PROCESS_SCOPE._contain(
                [self.authority()],
                [reference],
                freeze_ms=1,
                term_ms=1,
                kill_ms=1,
            )

        self.assertEqual(
            value["referenceInspection"]["fallbackProcesses"],
            [fallback.identity.as_dict()],
        )
        self.assertEqual(
            value["referenceExemptProcesses"][0]["process"]["identity"],
            fallback.identity.as_dict(),
        )

    def test_generic_exempt_inspection_error_still_fails_closed(self) -> None:
        limited = PROCESS_SCOPE.replace(
            record(320, sid=1),
            inspection_errors=("vnode inspection denied",),
            vnode_evidence_complete=False,
        )
        with (
            mock.patch.object(
                PROCESS_SCOPE,
                "_freeze_authorized",
                return_value=({}, {}),
            ),
            mock.patch.object(
                PROCESS_SCOPE,
                "_classify",
                return_value=({}, {}, {320: limited}),
            ),
        ):
            value = PROCESS_SCOPE._contain(
                [self.authority()],
                freeze_ms=1,
                term_ms=1,
                kill_ms=1,
            )

        self.assertFalse(value["referenceInspection"]["complete"])
        self.assertEqual(
            value["inspectionLimitations"],
            [
                {
                    "identity": limited.identity.as_dict(),
                    "errors": ["vnode inspection denied"],
                }
            ],
        )

    def test_create_launch_authority_writes_canonical_mode_0600_schema_v2(self) -> None:
        owner_pid = 100
        supervisor_pid = os.getpid()
        leader_pid = 400
        owner = record(owner_pid, sid=100)
        supervisor = record(supervisor_pid, ppid=owner_pid, sid=100)
        leader = PROCESS_SCOPE.ProcessRecord(
            identity=identity(
                leader_pid,
                ppid=supervisor_pid,
                pgid=leader_pid,
                sid=leader_pid,
            ),
            executable=os.path.realpath("/bin/zsh"),
            argv=(os.path.realpath("/bin/zsh"), "-f", str(self.wrapper)),
            environment={},
            state=3,
        )
        authority_path = self.root / "created-authority.json"
        records = {
            owner_pid: owner,
            supervisor_pid: supervisor,
            leader_pid: leader,
        }
        with (
            mock.patch.object(
                PROCESS_SCOPE,
                "_identity_inventory",
                return_value=records,
            ),
            mock.patch.object(
                PROCESS_SCOPE,
                "_record_for_pid",
                side_effect=lambda pid: records.get(pid),
            ),
        ):
            value = PROCESS_SCOPE.create_launch_authority(
                child_pid=leader_pid,
                owner_root_pid=owner_pid,
                launch_id=LAUNCH_A,
                wrapper_path=self.wrapper,
                wrapper_sha256=hashlib.sha256(self.wrapper.read_bytes()).hexdigest(),
                command_cwd=self.cwd,
                roots=self.roots,
                authority_path=authority_path,
            )

        self.assertEqual(value["version"], 2)
        self.assertEqual(value["leader"]["sid"], leader_pid)
        self.assertEqual(stat.S_IMODE(authority_path.stat().st_mode), 0o600)
        self.assertEqual(json.loads(authority_path.read_text()), value)

    def test_authority_schema_tamper_and_root_topology_are_rejected(self) -> None:
        unexpected = self.authority()
        unexpected["extra"] = True
        unexpected_path = self.write_authority("unexpected.json", unexpected)
        with self.assertRaisesRegex(ValueError, "schema"):
            PROCESS_SCOPE._load_authority(unexpected_path)

        bad_roots = self.authority()
        bad_roots["roots"]["kotlinDaemonRunFilesDir"] = str(self.gradle)
        bad_path = self.write_authority("bad-root.json", bad_roots)
        with self.assertRaisesRegex(ValueError, "direct sandboxRunTemp child"):
            PROCESS_SCOPE._load_authority(bad_path)

    def test_authority_wrapper_digest_tamper_is_rejected(self) -> None:
        path = self.write_authority("wrapper-authority.json")
        self.wrapper.write_text("#!/bin/zsh\nexit 7\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "wrapper changed"):
            PROCESS_SCOPE._load_authority(path)

    def test_live_authority_context_defers_leader_pid_reuse_to_classification(
        self,
    ) -> None:
        current_pid = os.getpid()
        authority = self.authority()
        authority["ownerRoot"] = identity(100, ppid=1, sid=100).as_dict()
        authority["supervisor"] = identity(
            150,
            ppid=100,
            sid=100,
        ).as_dict()
        authority["leader"] = identity(
            200,
            ppid=150,
            pgid=200,
            sid=200,
            start=10,
        ).as_dict()
        records = {
            100: record(100, sid=100),
            current_pid: record(current_pid, ppid=100, sid=100),
            200: record(200, ppid=150, sid=200, start=11),
        }
        with mock.patch.object(
            PROCESS_SCOPE,
            "_identity_inventory",
            return_value=records,
        ):
            PROCESS_SCOPE._validate_live_authority_context([authority])

    def test_live_authority_remains_valid_after_supervisor_exit(self) -> None:
        current_pid = os.getpid()
        authority = self.authority()
        records = {
            100: record(100, sid=100),
            current_pid: record(current_pid, ppid=100, sid=100),
        }
        with mock.patch.object(
            PROCESS_SCOPE,
            "_identity_inventory",
            return_value=records,
        ):
            PROCESS_SCOPE._validate_live_authority_context([authority])

    def test_contain_and_write_supports_multiple_authorities_and_hashes_each(
        self,
    ) -> None:
        first_value = self.authority(leader_pid=200, sid=200)
        second_value = self.authority(leader_pid=201, sid=201)
        second_value["launchId"] = LAUNCH_B
        first = self.write_authority("first.json", first_value)
        second = self.write_authority("second.json", second_value)
        evidence = self.root / "evidence.json"
        contained = {
            "stoppedProcesses": [],
            "termSentProcesses": [],
            "killSentProcesses": [],
            "remainingOwnedProcesses": [],
            "foreignProcesses": [],
        }
        with (
            mock.patch.object(
                PROCESS_SCOPE,
                "_validate_live_authority_context",
            ),
            mock.patch.object(PROCESS_SCOPE, "_contain", return_value=contained),
        ):
            value = PROCESS_SCOPE.contain_and_write(
                [first, second],
                evidence,
                freeze_ms=1,
                term_ms=1,
                kill_ms=1,
            )

        self.assertEqual(value["status"], "quiescent")
        self.assertEqual(value["authorizedSessions"], [200, 201])
        self.assertEqual(len(value["authorities"]), 2)
        for item in value["authorities"]:
            self.assertRegex(item["sha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(stat.S_IMODE(evidence.stat().st_mode), 0o600)

    def test_contain_evidence_v3_seals_reference_authority_and_exempt_subject(
        self,
    ) -> None:
        _reference_value, reference_path, records = (
            self.create_reference_authority_fixture()
        )
        launch_path = self.write_authority("launch.json")
        evidence = self.root / "reference-evidence.json"
        exempt_process = records[500].as_dict()
        contained = {
            "stoppedProcesses": [],
            "termSentProcesses": [],
            "killSentProcesses": [],
            "remainingOwnedProcesses": [],
            "foreignProcesses": [],
            "referenceExemptProcesses": [
                {
                    "exemptionId": LAUNCH_A,
                    "process": exempt_process,
                    "reasons": ["env:HOME:home"],
                }
            ],
            "inspectionLimitations": [],
        }
        with (
            mock.patch.object(PROCESS_SCOPE, "_validate_live_authority_context"),
            mock.patch.object(PROCESS_SCOPE, "_contain", return_value=contained),
        ):
            value = PROCESS_SCOPE.contain_and_write(
                [launch_path],
                evidence,
                freeze_ms=1,
                term_ms=1,
                kill_ms=1,
                reference_authority_paths=[reference_path],
            )

        self.assertEqual(value["version"], 3)
        self.assertEqual(value["status"], "quiescent")
        self.assertEqual(
            value["referenceExemptProcesses"], contained["referenceExemptProcesses"]
        )
        self.assertEqual(len(value["referenceAuthorities"]), 1)
        self.assertEqual(value["referenceAuthorities"][0]["exemptionId"], LAUNCH_A)
        self.assertRegex(value["referenceAuthorities"][0]["sha256"], r"^[0-9a-f]{64}$")

    def test_authority_changed_during_containment_is_rejected(self) -> None:
        authority = self.write_authority("racing-authority.json")
        evidence = self.root / "racing-evidence.json"

        def tamper(_authorities, _reference_authorities, **_timeouts):
            authority.write_text("{}", encoding="utf-8")
            return {
                "stoppedProcesses": [],
                "termSentProcesses": [],
                "killSentProcesses": [],
                "remainingOwnedProcesses": [],
                "foreignProcesses": [],
                "inspectionLimitations": [],
            }

        with (
            mock.patch.object(
                PROCESS_SCOPE,
                "_validate_live_authority_context",
            ),
            mock.patch.object(PROCESS_SCOPE, "_contain", side_effect=tamper),
        ):
            value = PROCESS_SCOPE.contain_and_write(
                [authority],
                evidence,
                freeze_ms=1,
                term_ms=1,
                kill_ms=1,
            )

        self.assertEqual(value["status"], "error")
        self.assertRegex(value["error"], "authority schema")

    def test_contain_error_writes_fail_closed_v3_evidence(self) -> None:
        evidence = self.root / "error-evidence.json"
        value = PROCESS_SCOPE.contain_and_write(
            [self.root / "missing.json"],
            evidence,
            freeze_ms=1,
            term_ms=1,
            kill_ms=1,
        )

        self.assertEqual(value["version"], 3)
        self.assertEqual(value["status"], "error")
        self.assertIn("FileNotFoundError", value["error"])
        self.assertEqual(json.loads(evidence.read_text()), value)

    def test_incomplete_reference_inspection_forces_error_status(self) -> None:
        authority = self.write_authority("limited-authority.json")
        evidence = self.root / "limited-evidence.json"
        contained = {
            "stoppedProcesses": [],
            "termSentProcesses": [],
            "killSentProcesses": [],
            "remainingOwnedProcesses": [],
            "foreignProcesses": [],
            "inspectionLimitations": [
                {"identity": identity(316).as_dict(), "errors": ["denied"]}
            ],
        }
        with (
            mock.patch.object(
                PROCESS_SCOPE,
                "_validate_live_authority_context",
            ),
            mock.patch.object(PROCESS_SCOPE, "_contain", return_value=contained),
        ):
            value = PROCESS_SCOPE.contain_and_write(
                [authority],
                evidence,
                freeze_ms=1,
                term_ms=1,
                kill_ms=1,
            )

        self.assertEqual(value["status"], "error")
        self.assertEqual(value["error"], "process reference inspection was incomplete")

    def test_cli_requires_repeatable_authority_not_marker_scope(self) -> None:
        args = PROCESS_SCOPE.parse_args(
            [
                "contain",
                "--authority",
                str(self.root / "one.json"),
                "--authority",
                str(self.root / "two.json"),
                "--evidence",
                str(self.root / "evidence.json"),
            ]
        )
        self.assertEqual(len(args.authority), 2)
        self.assertFalse(hasattr(args, "scope"))

    def test_cli_accepts_repeatable_reference_authority(self) -> None:
        args = PROCESS_SCOPE.parse_args(
            [
                "contain",
                "--authority",
                str(self.root / "launch.json"),
                "--reference-authority",
                str(self.root / "guard-a.json"),
                "--reference-authority",
                str(self.root / "guard-b.json"),
                "--evidence",
                str(self.root / "evidence.json"),
            ]
        )

        self.assertEqual(
            args.reference_authority,
            [self.root / "guard-a.json", self.root / "guard-b.json"],
        )

    def test_launch_id_is_exactly_32_lowercase_hex_characters(self) -> None:
        self.assertIsNotNone(PROCESS_SCOPE.LAUNCH_ID_PATTERN.fullmatch("a" * 32))
        for invalid in ("a" * 31, "a" * 33, "A" * 32, "launch-12345678"):
            with self.subTest(invalid=invalid):
                self.assertIsNone(PROCESS_SCOPE.LAUNCH_ID_PATTERN.fullmatch(invalid))


if __name__ == "__main__":
    unittest.main()
