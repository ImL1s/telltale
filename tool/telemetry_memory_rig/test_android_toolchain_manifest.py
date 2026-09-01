import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


HERE = pathlib.Path(__file__).resolve().parent
TOOL = HERE / "android_toolchain_manifest.py"


class AndroidToolchainManifestTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        temporary = pathlib.Path(self.temp.name).resolve()
        self.root = temporary / "app"
        self.sdk = temporary / "android-sdk"
        self.jdk = temporary / "jdk"
        self.gradle = temporary / "gradle-9.3.1"
        self.manifest = temporary / "android-toolchain.sha256"
        (self.root / "android").mkdir(parents=True)
        (self.root / "android/local.properties").write_text(
            f"sdk.dir={self.sdk}\nflutter.sdk={temporary / 'flutter'}\n",
            encoding="utf-8",
        )

        self.files = {
            "platform34": self.sdk / "platforms/android-34/android.jar",
            "platform36": self.sdk / "platforms/android-36/android.jar",
            "build_tools": self.sdk / "build-tools/36.0.0/core-lambda-stubs.jar",
            "ndk": self.sdk / "ndk/28.2.13676358/build/cmake/android.toolchain.cmake",
            "cmake": self.sdk / "cmake/3.22.1/bin/cmake",
            "ninja": self.sdk / "cmake/3.22.1/bin/ninja",
            "adb": self.sdk / "platform-tools/adb",
            "java": self.jdk / "bin/java",
            "java_conf": self.jdk / "conf/security/java.security",
            "java_modules": self.jdk / "lib/modules",
            "java_release": self.jdk / "release",
            "gradle": self.gradle / "bin/gradle",
            "gradle_jar": self.gradle / "lib/gradle.jar",
        }
        for name, path in self.files.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(f"{name}\n".encode())
        for name in ("adb", "java", "gradle", "cmake", "ninja"):
            self.files[name].chmod(0o755)
        (self.jdk / "jmods").mkdir()
        (self.jdk / "jmods/ignored.jmod").write_bytes(b"not-runtime\n")
        self.write_models()

    def tearDown(self):
        self.temp.cleanup()

    def write_models(self):
        for module, platform in (("plugin34", "34"), ("app", "36")):
            path = (
                self.root / f"build/{module}/intermediates/lint_model/release/"
                "generateReleaseLintModel/module.xml"
            )
            path.parent.mkdir(parents=True, exist_ok=True)
            boot = os.pathsep.join(
                (
                    str(self.sdk / f"platforms/android-{platform}/android.jar"),
                    str(self.files["build_tools"]),
                )
            )
            path.write_text(
                '<lint-module format="1" '
                f'compileTarget="android-{platform}" '
                f'bootClassPath="{boot}" />\n',
                encoding="utf-8",
            )

        path = (
            self.root
            / "build/app/intermediates/cxx/debug/hash/logs/arm64-v8a/build_model.json"
        )
        path.parent.mkdir(parents=True, exist_ok=True)
        native_cache = self.root / "build/.cxx"
        native_build = native_cache / "debug/hash/arm64-v8a"
        native_build.mkdir(parents=True, exist_ok=True)
        module_root = self.root / "android/app"
        module_root.mkdir(parents=True, exist_ok=True)
        module_build_file = module_root / "build.gradle.kts"
        module_build_file.write_text("plugins {}\n", encoding="utf-8")
        make_file = self.root / "native/CMakeLists.txt"
        make_file.parent.mkdir(parents=True, exist_ok=True)
        make_file.write_text("cmake_minimum_required(VERSION 3.22)\n", encoding="utf-8")
        path.write_text(
            json.dumps(
                {
                    "cxxBuildFolder": str(native_build),
                    "variant": {
                        "module": {
                            "cxxFolder": str(native_cache),
                            "moduleRootFolder": str(module_root),
                            "moduleBuildFile": str(module_build_file),
                            "makeFile": str(make_file),
                            "ndkFolder": str(self.sdk / "ndk/28.2.13676358"),
                            "ndkFolderBeforeSymLinking": str(
                                self.sdk / "ndk/28.2.13676358"
                            ),
                            "ndkVersion": "28.2.13676358",
                            "cmakeToolchainFile": str(self.files["ndk"]),
                            "cmake": {"cmakeExe": str(self.files["cmake"])},
                            "project": {"sdkFolder": str(self.sdk)},
                            "ninjaExe": str(self.files["ninja"]),
                        }
                    },
                },
                separators=(",", ":"),
            ),
            encoding="utf-8",
        )

    def command(self, operation, *extra):
        command = [
            sys.executable,
            str(TOOL),
            operation,
            "--root",
            str(self.root),
            "--expected-sdk-root",
            str(self.sdk),
            "--expected-jdk-root",
            str(self.jdk),
            "--expected-adb",
            str(self.files["adb"]),
            "--expected-gradle-root",
            str(self.gradle),
        ]
        if operation in {"write", "verify"}:
            command.extend(("--manifest", str(self.manifest)))
        command.extend(extra)
        return command

    def run_tool(self, operation, *extra, check=True):
        return subprocess.run(
            self.command(operation, *extra),
            check=check,
            capture_output=True,
            text=True,
        )

    def explicit_components(self):
        return (
            "platforms/android-34",
            "platforms/android-36",
            "build-tools/36.0.0",
            "ndk/28.2.13676358",
            "cmake/3.22.1",
            "platform-tools",
        )

    def explicit_args(self):
        return tuple(
            argument
            for component in self.explicit_components()
            for argument in ("--component-root", component)
        )

    def test_discovery_write_verify_and_roots_are_canonical(self):
        self.run_tool("write")
        self.run_tool("verify")

        lines = self.manifest.read_text(encoding="utf-8").splitlines()
        paths = [line.split("  ", 1)[1] for line in lines]
        self.assertEqual(paths, sorted(paths))
        self.assertEqual(len(paths), len(set(paths)))
        for expected in (
            "@toolchain/android-sdk/platforms/android-34/android.jar",
            "@toolchain/android-sdk/platforms/android-36/android.jar",
            "@toolchain/android-sdk/build-tools/36.0.0/core-lambda-stubs.jar",
            "@toolchain/android-sdk/ndk/28.2.13676358/build/cmake/android.toolchain.cmake",
            "@toolchain/android-sdk/cmake/3.22.1/bin/cmake",
            "@toolchain/android-sdk/platform-tools/adb",
            "@toolchain/jdk/bin/java",
            "@toolchain/jdk/conf/security/java.security",
            "@toolchain/jdk/lib/modules",
            "@toolchain/jdk/release",
            "@toolchain/gradle/bin/gradle",
            "@toolchain/gradle/lib/gradle.jar",
        ):
            self.assertIn(expected, paths)
        self.assertNotIn("@toolchain/jdk/jmods/ignored.jmod", paths)
        self.assertTrue(
            any(path.startswith("@discovery-model/lint/") for path in paths)
        )
        self.assertTrue(any(path.startswith("@discovery-model/cxx/") for path in paths))

        value = json.loads(self.run_tool("roots").stdout)
        self.assertEqual(value["version"], 1)
        self.assertEqual(value["sdkRoot"], str(self.sdk))
        self.assertEqual(value["jdkRoot"], str(self.jdk))
        self.assertEqual(value["adb"], str(self.files["adb"]))
        self.assertEqual(value["gradleRoot"], str(self.gradle))
        self.assertEqual(
            value["components"],
            list(self.explicit_components()),
        )
        self.assertEqual(
            value["watchRoots"],
            sorted(
                [str(self.sdk / component) for component in self.explicit_components()]
                + [str(self.jdk), str(self.gradle)]
            ),
        )
        self.assertEqual(
            set(value["discoveryModelSha256"]),
            set(value["discoveryModels"]),
        )
        self.assertTrue(
            all(len(digest) == 64 for digest in value["discoveryModelSha256"].values())
        )
        self.assertEqual(value["nativeCacheRoots"], [str(self.root / "build/.cxx")])
        self.assertEqual(
            value["nativeModelSourcePaths"],
            sorted(
                [
                    str(self.root / "android/app/build.gradle.kts"),
                    str(self.root / "native/CMakeLists.txt"),
                ]
            ),
        )

    def test_mutation_of_each_consumed_scope_fails_verification(self):
        targets = (
            "platform34",
            "platform36",
            "build_tools",
            "ndk",
            "cmake",
            "adb",
            "java",
            "java_conf",
            "java_modules",
            "java_release",
            "gradle",
            "gradle_jar",
        )
        for name in targets:
            with self.subTest(name=name):
                self.run_tool("write")
                original = self.files[name].read_bytes()
                self.files[name].write_bytes(original + b"mutated")
                failed = self.run_tool("verify", check=False)
                self.assertNotEqual(failed.returncode, 0, failed.stdout)
                self.files[name].write_bytes(original)

    def test_discovery_model_mutation_fails_verification(self):
        self.run_tool("write")
        model = next(self.root.glob("build/**/lint_model/**/module.xml"))
        model.write_text(model.read_text(encoding="utf-8") + "\n", encoding="utf-8")
        failed = self.run_tool("verify", check=False)
        self.assertNotEqual(failed.returncode, 0)

    def test_explicit_component_roots_do_not_depend_on_generated_models(self):
        import shutil

        shutil.rmtree(self.root / "build")
        self.run_tool("write", *self.explicit_args())
        self.run_tool("verify", *self.explicit_args())
        paths = [
            line.split("  ", 1)[1]
            for line in self.manifest.read_text(encoding="utf-8").splitlines()
        ]
        self.assertFalse(any(path.startswith("@discovery-model/") for path in paths))

    def test_explicit_component_roots_reject_duplicate_unknown_and_incomplete_sets(
        self,
    ):
        duplicate = self.run_tool(
            "write",
            *self.explicit_args(),
            "--component-root",
            "platform-tools",
            check=False,
        )
        self.assertNotEqual(duplicate.returncode, 0)
        self.assertIn("duplicate", duplicate.stderr)

        unknown = self.run_tool(
            "write", "--component-root", "extras/vendor", check=False
        )
        self.assertNotEqual(unknown.returncode, 0)
        self.assertIn("unsupported", unknown.stderr)

        incomplete = self.run_tool(
            "write", "--component-root", "platforms/android-36", check=False
        )
        self.assertNotEqual(incomplete.returncode, 0)
        self.assertIn("missing required", incomplete.stderr)

    def test_expected_sdk_jdk_adb_and_gradle_bindings_fail_closed(self):
        for option, value in (
            ("--expected-sdk-root", self.root),
            ("--expected-jdk-root", self.root),
            ("--expected-adb", self.files["java"]),
            ("--expected-gradle-root", self.jdk),
        ):
            with self.subTest(option=option):
                command = self.command("write")
                index = command.index(option)
                command[index + 1] = str(value)
                failed = subprocess.run(command, capture_output=True, text=True)
                self.assertNotEqual(failed.returncode, 0)

    def test_unknown_lint_sdk_path_and_cxx_escape_fail_closed(self):
        lint = next(self.root.glob("build/**/lint_model/**/module.xml"))
        lint.write_text(
            '<lint-module format="1" compileTarget="android-36" '
            f'bootClassPath="{self.sdk / "extras/vendor/unknown.jar"}" />\n',
            encoding="utf-8",
        )
        unknown = self.run_tool("write", check=False)
        self.assertNotEqual(unknown.returncode, 0)
        self.assertIn("unsupported Android SDK model path", unknown.stderr)

        self.write_models()
        cxx = next(self.root.glob("build/**/cxx/**/build_model.json"))
        value = json.loads(cxx.read_text(encoding="utf-8"))
        outside = self.root / "outside/cmake"
        outside.parent.mkdir(parents=True, exist_ok=True)
        outside.write_bytes(b"outside")
        value["variant"]["module"]["cmake"]["cmakeExe"] = str(outside)
        cxx.write_text(json.dumps(value), encoding="utf-8")
        escaped = self.run_tool("write", check=False)
        self.assertNotEqual(escaped.returncode, 0)
        self.assertIn("outside expected Android SDK root", escaped.stderr)

    def test_cxx_cache_and_model_source_paths_fail_closed(self):
        cxx = next(self.root.glob("build/**/cxx/**/build_model.json"))

        value = json.loads(cxx.read_text(encoding="utf-8"))
        value["variant"]["module"]["cxxFolder"] = str(self.root / "build")
        cxx.write_text(json.dumps(value), encoding="utf-8")
        wrong_cache = self.run_tool("write", check=False)
        self.assertNotEqual(wrong_cache.returncode, 0)
        self.assertIn("unsafe CXX model native cache root", wrong_cache.stderr)

        self.write_models()
        value = json.loads(cxx.read_text(encoding="utf-8"))
        outside_build = self.root / "outside-build"
        outside_build.mkdir()
        value["cxxBuildFolder"] = str(outside_build)
        cxx.write_text(json.dumps(value), encoding="utf-8")
        escaped_build = self.run_tool("write", check=False)
        self.assertNotEqual(escaped_build.returncode, 0)
        self.assertIn("build folder escapes", escaped_build.stderr)

        self.write_models()
        value = json.loads(cxx.read_text(encoding="utf-8"))
        outside_source = self.root / "outside.gradle"
        outside_source.write_text("plugins {}\n", encoding="utf-8")
        value["variant"]["module"]["moduleBuildFile"] = str(outside_source)
        cxx.write_text(json.dumps(value), encoding="utf-8")
        escaped_source = self.run_tool("write", check=False)
        self.assertNotEqual(escaped_source.returncode, 0)
        self.assertIn("module build file escapes", escaped_source.stderr)

    def test_roots_and_nested_gradle_symlinks_are_rejected(self):
        gradle_link = self.root.parent / "gradle-link"
        gradle_link.symlink_to(self.gradle, target_is_directory=True)
        command = self.command("write")
        index = command.index("--expected-gradle-root")
        command[index + 1] = str(gradle_link)
        linked_root = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(linked_root.returncode, 0)
        self.assertIn("symlink", linked_root.stderr)

        nested = self.gradle / "bin/gradle-link"
        nested.symlink_to("gradle")
        nested_link = self.run_tool("write", check=False)
        self.assertNotEqual(nested_link.returncode, 0)
        self.assertIn("symlink", nested_link.stderr)

    def test_confined_ndk_symlink_is_sealed_but_escape_is_rejected(self):
        target = self.sdk / "ndk/28.2.13676358/toolchains/clang-real"
        target.parent.mkdir(parents=True)
        target.write_bytes(b"clang")
        link = target.with_name("clang")
        link.symlink_to("clang-real")
        self.run_tool("write")
        paths = [
            line.split("  ", 1)[1]
            for line in self.manifest.read_text(encoding="utf-8").splitlines()
        ]
        self.assertIn(
            "@toolchain/android-sdk/ndk/28.2.13676358/toolchains/clang", paths
        )

        link.unlink()
        link.symlink_to(self.files["java"])
        escaped = self.run_tool("write", check=False)
        self.assertNotEqual(escaped.returncode, 0)
        self.assertIn("unsafe symlink", escaped.stderr)

    def test_nested_symlink_outside_ndk_is_rejected(self):
        link = self.sdk / "build-tools/36.0.0/core-lambda-link.jar"
        link.symlink_to("core-lambda-stubs.jar")
        failed = self.run_tool("write", check=False)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("symlink", failed.stderr)

    def test_external_hardlink_alias_is_rejected(self):
        outside = self.root.parent / "outside-gradle-alias.jar"
        os.link(self.files["gradle_jar"], outside)
        failed = self.run_tool("write", check=False)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("hard-linked", failed.stderr)

    def test_control_characters_and_noncanonical_component_paths_are_rejected(self):
        (self.root / "android/local.properties").write_text(
            f"sdk.dir={self.sdk}\x00evil\n", encoding="utf-8"
        )
        control = self.run_tool("write", check=False)
        self.assertNotEqual(control.returncode, 0)
        self.assertIn("control", control.stderr)

        (self.root / "android/local.properties").write_text(
            f"sdk.dir={self.sdk}\n", encoding="utf-8"
        )
        traversal = self.run_tool(
            "write", "--component-root", "platforms/../platform-tools", check=False
        )
        self.assertNotEqual(traversal.returncode, 0)
        self.assertIn("canonical", traversal.stderr)


if __name__ == "__main__":
    unittest.main()
