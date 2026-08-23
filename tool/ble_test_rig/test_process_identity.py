import os
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import process_identity


class ProcessIdentityTest(unittest.TestCase):
    def test_parses_exact_argv_and_environment(self):
        payload = (
            struct.pack("i", 3)
            + b"/usr/bin/python3\0\0"
            + b"python3\0script.py\0--flag\0\0"
            + b"TOKEN=abc\0EMPTY=\0\0"
        )

        argv, environment = process_identity._split_procargs(payload)

        self.assertEqual(argv, ("python3", "script.py", "--flag"))
        self.assertEqual(environment, {"TOKEN": "abc", "EMPTY": ""})

    def test_emulator_match_requires_exact_argv_and_token(self):
        here = Path("/tmp/rig")
        venv = Path("/tmp/venv")
        app = Path("/tmp/BleHost.app")
        state = Path("/tmp/state")
        token = "a" * 32
        expected_executable = os.path.realpath(venv / "bin/python")
        snapshot = process_identity.ProcessSnapshot(
            expected_executable,
            (
                expected_executable,
                str(here / "emulator_entrypoint.py"),
                "--pid-directory",
                str(state),
                "-d",
                "-n",
                "35000",
                "-s",
                "car",
            ),
            {"TELLTALE_RIG_TOKEN": token},
            "Sat Aug 23 10:00:00 2026",
        )

        self.assertTrue(
            process_identity.matches_rig_process(
                snapshot,
                name="emulator",
                token=token,
                here=here,
                venv=venv,
                app=app,
                state=state,
                port=35000,
            )
        )
        changed = process_identity.ProcessSnapshot(
            expected_executable,
            snapshot.argv[:-1] + ("truck",),
            snapshot.environment,
            snapshot.started,
        )
        self.assertFalse(
            process_identity.matches_rig_process(
                changed,
                name="emulator",
                token=token,
                here=here,
                venv=venv,
                app=app,
                state=state,
                port=35000,
            )
        )
        self.assertEqual(
            process_identity.ownership_token(snapshot, name="emulator"),
            token,
        )

    def test_fingerprint_changes_with_process_start_time(self):
        first = process_identity.ProcessSnapshot(
            "/bin/example",
            ("example",),
            {},
            "Sat Aug 23 10:00:00 2026",
        )
        second = process_identity.ProcessSnapshot(
            "/bin/example",
            ("example",),
            {},
            "Sat Aug 23 10:00:01 2026",
        )

        self.assertNotEqual(first.fingerprint, second.fingerprint)

    def test_bridge_match_requires_exact_argv_and_token_argument(self):
        here = Path("/tmp/rig")
        venv = Path("/tmp/venv")
        app = Path("/tmp/BleHost.app")
        state = Path("/tmp/state")
        token = "b" * 32
        expected_executable = os.path.realpath(venv / "bin/python")
        snapshot = process_identity.ProcessSnapshot(
            expected_executable,
            (
                expected_executable,
                "-u",
                str(here / "bridge.py"),
                "120",
                str(state / "bridge.pid"),
                "0",
                "20",
                "0",
                token,
                str(state.parent),
            ),
            {},
            "Sat Aug 23 10:00:00 2026",
        )

        self.assertTrue(
            process_identity.matches_rig_process(
                snapshot,
                name="bridge",
                token=token,
                here=here,
                venv=venv,
                app=app,
                state=state,
                port=35000,
            )
        )
        changed = process_identity.ProcessSnapshot(
            expected_executable,
            snapshot.argv[:8] + ("c" * 32,) + snapshot.argv[9:],
            snapshot.environment,
            snapshot.started,
        )
        self.assertFalse(
            process_identity.matches_rig_process(
                changed,
                name="bridge",
                token=token,
                here=here,
                venv=venv,
                app=app,
                state=state,
                port=35000,
            )
        )
        self.assertEqual(
            process_identity.ownership_token(snapshot, name="bridge"),
            token,
        )
        self.assertEqual(
            process_identity.ownership_token(changed, name="bridge"),
            "c" * 32,
        )
        invalid_token = process_identity.ProcessSnapshot(
            expected_executable,
            snapshot.argv[:8] + ("not-a-token",) + snapshot.argv[9:],
            snapshot.environment,
            snapshot.started,
        )
        self.assertIsNone(
            process_identity.ownership_token(invalid_token, name="bridge")
        )


if __name__ == "__main__":
    unittest.main()
