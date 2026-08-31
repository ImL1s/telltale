from __future__ import annotations

import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "test_target_outer_gate_result_verifier",
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


def _child_environment(launch_id: str) -> dict[str, object]:
    allowed_names = sorted(verifier.CHILD_ENVIRONMENT_ALLOWED_NAMES)
    actual_names = sorted(verifier.CHILD_ENVIRONMENT_ALLOWED_NAMES)
    return {
        "schema": "telltale-gate-c-child-environment-names-v2",
        "version": 2,
        "launchId": launch_id,
        "allowedNames": allowed_names,
        "allowedNamesSha256": verifier._canonical_json_sha256(allowed_names),
        "actualNames": actual_names,
        "actualNamesSha256": verifier._canonical_json_sha256(actual_names),
        "actualNamesObservationPoint": "cooperative-sealed-wrapper-pre-release-barrier-v1",
        "producerPlannedEnvironmentValuesSha256": "e" * 64,
        "plannedNamesMatchBarrier": True,
        "valuesObserved": False,
        "postBarrierAddedNames": [
            "FLUTTER_ALREADY_LOCKED",
            "JAVA_TOOL_OPTIONS",
            "TMPDIR",
        ],
        "credentialNamesAssertedAbsent": sorted(
            verifier.CHILD_ENVIRONMENT_CREDENTIAL_NAMES
        ),
        "forbiddenCredentialNamesPresent": [],
    }


class OuterGateResultVerifierTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve(strict=True)
        self.app = self.root / "app"
        self.rig = self.app / "tool" / "telemetry_memory_rig"
        self.evidence = self.root / "evidence"
        self.python = self.root / "python3"
        self.rig.mkdir(parents=True)
        self.evidence.mkdir()
        self.evidence.chmod(0o700)
        self.python.write_bytes(b"sealed python\n")
        self.python.chmod(0o700)
        self.sandbox_exec = self.root / "sandbox-exec"
        self.sandbox_exec.write_bytes(b"sealed system sandbox-exec\n")
        self.sandbox_exec.chmod(0o700)
        for relative in set(verifier.SHA_COMPONENT_PATHS.values()):
            _write(self.rig / relative, f"component:{relative}\n")
        for relative in verifier.SHA_EVIDENCE_PATHS.values():
            _write(self.evidence / relative, f"evidence:{relative}\n")
        self.cleanup = self.evidence / "gradle-process-scope-cleanup-1.json"
        self.scope = {
            "version": 3,
            "mode": "audit-only",
            "status": "quiescent",
            "marker": "TELLTALE_GATE_C_PROCESS_SCOPE_AUDIT",
            "ownerRoot": {},
            "roots": {},
            "authorities": [{"path": "authority.json", "sha256": "a" * 64}],
            "referenceAuthorities": [],
            "authorizedSessions": [],
            "startedMonotonicNs": 1,
            "endedMonotonicNs": 2,
            "stoppedProcesses": [],
            "termSentProcesses": [],
            "killSentProcesses": [],
            "remainingOwnedProcesses": [],
            "foreignProcesses": [],
            "referenceExemptProcesses": [],
            "inspectionLimitations": [],
            "referenceInspection": {
                "complete": True,
                "lsof": {},
                "fallbackProcesses": [],
            },
        }
        self._write_scope()
        self._write_result()
        self._write_manifest()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _write_scope(self) -> None:
        _write(
            self.cleanup,
            json.dumps(self.scope, sort_keys=True, separators=(",", ":")) + "\n",
        )

    def _result(self) -> dict[str, object]:
        value: dict[str, object] = {
            "version": 1,
            "result": "pass",
            "cuts": verifier.CUTS,
            "cleanupVerified": True,
        }
        for key, relative in verifier.SHA_EVIDENCE_PATHS.items():
            value[key] = _sha(self.evidence / relative)
        value["pythonExecutableSha256"] = _sha(self.python)
        for key, relative in verifier.SHA_COMPONENT_PATHS.items():
            value[key] = _sha(self.rig / relative)
        value["androidSdkSandboxExecSha256"] = _sha(self.sandbox_exec)
        value["processScopeCleanupSha256"] = _sha(self.cleanup)
        return value

    def _write_result(self, mutate=None) -> None:
        value = self._result()
        if mutate is not None:
            mutate(value)
        _write(
            self.evidence / verifier.RESULT_NAME,
            json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
        )

    def _write_manifest(self, paths: list[str] | None = None) -> None:
        manifest = self.evidence / verifier.MANIFEST_NAME
        if manifest.exists() or manifest.is_symlink():
            manifest.unlink()
        selected = paths or sorted(
            path.relative_to(self.evidence).as_posix()
            for path in self.evidence.rglob("*")
            if path.is_file()
        )
        _write(
            manifest,
            "".join(f"{_sha(self.evidence / path)}  ./{path}\n" for path in selected),
        )

    def _write_flutter_gradle_cleanup_evidence(
        self,
        prepared: dict[str, object],
    ) -> None:
        paths = prepared["paths"]
        assert isinstance(paths, dict)
        gradle = Path(str(paths["flutter_root"])) / "packages/flutter_tools/gradle"
        value = {
            "version": 1,
            "checked": [
                str(gradle / ".gradle"),
                str(gradle / "build"),
                str(gradle / ".kotlin"),
            ],
            "removed": [],
        }
        payload = json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"
        for phase in ("pre", "post"):
            _write(
                self.evidence / f"flutter-gradle-generated-cleanup.{phase}.json",
                payload,
            )

    def _verify(self) -> None:
        prepared = {"paths": {}}

        def verify_cleanup_digest(evidence, result, prepared_value, preflight):
            del prepared_value, preflight
            if result["processScopeCleanupSha256"] != _sha(
                evidence / self.cleanup.name
            ):
                raise verifier.VerificationError(
                    "final process-scope cleanup digest mismatch"
                )

        with (
            mock.patch.object(
                verifier,
                "_verify_sandbox_semantics",
                return_value=(prepared, object()),
            ),
            mock.patch.object(verifier, "_verify_equal_evidence_pairs"),
            mock.patch.object(verifier, "_verify_tested_tree_and_summary"),
            mock.patch.object(verifier, "_verify_gate_cut_semantics"),
            mock.patch.object(verifier, "_verify_process_scope_semantics"),
            mock.patch.object(verifier, "_verify_cleanup_and_toolchain_semantics"),
            mock.patch.object(verifier, "_verify_source_guard_semantics"),
            mock.patch.object(
                verifier,
                "_verify_final_scope",
                side_effect=verify_cleanup_digest,
            ),
        ):
            verifier.verify(
                self.evidence,
                self.app,
                self.python,
                sandbox_exec=self.sandbox_exec,
            )

    @staticmethod
    def _identity(pid: int, *, ppid: int = 1) -> dict[str, int]:
        return {
            "pid": pid,
            "ppid": ppid,
            "uid": 501,
            "pgid": pid,
            "sid": pid,
            "startSec": 100,
            "startUsec": 200,
        }

    def _sandbox_fixture(self) -> tuple[dict[str, object], object]:
        persistent = {
            "flutter_root": self.root / "flutter",
            "pub_cache": self.root / "pub-cache",
            "android_sdk_root": self.root / "android-sdk",
        }
        for path in persistent.values():
            path.mkdir()
        known_packages = persistent["android_sdk_root"] / ".knownPackages"
        _write(known_packages, "packages\n")
        isolated = self.root / "deleted-isolated"
        paths = {
            "app_root": str(self.app),
            "flutter_root": str(persistent["flutter_root"]),
            "pub_cache": str(persistent["pub_cache"]),
            "gradle_home": str(self.root / "deleted-gradle"),
            "isolated_root": str(isolated),
            "run_temp": str(isolated / "run-temp"),
            "android_sdk_root": str(persistent["android_sdk_root"]),
            "host_home": str(Path.home().resolve(strict=True)),
        }
        component_paths = {
            name: self.rig / relative
            for name, relative in verifier.PREPARED_COMPONENT_PATHS.items()
        }
        component_paths.update(
            {
                "preflight": self.rig / "android_sdk_sandbox_preflight.py",
                "python": self.python,
            }
        )
        components = {
            name: {"path": str(path), "sha256": _sha(path)}
            for name, path in component_paths.items()
        }
        session_paths = {
            "authority": self.evidence
            / "android-sdk-sandbox-probe.process-authority.json",
            "environment": self.evidence
            / "android-sdk-sandbox-probe.child-environment.json",
            "scope": self.evidence / "android-sdk-sandbox-probe.process-scope.json",
            "result": self.evidence / "android-sdk-sandbox-probe.scoped-command.json",
        }
        owner = self._identity(900)
        launch_id = "9" * 32
        _write(
            session_paths["authority"],
            json.dumps({"ownerRoot": owner, "launchId": launch_id}) + "\n",
        )
        _write(
            session_paths["environment"],
            json.dumps(
                _child_environment(launch_id), sort_keys=True, separators=(",", ":")
            )
            + "\n",
        )
        _write(session_paths["scope"], "{}\n")
        _write(session_paths["result"], "{}\n")
        reference = self.evidence / "source-guard.reference-authority.json"
        _write(reference, "{}\n")
        session = {
            name: {"path": str(path), "sha256": _sha(path)}
            for name, path in session_paths.items()
        }
        session["referenceAuthorities"] = [
            {"path": str(reference), "sha256": _sha(reference)}
        ]
        sandbox_identity = {
            "path": str(self.sandbox_exec),
            "sha256": _sha(self.sandbox_exec),
        }
        prepared: dict[str, object] = {
            "version": 1,
            "status": "prepared",
            "paths": paths,
            "components": components,
            "sandboxExec": sandbox_identity,
            "androidSdk": {
                "knownPackages": {
                    "path": str(known_packages),
                    "sha256": _sha(known_packages),
                },
            },
            "probe": {"result": "pass"},
            "sessionProof": session,
            "evidenceSha256": "a" * 64,
        }
        post = {
            "version": 1,
            "status": "verified",
            "preparedEvidenceSha256": "a" * 64,
            **{
                field: prepared[field]
                for field in (
                    "paths",
                    "components",
                    "sandboxExec",
                    "androidSdk",
                    "sessionProof",
                )
            },
        }
        _write(
            self.evidence / "android-sdk-sandbox.post.json",
            json.dumps(post, sort_keys=True, separators=(",", ":")) + "\n",
        )

        class FakePreflight:
            AUTHORITY_KEYS: set[str] = set()

            @staticmethod
            def read_prepared_evidence(path, expected):
                del path, expected
                return prepared

            @staticmethod
            def validate_directory(path, label):
                del label
                return path.resolve(strict=True)

            @staticmethod
            def _same_fingerprint(fingerprint, label):
                del fingerprint, label

            @staticmethod
            def codesign_identity(path):
                del path
                return sandbox_identity

            @staticmethod
            def validate_probe_result(probe):
                if probe != {"result": "pass"}:
                    raise ValueError("probe")

            @staticmethod
            def _valid_identity(value):
                return isinstance(value, dict) and set(value) == {
                    "pid",
                    "ppid",
                    "uid",
                    "pgid",
                    "sid",
                    "startSec",
                    "startUsec",
                }

            @staticmethod
            def validate_session_result(**kwargs):
                del kwargs

        return prepared, FakePreflight()

    def _verify_sandbox_fixture(
        self,
        prepared: dict[str, object],
        preflight: object,
    ) -> None:
        with mock.patch.object(
            verifier, "_load_trusted_module", return_value=preflight
        ):
            verifier._verify_sandbox_semantics(
                self.evidence,
                self.app,
                self.rig,
                self.python,
                self.sandbox_exec,
                {"androidSdkSandboxPrepareSha256": "a" * 64},
            )

    def _final_scope_fixture(
        self,
    ) -> tuple[dict[str, object], object, dict[str, object]]:
        owner = self._identity(700, ppid=600)
        supervisor = self._identity(800, ppid=700)
        leader = self._identity(900, ppid=800)
        expected_roots = {
            "gradleUserHome": str(self.root / "deleted-gradle"),
            "isolatedUserRoot": str(self.root / "deleted-isolated"),
            "home": str(self.root / "deleted-isolated" / "home"),
            "sandboxRunTemp": str(self.root / "deleted-isolated" / "run-temp"),
            "kotlinProjectPersistentDir": str(
                self.root
                / "deleted-isolated"
                / "run-temp"
                / "kotlin-project-persistent"
            ),
            "kotlinDaemonRunFilesDir": str(
                self.root / "deleted-isolated" / "run-temp" / "kotlin-daemon"
            ),
        }
        wrapper = {
            "path": str(self.rig / "android_sdk_sandbox_exec.sh"),
            "sha256": _sha(self.rig / "android_sdk_sandbox_exec.sh"),
        }
        launch_id = "1" * 32
        authority = {
            "version": 2,
            "launchId": launch_id,
            "ownerRoot": owner,
            "supervisor": supervisor,
            "leader": leader,
            "roots": expected_roots,
            "wrapper": wrapper,
            "cwd": str(self.app),
        }
        authority_path = self.evidence / "build.process-authority.json"
        _write(
            authority_path,
            json.dumps(authority, sort_keys=True, separators=(",", ":")) + "\n",
        )
        _write(
            verifier._child_environment_path(authority_path),
            json.dumps(
                _child_environment(launch_id), sort_keys=True, separators=(",", ":")
            )
            + "\n",
        )
        self.scope = {
            "version": 3,
            "mode": "audit-only",
            "status": "quiescent",
            "marker": "TELLTALE_GATE_C_PROCESS_SCOPE_AUDIT",
            "ownerRoot": owner,
            "roots": expected_roots,
            "authorities": [
                {
                    "path": str(authority_path),
                    "sha256": _sha(authority_path),
                    "launchId": launch_id,
                }
            ],
            "referenceAuthorities": [],
            "authorizedSessions": [],
            "startedMonotonicNs": 1,
            "endedMonotonicNs": 2,
            "stoppedProcesses": [],
            "termSentProcesses": [],
            "killSentProcesses": [],
            "remainingOwnedProcesses": [],
            "foreignProcesses": [],
            "referenceExemptProcesses": [],
            "inspectionLimitations": [],
            "referenceInspection": {
                "complete": True,
                "lsof": {"sealed": True},
                "fallbackProcesses": [],
            },
        }
        self._write_scope()
        prepared = {
            "paths": {
                "gradle_home": expected_roots["gradleUserHome"],
                "isolated_root": expected_roots["isolatedUserRoot"],
                "run_temp": expected_roots["sandboxRunTemp"],
                "app_root": str(self.app),
            },
            "components": {"wrapper": wrapper},
        }

        class FakePreflight:
            AUTHORITY_KEYS = set(authority)

            @staticmethod
            def _valid_identity(value):
                return (
                    isinstance(value, dict)
                    and set(value)
                    == {"pid", "ppid", "uid", "pgid", "sid", "startSec", "startUsec"}
                    and all(type(item) is int and item >= 0 for item in value.values())
                )

            @staticmethod
            def _valid_process_record(value):
                return isinstance(value, dict) and "identity" in value

            @staticmethod
            def _validate_lsof_seal(value):
                if value != {"sealed": True}:
                    raise ValueError("lsof")

        result = {"processScopeCleanupSha256": _sha(self.cleanup)}
        return prepared, FakePreflight(), result

    def _verify_final_fixture(
        self,
        prepared: dict[str, object],
        preflight: object,
        result: dict[str, object],
    ) -> None:
        result["processScopeCleanupSha256"] = _sha(self.cleanup)
        verifier._verify_final_scope(
            self.evidence,
            result,
            prepared,
            preflight,
        )

    def test_accepts_exact_result_manifest_components_and_cleanup(self) -> None:
        self._verify()

    def test_process_scope_outer_requires_all_non_gate_and_gate_lanes(self) -> None:
        calls = {"scoped": [], "guarded": [], "final": 0}
        _write(
            self.evidence / "identity.txt",
            "flutter_version=Flutter 3.47.0\ndart_version=Dart 3.x\n",
        )
        _write(
            self.evidence / "fixture-generator.log",
            "TELLTALE_MEMORY_HOST_FIXTURES_READY indexBytes=104857600 "
            "sessionBytes=26214400\n",
        )

        class Helper:
            @staticmethod
            def validate_scoped_command(_evidence, label, status, _prepared, _rig):
                calls["scoped"].append((label, status))
                return {"label": label, "status": status, "authorizedSessions": [1]}

            @staticmethod
            def validate_guarded_command(_evidence, label, _prepared, _rig):
                calls["guarded"].append(label)
                return {"label": label, "status": "completed", "guardPid": 2}

            @staticmethod
            def validate_final_cleanup(_evidence, result, _prepared, _rig):
                calls["final"] += 1
                return {
                    "status": "quiescent",
                    "path": "/cleanup",
                    "sha256": result["processScopeCleanupSha256"],
                    "authorizedSessions": [],
                }

        helper_path = self.rig / "outer_process_scope_validator.py"
        if not helper_path.exists():
            _write(helper_path, "# process scope helper fixture\n")
        with (
            mock.patch.object(
                verifier,
                "_parse_build_manifest",
                return_value={
                    "tool/telemetry_memory_rig/outer_process_scope_validator.py": _sha(
                        helper_path
                    )
                },
            ),
            mock.patch.object(verifier, "_load_trusted_module", return_value=Helper()),
        ):
            verifier._verify_process_scope_semantics(
                self.evidence,
                self.rig,
                {},
                {"processScopeCleanupSha256": "a" * 64},
            )
        self.assertIn(("gradle-version", "completed"), calls["scoped"])
        self.assertIn(("flutter-version", "completed"), calls["scoped"])
        self.assertIn(("dart-version", "completed"), calls["scoped"])
        self.assertIn(("fixture-generator", "completed"), calls["scoped"])
        self.assertIn(("telemetry-memory-measure", "completed"), calls["scoped"])
        self.assertEqual(
            calls["guarded"],
            ["android-toolchain-build", "android-toolchain-lint-model"],
        )
        self.assertEqual(len(calls["scoped"]), 19)
        self.assertEqual(calls["final"], 1)
        for path, value, message in (
            (
                self.evidence / "identity.txt",
                "flutter_version=\ndart_version=Dart 3.x\n",
                "version output",
            ),
            (
                self.evidence / "fixture-generator.log",
                "TELLTALE_MEMORY_HOST_FIXTURES_READY indexBytes=1 sessionBytes=1\n",
                "fixture-generator",
            ),
        ):
            with self.subTest(path=path.name):
                original = path.read_bytes()
                _write(path, value)
                with (
                    mock.patch.object(
                        verifier,
                        "_parse_build_manifest",
                        return_value={
                            "tool/telemetry_memory_rig/outer_process_scope_validator.py": _sha(
                                helper_path
                            )
                        },
                    ),
                    mock.patch.object(
                        verifier,
                        "_load_trusted_module",
                        return_value=Helper(),
                    ),
                    self.assertRaisesRegex(verifier.VerificationError, message),
                ):
                    verifier._verify_process_scope_semantics(
                        self.evidence,
                        self.rig,
                        {},
                        {"processScopeCleanupSha256": "a" * 64},
                    )
                _write(path, original)

    def test_result_schema_is_exactly_26_keys(self) -> None:
        self._write_result(lambda value: value.__setitem__("unexpected", True))
        self._write_manifest()
        with self.assertRaisesRegex(verifier.VerificationError, "exact contract"):
            self._verify()

    def test_each_result_digest_is_recomputed(self) -> None:
        for key, relative in {
            **verifier.SHA_EVIDENCE_PATHS,
            **verifier.SHA_COMPONENT_PATHS,
        }.items():
            with self.subTest(key=key):
                target = (
                    self.evidence / relative
                    if key in verifier.SHA_EVIDENCE_PATHS
                    else self.rig / relative
                )
                original = target.read_bytes()
                target.write_bytes(original + b"tampered")
                if key in verifier.SHA_EVIDENCE_PATHS:
                    self._write_manifest()
                with self.assertRaisesRegex(
                    verifier.VerificationError, "digest mismatch"
                ):
                    self._verify()
                target.write_bytes(original)
                self._write_manifest()

    def test_system_sandbox_exec_digest_uses_separate_system_path(self) -> None:
        wrapper = (
            self.rig / verifier.SHA_COMPONENT_PATHS["androidSdkSandboxWrapperSha256"]
        )
        self.assertNotEqual(_sha(wrapper), _sha(self.sandbox_exec))
        self._verify()

        self.sandbox_exec.write_bytes(wrapper.read_bytes())
        with self.assertRaisesRegex(
            verifier.VerificationError,
            "system sandbox-exec digest mismatch",
        ):
            self._verify()

    def test_hash_consistent_arbitrary_prepared_evidence_is_rejected(self) -> None:
        prepared, preflight = self._sandbox_fixture()
        prepared["paths"]["app_root"] = str(self.root)
        with self.assertRaisesRegex(verifier.VerificationError, "app-root binding"):
            self._verify_sandbox_fixture(prepared, preflight)

    def test_sandbox_post_must_exactly_match_prepared_evidence(self) -> None:
        prepared, preflight = self._sandbox_fixture()
        post_path = self.evidence / "android-sdk-sandbox.post.json"
        post = json.loads(post_path.read_text())
        post["paths"]["pub_cache"] = str(self.root / "different-cache")
        _write(
            post_path, json.dumps(post, sort_keys=True, separators=(",", ":")) + "\n"
        )
        with self.assertRaisesRegex(verifier.VerificationError, "post attestation"):
            self._verify_sandbox_fixture(prepared, preflight)

    def test_sandbox_prepared_disposable_roots_must_be_deleted(self) -> None:
        prepared, preflight = self._sandbox_fixture()
        Path(prepared["paths"]["gradle_home"]).mkdir()
        with self.assertRaisesRegex(verifier.VerificationError, "survived cleanup"):
            self._verify_sandbox_fixture(prepared, preflight)

    def test_sandbox_prepared_version_is_exact(self) -> None:
        prepared, preflight = self._sandbox_fixture()
        prepared["version"] = 999
        with self.assertRaisesRegex(verifier.VerificationError, "schema"):
            self._verify_sandbox_fixture(prepared, preflight)

    def test_sandbox_prepared_status_is_exact(self) -> None:
        prepared, preflight = self._sandbox_fixture()
        prepared["status"] = "forged"
        with self.assertRaisesRegex(verifier.VerificationError, "schema"):
            self._verify_sandbox_fixture(prepared, preflight)

    def test_sandbox_session_requires_bound_child_environment(self) -> None:
        prepared, preflight = self._sandbox_fixture()
        path = self.evidence / "android-sdk-sandbox-probe.child-environment.json"
        value = json.loads(path.read_text())
        value["launchId"] = "0" * 32
        _write(path, json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
        with self.assertRaisesRegex(verifier.VerificationError, "session proof"):
            self._verify_sandbox_fixture(prepared, preflight)

    def test_sandbox_session_rejects_missing_child_environment(self) -> None:
        prepared, preflight = self._sandbox_fixture()
        (self.evidence / "android-sdk-sandbox-probe.child-environment.json").unlink()
        with self.assertRaisesRegex(verifier.VerificationError, "session proof"):
            self._verify_sandbox_fixture(prepared, preflight)

    def test_hash_consistent_arbitrary_cleanup_evidence_is_rejected(self) -> None:
        prepared, _ = self._sandbox_fixture()
        self._write_flutter_gradle_cleanup_evidence(prepared)
        _write(self.evidence / "generated-input-cleanup.json", "{}\n")
        with self.assertRaisesRegex(verifier.VerificationError, "cleanup evidence"):
            verifier._verify_cleanup_and_toolchain_semantics(
                self.evidence,
                prepared,
                self.rig,
            )

    def test_flutter_gradle_cleanup_rejects_incomplete_checked_roots(self) -> None:
        prepared, _ = self._sandbox_fixture()
        self._write_flutter_gradle_cleanup_evidence(prepared)
        target = self.evidence / "flutter-gradle-generated-cleanup.pre.json"
        value = json.loads(target.read_text())
        value["checked"].pop()
        _write(target, json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
        with self.assertRaisesRegex(verifier.VerificationError, "checked roots"):
            verifier._verify_cleanup_and_toolchain_semantics(
                self.evidence,
                prepared,
                self.rig,
            )

    def test_flutter_gradle_cleanup_rejects_surviving_generated_state(self) -> None:
        prepared, _ = self._sandbox_fixture()
        self._write_flutter_gradle_cleanup_evidence(prepared)
        generated = (
            Path(str(prepared["paths"]["flutter_root"]))
            / "packages/flutter_tools/gradle/.gradle"
        )
        generated.mkdir(parents=True)
        with self.assertRaisesRegex(verifier.VerificationError, "survived cleanup"):
            verifier._verify_cleanup_and_toolchain_semantics(
                self.evidence,
                prepared,
                self.rig,
            )

    def test_final_cleanup_rejects_malformed_owner(self) -> None:
        prepared, preflight, result = self._final_scope_fixture()
        self.scope["ownerRoot"] = {"pid": 700}
        self._write_scope()
        with self.assertRaisesRegex(
            verifier.VerificationError, "not exact and quiescent"
        ):
            self._verify_final_fixture(prepared, preflight, result)

    def test_final_cleanup_rejects_mismatched_roots(self) -> None:
        prepared, preflight, result = self._final_scope_fixture()
        self.scope["roots"]["gradleUserHome"] = str(self.root / "other-gradle")
        self._write_scope()
        with self.assertRaisesRegex(
            verifier.VerificationError, "not exact and quiescent"
        ):
            self._verify_final_fixture(prepared, preflight, result)

    def test_final_cleanup_rejects_malformed_lsof_seal(self) -> None:
        prepared, preflight, result = self._final_scope_fixture()
        self.scope["referenceInspection"]["lsof"] = {"sealed": False}
        self._write_scope()
        with self.assertRaisesRegex(verifier.VerificationError, "lsof seal"):
            self._verify_final_fixture(prepared, preflight, result)

    def test_final_cleanup_requires_exact_audit_only_mode(self) -> None:
        for mutation in ("marker", "mode", "sessions", "stopped"):
            with self.subTest(mutation=mutation):
                prepared, preflight, result = self._final_scope_fixture()
                if mutation == "marker":
                    self.scope["marker"] = "TELLTALE_GATE_C_PROCESS_SCOPE"
                elif mutation == "mode":
                    self.scope["mode"] = "signal"
                elif mutation == "sessions":
                    self.scope["authorizedSessions"] = [900]
                else:
                    self.scope["stoppedProcesses"] = [
                        {"identity": self._identity(901, ppid=900)}
                    ]
                self._write_scope()
                with self.assertRaisesRegex(
                    verifier.VerificationError, "not exact and quiescent"
                ):
                    self._verify_final_fixture(prepared, preflight, result)

    def test_final_cleanup_requires_exact_child_environment_set(self) -> None:
        prepared, preflight, result = self._final_scope_fixture()
        authority_path = self.evidence / "build.process-authority.json"
        environment_path = verifier._child_environment_path(authority_path)

        environment_path.unlink()
        with self.assertRaises(verifier.VerificationError):
            self._verify_final_fixture(prepared, preflight, result)

        _write(
            environment_path,
            json.dumps(
                _child_environment("1" * 32), sort_keys=True, separators=(",", ":")
            )
            + "\n",
        )
        extra = self.evidence / "extra.child-environment.json"
        _write(extra, "{}\n")
        with self.assertRaisesRegex(verifier.VerificationError, "incomplete or extra"):
            self._verify_final_fixture(prepared, preflight, result)

    def test_final_cleanup_rejects_tampered_child_environment(self) -> None:
        for label, mutate in (
            (
                "credential assertion",
                lambda value: value.update(credentialNamesAssertedAbsent=[]),
            ),
            ("values observed", lambda value: value.update(valuesObserved=True)),
            (
                "post-barrier names",
                lambda value: value.update(postBarrierAddedNames=["TMPDIR"]),
            ),
            ("legacy version", lambda value: value.update(version=1)),
        ):
            with self.subTest(label=label):
                prepared, preflight, result = self._final_scope_fixture()
                path = self.evidence / "build.child-environment.json"
                value = json.loads(path.read_text())
                mutate(value)
                _write(
                    path,
                    json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
                )
                with self.assertRaisesRegex(verifier.VerificationError, "binding"):
                    self._verify_final_fixture(prepared, preflight, result)

    def test_each_of_24_result_sha_fields_is_independently_enforced(self) -> None:
        self.assertEqual(len(verifier.SHA_KEYS), 24)
        for key in verifier.SHA_KEYS:
            with self.subTest(key=key):
                self._write_result(
                    lambda value, selected=key: value.__setitem__(selected, "0" * 64),
                )
                self._write_manifest()
                with self.assertRaisesRegex(
                    verifier.VerificationError, "digest mismatch"
                ):
                    self._verify()

    def test_python_digest_is_recomputed(self) -> None:
        self.python.write_bytes(b"different python\n")
        with self.assertRaisesRegex(verifier.VerificationError, "Python executable"):
            self._verify()

    def test_python_symlink_is_rejected_even_when_target_digest_matches(self) -> None:
        alias = self.root / "python-alias"
        alias.symlink_to(self.python)
        with self.assertRaisesRegex(verifier.VerificationError, "symlinked file path"):
            verifier.verify(self.evidence, self.app, alias)

    def test_manifest_paths_must_be_sorted_and_unique(self) -> None:
        paths = sorted(
            path.relative_to(self.evidence).as_posix()
            for path in self.evidence.rglob("*")
            if path.is_file() and path.name != verifier.MANIFEST_NAME
        )
        self._write_manifest(list(reversed(paths)))
        with self.assertRaisesRegex(verifier.VerificationError, "sorted and unique"):
            self._verify()

    def test_manifest_rejects_traversal(self) -> None:
        manifest = self.evidence / verifier.MANIFEST_NAME
        _write(manifest, f"{'a' * 64}  ./../escape\n")
        with self.assertRaisesRegex(verifier.VerificationError, "non-canonical"):
            self._verify()

    def test_manifest_path_set_must_equal_all_regular_files(self) -> None:
        paths = sorted(
            path.relative_to(self.evidence).as_posix()
            for path in self.evidence.rglob("*")
            if path.is_file()
            and path.name not in {verifier.MANIFEST_NAME, verifier.RESULT_NAME}
        )
        self._write_manifest(paths)
        with self.assertRaisesRegex(verifier.VerificationError, "exactly cover"):
            self._verify()

    def test_manifest_rejects_digest_mismatch(self) -> None:
        target = self.evidence / "summary.json"
        target.write_bytes(b"tampered after seal\n")
        with self.assertRaisesRegex(
            verifier.VerificationError, "manifest digest mismatch"
        ):
            self._verify()

    def test_evidence_symlink_is_rejected(self) -> None:
        target = self.evidence / "summary.json"
        target.unlink()
        target.symlink_to(self.python)
        with self.assertRaises(verifier.VerificationError):
            self._verify()

    def test_duplicate_json_keys_are_rejected(self) -> None:
        result = (self.evidence / verifier.RESULT_NAME).read_text()
        duplicate = result[:-2] + ',"version":1}\n'
        _write(self.evidence / verifier.RESULT_NAME, duplicate)
        self._write_manifest()
        with self.assertRaisesRegex(verifier.VerificationError, "duplicate JSON key"):
            self._verify()


if __name__ == "__main__":
    unittest.main()
