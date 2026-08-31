from __future__ import annotations

import os
import shlex
import subprocess
import tempfile
import time
import unittest
from dataclasses import dataclass
from pathlib import Path


HERE = Path(__file__).resolve().parent
RUN_SH = (HERE / "run.sh").read_text(encoding="utf-8")


def _extract_function(name: str) -> str:
    start = RUN_SH.index(f"{name}() {{")
    cursor = start
    depth = 0
    while cursor < len(RUN_SH):
        character = RUN_SH[cursor]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return RUN_SH[start : cursor + 1]
        cursor += 1
    raise AssertionError(f"unterminated shell function: {name}")


CLEANUP_FUNCTION = _extract_function("cleanup_isolated_gradle_home")
USER_CLEANUP_FUNCTION = _extract_function("cleanup_isolated_user_home")
QUIESCE_FUNCTION = _extract_function("quiesce_gradle_process_scope")
BOOTSTRAP_EXIT_FUNCTION = _extract_function("bootstrap_exit")
ON_EXIT_FUNCTION = _extract_function("on_exit")


@dataclass(frozen=True)
class CleanupResult:
    returncode: int
    stdout: str
    stderr: str
    elapsed: float


class GradleCleanupTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="gradle-cleanup-test.")
        self.workspace = Path(self.temporary.name)
        self.evidence = self.workspace / "evidence"
        self.evidence.mkdir()
        self.scope_log = self.evidence / "scope-call.txt"
        self.gradle_root = Path(
            tempfile.mkdtemp(prefix="telltale-gradle-home.", dir="/tmp")
        ).resolve(strict=True)
        (self.gradle_root / "home").mkdir()
        self.user_root = Path(
            tempfile.mkdtemp(prefix="telltale-gate-user-home.", dir="/tmp")
        ).resolve(strict=True)

    def tearDown(self) -> None:
        if self.gradle_root.exists():
            subprocess.run(
                ["/bin/rm", "-rf", str(self.gradle_root)],
                check=True,
            )
        if self.user_root.exists():
            subprocess.run(
                ["/bin/rm", "-rf", str(self.user_root)],
                check=True,
            )
        self.temporary.cleanup()

    def _failing_cleanup_python(self) -> tuple[Path, Path]:
        calls = self.evidence / "user-rmtree-calls.txt"
        executable = self.workspace / "failing-cleanup-python"
        executable.write_text(
            "#!/bin/zsh\nprint -r -- call >> "
            f"{shlex.quote(str(calls))}\nexit 41\n",
            encoding="utf-8",
        )
        executable.chmod(0o700)
        return executable, calls

    def _run_cleanup(self, scope_mode: str) -> CleanupResult:
        script = f"""
{CLEANUP_FUNCTION}
quiesce_gradle_process_scope() {{
  print -r -- "$#|${{1:-}}|${{2:-}}" > {shlex.quote(str(self.scope_log))}
  /usr/bin/env bash -c 'exit 0' || return $?
  [[ {shlex.quote(scope_mode)} == success ]] || return 23
  return 0
}}
GRADLE_TEMP_PARENT={shlex.quote(str(self.gradle_root))}
GRADLE_USER_HOME="$GRADLE_TEMP_PARENT/home"
GRADLE_FORENSIC_RETENTION_LATCH=0
GRADLE_PROCESS_SCOPE_CLEANUP_ATTEMPT=0
EVIDENCE={shlex.quote(str(self.evidence))}
PYTHON=/opt/homebrew/bin/python3
ANDROID_SDK_SANDBOX_EXEC=/does/not/exist
APP_ROOT={shlex.quote(str(self.workspace / 'app'))}
set +e
cleanup_isolated_gradle_home
rc=$?
set -e
print -r -- "cleanup_rc=$rc"
print -r -- "retention_latch=$GRADLE_FORENSIC_RETENTION_LATCH"
print -r -- "cleanup_attempts=$GRADLE_PROCESS_SCOPE_CLEANUP_ATTEMPT"
"""
        started = time.monotonic()
        completed = subprocess.run(
            ["zsh", "-c", script],
            text=True,
            capture_output=True,
            timeout=3,
            check=True,
        )
        return CleanupResult(
            returncode=completed.returncode,
            stdout=completed.stdout,
            stderr=completed.stderr,
            elapsed=time.monotonic() - started,
        )

    def test_cleanup_quiesces_only_the_current_isolated_scope(self) -> None:
        foreign_root = Path(
            tempfile.mkdtemp(prefix="telltale-gradle-home.", dir="/tmp")
        ).resolve(strict=True)
        foreign_marker = foreign_root / "must-remain"
        foreign_marker.write_text("foreign", encoding="utf-8")
        self.addCleanup(
            subprocess.run,
            ["/bin/rm", "-rf", str(foreign_root)],
            check=True,
        )

        result = self._run_cleanup("success")

        self.assertIn("cleanup_rc=0", result.stdout)
        arguments = self.scope_log.read_text(encoding="utf-8").strip().split("|")
        self.assertEqual(arguments[0], "2")
        self.assertEqual(arguments[1], "cleanup")
        self.assertEqual(Path(arguments[2]).parent, self.evidence)
        self.assertTrue(foreign_marker.is_file())

    def test_scope_failure_preserves_root_and_fails_closed(self) -> None:
        result = self._run_cleanup("failure")

        self.assertRegex(result.stdout, r"cleanup_rc=[1-9][0-9]*")
        self.assertIn("retention_latch=1", result.stdout)
        self.assertTrue(self.gradle_root.is_dir())

    def test_process_scope_precondition_failure_sets_retention_latch(self) -> None:
        script = f"""
{QUIESCE_FUNCTION}
GRADLE_FORENSIC_RETENTION_LATCH=0
ANDROID_SDK_SANDBOX_RUN_TEMP=''
GRADLE_USER_HOME=''
set +e
quiesce_gradle_process_scope gradle-version /tmp/not-created.json
print -r -- "scope_rc=$?"
print -r -- "retention_latch=$GRADLE_FORENSIC_RETENTION_LATCH"
"""
        completed = subprocess.run(
            ["zsh", "-c", script],
            text=True,
            capture_output=True,
            timeout=3,
            check=True,
        )

        self.assertIn("scope_rc=64", completed.stdout)
        self.assertIn("retention_latch=1", completed.stdout)

    def test_failure_latch_preserves_first_evidence_without_retry(self) -> None:
        script = f"""
{CLEANUP_FUNCTION}
quiesce_gradle_process_scope() {{
  print -r -- "${{1}}|${{2}}" >> {shlex.quote(str(self.scope_log))}
  GRADLE_FORENSIC_RETENTION_LATCH=1
  return 23
}}
GRADLE_TEMP_PARENT={shlex.quote(str(self.gradle_root))}
GRADLE_USER_HOME="$GRADLE_TEMP_PARENT/home"
GRADLE_FORENSIC_RETENTION_LATCH=0
GRADLE_PROCESS_SCOPE_CLEANUP_ATTEMPT=0
EVIDENCE={shlex.quote(str(self.evidence))}
PYTHON=/opt/homebrew/bin/python3
set +e
cleanup_isolated_gradle_home
first_rc=$?
cleanup_isolated_gradle_home
second_rc=$?
print -r -- "first_rc=$first_rc"
print -r -- "second_rc=$second_rc"
print -r -- "cleanup_attempts=$GRADLE_PROCESS_SCOPE_CLEANUP_ATTEMPT"
"""
        completed = subprocess.run(
            ["zsh", "-c", script],
            text=True,
            capture_output=True,
            timeout=3,
            check=True,
        )

        self.assertIn("first_rc=23", completed.stdout)
        self.assertIn("second_rc=75", completed.stdout)
        self.assertIn("cleanup_attempts=1", completed.stdout)
        self.assertEqual(len(self.scope_log.read_text(encoding="utf-8").splitlines()), 1)
        self.assertTrue(self.gradle_root.is_dir())

    def test_success_deletes_root_after_scope_quiescence(self) -> None:
        result = self._run_cleanup("success")

        self.assertIn("cleanup_rc=0", result.stdout)
        self.assertTrue(self.scope_log.is_file())
        self.assertFalse(self.gradle_root.exists())

    def test_cleanup_does_not_shadow_zsh_path_special_variable(self) -> None:
        original_path = os.environ["PATH"]

        result = self._run_cleanup("success")

        self.assertIn("cleanup_rc=0", result.stdout)
        self.assertNotIn("env: bash: No such file or directory", result.stderr)
        self.assertEqual(os.environ["PATH"], original_path)

    def test_scope_quiescence_precedes_the_single_recursive_delete(self) -> None:
        scope_index = CLEANUP_FUNCTION.index("quiesce_gradle_process_scope")
        delete_index = CLEANUP_FUNCTION.index("shutil.rmtree(")

        self.assertLess(scope_index, delete_index)
        self.assertEqual(CLEANUP_FUNCTION.count("shutil.rmtree("), 1)

    def test_on_exit_does_not_retry_failed_gradle_cleanup_or_delete_user_temp(
        self,
    ) -> None:
        user_cleanup_log = self.evidence / "user-cleanup-called"
        script = f"""
{CLEANUP_FUNCTION}
{ON_EXIT_FUNCTION}
quiesce_gradle_process_scope() {{
  print -r -- "${{1}}|${{2}}" >> {shlex.quote(str(self.scope_log))}
  GRADLE_FORENSIC_RETENTION_LATCH=1
  return 23
}}
cleanup_isolated_user_home() {{
  touch {shlex.quote(str(user_cleanup_log))}
}}
GRADLE_TEMP_PARENT={shlex.quote(str(self.gradle_root))}
GRADLE_USER_HOME="$GRADLE_TEMP_PARENT/home"
GRADLE_FORENSIC_RETENTION_LATCH=0
GRADLE_PROCESS_SCOPE_CLEANUP_ATTEMPT=0
EVIDENCE={shlex.quote(str(self.evidence))}
PYTHON=/opt/homebrew/bin/python3
CLEANUP_DONE=1
SOURCE_GUARD_PID=''
BOOTSTRAP_SOURCE_GUARD_PID=''
SOURCE_GUARD_EVENTS_LIVE=''
BOOTSTRAP_SOURCE_GUARD_EVENTS_LIVE=''
set +e
cleanup_isolated_gradle_home
print -r -- "$?" > {shlex.quote(str(self.evidence / 'first-rc'))}
trap on_exit EXIT
exit 1
"""
        completed = subprocess.run(
            ["zsh", "-c", script],
            text=True,
            capture_output=True,
            timeout=3,
            check=False,
        )

        self.assertEqual(completed.returncode, 1)
        self.assertEqual(
            (self.evidence / "first-rc").read_text(encoding="utf-8").strip(),
            "23",
        )
        self.assertEqual(len(self.scope_log.read_text(encoding="utf-8").splitlines()), 1)
        self.assertFalse(user_cleanup_log.exists())
        self.assertTrue(self.gradle_root.is_dir())

    def test_bootstrap_exit_retains_user_temp_when_latch_is_already_set(
        self,
    ) -> None:
        user_cleanup_log = self.evidence / "bootstrap-user-cleanup-called"
        script = f"""
{CLEANUP_FUNCTION}
{BOOTSTRAP_EXIT_FUNCTION}
quiesce_gradle_process_scope() {{ return 99; }}
cleanup_isolated_user_home() {{
  touch {shlex.quote(str(user_cleanup_log))}
}}
preserve_guard_event_ledger() {{ return 0; }}
GRADLE_TEMP_PARENT={shlex.quote(str(self.gradle_root))}
GRADLE_USER_HOME="$GRADLE_TEMP_PARENT/home"
GRADLE_FORENSIC_RETENTION_LATCH=1
GRADLE_PROCESS_SCOPE_CLEANUP_ATTEMPT=1
EVIDENCE={shlex.quote(str(self.evidence))}
PYTHON=/opt/homebrew/bin/python3
BOOTSTRAP_SOURCE_GUARD_PID=''
BOOTSTRAP_SOURCE_GUARD_STOP=''
BOOTSTRAP_SOURCE_GUARD_EVENTS=''
BOOTSTRAP_SOURCE_GUARD_EVENTS_LIVE=''
trap bootstrap_exit EXIT
exit 1
"""
        completed = subprocess.run(
            ["zsh", "-c", script],
            text=True,
            capture_output=True,
            timeout=3,
            check=False,
        )

        self.assertEqual(completed.returncode, 1)
        self.assertFalse(user_cleanup_log.exists())
        self.assertTrue(self.gradle_root.is_dir())

    def test_user_cleanup_failure_sets_retention_latch_and_preserves_root(
        self,
    ) -> None:
        failing_python, calls = self._failing_cleanup_python()
        script = f"""
{USER_CLEANUP_FUNCTION}
ISOLATED_USER_TEMP_PARENT={shlex.quote(str(self.user_root))}
GRADLE_FORENSIC_RETENTION_LATCH=0
HOST_HOME={shlex.quote(os.environ.get('HOME', '/tmp'))}
PYTHON={shlex.quote(str(failing_python))}
set +e
cleanup_isolated_user_home
print -r -- "cleanup_rc=$?"
print -r -- "retention_latch=$GRADLE_FORENSIC_RETENTION_LATCH"
"""
        completed = subprocess.run(
            ["zsh", "-c", script],
            text=True,
            capture_output=True,
            timeout=3,
            check=True,
        )

        self.assertIn("cleanup_rc=41", completed.stdout)
        self.assertIn("retention_latch=1", completed.stdout)
        self.assertEqual(calls.read_text(encoding="utf-8").splitlines(), ["call"])
        self.assertTrue(self.user_root.is_dir())

    def test_on_exit_does_not_retry_user_cleanup_after_first_rmtree_failure(
        self,
    ) -> None:
        failing_python, calls = self._failing_cleanup_python()
        script = f"""
{CLEANUP_FUNCTION}
{USER_CLEANUP_FUNCTION}
{ON_EXIT_FUNCTION}
ISOLATED_USER_TEMP_PARENT={shlex.quote(str(self.user_root))}
GRADLE_TEMP_PARENT=''
GRADLE_FORENSIC_RETENTION_LATCH=0
HOST_HOME={shlex.quote(os.environ.get('HOME', '/tmp'))}
PYTHON={shlex.quote(str(failing_python))}
CLEANUP_DONE=1
SOURCE_GUARD_PID=''
BOOTSTRAP_SOURCE_GUARD_PID=''
SOURCE_GUARD_EVENTS_LIVE=''
BOOTSTRAP_SOURCE_GUARD_EVENTS_LIVE=''
set +e
cleanup_isolated_user_home
print -r -- "$?" > {shlex.quote(str(self.evidence / 'user-first-rc'))}
trap on_exit EXIT
exit 0
"""
        completed = subprocess.run(
            ["zsh", "-c", script],
            text=True,
            capture_output=True,
            timeout=3,
            check=False,
        )

        self.assertEqual(completed.returncode, 1)
        self.assertEqual(
            (self.evidence / "user-first-rc").read_text(encoding="utf-8").strip(),
            "41",
        )
        self.assertEqual(calls.read_text(encoding="utf-8").splitlines(), ["call"])
        self.assertTrue(self.user_root.is_dir())

    def test_bootstrap_exit_does_not_retry_user_cleanup_after_first_rmtree_failure(
        self,
    ) -> None:
        failing_python, calls = self._failing_cleanup_python()
        script = f"""
{CLEANUP_FUNCTION}
{USER_CLEANUP_FUNCTION}
{BOOTSTRAP_EXIT_FUNCTION}
preserve_guard_event_ledger() {{ return 0; }}
ISOLATED_USER_TEMP_PARENT={shlex.quote(str(self.user_root))}
GRADLE_TEMP_PARENT=''
GRADLE_FORENSIC_RETENTION_LATCH=0
HOST_HOME={shlex.quote(os.environ.get('HOME', '/tmp'))}
PYTHON={shlex.quote(str(failing_python))}
BOOTSTRAP_SOURCE_GUARD_PID=''
BOOTSTRAP_SOURCE_GUARD_EVENTS_LIVE=''
set +e
cleanup_isolated_user_home
print -r -- "$?" > {shlex.quote(str(self.evidence / 'bootstrap-user-first-rc'))}
trap bootstrap_exit EXIT
exit 0
"""
        completed = subprocess.run(
            ["zsh", "-c", script],
            text=True,
            capture_output=True,
            timeout=3,
            check=False,
        )

        self.assertEqual(completed.returncode, 1)
        self.assertEqual(
            (self.evidence / "bootstrap-user-first-rc")
            .read_text(encoding="utf-8")
            .strip(),
            "41",
        )
        self.assertEqual(calls.read_text(encoding="utf-8").splitlines(), ["call"])
        self.assertTrue(self.user_root.is_dir())


if __name__ == "__main__":
    unittest.main()
