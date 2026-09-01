import json
import hashlib
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from tree_manifest import (
    TOOLCHAIN_DIRECTORIES,
    TOOLCHAIN_FILES,
    build_entries,
    android_sdk_root,
    clean_external_native_build_caches,
    clean_flutter_gradle_generated_state,
    collect_manifest_path_bindings,
    collect_paths,
    flutter_sdk_root,
    verify_native_cache_freshness,
    verify_manifest,
    write_manifest,
)


class TreeManifestTest(unittest.TestCase):
    def test_engine_realm_is_a_sealed_toolchain_input(self):
        self.assertIn("bin/cache/engine.realm", TOOLCHAIN_FILES)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name).resolve()
        self.cache_temp = tempfile.TemporaryDirectory()
        self.pub_cache = pathlib.Path(self.cache_temp.name).resolve()
        self.dependency = self.pub_cache / "hosted/pub.dev/dependency-1.0.0"
        self.dependency.mkdir(parents=True)
        self.tool_dependency = self.pub_cache / "hosted/pub.dev/tool_dependency-1.0.0"
        self.tool_dependency.mkdir(parents=True)
        self.flutter_temp = tempfile.TemporaryDirectory()
        self.flutter = pathlib.Path(self.flutter_temp.name).resolve()
        self.environment = mock.patch.dict(
            os.environ,
            {"PUB_CACHE": str(self.pub_cache)},
        )
        self.environment.start()
        for directory in (
            "lib/core",
            "integration_test",
            "test",
            "assets",
            "tool/telemetry_memory_rig",
            "android/app/src/main/kotlin",
            "android/gradle/wrapper",
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
            "android/gradle/verification-metadata.xml",
            "android/local.properties",
            "android/gradlew",
            "android/gradlew.bat",
            "android/settings.gradle.kts",
            "android/gradle/wrapper/gradle-wrapper.properties",
            "lib/main.dart",
            "lib/core/transitive_bridge.dart",
            "integration_test/rig_test.dart",
            "test/rig_contract_test.dart",
            "assets/icon.png",
            "tool/telemetry_memory_rig/run.sh",
            "android/app/src/main/AndroidManifest.xml",
            "android/app/src/main/kotlin/MainActivity.kt",
        ):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(relative, encoding="utf-8")
        (self.root / "android/local.properties").write_text(
            f"flutter.sdk={self.flutter}\nsdk.dir={self.root / 'android-sdk'}\n",
            encoding="utf-8",
        )
        (self.root / "android-sdk").mkdir()
        for relative in TOOLCHAIN_FILES:
            path = self.flutter / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(relative, encoding="utf-8")
        for relative in TOOLCHAIN_DIRECTORIES:
            directory = self.flutter / relative
            directory.mkdir(parents=True, exist_ok=True)
            (directory / "captured.input").write_text(relative, encoding="utf-8")
        gradle_input = self.flutter / "packages/flutter_tools/gradle/captured.input"
        gradle_input.parent.mkdir(parents=True, exist_ok=True)
        gradle_input.write_text("gradle", encoding="utf-8")
        tool_package_config = (
            self.flutter / "packages/flutter_tools/.dart_tool/package_config.json"
        )
        tool_package_config.write_text(
            json.dumps(
                {
                    "configVersion": 2,
                    "packages": [
                        {
                            "name": "tool_dependency",
                            "rootUri": self.tool_dependency.as_uri(),
                            "packageUri": "lib/",
                        },
                    ],
                },
                separators=(",", ":"),
            ),
            encoding="utf-8",
        )
        (self.root / ".dart_tool").mkdir(exist_ok=True)
        native_lib = self.root / ".dart_tool/lib/native.dylib"
        native_lib.parent.mkdir()
        native_lib.write_bytes(b"native")
        (self.root / ".dart_tool/native_assets.yaml").write_text(
            json.dumps(
                {
                    "format-version": [1, 0, 0],
                    "native-assets": {
                        "macos_arm64": {
                            "package:fixture/native.dylib": [
                                "absolute",
                                str(native_lib),
                            ],
                        },
                    },
                }
            ),
            encoding="utf-8",
        )
        (self.dependency / "lib").mkdir()
        (self.dependency / "lib/dependency.dart").write_text(
            "dependency", encoding="utf-8"
        )
        (self.dependency / "pubspec.yaml").write_text(
            "name: dependency\n", encoding="utf-8"
        )
        (self.tool_dependency / "lib").mkdir()
        (self.tool_dependency / "lib/tool_dependency.dart").write_text(
            "tool dependency",
            encoding="utf-8",
        )
        (self.tool_dependency / "pubspec.yaml").write_text(
            "name: tool_dependency\n",
            encoding="utf-8",
        )
        self.write_package_config(self.dependency.as_uri())
        (self.root / ".dart_tool/package_graph.json").write_text(
            '{"roots":["app"]}\n',
            encoding="utf-8",
        )
        self.manifest = self.root.parent / f"{self.root.name}.manifest"

    def write_package_config(self, dependency_uri: str):
        (self.root / ".dart_tool/package_config.json").write_text(
            json.dumps(
                {
                    "configVersion": 2,
                    "packages": [
                        {
                            "name": "app",
                            "rootUri": "../",
                            "packageUri": "lib/",
                        },
                        {
                            "name": "dependency",
                            "rootUri": dependency_uri,
                            "packageUri": "lib/",
                        },
                    ],
                },
                separators=(",", ":"),
            ),
            encoding="utf-8",
        )

    def tearDown(self):
        self.manifest.unlink(missing_ok=True)
        self.environment.stop()
        self.flutter_temp.cleanup()
        self.cache_temp.cleanup()
        self.temp.cleanup()

    def test_complete_android_rig_input_set_verifies(self):
        write_manifest(self.root, self.manifest)
        verify_manifest(self.root, self.manifest)
        paths = {
            path.relative_to(self.root).as_posix() for path in collect_paths(self.root)
        }
        self.assertIn("lib/core/transitive_bridge.dart", paths)
        self.assertIn("android/app/src/main/kotlin/MainActivity.kt", paths)
        self.assertIn("assets/icon.png", paths)
        self.assertIn("pubspec.lock", paths)
        entry_paths = {relative for _, relative in build_entries(self.root)}
        self.assertIn("@package/dependency/lib/dependency.dart", entry_paths)
        self.assertIn(
            "@toolchain/flutter/packages/flutter_tools/gradle/captured.input",
            entry_paths,
        )
        self.assertIn(
            "@toolchain/flutter/bin/cache/artifacts/engine/common/captured.input",
            entry_paths,
        )
        self.assertIn(
            "@toolchain/flutter/bin/internal/captured.input",
            entry_paths,
        )
        self.assertIn("@toolchain/flutter/bin/dart", entry_paths)
        self.assertIn(
            "@toolchain/flutter/bin/cache/artifacts/engine/darwin-x64/impellerc",
            entry_paths,
        )
        self.assertIn(".dart_tool/package_config.json", entry_paths)
        self.assertIn(".dart_tool/package_graph.json", entry_paths)
        self.assertIn(".dart_tool/native_assets.yaml", entry_paths)
        self.assertIn(".dart_tool/lib/native.dylib", entry_paths)
        self.assertIn("android/local.properties", entry_paths)
        self.assertIn("android/gradle/verification-metadata.xml", entry_paths)
        self.assertIn(
            "@toolchain/flutter/packages/flutter_tools/.dart_tool/package_config.json",
            entry_paths,
        )
        self.assertIn(
            "@flutter-tool-package/tool_dependency/lib/tool_dependency.dart",
            entry_paths,
        )

        bindings = collect_manifest_path_bindings(self.root)
        self.assertEqual(
            [binding.logical_id for binding in bindings],
            sorted(entry_paths),
        )
        namespaces = {binding.logical_id: binding.namespace for binding in bindings}
        self.assertEqual(namespaces["lib/main.dart"], "local")
        self.assertEqual(
            namespaces["@package/dependency/lib/dependency.dart"], "package"
        )
        self.assertEqual(
            namespaces[
                "@flutter-tool-package/tool_dependency/lib/tool_dependency.dart"
            ],
            "flutterToolPackage",
        )
        self.assertEqual(namespaces["@toolchain/flutter/bin/dart"], "flutterToolchain")

    def test_flutter_root_cli_executes_source_directly(self):
        result = subprocess.run(
            [
                sys.executable,
                str(pathlib.Path(__file__).with_name("tree_manifest.py")),
                "flutter-root",
                "--root",
                str(self.root),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertEqual(str(flutter_sdk_root(self.root)), result.stdout.strip())

        android_result = subprocess.run(
            [
                sys.executable,
                str(pathlib.Path(__file__).with_name("tree_manifest.py")),
                "android-sdk-root",
                "--root",
                str(self.root),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            str(android_sdk_root(self.root)),
            android_result.stdout.strip(),
        )

    def test_expected_flutter_root_binds_write_and_verify(self):
        write_manifest(
            self.root,
            self.manifest,
            expected_flutter_root=self.flutter,
        )
        verify_manifest(
            self.root,
            self.manifest,
            expected_flutter_root=self.flutter,
        )
        with tempfile.TemporaryDirectory() as other:
            other_root = pathlib.Path(other).resolve()
            (self.root / "android/local.properties").write_text(
                f"flutter.sdk={other_root}\nsdk.dir={self.root / 'android-sdk'}\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "does not match the expected"):
                verify_manifest(
                    self.root,
                    self.manifest,
                    expected_flutter_root=self.flutter,
                )

    def test_direct_and_transitive_source_mutations_fail_verification(self):
        for relative in ("lib/main.dart", "lib/core/transitive_bridge.dart"):
            with self.subTest(relative=relative):
                write_manifest(self.root, self.manifest)
                path = self.root / relative
                original = path.read_text(encoding="utf-8")
                path.write_text(original + " changed", encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "changed="):
                    verify_manifest(self.root, self.manifest)
                path.write_text(original, encoding="utf-8")

    def test_package_graph_mutation_fails_verification(self):
        write_manifest(self.root, self.manifest)
        package_graph = self.root / ".dart_tool/package_graph.json"
        package_graph.write_text('{"roots":["poison"]}\n', encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "changed="):
            verify_manifest(self.root, self.manifest)

    def test_native_asset_mapping_and_binary_mutations_fail_verification(self):
        mapping = self.root / ".dart_tool/native_assets.yaml"
        binary = self.root / ".dart_tool/lib/native.dylib"
        write_manifest(self.root, self.manifest)
        binary.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "changed="):
            verify_manifest(self.root, self.manifest)
        binary.write_bytes(b"native")
        mapping.write_text("{}\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "native-assets mapping"):
            verify_manifest(self.root, self.manifest)

    def test_native_asset_escape_is_rejected(self):
        outside = self.root.parent / f"{self.root.name}-outside.dylib"
        outside.write_bytes(b"outside")
        self.addCleanup(outside.unlink, missing_ok=True)
        (self.root / ".dart_tool/native_assets.yaml").write_text(
            json.dumps(
                {
                    "format-version": [1, 0, 0],
                    "native-assets": {
                        "macos_arm64": {
                            "package:fixture/native.dylib": [
                                "absolute",
                                str(outside),
                            ],
                        },
                    },
                }
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(ValueError, "escapes"):
            write_manifest(self.root, self.manifest)

    def test_external_native_build_cache_is_removed_and_audited(self):
        cache = self.dependency / "android/.cxx/Debug/hash/arm64-v8a"
        cache.mkdir(parents=True)
        (cache / "build.ninja").write_text("planted", encoding="utf-8")
        (cache / "dependency.o").write_bytes(b"object")
        evidence_parent = self.root / ".omx/evidence"
        evidence_parent.mkdir(parents=True, mode=0o700)
        evidence = evidence_parent / "native-cache-cleanup.json"

        clean_external_native_build_caches(self.root, evidence)

        self.assertFalse((self.dependency / "android/.cxx").exists())
        payload = json.loads(evidence.read_text(encoding="utf-8"))
        self.assertEqual(payload["version"], 1)
        self.assertGreaterEqual(payload["packageRootsChecked"], 1)
        self.assertEqual(payload["packageRootsChecked"], len(payload["packageRoots"]))
        self.assertIn(str(self.dependency), payload["packageRoots"])
        self.assertEqual(payload["removed"][0]["files"], 2)
        self.assertEqual(
            payload["removed"][0]["path"],
            str(self.dependency / "android/.cxx"),
        )

    def _flutter_gradle_cleanup_evidence(self, name="flutter-gradle-cleanup.json"):
        evidence_parent = self.root / ".omx/evidence"
        evidence_parent.mkdir(parents=True, mode=0o700, exist_ok=True)
        evidence_parent.chmod(0o700)
        return evidence_parent / name

    def test_flutter_gradle_generated_state_removes_only_named_directories(self):
        gradle = self.flutter / "packages/flutter_tools/gradle"
        generated = (
            gradle / ".gradle",
            gradle / "build",
            gradle / ".kotlin",
        )
        for directory in generated:
            directory.mkdir(parents=True, exist_ok=True)
            (directory / "generated.bin").write_bytes(b"generated")
        kotlin_error = gradle / ".kotlin/errors/failure.bin"
        kotlin_error.parent.mkdir()
        kotlin_error.write_bytes(b"generated error")
        settings = gradle / "settings.gradle.kts"
        build_script = gradle / "build.gradle.kts"
        plugin_source = gradle / "src/main/kotlin/plugin.kt"
        settings.write_text("sealed settings\n", encoding="utf-8")
        build_script.write_text("sealed build\n", encoding="utf-8")
        plugin_source.parent.mkdir(parents=True)
        plugin_source.write_text("sealed plugin source\n", encoding="utf-8")
        evidence = self._flutter_gradle_cleanup_evidence()

        clean_flutter_gradle_generated_state(
            self.root,
            evidence,
            expected_flutter_root=self.flutter,
        )

        for directory in generated:
            self.assertFalse(directory.exists())
        self.assertEqual(settings.read_text(encoding="utf-8"), "sealed settings\n")
        self.assertEqual(build_script.read_text(encoding="utf-8"), "sealed build\n")
        self.assertEqual(
            plugin_source.read_text(encoding="utf-8"),
            "sealed plugin source\n",
        )
        payload = json.loads(evidence.read_text(encoding="utf-8"))
        self.assertEqual(payload["version"], 1)
        self.assertCountEqual(
            [entry["path"] for entry in payload["removed"]],
            [str(directory) for directory in generated],
        )

    def test_flutter_gradle_generated_state_rejects_symlinked_generated_directory(self):
        outside = self.root.parent / f"{self.root.name}-flutter-gradle-outside"
        outside.mkdir()
        self.addCleanup(lambda: outside.rmdir() if outside.exists() else None)
        generated = self.flutter / "packages/flutter_tools/gradle/build"
        generated.symlink_to(outside, target_is_directory=True)

        with self.assertRaisesRegex(ValueError, "symlink"):
            clean_flutter_gradle_generated_state(
                self.root,
                self._flutter_gradle_cleanup_evidence("symlink.json"),
                expected_flutter_root=self.flutter,
            )

        generated.unlink()

    def test_flutter_gradle_generated_state_rejects_foreign_owner_file(self):
        generated = self.flutter / "packages/flutter_tools/gradle/.gradle"
        generated.mkdir()
        target = generated / "generated.bin"
        target.write_bytes(b"generated")
        real_lstat = os.lstat

        def foreign_file_lstat(path):
            metadata = real_lstat(path)
            if pathlib.Path(path) == target:
                return mock.Mock(
                    st_mode=metadata.st_mode,
                    st_uid=os.getuid() + 1,
                    st_size=metadata.st_size,
                    st_nlink=metadata.st_nlink,
                )
            return metadata

        with mock.patch("tree_manifest.os.lstat", side_effect=foreign_file_lstat):
            with self.assertRaisesRegex(ValueError, "unsafe.*generated.*file"):
                clean_flutter_gradle_generated_state(
                    self.root,
                    self._flutter_gradle_cleanup_evidence("foreign-owner.json"),
                    expected_flutter_root=self.flutter,
                )

    def test_flutter_gradle_generated_state_rejects_foreign_owner_directory(self):
        generated = self.flutter / "packages/flutter_tools/gradle/build"
        generated.mkdir()
        real_lstat = os.lstat

        def foreign_directory_lstat(path):
            metadata = real_lstat(path)
            if pathlib.Path(path) == generated:
                return mock.Mock(
                    st_mode=metadata.st_mode,
                    st_uid=os.getuid() + 1,
                    st_size=metadata.st_size,
                    st_nlink=metadata.st_nlink,
                )
            return metadata

        with mock.patch("tree_manifest.os.lstat", side_effect=foreign_directory_lstat):
            with self.assertRaisesRegex(ValueError, "unsafe.*generated.*directory"):
                clean_flutter_gradle_generated_state(
                    self.root,
                    self._flutter_gradle_cleanup_evidence("foreign-directory.json"),
                    expected_flutter_root=self.flutter,
                )

    def test_flutter_gradle_generated_state_rejects_mismatched_flutter_root(self):
        outside = self.root.parent / f"{self.root.name}-other-flutter"
        outside.mkdir()
        self.addCleanup(lambda: outside.rmdir() if outside.exists() else None)

        with self.assertRaisesRegex(ValueError, "Flutter SDK root|flutter root"):
            clean_flutter_gradle_generated_state(
                self.root,
                self._flutter_gradle_cleanup_evidence("mismatched-root.json"),
                expected_flutter_root=outside,
            )

    def test_flutter_gradle_generated_state_rejects_evidence_outside_app_root(self):
        outside = self.root.parent / f"{self.root.name}-cleanup.json"
        self.addCleanup(outside.unlink, missing_ok=True)

        with self.assertRaisesRegex(ValueError, "escapes|outside|boundary"):
            clean_flutter_gradle_generated_state(
                self.root,
                outside,
                expected_flutter_root=self.flutter,
            )

    def test_flutter_gradle_generated_state_cli_cleans_bound_flutter_root(self):
        generated = self.flutter / "packages/flutter_tools/gradle/build"
        generated.mkdir()
        (generated / "generated.bin").write_bytes(b"generated")
        evidence = self._flutter_gradle_cleanup_evidence("cli.json")

        completed = subprocess.run(
            [
                sys.executable,
                str(pathlib.Path(__file__).with_name("tree_manifest.py")),
                "clean-flutter-gradle-generated-state",
                "--root",
                str(self.root),
                "--expected-flutter-root",
                str(self.flutter),
                "--evidence",
                str(evidence),
            ],
            capture_output=True,
            text=True,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertFalse(generated.exists())
        self.assertTrue(evidence.is_file())

    def test_external_native_build_cache_symlink_is_rejected(self):
        outside = self.root.parent / f"{self.root.name}-native-cache-outside"
        outside.mkdir()
        self.addCleanup(lambda: outside.rmdir() if outside.exists() else None)
        evidence_parent = self.root / ".omx/evidence"
        evidence_parent.mkdir(parents=True, mode=0o700)
        android = self.dependency / "android"
        android.mkdir()
        cache = android / ".cxx"
        cache.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            clean_external_native_build_caches(
                self.root,
                evidence_parent / "symlink.json",
            )
        cache.unlink()

    def test_nested_external_native_build_cache_hardlink_is_removed_and_audited(self):
        outside = self.root.parent / f"{self.root.name}-native-cache-hardlink"
        outside.write_bytes(b"object")
        self.addCleanup(outside.unlink, missing_ok=True)
        cache = self.dependency / "android/.cxx/Debug/hash/arm64-v8a"
        cache.mkdir(parents=True)
        linked = cache / "compile_commands.json"
        os.link(outside, linked)
        self.assertEqual(linked.stat().st_nlink, 2)
        evidence_parent = self.root / ".omx/evidence"
        evidence_parent.mkdir(parents=True, mode=0o700)
        evidence = evidence_parent / "hardlink.json"

        clean_external_native_build_caches(self.root, evidence)

        self.assertFalse((self.dependency / "android/.cxx").exists())
        self.assertEqual(outside.read_bytes(), b"object")
        self.assertEqual(outside.stat().st_nlink, 1)
        payload = json.loads(evidence.read_text(encoding="utf-8"))
        self.assertEqual(payload["removed"][0]["files"], 1)
        self.assertEqual(payload["removed"][0]["bytes"], len(b"object"))

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO is not supported")
    def test_external_native_build_cache_special_file_is_rejected(self):
        cache = self.dependency / "android/.cxx"
        cache.mkdir(parents=True)
        fifo = cache / "object.o"
        os.mkfifo(fifo)
        evidence_parent = self.root / ".omx/evidence"
        evidence_parent.mkdir(parents=True, mode=0o700)
        with self.assertRaisesRegex(ValueError, "unsafe external native cache file"):
            clean_external_native_build_caches(
                self.root,
                evidence_parent / "special.json",
            )

    def test_external_native_build_cache_foreign_owner_file_is_rejected(self):
        cache = self.dependency / "android/.cxx"
        cache.mkdir(parents=True)
        target = cache / "object.o"
        target.write_bytes(b"object")
        evidence_parent = self.root / ".omx/evidence"
        evidence_parent.mkdir(parents=True, mode=0o700)
        real_lstat = os.lstat

        def foreign_file_lstat(path):
            metadata = real_lstat(path)
            if pathlib.Path(path) == target:
                return mock.Mock(
                    st_mode=metadata.st_mode,
                    st_uid=os.getuid() + 1,
                    st_size=metadata.st_size,
                    st_nlink=metadata.st_nlink,
                )
            return metadata

        with mock.patch("tree_manifest.os.lstat", side_effect=foreign_file_lstat):
            with self.assertRaisesRegex(
                ValueError,
                "unsafe external native cache file",
            ):
                clean_external_native_build_caches(
                    self.root,
                    evidence_parent / "foreign-owner.json",
                )

    def test_unenumerable_external_directory_fails_manifest_and_cache_cleanup(self):
        android = self.dependency / "android"
        cache = android / ".cxx"
        cache.mkdir(parents=True)
        (android / "build.gradle").write_text("plugins {}\n", encoding="utf-8")
        (cache / "object.o").write_bytes(b"object")
        android.chmod(0o111)
        try:
            with self.assertRaisesRegex(ValueError, "unenumerable|enumerate|unsafe"):
                write_manifest(self.root, self.manifest)

            evidence_parent = self.root / ".omx/evidence"
            evidence_parent.mkdir(parents=True, mode=0o700)
            with self.assertRaisesRegex(ValueError, "enumerate|unsafe"):
                clean_external_native_build_caches(
                    self.root,
                    evidence_parent / "unreadable.json",
                )
        finally:
            android.chmod(0o755)

    def test_unenumerable_external_native_cache_fails_cleanup(self):
        cache = self.dependency / "android/.cxx/Debug"
        cache.mkdir(parents=True)
        (cache / "object.o").write_bytes(b"object")
        cache.chmod(0o111)
        evidence_parent = self.root / ".omx/evidence"
        evidence_parent.mkdir(parents=True, mode=0o700)
        try:
            with self.assertRaisesRegex(ValueError, "enumerate"):
                clean_external_native_build_caches(
                    self.root,
                    evidence_parent / "unreadable-cache.json",
                )
        finally:
            cache.chmod(0o755)

    def _write_native_cache_freshness_inputs(
        self,
        native_cache_roots: list[pathlib.Path],
    ) -> tuple[pathlib.Path, pathlib.Path, pathlib.Path, pathlib.Path]:
        evidence_parent = self.root / ".omx/evidence"
        evidence_parent.mkdir(parents=True, mode=0o700)
        cleanup = evidence_parent / "cleanup.json"
        clean_external_native_build_caches(self.root, cleanup)

        generated = evidence_parent / "generated.json"
        generated.write_text(
            json.dumps(
                {
                    "checked": [
                        "build",
                        "android/.gradle",
                        ".dart_tool/flutter_build",
                        ".dart_tool/hooks_runner",
                        ".dart_tool/test",
                    ],
                    "removed": [],
                    "version": 1,
                },
                sort_keys=True,
            ),
            encoding="utf-8",
        )

        for cache in native_cache_roots:
            cache.mkdir(parents=True)
        model = (
            self.root
            / "build/app/intermediates/cxx/debug/hash/logs/arm64-v8a/build_model.json"
        )
        model.parent.mkdir(parents=True)
        model.write_text("{}\n", encoding="utf-8")
        model_sha = hashlib.sha256(model.read_bytes()).hexdigest()
        discovery = evidence_parent / "discovery.json"
        source_paths = sorted(
            [
                str(self.root / "android/app/build.gradle.kts"),
                str(self.dependency / "pubspec.yaml"),
            ]
        )
        discovery.write_text(
            json.dumps(
                {
                    "discoveryModels": [str(model)],
                    "discoveryModelSha256": {str(model): model_sha},
                    "nativeCacheRoots": sorted(map(str, native_cache_roots)),
                    "nativeModelSourcePaths": source_paths,
                    "version": 1,
                },
                sort_keys=True,
            ),
            encoding="utf-8",
        )
        output = evidence_parent / "freshness.json"
        return cleanup, generated, discovery, output

    def test_native_cache_freshness_binds_cleanup_models_and_sealed_sources(self):
        local_cache = self.root / "build/.cxx"
        external_cache = self.dependency / "android/.cxx"
        cleanup, generated, discovery, output = (
            self._write_native_cache_freshness_inputs(
                [local_cache, external_cache],
            )
        )

        verify_native_cache_freshness(
            self.root,
            cleanup,
            generated,
            discovery,
            output,
        )

        result = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(result["result"], "pass")
        self.assertEqual(result["localNativeCacheRoots"], 1)
        self.assertEqual(result["externalNativeCacheRoots"], 1)

    def test_native_cache_freshness_accepts_external_cache_without_local_cache(self):
        external_cache = self.dependency / "android/.cxx"
        cleanup, generated, discovery, output = (
            self._write_native_cache_freshness_inputs([external_cache])
        )

        verify_native_cache_freshness(
            self.root,
            cleanup,
            generated,
            discovery,
            output,
        )

        result = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(result["result"], "pass")
        self.assertEqual(result["localNativeCacheRoots"], 0)
        self.assertEqual(result["externalNativeCacheRoots"], 1)

    def test_native_cache_freshness_accepts_local_cache_without_external_cache(self):
        local_cache = self.root / "build/.cxx"
        cleanup, generated, discovery, output = (
            self._write_native_cache_freshness_inputs([local_cache])
        )

        verify_native_cache_freshness(
            self.root,
            cleanup,
            generated,
            discovery,
            output,
        )

        result = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(result["result"], "pass")
        self.assertEqual(result["localNativeCacheRoots"], 1)
        self.assertEqual(result["externalNativeCacheRoots"], 0)

    def test_native_cache_freshness_rejects_boolean_package_root_count(self):
        tool_config = (
            self.flutter / "packages/flutter_tools/.dart_tool/package_config.json"
        )
        tool_payload = json.loads(tool_config.read_text(encoding="utf-8"))
        tool_payload["packages"][0]["rootUri"] = self.dependency.as_uri()
        tool_config.write_text(json.dumps(tool_payload), encoding="utf-8")
        local_cache = self.root / "build/.cxx"
        cleanup, generated, discovery, output = (
            self._write_native_cache_freshness_inputs([local_cache])
        )
        cleanup_payload = json.loads(cleanup.read_text(encoding="utf-8"))
        self.assertEqual(len(cleanup_payload["packageRoots"]), 1)
        cleanup_payload["packageRootsChecked"] = True
        cleanup.write_text(json.dumps(cleanup_payload), encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "package roots are incomplete"):
            verify_native_cache_freshness(
                self.root,
                cleanup,
                generated,
                discovery,
                output,
            )

    def test_native_cache_freshness_rejects_boolean_cleanup_version(self):
        local_cache = self.root / "build/.cxx"
        cleanup, generated, discovery, output = (
            self._write_native_cache_freshness_inputs([local_cache])
        )
        cleanup_payload = json.loads(cleanup.read_text(encoding="utf-8"))
        cleanup_payload["version"] = True
        cleanup.write_text(json.dumps(cleanup_payload), encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "package roots are incomplete"):
            verify_native_cache_freshness(
                self.root,
                cleanup,
                generated,
                discovery,
                output,
            )

    def test_native_cache_freshness_rejects_boolean_removed_bytes(self):
        self._assert_native_cache_freshness_rejects_boolean_removed_count("bytes")

    def test_native_cache_freshness_rejects_boolean_removed_files(self):
        self._assert_native_cache_freshness_rejects_boolean_removed_count("files")

    def _assert_native_cache_freshness_rejects_boolean_removed_count(
        self,
        field: str,
    ) -> None:
        external_cache = self.dependency / "android/.cxx"
        cleanup, generated, discovery, output = (
            self._write_native_cache_freshness_inputs([external_cache])
        )
        cleanup_payload = json.loads(cleanup.read_text(encoding="utf-8"))
        cleanup_payload["removed"] = [
            {
                "bytes": True if field == "bytes" else 1,
                "files": True if field == "files" else 1,
                "path": str(external_cache),
            }
        ]
        cleanup.write_text(json.dumps(cleanup_payload), encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "invalid.*removal record"):
            verify_native_cache_freshness(
                self.root,
                cleanup,
                generated,
                discovery,
                output,
            )

    def test_native_cache_freshness_rejects_discovery_without_native_cache(self):
        cleanup, generated, discovery, output = (
            self._write_native_cache_freshness_inputs([])
        )

        with self.assertRaisesRegex(
            ValueError, "native cache roots must be a non-empty list"
        ):
            verify_native_cache_freshness(
                self.root,
                cleanup,
                generated,
                discovery,
                output,
            )

    def test_native_cache_freshness_rejects_incomplete_cleanup_roots(self):
        evidence_parent = self.root / ".omx/evidence"
        evidence_parent.mkdir(parents=True, mode=0o700)
        cleanup = evidence_parent / "cleanup.json"
        clean_external_native_build_caches(self.root, cleanup)
        payload = json.loads(cleanup.read_text(encoding="utf-8"))
        payload["packageRoots"] = payload["packageRoots"][1:]
        payload["packageRootsChecked"] = len(payload["packageRoots"])
        cleanup.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")
        generated = evidence_parent / "generated.json"
        generated.write_text(
            json.dumps(
                {
                    "checked": [
                        "build",
                        "android/.gradle",
                        ".dart_tool/flutter_build",
                        ".dart_tool/hooks_runner",
                        ".dart_tool/test",
                    ],
                    "removed": [],
                    "version": 1,
                }
            ),
            encoding="utf-8",
        )
        discovery = evidence_parent / "discovery.json"
        discovery.write_text('{"version":1}\n', encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "package roots are incomplete"):
            verify_native_cache_freshness(
                self.root,
                cleanup,
                generated,
                discovery,
                evidence_parent / "freshness.json",
            )

    def test_local_and_package_hardlinks_are_rejected(self):
        outside = self.root.parent / f"{self.root.name}-alias"
        outside.write_text("alias", encoding="utf-8")
        self.addCleanup(outside.unlink, missing_ok=True)
        local = self.root / "lib/hardlink.dart"
        os.link(outside, local)
        with self.assertRaisesRegex(ValueError, "hardlinked manifest input"):
            write_manifest(self.root, self.manifest)
        local.unlink()
        package_alias = self.dependency / "lib/hardlink.dart"
        os.link(outside, package_alias)
        with self.assertRaisesRegex(ValueError, "hardlinked manifest input"):
            write_manifest(self.root, self.manifest)

    def test_new_or_removed_build_input_fails_verification(self):
        write_manifest(self.root, self.manifest)
        added = self.root / "lib/new_source.dart"
        added.write_text("new", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "added="):
            verify_manifest(self.root, self.manifest)
        added.unlink()
        (self.root / "assets/icon.png").unlink()
        with self.assertRaisesRegex(ValueError, "removed="):
            verify_manifest(self.root, self.manifest)

    def test_external_package_mutation_and_addition_fail_verification(self):
        write_manifest(self.root, self.manifest)
        source = self.dependency / "lib/dependency.dart"
        source.write_text("changed", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "changed="):
            verify_manifest(self.root, self.manifest)
        source.write_text("dependency", encoding="utf-8")
        added = self.dependency / "lib/added.dart"
        added.write_text("added", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "added="):
            verify_manifest(self.root, self.manifest)

    def test_flutter_gradle_and_toolchain_mutations_fail_verification(self):
        write_manifest(self.root, self.manifest)
        gradle_input = self.flutter / "packages/flutter_tools/gradle/captured.input"
        gradle_input.write_text("mutated", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "changed="):
            verify_manifest(self.root, self.manifest)

        gradle_input.write_text("gradle", encoding="utf-8")
        tool_input = self.tool_dependency / "lib/tool_dependency.dart"
        tool_input.write_text("mutated", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "changed="):
            verify_manifest(self.root, self.manifest)

    def test_unapproved_or_noncanonical_package_root_is_rejected(self):
        with tempfile.TemporaryDirectory(dir=self.root.parent) as outside:
            outside_path = pathlib.Path(outside)
            self.write_package_config(outside_path.as_uri())
            with self.assertRaisesRegex(ValueError, "unapproved external"):
                write_manifest(self.root, self.manifest)
        self.write_package_config(f"{self.dependency.as_uri()}?mutable=true")
        with self.assertRaisesRegex(ValueError, "non-canonical"):
            write_manifest(self.root, self.manifest)

    def test_tool_markdown_is_not_an_executable_input_but_asset_markdown_is(self):
        write_manifest(self.root, self.manifest)
        readme = self.root / "tool/telemetry_memory_rig/README.md"
        readme.write_text("documentation", encoding="utf-8")
        verify_manifest(self.root, self.manifest)
        asset = self.root / "assets/content.md"
        asset.write_text("bundled", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "added="):
            verify_manifest(self.root, self.manifest)
        asset.unlink()
        nested = self.root / "tool/telemetry_memory_rig/fixtures/contract.md"
        nested.parent.mkdir()
        nested.write_text("fixture", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "added="):
            verify_manifest(self.root, self.manifest)

    def test_symlink_in_local_or_package_input_fails_closed(self):
        local_link = self.root / "lib/link.dart"
        local_link.symlink_to(self.root / "lib/main.dart")
        with self.assertRaisesRegex(ValueError, "symlink"):
            write_manifest(self.root, self.manifest)
        local_link.unlink()
        package_link = self.dependency / "lib/link.dart"
        package_link.symlink_to(self.dependency / "lib/dependency.dart")
        with self.assertRaisesRegex(ValueError, "symlink package"):
            write_manifest(self.root, self.manifest)

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO is not supported")
    def test_special_file_in_build_input_fails_closed(self):
        fifo = self.root / "lib/stream.dart"
        os.mkfifo(fifo)
        with self.assertRaisesRegex(ValueError, "special file"):
            write_manifest(self.root, self.manifest)

    def test_symlinked_package_root_is_rejected_before_traversal(self):
        package_link = self.pub_cache / "linked-dependency"
        package_link.symlink_to(self.dependency, target_is_directory=True)
        self.write_package_config(package_link.as_uri())
        with self.assertRaisesRegex(ValueError, "symlinked package root"):
            write_manifest(self.root, self.manifest)

    def test_symlinked_ancestor_of_exact_build_input_is_rejected(self):
        with tempfile.TemporaryDirectory() as outside:
            outside_app = pathlib.Path(outside) / "app"
            outside_app.mkdir()
            (outside_app / "build.gradle.kts").write_text(
                "escaped",
                encoding="utf-8",
            )
            original = self.root / "android/app"
            for path in sorted(original.rglob("*"), reverse=True):
                path.unlink() if path.is_file() else path.rmdir()
            original.rmdir()
            original.symlink_to(outside_app, target_is_directory=True)

            with self.assertRaisesRegex(ValueError, "symlink ancestor"):
                write_manifest(self.root, self.manifest)

    def test_symlinked_ancestor_of_exact_toolchain_input_is_rejected(self):
        cache = self.flutter / "bin/cache"
        with tempfile.TemporaryDirectory() as outside:
            outside_cache = pathlib.Path(outside) / "cache"
            cache.rename(outside_cache)
            cache.symlink_to(outside_cache, target_is_directory=True)

            with self.assertRaisesRegex(ValueError, "symlink ancestor"):
                write_manifest(self.root, self.manifest)

    def test_generated_python_cache_is_ignored(self):
        cache = self.root / "tool/telemetry_memory_rig/__pycache__"
        cache.mkdir()
        (cache / "module.pyc").write_bytes(b"cache")
        write_manifest(self.root, self.manifest)
        (cache / "module.pyc").write_bytes(b"changed")
        verify_manifest(self.root, self.manifest)

    def test_external_non_build_outputs_are_ignored(self):
        for relative in (
            "test/fixture.dart",
            "example/build/output.bin",
            "android/.cxx/object.o",
            "gradle/.kotlin/sessions/kotlin-compiler-1.salive",
            "docs/guide.md",
            "_out/generated.bin",
        ):
            path = self.dependency / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(relative, encoding="utf-8")
        write_manifest(self.root, self.manifest)
        (self.dependency / "android/.cxx/object.o").write_text(
            "changed", encoding="utf-8"
        )
        (
            self.dependency / "gradle/.kotlin/sessions/kotlin-compiler-1.salive"
        ).write_text("changed", encoding="utf-8")
        verify_manifest(self.root, self.manifest)


if __name__ == "__main__":
    unittest.main()
