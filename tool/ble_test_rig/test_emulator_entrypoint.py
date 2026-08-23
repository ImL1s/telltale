import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

import emulator_entrypoint


class EmulatorEntrypointTest(unittest.TestCase):
    def test_configures_ircama_pid_and_working_directory_under_private_state(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            state = Path(temporary_directory) / "state"
            state.mkdir(mode=0o700)
            interpreter = SimpleNamespace(
                DAEMON_PIDFILE_DIR_ROOT="/var/run/",
                DAEMON_PIDFILE_DIR_NON_ROOT="/tmp/",
                DAEMON_DIR="/tmp",
            )

            remaining = emulator_entrypoint.configure_ircama_runtime(
                interpreter,
                ["--pid-directory", str(state), "-d", "-n", "35000"],
            )

            expected_directory = f"{state}{os.sep}"
            self.assertEqual(interpreter.DAEMON_PIDFILE_DIR_ROOT, expected_directory)
            self.assertEqual(
                interpreter.DAEMON_PIDFILE_DIR_NON_ROOT,
                expected_directory,
            )
            self.assertEqual(interpreter.DAEMON_DIR, str(state))
            self.assertEqual(interpreter.DAEMON_PIDFILE, "ircama.pid")
            self.assertEqual(interpreter.DAEMON_UMASK, 0o077)
            self.assertEqual(remaining, ["-d", "-n", "35000"])

    def test_refuses_a_shared_pid_directory(self):
        interpreter = SimpleNamespace()

        with self.assertRaisesRegex(ValueError, "private"):
            emulator_entrypoint.configure_ircama_runtime(
                interpreter,
                ["--pid-directory", "/tmp", "-d"],
            )


if __name__ == "__main__":
    unittest.main()
