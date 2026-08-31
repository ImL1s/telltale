import subprocess
import shlex
import tempfile
import time
import unittest
from collections.abc import Callable
from pathlib import Path


HERE = Path(__file__).resolve().parent
HELPER = HERE / "bounded_reap.sh"
RUN_SH = (HERE / "run.sh").read_text(encoding="utf-8")


def _run_case(
    child: str | Callable[[Path], str],
    natural_ms: int,
    term_ms: int,
    kill_ms: int,
):
    with tempfile.TemporaryDirectory() as temporary:
        evidence = Path(temporary) / "reap.txt"
        ready = Path(temporary) / "ready"
        child_command = child(ready) if callable(child) else child
        readiness = (
            f"""
for attempt in {{1..100}}; do
  [[ -f {shlex.quote(str(ready))} ]] && break
  sleep 0.01
done
[[ -f {shlex.quote(str(ready))} ]] || exit 70
"""
            if callable(child)
            else ""
        )
        script = f"""
source {shlex.quote(str(HELPER))}
zsh -c {shlex.quote(child_command)} &
pid=$!
{readiness}
set +e
bounded_reap "$pid" {shlex.quote(str(evidence))} test {natural_ms} {term_ms} {kill_ms}
rc=$?
set -e
print -r -- "helper_rc=$rc"
"""
        started = time.monotonic()
        completed = subprocess.run(
            ["zsh", "-c", script],
            text=True,
            capture_output=True,
            timeout=5,
            check=True,
        )
        elapsed = time.monotonic() - started
        values = {}
        for line in evidence.read_text(encoding="utf-8").splitlines():
            key, value = line.split("=", 1)
            values[key] = value
        return completed.stdout, values, elapsed


class BoundedReapTest(unittest.TestCase):
    def test_clock_failure_returns_bounded_error_without_spinning(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary) / "reap.txt"
            script = f"""
source {shlex.quote(str(HELPER))}
PYTHON=/does/not/exist
zsh -c 'sleep 60' &
pid=$!
trap 'kill -KILL "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
set +e
bounded_reap "$pid" {shlex.quote(str(evidence))} test 10 10 10
rc=$?
set -e
print -r -- "helper_rc=$rc"
if kill -0 "$pid" 2>/dev/null; then
  print -r -- "child_alive=true"
else
  print -r -- "child_alive=false"
fi
"""
            completed = subprocess.run(
                ["zsh", "-c", script],
                text=True,
                capture_output=True,
                timeout=2,
                check=True,
            )
            self.assertIn("helper_rc=127", completed.stdout)
            self.assertIn("child_alive=false", completed.stdout)
            values = {}
            for line in evidence.read_text(encoding="utf-8").splitlines():
                key, value = line.split("=", 1)
                values[key] = value
            self.assertEqual(values["clock_failure"], "true")
            self.assertEqual(values["clock_failure_stage"], "start")
            self.assertIn(values["outcome"], {"terminated", "killed"})
            self.assertEqual(values["term_sent"], "true")
            expected_signal = "KILL" if values["outcome"] == "killed" else "TERM"
            self.assertEqual(values["forced_host_termination"], expected_signal)

    def test_clock_failure_kills_and_waits_for_term_ignoring_child(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary) / "reap.txt"
            ready = Path(temporary) / "ready"
            child = (
                "trap '' TERM; "
                f": > {shlex.quote(str(ready))}; "
                "while true; do sleep 1; done"
            )
            script = f"""
source {shlex.quote(str(HELPER))}
PYTHON=/does/not/exist
zsh -c {shlex.quote(child)} &
pid=$!
trap 'kill -KILL "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
for attempt in {{1..100}}; do
  [[ -f {shlex.quote(str(ready))} ]] && break
  sleep 0.01
done
[[ -f {shlex.quote(str(ready))} ]] || exit 70
set +e
bounded_reap "$pid" {shlex.quote(str(evidence))} test 10 10 200
rc=$?
set -e
print -r -- "helper_rc=$rc"
if kill -0 "$pid" 2>/dev/null; then
  print -r -- "child_alive=true"
else
  print -r -- "child_alive=false"
fi
"""
            completed = subprocess.run(
                ["zsh", "-c", script],
                text=True,
                capture_output=True,
                timeout=2,
                check=True,
            )
            self.assertIn("helper_rc=127", completed.stdout)
            self.assertIn("child_alive=false", completed.stdout)
            values = {}
            for line in evidence.read_text(encoding="utf-8").splitlines():
                key, value = line.split("=", 1)
                values[key] = value
            self.assertEqual(values["clock_failure"], "true")
            self.assertEqual(values["outcome"], "killed")
            self.assertEqual(values["term_sent"], "true")
            self.assertEqual(values["kill_sent"], "true")
            self.assertEqual(values["forced_host_termination"], "KILL")

    def test_natural_exit_is_waited_and_audited(self):
        stdout, evidence, elapsed = _run_case("exit 7", 500, 100, 100)
        self.assertIn("helper_rc=7", stdout)
        self.assertEqual(evidence["outcome"], "natural_exit")
        self.assertEqual(evidence["forced_host_termination"], "none")
        self.assertEqual(evidence["exit_code"], "7")
        self.assertEqual(evidence["clock_failure"], "false")
        self.assertLess(elapsed, 2)

    def test_natural_exit_after_old_threshold_analogue_is_not_terminated(self):
        stdout, evidence, elapsed = _run_case(
            lambda ready: (
                f": > {shlex.quote(str(ready))}; "
                "sleep 0.15; exit 79"
            ),
            300,
            50,
            50,
        )
        self.assertIn("helper_rc=79", stdout)
        self.assertEqual(evidence["outcome"], "natural_exit")
        self.assertEqual(evidence["forced_host_termination"], "none")
        self.assertEqual(evidence["term_sent"], "false")
        self.assertEqual(evidence["exit_code"], "79")
        self.assertGreaterEqual(elapsed, 0.1)
        self.assertLess(elapsed, 2)

    def test_term_ignoring_child_is_killed_with_a_bounded_wait(self):
        stdout, evidence, elapsed = _run_case(
            lambda ready: (
                "trap '' TERM; "
                f": > {shlex.quote(str(ready))}; "
                "while true; do sleep 1; done"
            ),
            50,
            100,
            1000,
        )
        self.assertIn("helper_rc=137", stdout)
        self.assertEqual(evidence["outcome"], "killed")
        self.assertEqual(evidence["forced_host_termination"], "KILL")
        self.assertEqual(evidence["term_sent"], "true")
        self.assertEqual(evidence["kill_sent"], "true")
        self.assertEqual(evidence["exit_code"], "137")
        self.assertEqual(evidence["clock_failure"], "false")
        self.assertLess(elapsed, 3)

    def test_runner_uses_one_bounded_reaper_for_every_driver_exit(self):
        for evidence in (
            "cleanup-current-driver${suffix}.txt",
            "cleanup-gate-driver${suffix}.txt",
            "measurement-driver-exit.txt",
            "seed-driver-exit.txt",
            "recovery-driver-exit.txt",
        ):
            self.assertIn(evidence, RUN_SH)
        self.assertIn(
            "Gate C seed driver required host TERM/KILL after force-stop",
            RUN_SH,
        )
        executable_lines = [
            line.strip()
            for line in RUN_SH.splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
        self.assertFalse(any(line.startswith("wait ") for line in executable_lines))


if __name__ == "__main__":
    unittest.main()
