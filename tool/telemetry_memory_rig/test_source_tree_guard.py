import dataclasses
import json
import os
import pathlib
import queue
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

from source_tree_guard import (
    BaselineManifestEntry,
    CloneBaseline,
    CloneBaselineRecord,
    DARWIN_EVENT_FLAG_NAMES,
    DarwinFSEventsWatcher,
    DarwinFSEventRecord,
    EXACT_DOC_ALLOWLIST,
    WatchPlan,
    _capture_file_fingerprint,
    _is_suppressible_internal_sink_event,
    _load_local_clone_baseline,
    _load_manifest_clone_baseline,
    _persist_darwin_record,
    _reconcile_item_cloned_event,
    _require_native_events_sink_outside_watch_roots,
    _write_baseline_sidecar,
    build_watch_plan,
    classify_event,
    decode_darwin_flags,
    run_guard,
)


HERE = pathlib.Path(__file__).resolve().parent
GUARD = HERE / "source_tree_guard.py"
NONCE = "0123456789abcdef0123456789abcdef"


class SourceTreeGuardClassificationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name).resolve()
        for relative in ("lib", "tool/telemetry_memory_rig", "dependency", "toolchain"):
            (self.root / relative).mkdir(parents=True)
        self.plan = WatchPlan(
            root=self.root,
            local_directories=(
                self.root / "lib",
                self.root / "tool/telemetry_memory_rig",
            ),
            exact_files=frozenset({self.root / "pubspec.yaml"}),
            package_roots=(self.root / "dependency",),
            toolchain_roots=(self.root / "toolchain",),
        )

    def tearDown(self):
        self.temp.cleanup()

    def test_transient_change_and_restore_remain_two_violations(self):
        path = self.root / "lib/transient.dart"
        created = classify_event(self.plan, str(path), ["Created", "IsFile"])
        restored = classify_event(self.plan, str(path), ["Removed", "IsFile"])
        self.assertTrue(created.violates)
        self.assertTrue(restored.violates)
        self.assertEqual(created.scope, "local-directory")

    def test_generated_cache_is_ignored_but_new_tool_doc_is_not(self):
        cache = self.root / "tool/telemetry_memory_rig/__pycache__/guard.pyc"
        ignored = classify_event(self.plan, str(cache), ["Updated"])
        self.assertFalse(ignored.violates)
        self.assertEqual(ignored.ignored_reason, "generated-local-directory")

        allowed = self.root / next(iter(EXACT_DOC_ALLOWLIST))
        doc = classify_event(self.plan, str(allowed), ["Updated"])
        self.assertFalse(doc.violates)
        self.assertEqual(doc.ignored_reason, "exact-doc-allowlist")

        unlisted = self.root / "tool/telemetry_memory_rig/new_notes.md"
        self.assertTrue(classify_event(self.plan, str(unlisted), ["Created"]).violates)

    def test_exact_external_and_toolchain_inputs_are_included(self):
        cases = (
            (self.root / "pubspec.yaml", "exact-file"),
            (self.root / "dependency/lib/a.dart", "external-package"),
            (self.root / "toolchain/bin/dart", "toolchain"),
        )
        for path, scope in cases:
            with self.subTest(scope=scope):
                event = classify_event(self.plan, str(path), ["Renamed"])
                self.assertTrue(event.violates)
                self.assertEqual(event.scope, scope)

    def test_kotlin_generated_tree_is_ignored_but_adjacent_source_is_sealed(self):
        for relative in (
            "sessions/kotlin-compiler-1.salive",
            "errors/compiler-error.log",
        ):
            with self.subTest(relative=relative):
                generated = self.root / "dependency/gradle/.kotlin" / relative
                ignored = classify_event(
                    self.plan,
                    str(generated),
                    ["Created", "IsFile"],
                )
                self.assertFalse(ignored.violates)
                self.assertEqual(
                    ignored.ignored_reason,
                    "generated-package-directory",
                )

        source = self.root / "dependency/gradle/src/input.kt"
        included = classify_event(self.plan, str(source), ["Updated", "IsFile"])
        self.assertTrue(included.violates)
        self.assertEqual(included.scope, "external-package")

    def test_known_fswatch_flags_have_explicit_fail_closed_policy(self):
        included = self.root / "lib/input.dart"
        ignored = self.root / "dependency/gradle/.kotlin/sessions/compiler.salive"
        outside = self.root.parent / "outside.txt"

        material_flags = (
            "Created",
            "Updated",
            "Removed",
            "Renamed",
            "MovedFrom",
            "MovedTo",
            "Link",
            "CloseWrite",
        )
        for flag in material_flags:
            with self.subTest(policy="material", flag=flag):
                event = classify_event(self.plan, str(included), [flag, "IsFile"])
                self.assertTrue(event.material)
                self.assertTrue(event.violates)
        for flags in (("Created", "AttributeModified", "IsFile"),):
            with self.subTest(policy="material-combination", flags=flags):
                event = classify_event(self.plan, str(included), flags)
                self.assertTrue(event.material)
                self.assertTrue(event.violates)

        benign_flag_sets = (
            ("NoOp", "IsFile"),
            ("IsFile",),
            ("IsDir",),
            ("IsSymLink",),
        )
        for flags in benign_flag_sets:
            with self.subTest(policy="benign", flags=flags):
                event = classify_event(self.plan, str(included), flags)
                self.assertFalse(event.material)
                self.assertFalse(event.violates)

        for flags in (
            ("OwnerModified", "IsFile"),
            ("AttributeModified", "IsFile"),
        ):
            with self.subTest(policy="metadata-material", flags=flags):
                event = classify_event(self.plan, str(included), flags)
                self.assertTrue(event.material)
                self.assertTrue(event.violates)

        integrity_failures = (
            ("Overflow", "NoOp"),
            ("PlatformSpecific",),
            ("PlatformSpecific", "AttributeModified"),
        )
        for path in (included, ignored, outside):
            for flags in integrity_failures:
                with self.subTest(policy="integrity-failure", path=path, flags=flags):
                    with self.assertRaisesRegex(RuntimeError, "integrity|overflow"):
                        classify_event(self.plan, str(path), flags)

        for flags in ((), ("MysteryFlag",), ("Created", "MysteryFlag")):
            with self.subTest(policy="invalid", flags=flags):
                with self.assertRaisesRegex(ValueError, "flag"):
                    classify_event(self.plan, str(included), flags)

    def test_darwin_fsevent_flags_have_explicit_fail_closed_mapping(self):
        path = self.root / "lib/input.dart"
        mapped = decode_darwin_flags(
            int("00400000", 16)
            | int("00002000", 16)
            | int("00200000", 16)
            | int("00010000", 16)
        )
        self.assertEqual(
            mapped,
            ("AttributeModified", "IsFile", "ItemCloned", "Link"),
        )
        event = classify_event(self.plan, str(path), mapped)
        self.assertTrue(event.material)
        self.assertTrue(event.violates)

        for name in (
            "MustScanSubDirs",
            "UserDropped",
            "KernelDropped",
            "EventIdsWrapped",
            "HistoryDone",
            "RootChanged",
            "Mount",
            "Unmount",
        ):
            with self.subTest(name=name):
                with self.assertRaisesRegex(RuntimeError, name):
                    raw_flag = next(
                        flag
                        for flag, flag_name in DARWIN_EVENT_FLAG_NAMES.items()
                        if flag_name == name
                    )
                    decode_darwin_flags(raw_flag)

        with self.assertRaisesRegex(RuntimeError, "unknown.*0x80000000"):
            decode_darwin_flags(0x80000000)

    def test_darwin_raw_record_is_persisted_before_flag_failure(self):
        events = self.root / "events.jsonl"
        record = DarwinFSEventRecord(
            path=str(self.root / "lib/input.dart"),
            raw_flags=0x80000000,
            event_id=123,
            callback_batch_sequence=4,
            callback_record_sequence=7,
        )
        with self.assertRaisesRegex(RuntimeError, "unknown"):
            _persist_darwin_record(events, self.plan, record)
        persisted = [
            json.loads(line) for line in events.read_text(encoding="utf-8").splitlines()
        ]
        self.assertEqual(len(persisted), 1)
        self.assertEqual(persisted[0]["recordType"], "raw-darwin-fsevents")
        self.assertEqual(persisted[0]["rawFlagsHex"], "0x80000000")
        self.assertEqual(persisted[0]["eventId"], 123)
        self.assertEqual(persisted[0]["callbackBatchSequence"], 4)
        self.assertEqual(persisted[0]["callbackRecordSequence"], 7)
        raw_count = sum(
            item.get("recordType") == "raw-darwin-fsevents" for item in persisted
        )
        classified_count = sum(
            item.get("recordType") == "classified-darwin-fsevents" for item in persisted
        )
        fatal_count = 1
        self.assertEqual(fatal_count, raw_count - classified_count)

    def test_pure_item_cloned_reconciles_only_against_exact_local_baseline(self):
        source = self.root / "lib/input.dart"
        source.write_text("sealed source", encoding="utf-8")
        digest = __import__("hashlib").sha256(source.read_bytes()).hexdigest()
        manifest = self.root / "baseline.sha256"
        manifest.write_text(f"{digest}  lib/input.dart\n", encoding="utf-8")
        baseline, manifest_sha = _load_local_clone_baseline(
            self.plan,
            manifest,
        )
        self.assertRegex(manifest_sha, r"^[0-9a-f]{64}$")
        self.assertEqual(set(baseline), {source})

        record = DarwinFSEventRecord(
            path=str(source),
            raw_flags=0x00410000,
            event_id=124,
            callback_batch_sequence=5,
            callback_record_sequence=8,
        )
        strict = classify_event(
            self.plan,
            str(source),
            decode_darwin_flags(record.raw_flags),
        )
        reconciled = _reconcile_item_cloned_event(strict, record, baseline)
        self.assertFalse(reconciled.material)
        self.assertFalse(reconciled.violates)
        self.assertEqual(
            reconciled.clone_reconciliation["status"],
            "clone-observed-no-delta",
        )
        self.assertEqual(
            reconciled.clone_reconciliation["baseline"],
            reconciled.clone_reconciliation["current"],
        )

        source.write_text("changed", encoding="utf-8")
        changed = _reconcile_item_cloned_event(strict, record, baseline)
        self.assertTrue(changed.material)
        self.assertTrue(changed.violates)
        self.assertEqual(
            changed.clone_reconciliation["status"],
            "clone-observed-delta",
        )

    def test_item_cloned_reconciliation_is_narrow_and_fail_closed(self):
        source = self.root / "lib/input.dart"
        source.write_text("sealed source", encoding="utf-8")
        fingerprint = _capture_file_fingerprint(source)
        baseline = {source: fingerprint}

        pure_record = DarwinFSEventRecord(
            path=str(source),
            raw_flags=0x00410000,
            event_id=1,
            callback_batch_sequence=1,
            callback_record_sequence=1,
        )
        pure = classify_event(
            self.plan,
            str(source),
            decode_darwin_flags(pure_record.raw_flags),
        )
        missing = _reconcile_item_cloned_event(pure, pure_record, {})
        self.assertTrue(missing.violates)
        self.assertEqual(
            missing.clone_reconciliation["status"],
            "clone-baseline-missing",
        )

        modified_record = DarwinFSEventRecord(
            path=str(source),
            raw_flags=0x00411000,
            event_id=2,
            callback_batch_sequence=1,
            callback_record_sequence=2,
        )
        modified = classify_event(
            self.plan,
            str(source),
            decode_darwin_flags(modified_record.raw_flags),
        )
        unchanged = _reconcile_item_cloned_event(
            modified,
            modified_record,
            baseline,
        )
        self.assertIs(unchanged, modified)
        self.assertTrue(unchanged.violates)

        own_record = DarwinFSEventRecord(
            path=str(source),
            raw_flags=0x00490000,
            event_id=3,
            callback_batch_sequence=1,
            callback_record_sequence=3,
        )
        own = classify_event(
            self.plan,
            str(source),
            decode_darwin_flags(own_record.raw_flags),
        )
        self.assertIs(
            _reconcile_item_cloned_event(own, own_record, baseline),
            own,
        )
        self.assertTrue(own.violates)

        ignored_path = self.root / "dependency/build/generated.bin"
        ignored = classify_event(
            self.plan,
            str(ignored_path),
            decode_darwin_flags(pure_record.raw_flags),
        )
        ignored_result = _reconcile_item_cloned_event(ignored, pure_record, baseline)
        self.assertFalse(ignored_result.included)
        self.assertFalse(ignored_result.violates)
        self.assertIsNone(ignored_result.clone_reconciliation)

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS xattrs")
    def test_item_cloned_reconciliation_detects_xattr_delta(self):
        source = self.root / "lib/input.dart"
        source.write_text("sealed source", encoding="utf-8")
        baseline = {source: _capture_file_fingerprint(source)}
        completed = subprocess.run(
            [
                "/usr/bin/xattr",
                "-w",
                "com.cbstudio.telltale.guard-test",
                "changed",
                str(source),
            ],
            capture_output=True,
            text=True,
        )
        if completed.returncode != 0:
            self.skipTest(f"xattr unavailable: {completed.stderr}")
        record = DarwinFSEventRecord(
            path=str(source),
            raw_flags=0x00410000,
            event_id=4,
            callback_batch_sequence=1,
            callback_record_sequence=4,
        )
        strict = classify_event(
            self.plan,
            str(source),
            decode_darwin_flags(record.raw_flags),
        )
        reconciled = _reconcile_item_cloned_event(strict, record, baseline)
        self.assertTrue(reconciled.material)
        self.assertTrue(reconciled.violates)
        self.assertEqual(
            reconciled.clone_reconciliation["status"],
            "clone-observed-delta",
        )
        self.assertNotEqual(
            reconciled.clone_reconciliation["baseline"]["xattrs"],
            reconciled.clone_reconciliation["current"]["xattrs"],
        )

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS FSEvents")
    def test_native_pure_clone_source_hint_reconciles_without_repo_mutation(self):
        source = HERE / "tree_manifest.py"
        baseline = {source: _capture_file_fingerprint(source)}
        plan = WatchPlan(
            root=HERE,
            local_directories=(HERE,),
            exact_files=frozenset(),
            package_roots=(),
            toolchain_roots=(),
        )
        records = queue.Queue()
        watcher = DarwinFSEventsWatcher((HERE,), records)
        watcher.start(5)
        destination = self.root / "tree-manifest-clone.py"
        completed = subprocess.run(
            ["cp", "-c", str(source), str(destination)],
            capture_output=True,
            text=True,
        )
        if completed.returncode != 0:
            watcher.flush_and_stop(2)
            self.skipTest(f"APFS clone unavailable: {completed.stderr}")
        termination = watcher.flush_and_stop(2)
        self.assertTrue(termination["flushSyncCompleted"])
        observed = []
        while True:
            try:
                kind, value = records.get_nowait()
            except queue.Empty:
                break
            if kind == "record" and isinstance(value, DarwinFSEventRecord):
                observed.append(value)
        pure = [
            record
            for record in observed
            if record.path == str(source) and record.raw_flags == 0x00410000
        ]
        self.assertTrue(pure, observed)
        strict = classify_event(
            plan,
            str(source),
            decode_darwin_flags(pure[0].raw_flags),
        )
        reconciled = _reconcile_item_cloned_event(strict, pure[0], baseline)
        self.assertFalse(reconciled.material)
        self.assertFalse(reconciled.violates)
        self.assertEqual(
            reconciled.clone_reconciliation["status"],
            "clone-observed-no-delta",
        )
        self.assertEqual(
            baseline[source],
            _capture_file_fingerprint(source),
        )

    def test_darwin_unspecified_event_is_material_and_path_scoped(self):
        included = decode_darwin_flags(0)
        self.assertEqual(included, ("FSEventsUnspecified",))
        self.assertTrue(
            classify_event(
                self.plan,
                str(self.root / "lib/input.dart"),
                included,
            ).violates
        )
        ignored = classify_event(
            self.plan,
            str(self.root / "tool/telemetry_memory_rig/__pycache__/x.pyc"),
            included,
        )
        self.assertTrue(ignored.material)
        self.assertFalse(ignored.violates)

    def test_darwin_own_event_source_edit_is_not_suppressed(self):
        events = self.root / "events.jsonl"
        events.touch()
        source = self.root / "lib/input.dart"
        source.write_text("changed", encoding="utf-8")
        source_record = DarwinFSEventRecord(
            path=str(source),
            raw_flags=0x00080000 | 0x00001000 | 0x00010000,
            event_id=99,
            callback_batch_sequence=2,
            callback_record_sequence=3,
        )
        self.assertFalse(
            _is_suppressible_internal_sink_event(
                source_record,
                events.resolve(strict=True),
            )
        )
        classified = _persist_darwin_record(events, self.plan, source_record)
        self.assertTrue(classified.material)
        self.assertTrue(classified.violates)
        ledger = [json.loads(line) for line in events.read_text().splitlines()]
        self.assertEqual(
            [item["recordType"] for item in ledger],
            ["raw-darwin-fsevents", "classified-darwin-fsevents"],
        )

    def test_only_known_nonfatal_own_event_for_sink_is_suppressible(self):
        events = self.root / "events.jsonl"
        events.touch()
        canonical = events.resolve(strict=True)

        def record(flags: int) -> DarwinFSEventRecord:
            return DarwinFSEventRecord(
                path=str(events),
                raw_flags=flags,
                event_id=1,
                callback_batch_sequence=1,
                callback_record_sequence=1,
            )

        self.assertTrue(
            _is_suppressible_internal_sink_event(
                record(0x00080000 | 0x00001000 | 0x00010000),
                canonical,
            )
        )
        self.assertFalse(
            _is_suppressible_internal_sink_event(
                record(0x00001000 | 0x00010000),
                canonical,
            )
        )
        self.assertFalse(
            _is_suppressible_internal_sink_event(
                record(0x00080000 | 0x80000000),
                canonical,
            )
        )
        self.assertFalse(
            _is_suppressible_internal_sink_event(
                record(0x00080000 | 0x00000002),
                canonical,
            )
        )

    def test_native_events_sink_must_be_outside_every_watch_root(self):
        watched_root = self.root / "lib"
        with self.assertRaisesRegex(ValueError, "outside every watch root"):
            _require_native_events_sink_outside_watch_roots(
                watched_root / "events.jsonl",
                (watched_root,),
            )

        evidence = self.root / "evidence"
        evidence.mkdir()
        _require_native_events_sink_outside_watch_roots(
            evidence / "events.jsonl",
            (watched_root,),
        )

    def test_clone_fingerprint_uses_effective_group_writability(self):
        source = self.root / "lib/writable.dart"
        source.write_text("sealed", encoding="utf-8")
        source.chmod(0o664)
        file_gid = source.stat().st_gid
        nonmember_gid = file_gid + 1
        with (
            mock.patch("source_tree_guard.os.getegid", return_value=nonmember_gid),
            mock.patch("source_tree_guard.os.getgroups", return_value=[]),
        ):
            self.assertEqual(
                _capture_file_fingerprint(source).sha256,
                __import__("hashlib").sha256(source.read_bytes()).hexdigest(),
            )
        with (
            mock.patch("source_tree_guard.os.getegid", return_value=file_gid),
            mock.patch("source_tree_guard.os.getgroups", return_value=[]),
        ):
            with self.assertRaisesRegex(ValueError, "unsafe clone-baseline"):
                _capture_file_fingerprint(source)
        with (
            mock.patch("source_tree_guard.os.getegid", return_value=nonmember_gid),
            mock.patch("source_tree_guard.os.getgroups", return_value=[file_gid]),
        ):
            with self.assertRaisesRegex(ValueError, "unsafe clone-baseline"):
                _capture_file_fingerprint(source)

        source.chmod(0o666)
        with (
            mock.patch("source_tree_guard.os.getegid", return_value=nonmember_gid),
            mock.patch("source_tree_guard.os.getgroups", return_value=[]),
        ):
            with self.assertRaisesRegex(ValueError, "unsafe clone-baseline"):
                _capture_file_fingerprint(source)

    def test_sidecar_rejects_symlinked_parent_and_verifies_publication(self):
        real = self.root / "evidence-real"
        real.mkdir(mode=0o700)
        alias = self.root / "evidence-alias"
        alias.symlink_to(real, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlinked.*parent"):
            _write_baseline_sidecar(alias / "baseline.json", {}, self.plan)

        outside = self.root.parent / f"{self.root.name}-sidecar-evidence"
        outside.mkdir(mode=0o700)
        self.addCleanup(outside.rmdir)
        output = outside / "baseline.json"
        self.addCleanup(output.unlink, missing_ok=True)
        canonical, digest, size = _write_baseline_sidecar(
            output, {"version": 1}, self.plan
        )
        self.assertEqual(canonical, output)
        self.assertEqual(size, output.stat().st_size)
        self.assertEqual(
            digest,
            __import__("hashlib").sha256(output.read_bytes()).hexdigest(),
        )
        self.assertEqual(output.stat().st_mode & 0o077, 0)


class SourceTreeGuardProcessTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name).resolve()
        self.toolchain = self.root.parent / f"{self.root.name}-toolchain"
        self.dependency = self.root / "dependency"
        self.toolchain.mkdir()
        for relative in __import__("tree_manifest").TOOLCHAIN_DIRECTORIES:
            (self.toolchain / relative).mkdir(parents=True)
        for relative in __import__("tree_manifest").TOOLCHAIN_FILES:
            path = self.toolchain / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(relative, encoding="utf-8")
        (
            self.toolchain / "packages/flutter_tools/.dart_tool/package_config.json"
        ).write_text(
            json.dumps({"configVersion": 2, "packages": []}),
            encoding="utf-8",
        )
        (self.dependency / "lib").mkdir(parents=True)
        (self.dependency / "lib/dependency.dart").write_text(
            "dependency", encoding="utf-8"
        )
        for directory in (
            "lib",
            "integration_test",
            "test",
            "assets",
            "tool/telemetry_memory_rig",
            "android/app/src",
            "android/gradle/wrapper",
            ".dart_tool",
            "android/gradle",
        ):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        for relative in (
            ".flutter-plugins-dependencies",
            ".metadata",
            "analysis_options.yaml",
            "pubspec.yaml",
            "pubspec.lock",
            "android/app/build.gradle.kts",
            "android/build.gradle.kts",
            "android/gradle.properties",
            "android/local.properties",
            "android/gradlew",
            "android/gradlew.bat",
            "android/settings.gradle.kts",
            "android/gradle/verification-metadata.xml",
            "lib/main.dart",
        ):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            if relative == "android/local.properties":
                path.write_text(f"flutter.sdk={self.toolchain}\n", encoding="utf-8")
            else:
                path.write_text(relative, encoding="utf-8")
        (self.root / ".dart_tool/package_config.json").write_text(
            json.dumps(
                {
                    "configVersion": 2,
                    "packages": [
                        {"name": "app", "rootUri": "../", "packageUri": "lib/"},
                        {
                            "name": "dependency",
                            "rootUri": self.dependency.as_uri(),
                            "packageUri": "lib/",
                        },
                    ],
                }
            ),
            encoding="utf-8",
        )
        (self.root / ".dart_tool/package_graph.json").write_text(
            '{"roots":["app"]}\n',
            encoding="utf-8",
        )
        native = self.root / ".dart_tool/lib/native.dylib"
        native.parent.mkdir()
        native.write_bytes(b"native")
        (self.root / ".dart_tool/native_assets.yaml").write_text(
            json.dumps(
                {
                    "format-version": [1, 0, 0],
                    "native-assets": {
                        "test": {
                            "package:fixture/native.dylib": [
                                "absolute",
                                str(native),
                            ],
                        },
                    },
                }
            ),
            encoding="utf-8",
        )
        self.stop = self.root.parent / f"{self.root.name}.stop"
        self.ready = self.root.parent / f"{self.root.name}.ready.json"
        self.events = self.root.parent / f"{self.root.name}.events.jsonl"
        self.result = self.root.parent / f"{self.root.name}.result.json"
        self.baseline = self.root.parent / f"{self.root.name}.baseline.sha256"
        self.sidecar = self.root.parent / f"{self.root.name}.baseline.json"
        __import__("tree_manifest").write_manifest(self.root, self.baseline)

    def tearDown(self):
        for path in (
            self.stop,
            self.ready,
            self.events,
            self.result,
            self.baseline,
            self.sidecar,
        ):
            path.unlink(missing_ok=True)
        for directory in (self.toolchain,):
            if directory.exists():
                import shutil

                shutil.rmtree(directory)
        self.temp.cleanup()

    def _fake(self, body: str, *, ignore_first_canary: bool = False) -> pathlib.Path:
        path = self.root.parent / f"{self.root.name}-fake-fswatch.py"
        retry_wait = (
            "initial = canary.read_bytes()\n"
            "while canary.exists() and canary.read_bytes() == initial and time.monotonic() < deadline:\n"
            "    time.sleep(0.005)\n"
            if ignore_first_canary
            else ""
        )
        created_flag = "Updated" if ignore_first_canary else "Created"
        handshake = (
            "import os, pathlib, sys, time\n"
            "tool = next(pathlib.Path(value) for value in sys.argv[1:] "
            "if value.endswith('tool/telemetry_memory_rig'))\n"
            "deadline = time.monotonic() + 3\n"
            "matches = []\n"
            "while not matches and time.monotonic() < deadline:\n"
            "    matches = list((tool / '__pycache__').glob('source-tree-guard-canary-*.pyc'))\n"
            "    time.sleep(0.005)\n"
            "if not matches: raise SystemExit('canary not created')\n"
            "canary = matches[0]\n"
            + retry_wait
            + f"os.write(sys.stdout.fileno(), str(canary).encode() + b'\\t{created_flag} IsFile\\0')\n"
            "while canary.exists() and time.monotonic() < deadline: time.sleep(0.005)\n"
            "os.write(sys.stdout.fileno(), str(canary).encode() + b'\\tRemoved IsFile\\0')\n"
        )
        path.write_text("#!/usr/bin/env python3\n" + handshake + body, encoding="utf-8")
        path.chmod(0o755)
        self.addCleanup(path.unlink, missing_ok=True)
        return path

    def _command(self, fake: pathlib.Path, timeout: str = "0.2") -> list[str]:
        return [
            sys.executable,
            str(GUARD),
            "--root",
            str(self.root),
            "--fswatch",
            str(fake),
            "--stop-file",
            str(self.stop),
            "--ready-file",
            str(self.ready),
            "--events-file",
            str(self.events),
            "--result-file",
            str(self.result),
            "--baseline-manifest",
            str(self.baseline),
            "--baseline-sidecar",
            str(self.sidecar),
            "--stop-timeout-seconds",
            timeout,
            "--nonce",
            NONCE,
        ]

    def _native_command(self) -> list[str]:
        return [
            sys.executable,
            str(GUARD),
            "--backend",
            "darwin-fsevents",
            "--root",
            str(self.root),
            "--stop-file",
            str(self.stop),
            "--ready-file",
            str(self.ready),
            "--events-file",
            str(self.events),
            "--result-file",
            str(self.result),
            "--baseline-manifest",
            str(self.baseline),
            "--baseline-sidecar",
            str(self.sidecar),
            "--stop-timeout-seconds",
            "1",
            "--nonce",
            NONCE,
        ]

    def test_manifest_sidecar_accepts_exact_external_member_and_binds_event(self):
        plan = build_watch_plan(self.root)
        baseline = _load_manifest_clone_baseline(
            plan,
            self.baseline,
            self.sidecar,
        )
        source = self.dependency / "lib/dependency.dart"
        record = baseline.records[source]
        self.assertEqual(record.event_scope, "external-package")
        self.assertEqual(
            [entry.logical_id for entry in record.manifest_entries],
            ["@package/dependency/lib/dependency.dart"],
        )
        raw = DarwinFSEventRecord(str(source), 0x00410000, 1, 1, 1)
        event = classify_event(plan, str(source), decode_darwin_flags(raw.raw_flags))
        reconciled = _reconcile_item_cloned_event(event, raw, baseline.records)
        self.assertFalse(reconciled.violates)
        self.assertEqual(
            reconciled.clone_reconciliation["baselineCanonicalPath"],
            str(source),
        )
        self.assertEqual(
            reconciled.clone_reconciliation["baselineManifestEntries"],
            [entry.to_json() for entry in record.manifest_entries],
        )

        sidecar = json.loads(self.sidecar.read_text(encoding="utf-8"))
        self.assertEqual(sidecar["version"], 1)
        self.assertEqual(sidecar["policy"], "sealed-manifest-pure-item-cloned-v2")
        self.assertEqual(
            sidecar["manifestEntryCount"],
            sum(sidecar["namespaceEntryCounts"].values()),
        )
        self.assertEqual(sidecar["uniqueRegularFileCount"], len(sidecar["records"]))

    def test_manifest_sidecar_rejects_unmanifested_and_changed_external_files(self):
        plan = build_watch_plan(self.root)
        baseline = _load_manifest_clone_baseline(
            plan,
            self.baseline,
            self.sidecar,
        )
        new_file = self.dependency / "lib/new.dart"
        new_file.write_text("new", encoding="utf-8")
        raw = DarwinFSEventRecord(str(new_file), 0x00410000, 1, 1, 1)
        event = classify_event(plan, str(new_file), decode_darwin_flags(raw.raw_flags))
        missing = _reconcile_item_cloned_event(event, raw, baseline.records)
        self.assertTrue(missing.violates)
        self.assertEqual(
            missing.clone_reconciliation["status"], "clone-baseline-missing"
        )

        source = self.dependency / "lib/dependency.dart"
        source.write_text("changed", encoding="utf-8")
        changed_raw = dataclasses.replace(raw, path=str(source))
        changed_event = classify_event(
            plan, str(source), decode_darwin_flags(changed_raw.raw_flags)
        )
        changed = _reconcile_item_cloned_event(
            changed_event, changed_raw, baseline.records
        )
        self.assertTrue(changed.violates)
        self.assertEqual(changed.clone_reconciliation["status"], "clone-observed-delta")

    def test_manifest_sidecar_rejects_conflicting_alias_digests_and_caps(self):
        import source_tree_guard as guard

        plan = build_watch_plan(self.root)
        source = self.root / "lib/main.dart"
        binding_type = __import__("tree_manifest").ManifestPathBinding
        digest = __import__("hashlib").sha256(source.read_bytes()).hexdigest()
        conflicting = "0" * 64 if digest != "0" * 64 else "1" * 64
        alias_manifest = self.root.parent / f"{self.root.name}.aliases.sha256"
        alias_sidecar = self.root.parent / f"{self.root.name}.aliases.json"
        self.addCleanup(alias_manifest.unlink, missing_ok=True)
        self.addCleanup(alias_sidecar.unlink, missing_ok=True)
        alias_manifest.write_text(
            f"{digest}  alias-a\n{conflicting}  alias-b\n",
            encoding="utf-8",
        )
        bindings = [
            binding_type("alias-a", source, "local"),
            binding_type("alias-b", source, "local"),
        ]
        with mock.patch.object(
            guard.tree_manifest,
            "collect_manifest_path_bindings",
            return_value=bindings,
        ):
            with self.assertRaisesRegex(ValueError, "conflicting.*alias"):
                _load_manifest_clone_baseline(plan, alias_manifest, alias_sidecar)

        with mock.patch.object(guard, "MAX_BASELINE_MANIFEST_ENTRIES", 1):
            with self.assertRaisesRegex(ValueError, "entry bound"):
                _load_manifest_clone_baseline(plan, self.baseline, alias_sidecar)
        with mock.patch.object(guard, "MAX_BASELINE_UNIQUE_FILE_BYTES", 0):
            with self.assertRaisesRegex(ValueError, "unique content"):
                _load_manifest_clone_baseline(plan, self.baseline, alias_sidecar)
        with mock.patch.object(guard, "MAX_BASELINE_XATTR_BYTES", -1):
            with self.assertRaisesRegex(ValueError, "xattrs"):
                _load_manifest_clone_baseline(plan, self.baseline, alias_sidecar)
        with mock.patch.object(guard, "MAX_BASELINE_SIDECAR_BYTES", 1):
            with self.assertRaisesRegex(ValueError, "sidecar exceeds"):
                _load_manifest_clone_baseline(plan, self.baseline, alias_sidecar)

    def test_clone_queued_during_capture_fails_before_ready_without_reconciliation(
        self,
    ):
        import source_tree_guard as guard

        plan = build_watch_plan(self.root)
        source = self.root / "lib/main.dart"
        fingerprint = _capture_file_fingerprint(source)
        logical = BaselineManifestEntry("lib/main.dart", "local", fingerprint.sha256)
        baseline_record = CloneBaselineRecord(
            source,
            "local-directory",
            (logical,),
            fingerprint,
        )
        captured = CloneBaseline(
            records={source: baseline_record},
            manifest_sha256="a" * 64,
            sidecar_path=self.sidecar,
            sidecar_sha256="b" * 64,
            sidecar_bytes=1,
            manifest_entry_count=1,
            unique_regular_file_bytes=fingerprint.size,
            total_xattr_bytes=0,
            namespace_entry_counts={"local": 1},
            event_scope_file_counts={"local-directory": 1},
        )

        class FakeNativeWatcher:
            def __init__(self, _paths, records):
                self.records = records

            @property
            def pid(self):
                return os.getpid()

            def start(self, _timeout):
                canary = (
                    self_outer.root
                    / "tool/telemetry_memory_rig/__pycache__"
                    / f"source-tree-guard-canary-{NONCE}.pyc"
                )
                self.records.put(
                    (
                        "record",
                        DarwinFSEventRecord(str(canary), 0x00010100, 1, 1, 1),
                    )
                )
                self.records.put(
                    (
                        "record",
                        DarwinFSEventRecord(str(canary), 0x00010200, 2, 1, 2),
                    )
                )

            def poll(self):
                return None

            def flush_and_stop(self, _timeout):
                self.records.put(("drained", None))
                return {
                    "termSent": False,
                    "killSent": False,
                    "exitCode": 0,
                    "contained": True,
                    "flushSyncRequested": True,
                    "flushSyncCompleted": True,
                    "drainedSentinelEmitted": True,
                }

        self_outer = self

        def capture_with_queued_clone(*_args, **_kwargs):
            watcher = fake_instances[-1]
            watcher.records.put(
                (
                    "record",
                    DarwinFSEventRecord(str(source), 0x00410000, 3, 2, 1),
                )
            )
            return captured

        fake_instances = []

        class RecordingFakeNativeWatcher(FakeNativeWatcher):
            def __init__(self, paths, records):
                super().__init__(paths, records)
                fake_instances.append(self)

        with (
            mock.patch.object(
                guard, "DarwinFSEventsWatcher", RecordingFakeNativeWatcher
            ),
            mock.patch.object(
                guard,
                "_load_manifest_clone_baseline",
                side_effect=capture_with_queued_clone,
            ),
        ):
            result_code = run_guard(
                plan=plan,
                fswatch=None,
                backend="darwin-fsevents",
                stop_file=self.stop,
                ready_file=self.ready,
                events_file=self.events,
                result_file=self.result,
                baseline_manifest=self.baseline,
                baseline_sidecar=self.sidecar,
                stop_timeout_seconds=0.2,
                nonce=NONCE,
            )
        self.assertEqual(result_code, 2)
        self.assertFalse(self.ready.exists())
        result = json.loads(self.result.read_text(encoding="utf-8"))
        self.assertFalse(result["readyWritten"])
        self.assertEqual(result["status"], "guard-error")
        self.assertIn("during baseline capture", result["guardError"])
        classified = [
            json.loads(line)
            for line in self.events.read_text(encoding="utf-8").splitlines()
            if '"recordType": "classified-darwin-fsevents"' in line
        ]
        clone = next(item for item in classified if item["path"] == str(source))
        self.assertTrue(clone["material"])
        self.assertTrue(clone["violates"])
        self.assertEqual(
            clone["cloneReconciliation"]["status"],
            "clone-baseline-missing",
        )

    def test_fake_fswatch_transient_event_fails_and_is_persisted(self):
        changed = self.root / "lib/main.dart"
        unchanged_contents = changed.read_text(encoding="utf-8")
        fake = self._fake(
            "import os, sys, time\n"
            "time.sleep(0.6)\n"
            f"os.write(sys.stdout.fileno(), {str(changed)!r}.encode() + b'\\tUpdated IsFile\\0')\n"
            "time.sleep(60)\n"
        )
        completed = subprocess.run(
            self._command(fake), capture_output=True, text=True, timeout=5
        )
        self.assertEqual(completed.returncode, 2, completed.stderr)
        result = json.loads(self.result.read_text(encoding="utf-8"))
        self.assertEqual(result["watcherBackend"], "fswatch")
        self.assertEqual(result["status"], "source-changed")
        self.assertEqual(result["violatingEventCount"], 1)
        event = json.loads(self.events.read_text(encoding="utf-8").strip())
        self.assertTrue(event["violates"])
        self.assertEqual(changed.read_text(encoding="utf-8"), unchanged_contents)

    def test_global_integrity_failure_on_ignored_path_is_guard_error(self):
        ignored = self.dependency / "gradle/.kotlin/sessions/kotlin-compiler-1.salive"
        for flags, expected in (
            ("Overflow NoOp", "overflow"),
            ("PlatformSpecific AttributeModified", "integrity"),
        ):
            with self.subTest(flags=flags):
                fake = self._fake(
                    f"os.write(sys.stdout.fileno(), {str(ignored)!r}.encode() "
                    f"+ b'\\t{flags}\\0')\n"
                )
                completed = subprocess.run(
                    self._command(fake),
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
                self.assertEqual(completed.returncode, 2, completed.stderr)
                result = json.loads(self.result.read_text(encoding="utf-8"))
                self.assertEqual(result["status"], "guard-error")
                self.assertIn(expected, result["guardError"].lower())
                self.assertEqual(result["violatingEventCount"], 0)
                self.events.unlink()
                self.result.unlink()

    def test_stop_control_kills_term_ignoring_fswatch_with_bounded_wait(self):
        child_ready = self.root.parent / f"{self.root.name}.child-ready"
        self.addCleanup(child_ready.unlink, missing_ok=True)
        fake = self._fake(
            "import pathlib, signal, time\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            f"pathlib.Path({str(child_ready)!r}).write_text('ready')\n"
            "while True: time.sleep(1)\n"
        )
        process = subprocess.Popen(
            self._command(fake, "0.15"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            deadline = time.monotonic() + 3
            while (
                (not self.ready.exists() or not child_ready.exists())
                and process.poll() is None
                and time.monotonic() < deadline
            ):
                time.sleep(0.02)
            self.assertTrue(self.ready.exists(), "guard never became ready")
            self.assertTrue(
                child_ready.exists(), "fake fswatch never installed its TERM handler"
            )
            self.stop.write_text("stop\n", encoding="utf-8")
            stdout, stderr = process.communicate(timeout=3)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=1)
        self.assertEqual(process.returncode, 0, f"{stdout}\n{stderr}")
        result = json.loads(self.result.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "stopped")
        self.assertTrue(result["watcherTermination"]["termSent"])
        self.assertTrue(result["watcherTermination"]["killSent"])
        self.assertTrue(result["watcherTermination"]["contained"])
        self.assertEqual(result["nonce"], NONCE)
        ready = json.loads(self.ready.read_text(encoding="utf-8"))
        self.assertEqual(ready["nonce"], NONCE)
        self.assertEqual(ready["watcherBackend"], "fswatch")
        self.assertTrue(ready["canaryCreatedObserved"])
        self.assertTrue(ready["canaryRemovedObserved"])

    def test_canary_retries_when_watcher_ignores_first_creation(self):
        fake = self._fake("time.sleep(60)\n", ignore_first_canary=True)
        process = subprocess.Popen(
            self._command(fake),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        deadline = time.monotonic() + 4
        while (
            not self.ready.exists()
            and process.poll() is None
            and time.monotonic() < deadline
        ):
            time.sleep(0.01)
        self.assertTrue(self.ready.exists(), "guard did not retry its canary")
        ready = json.loads(self.ready.read_text(encoding="utf-8"))
        self.assertTrue(ready["canaryCreatedObserved"])
        self.assertTrue(ready["canaryRemovedObserved"])
        self.assertGreaterEqual(ready["canaryWriteAttemptCount"], 2)
        self.stop.write_text("stop\n", encoding="utf-8")
        stdout, stderr = process.communicate(timeout=4)
        self.assertEqual(process.returncode, 0, f"{stdout}\n{stderr}")

    def test_event_emitted_just_after_stop_creation_is_not_missed(self):
        changed = self.root / "lib/main.dart"
        fake = self._fake(
            f"stop = pathlib.Path({str(self.stop)!r})\n"
            "while not stop.exists(): time.sleep(0.005)\n"
            "time.sleep(0.05)\n"
            f"os.write(sys.stdout.fileno(), {str(changed)!r}.encode() + b'\\tUpdated IsFile\\0')\n"
            "time.sleep(60)\n"
        )
        process = subprocess.Popen(
            self._command(fake),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        deadline = time.monotonic() + 4
        while (
            not self.ready.exists()
            and process.poll() is None
            and time.monotonic() < deadline
        ):
            time.sleep(0.01)
        self.assertTrue(self.ready.exists(), "guard never became ready")
        self.stop.write_text("stop\n", encoding="utf-8")
        stdout, stderr = process.communicate(timeout=4)
        self.assertEqual(process.returncode, 2, f"{stdout}\n{stderr}")
        result = json.loads(self.result.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "source-changed")
        self.assertEqual(result["violatingEventCount"], 1)
        self.assertIsNotNone(result["stopRequestedEpochUs"])

    def test_stale_outputs_are_rejected_without_overwrite(self):
        self.ready.write_text("stale\n", encoding="utf-8")
        fake = self._fake("time.sleep(60)\n")
        completed = subprocess.run(
            self._command(fake), capture_output=True, text=True, timeout=3
        )
        self.assertEqual(completed.returncode, 3)
        self.assertIn("stale guard output exists", completed.stderr)
        self.assertEqual(self.ready.read_text(encoding="utf-8"), "stale\n")
        self.assertFalse(self.events.exists())
        self.assertFalse(self.result.exists())

    def test_watcher_eof_and_stderr_fail_closed(self):
        fake = self._fake(
            "sys.stderr.write('synthetic watcher failure\\n')\nsys.stderr.flush()\n"
        )
        completed = subprocess.run(
            self._command(fake), capture_output=True, text=True, timeout=4
        )
        self.assertEqual(completed.returncode, 2, completed.stderr)
        result = json.loads(self.result.read_text(encoding="utf-8"))
        self.assertNotEqual(result["status"], "stopped")
        self.assertIn("synthetic watcher failure", result["watcherStderr"])

    def test_partial_record_flushed_by_sigterm_fails_closed(self):
        changed = self.root / "lib/main.dart"
        fake = self._fake(
            "import signal\n"
            "def flush_partial_and_exit(_signum, _frame):\n"
            f"    os.write(sys.stdout.fileno(), {str(changed)!r}.encode() + b'\\tUp')\n"
            "    os._exit(0)\n"
            "signal.signal(signal.SIGTERM, flush_partial_and_exit)\n"
            "while True: time.sleep(1)\n"
        )
        process = subprocess.Popen(
            self._command(fake),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        deadline = time.monotonic() + 4
        while (
            not self.ready.exists()
            and process.poll() is None
            and time.monotonic() < deadline
        ):
            time.sleep(0.01)
        self.assertTrue(self.ready.exists(), "guard never became ready")
        self.stop.write_text("stop\n", encoding="utf-8")
        stdout, stderr = process.communicate(timeout=4)
        self.assertEqual(process.returncode, 2, f"{stdout}\n{stderr}")
        result = json.loads(self.result.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "guard-error")
        self.assertIn("unterminated fswatch record at EOF", result["guardError"])
        self.assertEqual(result["violatingEventCount"], 0)

    def test_stop_requested_before_ready_fails_closed(self):
        fake = self._fake("time.sleep(60)\n")
        process = subprocess.Popen(
            self._command(fake),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        deadline = time.monotonic() + 2
        while (
            not self.events.exists()
            and process.poll() is None
            and time.monotonic() < deadline
        ):
            time.sleep(0.005)
        self.assertTrue(self.events.exists(), "guard did not start")
        self.stop.write_text("stop\n", encoding="utf-8")
        stdout, stderr = process.communicate(timeout=4)
        self.assertEqual(process.returncode, 2, f"{stdout}\n{stderr}")
        result = json.loads(self.result.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "stop-requested-before-ready")
        self.assertFalse(result["readyWritten"])

    def test_sigterm_after_ready_is_failure_not_clean_stop(self):
        fake = self._fake("time.sleep(60)\n")
        process = subprocess.Popen(
            self._command(fake),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        deadline = time.monotonic() + 4
        while (
            not self.ready.exists()
            and process.poll() is None
            and time.monotonic() < deadline
        ):
            time.sleep(0.01)
        self.assertTrue(self.ready.exists(), "guard never became ready")
        process.terminate()
        stdout, stderr = process.communicate(timeout=4)
        self.assertEqual(process.returncode, 2, f"{stdout}\n{stderr}")
        result = json.loads(self.result.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "guard-terminated")
        self.assertIsNone(result["stopRequestedEpochUs"])

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS FSEvents")
    def test_native_darwin_backend_observes_cloned_included_file(self):
        # Force setup-time create/modify flags into an earlier native clone
        # event so the guarded operation observes a pure clone-source hint.
        source = self.root / "lib/main.dart"
        warmup = self.root.parent / f"{self.root.name}-warmup-clone"
        completed = subprocess.run(
            ["cp", "-c", str(source), str(warmup)],
            capture_output=True,
            text=True,
        )
        if completed.returncode != 0:
            self.skipTest(f"APFS clone unavailable: {completed.stderr}")
        warmup.unlink()
        time.sleep(0.4)
        process = subprocess.Popen(
            self._native_command(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            deadline = time.monotonic() + 8
            while (
                not self.ready.exists()
                and process.poll() is None
                and time.monotonic() < deadline
            ):
                time.sleep(0.02)
            self.assertTrue(self.ready.exists(), "native guard never became ready")
            clone = self.root / "lib/cloned.dart"
            completed = subprocess.run(
                ["cp", "-c", str(source), str(clone)],
                capture_output=True,
                text=True,
            )
            if completed.returncode != 0:
                self.skipTest(f"APFS clone unavailable: {completed.stderr}")
            stdout, stderr = process.communicate(timeout=8)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=2)
        self.assertEqual(process.returncode, 2, f"{stdout}\n{stderr}")
        result = json.loads(self.result.read_text(encoding="utf-8"))
        self.assertEqual(result["watcherBackend"], "darwin-fsevents")
        self.assertEqual(result["status"], "source-changed")
        self.assertTrue(result["watcherTermination"]["flushSyncRequested"])
        self.assertTrue(result["watcherTermination"]["flushSyncCompleted"])
        self.assertTrue(result["watcherTermination"]["drainedSentinelObserved"])
        self.assertTrue(result["watcherTermination"]["contained"])
        self.assertGreater(result["rawCallbackRecordCount"], 0)
        self.assertEqual(result["fatalRawRecordCount"], 0)
        self.assertEqual(
            result["rawCallbackRecordCount"],
            result["classifiedEventCount"],
        )
        records = [
            json.loads(line)
            for line in self.events.read_text(encoding="utf-8").splitlines()
        ]
        raw = [
            item for item in records if item.get("recordType") == "raw-darwin-fsevents"
        ]
        classified = [
            item
            for item in records
            if item.get("recordType") == "classified-darwin-fsevents"
        ]
        self.assertEqual(len(raw), result["rawCallbackRecordCount"])
        self.assertEqual(len(classified), result["classifiedEventCount"])
        self.assertEqual(result["fatalRawRecordCount"], len(raw) - len(classified))
        source_clone_raw = [
            item
            for item in raw
            if item["path"] == str(source) and item["rawFlags"] & 0x00400000
        ]
        self.assertTrue(
            source_clone_raw,
            "clone source event omitted ItemCloned raw bit",
        )
        selected = source_clone_raw[0]
        source_paired = [
            item
            for item in classified
            if item["callbackBatchSequence"] == selected["callbackBatchSequence"]
            and item["callbackRecordSequence"] == selected["callbackRecordSequence"]
        ]
        self.assertEqual(len(source_paired), 1)
        self.assertIn("ItemCloned", source_paired[0]["flags"])
        if source_paired[0]["flags"] == ["IsFile", "ItemCloned"]:
            self.assertFalse(source_paired[0]["material"], source_paired[0])
            self.assertFalse(source_paired[0]["violates"])
            self.assertEqual(
                source_paired[0]["cloneReconciliation"]["status"],
                "clone-observed-no-delta",
            )

        destination_paired = [
            item
            for item in classified
            if item["path"] == str(clone) and "ItemCloned" in item["flags"]
        ]
        self.assertTrue(destination_paired)
        self.assertTrue(any(item["material"] for item in destination_paired))
        self.assertTrue(any(item["violates"] for item in destination_paired))
        self.assertGreaterEqual(result["cloneObservedNoDeltaEventCount"], 0)

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS FSEvents")
    def test_native_darwin_backend_watches_parent_of_exact_file(self):
        process = subprocess.Popen(
            self._native_command(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            deadline = time.monotonic() + 8
            while (
                not self.ready.exists()
                and process.poll() is None
                and time.monotonic() < deadline
            ):
                time.sleep(0.02)
            self.assertTrue(self.ready.exists(), "native guard never became ready")
            ready = json.loads(self.ready.read_text(encoding="utf-8"))
            self.assertIn(str(self.root), ready["nativeFSEventsWatchRoots"])
            exact = self.root / "pubspec.yaml"
            original = exact.read_text(encoding="utf-8")
            exact.write_text("changed", encoding="utf-8")
            exact.write_text(original, encoding="utf-8")
            stdout, stderr = process.communicate(timeout=8)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=2)
        self.assertEqual(process.returncode, 2, f"{stdout}\n{stderr}")
        result = json.loads(self.result.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "source-changed")
        records = [json.loads(line) for line in self.events.read_text().splitlines()]
        classified = [
            item
            for item in records
            if item.get("recordType") == "classified-darwin-fsevents"
            and item["path"] == str(exact)
        ]
        self.assertTrue(classified)
        self.assertTrue(classified[-1]["violates"])
        self.assertEqual(exact.read_text(encoding="utf-8"), original)

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS FSEvents")
    def test_native_darwin_clean_stop_has_flush_and_drain_proof(self):
        process = subprocess.Popen(
            self._native_command(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            deadline = time.monotonic() + 8
            while (
                not self.ready.exists()
                and process.poll() is None
                and time.monotonic() < deadline
            ):
                time.sleep(0.02)
            self.assertTrue(self.ready.exists(), "native guard never became ready")
            ready = json.loads(self.ready.read_text(encoding="utf-8"))
            self.stop.write_text("stop\n", encoding="utf-8")
            stdout, stderr = process.communicate(timeout=8)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=2)
        self.assertEqual(process.returncode, 0, f"{stdout}\n{stderr}")
        result = json.loads(self.result.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "stopped")
        sidecar_bytes = self.sidecar.read_bytes()
        sidecar = json.loads(sidecar_bytes)
        self.assertEqual(ready["version"], 3)
        self.assertEqual(result["version"], 3)
        attestation_fields = (
            "baselineManifestPath",
            "baselineManifestSha256",
            "baselineSidecarPath",
            "baselineSidecarSha256",
            "baselineSidecarBytes",
            "baselineManifestEntryCount",
            "baselineUniqueRegularFileCount",
            "baselineUniqueRegularFileBytes",
            "baselineTotalXattrBytes",
            "baselineNamespaceEntryCounts",
            "baselineEventScopeFileCounts",
        )
        for field in attestation_fields:
            self.assertEqual(ready[field], result[field], field)
        expected_attestation = {
            "baselineManifestPath": sidecar["manifestPath"],
            "baselineManifestSha256": sidecar["manifestSha256"],
            "baselineSidecarPath": str(self.sidecar),
            "baselineSidecarSha256": __import__("hashlib")
            .sha256(sidecar_bytes)
            .hexdigest(),
            "baselineSidecarBytes": len(sidecar_bytes),
            "baselineManifestEntryCount": sidecar["manifestEntryCount"],
            "baselineUniqueRegularFileCount": sidecar["uniqueRegularFileCount"],
            "baselineUniqueRegularFileBytes": sidecar["uniqueRegularFileBytes"],
            "baselineTotalXattrBytes": sidecar["totalXattrBytes"],
            "baselineNamespaceEntryCounts": sidecar["namespaceEntryCounts"],
            "baselineEventScopeFileCounts": sidecar["eventScopeFileCounts"],
        }
        for field, expected in expected_attestation.items():
            self.assertEqual(ready[field], expected, field)
        self.assertEqual(ready["cloneReconciliationPolicy"], sidecar["policy"])
        self.assertEqual(result["cloneReconciliationPolicy"], sidecar["policy"])
        termination = result["watcherTermination"]
        self.assertTrue(termination["flushSyncRequested"])
        self.assertTrue(termination["flushSyncCompleted"])
        self.assertTrue(termination["drainedSentinelEmitted"])
        self.assertTrue(termination["drainedSentinelObserved"])
        self.assertTrue(termination["contained"])
        self.assertEqual(termination["exitCode"], 0)
        records = [json.loads(line) for line in self.events.read_text().splitlines()]
        raw_count = sum(
            item.get("recordType") == "raw-darwin-fsevents" for item in records
        )
        classified_count = sum(
            item.get("recordType") == "classified-darwin-fsevents" for item in records
        )
        self.assertEqual(result["rawCallbackRecordCount"], raw_count)
        self.assertEqual(result["classifiedEventCount"], classified_count)
        self.assertEqual(
            result["fatalRawRecordCount"],
            raw_count - classified_count,
        )

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS FSEvents")
    def test_two_overlapping_native_guards_with_external_ledgers_both_quiesce(self):
        controls = []
        processes = []
        for index, nonce in enumerate(("a" * 32, "b" * 32), 1):
            prefix = self.root.parent / f"{self.root.name}-overlap-{index}"
            stop = pathlib.Path(f"{prefix}.stop")
            ready = pathlib.Path(f"{prefix}.ready.json")
            events = pathlib.Path(f"{prefix}.events.jsonl")
            result = pathlib.Path(f"{prefix}.result.json")
            sidecar = pathlib.Path(f"{prefix}.baseline.json")
            controls.append((stop, ready, events, result, sidecar))
            for path in controls[-1]:
                self.addCleanup(path.unlink, missing_ok=True)
            command = [
                sys.executable,
                str(GUARD),
                "--backend",
                "darwin-fsevents",
                "--root",
                str(self.root),
                "--stop-file",
                str(stop),
                "--ready-file",
                str(ready),
                "--events-file",
                str(events),
                "--result-file",
                str(result),
                "--baseline-manifest",
                str(self.baseline),
                "--baseline-sidecar",
                str(sidecar),
                "--stop-timeout-seconds",
                "1",
                "--nonce",
                nonce,
            ]
            processes.append(
                subprocess.Popen(
                    command,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
            )
        try:
            deadline = time.monotonic() + 10
            while (
                not all(ready.exists() for _, ready, _, _, _ in controls)
                and all(process.poll() is None for process in processes)
                and time.monotonic() < deadline
            ):
                time.sleep(0.02)
            self.assertTrue(
                all(ready.exists() for _, ready, _, _, _ in controls),
                "overlapping native guards did not both become ready",
            )
            for stop, _, _, _, _ in controls:
                stop.write_text("stop\n", encoding="utf-8")
            outputs = [process.communicate(timeout=8) for process in processes]
        finally:
            for process in processes:
                if process.poll() is None:
                    process.kill()
                    process.communicate(timeout=2)
        for process, output, (_, _, _, result_path, _) in zip(
            processes,
            outputs,
            controls,
        ):
            stdout, stderr = output
            self.assertEqual(process.returncode, 0, f"{stdout}\n{stderr}")
            result = json.loads(result_path.read_text(encoding="utf-8"))
            self.assertEqual(result["status"], "stopped")
            self.assertEqual(
                result["rawCallbackRecordCount"],
                result["classifiedEventCount"],
            )

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS FSEvents")
    def test_native_sink_inside_exact_file_parent_is_rejected(self):
        self.events = self.root / "native-events.jsonl"
        process = subprocess.Popen(
            self._native_command(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        stdout, stderr = process.communicate(timeout=8)
        self.assertNotEqual(process.returncode, 0, f"{stdout}\n{stderr}")
        self.assertIn(
            "native FSEvents ledger must be outside every watch root",
            stderr,
        )
        self.assertFalse(self.ready.exists())
        self.assertFalse(self.result.exists())


if __name__ == "__main__":
    unittest.main()
