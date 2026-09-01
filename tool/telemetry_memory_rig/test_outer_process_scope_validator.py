from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest import mock

import outer_process_scope_validator as validator


def _sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _write(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
    path.chmod(0o600)
    if path.name.endswith(".process-authority.json") and isinstance(value, dict):
        allowed_names = sorted(validator.CHILD_ENVIRONMENT_ALLOWED_NAMES)
        actual_names = sorted(validator.CHILD_ENVIRONMENT_ALLOWED_NAMES)
        environment = {
            "schema": "telltale-gate-c-child-environment-names-v2",
            "version": 2,
            "launchId": value.get("launchId"),
            "allowedNames": allowed_names,
            "allowedNamesSha256": validator._canonical_json_sha256(allowed_names),
            "actualNames": actual_names,
            "actualNamesSha256": validator._canonical_json_sha256(actual_names),
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
                validator.CHILD_ENVIRONMENT_CREDENTIAL_NAMES
            ),
            "forbiddenCredentialNamesPresent": [],
        }
        environment_path = validator._child_environment_path(path)
        environment_path.write_text(
            json.dumps(environment, sort_keys=True, separators=(",", ":")) + "\n"
        )
        environment_path.chmod(0o600)


class OuterProcessScopeValidatorTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve(strict=True)
        self.evidence = self.root / "evidence"
        self.rig = self.root / "rig"
        self.app = self.root / "app"
        self.evidence.mkdir()
        self.rig.mkdir()
        self.app.mkdir()
        self.flutter_root = self.root / "flutter"
        self.android_sdk_root = self.root / "android-sdk"
        self.jdk_root = self.root / "jdk"
        self.gradle_root = self.root / "gradle-dist"
        for path in (
            self.flutter_root,
            self.android_sdk_root,
            self.jdk_root,
            self.gradle_root,
        ):
            path.mkdir()
        self.wrapper = self.rig / "android_sdk_sandbox_exec.py"
        self.python = self.rig / "python"
        self.process_scope = self.rig / "process_scope.py"
        self.program = self.rig / "source_tree_guard.py"
        for path, payload in (
            (self.wrapper, b"wrapper"),
            (self.python, b"python"),
            (self.process_scope, b"process scope"),
            (self.program, b"guard"),
        ):
            path.write_bytes(payload)
        isolated = self.root / "isolated"
        run_temp = isolated / "run"
        for path in (
            self.root / "user-gradle-home",
            isolated / "home",
            run_temp / "kotlin-project-persistent",
            run_temp / "kotlin-daemon",
        ):
            path.mkdir(parents=True)
        self.prepared = {
            "version": 1,
            "status": "prepared",
            "paths": {
                "app_root": str(self.app),
                "gradle_home": str(self.root / "user-gradle-home"),
                "isolated_root": str(isolated),
                "run_temp": str(run_temp),
                "flutter_root": str(self.flutter_root),
                "android_sdk_root": str(self.android_sdk_root),
            },
            "components": {
                "wrapper": {"path": str(self.wrapper), "sha256": _sha(self.wrapper)},
                "python": {"path": str(self.python), "sha256": _sha(self.python)},
                "processScope": {
                    "path": str(self.process_scope),
                    "sha256": _sha(self.process_scope),
                },
            },
        }
        self.uid = os.getuid()
        self.lsof = {"live": "sealed"}
        self.label = "gate-seed-allocated"
        self.authority_path = (
            self.evidence
            / "process-scope-authorities"
            / f"{self.label}.process-authority.json"
        )
        self.reference_path = (
            self.evidence
            / "process-scope-reference-authorities"
            / "source-guard.reference-authority.json"
        )
        self.scope_path = self.evidence / f"{self.label}.process-scope.json"
        self.result_path = self.evidence / f"{self.label}.scoped-command.json"
        self.roots = validator._expected_roots(self.prepared)
        _write(
            self.evidence / "android-toolchain.roots.post.json",
            {"jdkRoot": str(self.jdk_root), "gradleRoot": str(self.gradle_root)},
        )
        self.owner = self._identity(100, 1, 100, 90)
        self.supervisor = self._identity(110, 100, 100, 90)
        self.leader = self._identity(120, 110, 120, 120)
        self.subject = self._identity(130, 100, 100, 90)
        self.authority = {
            "version": 2,
            "launchId": "a" * 32,
            "ownerRoot": self.owner,
            "supervisor": self.supervisor,
            "leader": self.leader,
            "wrapper": {"path": str(self.wrapper), "sha256": _sha(self.wrapper)},
            "roots": self.roots,
            "cwd": str(self.app),
        }
        ready = self.evidence / "source-tree-guard-ready.json"
        _write(ready, {"pid": 130, "nonce": "b" * 32})
        self.reference = {
            "version": 1,
            "kind": "source-guard-reference-exemption",
            "exemptionId": "c" * 32,
            "ownerRoot": self.owner,
            "subject": self.subject,
            "executable": {"path": str(self.python), "sha256": _sha(self.python)},
            "program": {"path": str(self.program), "sha256": _sha(self.program)},
            "argv": [],
            "readiness": {
                "path": str(ready),
                "sha256": _sha(ready),
                "nonce": "b" * 32,
                "stopPath": str(self.evidence / "source-tree-guard.stop"),
                "resultPath": str(self.evidence / "source-tree-guard-result.json"),
            },
            "roots": self.roots,
            "allowedRootKeys": ["gradleUserHome", "isolatedUserRoot"],
        }
        self.reference["argv"] = self._guard_argv(bootstrap=False)
        _write(self.authority_path, self.authority)
        _write(self.reference_path, self.reference)
        record = self._record(self.leader)
        exempt_record = self._record(self.subject, cwd=self.roots["gradleUserHome"])
        exempt_record["executable"] = str(self.python)
        exempt_record["argv"] = copy.deepcopy(self.reference["argv"])
        self.scope = self._scope(
            [(self.authority_path, self.authority)],
            [(self.reference_path, self.reference)],
            [record],
            [copy.deepcopy(record)],
            [],
            [
                {
                    "exemptionId": "c" * 32,
                    "process": exempt_record,
                    "reasons": [
                        "argv:isolatedUserRoot",
                        "cwd:gradleUserHome",
                    ],
                }
            ],
        )
        _write(self.scope_path, self.scope)
        self.result = {
            "version": 1,
            "label": self.label,
            "status": "command_failed",
            "commandExitCode": 1,
            "authority": self.authority,
            "scopeTermination": self.scope,
            "authoritySha256": _sha(self.authority_path),
            "childPid": 120,
            "scopeEvidenceSha256": _sha(self.scope_path),
        }
        _write(self.result_path, self.result)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _identity(self, pid: int, ppid: int, pgid: int, sid: int) -> dict[str, int]:
        return {
            "pid": pid,
            "ppid": ppid,
            "pgid": pgid,
            "sid": sid,
            "uid": self.uid,
            "startSec": 10,
            "startUsec": pid,
        }

    def _record(
        self, identity: dict[str, int], cwd: str | None = None
    ) -> dict[str, object]:
        return {
            "identity": identity,
            "state": 2,
            "executable": "/bin/zsh",
            "argv": ["/bin/zsh"],
            "environmentSha256": "d" * 64,
            "cwd": cwd,
            "root": "/",
            "openVnodePaths": [],
            "inspectionErrors": [],
            "vnodeEvidenceMethod": "libproc",
            "vnodeEvidenceComplete": True,
        }

    def _guard_argv(self, *, bootstrap: bool) -> list[str]:
        prefix = "bootstrap-" if bootstrap else ""
        toolchains = [str(self.android_sdk_root), str(self.jdk_root)]
        settings = str(
            Path(self.prepared["paths"]["isolated_root"]) / "xdg-config" / "settings"
        )
        if bootstrap:
            toolchains.extend((settings, str(Path(sys.base_prefix).resolve())))
        else:
            toolchains.extend(
                (
                    str(self.gradle_root),
                    settings,
                    str(
                        Path(self.prepared["paths"]["isolated_root"])
                        / "android-user-home"
                        / "debug.keystore"
                    ),
                    str(Path(sys.base_prefix).resolve()),
                )
            )
        argv = [
            str(self.python),
            "-I",
            "-S",
            "-B",
            str(self.program),
            "--root",
            str(self.app),
            "--expected-flutter-root",
            str(self.flutter_root),
        ]
        for root in toolchains:
            argv.extend(("--toolchain-root", root))
        argv.extend(
            (
                "--backend",
                "darwin-fsevents",
                "--stop-file",
                str(self.evidence / f"{prefix}source-tree-guard.stop"),
                "--ready-file",
                str(self.evidence / f"{prefix}source-tree-guard-ready.json"),
                "--events-file",
                str(
                    Path(self.prepared["paths"]["isolated_root"])
                    / f"{prefix}source-tree-guard-events.jsonl"
                ),
                "--result-file",
                str(self.evidence / f"{prefix}source-tree-guard-result.json"),
                "--baseline-manifest",
                str(
                    self.evidence
                    / f"tested-files.{('bootstrap' if bootstrap else 'pre')}.sha256"
                ),
                "--baseline-sidecar",
                str(self.evidence / f"{prefix}source-tree-guard-baseline.json"),
                "--nonce",
                "b" * 32,
            )
        )
        return argv

    def _scope(
        self,
        authorities,
        references,
        stopped,
        term,
        kill,
        exempt,
        *,
        audit=False,
    ):
        value = {
            "version": 3,
            "status": "quiescent",
            "marker": (
                "TELLTALE_GATE_C_PROCESS_SCOPE_AUDIT"
                if audit
                else "TELLTALE_GATE_C_PROCESS_SCOPE"
            ),
            "ownerRoot": authorities[0][1]["ownerRoot"],
            "roots": self.roots,
            "authorities": [
                {"path": str(path), "sha256": _sha(path), "launchId": value["launchId"]}
                for path, value in authorities
            ],
            "referenceAuthorities": [
                {
                    "path": str(path),
                    "sha256": _sha(path),
                    "exemptionId": value["exemptionId"],
                }
                for path, value in references
            ],
            "authorizedSessions": (
                []
                if audit
                else sorted({value["leader"]["sid"] for _, value in authorities})
            ),
            "startedMonotonicNs": 1,
            "endedMonotonicNs": 2,
            "stoppedProcesses": stopped,
            "termSentProcesses": term,
            "killSentProcesses": kill,
            "remainingOwnedProcesses": [],
            "foreignProcesses": [],
            "referenceExemptProcesses": exempt,
            "inspectionLimitations": [],
            "referenceInspection": {
                "complete": True,
                "lsof": self.lsof,
                "fallbackProcesses": [],
            },
        }
        if audit:
            value["mode"] = "audit-only"
        return value

    def _write_full_authority_set(self):
        labels = set(validator.REQUIRED_NON_GATE_LABELS)
        for cut in validator.GATE_CUTS:
            phase = "realpluginmirror" if cut == "realpluginmirror" else "seed"
            labels.add(f"gate-{phase}-{cut}")
            labels.add(f"gate-recover-{cut}")
        pairs = []
        for label in labels:
            path = (
                self.evidence
                / "process-scope-authorities"
                / f"{label}.process-authority.json"
            )
            _write(path, self.authority)
            pairs.append((path, self.authority))
        probe = self.evidence / "android-sdk-sandbox-probe.process-authority.json"
        _write(probe, self.authority)
        pairs.append((probe, self.authority))
        self.assertEqual(len(pairs), 22)
        return sorted(pairs, key=lambda item: str(item[0]))

    def _validate(self):
        with mock.patch.object(
            validator,
            "_load_process_scope",
            return_value=mock.Mock(LSOF_SEAL=self.lsof),
        ):
            return validator.validate_scoped_command(
                self.evidence, self.label, "command_failed", self.prepared, self.rig
            )

    def test_accepts_producer_shaped_scoped_command(self) -> None:
        self.assertEqual(self._validate()["status"], "command_failed")

    def test_rejects_missing_or_tampered_scoped_child_environment(self) -> None:
        environment_path = validator._child_environment_path(self.authority_path)
        environment = json.loads(environment_path.read_text())

        environment_path.unlink()
        with self.assertRaisesRegex(validator.ValidationError, "unavailable"):
            self._validate()

        for label, mutate in (
            ("schema", lambda value: value.update(schema="wrong")),
            ("launch", lambda value: value.update(launchId="f" * 32)),
            (
                "actual digest",
                lambda value: value.update(actualNamesSha256="0" * 64),
            ),
            (
                "credential set",
                lambda value: value.update(credentialNamesAssertedAbsent=[]),
            ),
            (
                "credential present",
                lambda value: value.update(
                    forbiddenCredentialNamesPresent=["HF_TOKEN"]
                ),
            ),
            ("values observed", lambda value: value.update(valuesObserved=True)),
            (
                "post-barrier names",
                lambda value: value.update(postBarrierAddedNames=["TMPDIR"]),
            ),
            ("legacy version", lambda value: value.update(version=1)),
        ):
            with self.subTest(label=label):
                candidate = copy.deepcopy(environment)
                mutate(candidate)
                _write(environment_path, candidate)
                with self.assertRaises(validator.ValidationError):
                    self._validate()

        _write(self.authority_path, self.authority)
        environment_path.chmod(0o644)
        with self.assertRaisesRegex(validator.ValidationError, "unsafe"):
            self._validate()

    def test_accepts_gradle_version_with_android_cwd(self) -> None:
        label = "gradle-version"
        (self.app / "android").mkdir()
        bootstrap_ready = self.evidence / "bootstrap-source-tree-guard-ready.json"
        _write(bootstrap_ready, {"pid": 130, "nonce": "b" * 32})
        bootstrap_reference = copy.deepcopy(self.reference)
        bootstrap_reference["argv"] = self._guard_argv(bootstrap=True)
        bootstrap_reference["readiness"] = {
            "path": str(bootstrap_ready),
            "sha256": _sha(bootstrap_ready),
            "nonce": "b" * 32,
            "stopPath": str(self.evidence / "bootstrap-source-tree-guard.stop"),
            "resultPath": str(
                self.evidence / "bootstrap-source-tree-guard-result.json"
            ),
        }
        bootstrap_reference_path = (
            self.evidence
            / "process-scope-reference-authorities"
            / "bootstrap-source-guard.reference-authority.json"
        )
        _write(bootstrap_reference_path, bootstrap_reference)
        authority = copy.deepcopy(self.authority)
        authority["cwd"] = str(self.app / "android")
        authority_path = (
            self.evidence
            / "process-scope-authorities"
            / f"{label}.process-authority.json"
        )
        scope_path = self.evidence / f"{label}.process-scope.json"
        result_path = self.evidence / f"{label}.scoped-command.json"
        _write(authority_path, authority)
        exemptions = copy.deepcopy(self.scope["referenceExemptProcesses"])
        exemptions[0]["process"]["argv"] = copy.deepcopy(bootstrap_reference["argv"])
        scope = self._scope(
            [(authority_path, authority)],
            [(bootstrap_reference_path, bootstrap_reference)],
            [],
            [],
            [],
            exemptions,
        )
        _write(scope_path, scope)
        result = {
            "version": 1,
            "label": label,
            "status": "completed",
            "commandExitCode": 0,
            "authority": authority,
            "scopeTermination": scope,
            "authoritySha256": _sha(authority_path),
            "childPid": self.leader["pid"],
            "scopeEvidenceSha256": _sha(scope_path),
        }
        _write(result_path, result)
        with mock.patch.object(
            validator,
            "_load_process_scope",
            return_value=mock.Mock(LSOF_SEAL=self.lsof),
        ):
            report = validator.validate_scoped_command(
                self.evidence, label, "completed", self.prepared, self.rig
            )
        self.assertEqual(report["status"], "completed")

    def test_flutter_and_dart_versions_use_bootstrap_reference(self) -> None:
        bootstrap_ready = self.evidence / "bootstrap-source-tree-guard-ready.json"
        _write(bootstrap_ready, {"pid": 130, "nonce": "b" * 32})
        bootstrap_reference = copy.deepcopy(self.reference)
        bootstrap_reference["argv"] = self._guard_argv(bootstrap=True)
        bootstrap_reference["readiness"] = {
            "path": str(bootstrap_ready),
            "sha256": _sha(bootstrap_ready),
            "nonce": "b" * 32,
            "stopPath": str(self.evidence / "bootstrap-source-tree-guard.stop"),
            "resultPath": str(
                self.evidence / "bootstrap-source-tree-guard-result.json"
            ),
        }
        reference_path = (
            self.evidence
            / "process-scope-reference-authorities"
            / "bootstrap-source-guard.reference-authority.json"
        )
        _write(reference_path, bootstrap_reference)
        for label in ("flutter-version", "dart-version"):
            with self.subTest(label=label):
                authority_path = (
                    self.evidence
                    / "process-scope-authorities"
                    / f"{label}.process-authority.json"
                )
                scope_path = self.evidence / f"{label}.process-scope.json"
                result_path = self.evidence / f"{label}.scoped-command.json"
                _write(authority_path, self.authority)
                exemptions = copy.deepcopy(self.scope["referenceExemptProcesses"])
                exemptions[0]["process"]["argv"] = copy.deepcopy(
                    bootstrap_reference["argv"]
                )
                scope = self._scope(
                    [(authority_path, self.authority)],
                    [(reference_path, bootstrap_reference)],
                    [],
                    [],
                    [],
                    exemptions,
                )
                _write(scope_path, scope)
                result = {
                    "version": 1,
                    "label": label,
                    "status": "completed",
                    "commandExitCode": 0,
                    "authority": self.authority,
                    "scopeTermination": scope,
                    "authoritySha256": _sha(authority_path),
                    "childPid": self.leader["pid"],
                    "scopeEvidenceSha256": _sha(scope_path),
                }
                _write(result_path, result)
                with mock.patch.object(
                    validator,
                    "_load_process_scope",
                    return_value=mock.Mock(LSOF_SEAL=self.lsof),
                ):
                    report = validator.validate_scoped_command(
                        self.evidence,
                        label,
                        "completed",
                        self.prepared,
                        self.rig,
                    )
                self.assertEqual(report["status"], "completed")

    def test_rejects_duplicate_json_key(self) -> None:
        self.result_path.write_text('{"version":1,"version":1}\n')
        with self.assertRaisesRegex(validator.ValidationError, "duplicate JSON key"):
            self._validate()

    def test_rejects_foreign_uid_and_unauthorized_session(self) -> None:
        for mutation in ("uid", "sid"):
            with self.subTest(mutation=mutation):
                value = copy.deepcopy(self.scope)
                value["stoppedProcesses"][0]["identity"][mutation] += 1
                value["termSentProcesses"] = copy.deepcopy(value["stoppedProcesses"])
                _write(self.scope_path, value)
                changed = copy.deepcopy(self.result)
                changed["scopeTermination"] = value
                changed["scopeEvidenceSha256"] = _sha(self.scope_path)
                _write(self.result_path, changed)
                with self.assertRaises(validator.ValidationError):
                    self._validate()
                _write(self.scope_path, self.scope)
                _write(self.result_path, self.result)

    def test_rejects_term_record_not_exact_stopped_subset(self) -> None:
        value = copy.deepcopy(self.scope)
        value["termSentProcesses"][0]["argv"] = ["forged"]
        _write(self.scope_path, value)
        changed = copy.deepcopy(self.result)
        changed["scopeTermination"] = value
        changed["scopeEvidenceSha256"] = _sha(self.scope_path)
        _write(self.result_path, changed)
        with self.assertRaisesRegex(validator.ValidationError, "exact subset"):
            self._validate()

    def test_accepts_kill_only_new_authorized_session_descendant(self) -> None:
        value = copy.deepcopy(self.scope)
        child = self._record(self._identity(121, 120, 120, 120))
        value["killSentProcesses"] = [child]
        _write(self.scope_path, value)
        changed = copy.deepcopy(self.result)
        changed["scopeTermination"] = value
        changed["scopeEvidenceSha256"] = _sha(self.scope_path)
        _write(self.result_path, changed)
        self.assertEqual(self._validate()["status"], "command_failed")

    def test_rejects_unowned_fallback_identity(self) -> None:
        value = copy.deepcopy(self.scope)
        fallback = copy.deepcopy(value["stoppedProcesses"][0]["identity"])
        fallback["uid"] += 1
        value["referenceInspection"]["fallbackProcesses"] = [fallback]
        _write(self.scope_path, value)
        changed = copy.deepcopy(self.result)
        changed["scopeTermination"] = value
        changed["scopeEvidenceSha256"] = _sha(self.scope_path)
        _write(self.result_path, changed)
        with self.assertRaisesRegex(validator.ValidationError, "fallback"):
            self._validate()

    def test_rejects_authority_cwd_outside_exact_prepared_commands(self) -> None:
        value = copy.deepcopy(self.authority)
        value["cwd"] = str(self.root)
        _write(self.authority_path, value)
        with self.assertRaisesRegex(validator.ValidationError, "launch authority"):
            self._validate()

    def test_rejects_wrong_reference_program_and_readiness_path(self) -> None:
        for field in ("program", "readiness"):
            with self.subTest(field=field):
                value = copy.deepcopy(self.reference)
                if field == "program":
                    value["program"]["path"] = str(self.wrapper)
                else:
                    value["readiness"]["stopPath"] = str(self.evidence / "wrong.stop")
                _write(self.reference_path, value)
                with self.assertRaises(validator.ValidationError):
                    self._validate()
                _write(self.reference_path, self.reference)

    def test_rejects_forged_guard_configuration_even_when_record_matches(self) -> None:
        cases = {
            "root": ("--root", str(self.root)),
            "backend": ("--backend", "forged-backend"),
            "events": (
                "--events-file",
                str(Path(self.prepared["paths"]["isolated_root"]) / "forged.jsonl"),
            ),
            "baseline": (
                "--baseline-manifest",
                str(self.evidence / "forged.sha256"),
            ),
            "nonce": ("--nonce", "f" * 32),
        }
        for label, (option, replacement) in cases.items():
            with self.subTest(label=label):
                reference = copy.deepcopy(self.reference)
                index = reference["argv"].index(option) + 1
                reference["argv"][index] = replacement
                _write(self.reference_path, reference)
                scope = copy.deepcopy(self.scope)
                scope["referenceAuthorities"][0]["sha256"] = _sha(self.reference_path)
                scope["referenceExemptProcesses"][0]["process"]["argv"] = copy.deepcopy(
                    reference["argv"]
                )
                _write(self.scope_path, scope)
                result = copy.deepcopy(self.result)
                result["scopeTermination"] = scope
                result["scopeEvidenceSha256"] = _sha(self.scope_path)
                _write(self.result_path, result)
                with self.assertRaisesRegex(
                    validator.ValidationError,
                    "exact producer command",
                ):
                    self._validate()
                _write(self.reference_path, self.reference)
                _write(self.scope_path, self.scope)
                _write(self.result_path, self.result)

    def test_rejects_exempt_executable_or_argv_mismatch(self) -> None:
        for field, forged in (
            ("executable", "/bin/zsh"),
            ("argv", [str(self.python), "-I", "-S", "-B", str(self.wrapper)]),
        ):
            with self.subTest(field=field):
                value = copy.deepcopy(self.scope)
                value["referenceExemptProcesses"][0]["process"][field] = forged
                _write(self.scope_path, value)
                changed = copy.deepcopy(self.result)
                changed["scopeTermination"] = value
                changed["scopeEvidenceSha256"] = _sha(self.scope_path)
                _write(self.result_path, changed)
                with self.assertRaisesRegex(
                    validator.ValidationError, "reference exemption"
                ):
                    self._validate()
                _write(self.scope_path, self.scope)
                _write(self.result_path, self.result)

    def test_rejects_marker_or_observable_reason_mismatch(self) -> None:
        for reasons in (
            ["cwd:gradleUserHome", "marker"],
            ["argv:gradleUserHome", "cwd:gradleUserHome"],
        ):
            with self.subTest(reasons=reasons):
                value = copy.deepcopy(self.scope)
                value["referenceExemptProcesses"][0]["reasons"] = sorted(reasons)
                _write(self.scope_path, value)
                changed = copy.deepcopy(self.result)
                changed["scopeTermination"] = value
                changed["scopeEvidenceSha256"] = _sha(self.scope_path)
                _write(self.result_path, changed)
                with self.assertRaisesRegex(
                    validator.ValidationError, "observable reasons"
                ):
                    self._validate()
                _write(self.scope_path, self.scope)
                _write(self.result_path, self.result)

    def test_rejects_stale_lsof_seal(self) -> None:
        with mock.patch.object(
            validator,
            "_load_process_scope",
            return_value=mock.Mock(LSOF_SEAL={"live": "changed"}),
        ):
            with self.assertRaisesRegex(validator.ValidationError, "live lsof"):
                validator.validate_scoped_command(
                    self.evidence, self.label, "command_failed", self.prepared, self.rig
                )

    def test_accepts_producer_shaped_guarded_command(self) -> None:
        label = "android-toolchain-build"
        authority_path = (
            self.evidence
            / "process-scope-authorities"
            / f"{label}.process-authority.json"
        )
        scope_path = self.evidence / f"{label}-process-scope.json"
        result_path = self.evidence / f"{label}-supervision.json"
        log_path = self.evidence / f"{label}.log"
        _write(authority_path, self.authority)
        log_path.write_text("guarded output\n")
        log_path.chmod(0o600)
        exempt = copy.deepcopy(self.scope["referenceExemptProcesses"])
        scope = self._scope(
            [(authority_path, self.authority)],
            [(self.reference_path, self.reference)],
            [],
            [],
            [],
            exempt,
        )
        _write(scope_path, scope)
        result = {
            "version": 1,
            "label": label,
            "guardPid": self.subject["pid"],
            "guardExitObserved": False,
            "commandExitCode": 0,
            "termination": "natural_exit",
            "scopeTermination": scope,
            "status": "completed",
            "childPid": self.leader["pid"],
            "childPgid": self.leader["pgid"],
            "scopeAuthority": self.authority,
            "scopeAuthoritySha256": _sha(authority_path),
            "scopeEvidenceSha256": _sha(scope_path),
            "logSha256": _sha(log_path),
        }
        _write(result_path, result)
        with mock.patch.object(
            validator,
            "_load_process_scope",
            return_value=mock.Mock(LSOF_SEAL=self.lsof),
        ):
            report = validator.validate_guarded_command(
                self.evidence, label, self.prepared, self.rig
            )
        self.assertEqual(report["status"], "completed")

    def test_accepts_unique_reference_free_final_cleanup(self) -> None:
        authority_pairs = self._write_full_authority_set()
        cleanup = self._scope(
            authority_pairs,
            [],
            [],
            [],
            [],
            [],
            audit=True,
        )
        cleanup_path = self.evidence / "gradle-process-scope-cleanup-1.json"
        _write(cleanup_path, cleanup)
        result = {"processScopeCleanupSha256": _sha(cleanup_path)}
        with mock.patch.object(
            validator,
            "_load_process_scope",
            return_value=mock.Mock(LSOF_SEAL=self.lsof),
        ):
            report = validator.validate_final_cleanup(
                self.evidence, result, self.prepared, self.rig
            )
        self.assertEqual(report["status"], "quiescent")

    def test_final_cleanup_rejects_missing_or_extra_child_environment(self) -> None:
        authority_pairs = self._write_full_authority_set()
        cleanup = self._scope(authority_pairs, [], [], [], [], [], audit=True)
        cleanup_path = self.evidence / "gradle-process-scope-cleanup-1.json"
        _write(cleanup_path, cleanup)
        result = {"processScopeCleanupSha256": _sha(cleanup_path)}

        missing = validator._child_environment_path(authority_pairs[0][0])
        missing.unlink()
        with self.assertRaises(validator.ValidationError):
            validator.validate_final_cleanup(
                self.evidence, result, self.prepared, self.rig
            )

        _write(authority_pairs[0][0], authority_pairs[0][1])
        extra = self.evidence / "unexpected.child-environment.json"
        _write(extra, {})
        with mock.patch.object(
            validator,
            "_load_process_scope",
            return_value=mock.Mock(LSOF_SEAL=self.lsof),
        ):
            with self.assertRaisesRegex(
                validator.ValidationError, "incomplete or extra"
            ):
                validator.validate_final_cleanup(
                    self.evidence, result, self.prepared, self.rig
                )

    def test_accepts_probe_in_exact_producer_sorted_authority_order(self) -> None:
        authority_pairs = self._write_full_authority_set()
        self.assertEqual(
            [str(path) for path, _ in authority_pairs],
            sorted(str(path) for path, _ in authority_pairs),
        )
        cleanup = self._scope(authority_pairs, [], [], [], [], [], audit=True)
        cleanup_path = self.evidence / "gradle-process-scope-cleanup-1.json"
        _write(cleanup_path, cleanup)
        result = {"processScopeCleanupSha256": _sha(cleanup_path)}
        with mock.patch.object(
            validator,
            "_load_process_scope",
            return_value=mock.Mock(LSOF_SEAL=self.lsof),
        ):
            report = validator.validate_final_cleanup(
                self.evidence, result, self.prepared, self.rig
            )
        self.assertEqual(report["authorizedSessions"], [])

    def test_rejects_signal_mode_or_records_in_final_audit(self) -> None:
        authority_pairs = self._write_full_authority_set()
        cleanup = self._scope(authority_pairs, [], [], [], [], [], audit=True)
        cleanup_path = self.evidence / "gradle-process-scope-cleanup-1.json"
        result = {"processScopeCleanupSha256": ""}
        with mock.patch.object(
            validator,
            "_load_process_scope",
            return_value=mock.Mock(LSOF_SEAL=self.lsof),
        ):
            for mutation in ("marker", "mode", "sessions", "stopped"):
                with self.subTest(mutation=mutation):
                    candidate = copy.deepcopy(cleanup)
                    if mutation == "marker":
                        candidate["marker"] = "TELLTALE_GATE_C_PROCESS_SCOPE"
                    elif mutation == "mode":
                        candidate["mode"] = "signal"
                    elif mutation == "sessions":
                        candidate["authorizedSessions"] = [120]
                    else:
                        candidate["stoppedProcesses"] = [self._record(self.leader)]
                    _write(cleanup_path, candidate)
                    result["processScopeCleanupSha256"] = _sha(cleanup_path)
                    with self.assertRaises(validator.ValidationError):
                        validator.validate_final_cleanup(
                            self.evidence,
                            result,
                            self.prepared,
                            self.rig,
                        )

    def test_rejects_multiple_final_cleanup_files(self) -> None:
        cleanup_authority_path = (
            self.evidence
            / "process-scope-authorities"
            / "cleanup.process-authority.json"
        )
        _write(cleanup_authority_path, self.authority)
        cleanup = self._scope(
            [
                (cleanup_authority_path, self.authority),
                (self.authority_path, self.authority),
            ],
            [],
            [],
            [],
            [],
            [],
        )
        cleanup_path = self.evidence / "gradle-process-scope-cleanup-1.json"
        _write(cleanup_path, cleanup)
        result = {"processScopeCleanupSha256": _sha(cleanup_path)}
        (self.evidence / "gradle-process-scope-cleanup-2.json").write_text("{}\n")
        with self.assertRaisesRegex(validator.ValidationError, "not unique"):
            validator.validate_final_cleanup(
                self.evidence, result, self.prepared, self.rig
            )

    def test_rejects_referenced_final_cleanup(self) -> None:
        cleanup_authority_path = (
            self.evidence
            / "process-scope-authorities"
            / "cleanup.process-authority.json"
        )
        _write(cleanup_authority_path, self.authority)
        exempt_record = self._record(self.subject, cwd=self.roots["gradleUserHome"])
        exempt_record["executable"] = str(self.python)
        exempt_record["argv"] = copy.deepcopy(self.reference["argv"])
        cleanup = self._scope(
            [
                (cleanup_authority_path, self.authority),
                (self.authority_path, self.authority),
            ],
            [(self.reference_path, self.reference)],
            [],
            [],
            [],
            [
                {
                    "exemptionId": "c" * 32,
                    "process": exempt_record,
                    "reasons": ["cwd:gradleUserHome"],
                }
            ],
        )
        cleanup_path = self.evidence / "gradle-process-scope-cleanup-1.json"
        _write(cleanup_path, cleanup)
        result = {"processScopeCleanupSha256": _sha(cleanup_path)}
        with mock.patch.object(
            validator,
            "_load_process_scope",
            return_value=mock.Mock(LSOF_SEAL=self.lsof),
        ):
            with self.assertRaises(validator.ValidationError):
                validator.validate_final_cleanup(
                    self.evidence, result, self.prepared, self.rig
                )

    def test_rejects_external_final_authority_path(self) -> None:
        external = self.root / "external.process-authority.json"
        _write(external, self.authority)
        cleanup = self._scope([(external, self.authority)], [], [], [], [], [])
        cleanup_path = self.evidence / "gradle-process-scope-cleanup-1.json"
        _write(cleanup_path, cleanup)
        result = {"processScopeCleanupSha256": _sha(cleanup_path)}
        with self.assertRaisesRegex(validator.ValidationError, "authority set"):
            validator.validate_final_cleanup(
                self.evidence, result, self.prepared, self.rig
            )

    def test_rejects_deleted_required_non_gate_authority(self) -> None:
        pairs = self._write_full_authority_set()
        cleanup = self._scope(pairs, [], [], [], [], [])
        cleanup_path = self.evidence / "gradle-process-scope-cleanup-1.json"
        _write(cleanup_path, cleanup)
        result = {"processScopeCleanupSha256": _sha(cleanup_path)}
        for label in sorted(validator.REQUIRED_NON_GATE_LABELS):
            with self.subTest(label=label):
                target = (
                    self.evidence
                    / "process-scope-authorities"
                    / f"{label}.process-authority.json"
                )
                target.unlink()
                with self.assertRaises(validator.ValidationError):
                    validator.validate_final_cleanup(
                        self.evidence, result, self.prepared, self.rig
                    )
                _write(target, self.authority)

    def test_fixed_authority_universe_matches_run_sh_producers(self) -> None:
        source = self.rig.parent.parent.parent / "run.sh"
        if not source.exists():
            source = Path(__file__).with_name("run.sh")
        text = source.read_text(encoding="utf-8")
        wrapper_labels = set(re.findall(r"sealed_(?:flutter|dart) ([a-z0-9-]+)", text))
        direct_scoped = set(
            re.findall(r"^run_scoped_sandbox_command ([a-z0-9-]+) ", text, re.M)
        )
        guarded = set(re.findall(r"^run_guarded_command ([a-z0-9-]+) ", text, re.M))
        producer_non_gate = (
            wrapper_labels | direct_scoped | guarded | {"telemetry-memory-measure"}
        )
        self.assertEqual(producer_non_gate, set(validator.REQUIRED_NON_GATE_LABELS))
        expected = set(producer_non_gate)
        for cut in validator.GATE_CUTS:
            phase = "realpluginmirror" if cut == "realpluginmirror" else "seed"
            expected.add(f"gate-{phase}-{cut}")
            expected.add(f"gate-recover-{cut}")
        self.assertEqual(len(expected) + 1, 22)

    def test_rejects_deleted_required_probe_authority(self) -> None:
        pairs = self._write_full_authority_set()
        cleanup = self._scope(pairs, [], [], [], [], [])
        cleanup_path = self.evidence / "gradle-process-scope-cleanup-1.json"
        _write(cleanup_path, cleanup)
        result = {"processScopeCleanupSha256": _sha(cleanup_path)}
        (self.evidence / "android-sdk-sandbox-probe.process-authority.json").unlink()
        with self.assertRaises(validator.ValidationError):
            validator.validate_final_cleanup(
                self.evidence, result, self.prepared, self.rig
            )


if __name__ == "__main__":
    unittest.main()
