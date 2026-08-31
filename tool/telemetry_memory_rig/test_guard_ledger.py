import os
import pathlib
import stat
import tempfile
import unittest

from guard_ledger import preserve_guard_ledger


class GuardLedgerTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name).resolve()
        self.temp_root = self.root / "isolated"
        self.evidence_root = self.root / "evidence"
        self.temp_root.mkdir(mode=0o700)
        self.evidence_root.mkdir(mode=0o700)
        self.name = "source-tree-guard-events.jsonl"
        self.live = self.temp_root / self.name
        self.destination = self.evidence_root / self.name

    def tearDown(self):
        self.temporary.cleanup()

    def _write_live(self, value: bytes = b'{"recordType":"raw-darwin-fsevents"}\n'):
        self.live.write_bytes(value)
        self.live.chmod(0o600)

    def test_preserves_private_ledger_across_directories_and_removes_live_copy(self):
        payload = b"first\nsecond\n"
        self._write_live(payload)

        result = preserve_guard_ledger(
            live=self.live,
            destination=self.destination,
            temp_root=self.temp_root,
            evidence_root=self.evidence_root,
        )

        self.assertFalse(self.live.exists())
        self.assertEqual(self.destination.read_bytes(), payload)
        self.assertEqual(stat.S_IMODE(self.destination.lstat().st_mode), 0o600)
        self.assertEqual(result["status"], "preserved")
        self.assertEqual(result["bytes"], len(payload))
        self.assertRegex(result["sha256"], r"^[0-9a-f]{64}$")

    def test_repeated_call_validates_existing_preserved_ledger(self):
        self._write_live(b"stable\n")
        preserve_guard_ledger(
            live=self.live,
            destination=self.destination,
            temp_root=self.temp_root,
            evidence_root=self.evidence_root,
        )

        result = preserve_guard_ledger(
            live=self.live,
            destination=self.destination,
            temp_root=self.temp_root,
            evidence_root=self.evidence_root,
        )

        self.assertEqual(result["status"], "already-preserved")
        self.assertEqual(result["bytes"], 7)

    def test_existing_different_destination_is_not_overwritten(self):
        self._write_live(b"live\n")
        self.destination.write_bytes(b"different\n")
        self.destination.chmod(0o600)

        with self.assertRaisesRegex(ValueError, "differ"):
            preserve_guard_ledger(
                live=self.live,
                destination=self.destination,
                temp_root=self.temp_root,
                evidence_root=self.evidence_root,
            )

        self.assertEqual(self.live.read_bytes(), b"live\n")
        self.assertEqual(self.destination.read_bytes(), b"different\n")

    def test_rejects_hardlinked_live_ledger(self):
        self._write_live()
        os.link(self.live, self.temp_root / "second-link")

        with self.assertRaisesRegex(ValueError, "hardlink"):
            preserve_guard_ledger(
                live=self.live,
                destination=self.destination,
                temp_root=self.temp_root,
                evidence_root=self.evidence_root,
            )

    def test_rejects_symlinked_live_ledger(self):
        real = self.temp_root / "real"
        real.write_bytes(b"real")
        real.chmod(0o600)
        self.live.symlink_to(real)

        with self.assertRaisesRegex(ValueError, "symlink"):
            preserve_guard_ledger(
                live=self.live,
                destination=self.destination,
                temp_root=self.temp_root,
                evidence_root=self.evidence_root,
            )

    def test_rejects_unsafe_live_mode(self):
        self._write_live()
        self.live.chmod(0o640)

        with self.assertRaisesRegex(ValueError, "mode"):
            preserve_guard_ledger(
                live=self.live,
                destination=self.destination,
                temp_root=self.temp_root,
                evidence_root=self.evidence_root,
            )

    def test_rejects_path_outside_bound_roots(self):
        self._write_live()
        outside = self.root / self.name

        with self.assertRaisesRegex(ValueError, "direct child"):
            preserve_guard_ledger(
                live=self.live,
                destination=outside,
                temp_root=self.temp_root,
                evidence_root=self.evidence_root,
            )


if __name__ == "__main__":
    unittest.main()
