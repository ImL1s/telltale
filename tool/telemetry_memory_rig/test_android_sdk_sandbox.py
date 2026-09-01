import hashlib
import importlib.util
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
import tempfile
import unittest
from copy import deepcopy
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
PREFLIGHT_PATH = HERE / "android_sdk_sandbox_preflight.py"
PREFLIGHT_SPEC = importlib.util.spec_from_file_location(
    "android_sdk_sandbox_preflight",
    PREFLIGHT_PATH,
)
if PREFLIGHT_SPEC is None or PREFLIGHT_SPEC.loader is None:
    raise RuntimeError(f"cannot load Android SDK sandbox preflight: {PREFLIGHT_PATH}")
preflight = importlib.util.module_from_spec(PREFLIGHT_SPEC)
sys.modules[PREFLIGHT_SPEC.name] = preflight
PREFLIGHT_SPEC.loader.exec_module(preflight)


def _identity(pid, *, ppid=1, pgid=None, sid=None):
    return {
        "pid": pid,
        "ppid": ppid,
        "pgid": pid if pgid is None else pgid,
        "sid": pid if sid is None else sid,
        "uid": os.getuid(),
        "startSec": 1_700_000_000,
        "startUsec": pid,
    }


def _lsof_seal():
    return {
        "path": "/usr/sbin/lsof",
        "sha256": "a" * 64,
        "device": 1,
        "inode": 2,
        "size": 3,
        "mtimeNs": 4,
        "mode": 0o755,
        "uid": 0,
        "gid": 0,
        "nlink": 1,
        "codesignVerified": True,
        "identifier": "com.apple.lsof",
        "cdhash": "b" * 40,
        "authorities": [
            "macOS Software Signing",
            "Apple Code Signing Certification Authority",
            "Apple Root CA",
        ],
        "designatedRequirement": 'identifier "com.apple.lsof" and anchor apple',
    }


def _probe_result():
    def denied(operation):
        return {"operation": operation, "denied": True, "errno": 1}

    return {
        "version": 1,
        "status": "passed",
        "readSucceeded": True,
        "allowedWrite": True,
        "deniedStateUnchanged": True,
        "sdkOpenWrite": denied("sdk-open-write"),
        "deniedOperations": [
            denied(operation)
            for operation in (
                "write",
                "open-write",
                "create",
                "delete",
                "rename",
                "chmod",
                "xattr",
            )
        ],
        "child": {
            "depth": 1,
            "write": denied("descendant-create"),
            "childReturnCode": 0,
            "child": {
                "depth": 2,
                "write": denied("descendant-create"),
            },
        },
    }


