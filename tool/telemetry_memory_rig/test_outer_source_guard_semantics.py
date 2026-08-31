from __future__ import annotations

import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "test_outer_source_guard_target",
    HERE / "outer_gate_result_verifier.py",
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load outer Gate result verifier")
verifier = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = verifier
SPEC.loader.exec_module(verifier)


def _write(path: Path, value: bytes | str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(value.encode() if isinstance(value, str) else value)
    path.chmod(0o600)


def _sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _compact(paths) -> tuple[Path, ...]:
    selected: list[Path] = []
    for path in sorted(
        {Path(path).absolute() for path in paths},
        key=lambda item: (len(item.parts), str(item)),
    ):
        if not any(
            path == parent or path.is_relative_to(parent) for parent in selected
        ):
            selected.append(path)
    return tuple(selected)


class OuterSourceGuardSemanticsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve(strict=True)
        self.app = self.root / "app"
        self.rig = self.app / "tool/telemetry_memory_rig"
        self.evidence = self.root / "evidence"
        self.flutter = self.root / "flutter"
        self.sdk = self.root / "android-sdk"
        self.jdk = self.root / "jdk"
        self.python_runtime = self.root / "python-runtime"
        for path in (
            self.rig,
            self.evidence,
            self.flutter,
            self.sdk,
            self.jdk,
            self.python_runtime,
        ):
            path.mkdir(parents=True, exist_ok=True)
        self.evidence.chmod(0o700)

        self.isolated = self.root / "deleted-isolated"
        self.gradle_home = self.root / "deleted-gradle-home"
        self.settings = self.isolated / "xdg-config/settings"
        self.debug_keystore = self.isolated / "android-user-home/debug.keystore"
        self.gradle_distribution = self.gradle_home / "wrapper/dists/gradle-9.3.1"
        self.app_watch = self.app / "lib"
        self.app_watch.mkdir()

        helper_names = (
            "source_guard_evidence_validator.py",
            "source_tree_guard.py",
        )
        manifest_lines: list[tuple[str, str]] = []
        for name in helper_names:
            path = self.rig / name
            _write(path, f"helper:{name}\n")
            logical = f"tool/telemetry_memory_rig/{name}"
            manifest_lines.append((logical, f"{_sha(path)}  {logical}\n"))
        _write(
            self.evidence / "tested-files.post.sha256",
            "".join(line for _, line in sorted(manifest_lines)),
        )
        _write(
            self.evidence / "identity.txt",
            f"android_sdk_root={self.sdk}\n"
            f"jdk_root={self.jdk}\n"
            f"python_runtime_root={self.python_runtime}\n"
            f"gradle_distribution_root={self.gradle_distribution}\n",
        )
        for prefix, path in (
            ("flutter-settings", self.settings),
            ("android-debug-keystore", self.debug_keystore),
        ):
            text = f"{'a' * 64}  {path}\n"
            _write(self.evidence / f"{prefix}.pre.sha256", text)
            _write(self.evidence / f"{prefix}.post.sha256", text)

        self.prepared = {
            "paths": {
                "app_root": str(self.app),
                "flutter_root": str(self.flutter),
                "android_sdk_root": str(self.sdk),
                "isolated_root": str(self.isolated),
                "gradle_home": str(self.gradle_home),
            }
        }
        self.validator_module = SimpleNamespace(
            validate_completed_guard_evidence=lambda *args: {
                "status": "stopped",
                "observedEventCount": 2,
                "baselineUniqueRegularFileCount": 1,
                "unchangedTreeVerified": True,
            }
        )
        self.source_module = SimpleNamespace(
            build_watch_plan=lambda *args, **kwargs: SimpleNamespace(
                watch_paths=(self.app_watch, self.sdk, self.jdk, self.python_runtime)
            ),
            _compact_roots=_compact,
        )
        self._write_phase(
            "bootstrap-source-tree-guard",
            (self.settings,),
            frozenset({self.settings}),
        )
        self._write_phase(
            "source-tree-guard",
            (self.settings, self.gradle_distribution, self.debug_keystore),
            frozenset({self.settings, self.debug_keystore}),
        )

    def _write_phase(
        self,
        prefix: str,
        deleted_roots: tuple[Path, ...],
        deleted_files: frozenset[Path],
    ) -> None:
        watch_paths = _compact(
            (
                self.app_watch,
                self.sdk,
                self.jdk,
                self.python_runtime,
                *deleted_roots,
            )
        )
        native_roots = _compact(
            path.parent if path in deleted_files or path.is_file() else path
            for path in watch_paths
        )
        _write(
            self.evidence / f"{prefix}-ready.json",
            json.dumps(
                {
                    "watchPaths": [str(path) for path in watch_paths],
                    "nativeFSEventsWatchRoots": [str(path) for path in native_roots],
                }
            )
            + "\n",
        )
        events = self.evidence / f"{prefix}-events.jsonl"
        _write(events, "ledger\n")
        _write(
            self.evidence / f"{prefix}-ledger-preservation.json",
            json.dumps(
                {
                    "version": 1,
                    "status": "preserved",
                    "destination": str(events),
                    "bytes": events.stat().st_size,
                    "sha256": _sha(events),
                }
            )
            + "\n",
        )

    def _verify(self) -> None:
        def load(path: Path, name: str):
            del name
            if path.name == "source_guard_evidence_validator.py":
                return self.validator_module
            if path.name == "source_tree_guard.py":
                return self.source_module
            raise AssertionError(path)

        with mock.patch.object(verifier, "_load_trusted_module", side_effect=load):
            verifier._verify_source_guard_semantics(
                self.evidence,
                self.rig,
                self.prepared,
            )

    def test_accepts_completed_run_after_disposable_watch_roots_are_deleted(
        self,
    ) -> None:
        self.assertFalse(self.isolated.exists())
        self.assertFalse(self.gradle_home.exists())
        self._verify()

    def test_rejects_ready_watch_plan_missing_deleted_gradle_root(self) -> None:
        ready_path = self.evidence / "source-tree-guard-ready.json"
        ready = json.loads(ready_path.read_text())
        ready["watchPaths"].remove(str(self.gradle_distribution))
        _write(ready_path, json.dumps(ready) + "\n")
        with self.assertRaisesRegex(verifier.VerificationError, "watch plan"):
            self._verify()


if __name__ == "__main__":
    unittest.main()
