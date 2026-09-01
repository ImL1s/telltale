import tempfile
import unittest
from pathlib import Path

from verify_evidence import verify


class VerifyEvidenceTest(unittest.TestCase):
    def test_accepts_ordered_home_seed_and_recovery_proof(self):
        with tempfile.TemporaryDirectory() as root:
            paths = [Path(root) / name for name in ("home", "seed", "recovery")]
            paths[0].write_text(
                "TELLTALE_LIFECYCLE_READY_HOME\n"
                "TELLTALE_LIFECYCLE_HOME_STORED values=2 statuses=0 gaps=0\n"
                "All tests passed!\n",
                encoding="utf-8",
            )
            paths[1].write_text(
                "TELLTALE_LIFECYCLE_READY_FORCE_STOP "
                "session=0123456789abcdef0123456789abcdef "
                "values=2 statuses=1 gaps=3\n",
                encoding="utf-8",
            )
            paths[2].write_text(
                "TELLTALE_LIFECYCLE_RECOVERED "
                "session=0123456789abcdef0123456789abcdef "
                "values=2 statuses=1 gaps=3 "
                "terminal=recoveredAfterInterruption ui=connect-history\n"
                "All tests passed!\n",
                encoding="utf-8",
            )
            verify(*(str(path) for path in paths))

    def test_rejects_recovery_without_a_positive_value_count(self):
        with tempfile.TemporaryDirectory() as root:
            paths = [Path(root) / name for name in ("home", "seed", "recovery")]
            paths[0].write_text(
                "TELLTALE_LIFECYCLE_READY_HOME\n"
                "TELLTALE_LIFECYCLE_HOME_STORED values=1 statuses=0 gaps=0\n"
                "All tests passed!\n",
                encoding="utf-8",
            )
            paths[1].write_text(
                "TELLTALE_LIFECYCLE_READY_FORCE_STOP "
                "session=0123456789abcdef0123456789abcdef "
                "values=1 statuses=0 gaps=0\n",
                encoding="utf-8",
            )
            paths[2].write_text(
                "TELLTALE_LIFECYCLE_RECOVERED "
                "session=0123456789abcdef0123456789abcdef "
                "values=0 statuses=0 gaps=0 "
                "terminal=recoveredAfterInterruption ui=connect-history\n"
                "All tests passed!\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "artifact/UI proof"):
                verify(*(str(path) for path in paths))

    def test_rejects_recovery_for_a_different_session(self):
        with tempfile.TemporaryDirectory() as root:
            paths = [Path(root) / name for name in ("home", "seed", "recovery")]
            paths[0].write_text(
                "TELLTALE_LIFECYCLE_READY_HOME\n"
                "TELLTALE_LIFECYCLE_HOME_STORED values=1 statuses=0 gaps=0\n"
                "All tests passed!\n",
                encoding="utf-8",
            )
            paths[1].write_text(
                "TELLTALE_LIFECYCLE_READY_FORCE_STOP "
                "session=0123456789abcdef0123456789abcdef "
                "values=1 statuses=0 gaps=0\n",
                encoding="utf-8",
            )
            paths[2].write_text(
                "TELLTALE_LIFECYCLE_RECOVERED "
                "session=fedcba9876543210fedcba9876543210 "
                "values=1 statuses=0 gaps=0 "
                "terminal=recoveredAfterInterruption ui=connect-history\n"
                "All tests passed!\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "killed durable prefix"):
                verify(*(str(path) for path in paths))

    def test_rejects_changed_recovery_counts(self):
        with tempfile.TemporaryDirectory() as root:
            paths = [Path(root) / name for name in ("home", "seed", "recovery")]
            paths[0].write_text(
                "TELLTALE_LIFECYCLE_READY_HOME\n"
                "TELLTALE_LIFECYCLE_HOME_STORED values=1 statuses=0 gaps=0\n"
                "All tests passed!\n",
                encoding="utf-8",
            )
            paths[1].write_text(
                "TELLTALE_LIFECYCLE_READY_FORCE_STOP "
                "session=0123456789abcdef0123456789abcdef "
                "values=2 statuses=1 gaps=0\n",
                encoding="utf-8",
            )
            paths[2].write_text(
                "TELLTALE_LIFECYCLE_RECOVERED "
                "session=0123456789abcdef0123456789abcdef "
                "values=3 statuses=1 gaps=0 "
                "terminal=recoveredAfterInterruption ui=connect-history\n"
                "All tests passed!\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "killed durable prefix"):
                verify(*(str(path) for path in paths))


if __name__ == "__main__":
    unittest.main()
