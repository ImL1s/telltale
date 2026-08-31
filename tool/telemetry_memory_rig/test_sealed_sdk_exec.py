import hashlib
import json
import os
import pathlib
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

import tree_manifest


HERE = pathlib.Path(__file__).resolve().parent
APP_ROOT = HERE.parent.parent
EXECUTOR = HERE / "sealed_sdk_exec.sh"
GRADLE_ENTRYPOINT = HERE / "sealed_gradle_flutter.sh"
SOURCE_GUARD = HERE / "source_tree_guard.py"


def _sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _configured_flutter_jdk_root() -> pathlib.Path:
    settings = pathlib.Path.home() / ".config" / "flutter" / "settings"
    value = json.loads(settings.read_text(encoding="utf-8"))
    jdk_root = pathlib.Path(value["jdk-dir"])
    resolved = jdk_root.resolve(strict=True)
    if resolved != jdk_root or not (jdk_root / "bin" / "java").is_file():
        raise ValueError("configured Flutter JDK root is unsafe")
    return jdk_root


class SealedGradleFlutterContractTest(unittest.TestCase):
    def test_gradle_entrypoint_rejects_mismatched_java_home_before_flutter(self):
        flutter_root = tree_manifest.flutter_sdk_root(APP_ROOT)
        with tempfile.TemporaryDirectory() as temporary_text:
            temporary = pathlib.Path(temporary_text)
            expected_jdk = temporary / "expected-jdk"
            actual_jdk = temporary / "actual-jdk"
            for root in (expected_jdk, actual_jdk):
                java = root / "bin" / "java"
                java.parent.mkdir(parents=True)
                java.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                java.chmod(0o700)
            environment = {
                "HOME": str(pathlib.Path.home()),
                "PATH": "/usr/bin:/bin",
                "ORG_GRADLE_PROJECT_telltaleGateCRigDebug": "true",
                "TELLTALE_GATE_C_FLUTTER_ROOT": str(flutter_root),
                "TELLTALE_GATE_C_JDK_ROOT": str(expected_jdk),
                "JAVA_HOME": str(actual_jdk),
            }
            completed = subprocess.run(
                [str(GRADLE_ENTRYPOINT), "--version"],
                cwd=APP_ROOT,
                env=environment,
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(completed.returncode, 64)
            self.assertIn(
                "JAVA_HOME does not match TELLTALE_GATE_C_JDK_ROOT",
                completed.stderr,
            )


@unittest.skipUnless(
    sys.platform == "darwin" and shutil.which("fswatch") is not None,
    "requires the macOS FSEvents fswatch used by Gate C",
)
class SealedSdkExecRealTest(unittest.TestCase):
    def test_actual_flutter_command_is_quiet_under_live_source_guard(self):
        flutter_root = tree_manifest.flutter_sdk_root(APP_ROOT)
        jdk_root = _configured_flutter_jdk_root()
        engine_stamp = flutter_root / "bin/cache/engine.stamp"
        nonce = secrets.token_hex(16)
        with tempfile.TemporaryDirectory() as temporary_text:
            temporary = pathlib.Path(temporary_text)
            stop = temporary / "guard.stop"
            ready = temporary / "guard.ready.json"
            events = temporary / "guard.events.jsonl"
            result = temporary / "guard.result.json"
            guard_log = temporary / "guard.log"
            environment = os.environ.copy()
            environment["PYTHONPYCACHEPREFIX"] = str(temporary / "pycache")
            with guard_log.open("w", encoding="utf-8") as log:
                guard = subprocess.Popen(
                    [
                        sys.executable,
                        str(SOURCE_GUARD),
                        "--root",
                        str(APP_ROOT),
                        "--fswatch",
                        shutil.which("fswatch"),
                        "--stop-file",
                        str(stop),
                        "--ready-file",
                        str(ready),
                        "--events-file",
                        str(events),
                        "--result-file",
                        str(result),
                        "--nonce",
                        nonce,
                    ],
                    cwd=APP_ROOT,
                    env=environment,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    text=True,
                )
            try:
                deadline = time.monotonic() + 10
                while (
                    not ready.exists()
                    and guard.poll() is None
                    and time.monotonic() < deadline
                ):
                    time.sleep(0.025)
                self.assertTrue(
                    ready.exists(),
                    guard_log.read_text(encoding="utf-8"),
                )
                ready_value = json.loads(ready.read_text(encoding="utf-8"))
                self.assertEqual(ready_value["nonce"], nonce)
                self.assertTrue(ready_value["canaryCreatedObserved"])
                self.assertTrue(ready_value["canaryRemovedObserved"])

                before = _sha256(engine_stamp)
                commands = (
                    (
                        [
                            str(EXECUTOR),
                            str(flutter_root),
                            "flutter",
                            "--version",
                            "--suppress-analytics",
                        ],
                        "Flutter 3.47.0",
                        None,
                        30,
                    ),
                    (
                        [
                            str(EXECUTOR),
                            str(flutter_root),
                            "flutter",
                            "test",
                            "--no-pub",
                            "test/fnv1a64_test.dart",
                        ],
                        "All tests passed!",
                        None,
                        120,
                    ),
                    (
                        [
                            str(GRADLE_ENTRYPOINT),
                            "--version",
                            "--suppress-analytics",
                        ],
                        "Flutter 3.47.0",
                        {
                            "ORG_GRADLE_PROJECT_telltaleGateCRigDebug": "true",
                            "TELLTALE_GATE_C_FLUTTER_ROOT": str(flutter_root),
                            "TELLTALE_GATE_C_JDK_ROOT": str(jdk_root),
                            "JAVA_HOME": str(jdk_root),
                        },
                        30,
                    ),
                )
                self.assertTrue(
                    GRADLE_ENTRYPOINT.exists(),
                    "Gate C Gradle Flutter entrypoint is missing",
                )
                for arguments, marker, overrides, timeout_seconds in commands:
                    command_environment = os.environ.copy()
                    if overrides is not None:
                        command_environment.update(overrides)
                    completed = subprocess.run(
                        arguments,
                        cwd=APP_ROOT,
                        env=command_environment,
                        capture_output=True,
                        text=True,
                        timeout=timeout_seconds,
                    )
                    self.assertEqual(completed.returncode, 0, completed.stderr)
                    self.assertIn(marker, completed.stdout)
                self.assertEqual(_sha256(engine_stamp), before)

                stop.write_text("stop\n", encoding="utf-8")
                guard.wait(timeout=10)
                self.assertEqual(
                    guard.returncode,
                    0,
                    guard_log.read_text(encoding="utf-8"),
                )
                result_value = json.loads(result.read_text(encoding="utf-8"))
                self.assertEqual(result_value["status"], "stopped")
                self.assertEqual(result_value["nonce"], nonce)
                self.assertEqual(result_value["violatingEventCount"], 0)
                for line in events.read_text(encoding="utf-8").splitlines():
                    self.assertFalse(json.loads(line)["violates"])
            finally:
                if guard.poll() is None:
                    stop.touch(exist_ok=True)
                    try:
                        guard.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        guard.kill()
                        guard.wait(timeout=2)


if __name__ == "__main__":
    unittest.main()
