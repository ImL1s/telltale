import os
import pathlib
import stat
import tempfile
import unittest

from prepare_evidence_dir import (
    create_default_runner,
    create_wrapper_outer,
    create_wrapper_runner,
)


class PrepareEvidenceDirTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.app_root = pathlib.Path(self.temporary.name).resolve() / "app"
        self.app_root.mkdir(mode=0o700)

    def tearDown(self):
        self.temporary.cleanup()

    def test_default_runner_is_fresh_private_and_collision_safe(self):
        first = create_default_runner(self.app_root)
        second = create_default_runner(self.app_root)

        expected_parent = self.app_root / ".omx/logs"
        self.assertEqual(first.parent, expected_parent)
        self.assertEqual(second.parent, expected_parent)
        self.assertNotEqual(first, second)
        self.assertTrue(first.name.startswith("telemetry-memory-rig-"))
        self.assertEqual(_mode(first), 0o700)
        self.assertEqual(_mode(second), 0o700)

    def test_wrapper_outer_accepts_safe_prelude_and_creates_fresh_runner(self):
        outer = create_wrapper_outer(self.app_root)
        for name in (
            "runner.log",
            "wrapper-before-state.txt",
            "wrapper-identity.txt",
        ):
            path = outer / name
            path.write_text(name, encoding="utf-8")
            path.chmod(0o600)

        runner = create_wrapper_runner(self.app_root, outer)

        self.assertEqual(
            outer.parent,
            self.app_root / ".omx/evidence/telemetry-v1/oracles/final",
        )
        self.assertTrue(outer.name.startswith("memory-gate-c-"))
        self.assertEqual(runner.parent, outer)
        self.assertTrue(runner.name.startswith("telemetry-memory-rig-"))
        self.assertEqual(_mode(outer), 0o700)
        self.assertEqual(_mode(runner), 0o700)

    def test_wrapper_outer_accepts_tempfile_underscore_suffix(self):
        parent = self.app_root / ".omx/evidence/telemetry-v1/oracles/final"
        parent.mkdir(parents=True, mode=0o700)
        outer = parent / "memory-gate-c-_fixed"
        outer.mkdir(mode=0o700)

        runner = create_wrapper_runner(self.app_root, outer)

        self.assertEqual(runner.parent, outer)
        self.assertTrue(runner.name.startswith("telemetry-memory-rig-"))

    def test_out_of_bound_wrapper_path_is_rejected(self):
        outside = pathlib.Path(self.temporary.name) / "memory-gate-c-outside"
        outside.mkdir(mode=0o700)
        with self.assertRaisesRegex(ValueError, "escapes app root"):
            create_wrapper_runner(self.app_root, outside)

    def test_symlinked_evidence_ancestor_is_rejected(self):
        real = self.app_root / "real"
        real.mkdir(mode=0o700)
        (self.app_root / ".omx").symlink_to(real, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            create_default_runner(self.app_root)

    def test_symlinked_wrapper_leaf_is_rejected(self):
        parent = self.app_root / ".omx/evidence/telemetry-v1/oracles/final"
        parent.mkdir(parents=True, mode=0o700)
        real = self.app_root / "real-outer"
        real.mkdir(mode=0o700)
        outer = parent / "memory-gate-c-linked"
        outer.symlink_to(real, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            create_wrapper_runner(self.app_root, outer)

    def test_unexpected_existing_wrapper_entry_is_rejected(self):
        outer = create_wrapper_outer(self.app_root)
        (outer / "unexpected.txt").write_text("no", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "unexpected wrapper evidence entry"):
            create_wrapper_runner(self.app_root, outer)

    def test_hardlinked_wrapper_prelude_is_rejected(self):
        outer = create_wrapper_outer(self.app_root)
        source = pathlib.Path(self.temporary.name) / "source"
        source.write_text("linked", encoding="utf-8")
        os.link(source, outer / "runner.log")
        with self.assertRaisesRegex(ValueError, "hardlinked"):
            create_wrapper_runner(self.app_root, outer)

    def test_special_wrapper_prelude_is_rejected(self):
        outer = create_wrapper_outer(self.app_root)
        os.mkfifo(outer / "runner.log", 0o600)
        with self.assertRaisesRegex(ValueError, "not a regular file"):
            create_wrapper_runner(self.app_root, outer)

    def test_group_readable_wrapper_prelude_is_rejected(self):
        outer = create_wrapper_outer(self.app_root)
        prelude = outer / "runner.log"
        prelude.write_text("log", encoding="utf-8")
        prelude.chmod(0o640)
        with self.assertRaisesRegex(ValueError, "unsafe mode"):
            create_wrapper_runner(self.app_root, outer)

    def test_unsafe_existing_parent_mode_is_rejected_without_chmod(self):
        omx = self.app_root / ".omx"
        omx.mkdir(mode=0o777)
        omx.chmod(0o777)
        with self.assertRaisesRegex(ValueError, "group/world-writable"):
            create_default_runner(self.app_root)
        self.assertEqual(_mode(omx), 0o777)

    def test_control_character_in_outer_path_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "control character"):
            create_wrapper_runner(
                self.app_root,
                self.app_root / ".omx/evidence/memory-gate-c-bad\nleaf",
            )


def _mode(path: pathlib.Path) -> int:
    return stat.S_IMODE(path.lstat().st_mode)


if __name__ == "__main__":
    unittest.main()
