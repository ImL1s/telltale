import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


HERE = pathlib.Path(__file__).resolve().parent
SCOPED_COMMAND_PATH = HERE / "scoped_command.py"
SPEC = importlib.util.spec_from_file_location(
    "telemetry_memory_rig_scoped_command",
    SCOPED_COMMAND_PATH,
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load scoped command: {SCOPED_COMMAND_PATH}")
scoped_command = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = scoped_command
SPEC.loader.exec_module(scoped_command)


def _sandbox_environment(root):
    isolated = root / "isolated"
    run_temp = isolated / "run"
    paths = {
        "PROFILE": HERE / "android_sdk_write_deny.sb",
        "APP_ROOT": root / "app",
        "FLUTTER_ROOT": root / "flutter",
        "PUB_CACHE": root / "pub",
        "GRADLE_HOME": root / "gradle",
        "ISOLATED_ROOT": isolated,
        "RUN_TEMP": run_temp,
        "ANDROID_SDK_ROOT": root / "sdk",
    }
    for path in paths.values():
        if path == paths["PROFILE"]:
            continue
        path.mkdir(parents=True, exist_ok=True)
    for path in (
        isolated / "home",
        run_temp / "kotlin-project-persistent",
        run_temp / "kotlin-daemon",
    ):
        path.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment["HOME"] = str(isolated / "home")
    for name, path in paths.items():
        environment[f"TELLTALE_GATE_C_SANDBOX_{name}"] = str(path.resolve())
    return environment, paths


def _environment_evidence(environment, launch_id):
    allowed_names = sorted(
        scoped_command.CHILD_ENVIRONMENT_ALLOWED_NAMES
        | scoped_command.CHILD_ENVIRONMENT_RUNTIME_NAMES
    )
    actual_names = sorted(environment)
    return {
        "schema": scoped_command.CHILD_ENVIRONMENT_SCHEMA,
        "version": scoped_command.CHILD_ENVIRONMENT_VERSION,
        "launchId": launch_id,
        "allowedNames": allowed_names,
        "allowedNamesSha256": scoped_command._canonical_json_sha256(allowed_names),
        "actualNames": actual_names,
        "actualNamesSha256": scoped_command._canonical_json_sha256(actual_names),
        "actualNamesObservationPoint": "cooperative-sealed-wrapper-pre-release-barrier-v1",
        "producerPlannedEnvironmentValuesSha256": scoped_command._canonical_json_sha256(
            environment
        ),
        "plannedNamesMatchBarrier": True,
        "valuesObserved": False,
        "postBarrierAddedNames": [
            "FLUTTER_ALREADY_LOCKED",
            "JAVA_TOOL_OPTIONS",
            "TMPDIR",
        ],
        "credentialNamesAssertedAbsent": sorted(
            scoped_command.CREDENTIAL_ABSENCE_ASSERTION_NAMES
        ),
        "forbiddenCredentialNamesPresent": [],
    }


def _observe_popen_environment(process_scope, record=None):
    def observe(_pid):
        value = record or SimpleNamespace()
        value.environment = dict(
            scoped_command.subprocess.Popen.call_args.kwargs["env"]
        )
        return value

    process_scope._record_for_pid.side_effect = observe


class ScopedCommandContractTest(unittest.TestCase):
    def test_ready_environment_report_requires_exact_bounded_framing(self):
        names = ["HOME", "PATH"]
        launch_id = "1" * 32
        valid = (
            f"{scoped_command.CHILD_ENVIRONMENT_READY_HEADER}\n"
            f"launchId={launch_id}\nHOME\nPATH\n.\n"
        ).encode("ascii")
        for payload, valid_payload in (
            (valid, True),
            (valid.replace(launch_id.encode("ascii"), b"2" * 32), False),
            (valid.replace(b".\n", b"SECRET\n.\n"), False),
            (valid.replace(b"PATH\n", b""), False),
            (valid + b"extra\n", False),
        ):
            read_descriptor, write_descriptor = os.pipe()
            try:
                os.write(write_descriptor, payload)
                os.close(write_descriptor)
                write_descriptor = -1
                if valid_payload:
                    scoped_command._read_ready(read_descriptor, 1000, launch_id, names)
                else:
                    with self.assertRaisesRegex(RuntimeError, "report is invalid"):
                        scoped_command._read_ready(
                            read_descriptor, 1000, launch_id, names
                        )
            finally:
                os.close(read_descriptor)
                if write_descriptor >= 0:
                    os.close(write_descriptor)

    def test_waitid_observes_exit_and_signal_without_reaping_then_reaps_once(self):
        child = mock.Mock(pid=321)
        child.wait.side_effect = [7, -signal.SIGTERM]
        exited = SimpleNamespace(
            si_pid=321,
            si_code=os.CLD_EXITED,
            si_status=7,
        )
        killed = SimpleNamespace(
            si_pid=321,
            si_code=os.CLD_KILLED,
            si_status=signal.SIGTERM,
        )
        with mock.patch.object(
            scoped_command.os,
            "waitid",
            side_effect=[exited, killed],
        ) as waitid:
            exit_status = scoped_command.observe_child_exit(child)
            child.wait.assert_not_called()
            self.assertEqual(scoped_command.reap_child(child, exit_status), 7)
            signal_status = scoped_command.observe_child_exit(child, nohang=True)
            self.assertEqual(
                scoped_command.reap_child(child, signal_status),
                -signal.SIGTERM,
            )

        self.assertEqual(
            waitid.call_args_list,
            [
                mock.call(os.P_PID, 321, os.WEXITED | os.WNOWAIT),
                mock.call(
                    os.P_PID,
                    321,
                    os.WEXITED | os.WNOWAIT | os.WNOHANG,
                ),
            ],
        )
        self.assertEqual(child.wait.call_count, 2)

    def test_containment_failure_kills_only_exact_sealed_direct_child_then_reaps(self):
        child = mock.Mock(pid=321)
        child.wait.return_value = -signal.SIGKILL
        leader = SimpleNamespace(pid=321, ppid=os.getpid())
        supervisor = SimpleNamespace(pid=os.getpid())
        current = SimpleNamespace(identity=supervisor)
        candidate = SimpleNamespace(pid=321, identity=leader)
        authority = {"leader": {}, "supervisor": {}}
        process_scope = mock.Mock()
        process_scope._identity_from_dict.side_effect = [leader, supervisor]
        process_scope._record_for_pid.side_effect = [current, candidate]
        process_scope._identity_equal.side_effect = lambda left, right: left is right
        process_scope._signal_exact.return_value = True
        with mock.patch.object(
            scoped_command,
            "observe_child_exit",
            return_value=None,
        ):
            value = scoped_command.contain_failure_reap(
                child,
                authority,
                process_scope,
                None,
            )

        self.assertEqual(value, -signal.SIGKILL)
        process_scope._signal_exact.assert_called_once_with(candidate, signal.SIGKILL)
        child.wait.assert_called_once_with(timeout=2)

    def test_containment_failure_identity_mismatch_never_signals_or_hangs(self):
        child = mock.Mock(pid=321)
        child.wait.side_effect = subprocess.TimeoutExpired("child", 0.2)
        leader = SimpleNamespace(pid=321, ppid=os.getpid())
        supervisor = SimpleNamespace(pid=os.getpid())
        authority = {"leader": {}, "supervisor": {}}
        process_scope = mock.Mock()
        process_scope._identity_from_dict.side_effect = [leader, supervisor]
        process_scope._record_for_pid.return_value = None
        with (
            mock.patch.object(
                scoped_command,
                "observe_child_exit",
                return_value=None,
            ),
            self.assertRaisesRegex(RuntimeError, "not signal-authorized"),
        ):
            scoped_command.contain_failure_reap(
                child,
                authority,
                process_scope,
                None,
            )

        process_scope._signal_exact.assert_not_called()
        child.wait.assert_called_once_with(timeout=0.2)

    def test_cli_accepts_repeatable_reference_authority(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            args = scoped_command._parse_args(
                [
                    "--authority",
                    str(root / "launch.json"),
                    "--reference-authority",
                    str(root / "guard-a.json"),
                    "--reference-authority",
                    str(root / "guard-b.json"),
                    "--scope-evidence",
                    str(root / "scope.json"),
                    "--result",
                    str(root / "result.json"),
                    "--label",
                    "probe",
                    "--cwd",
                    str(root),
                    "--owner-root-pid",
                    str(os.getppid()),
                    "--wrapper",
                    str(HERE / "android_sdk_sandbox_exec.sh"),
                    "--wrapper-sha256",
                    "a" * 64,
                    "--",
                    "/usr/bin/true",
                ]
            )

        self.assertEqual(
            args.reference_authority,
            [root / "guard-a.json", root / "guard-b.json"],
        )

    def test_roots_require_exact_owned_topology(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            environment, paths = _sandbox_environment(root)
            roots = scoped_command.roots_from_environment(environment)
            self.assertEqual(roots["home"], paths["ISOLATED_ROOT"] / "home")
            self.assertEqual(roots["sandboxRunTemp"], paths["RUN_TEMP"])
            self.assertEqual(
                set(roots),
                {
                    "gradleUserHome",
                    "isolatedUserRoot",
                    "home",
                    "sandboxRunTemp",
                    "kotlinProjectPersistentDir",
                    "kotlinDaemonRunFilesDir",
                },
            )
            environment["HOME"] = str(paths["APP_ROOT"])
            with self.assertRaisesRegex(RuntimeError, "topology"):
                scoped_command.roots_from_environment(environment)

    def test_launch_rejects_ambient_authority_before_spawning(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            environment, paths = _sandbox_environment(root)
            environment[scoped_command.LAUNCH_MARKER] = "1" * 32
            wrapper = (HERE / "android_sdk_sandbox_exec.sh").resolve()
            with (
                mock.patch.object(scoped_command.subprocess, "Popen") as popen,
                self.assertRaisesRegex(RuntimeError, "ambient"),
            ):
                scoped_command.launch_authorized_child(
                    [str(wrapper), "--", "/usr/bin/true"],
                    cwd=paths["APP_ROOT"],
                    environment=environment,
                    authority_path=root / "authority.json",
                    owner_root_pid=os.getppid(),
                    wrapper_path=wrapper,
                    wrapper_sha256=hashlib.sha256(wrapper.read_bytes()).hexdigest(),
                )
            popen.assert_not_called()

    def test_authority_is_written_before_two_pipe_release(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            environment, paths = _sandbox_environment(root)
            wrapper = (HERE / "android_sdk_sandbox_exec.sh").resolve()
            child = mock.Mock(pid=321, returncode=None)
            child.poll.return_value = None
            process_scope = mock.Mock()
            process_scope.create_launch_authority.side_effect = lambda **_kwargs: (
                events.append("authority") or {"version": 2}
            )
            _observe_popen_environment(process_scope)
            events = []
            original_write_json = scoped_command._write_json

            def write_environment_evidence(path, value, label):
                events.append("environment")
                original_write_json(path, value, label)

            def release(descriptor, value):
                self.assertEqual((descriptor, value), (11, b"G"))
                events.append("release")
                return 1

            with (
                mock.patch.object(
                    scoped_command.os, "pipe", side_effect=[(10, 11), (12, 13)]
                ),
                mock.patch.object(scoped_command.os, "close"),
                mock.patch.object(scoped_command.os, "write", side_effect=release),
                mock.patch.object(
                    scoped_command,
                    "_write_json",
                    side_effect=write_environment_evidence,
                ),
                mock.patch.object(scoped_command, "_read_ready") as read_ready,
                mock.patch.object(
                    scoped_command, "_load_process_scope", return_value=process_scope
                ),
                mock.patch.object(
                    scoped_command.subprocess, "Popen", return_value=child
                ) as popen,
            ):
                returned_child, authority = scoped_command.launch_authorized_child(
                    [str(wrapper), "--", "/usr/bin/true"],
                    cwd=paths["APP_ROOT"],
                    environment=environment,
                    authority_path=root / "authority.json",
                    owner_root_pid=os.getppid(),
                    wrapper_path=wrapper,
                    wrapper_sha256=hashlib.sha256(wrapper.read_bytes()).hexdigest(),
                )

            self.assertIs(returned_child, child)
            self.assertEqual(authority, {"version": 2})
            self.assertEqual(events, ["authority", "environment", "release"])
            child_environment = popen.call_args.kwargs["env"]
            read_ready.assert_called_once_with(
                12,
                5000,
                child_environment[scoped_command.LAUNCH_MARKER],
                sorted(child_environment),
            )
            launch = popen.call_args
            self.assertTrue(launch.kwargs["start_new_session"])
            self.assertEqual(launch.kwargs["pass_fds"], (10, 13))
            self.assertRegex(
                child_environment[scoped_command.LAUNCH_MARKER],
                r"\A[0-9a-f]{32}\Z",
            )
            self.assertEqual(child_environment[scoped_command.RELEASE_FD], "10")
            self.assertEqual(child_environment[scoped_command.READY_FD], "13")

    def test_launch_uses_fixed_allowlist_and_attests_actual_child_names(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            environment, paths = _sandbox_environment(root)
            environment.update(
                {
                    "ANDROID_HOME": str(paths["ANDROID_SDK_ROOT"]),
                    "ANDROID_SDK_ROOT": str(paths["ANDROID_SDK_ROOT"]),
                    "ANDROID_USER_HOME": str(paths["ISOLATED_ROOT"] / "android"),
                    "GRADLE_USER_HOME": str(paths["GRADLE_HOME"]),
                    "JAVA_HOME": str(root / "jdk"),
                    "LANG": "en_US.UTF-8",
                    "LC_ALL": "C",
                    "ORG_GRADLE_PROJECT_telltaleGateCRigDebug": "true",
                    "PATH": "/evil/ambient/path",
                    "PUB_CACHE": str(paths["PUB_CACHE"]),
                    "TELLTALE_GATE_C_FLUTTER_ROOT": str(paths["FLUTTER_ROOT"]),
                    "TELLTALE_GATE_C_JDK_ROOT": str(root / "jdk"),
                    "XDG_CONFIG_HOME": str(paths["ISOLATED_ROOT"] / "config"),
                    "OP_SERVICE_ACCOUNT_TOKEN": "must-not-cross",
                    "HF_TOKEN": "must-not-cross",
                    "SSH_AUTH_SOCK": "/tmp/must-not-cross.sock",
                    "ARBITRARY_SECRET": "must-not-cross",
                    "TELLTALE_GATE_C_ARBITRARY_SECRET": "must-not-cross",
                    "TMPDIR": "/tmp/ambient-must-not-cross",
                    "JAVA_TOOL_OPTIONS": "-Dsecret=must-not-cross",
                    "FLUTTER_ALREADY_LOCKED": "false",
                }
            )
            wrapper = (HERE / "android_sdk_sandbox_exec.sh").resolve()
            child = mock.Mock(pid=321, returncode=None)
            child.poll.return_value = None
            process_scope = mock.Mock()
            signal_authority = {"version": 2}
            process_scope.create_launch_authority.return_value = signal_authority
            _observe_popen_environment(process_scope)

            with (
                mock.patch.object(
                    scoped_command.os, "pipe", side_effect=[(10, 11), (12, 13)]
                ),
                mock.patch.object(scoped_command.os, "close"),
                mock.patch.object(scoped_command.os, "write", return_value=1),
                mock.patch.object(scoped_command, "_read_ready"),
                mock.patch.object(
                    scoped_command, "_load_process_scope", return_value=process_scope
                ),
                mock.patch.object(
                    scoped_command.subprocess, "Popen", return_value=child
                ) as popen,
            ):
                _, authority = scoped_command.launch_authorized_child(
                    [str(wrapper), "--", "/usr/bin/true"],
                    cwd=paths["APP_ROOT"],
                    environment=environment,
                    authority_path=root / "authority.json",
                    owner_root_pid=os.getppid(),
                    wrapper_path=wrapper,
                    wrapper_sha256=hashlib.sha256(wrapper.read_bytes()).hexdigest(),
                )

            child_environment = popen.call_args.kwargs["env"]
            self.assertEqual(
                child_environment["PATH"],
                ":".join(
                    (
                        str(root / "jdk" / "bin"),
                        str(paths["ANDROID_SDK_ROOT"] / "platform-tools"),
                        "/usr/bin",
                        "/bin",
                        "/usr/sbin",
                        "/sbin",
                    )
                ),
            )
            self.assertEqual(child_environment["LANG"], "C")
            self.assertEqual(child_environment["LC_ALL"], "C")
            self.assertEqual(child_environment["PWD"], str(paths["APP_ROOT"]))
            for name in (
                "HOME",
                "XDG_CONFIG_HOME",
                "ANDROID_USER_HOME",
                "ANDROID_HOME",
                "ANDROID_SDK_ROOT",
                "JAVA_HOME",
                "GRADLE_USER_HOME",
                "PUB_CACHE",
                "PATH",
                "LANG",
                "LC_ALL",
                "ORG_GRADLE_PROJECT_telltaleGateCRigDebug",
                "TELLTALE_GATE_C_FLUTTER_ROOT",
                "TELLTALE_GATE_C_JDK_ROOT",
                "TELLTALE_GATE_C_SANDBOX_PROFILE",
                scoped_command.LAUNCH_MARKER,
                scoped_command.RELEASE_FD,
                scoped_command.READY_FD,
            ):
                self.assertIn(name, child_environment)
            for name in (
                "OP_SERVICE_ACCOUNT_TOKEN",
                "HF_TOKEN",
                "SSH_AUTH_SOCK",
                "ARBITRARY_SECRET",
                "TELLTALE_GATE_C_ARBITRARY_SECRET",
                "TMPDIR",
                "JAVA_TOOL_OPTIONS",
                "FLUTTER_ALREADY_LOCKED",
            ):
                self.assertNotIn(name, child_environment)
            evidence = json.loads(
                scoped_command.child_environment_evidence_path(
                    root / "authority.json"
                ).read_text(encoding="utf-8")
            )
            self.assertRegex(evidence["launchId"], r"\A[0-9a-f]{32}\Z")
            self.assertEqual(
                evidence,
                _environment_evidence(child_environment, evidence["launchId"]),
            )
            self.assertEqual(evidence["actualNames"], sorted(child_environment))
            self.assertFalse(evidence["valuesObserved"])
            self.assertEqual(
                evidence["postBarrierAddedNames"],
                ["FLUTTER_ALREADY_LOCKED", "JAVA_TOOL_OPTIONS", "TMPDIR"],
            )
            self.assertNotIn("FLUTTER_ALREADY_LOCKED", evidence["actualNames"])
            self.assertNotIn("JAVA_TOOL_OPTIONS", evidence["actualNames"])
            self.assertNotIn("TMPDIR", evidence["actualNames"])
            self.assertNotIn("must-not-cross", repr(evidence))
            self.assertEqual(signal_authority, {"version": 2})
            self.assertIs(authority, signal_authority)

    def test_launch_does_not_copy_the_supplied_ambient_environment(self):
        class CopyRejectingEnvironment(dict):
            def copy(self):
                raise AssertionError("ambient environment copy is forbidden")

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            base_environment, paths = _sandbox_environment(root)
            environment = CopyRejectingEnvironment(base_environment)
            wrapper = (HERE / "android_sdk_sandbox_exec.sh").resolve()
            child = mock.Mock(pid=321, returncode=None)
            child.poll.return_value = None
            process_scope = mock.Mock()
            process_scope.create_launch_authority.return_value = {"version": 2}
            _observe_popen_environment(process_scope)
            with (
                mock.patch.object(
                    scoped_command.os, "pipe", side_effect=[(10, 11), (12, 13)]
                ),
                mock.patch.object(scoped_command.os, "close"),
                mock.patch.object(scoped_command.os, "write", return_value=1),
                mock.patch.object(scoped_command, "_read_ready"),
                mock.patch.object(
                    scoped_command, "_load_process_scope", return_value=process_scope
                ),
                mock.patch.object(
                    scoped_command.subprocess, "Popen", return_value=child
                ),
            ):
                scoped_command.launch_authorized_child(
                    [str(wrapper), "--", "/usr/bin/true"],
                    cwd=paths["APP_ROOT"],
                    environment=environment,
                    authority_path=root / "authority.json",
                    owner_root_pid=os.getppid(),
                    wrapper_path=wrapper,
                    wrapper_sha256=hashlib.sha256(wrapper.read_bytes()).hexdigest(),
                )

    def test_malformed_barrier_environment_never_writes_authority_or_releases(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            environment, paths = _sandbox_environment(root)
            wrapper = (HERE / "android_sdk_sandbox_exec.sh").resolve()
            child = mock.Mock(pid=321, returncode=None)
            child.poll.return_value = None
            process_scope = mock.Mock()

            with (
                mock.patch.object(
                    scoped_command.os, "pipe", side_effect=[(10, 11), (12, 13)]
                ),
                mock.patch.object(scoped_command.os, "close"),
                mock.patch.object(scoped_command.os, "write") as release,
                mock.patch.object(
                    scoped_command,
                    "_read_ready",
                    side_effect=RuntimeError(
                        "sandbox wrapper launch-barrier environment report is invalid"
                    ),
                ),
                mock.patch.object(
                    scoped_command, "_load_process_scope", return_value=process_scope
                ),
                mock.patch.object(
                    scoped_command.subprocess, "Popen", return_value=child
                ),
                mock.patch.object(
                    scoped_command, "_terminate_blocked_child"
                ) as terminate,
                self.assertRaisesRegex(RuntimeError, "report is invalid"),
            ):
                scoped_command.launch_authorized_child(
                    [str(wrapper), "--", "/usr/bin/true"],
                    cwd=paths["APP_ROOT"],
                    environment=environment,
                    authority_path=root / "authority.process-authority.json",
                    owner_root_pid=os.getppid(),
                    wrapper_path=wrapper,
                    wrapper_sha256=hashlib.sha256(wrapper.read_bytes()).hexdigest(),
                )

            release.assert_not_called()
            process_scope.create_launch_authority.assert_not_called()
            self.assertTrue(terminate.called)
            self.assertFalse((root / "authority.child-environment.json").exists())

    def test_authority_failure_kills_blocked_child_without_release(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            environment, paths = _sandbox_environment(root)
            wrapper = (HERE / "android_sdk_sandbox_exec.sh").resolve()
            child = mock.Mock(pid=321, returncode=None)
            child.poll.return_value = None
            process_scope = mock.Mock()
            blocked_record = SimpleNamespace(
                pid=321,
                identity=SimpleNamespace(
                    pid=321,
                    ppid=os.getpid(),
                    pgid=321,
                    sid=321,
                    uid=os.getuid(),
                ),
            )
            _observe_popen_environment(process_scope, blocked_record)
            process_scope.create_launch_authority.side_effect = RuntimeError(
                "no authority"
            )
            events = []
            with (
                mock.patch.object(
                    scoped_command.os, "pipe", side_effect=[(10, 11), (12, 13)]
                ),
                mock.patch.object(
                    scoped_command.os,
                    "close",
                    side_effect=lambda descriptor: events.append(("close", descriptor)),
                ),
                mock.patch.object(scoped_command.os, "write") as release,
                mock.patch.object(scoped_command, "_read_ready"),
                mock.patch.object(
                    scoped_command, "_load_process_scope", return_value=process_scope
                ),
                mock.patch.object(
                    scoped_command.subprocess, "Popen", return_value=child
                ),
                mock.patch.object(
                    scoped_command,
                    "_terminate_blocked_child",
                    side_effect=lambda *_args: events.append(("terminate", 321)),
                ) as terminate,
                self.assertRaisesRegex(RuntimeError, "no authority"),
            ):
                scoped_command.launch_authorized_child(
                    [str(wrapper), "--", "/usr/bin/true"],
                    cwd=paths["APP_ROOT"],
                    environment=environment,
                    authority_path=root / "authority.json",
                    owner_root_pid=os.getppid(),
                    wrapper_path=wrapper,
                    wrapper_sha256=hashlib.sha256(wrapper.read_bytes()).hexdigest(),
                )
            release.assert_not_called()
            terminate.assert_called_with(child, process_scope, blocked_record)
            self.assertLess(
                events.index(("close", 11)), events.index(("terminate", 321))
            )

    def test_blocked_child_eof_reap_precedes_any_signal(self):
        child = mock.Mock(pid=321, returncode=None)
        child.poll.return_value = None
        child.wait.return_value = 0
        process_scope = mock.Mock()

        with mock.patch.object(scoped_command.os, "killpg") as killpg:
            scoped_command._terminate_blocked_child(child, process_scope, None)

        child.wait.assert_called_once_with(timeout=0.5)
        process_scope._record_for_pid.assert_not_called()
        process_scope._signal_exact.assert_not_called()
        killpg.assert_not_called()

    def test_blocked_child_fallback_signals_only_the_exact_single_pid(self):
        child = mock.Mock(pid=321, returncode=None)
        child.poll.return_value = None
        child.wait.side_effect = [
            subprocess.TimeoutExpired("blocked", 0.5),
            0,
        ]
        blocked_record = SimpleNamespace(
            pid=321,
            identity=SimpleNamespace(
                pid=321,
                ppid=os.getpid(),
                pgid=321,
                sid=321,
                uid=os.getuid(),
            ),
        )
        process_scope = mock.Mock()
        process_scope._signal_exact.return_value = True

        with mock.patch.object(scoped_command.os, "killpg") as killpg:
            scoped_command._terminate_blocked_child(
                child,
                process_scope,
                blocked_record,
            )

        process_scope._signal_exact.assert_called_once_with(
            blocked_record,
            signal.SIGKILL,
        )
        self.assertEqual(
            child.wait.call_args_list,
            [mock.call(timeout=0.5), mock.call(timeout=2)],
        )
        killpg.assert_not_called()

    def test_blocked_child_pid_reuse_never_falls_back_to_pid_only_signal(self):
        child = mock.Mock(pid=321, returncode=None)
        child.poll.return_value = None
        child.wait.side_effect = [
            subprocess.TimeoutExpired("blocked", 0.5),
            subprocess.TimeoutExpired("reused", 0.5),
        ]
        blocked_record = SimpleNamespace(
            pid=321,
            identity=SimpleNamespace(
                pid=321,
                ppid=os.getpid(),
                pgid=321,
                sid=321,
                uid=os.getuid(),
            ),
        )
        process_scope = mock.Mock()
        process_scope._signal_exact.return_value = False

        with (
            mock.patch.object(scoped_command.os, "kill") as kill,
            mock.patch.object(scoped_command.os, "killpg") as killpg,
            self.assertRaisesRegex(RuntimeError, "changed identity"),
        ):
            scoped_command._terminate_blocked_child(
                child,
                process_scope,
                blocked_record,
            )

        kill.assert_not_called()
        killpg.assert_not_called()

    def test_pending_cleanup_signal_is_delivered_only_after_authority_binding(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            authority_path = root / "authority.json"
            scope_path = root / "scope.json"
            result_path = root / "result.json"
            args = argparse.Namespace(
                authority=authority_path,
                reference_authority=[],
                scope_evidence=scope_path,
                result=result_path,
                label="probe",
                cwd=root,
                owner_root_pid=os.getppid(),
                wrapper=HERE / "android_sdk_sandbox_exec.sh",
                wrapper_sha256="a" * 64,
                barrier_ms=100,
                freeze_ms=100,
                term_ms=100,
                kill_ms=100,
                command=["unused"],
            )
            child = mock.Mock(pid=444, returncode=None)
            child.poll.return_value = None
            authority = {"version": 2}
            callbacks = {}
            events = []

            def install(signum, handler):
                if callable(handler):
                    callbacks[signum] = handler
                return signal.SIG_DFL

            def mask(how, values):
                if how == signal.SIG_BLOCK:
                    events.append("blocked")
                    return set()
                events.append("unblocked")
                callbacks[signal.SIGTERM](signal.SIGTERM, None)
                return set()

            def launch(*_args, **_kwargs):
                events.append("launched")
                return child, authority

            scope = {"status": "quiescent"}

            def contain(*_args, **_kwargs):
                events.append("contained")
                scope_path.write_text("{}\n", encoding="utf-8")
                return scope

            process_scope = mock.Mock()
            process_scope.contain_and_write.side_effect = contain
            written = {}

            def reap(*_args, **_kwargs):
                events.append("reaped")
                return 0

            def write_result(_path, value, _label):
                written.update(value)

            with (
                mock.patch.object(scoped_command, "_parse_args", return_value=args),
                mock.patch.object(
                    scoped_command, "launch_authorized_child", side_effect=launch
                ),
                mock.patch.object(
                    scoped_command, "_load_process_scope", return_value=process_scope
                ),
                mock.patch.object(
                    scoped_command, "reap_child", side_effect=reap
                ) as reaper,
                mock.patch.object(
                    scoped_command, "_write_json", side_effect=write_result
                ),
                mock.patch.object(scoped_command.signal, "signal", side_effect=install),
                mock.patch.object(
                    scoped_command.signal, "pthread_sigmask", side_effect=mask
                ),
            ):
                exit_code = scoped_command.main([])

            self.assertEqual(exit_code, 128 + signal.SIGTERM)
            self.assertEqual(
                events,
                ["blocked", "launched", "unblocked", "contained", "reaped"],
            )
            reaper.assert_called_once_with(child, None, timeout=2)
            self.assertEqual(written["scopeTermination"], scope)
            self.assertNotEqual(written["status"], "completed")
            self.assertEqual(
                process_scope.contain_and_write.call_args.kwargs[
                    "reference_authority_paths"
                ],
                [],
            )

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS process sessions")
    def test_real_unreaped_leader_anchor_contains_detached_same_sid_orphan(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            environment, paths = _sandbox_environment(root)
            wrapper = (HERE / "android_sdk_sandbox_exec.sh").resolve()
            authority_path = root / "authority.json"
            evidence_path = root / "scope.json"
            child, _authority = scoped_command.launch_authorized_child(
                [str(wrapper), "--", "/bin/sh", "-c", "sleep 60 &"],
                cwd=paths["APP_ROOT"],
                environment=environment,
                authority_path=authority_path,
                owner_root_pid=os.getppid(),
                wrapper_path=wrapper,
                wrapper_sha256=hashlib.sha256(wrapper.read_bytes()).hexdigest(),
            )
            process_scope = scoped_command._load_process_scope()
            try:
                observed = scoped_command.observe_child_exit(child)
                self.assertEqual(observed, 0)
                orphans = [
                    record
                    for record in process_scope._all_records().values()
                    if record.identity.sid == child.pid and record.pid != child.pid
                ]
                self.assertTrue(orphans)
                scope = process_scope.contain_and_write(
                    [authority_path],
                    evidence_path,
                    freeze_ms=5000,
                    term_ms=5000,
                    kill_ms=5000,
                )
                self.assertEqual(scope["status"], "quiescent")
                stopped_pids = {
                    item["identity"]["pid"] for item in scope["stoppedProcesses"]
                }
                self.assertTrue({item.pid for item in orphans}.issubset(stopped_pids))
                self.assertEqual(scoped_command.reap_child(child, observed), 0)
            finally:
                if child.returncode is None:
                    try:
                        child.wait(timeout=0.2)
                    except subprocess.TimeoutExpired:
                        os.kill(child.pid, signal.SIGKILL)
                        child.wait(timeout=2)

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS process sessions")
    def test_real_wrapper_waits_for_two_pipe_authorization(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            ambient_environment, paths = _sandbox_environment(root)
            ambient_environment.update(
                {
                    "OP_SERVICE_ACCOUNT_TOKEN": "must-not-cross",
                    "HF_TOKEN": "must-not-cross",
                    "SSH_AUTH_SOCK": "/tmp/must-not-cross.sock",
                    "ARBITRARY_SECRET": "must-not-cross",
                    "TMPDIR": "/tmp/ambient-must-not-cross",
                    "JAVA_TOOL_OPTIONS": "-Dsecret=must-not-cross",
                    "FLUTTER_ALREADY_LOCKED": "false",
                    "PATH": "/evil/ambient/path",
                }
            )
            environment = scoped_command._child_environment(
                ambient_environment,
                paths["APP_ROOT"],
            )
            wrapper = (HERE / "android_sdk_sandbox_exec.sh").resolve()
            release_read, release_write = os.pipe()
            ready_read, ready_write = os.pipe()
            child = None
            try:
                environment.update(
                    {
                        scoped_command.LAUNCH_MARKER: "1" * 32,
                        scoped_command.RELEASE_FD: str(release_read),
                        scoped_command.READY_FD: str(ready_write),
                    }
                )
                expected_java_tool_options = (
                    f"-Djava.io.tmpdir={paths['RUN_TEMP']} "
                    f"-Duser.home={paths['ISOLATED_ROOT']}/home "
                    "-Dkotlin.daemon.options="
                    f"runFilesPath={paths['RUN_TEMP']}/kotlin-daemon"
                )
                probe = (
                    '[[ "$TMPDIR" == "$1" '
                    '&& "$JAVA_TOOL_OPTIONS" == "$2" '
                    '&& "$FLUTTER_ALREADY_LOCKED" == true '
                    "&& -z ${OP_SERVICE_ACCOUNT_TOKEN:-} "
                    "&& -z ${HF_TOKEN:-} "
                    "&& -z ${SSH_AUTH_SOCK:-} "
                    "&& -z ${ARBITRARY_SECRET:-} ]]"
                )
                child = scoped_command.subprocess.Popen(
                    [
                        str(wrapper),
                        "--",
                        "/bin/zsh",
                        "-f",
                        "-c",
                        probe,
                        "gate-environment-probe",
                        str(paths["RUN_TEMP"]),
                        expected_java_tool_options,
                    ],
                    env=environment,
                    stdin=scoped_command.subprocess.DEVNULL,
                    stderr=scoped_command.subprocess.PIPE,
                    start_new_session=True,
                    pass_fds=(release_read, ready_write),
                )
                os.close(release_read)
                release_read = -1
                os.close(ready_write)
                ready_write = -1
                scoped_command._read_ready(
                    ready_read,
                    5000,
                    "1" * 32,
                    sorted(environment),
                )
                self.assertIsNone(child.poll())
                self.assertEqual(os.write(release_write, b"G"), 1)
                _, stderr = child.communicate(timeout=15)
                self.assertEqual(child.returncode, 0, stderr.decode(errors="replace"))
            finally:
                for descriptor in (
                    release_read,
                    release_write,
                    ready_read,
                    ready_write,
                ):
                    if descriptor >= 0:
                        try:
                            os.close(descriptor)
                        except OSError:
                            pass
                if child is not None and child.poll() is None:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=2)
                if child is not None and child.stderr is not None:
                    child.stderr.close()


if __name__ == "__main__":
    unittest.main()