def _canonical_json(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def _canonical_json_sha256(value):
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def _add_duplicate_top_level_key(payload, key, value):
    prefix = json.dumps(key).encode() + b":" + json.dumps(value).encode() + b","
    if not payload.startswith(b"{"):
        raise AssertionError("fixture payload must be a JSON object")
    return b"{" + prefix + payload[1:]


def _session_fixture(root):
    app_root = root / "app"
    flutter_root = root / "flutter"
    android_sdk_root = root / "android-sdk"
    jdk_root = root / "jdk"
    gradle_home = root / "gradle"
    isolated_root = root / "isolated"
    run_temp = isolated_root / "run"
    for path in (
        app_root,
        flutter_root,
        android_sdk_root,
        jdk_root,
        gradle_home,
        isolated_root / "home",
        isolated_root / "xdg-config",
        run_temp / "kotlin-project-persistent",
        run_temp / "kotlin-daemon",
    ):
        path.mkdir(parents=True, exist_ok=True)
    wrapper = root / "wrapper.sh"
    wrapper.write_text("#!/bin/zsh -f\nexit 0\n", encoding="utf-8")
    executable = root / "python3"
    executable.write_text("sealed python fixture\n", encoding="utf-8")
    program = root / "source_tree_guard.py"
    program.write_text("raise SystemExit(0)\n", encoding="utf-8")
    process_scope = root / "process_scope.py"
    process_scope.write_text("# sealed process scope fixture\n", encoding="utf-8")
    flutter_settings = isolated_root / "xdg-config" / "settings"
    flutter_settings.write_text("{}\n", encoding="utf-8")
    roots = {
        "app_root": app_root,
        "flutter_root": flutter_root,
        "android_sdk_root": android_sdk_root,
        "gradle_home": gradle_home,
        "isolated_root": isolated_root,
        "run_temp": run_temp,
    }
    expected_roots = {
        "gradleUserHome": str(gradle_home),
        "isolatedUserRoot": str(isolated_root),
        "home": str(isolated_root / "home"),
        "sandboxRunTemp": str(run_temp),
        "kotlinProjectPersistentDir": str(run_temp / "kotlin-project-persistent"),
        "kotlinDaemonRunFilesDir": str(run_temp / "kotlin-daemon"),
    }
    owner = _identity(101, ppid=1, pgid=101, sid=101)
    supervisor = _identity(102, ppid=101, pgid=101, sid=101)
    leader = _identity(103, ppid=102)
    authority = {
        "version": 2,
        "launchId": "1" * 32,
        "ownerRoot": owner,
        "supervisor": supervisor,
        "leader": leader,
        "wrapper": {
            "path": str(wrapper),
            "sha256": hashlib.sha256(wrapper.read_bytes()).hexdigest(),
        },
        "roots": expected_roots,
        "cwd": str(app_root),
    }
    authority_path = root / "android-sdk-sandbox-probe.process-authority.json"
    environment_path = preflight.child_environment_evidence_path(authority_path)
    reference_authority_path = (
        root
        / "process-scope-reference-authorities"
        / "bootstrap-source-guard.reference-authority.json"
    )
    reference_authority_path.parent.mkdir(exist_ok=True)
    readiness_path = root / "bootstrap-source-tree-guard-ready.json"
    stop_path = root / "bootstrap-source-tree-guard.stop"
    guard_result_path = root / "bootstrap-source-tree-guard-result.json"
    scope_path = root / "scope.json"
    result_path = root / "result.json"
    subject = _identity(104, ppid=owner["pid"], pgid=owner["pgid"], sid=owner["sid"])
    readiness = {
        "version": 3,
        "pid": subject["pid"],
        "nonce": "2" * 32,
    }
    readiness_path.write_bytes(_canonical_json(readiness))
    reference_authority = {
        "version": 1,
        "kind": "source-guard-reference-exemption",
        "exemptionId": "3" * 32,
        "ownerRoot": owner,
        "subject": subject,
        "executable": {
            "path": str(executable),
            "sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
        },
        "program": {
            "path": str(program),
            "sha256": hashlib.sha256(program.read_bytes()).hexdigest(),
        },
        "argv": [
            str(executable),
            "-I",
            "-S",
            "-B",
            str(program),
            "--root",
            str(app_root),
            "--expected-flutter-root",
            str(flutter_root),
            "--toolchain-root",
            str(android_sdk_root),
            "--toolchain-root",
            str(jdk_root),
            "--toolchain-root",
            str(flutter_settings),
            "--toolchain-root",
            str(pathlib.Path(sys.base_prefix).resolve()),
            "--backend",
            "darwin-fsevents",
            "--stop-file",
            str(stop_path),
            "--ready-file",
            str(readiness_path),
            "--events-file",
            str(isolated_root / "bootstrap-source-tree-guard-events.jsonl"),
            "--result-file",
            str(guard_result_path),
            "--baseline-manifest",
            str(root / "tested-files.bootstrap.sha256"),
            "--baseline-sidecar",
            str(root / "bootstrap-source-tree-guard-baseline.json"),
            "--nonce",
            readiness["nonce"],
        ],
        "readiness": {
            "path": str(readiness_path),
            "sha256": hashlib.sha256(readiness_path.read_bytes()).hexdigest(),
            "nonce": readiness["nonce"],
            "stopPath": str(stop_path),
            "resultPath": str(guard_result_path),
        },
        "roots": expected_roots,
        "allowedRootKeys": ["home", "isolatedUserRoot"],
    }
    authority_bytes = _canonical_json(authority)
    reference_authority_bytes = _canonical_json(reference_authority)
    authority_entry = {
        "path": str(authority_path),
        "sha256": hashlib.sha256(authority_bytes).hexdigest(),
        "launchId": authority["launchId"],
    }
    reference_authority_entry = {
        "path": str(reference_authority_path),
        "sha256": hashlib.sha256(reference_authority_bytes).hexdigest(),
        "exemptionId": reference_authority["exemptionId"],
    }
    exempt_process = {
        "identity": subject,
        "state": 3,
        "executable": str(executable),
        "argv": reference_authority["argv"],
        "environmentSha256": "4" * 64,
        "cwd": None,
        "root": "/",
        "openVnodePaths": [str(isolated_root / "home")],
        "inspectionErrors": [],
        "vnodeEvidenceMethod": "libproc",
        "vnodeEvidenceComplete": True,
    }
    scope = {
        "version": 3,
        "status": "quiescent",
        "marker": "TELLTALE_GATE_C_PROCESS_SCOPE",
        "ownerRoot": owner,
        "roots": expected_roots,
        "authorities": [authority_entry],
        "referenceAuthorities": [reference_authority_entry],
        "authorizedSessions": [leader["sid"]],
        "startedMonotonicNs": 10,
        "endedMonotonicNs": 20,
        "stoppedProcesses": [],
        "termSentProcesses": [],
        "killSentProcesses": [],
        "remainingOwnedProcesses": [],
        "foreignProcesses": [],
        "referenceExemptProcesses": [
            {
                "exemptionId": reference_authority["exemptionId"],
                "process": exempt_process,
                "reasons": [
                    "argv:isolatedUserRoot",
                    "env:HOME:home",
                    "openFd:home",
                    "openFd:isolatedUserRoot",
                ],
            }
        ],
        "inspectionLimitations": [],
        "referenceInspection": {
            "complete": True,
            "lsof": _lsof_seal(),
            "fallbackProcesses": [],
        },
    }
    scope_bytes = _canonical_json(scope)
    result = {
        "version": 1,
        "label": "android-sdk-sandbox-probe",
        "status": "completed",
        "commandExitCode": 0,
        "authority": authority,
        "scopeTermination": scope,
        "authoritySha256": hashlib.sha256(authority_bytes).hexdigest(),
        "childPid": leader["pid"],
        "scopeEvidenceSha256": hashlib.sha256(scope_bytes).hexdigest(),
    }
    allowed_names = sorted(preflight.CHILD_ENVIRONMENT_ALLOWED_NAMES)
    actual_names = sorted(preflight.CHILD_ENVIRONMENT_ALLOWED_NAMES)
    environment = {
        "schema": preflight.CHILD_ENVIRONMENT_SCHEMA,
        "version": 2,
        "launchId": authority["launchId"],
        "allowedNames": allowed_names,
        "allowedNamesSha256": _canonical_json_sha256(allowed_names),
        "actualNames": actual_names,
        "actualNamesSha256": _canonical_json_sha256(actual_names),
        "actualNamesObservationPoint": "cooperative-sealed-wrapper-pre-release-barrier-v1",
        "producerPlannedEnvironmentValuesSha256": "5" * 64,
        "plannedNamesMatchBarrier": True,
        "valuesObserved": False,
        "postBarrierAddedNames": [
            "FLUTTER_ALREADY_LOCKED",
            "JAVA_TOOL_OPTIONS",
            "TMPDIR",
        ],
        "credentialNamesAssertedAbsent": sorted(
            preflight.CHILD_ENVIRONMENT_CREDENTIAL_NAMES
        ),
        "forbiddenCredentialNamesPresent": [],
    }
    return {
        "authority": authority,
        "environment": environment,
        "reference_authority": reference_authority,
        "scope": scope,
        "result": result,
        "authority_path": authority_path,
        "environment_path": environment_path,
        "reference_authority_path": reference_authority_path,
        "reference_authority_paths": [reference_authority_path],
        "scope_path": scope_path,
        "result_path": result_path,
        "roots": roots,
        "components": {
            "wrapper": wrapper,
            "python": executable,
            "processScope": process_scope,
            "referenceExecutable": executable,
            "referenceProgram": program,
            "referenceReadiness": readiness_path,
        },
        "owner_root_pid": owner["pid"],
    }


def _write_session_fixture(fixture, *, rebind=True):
    authority_bytes = _canonical_json(fixture["authority"])
    reference_authority_bytes = _canonical_json(fixture["reference_authority"])
    if rebind:
        fixture["scope"]["authorities"][0]["sha256"] = hashlib.sha256(
            authority_bytes
        ).hexdigest()
        fixture["scope"]["authorities"][0]["launchId"] = fixture["authority"].get(
            "launchId"
        )
        fixture["scope"]["referenceAuthorities"][0].update(
            {
                "sha256": hashlib.sha256(reference_authority_bytes).hexdigest(),
                "exemptionId": fixture["reference_authority"].get("exemptionId"),
            }
        )
        fixture["result"]["authority"] = deepcopy(fixture["authority"])
        fixture["result"]["authoritySha256"] = hashlib.sha256(
            authority_bytes
        ).hexdigest()
        fixture["result"]["scopeTermination"] = deepcopy(fixture["scope"])
    scope_bytes = _canonical_json(fixture["scope"])
    if rebind:
        fixture["result"]["scopeEvidenceSha256"] = hashlib.sha256(
            scope_bytes
        ).hexdigest()
    fixture["authority_path"].write_bytes(authority_bytes)
    if rebind:
        fixture["environment"]["launchId"] = fixture["authority"].get("launchId")
    fixture["environment_path"].write_bytes(_canonical_json(fixture["environment"]))
    fixture["environment_path"].chmod(0o600)
    fixture["reference_authority_path"].write_bytes(reference_authority_bytes)
    fixture["scope_path"].write_bytes(scope_bytes)
    fixture["result_path"].write_bytes(_canonical_json(fixture["result"]))


class AndroidSdkSandboxContractTest(unittest.TestCase):
    _FLUTTER_GRADLE_PROJECT_DIRECTORY = "packages/flutter_tools/gradle"
    _FLUTTER_PROJECT_WRITABILITY_DIRECTORIES = (
        _FLUTTER_GRADLE_PROJECT_DIRECTORY,
        "packages/integration_test/android",
    )
    _FLUTTER_GRADLE_GENERATED_DIRECTORIES = (
        "packages/flutter_tools/gradle/.gradle",
        "packages/flutter_tools/gradle/build",
        "packages/flutter_tools/gradle/.kotlin",
    )

    def _run_sandboxed(self, roots, *command):
        arguments = ["/usr/bin/sandbox-exec"]
        for name, value in roots.items():
            arguments.extend(("-D", f"{name}={value}"))
        arguments.extend(
            (
                "-f",
                str(HERE / "android_sdk_write_deny.sb"),
                "--",
                *command,
            )
        )
        return subprocess.run(
            arguments,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def _sandbox_roots(self, temporary):
        roots = {
            "APP_ROOT": temporary / "app",
            "FLUTTER_ROOT": temporary / "flutter",
            "PUB_CACHE": temporary / "pub-cache",
            "GRADLE_HOME": temporary / "gradle-home",
            "ISOLATED_ROOT": temporary / "isolated-root",
            "RUN_TEMP": temporary / "run-temp",
        }
        for root in roots.values():
            root.mkdir()
        return roots

    def _assert_generated_file_is_writable(self, relative_directory):
        with tempfile.TemporaryDirectory(
            prefix=".telltale-flutter-generated-sandbox-",
            dir=pathlib.Path.home(),
        ) as temporary_text:
            roots = self._sandbox_roots(pathlib.Path(temporary_text))
            gradle_root = roots["FLUTTER_ROOT"] / "packages/flutter_tools/gradle"
            gradle_root.mkdir(parents=True)
            generated_directory = roots["FLUTTER_ROOT"] / relative_directory
            generated = generated_directory / "fixture.bin"

            created = self._run_sandboxed(
                roots,
                "/bin/sh",
                "-c",
                '/bin/mkdir -p "$1" && printf "%s" generated > "$2"',
                "sh",
                str(generated_directory),
                str(generated),
            )
            modified = self._run_sandboxed(
                roots,
                "/bin/sh",
                "-c",
                'printf "%s" modified > "$1"',
                "sh",
                str(generated),
            )

            self.assertEqual(created.returncode, 0, created.stderr)
            self.assertEqual(modified.returncode, 0, modified.stderr)
            self.assertEqual(generated.read_bytes(), b"modified")

    def _assert_flutter_gradle_source_is_immutable(self, relative_file, *, atomic):
        with tempfile.TemporaryDirectory(
            prefix=".telltale-flutter-source-sandbox-",
            dir=pathlib.Path.home(),
        ) as temporary_text:
            roots = self._sandbox_roots(pathlib.Path(temporary_text))
            source = roots["FLUTTER_ROOT"] / relative_file
            source.parent.mkdir(parents=True)
            source.write_bytes(b"sealed-source\n")
            before_bytes = source.read_bytes()
            before_stat = source.stat()
            temporary_source = source.with_name(f"{source.name}.tmp.fixture")
            if atomic:
                temporary_source.write_bytes(b"replacement\n")
                command = (
                    "/bin/mv",
                    str(temporary_source),
                    str(source),
                )
            else:
                command = (
                    "/usr/bin/touch",
                    "-t",
                    "200001010000",
                    str(source),
                )

            completed = self._run_sandboxed(roots, *command)

            self.assertNotEqual(completed.returncode, 0)
            self.assertEqual(temporary_source.exists(), atomic)
            self.assertEqual(source.read_bytes(), before_bytes)
            self.assertEqual(source.stat().st_mtime_ns, before_stat.st_mtime_ns)

    def _assert_flutter_source_content_write_is_denied(self, relative_file):
        with tempfile.TemporaryDirectory(
            prefix=".telltale-flutter-source-overwrite-sandbox-",
            dir=pathlib.Path.home(),
        ) as temporary_text:
            roots = self._sandbox_roots(pathlib.Path(temporary_text))
            source = roots["FLUTTER_ROOT"] / relative_file
            source.parent.mkdir(parents=True)
            source.write_bytes(b"sealed-source\n")
            before_bytes = source.read_bytes()
            before_stat = source.stat()

            completed = self._run_sandboxed(
                roots,
                "/bin/sh",
                "-c",
                'printf "%s" replacement > "$1"',
                "sh",
                str(source),
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertEqual(source.read_bytes(), before_bytes)
            self.assertEqual(source.stat().st_mtime_ns, before_stat.st_mtime_ns)

    def test_profile_is_deny_default_and_has_only_named_write_roots(self):
        profile = (HERE / "android_sdk_write_deny.sb").read_text(encoding="utf-8")
        self.assertIn("(deny default)", profile)
        self.assertNotIn("(allow default)", profile)
        for operation in (
            "process*",
            "file-read*",
            "network*",
            "sysctl*",
            "mach*",
            "ipc*",
            "iokit*",
            "system*",
        ):
            self.assertIn(f"(allow {operation})", profile)
        for root in (
            "APP_ROOT",
            "PUB_CACHE",
            "GRADLE_HOME",
            "ISOLATED_ROOT",
            "RUN_TEMP",
        ):
            self.assertIn(f'(subpath (param "{root}"))', profile)
        self.assertNotIn('(subpath (param "FLUTTER_ROOT"))', profile)
        self.assertIn('(subpath "/private/tmp")', profile)
        self.assertIn('(subpath "/dev")', profile)
        self.assertNotIn('ANDROID_SDK_ROOT"))', profile)

    def test_profile_allows_only_named_flutter_gradle_generated_directories(self):
        profile = (HERE / "android_sdk_write_deny.sb").read_text(encoding="utf-8")
        for relative in self._FLUTTER_PROJECT_WRITABILITY_DIRECTORIES:
            project_directory = re.escape(
                f'(literal (string-append (param "FLUTTER_ROOT") "/{relative}"))'
            )
            with self.subTest(project_directory=relative):
                self.assertRegex(
                    profile,
                    rf"\(allow file-write-data\s+{project_directory}\s*\)",
                )
                self.assertNotRegex(
                    profile,
                    rf"\(allow file-write\*\s+{project_directory}\s*\)",
                )
        for relative in self._FLUTTER_GRADLE_GENERATED_DIRECTORIES:
            self.assertIn(
                f'(subpath (string-append (param "FLUTTER_ROOT") "/{relative}"))',
                profile,
            )
        self.assertNotIn('(subpath (param "FLUTTER_ROOT"))', profile)

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS sandbox-exec")
    def test_profile_allows_only_flutter_gradle_project_writability_probe(self):
        with tempfile.TemporaryDirectory(
            prefix=".telltale-flutter-gradle-root-probe-",
            dir=pathlib.Path.home(),
        ) as temporary_text:
            roots = self._sandbox_roots(pathlib.Path(temporary_text))
            for relative in self._FLUTTER_PROJECT_WRITABILITY_DIRECTORIES:
                project_directory = roots["FLUTTER_ROOT"] / relative
                project_directory.mkdir(parents=True)

                completed = self._run_sandboxed(
                    roots,
                    "/usr/bin/python3",
                    "-I",
                    "-S",
                    "-B",
                    "-c",
                    "import os, sys; print(os.access(sys.argv[1], os.W_OK))",
                    str(project_directory),
                )

                with self.subTest(project_directory=relative):
                    self.assertEqual(completed.returncode, 0, completed.stderr)
                    self.assertEqual(completed.stdout.strip(), "True")

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS sandbox-exec")
    def test_profile_denies_flutter_gradle_project_root_rename(self):
        with tempfile.TemporaryDirectory(
            prefix=".telltale-flutter-gradle-root-rename-",
            dir=pathlib.Path.home(),
        ) as temporary_text:
            roots = self._sandbox_roots(pathlib.Path(temporary_text))
            for relative in self._FLUTTER_PROJECT_WRITABILITY_DIRECTORIES:
                project_directory = roots["FLUTTER_ROOT"] / relative
                project_directory.mkdir(parents=True)
                (project_directory / "sealed-source").write_text(
                    "sealed-source\n",
                    encoding="utf-8",
                )
                renamed = roots["APP_ROOT"] / f"moved-{project_directory.name}"

                completed = self._run_sandboxed(
                    roots,
                    "/bin/mv",
                    str(project_directory),
                    str(renamed),
                )

                with self.subTest(project_directory=relative):
                    self.assertNotEqual(completed.returncode, 0)
                    self.assertTrue(project_directory.is_dir())
                    self.assertFalse(renamed.exists())

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS sandbox-exec")
    def test_profile_denies_flutter_integration_test_root_file_creation(self):
        with tempfile.TemporaryDirectory(
            prefix=".telltale-flutter-integration-root-create-",
            dir=pathlib.Path.home(),
        ) as temporary_text:
            roots = self._sandbox_roots(pathlib.Path(temporary_text))
            project_directory = (
                roots["FLUTTER_ROOT"] / "packages/integration_test/android"
            )
            project_directory.mkdir(parents=True)
            target = project_directory / "unexpected-generated-file"

            completed = self._run_sandboxed(
                roots,
                "/bin/sh",
                "-c",
                'printf "%s" forbidden > "$1"',
                "sh",
                str(target),
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertFalse(target.exists())

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS sandbox-exec")
    def test_profile_denies_arbitrary_flutter_root_file_creation(self):
        with tempfile.TemporaryDirectory(
            prefix=".telltale-flutter-root-sandbox-",
            dir=pathlib.Path.home(),
        ) as temporary_text:
            roots = self._sandbox_roots(pathlib.Path(temporary_text))
            target = roots["FLUTTER_ROOT"] / "unexpected-generated-file"

            completed = self._run_sandboxed(
                roots,
                "/bin/sh",
                "-c",
                'printf "%s" forbidden > "$1"',
                "sh",
                str(target),
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertFalse(target.exists())

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS sandbox-exec")
    def test_profile_denies_flutter_version_check_stamp_creation(self):
        with tempfile.TemporaryDirectory(
            prefix=".telltale-flutter-version-check-sandbox-",
            dir=pathlib.Path.home(),
        ) as temporary_text:
            roots = self._sandbox_roots(pathlib.Path(temporary_text))
            target = (
                roots["FLUTTER_ROOT"] / "bin" / "cache" / "flutter_version_check.stamp"
            )
            target.parent.mkdir(parents=True)

            completed = self._run_sandboxed(
                roots,
                "/bin/sh",
                "-c",
                'printf "%s" forbidden > "$1"',
                "sh",
                str(target),
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertFalse(target.exists())

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS sandbox-exec")
    def test_profile_denies_flutter_version_check_stamp_overwrite(self):
        with tempfile.TemporaryDirectory(
            prefix=".telltale-flutter-version-check-overwrite-sandbox-",
            dir=pathlib.Path.home(),
        ) as temporary_text:
            roots = self._sandbox_roots(pathlib.Path(temporary_text))
            target = (
                roots["FLUTTER_ROOT"] / "bin" / "cache" / "flutter_version_check.stamp"
            )
            target.parent.mkdir(parents=True)
            target.write_bytes(b"sealed-version-check\n")
            before_bytes = target.read_bytes()
            before_stat = target.stat()

            completed = self._run_sandboxed(
                roots,
                "/bin/sh",
                "-c",
                'printf "%s" replacement > "$1"',
                "sh",
                str(target),
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertEqual(target.read_bytes(), before_bytes)
            self.assertEqual(target.stat().st_mtime_ns, before_stat.st_mtime_ns)

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS sandbox-exec")
    def test_profile_allows_flutter_gradle_dot_gradle_generated_file_write(self):
        self._assert_generated_file_is_writable("packages/flutter_tools/gradle/.gradle")

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS sandbox-exec")
    def test_profile_allows_flutter_gradle_build_generated_file_write(self):
        self._assert_generated_file_is_writable("packages/flutter_tools/gradle/build")

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS sandbox-exec")
    def test_profile_allows_flutter_gradle_kotlin_errors_generated_file_write(self):
        self._assert_generated_file_is_writable(
            "packages/flutter_tools/gradle/.kotlin/errors"
        )

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS sandbox-exec")
    def test_profile_denies_flutter_gradle_settings_metadata_write(self):
        self._assert_flutter_gradle_source_is_immutable(
            "packages/flutter_tools/gradle/settings.gradle.kts",
            atomic=False,
        )

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS sandbox-exec")
    def test_profile_denies_flutter_gradle_settings_atomic_replace(self):
        self._assert_flutter_gradle_source_is_immutable(
            "packages/flutter_tools/gradle/settings.gradle.kts",
            atomic=True,
        )

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS sandbox-exec")
    def test_profile_denies_flutter_gradle_settings_content_overwrite(self):
        self._assert_flutter_source_content_write_is_denied(
            "packages/flutter_tools/gradle/settings.gradle.kts",
        )

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS sandbox-exec")
    def test_profile_denies_flutter_gradle_build_script_metadata_write(self):
        self._assert_flutter_gradle_source_is_immutable(
            "packages/flutter_tools/gradle/build.gradle.kts",
            atomic=False,
        )

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS sandbox-exec")
    def test_profile_denies_flutter_gradle_build_script_atomic_replace(self):
        self._assert_flutter_gradle_source_is_immutable(
            "packages/flutter_tools/gradle/build.gradle.kts",
            atomic=True,
        )

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS sandbox-exec")
    def test_profile_denies_flutter_integration_test_build_script_metadata_write(self):
        self._assert_flutter_gradle_source_is_immutable(
            "packages/integration_test/android/build.gradle.kts",
            atomic=False,
        )

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS sandbox-exec")
    def test_profile_denies_flutter_integration_test_build_script_atomic_replace(self):
        self._assert_flutter_gradle_source_is_immutable(
            "packages/integration_test/android/build.gradle.kts",
            atomic=True,
        )

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS sandbox-exec")
    def test_profile_denies_flutter_integration_test_build_script_content_overwrite(
        self,
    ):
        self._assert_flutter_source_content_write_is_denied(
            "packages/integration_test/android/build.gradle.kts",
        )

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS sandbox-exec")
    def test_profile_denies_generated_root_symlink_escape(self):
        with tempfile.TemporaryDirectory(
            prefix=".telltale-flutter-generated-symlink-escape-",
            dir=pathlib.Path.home(),
        ) as temporary_text:
            roots = self._sandbox_roots(pathlib.Path(temporary_text))
            sealed_source = (
                roots["FLUTTER_ROOT"]
                / self._FLUTTER_GRADLE_PROJECT_DIRECTORY
                / "settings.gradle.kts"
            )
            sealed_source.parent.mkdir(parents=True)
            sealed_source.write_bytes(b"sealed-source\n")

            for relative in self._FLUTTER_GRADLE_GENERATED_DIRECTORIES:
                generated_directory = roots["FLUTTER_ROOT"] / relative
                generated_directory.mkdir(parents=True)
                escape = generated_directory / "escape"
                escape.symlink_to(sealed_source)
                before_bytes = sealed_source.read_bytes()
                before_stat = sealed_source.stat()

                completed = self._run_sandboxed(
                    roots,
                    "/bin/sh",
                    "-c",
                    'printf "%s" replacement > "$1"',
                    "sh",
                    str(escape),
                )

                with self.subTest(generated_directory=relative):
                    self.assertNotEqual(completed.returncode, 0)
                    self.assertEqual(sealed_source.read_bytes(), before_bytes)
                    self.assertEqual(
                        sealed_source.stat().st_mtime_ns,
                        before_stat.st_mtime_ns,
                    )

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS sandbox-exec")
    def test_profile_denies_flutter_engine_stamp_metadata_write(self):
        profile = HERE / "android_sdk_write_deny.sb"
        home = pathlib.Path.home()
        with tempfile.TemporaryDirectory(
            prefix=".telltale-flutter-sandbox-",
            dir=home,
        ) as temporary_text:
            temporary = pathlib.Path(temporary_text)
            roots = {
                "APP_ROOT": temporary / "app",
                "FLUTTER_ROOT": temporary / "flutter",
                "PUB_CACHE": temporary / "pub-cache",
                "GRADLE_HOME": temporary / "gradle-home",
                "ISOLATED_ROOT": temporary / "isolated-root",
                "RUN_TEMP": temporary / "run-temp",
            }
            for root in roots.values():
                root.mkdir()
            engine_stamp = roots["FLUTTER_ROOT"] / "bin" / "cache" / "engine.stamp"
            engine_stamp.parent.mkdir(parents=True)
            engine_stamp.write_text("sealed-engine\n", encoding="utf-8")
            before_bytes = engine_stamp.read_bytes()
            before_stat = engine_stamp.stat()

            arguments = ["/usr/bin/sandbox-exec"]
            for name, value in roots.items():
                arguments.extend(("-D", f"{name}={value}"))
            arguments.extend(
                (
                    "-f",
                    str(profile),
                    "--",
                    "/usr/bin/touch",
                    "-t",
                    "200001010000",
                    str(engine_stamp),
                )
            )
            completed = subprocess.run(
                arguments,
                capture_output=True,
                text=True,
                timeout=10,
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertEqual(engine_stamp.read_bytes(), before_bytes)
            self.assertEqual(engine_stamp.stat().st_mtime_ns, before_stat.st_mtime_ns)

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS sandbox-exec")
    def test_profile_denies_flutter_engine_stamp_atomic_replace(self):
        profile = HERE / "android_sdk_write_deny.sb"
        with tempfile.TemporaryDirectory(
            prefix=".telltale-flutter-rename-sandbox-",
            dir=pathlib.Path.home(),
        ) as temporary_text:
            temporary = pathlib.Path(temporary_text)
            roots = {
                "APP_ROOT": temporary / "app",
                "FLUTTER_ROOT": temporary / "flutter",
                "PUB_CACHE": temporary / "pub-cache",
                "GRADLE_HOME": temporary / "gradle-home",
                "ISOLATED_ROOT": temporary / "isolated-root",
                "RUN_TEMP": temporary / "run-temp",
            }
            for root in roots.values():
                root.mkdir()
            engine_stamp = roots["FLUTTER_ROOT"] / "bin" / "cache" / "engine.stamp"
            engine_stamp.parent.mkdir(parents=True)
            engine_stamp.write_text("sealed-engine\n", encoding="utf-8")
            before_bytes = engine_stamp.read_bytes()
            before_stat = engine_stamp.stat()
            temporary_stamp = engine_stamp.with_name("engine.stamp.tmp.fixture")

            arguments = ["/usr/bin/sandbox-exec"]
            for name, value in roots.items():
                arguments.extend(("-D", f"{name}={value}"))
            arguments.extend(
                (
                    "-f",
                    str(profile),
                    "--",
                    "/bin/sh",
                    "-c",
                    'printf "%s\\n" replacement > "$1" && /bin/mv "$1" "$2"',
                    "sh",
                    str(temporary_stamp),
                    str(engine_stamp),
                )
            )
            completed = subprocess.run(
                arguments,
                capture_output=True,
                text=True,
                timeout=10,
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertFalse(temporary_stamp.exists())
            self.assertEqual(engine_stamp.read_bytes(), before_bytes)
            self.assertEqual(engine_stamp.stat().st_mtime_ns, before_stat.st_mtime_ns)

    def test_wrapper_has_fixed_interface_and_exact_system_binary(self):
        wrapper = (HERE / "android_sdk_sandbox_exec.sh").read_text(encoding="utf-8")
        self.assertIn("[[ $1 == -- ]]", wrapper)
        self.assertIn("exec /usr/bin/sandbox-exec", wrapper)
        self.assertNotIn("eval ", wrapper)
        self.assertNotIn("ulimit -n", wrapper)
        self.assertIn("/dev/fd/*(N)", wrapper)
        self.assertIn(
            'export TMPDIR="$TELLTALE_GATE_C_SANDBOX_RUN_TEMP"',
            wrapper,
        )
        self.assertIn("export FLUTTER_ALREADY_LOCKED=true", wrapper)
        self.assertGreater(
            wrapper.index("export FLUTTER_ALREADY_LOCKED=true"),
            wrapper.index("[[ $barrier_byte == G ]]"),
        )
        self.assertLess(
            wrapper.index("export FLUTTER_ALREADY_LOCKED=true"),
            wrapper.index("exec /usr/bin/sandbox-exec"),
        )
        self.assertIn("${#TELLTALE_GATE_C_PROCESS_SCOPE} == 32", wrapper)
        self.assertIn("$TELLTALE_GATE_C_PROCESS_SCOPE != *[^0-9a-f]*", wrapper)
        self.assertNotIn("export TELLTALE_GATE_C_PROCESS_SCOPE=", wrapper)
        self.assertIn("TELLTALE_GATE_C_LAUNCH_RELEASE_FD", wrapper)
        self.assertIn("TELLTALE_GATE_C_LAUNCH_READY_FD", wrapper)
        self.assertIn(
            "builtin print -r -u $ready_fd -- TELLTALE_GATE_C_CHILD_ENVIRONMENT_V1",
            wrapper,
        )
        self.assertIn('"launchId=$TELLTALE_GATE_C_PROCESS_SCOPE"', wrapper)
        self.assertIn("for environment_name in ${(ko)parameters}", wrapper)
        self.assertIn("${(tP)environment_name} == *-export*", wrapper)
        self.assertIn("exported_environment_names+=($environment_name)", wrapper)
        self.assertIn("builtin print -r -u $ready_fd -- .", wrapper)
        self.assertIn("read -r -k 1 -u $release_fd barrier_byte", wrapper)
        self.assertIn("[[ $barrier_byte == G ]]", wrapper)
        self.assertIn("exec {ready_fd}>&-", wrapper)
        self.assertIn("exec {release_fd}<&-", wrapper)
        self.assertLess(
            wrapper.index("exec {ready_fd}>&-"),
            wrapper.index("read -r -k 1 -u $release_fd barrier_byte"),
        )
        self.assertIn(
            'export JAVA_TOOL_OPTIONS="-Djava.io.tmpdir='
            "$TELLTALE_GATE_C_SANDBOX_RUN_TEMP "
            "-Duser.home=$TELLTALE_GATE_C_SANDBOX_ISOLATED_ROOT/home "
            "-Dkotlin.daemon.options=runFilesPath="
            '$TELLTALE_GATE_C_SANDBOX_RUN_TEMP/kotlin-daemon"',
            wrapper,
        )
        for suffix in (
            "PROFILE",
            "APP_ROOT",
            "FLUTTER_ROOT",
            "PUB_CACHE",
            "GRADLE_HOME",
            "ISOLATED_ROOT",
            "RUN_TEMP",
            "ANDROID_SDK_ROOT",
        ):
            self.assertIn(f"TELLTALE_GATE_C_SANDBOX_{suffix}", wrapper)

    def test_sdk_must_be_disjoint_from_every_write_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            sdk = root / "sdk"
            sdk.mkdir()
            with self.assertRaisesRegex(ValueError, "overlaps write root"):
                preflight.validate_disjoint_sdk(sdk, [root])
            nested = sdk / "nested"
            nested.mkdir()
            with self.assertRaisesRegex(ValueError, "overlaps write root"):
                preflight.validate_disjoint_sdk(sdk, [nested])
        for sdk in (pathlib.Path("/private/tmp/sdk"), pathlib.Path("/dev/sdk")):
            with self.assertRaisesRegex(ValueError, "profile write root"):
                preflight.validate_disjoint_sdk(sdk, [])

    def test_flutter_sdk_must_be_disjoint_from_every_write_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            app_root = root / "app"
            flutter_root = app_root / "flutter-sdk"
            flutter_root.mkdir(parents=True)
            with self.assertRaisesRegex(ValueError, "Flutter SDK overlaps write root"):
                preflight.validate_read_only_root(
                    flutter_root,
                    "Flutter SDK",
                    [app_root],
                )
        for flutter_root in (
            pathlib.Path("/private/tmp/flutter-sdk"),
            pathlib.Path("/dev/flutter-sdk"),
        ):
            with self.assertRaisesRegex(
                ValueError,
                "Flutter SDK overlaps profile write root",
            ):
                preflight.validate_read_only_root(
                    flutter_root,
                    "Flutter SDK",
                    [],
                )

    def test_symlink_and_unsafe_component_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            real = root / "real"
            real.write_text("x", encoding="utf-8")
            linked = root / "linked"
            linked.symlink_to(real)
            with self.assertRaisesRegex(ValueError, "symlink"):
                preflight.validate_regular_file(linked, "component")
            real.chmod(0o666)
            with self.assertRaisesRegex(ValueError, "writable"):
                preflight.validate_regular_file(real, "component")

    def test_fingerprint_detects_metadata_and_xattr_tamper(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "cache"
            path.write_bytes(b"0123456789abcdef")
            before = preflight.file_fingerprint(path)
            path.chmod(0o600)
            after = preflight.file_fingerprint(path)
            self.assertNotEqual(before, after)
            self.assertEqual(before["sha256"], after["sha256"])

    def test_atomic_evidence_is_exclusive_private_and_canonical(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "result.json"
            value = {"z": 1, "a": [True, None]}
            preflight.write_evidence(path, value)
            self.assertEqual(path.read_bytes(), b'{"a":[true,null],"z":1}\n')
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            with self.assertRaises(FileExistsError):
                preflight.write_evidence(path, value)

    def test_prepared_evidence_reader_rejects_digest_mismatch_before_parsing(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "prepared.json"
            value = {
                "version": 1,
                "status": "prepared",
                "paths": {},
                "components": {},
                "sandboxExec": {},
                "androidSdk": {},
                "probe": {},
                "sessionProof": {},
            }
            prepared_bytes = (json.dumps(value, separators=(",", ":")) + "\n").encode()
            path.write_bytes(prepared_bytes)
            expected_sha256 = hashlib.sha256(prepared_bytes).hexdigest()

            self.assertEqual(
                preflight.read_prepared_evidence(path, expected_sha256),
                {**value, "evidenceSha256": expected_sha256},
            )

            path.write_text("not-json\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "digest mismatch"):
                preflight.read_prepared_evidence(path, expected_sha256)

    def test_prepared_evidence_reader_rejects_duplicate_json_keys(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "prepared.json"
            value = {
                "version": 1,
                "status": "prepared",
                "paths": {},
                "components": {},
                "sandboxExec": {},
                "androidSdk": {},
                "probe": {},
                "sessionProof": {},
            }
            prepared_bytes = _add_duplicate_top_level_key(
                _canonical_json(value),
                "version",
                1,
            )
            path.write_bytes(prepared_bytes)

            with self.assertRaisesRegex(ValueError, "duplicate key.*version"):
                preflight.read_prepared_evidence(
                    path,
                    hashlib.sha256(prepared_bytes).hexdigest(),
                )

    def test_evidence_decoder_rejects_nested_duplicate_json_keys(self):
        with self.assertRaisesRegex(ValueError, "duplicate key.*pid"):
            preflight._decode_evidence_json(
                '{"outer":{"pid":101,"pid":101}}',
                "nested fixture",
            )

    def test_verify_rejects_component_or_cache_change(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            component = root / "component"
            cache = root / ".knownPackages"
            component.write_text("component", encoding="utf-8")
            cache.write_bytes(b"0123456789abcdef")
            component_fingerprint = preflight.file_fingerprint(component)
            canonical_root = preflight.validate_directory(root, "fixture root")
            evidence = {
                "version": 1,
                "status": "prepared",
                "evidenceSha256": "e" * 64,
                "paths": {name: str(canonical_root) for name in preflight.PATH_KEYS},
                "components": {
                    name: component_fingerprint for name in preflight.COMPONENT_KEYS
                },
                "sandboxExec": {
                    **component_fingerprint,
                    "verified": True,
                    "identifier": "com.apple.sandbox-exec",
                    "cdHash": "a" * 40,
                },
                "androidSdk": {
                    "knownPackages": preflight.file_fingerprint(cache),
                },
                "probe": _probe_result(),
                "sessionProof": {
                    "authority": preflight.file_fingerprint(cache),
                    "environment": preflight.file_fingerprint(cache),
                    "scope": preflight.file_fingerprint(cache),
                    "result": preflight.file_fingerprint(cache),
                    "referenceAuthorities": [preflight.file_fingerprint(cache)],
                },
            }
            component.write_text("tampered", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "component changed"):
                preflight.verify_prepared(evidence)

    @mock.patch.object(preflight.subprocess, "run")
    def test_codesign_identity_requires_verify_identifier_and_cdhash(self, run):
        binary = pathlib.Path("/usr/bin/sandbox-exec")
        run.side_effect = [
            mock.Mock(returncode=0, stdout="", stderr="valid on disk\n"),
            mock.Mock(
                returncode=0,
                stdout="",
                stderr="Identifier=com.apple.sandbox-exec\nCDHash=abc123\n",
            ),
        ]
        with mock.patch.object(preflight, "file_fingerprint") as fingerprint:
            fingerprint.return_value = {"path": str(binary), "sha256": "0" * 64}
            value = preflight.codesign_identity(binary)
        self.assertEqual(value["identifier"], "com.apple.sandbox-exec")
        self.assertEqual(value["cdHash"], "abc123")
        self.assertTrue(value["verified"])

    @mock.patch.object(preflight.subprocess, "run")
    def test_codesign_identity_rejects_wrong_identifier(self, run):
        run.side_effect = [
            mock.Mock(returncode=0, stdout="", stderr="valid on disk\n"),
            mock.Mock(
                returncode=0,
                stdout="",
                stderr="Identifier=evil.sandbox-exec\nCDHash=abc123\n",
            ),
        ]
        with mock.patch.object(preflight, "file_fingerprint") as fingerprint:
            fingerprint.return_value = {
                "path": "/usr/bin/sandbox-exec",
                "sha256": "0" * 64,
            }
            with self.assertRaisesRegex(ValueError, "unexpected identifier"):
                preflight.codesign_identity(pathlib.Path("/usr/bin/sandbox-exec"))

    def test_wrapper_direct_invocation_fails_closed_before_command(self):
        wrapper = HERE / "android_sdk_sandbox_exec.sh"
        environment = os.environ.copy()
        for suffix in (
            "PROFILE",
            "APP_ROOT",
            "FLUTTER_ROOT",
            "PUB_CACHE",
            "GRADLE_HOME",
            "ISOLATED_ROOT",
            "RUN_TEMP",
            "ANDROID_SDK_ROOT",
        ):
            environment[f"TELLTALE_GATE_C_SANDBOX_{suffix}"] = "/nonempty"
        completed = subprocess.run(
            [str(wrapper), "--", "/usr/bin/true"],
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 64)
        self.assertIn(
            "missing exported TELLTALE_GATE_C_PROCESS_SCOPE",
            completed.stderr,
        )

    def test_session_result_accepts_only_exact_bound_schema(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            baseline = _session_fixture(root)
            _write_session_fixture(baseline)
            preflight.validate_session_result(
                authority_path=baseline["authority_path"],
                scope_path=baseline["scope_path"],
                result_path=baseline["result_path"],
                roots=baseline["roots"],
                components=baseline["components"],
                owner_root_pid=baseline["owner_root_pid"],
                reference_authority_paths=baseline["reference_authority_paths"],
            )

            mutations = (
                ("authority extra", lambda item: item["authority"].update(extra=True)),
                (
                    "authority launch ID",
                    lambda item: item["authority"].update(launchId="1" * 31),
                ),
                ("scope extra", lambda item: item["scope"].update(extra=True)),
                (
                    "session binding",
                    lambda item: item["scope"].update(authorizedSessions=[999]),
                ),
                (
                    "lsof seal",
                    lambda item: item["scope"]["referenceInspection"]["lsof"].update(
                        extra=True
                    ),
                ),
                ("result extra", lambda item: item["result"].update(extra=True)),
            )
            for label, mutate in mutations:
                with self.subTest(label=label):
                    fixture = _session_fixture(root)
                    mutate(fixture)
                    _write_session_fixture(fixture)
                    with self.assertRaises(ValueError):
                        preflight.validate_session_result(
                            authority_path=fixture["authority_path"],
                            scope_path=fixture["scope_path"],
                            result_path=fixture["result_path"],
                            roots=fixture["roots"],
                            components=fixture["components"],
                            owner_root_pid=fixture["owner_root_pid"],
                            reference_authority_paths=fixture[
                                "reference_authority_paths"
                            ],
                        )

    def test_session_result_requires_private_bound_child_environment(self):
        def validate(fixture):
            preflight.validate_session_result(
                authority_path=fixture["authority_path"],
                scope_path=fixture["scope_path"],
                result_path=fixture["result_path"],
                roots=fixture["roots"],
                components=fixture["components"],
                owner_root_pid=fixture["owner_root_pid"],
                reference_authority_paths=fixture["reference_authority_paths"],
            )

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            baseline = _session_fixture(root)
            _write_session_fixture(baseline)
            validate(baseline)

            for label, mutate in (
                (
                    "schema",
                    lambda item: item["environment"].update(schema="wrong"),
                ),
                (
                    "launch identity",
                    lambda item: item["environment"].update(launchId="9" * 32),
                ),
                (
                    "allowed names digest",
                    lambda item: item["environment"].update(
                        allowedNamesSha256="0" * 64
                    ),
                ),
                (
                    "actual names digest",
                    lambda item: item["environment"].update(actualNamesSha256="0" * 64),
                ),
                (
                    "expanded actual names",
                    lambda item: item["environment"]["actualNames"].append(
                        "OP_SERVICE_ACCOUNT_TOKEN"
                    ),
                ),
                (
                    "credential assertion",
                    lambda item: item["environment"].update(
                        forbiddenCredentialNamesPresent=["HF_TOKEN"]
                    ),
                ),
                (
                    "credential assertion set",
                    lambda item: item["environment"].update(
                        credentialNamesAssertedAbsent=["HF_TOKEN"]
                    ),
                ),
                (
                    "barrier mismatch",
                    lambda item: item["environment"].update(
                        plannedNamesMatchBarrier=False
                    ),
                ),
                (
                    "values falsely observed",
                    lambda item: item["environment"].update(valuesObserved=True),
                ),
                (
                    "post-barrier names",
                    lambda item: item["environment"].update(
                        postBarrierAddedNames=["TMPDIR"]
                    ),
                ),
                (
                    "legacy values digest key",
                    lambda item: item["environment"].update(
                        plannedEnvironmentSha256=item["environment"].pop(
                            "producerPlannedEnvironmentValuesSha256"
                        )
                    ),
                ),
            ):
                with self.subTest(label=label):
                    fixture = _session_fixture(root)
                    mutate(fixture)
                    _write_session_fixture(fixture, rebind=False)
                    with self.assertRaises(ValueError):
                        validate(fixture)

            fixture = _session_fixture(root)
            _write_session_fixture(fixture)
            fixture["environment_path"].chmod(0o644)
            with self.assertRaisesRegex(ValueError, "private"):
                validate(fixture)

            fixture = _session_fixture(root)
            _write_session_fixture(fixture)
            fixture["environment_path"].unlink()
            with self.assertRaises(FileNotFoundError):
                validate(fixture)

            fixture = _session_fixture(root)
            _write_session_fixture(fixture)
            fixture["environment_path"].write_bytes(
                _add_duplicate_top_level_key(
                    fixture["environment_path"].read_bytes(),
                    "version",
                    1,
                )
            )
            with self.assertRaisesRegex(ValueError, "duplicate key.*version"):
                validate(fixture)

    def test_session_result_rejects_duplicate_evidence_json_keys(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            for label, path_key, duplicate_key, duplicate_value in (
                ("authority", "authority_path", "version", 2),
                ("scope", "scope_path", "version", 3),
                ("result", "result_path", "version", 1),
                (
                    "reference authority",
                    "reference_authority_path",
                    "version",
                    1,
                ),
            ):
                with self.subTest(label=label):
                    fixture = _session_fixture(root)
                    _write_session_fixture(fixture)
                    target = fixture[path_key]
                    target.write_bytes(
                        _add_duplicate_top_level_key(
                            target.read_bytes(),
                            duplicate_key,
                            duplicate_value,
                        )
                    )
                    with self.assertRaisesRegex(ValueError, "duplicate key.*version"):
                        preflight.validate_session_result(
                            authority_path=fixture["authority_path"],
                            scope_path=fixture["scope_path"],
                            result_path=fixture["result_path"],
                            roots=fixture["roots"],
                            components=fixture["components"],
                            owner_root_pid=fixture["owner_root_pid"],
                            reference_authority_paths=fixture[
                                "reference_authority_paths"
                            ],
                        )

    def test_session_result_rejects_duplicate_reference_readiness_key(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            fixture = _session_fixture(root)
            _write_session_fixture(fixture)
            readiness_path = fixture["components"]["referenceReadiness"]
            readiness_path.write_bytes(
                _add_duplicate_top_level_key(
                    readiness_path.read_bytes(),
                    "pid",
                    fixture["reference_authority"]["subject"]["pid"],
                )
            )
            fixture["reference_authority"]["readiness"]["sha256"] = hashlib.sha256(
                readiness_path.read_bytes()
            ).hexdigest()
            fixture["reference_authority_path"].write_bytes(
                _canonical_json(fixture["reference_authority"])
            )

            with self.assertRaisesRegex(ValueError, "duplicate key.*pid"):
                preflight.validate_session_result(
                    authority_path=fixture["authority_path"],
                    scope_path=fixture["scope_path"],
                    result_path=fixture["result_path"],
                    roots=fixture["roots"],
                    components=fixture["components"],
                    owner_root_pid=fixture["owner_root_pid"],
                    reference_authority_paths=fixture["reference_authority_paths"],
                )

    def test_session_result_rejects_digest_or_embedded_proof_mutation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            for label, mutate in (
                (
                    "authority digest",
                    lambda item: item["result"].update(authoritySha256="0" * 64),
                ),
                (
                    "scope digest",
                    lambda item: item["result"].update(scopeEvidenceSha256="0" * 64),
                ),
                (
                    "embedded authority",
                    lambda item: item["result"]["authority"].update(launchId="2" * 32),
                ),
            ):
                with self.subTest(label=label):
                    fixture = _session_fixture(root)
                    _write_session_fixture(fixture)
                    mutate(fixture)
                    fixture["result_path"].write_bytes(
                        _canonical_json(fixture["result"])
                    )
                    with self.assertRaisesRegex(
                        ValueError,
                        "scoped-command result",
                    ):
                        preflight.validate_session_result(
                            authority_path=fixture["authority_path"],
                            scope_path=fixture["scope_path"],
                            result_path=fixture["result_path"],
                            roots=fixture["roots"],
                            components=fixture["components"],
                            owner_root_pid=fixture["owner_root_pid"],
                            reference_authority_paths=fixture[
                                "reference_authority_paths"
                            ],
                        )

    def test_session_result_rejects_reference_authority_or_exemption_tamper(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()

            fixture = _session_fixture(root)
            _write_session_fixture(fixture)
            fixture["reference_authority_path"].write_bytes(
                _canonical_json(
                    {
                        **fixture["reference_authority"],
                        "exemptionId": "5" * 32,
                    }
                )
            )
            with self.assertRaises(ValueError):
                preflight.validate_session_result(
                    authority_path=fixture["authority_path"],
                    scope_path=fixture["scope_path"],
                    result_path=fixture["result_path"],
                    roots=fixture["roots"],
                    components=fixture["components"],
                    owner_root_pid=fixture["owner_root_pid"],
                    reference_authority_paths=fixture["reference_authority_paths"],
                )

            fixture = _session_fixture(root)
            _write_session_fixture(fixture)
            fixture["scope"]["referenceExemptProcesses"][0]["process"]["identity"][
                "startUsec"
            ] += 1
            scope_bytes = _canonical_json(fixture["scope"])
            fixture["result"]["scopeTermination"] = deepcopy(fixture["scope"])
            fixture["result"]["scopeEvidenceSha256"] = hashlib.sha256(
                scope_bytes
            ).hexdigest()
            fixture["scope_path"].write_bytes(scope_bytes)
            fixture["result_path"].write_bytes(_canonical_json(fixture["result"]))
            with self.assertRaisesRegex(ValueError, "reference exemption"):
                preflight.validate_session_result(
                    authority_path=fixture["authority_path"],
                    scope_path=fixture["scope_path"],
                    result_path=fixture["result_path"],
                    roots=fixture["roots"],
                    components=fixture["components"],
                    owner_root_pid=fixture["owner_root_pid"],
                    reference_authority_paths=fixture["reference_authority_paths"],
                )

            fixture = _session_fixture(root)
            _write_session_fixture(fixture)
            fixture["components"]["referenceReadiness"].write_text(
                json.dumps({"pid": 104, "nonce": "2" * 32, "tampered": True}),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "reference readiness"):
                preflight.validate_session_result(
                    authority_path=fixture["authority_path"],
                    scope_path=fixture["scope_path"],
                    result_path=fixture["result_path"],
                    roots=fixture["roots"],
                    components=fixture["components"],
                    owner_root_pid=fixture["owner_root_pid"],
                    reference_authority_paths=fixture["reference_authority_paths"],
                )

    def test_verify_prepared_requires_exact_session_proof_keys(self):
        prepared = {
            "version": 1,
            "status": "prepared",
            "evidenceSha256": "e" * 64,
            "paths": {name: f"/{name}" for name in preflight.PATH_KEYS},
            "components": {
                name: {"path": f"/{name}"} for name in preflight.COMPONENT_KEYS
            },
            "sandboxExec": {
                "verified": True,
                "identifier": "com.apple.sandbox-exec",
                "cdHash": "a" * 40,
            },
            "androidSdk": {"knownPackages": {}},
            "probe": _probe_result(),
            "sessionProof": {
                "authority": {
                    "path": "/android-sdk-sandbox-probe.process-authority.json"
                },
                "environment": {
                    "path": "/android-sdk-sandbox-probe.child-environment.json"
                },
                "scope": {"path": "/scope.json"},
                "result": {"path": "/result.json"},
                "referenceAuthorities": [{"path": "/reference-authority.json"}],
            },
        }
        with (
            mock.patch.object(preflight, "_same_fingerprint"),
            mock.patch.object(
                preflight,
                "validate_directory",
                side_effect=lambda path, _label: path,
            ),
            mock.patch.object(preflight.pathlib.Path, "read_bytes", return_value=b"{}"),
            mock.patch.object(
                preflight,
                "_decode_evidence_json",
                return_value={"ownerRoot": _identity(101)},
            ),
            mock.patch.object(preflight, "validate_session_result") as validate_session,
        ):
            preflight.verify_prepared(deepcopy(prepared))
            self.assertEqual(
                validate_session.call_args.kwargs["reference_authority_paths"],
                [pathlib.Path("/reference-authority.json")],
            )
            for label, mutation in (
                (
                    "missing",
                    {"authority": {"path": "/a"}, "scope": {"path": "/s"}},
                ),
                (
                    "extra",
                    {**prepared["sessionProof"], "unexpected": {}},
                ),
            ):
                with self.subTest(label=label):
                    changed = deepcopy(prepared)
                    changed["sessionProof"] = mutation
                    with self.assertRaisesRegex(ValueError, "session proof"):
                        preflight.verify_prepared(changed)

            changed = deepcopy(prepared)
            changed["sessionProof"]["referenceAuthorities"] = []
            with self.assertRaisesRegex(ValueError, "reference authorities"):
                preflight.verify_prepared(changed)

    def test_probe_result_requires_child_and_grandchild_denial(self):
        result = _probe_result()
        preflight.validate_probe_result(result)
        result["child"]["child"]["write"]["denied"] = False
        with self.assertRaisesRegex(ValueError, "descendant-create"):
            preflight.validate_probe_result(result)

    def test_session_result_rejects_strong_reference_and_process_tamper(self):
        def validate(fixture):
            preflight.validate_session_result(
                authority_path=fixture["authority_path"],
                scope_path=fixture["scope_path"],
                result_path=fixture["result_path"],
                roots=fixture["roots"],
                components=fixture["components"],
                owner_root_pid=fixture["owner_root_pid"],
                reference_authority_paths=fixture["reference_authority_paths"],
            )

        def stopped_record(fixture):
            record = deepcopy(
                fixture["scope"]["referenceExemptProcesses"][0]["process"]
            )
            record["identity"] = deepcopy(fixture["authority"]["leader"])
            return record

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            for label in (
                "untrusted executable",
                "untrusted program",
                "wrong guard root",
                "wrong guard backend",
                "wrong guard events",
                "wrong guard baseline",
                "wrong guard nonce",
                "exempt executable",
                "exempt argv",
                "marker reason",
                "foreign uid",
                "unauthorized kill session",
                "term mismatch",
                "fallback mismatch",
            ):
                with self.subTest(label=label):
                    fixture = _session_fixture(root)
                    if label == "untrusted executable":
                        seal = {
                            "path": str(fixture["components"]["wrapper"]),
                            "sha256": hashlib.sha256(
                                fixture["components"]["wrapper"].read_bytes()
                            ).hexdigest(),
                        }
                        fixture["reference_authority"]["executable"] = seal
                        fixture["reference_authority"]["argv"][0] = seal["path"]
                        process = fixture["scope"]["referenceExemptProcesses"][0][
                            "process"
                        ]
                        process["executable"] = seal["path"]
                        process["argv"][0] = seal["path"]
                    elif label == "untrusted program":
                        seal = {
                            "path": str(fixture["components"]["wrapper"]),
                            "sha256": hashlib.sha256(
                                fixture["components"]["wrapper"].read_bytes()
                            ).hexdigest(),
                        }
                        fixture["reference_authority"]["program"] = seal
                        fixture["reference_authority"]["argv"][4] = seal["path"]
                        fixture["scope"]["referenceExemptProcesses"][0]["process"][
                            "argv"
                        ][4] = seal["path"]
                    elif label.startswith("wrong guard"):
                        option, replacement = {
                            "wrong guard root": (
                                "--root",
                                str(fixture["roots"]["gradle_home"]),
                            ),
                            "wrong guard backend": ("--backend", "forged-backend"),
                            "wrong guard events": (
                                "--events-file",
                                str(fixture["roots"]["isolated_root"] / "forged.jsonl"),
                            ),
                            "wrong guard baseline": (
                                "--baseline-manifest",
                                str(fixture["authority_path"].parent / "forged.sha256"),
                            ),
                            "wrong guard nonce": ("--nonce", "a" * 32),
                        }[label]
                        authority_argv = fixture["reference_authority"]["argv"]
                        authority_argv[authority_argv.index(option) + 1] = replacement
                        process_argv = fixture["scope"]["referenceExemptProcesses"][0][
                            "process"
                        ]["argv"]
                        process_argv[process_argv.index(option) + 1] = replacement
                    elif label == "exempt executable":
                        fixture["scope"]["referenceExemptProcesses"][0]["process"][
                            "executable"
                        ] = "/bin/zsh"
                    elif label == "exempt argv":
                        process = fixture["scope"]["referenceExemptProcesses"][0][
                            "process"
                        ]
                        process["argv"] = deepcopy(process["argv"])
                        process["argv"][-1] = "forged"
                    elif label == "marker reason":
                        fixture["scope"]["referenceExemptProcesses"][0][
                            "reasons"
                        ].append("marker")
                        fixture["scope"]["referenceExemptProcesses"][0][
                            "reasons"
                        ].sort()
                    elif label == "foreign uid":
                        record = stopped_record(fixture)
                        record["identity"]["uid"] += 1
                        fixture["scope"]["stoppedProcesses"] = [record]
                    elif label == "unauthorized kill session":
                        record = stopped_record(fixture)
                        record["identity"]["sid"] += 1000
                        fixture["scope"]["killSentProcesses"] = [record]
                    elif label == "term mismatch":
                        record = stopped_record(fixture)
                        forged = deepcopy(record)
                        forged["argv"] = ["forged"]
                        fixture["scope"]["stoppedProcesses"] = [record]
                        fixture["scope"]["termSentProcesses"] = [forged]
                    else:
                        identity = deepcopy(
                            fixture["scope"]["referenceExemptProcesses"][0]["process"][
                                "identity"
                            ]
                        )
                        identity["startUsec"] += 1
                        fixture["scope"]["referenceInspection"]["fallbackProcesses"] = [
                            identity
                        ]
                    _write_session_fixture(fixture)
                    with self.assertRaises(ValueError):
                        validate(fixture)


if __name__ == "__main__":
    unittest.main()
