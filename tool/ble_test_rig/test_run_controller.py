import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


@unittest.skipUnless(
    sys.platform == "darwin" and shutil.which("zsh"),
    "the BLE rig controller is macOS-only",
)
class RunControllerTest(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.root = Path(self.temporary_directory.name)
        self.run_script = Path(__file__).with_name("run.sh")
        self.environment = os.environ.copy()
        # Exercise the trailing slash macOS normally supplies in TMPDIR.
        self.environment["TMPDIR"] = f"{self.root}/"

    def _run(self, action: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["zsh", str(self.run_script), action],
            check=False,
            capture_output=True,
            text=True,
            env=self.environment,
        )

    def _events(self) -> list[dict[str, object]]:
        path = self.root / "telltale-ble-rig/events.jsonl"
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines()]

    def _run_function_harness(self, body: str) -> subprocess.CompletedProcess[str]:
        return self._run_function_harness_with_environment(
            body,
            self.environment,
        )

    def _run_function_harness_with_environment(
        self,
        body: str,
        environment: dict[str, str],
        *,
        name: str = "controller_harness.zsh",
    ) -> subprocess.CompletedProcess[str]:
        source = self.run_script.read_text(encoding="utf-8")
        prefix, marker, _ = source.partition("\ncommand=${1:---start}")
        self.assertTrue(marker, "controller entrypoint marker changed")
        harness = self.root / name
        harness.write_text(f"{prefix}\n{body}\n", encoding="utf-8")
        return subprocess.run(
            ["zsh", str(harness)],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

    def test_controller_lock_serializes_distinct_private_tmp_roots(self):
        first_root = self.root / "first"
        second_root = self.root / "second"
        first_root.mkdir(mode=0o700)
        second_root.mkdir(mode=0o700)
        first_environment = self.environment.copy()
        second_environment = self.environment.copy()
        first_environment["TMPDIR"] = f"{first_root}/"
        second_environment["TMPDIR"] = f"{second_root}/"
        ready = self.root / "controller-lock-ready"

        source = self.run_script.read_text(encoding="utf-8")
        prefix, marker, _ = source.partition("\ncommand=${1:---start}")
        self.assertTrue(marker, "controller entrypoint marker changed")
        holder = self.root / "controller_lock_holder.zsh"
        holder.write_text(
            f"{prefix}\n"
            "acquire_controller_lock\n"
            f"print -r -- \"$CONTROLLER_LOCK\" > {shlex.quote(str(ready))}\n"
            "sleep 2\n",
            encoding="utf-8",
        )
        process = subprocess.Popen(
            ["zsh", str(holder)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=first_environment,
        )
        self.addCleanup(lambda: process.poll() is None and process.kill())
        for _ in range(100):
            if ready.exists():
                break
            if process.poll() is not None:
                stdout, stderr = process.communicate()
                self.fail(f"lock holder exited early: {stdout=} {stderr=}")
            time.sleep(0.02)
        else:
            self.fail("lock holder did not acquire its controller lock")

        contender = self._run_function_harness_with_environment(
            """
local -i contender_fd=0
if zsystem flock -t 0 -f contender_fd "$CONTROLLER_LOCK"; then
  zsystem flock -u "$contender_fd"
  print -r -- "$CONTROLLER_LOCK|acquired"
else
  print -r -- "$CONTROLLER_LOCK|busy"
fi
""",
            second_environment,
            name="controller_lock_contender.zsh",
        )

        process.communicate(timeout=5)
        self.assertEqual(contender.returncode, 0, contender.stderr)
        contender_lock, disposition = contender.stdout.strip().rsplit("|", 1)
        self.assertEqual(contender_lock, ready.read_text().strip())
        self.assertEqual(disposition, "busy")

    def test_status_failure_does_not_fall_through_to_success_event(self):
        result = self._run("--status")

        self.assertEqual(result.returncode, 1)
        self.assertIn("emulator is not a live owned process", result.stderr)
        self.assertNotIn("status_ok", {event["event"] for event in self._events()})

    def test_invalid_action_returns_usage_error(self):
        result = self._run("--invalid")

        self.assertEqual(result.returncode, 2)
        self.assertIn("usage:", result.stderr)

    def test_stop_removes_dead_malformed_pid_files(self):
        state = self.root / "telltale-ble-rig"
        state.mkdir(mode=0o700)
        for name in ("bridge", "emulator"):
            (state / f"{name}.pid").write_text(f" {'a' * 32} \n")

        result = self._run("--stop")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((state / "bridge.pid").exists())
        self.assertFalse((state / "emulator.pid").exists())

    def test_stop_discovers_live_owned_processes_without_valid_pid_files(self):
        token = "1" * 32
        fingerprint = "a" * 64
        state = self.root / "telltale-ble-rig"
        for name, pid_record in (
            ("bridge", None),
            ("bridge", f"111 {token}\n"),
            ("emulator", None),
            ("emulator", f"111 {token}\n"),
        ):
            with self.subTest(name=name, pid_record=pid_record):
                if state.exists():
                    shutil.rmtree(state)
                state.mkdir(mode=0o700)
                pid_file = state / f"{name}.pid"
                if pid_record is not None:
                    pid_file.write_text(pid_record)
                killed = self.root / f"killed-{name}"
                if killed.exists():
                    killed.unlink()
                result = self._run_function_harness(
                    f"""
TEST_KILLED={shlex.quote(str(killed))}
discover_owned_processes() {{
  [[ -e \"$TEST_KILLED\" ]] || print -- \"111 {token} {fingerprint}\"
}}
matches_owned_process() {{ return 0; }}
wait_owned_dead() {{ return 0; }}
kill() {{ print -r -- \"$*\" > \"$TEST_KILLED\"; }}
rig_event() {{ return 0; }}
_stop_one_locked {name}
"""
                )

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(killed.read_text().strip(), "111")
                self.assertFalse(pid_file.exists())

    def test_emulator_candidates_use_only_the_private_state_pid_lock(self):
        state = self.root / "telltale-ble-rig"
        state.mkdir(mode=0o700)
        (state / "ircama.pid").write_text("111\n")

        result = self._run_function_harness(
            """
pgrep() { return 1; }
candidate_process_ids emulator
"""
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "111")

    def test_dead_private_ircama_lock_is_removed_before_start(self):
        state = self.root / "telltale-ble-rig"
        state.mkdir(mode=0o700)
        lock = state / "ircama.pid"
        lock.write_text("111\n")
        result = self._run_function_harness(
            """
kill() { return 1; }
prepare_ircama_pid_lock_for_start
"""
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(lock.exists())

    def test_malformed_private_ircama_lock_fails_closed(self):
        state = self.root / "telltale-ble-rig"
        state.mkdir(mode=0o700)
        lock = state / "ircama.pid"
        lock.write_text("not-a-pid\n")
        result = self._run_function_harness(
            """prepare_ircama_pid_lock_for_start"""
        )

        self.assertEqual(result.returncode, 1)
        self.assertTrue(lock.exists())
        self.assertIn("malformed stale Ircama PID lock", result.stderr)

    def test_live_or_recycled_private_ircama_lock_is_preserved(self):
        state = self.root / "telltale-ble-rig"
        state.mkdir(mode=0o700)
        lock = state / "ircama.pid"
        lock.write_text("111\n")
        result = self._run_function_harness(
            """
kill() { return 0; }
prepare_ircama_pid_lock_for_start
"""
        )

        self.assertEqual(result.returncode, 1)
        self.assertEqual(lock.read_text(), "111\n")
        self.assertIn("references live pid=111", result.stderr)

    def test_forced_stop_removes_only_matching_dead_private_ircama_lock(self):
        state = self.root / "telltale-ble-rig"
        state.mkdir(mode=0o700)
        lock = state / "ircama.pid"
        for contents, live, removed in (
            ("111\n", False, True),
            ("111\n", True, False),
            ("222\n", False, False),
            ("bad\n", False, False),
        ):
            with self.subTest(contents=contents, live=live):
                lock.write_text(contents)
                result = self._run_function_harness(
                    f"""
kill() {{ return {0 if live else 1}; }}
remove_ircama_pid_lock_after_stop 111
"""
                )
                self.assertEqual(not lock.exists(), removed, result.stderr)

    def test_shared_tmpdir_is_refused_before_state_or_tools_are_used(self):
        environment = self.environment.copy()
        environment["TMPDIR"] = "/tmp"

        result = subprocess.run(
            ["zsh", str(self.run_script), "--status"],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(result.returncode, 1)
        self.assertTrue(
            "unsafe directory" in result.stderr
            or "accessible by other users" in result.stderr,
            result.stderr,
        )

    def test_launchservices_executes_only_private_runtime_scripts(self):
        source = self.run_script.read_text(encoding="utf-8")

        self.assertIn('RUNTIME="$STATE/runtime"', source)
        self.assertIn('"$RUNTIME/bridge.py"', source)
        self.assertIn('"$RUNTIME/probe.py"', source)
        self.assertNotIn('open -n -a "$APP" --args -u "$HERE/bridge.py"', source)
        self.assertNotIn('open -n -a "$APP" --args -u "$HERE/probe.py"', source)

    def test_host_bundle_identity_does_not_change_with_controller_tmpdir(self):
        source = self.run_script.read_text(encoding="utf-8")

        self.assertIn('VENV=$HOST_ROOT/telltale-ble-rig-venv', source)
        self.assertIn('APP=$HOST_ROOT/BleHost.app', source)
        self.assertIn(
            'CONTROLLER_LOCK="$HOST_ROOT/telltale-ble-rig.controller.lock"',
            source,
        )
        self.assertNotIn('VENV=$TMP_ROOT/telltale-ble-rig-venv', source)
        self.assertNotIn('APP=$TMP_ROOT/BleHost.app', source)
        self.assertNotIn('CONTROLLER_LOCK="$STATE/controller.lock"', source)

    def test_purge_preserves_per_run_stop_locks_and_removes_only_evidence(self):
        state = self.root / "telltale-ble-rig"
        state.mkdir(mode=0o700)
        stop_lock = state / "bridge.stop.lock"
        evidence = state / "events.jsonl"
        stop_lock.touch()
        evidence.write_text("evidence\n")
        bridge_log = self.root / "bridge.log"
        client_log = self.root / "client.log"
        bridge_log.write_text("bridge\n")
        client_log.write_text("client\n")
        result = self._run_function_harness(
            f"""
BRIDGE_LOG={shlex.quote(str(bridge_log))}
CLIENT_LOG={shlex.quote(str(client_log))}
stop() {{ return 0; }}
discover_owned_processes() {{ return 0; }}
port_owner() {{ return 0; }}
purge_evidence
"""
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(stop_lock.exists())
        self.assertFalse(evidence.exists())
        self.assertFalse(bridge_log.exists())
        self.assertFalse(client_log.exists())

    def test_expiry_stops_live_owned_process_without_pid_fingerprint(self):
        token = "1" * 32
        fingerprint = "a" * 64
        state = self.root / "telltale-ble-rig"
        state.mkdir(mode=0o700)
        (state / "emulator.pid").write_text(f"111 {token}\n")
        killed = self.root / "killed"
        events = self.root / "events"
        result = self._run_function_harness(
            f"""
TEST_KILLED={shlex.quote(str(killed))}
TEST_EVENTS={shlex.quote(str(events))}
owned_pid() {{ return 1; }}
list_owned_processes() {{
  [[ -e \"$TEST_KILLED\" ]] || print -- \"111 {'a' * 64}\"
}}
port_owner() {{ return 0; }}
matches_owned_process() {{ return 0; }}
wait_owned_dead() {{ return 0; }}
kill() {{ print -r -- \"$*\" > \"$TEST_KILLED\"; }}
rig_event() {{ print -r -- \"$*\" >> \"$TEST_EVENTS\"; }}
expire {token}
"""
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(killed.read_text().strip(), "111")
        self.assertFalse((state / "emulator.pid").exists())
        self.assertIn("rig_expired", events.read_text())

    def test_expiry_stops_live_owned_process_with_missing_pid_file(self):
        token = "1" * 32
        state = self.root / "telltale-ble-rig"
        state.mkdir(mode=0o700)
        killed = self.root / "killed"
        events = self.root / "events"
        result = self._run_function_harness(
            f"""
TEST_KILLED={shlex.quote(str(killed))}
TEST_EVENTS={shlex.quote(str(events))}
owned_pid() {{ return 1; }}
list_owned_processes() {{
  [[ -e \"$TEST_KILLED\" ]] || print -- \"111 {'a' * 64}\"
}}
port_owner() {{ return 0; }}
matches_owned_process() {{ return 0; }}
wait_owned_dead() {{ return 0; }}
kill() {{ print -r -- \"$*\" > \"$TEST_KILLED\"; }}
rig_event() {{ print -r -- \"$*\" >> \"$TEST_EVENTS\"; }}
expire {token}
"""
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(killed.read_text().strip(), "111")
        self.assertFalse((state / "emulator.pid").exists())
        self.assertIn("rig_expired", events.read_text())

    def test_old_expiry_preserves_newer_valid_owner_pid_file(self):
        old_token = "1" * 32
        new_token = "2" * 32
        old_fingerprint = "a" * 64
        new_fingerprint = "b" * 64
        state = self.root / "telltale-ble-rig"
        state.mkdir(mode=0o700)
        pid_file = state / "emulator.pid"
        expected_pid_file = f"222 {new_token} {new_fingerprint}\n"
        pid_file.write_text(expected_pid_file)
        killed = self.root / "killed"
        events = self.root / "events"
        result = self._run_function_harness(
            f"""
TEST_KILLED={shlex.quote(str(killed))}
TEST_EVENTS={shlex.quote(str(events))}
owned_pid() {{ print -- 222; }}
list_owned_processes() {{
  [[ -e \"$TEST_KILLED\" ]] || print -- \"111 {old_fingerprint}\"
}}
port_owner() {{ print -- 222; }}
matches_owned_process() {{ return 0; }}
wait_owned_dead() {{ return 0; }}
kill() {{ print -r -- \"$*\" > \"$TEST_KILLED\"; }}
rig_event() {{ print -r -- \"$*\" >> \"$TEST_EVENTS\"; }}
expire {old_token}
"""
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(killed.read_text().strip(), "111")
        self.assertEqual(pid_file.read_text(), expected_pid_file)
        self.assertIn("newer_valid_owner", events.read_text())

    def test_status_refuses_identity_lost_during_final_snapshot(self):
        events = self.root / "events"
        result = self._run_function_harness(
            f"""
TEST_EVENTS={shlex.quote(str(events))}
owned_pid() {{
  [[ \"$1\" == emulator ]] && print -- 111 || print -- 222
}}
port_owner() {{ print -- 111; }}
listener_endpoint() {{ print -- 127.0.0.1:35000; }}
verify_bridge_health() {{ return 0; }}
status_snapshot() {{ return 1; }}
rig_event() {{ print -r -- \"$*\" >> \"$TEST_EVENTS\"; }}
status
"""
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("changed during the status check", result.stderr)
        self.assertFalse(events.exists())

    def test_start_readiness_retries_a_transient_full_status_failure(self):
        attempts = self.root / "status-attempts"
        result = self._run_function_harness(
            f"""
TEST_ATTEMPTS={shlex.quote(str(attempts))}
BRIDGE_LOG={shlex.quote(str(self.root / 'bridge.log'))}
recover_owned_pid_file() {{ return 0; }}
owned_pid() {{ print -- 222; }}
status() {{
  local count=0
  [[ ! -f "$TEST_ATTEMPTS" ]] || count=$(cat "$TEST_ATTEMPTS")
  (( count += 1 ))
  print -- "$count" > "$TEST_ATTEMPTS"
  if (( count == 1 )); then
    print -u2 -- "transient identity snapshot"
    return 1
  fi
  print -- "healthy emulator_pid=111 bridge_pid=222 port=35000"
}}
sleep() {{ return 0; }}
wait_for_rig_ready {'1' * 32} 3 0
"""
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(attempts.read_text().strip(), "2")
        self.assertIn("healthy emulator_pid=111", result.stdout)


if __name__ == "__main__":
    unittest.main()
