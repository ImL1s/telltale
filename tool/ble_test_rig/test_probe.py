from __future__ import annotations

import os
from pathlib import Path
import stat
import tempfile
import unittest

from probe import open_private_log


class PrivateProbeLogTest(unittest.TestCase):
    def test_existing_log_is_truncated_and_restricted_to_owner(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "probe.log"
            path.write_text("old evidence\n", encoding="utf-8")
            path.chmod(0o644)

            with open_private_log(path) as stream:
                stream.write("new evidence\n")

            self.assertEqual("new evidence\n", path.read_text(encoding="utf-8"))
            self.assertEqual(0o600, stat.S_IMODE(path.stat().st_mode))

    @unittest.skipUnless(hasattr(os, "O_NOFOLLOW"), "O_NOFOLLOW unavailable")
    def test_symlink_target_is_refused_without_modifying_target(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "target"
            link = Path(directory) / "probe.log"
            target.write_text("keep\n", encoding="utf-8")
            link.symlink_to(target)

            with self.assertRaises(OSError):
                open_private_log(link)
            self.assertEqual("keep\n", target.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
