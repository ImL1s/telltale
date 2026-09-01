#!/usr/bin/env python3
"""Contract tests for outer_toolchain_cleanup_validator.py."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "test_target_outer_toolchain_cleanup_validator",
    HERE / "outer_toolchain_cleanup_validator.py",
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load outer toolchain/cleanup validator")
validator = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = validator
SPEC.loader.exec_module(validator)

OUTER_SPEC = importlib.util.spec_from_file_location(
    "test_target_outer_gate_toolchain_integration",
    HERE / "outer_gate_result_verifier.py",
)
if OUTER_SPEC is None or OUTER_SPEC.loader is None:
    raise RuntimeError("could not load outer Gate result verifier")
outer = importlib.util.module_from_spec(OUTER_SPEC)
sys.modules[OUTER_SPEC.name] = outer
OUTER_SPEC.loader.exec_module(outer)


def _sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Fixture:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.app = root / "app"
        self.evidence = self.app / "evidence"
        self.sdk = root / "sdk"
        self.jdk = root / "jdk"
        self.gradle = root / "isolated-gradle" / "gradle-9.0"
        self.flutter = root / "flutter"
        self.package = root / "pub-cache" / "package"
        self.evidence.mkdir(parents=True)
        self.package.mkdir(parents=True)
        flutter_gradle = self.flutter / "packages/flutter_tools/gradle"
        flutter_gradle.mkdir(parents=True)
        (self.app / "android").mkdir()
        (self.app / "android/local.properties").write_text(
            f"sdk.dir={self.sdk}\n", encoding="utf-8"
        )
        self.components = [
            "platforms/android-36",
            "build-tools/36.0.0",
            "ndk/28.0.0",
            "cmake/3.31.0",
            "platform-tools",
        ]
        self.tool_files: list[tuple[Path, str]] = []
        for component, relative in (
            ("platforms/android-36", "android.jar"),
            ("build-tools/36.0.0", "aapt2"),
            ("ndk/28.0.0", "source.properties"),
            ("cmake/3.31.0", "bin/cmake"),
            ("platform-tools", "adb"),
        ):
            path = self.sdk / component / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"{component}:{relative}\n", encoding="utf-8")
            self.tool_files.append(
                (path, f"@toolchain/android-sdk/{component}/{relative}")
            )
        jdk_release = self.jdk / "release"
        jdk_release.parent.mkdir(parents=True)
        jdk_release.write_text("JAVA_VERSION=fixture\n", encoding="utf-8")
        self.tool_files.append((jdk_release, "@toolchain/jdk/release"))

        lint = self.app / "build/a/intermediates/lint_model/rig/module.xml"
        cxx = self.app / "build/a/intermediates/cxx/rig/build_model.json"
        for path, text in ((lint, "<lint-module/>\n"), (cxx, "{}\n")):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        self.models = sorted((lint, cxx), key=str)
        self.external_cache = self.package / ".cxx"
        native_source = self.package / "CMakeLists.txt"
        native_source.write_text("project(fixture)\n", encoding="utf-8")
        self.native_source = native_source

        watch = sorted(
            [
                *(self.sdk / component for component in self.components),
                self.jdk,
                self.gradle,
            ],
            key=str,
        )
        self.discovery: dict[str, Any] = {
            "version": 1,
            "sdkRoot": str(self.sdk),
            "jdkRoot": str(self.jdk),
            "adb": str(self.sdk / "platform-tools/adb"),
            "gradleRoot": str(self.gradle),
            "components": self.components,
            "watchRoots": [str(path) for path in watch],
            "discoveryModels": [str(path) for path in self.models],
            "discoveryModelSha256": {str(path): _sha(path) for path in self.models},
            "nativeCacheRoots": [str(self.external_cache)],
            "nativeModelSourcePaths": [str(native_source)],
        }
        self.final_roots = {
            **self.discovery,
            "discoveryModels": [],
            "discoveryModelSha256": {},
            "nativeCacheRoots": [],
            "nativeModelSourcePaths": [],
        }
        self.write_json("android-toolchain.discovery.json", self.discovery)
        self.write_json("android-toolchain.roots.json", self.final_roots)
        self.write_json("android-toolchain.roots.post.json", self.final_roots)

        pre_cleanup = {
            "version": 1,
            "packageRoots": [str(self.package)],
            "packageRootsChecked": 1,
            "removed": [],
        }
        post_cleanup = {
            **pre_cleanup,
            "removed": [{"bytes": 8, "files": 1, "path": str(self.external_cache)}],
        }
        self.write_json("external-native-cache-cleanup.pre.json", pre_cleanup)
        self.write_json("external-native-cache-cleanup.post.json", post_cleanup)
        flutter_gradle_cleanup = {
            "version": 1,
            "checked": [
                str(flutter_gradle / ".gradle"),
                str(flutter_gradle / "build"),
                str(flutter_gradle / ".kotlin"),
            ],
            "removed": [],
        }
        self.write_json(
            "flutter-gradle-generated-cleanup.pre.json",
            flutter_gradle_cleanup,
        )
        self.write_json(
            "flutter-gradle-generated-cleanup.post.json",
            flutter_gradle_cleanup,
        )
        self.write_json(
            "generated-input-cleanup.json",
            {"version": 1, "checked": validator.GENERATED_SCOPES, "removed": []},
        )
        self.write_freshness()
        self.write_manifest()
        self.write_cleanup()
        self.write_result()
        self.prepared = {
            "paths": {
                "app_root": str(self.app),
                "android_sdk_root": str(self.sdk),
                "flutter_root": str(self.flutter),
            }
        }

    def write_json(self, name: str, value: object) -> None:
        (self.evidence / name).write_text(
            json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )

    def write_freshness(self) -> None:
        self.write_json(
            "native-cache-freshness-validated.json",
            {
                "version": 1,
                "result": "pass",
                "cleanupEvidenceSha256": _sha(
                    self.evidence / "external-native-cache-cleanup.pre.json"
                ),
                "generatedCleanupEvidenceSha256": _sha(
                    self.evidence / "generated-input-cleanup.json"
                ),
                "discoveryEvidenceSha256": _sha(
                    self.evidence / "android-toolchain.discovery.json"
                ),
                "localNativeCacheRoots": 0,
                "externalNativeCacheRoots": 1,
                "nativeCacheRoots": self.discovery["nativeCacheRoots"],
                "nativeModelSourcePaths": self.discovery["nativeModelSourcePaths"],
            },
        )

    def write_manifest(self) -> None:
        entries = [
            (
                validator._binding("components", "\n".join(self.components)),
                "@binding/android-sdk-components",
            ),
            (
                _sha(self.app / "android/local.properties"),
                "@binding/android-local-properties",
            ),
            (
                validator._binding("sdk-root", str(self.sdk)),
                "@binding/android-sdk-root",
            ),
            (
                validator._binding("adb", str(self.sdk / "platform-tools/adb")),
                "@binding/adb",
            ),
            (
                validator._binding("gradle-root", str(self.gradle)),
                "@binding/gradle-root",
            ),
            (validator._binding("jdk-root", str(self.jdk)), "@binding/jdk-root"),
            *[(_sha(path), logical) for path, logical in self.tool_files],
            ("a" * 64, "@toolchain/gradle/bin/gradle"),
        ]
        entries.sort(key=lambda item: item[1])
        text = "".join(f"{digest}  {logical}\n" for digest, logical in entries)
        for name in ("android-toolchain.pre.sha256", "android-toolchain.post.sha256"):
            (self.evidence / name).write_text(text, encoding="utf-8")

    def write_cleanup(self) -> None:
        before = {
            "serial": "DEVICE",
            "device_state": "device",
            "rig_path": "package:/data/app/rig/base.apk",
            "rig_pid": "123",
            "field_path": "package:/data/app/field/base.apk",
            "field_pid": "456",
            "font_scale": "1.0",
            "accelerometer_rotation": "1",
            "user_rotation": "0",
        }
        after = {**before, "rig_path": "absent", "rig_pid": "absent"}
        self.write_lines("before-state.txt", before)
        self.write_lines("after-state.txt", after)
        self.write_lines(
            "final-rig-removal.txt",
            {
                "serial": "DEVICE",
                "device_state": "device",
                "rig_path_before": before["rig_path"],
                "rig_pid_before": before["rig_pid"],
                "force_stop": "success",
                "uninstall": "success",
                "rig_path_after": "absent",
                "rig_pid_after": "absent",
            },
        )
        self.write_lines(
            "final-cleanup.txt",
            {
                "cleanup_attempt": "1",
                "rig_removal_evidence": "final-rig-removal.txt",
                "rig_path_after": "absent",
                "rig_pid_after": "absent",
                "field_path_unchanged": "true",
                "field_pid_unchanged": "true",
                "settings_unchanged": "true",
                "cleanup_verified": "true",
            },
        )

    def write_lines(self, name: str, values: dict[str, str]) -> None:
        (self.evidence / name).write_text(
            "".join(f"{key}={value}\n" for key, value in values.items()),
            encoding="utf-8",
        )

    def write_result(self) -> None:
        files = {
            "androidToolchainManifestSha256": "android-toolchain.post.sha256",
            "androidToolchainRootsSha256": "android-toolchain.roots.post.json",
            "androidToolchainDiscoverySha256": "android-toolchain.discovery.json",
            "externalNativeCacheCleanupPreSha256": "external-native-cache-cleanup.pre.json",
            "externalNativeCacheCleanupPostSha256": "external-native-cache-cleanup.post.json",
            "flutterGradleGeneratedCleanupPreSha256": "flutter-gradle-generated-cleanup.pre.json",
            "flutterGradleGeneratedCleanupPostSha256": "flutter-gradle-generated-cleanup.post.json",
            "generatedInputCleanupSha256": "generated-input-cleanup.json",
            "nativeCacheFreshnessValidationSha256": "native-cache-freshness-validated.json",
        }
        self.write_json(
            "runner-result.json",
            {
                "result": "pass",
                "cleanupVerified": True,
                **{key: _sha(self.evidence / name) for key, name in files.items()},
            },
        )


class OuterToolchainCleanupValidatorTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.fixture = Fixture(Path(self.temporary.name).resolve())

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def verify(self) -> Any:
        return validator.verify_toolchain_cleanup(
            self.fixture.evidence,
            self.fixture.prepared,
            app_root=self.fixture.app,
        )

    def verify_outer(self) -> None:
        rig = self.fixture.app / "tool/telemetry_memory_rig"
        rig.mkdir(parents=True, exist_ok=True)
        helper = rig / "outer_toolchain_cleanup_validator.py"
        shutil.copyfile(HERE / helper.name, helper)
        helper.chmod(0o600)
        tested = self.fixture.evidence / "tested-files.post.sha256"
        tested.write_text(
            f"{_sha(helper)}  tool/telemetry_memory_rig/{helper.name}\n",
            encoding="utf-8",
        )
        for path in self.fixture.evidence.rglob("*"):
            if path.is_file():
                path.chmod(0o600)
            elif path.is_dir():
                path.chmod(0o700)
        outer._verify_cleanup_and_toolchain_semantics(
            self.fixture.evidence,
            self.fixture.prepared,
            rig,
        )

    def test_accepts_hash_consistent_producer_schema_fixture(self) -> None:
        report = self.verify()
        self.assertGreater(report.live_reverified_entries, 6)
        self.assertEqual(report.gradle_attested_entries, 1)
        self.assertEqual(report.discovery_models, 2)
        self.assertEqual(report.cleanup_scope, "inner-run-device-state-only")

    def test_accepts_external_only_native_cache_topology(self) -> None:
        report = self.verify()

        self.assertEqual(report.discovery_models, 2)

    def test_accepts_local_only_native_cache_topology_in_both_consumers(self) -> None:
        local_cache = self.fixture.app / "build/.cxx"
        local_cache.mkdir(parents=True)
        self.fixture.discovery["nativeCacheRoots"] = [str(local_cache)]
        self.fixture.write_json(
            "android-toolchain.discovery.json", self.fixture.discovery
        )
        self.fixture.write_freshness()
        freshness_path = self.fixture.evidence / "native-cache-freshness-validated.json"
        freshness = json.loads(freshness_path.read_text(encoding="utf-8"))
        freshness["localNativeCacheRoots"] = 1
        freshness["externalNativeCacheRoots"] = 0
        freshness["nativeCacheRoots"] = [str(local_cache)]
        self.fixture.write_json("native-cache-freshness-validated.json", freshness)
        self.fixture.write_result()

        self.assertEqual(freshness["localNativeCacheRoots"], 1)
        self.assertEqual(freshness["externalNativeCacheRoots"], 0)
        self.verify()
        self.verify_outer()

    def test_rejects_boolean_package_root_count(self) -> None:
        for name in (
            "external-native-cache-cleanup.pre.json",
            "external-native-cache-cleanup.post.json",
        ):
            path = self.fixture.evidence / name
            cleanup = json.loads(path.read_text(encoding="utf-8"))
            cleanup["packageRootsChecked"] = True
            self.fixture.write_json(name, cleanup)
        self.fixture.write_freshness()
        self.fixture.write_result()

        with self.assertRaisesRegex(
            validator.ValidationError, "package root count is invalid"
        ):
            self.verify()

    def test_outer_consumer_rejects_boolean_package_root_count(self) -> None:
        for name in (
            "external-native-cache-cleanup.pre.json",
            "external-native-cache-cleanup.post.json",
        ):
            path = self.fixture.evidence / name
            cleanup = json.loads(path.read_text(encoding="utf-8"))
            cleanup["packageRootsChecked"] = True
            self.fixture.write_json(name, cleanup)
        self.fixture.write_freshness()
        self.fixture.write_result()

        with self.assertRaisesRegex(
            outer.VerificationError, "package roots are incomplete"
        ):
            self.verify_outer()

    def test_rejects_external_only_freshness_claiming_one_local_cache(self) -> None:
        freshness_path = self.fixture.evidence / "native-cache-freshness-validated.json"
        freshness = json.loads(freshness_path.read_text(encoding="utf-8"))
        freshness["localNativeCacheRoots"] = 1
        self.fixture.write_json("native-cache-freshness-validated.json", freshness)
        self.fixture.write_result()

        with self.assertRaisesRegex(
            validator.ValidationError, "native cache freshness attestation"
        ):
            self.verify()

    def test_outer_consumer_rejects_external_only_freshness_claiming_local_cache(
        self,
    ) -> None:
        freshness_path = self.fixture.evidence / "native-cache-freshness-validated.json"
        freshness = json.loads(freshness_path.read_text(encoding="utf-8"))
        freshness["localNativeCacheRoots"] = 1
        self.fixture.write_json("native-cache-freshness-validated.json", freshness)
        self.fixture.write_result()

        with self.assertRaisesRegex(
            outer.VerificationError, "native cache freshness evidence"
        ):
            self.verify_outer()

    def test_outer_consumer_invokes_bound_semantic_validator(self) -> None:
        self.verify_outer()

    def test_rejects_duplicate_json_keys(self) -> None:
        path = self.fixture.evidence / "generated-input-cleanup.json"
        path.write_text(
            '{"version":1,"version":1,"checked":[],"removed":[]}\n',
            encoding="utf-8",
        )
        with self.assertRaisesRegex(validator.ValidationError, "duplicate JSON key"):
            self.verify()

    def test_rejects_tampered_model_even_if_runner_hashes_are_refreshed(self) -> None:
        self.fixture.models[0].write_text("tampered\n", encoding="utf-8")
        with self.assertRaisesRegex(validator.ValidationError, "model digest mismatch"):
            self.verify()

    def test_rejects_watch_roots_not_derived_from_components(self) -> None:
        self.fixture.discovery["watchRoots"] = self.fixture.discovery["watchRoots"][:-1]
        self.fixture.write_json(
            "android-toolchain.discovery.json", self.fixture.discovery
        )
        self.fixture.write_freshness()
        self.fixture.write_result()
        with self.assertRaisesRegex(validator.ValidationError, "watchRoots"):
            self.verify()

    def test_rejects_missing_post_cleanup_coverage(self) -> None:
        cleanup = json.loads(
            (
                self.fixture.evidence / "external-native-cache-cleanup.post.json"
            ).read_text()
        )
        cleanup["removed"] = []
        self.fixture.write_json("external-native-cache-cleanup.post.json", cleanup)
        self.fixture.write_result()
        with self.assertRaisesRegex(validator.ValidationError, "does not cover"):
            self.verify()

    def test_rejects_live_sdk_tamper_with_hash_consistent_outer_result(self) -> None:
        self.fixture.tool_files[0][0].write_text("tampered\n", encoding="utf-8")
        with self.assertRaisesRegex(
            validator.ValidationError, "live Android toolchain"
        ):
            self.verify()

    def test_rejects_non_unique_successful_cleanup(self) -> None:
        source = self.fixture.evidence / "final-cleanup.txt"
        (self.fixture.evidence / "final-cleanup.retry-2.txt").write_bytes(
            source.read_bytes().replace(b"cleanup_attempt=1", b"cleanup_attempt=2")
        )
        with self.assertRaisesRegex(validator.ValidationError, "exactly one"):
            self.verify()

    def test_rejects_field_change_despite_claimed_cleanup_booleans(self) -> None:
        after = self.fixture.evidence / "after-state.txt"
        after.write_text(
            after.read_text().replace("field_pid=456", "field_pid=999"),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(validator.ValidationError, "field_pid"):
            self.verify()

    def test_rejects_surviving_disposable_gradle_root(self) -> None:
        self.fixture.gradle.mkdir(parents=True)
        with self.assertRaisesRegex(validator.ValidationError, "survived"):
            self.verify()


if __name__ == "__main__":
    unittest.main()
