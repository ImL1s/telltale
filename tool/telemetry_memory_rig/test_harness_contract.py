from __future__ import annotations

import copy
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


HERE = Path(__file__).resolve().parent
RUN_SH = (HERE / "run.sh").read_text(encoding="utf-8")
TARGET = (
    HERE.parent.parent / "integration_test" / "telemetry_memory_rig_test.dart"
).read_text(encoding="utf-8")
CRASH_TARGET = (
    HERE.parent.parent / "integration_test" / "telemetry_share_crash_rig_test.dart"
).read_text(encoding="utf-8")
ANALYZER = (HERE / "analyze_pss.py").read_text(encoding="utf-8")
GATE_VALIDATOR = (HERE / "gate_c_validate.py").read_text(encoding="utf-8")
TREE_MANIFEST = (HERE / "tree_manifest.py").read_text(encoding="utf-8")
SOURCE_TREE_GUARD = (HERE / "source_tree_guard.py").read_text(encoding="utf-8")
SEALED_SDK_EXEC = (HERE / "sealed_sdk_exec.sh").read_text(encoding="utf-8")
PREPARE_GRADLE_HOME = (HERE / "prepare_gradle_home.py").read_text(encoding="utf-8")
ANDROID_TOOLCHAIN_MANIFEST = (HERE / "android_toolchain_manifest.py").read_text(
    encoding="utf-8"
)
BOUNDED_REAP = (HERE / "bounded_reap.sh").read_text(encoding="utf-8")
GUARDED_COMMAND = (HERE / "guarded_command.py").read_text(encoding="utf-8")
SCOPED_COMMAND = (HERE / "scoped_command.py").read_text(encoding="utf-8")
PROCESS_SCOPE = (HERE / "process_scope.py").read_text(encoding="utf-8")
ANDROID_SANDBOX_PREFLIGHT = (HERE / "android_sdk_sandbox_preflight.py").read_text(
    encoding="utf-8"
)
OUTER_PROCESS_SCOPE_VALIDATOR = (HERE / "outer_process_scope_validator.py").read_text(
    encoding="utf-8"
)
OUTER_GATE_RESULT_VERIFIER = (HERE / "outer_gate_result_verifier.py").read_text(
    encoding="utf-8"
)
ADB_STATE_GUARD = (HERE / "adb_state_guard.sh").read_text(encoding="utf-8")
SEALED_GRADLE_FLUTTER = HERE / "sealed_gradle_flutter.sh"
SEALED_GRADLE_FLUTTER_TEXT = SEALED_GRADLE_FLUTTER.read_text(encoding="utf-8")
GENERATOR = (HERE / "generate_fixtures.dart").read_text(encoding="utf-8")
STORE = (
    HERE.parent.parent
    / "lib"
    / "telemetry"
    / "session"
    / "telemetry_session_store.dart"
).read_text(encoding="utf-8")
BLOCKERS = (HERE / "GATE_C_BLOCKERS.md").read_text(encoding="utf-8")
GRADLE_VERIFICATION = (
    HERE.parent.parent / "android" / "gradle" / "verification-metadata.xml"
).read_text(encoding="utf-8")
ANDROID_BUILD_GRADLE = (
    HERE.parent.parent / "android" / "app" / "build.gradle.kts"
).read_text(encoding="utf-8")


class HarnessContractTest(unittest.TestCase):
    @staticmethod
    def _sampling_cadence_helpers() -> str:
        start = RUN_SH.index("gate_c_monotonic_ns() {")
        end = RUN_SH.index("\n}\n", RUN_SH.index("gate_c_sleep_to_cadence() {", start)) + 2
        return RUN_SH[start:end]

    @staticmethod
    def _scoped_sandbox_runner() -> str:
        start = RUN_SH.index("run_scoped_sandbox_command() {")
        end = RUN_SH.index("\n}\n", start) + 2
        return RUN_SH[start:end]

    @staticmethod
    def _version_probe_block() -> str:
        start = RUN_SH.index("flutter_version=$(sealed_flutter")
        end = RUN_SH.index('\n{\n  print -r -- "serial=$SERIAL"', start)
        return RUN_SH[start:end]

    def _run_version_probe(
        self,
        *,
        flutter_body: str,
        dart_body: str,
    ) -> subprocess.CompletedProcess[str]:
        script = f"""
set -euo pipefail
die() {{ print -u2 -- \"telemetry memory rig: $*\"; exit 1; }}
sealed_flutter() {{ shift; {flutter_body}; }}
sealed_dart() {{ shift; {dart_body}; }}
{self._version_probe_block()}
print -r -- \"flutter=$flutter_version\"
print -r -- \"dart=$dart_version\"
"""
        return subprocess.run(
            ["/bin/zsh", "-f", "-c", script],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )

    @staticmethod
    def _guarded_command_binding_validator() -> str:
        function_start = RUN_SH.index("run_guarded_command() {")
        heredoc_start = RUN_SH.index("<<'PY'", function_start)
        script_start = RUN_SH.index("\nimport ", heredoc_start) + 1
        script_end = RUN_SH.index("\nPY\n", script_start)
        return RUN_SH[script_start:script_end]

    def _run_guarded_command_binding_validator(
        self,
        *,
        status: str,
        command_exit: int,
        helper_exit: int,
        tamper_authority_sha256: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            scope_path = temporary / "scope.json"
            authority_path = temporary / "authority.json"
            result_path = temporary / "result.json"
            scope = {"version": 3, "status": "quiescent"}
            authority = {"leader": {"pid": 4312, "pgid": 4312}}
            scope_path.write_text(json.dumps(scope), encoding="utf-8")
            authority_path.write_text(json.dumps(authority), encoding="utf-8")
            authority_sha256 = hashlib.sha256(authority_path.read_bytes()).hexdigest()
            if tamper_authority_sha256:
                authority_sha256 = "0" * 64
            supervisor = {
                "version": 1,
                "label": "android-toolchain-build",
                "guardPid": 9917,
                "guardExitObserved": False,
                "commandExitCode": command_exit,
                "termination": "natural_exit",
                "scopeTermination": scope,
                "status": status,
                "childPid": 4312,
                "childPgid": 4312,
                "scopeAuthority": authority,
                "scopeAuthoritySha256": authority_sha256,
                "scopeEvidenceSha256": hashlib.sha256(
                    scope_path.read_bytes()
                ).hexdigest(),
                "logSha256": "1" * 64,
            }
            result_path.write_text(json.dumps(supervisor), encoding="utf-8")
            validator = self._guarded_command_binding_validator()
            script = f"""
validate_binding() {{
  {shlex.quote(sys.executable)} -I -S -B - \
    {shlex.quote(str(result_path))} \
    {shlex.quote(str(scope_path))} \
    {shlex.quote(str(authority_path))} \
    android-toolchain-build 9917 "$1" <<'PY'
{validator}
PY
}}
exercise() {{
  local helper_exit=$1
  validate_binding "$helper_exit" || return 72
  (( helper_exit == 0 )) || return "$helper_exit"
  return 0
}}
exercise {helper_exit}
"""
            return subprocess.run(
                ["/bin/zsh", "-f", "-c", script],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )

    @staticmethod
    def _source_guard_readiness_waiter() -> str:
        start = RUN_SH.index("wait_for_live_guard_ready() {")
        end = RUN_SH.index("\n}\n", start) + 2
        return RUN_SH[start:end]

    def _run_source_guard_readiness_waiter(
        self,
        ready_file: str | Path,
        *,
        pid_argument: str = '"$child"',
        timeout_ms: str = "250",
    ) -> subprocess.CompletedProcess[str]:
        script = f"""
PYTHON={shlex.quote(sys.executable)}
{self._source_guard_readiness_waiter()}
/bin/sleep 30 &
child=$!
cleanup() {{
  kill "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
}}
trap cleanup EXIT
wait_for_live_guard_ready {pid_argument} {shlex.quote(str(ready_file))} {timeout_ms}
"""
        return subprocess.run(
            ["/bin/zsh", "-f", "-c", script],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )

    @staticmethod
    def _guard_result_validator(evidence_name: str) -> str:
        marker = f"> \"$EVIDENCE/{evidence_name}\" <<'PY'\n"
        start = RUN_SH.index(marker) + len(marker)
        end = RUN_SH.index("\nPY", start)
        return RUN_SH[start:end]

    @staticmethod
    def _guard_readiness_validator(evidence_name: str) -> str:
        return HarnessContractTest._guard_result_validator(evidence_name)

    @staticmethod
    def _valid_guard_fingerprint(seed: int) -> dict[str, object]:
        return {
            "sha256": f"{seed:064x}",
            "device": 1,
            "inode": seed,
            "mode": 0o100664,
            "linkCount": 1,
            "uid": os.getuid(),
            "gid": next(
                candidate
                for candidate in range(0, 65536)
                if candidate not in {os.getegid(), *os.getgroups()}
            ),
            "size": seed,
            "mtimeNs": 1_000_000 + seed,
            "ctimeNs": 2_000_000 + seed,
            "birthtimeNs": 500_000 + seed,
            "fileFlags": 0,
            "xattrs": [
                {
                    "name": "hex:636f6d2e74657374",
                    "bytes": 4,
                    "sha256": "a" * 64,
                }
            ],
        }

    @classmethod
    def _valid_guard_pair(
        cls,
        sequence: int,
    ) -> tuple[dict[str, object], dict[str, object]]:
        path = f"/sealed/source-{sequence}.dart"
        fingerprint = cls._valid_guard_fingerprint(sequence)
        manifest_entries = [
            {
                "logicalId": f"lib/source-{sequence}.dart",
                "namespace": "local",
                "sha256": fingerprint["sha256"],
            }
        ]
        raw = {
            "recordType": "raw-darwin-fsevents",
            "path": path,
            "rawFlags": 0x00410000,
            "eventId": 100 + sequence,
            "callbackBatchSequence": 1,
            "callbackRecordSequence": sequence,
        }
        classified = {
            "recordType": "classified-darwin-fsevents",
            "path": path,
            "flags": ["IsFile", "ItemCloned"],
            "included": True,
            "material": False,
            "violates": False,
            "scope": "local-directory",
            "eventId": 100 + sequence,
            "callbackBatchSequence": 1,
            "callbackRecordSequence": sequence,
            "cloneReconciliation": {
                "policy": "sealed-manifest-pure-item-cloned-v2",
                "status": "clone-observed-no-delta",
                "baselineCanonicalPath": path,
                "baselineEventScope": "local-directory",
                "baselineManifestEntries": manifest_entries,
                "baseline": fingerprint,
                "current": copy.deepcopy(fingerprint),
            },
        }
        return raw, classified

    @staticmethod
    def _guard_result(
        attestation: dict[str, object],
        *,
        raw_count: int,
        classified_count: int,
        clone_no_delta_count: int,
        fatal_count: int = 0,
    ) -> dict[str, object]:
        return {
            "version": 3,
            "nonce": "test-nonce",
            "watcherBackend": "darwin-fsevents",
            "status": "stopped",
            "readyWritten": True,
            "startedEpochUs": 100,
            "stopRequestedEpochUs": 200,
            "endedEpochUs": 300,
            "canaryCreatedObserved": True,
            "canaryRemovedObserved": True,
            "canaryWriteAttemptCount": 1,
            "canaryDeleteAttemptCount": 1,
            "bootstrapEventCount": 0,
            "violatingEventCount": 0,
            "cloneReconciliationPolicy": "sealed-manifest-pure-item-cloned-v2",
            **attestation,
            "rawCallbackRecordCount": raw_count,
            "classifiedEventCount": classified_count,
            "fatalRawRecordCount": fatal_count,
            "suppressedInternalSinkEventCount": 0,
            "cloneObservedNoDeltaEventCount": clone_no_delta_count,
            "observedEventCount": classified_count,
            "guardError": None,
            "watcherTermination": {
                "contained": True,
                "exitCode": 0,
                "flushSyncRequested": True,
                "flushSyncCompleted": True,
                "drainedSentinelEmitted": True,
                "drainedSentinelObserved": True,
            },
        }

    def _run_guard_result_validator(
        self,
        evidence_name: str,
        ledger: list[dict[str, object]],
        artifact_mutation: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        import hashlib

        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            rewritten = copy.deepcopy(ledger)
            canonical_paths: dict[int, str] = {}
            for sequence in (1, 2):
                source = temporary / f"source-{sequence}.dart"
                source.write_bytes(b"x" * sequence)
                canonical_paths[sequence] = str(source.resolve(strict=True))
            replacements = {
                f"/sealed/source-{sequence}.dart": canonical
                for sequence, canonical in canonical_paths.items()
            }

            def replace_paths(value: object) -> None:
                if isinstance(value, dict):
                    for key, item in value.items():
                        if isinstance(item, str) and item in replacements:
                            value[key] = replacements[item]
                        else:
                            replace_paths(item)
                elif isinstance(value, list):
                    for item in value:
                        replace_paths(item)

            replace_paths(rewritten)
            baseline = temporary / "baseline.sha256"
            baseline.write_text(
                "".join(
                    f"{sequence:064x}  lib/source-{sequence}.dart\n"
                    for sequence in (1, 2)
                ),
                encoding="utf-8",
            )
            records = []
            for sequence in (1, 2):
                fingerprint = self._valid_guard_fingerprint(sequence)
                records.append(
                    {
                        "canonicalPath": canonical_paths[sequence],
                        "eventScope": "local-directory",
                        "manifestEntries": [
                            {
                                "logicalId": f"lib/source-{sequence}.dart",
                                "namespace": "local",
                                "sha256": f"{sequence:064x}",
                            }
                        ],
                        "fingerprint": fingerprint,
                    }
                )
            sidecar_payload = {
                "version": 1,
                "policy": "sealed-manifest-pure-item-cloned-v2",
                "manifestPath": str(baseline.resolve(strict=True)),
                "manifestSha256": hashlib.sha256(baseline.read_bytes()).hexdigest(),
                "manifestEntryCount": 2,
                "uniqueRegularFileCount": 2,
                "uniqueRegularFileBytes": 3,
                "totalXattrBytes": 8,
                "namespaceEntryCounts": {"local": 2},
                "eventScopeFileCounts": {"local-directory": 2},
                "records": records,
            }
            sidecar = temporary / "baseline.json"

            def write_sidecar() -> None:
                sidecar.write_text(
                    json.dumps(sidecar_payload, sort_keys=True, separators=(",", ":"))
                    + "\n",
                    encoding="utf-8",
                )

            write_sidecar()
            attestation = {
                "baselineManifestPath": str(baseline.resolve(strict=True)),
                "baselineManifestSha256": hashlib.sha256(
                    baseline.read_bytes()
                ).hexdigest(),
                "baselineSidecarPath": str(sidecar.resolve(strict=True)),
                "baselineSidecarSha256": hashlib.sha256(
                    sidecar.read_bytes()
                ).hexdigest(),
                "baselineSidecarBytes": len(sidecar.read_bytes()),
                "baselineManifestEntryCount": 2,
                "baselineUniqueRegularFileCount": 2,
                "baselineUniqueRegularFileBytes": 3,
                "baselineTotalXattrBytes": 8,
                "baselineNamespaceEntryCounts": {"local": 2},
                "baselineEventScopeFileCounts": {"local-directory": 2},
            }
            raw_count = sum(
                record.get("recordType") == "raw-darwin-fsevents"
                for record in rewritten
            )
            classified_count = sum(
                record.get("recordType") == "classified-darwin-fsevents"
                for record in rewritten
            )
            clone_no_delta_count = sum(
                record.get("recordType") == "classified-darwin-fsevents"
                and isinstance(record.get("cloneReconciliation"), dict)
                and record["cloneReconciliation"].get("status")
                == "clone-observed-no-delta"
                for record in rewritten
            )
            result_value = self._guard_result(
                attestation,
                raw_count=raw_count,
                classified_count=classified_count,
                clone_no_delta_count=clone_no_delta_count,
            )
            ready_value = {
                "version": 3,
                "nonce": "test-nonce",
                "cloneReconciliationPolicy": "sealed-manifest-pure-item-cloned-v2",
                "bootstrapEventCount": 0,
                **attestation,
            }
            if artifact_mutation == "result-schema":
                result_value["version"] = 2
            elif artifact_mutation == "ready-schema":
                ready_value["version"] = 2
            elif artifact_mutation == "result-policy":
                result_value["cloneReconciliationPolicy"] = "forged-policy"
            elif artifact_mutation == "ready-policy":
                ready_value["cloneReconciliationPolicy"] = "forged-policy"
            elif artifact_mutation == "nonmember-group-writable-valid":
                pass
            elif artifact_mutation == "current-group-writable-fingerprint":
                sidecar_payload["records"][0]["fingerprint"]["gid"] = os.getegid()
                sidecar_payload["records"][0]["fingerprint"]["mode"] = 0o100664
                write_sidecar()
            elif artifact_mutation == "world-writable-fingerprint":
                sidecar_payload["records"][0]["fingerprint"]["mode"] = 0o100666
                write_sidecar()
            elif artifact_mutation == "sidecar-sha-attestation":
                result_value["baselineSidecarSha256"] = "f" * 64
            elif artifact_mutation == "sidecar-count-attestation":
                result_value["baselineUniqueRegularFileCount"] = 3
            elif artifact_mutation == "observed-count-tampering":
                result_value["observedEventCount"] = classified_count - 1
            elif artifact_mutation == "sidecar-resource-cap":
                oversized = 4 * 1024 * 1024 * 1024 + 1
                sidecar_payload["records"][0]["fingerprint"]["size"] = oversized
                sidecar_payload["uniqueRegularFileBytes"] = oversized + 2
                write_sidecar()
            elif artifact_mutation == "sidecar-noncanonical-tampering":
                sidecar.write_text(
                    sidecar.read_text(encoding="utf-8") + " ", encoding="utf-8"
                )
            elif artifact_mutation == "sidecar-logical-id-tampering":
                sidecar_payload["records"][0]["manifestEntries"][0]["logicalId"] = (
                    "lib/forged.dart"
                )
                write_sidecar()
            elif artifact_mutation == "sidecar-scope-tampering":
                sidecar_payload["records"][0]["eventScope"] = "root-wide"
                write_sidecar()
            elif artifact_mutation == "sidecar-manifest-sha-tampering":
                sidecar_payload["manifestSha256"] = "f" * 64
                write_sidecar()
            events = temporary / "events.jsonl"
            events.write_text(
                "".join(json.dumps(record) + "\n" for record in rewritten),
                encoding="utf-8",
            )
            result = temporary / "result.json"
            result.write_text(json.dumps(result_value), encoding="utf-8")
            ready = temporary / "ready.json"
            ready.write_text(json.dumps(ready_value), encoding="utf-8")
            return subprocess.run(
                [
                    sys.executable,
                    "-I",
                    "-S",
                    "-B",
                    "-",
                    str(result),
                    str(events),
                    str(ready),
                    str(baseline.resolve(strict=True)),
                    str(sidecar.resolve(strict=True)),
                    "test-nonce",
                    "50",
                    "150",
                    "250",
                ],
                input=self._guard_result_validator(evidence_name),
                text=True,
                capture_output=True,
                check=False,
            )

    def _run_guard_readiness_validator(
        self,
        evidence_name: str,
        sidecar_placement: str,
    ) -> subprocess.CompletedProcess[str]:
        import hashlib

        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory).resolve(strict=True)
            app_root = temporary / "app"
            watched_directory = app_root / "lib"
            watched_directory.mkdir(parents=True)
            watched_file = app_root / "pubspec.yaml"
            watched_file.write_text("name: fixture\n", encoding="utf-8")
            source = watched_directory / "source.dart"
            source.write_text("sealed", encoding="utf-8")
            digest = hashlib.sha256(source.read_bytes()).hexdigest()
            baseline_directory = app_root / ".omx/evidence"
            baseline_directory.mkdir(parents=True)
            baseline = baseline_directory / "baseline.sha256"
            baseline.write_text(f"{digest}  lib/source.dart\n", encoding="utf-8")
            if sidecar_placement == "under-logical-directory":
                sidecar = watched_directory / "baseline.json"
            else:
                sidecar = baseline_directory / "baseline.json"
            fingerprint = self._valid_guard_fingerprint(1)
            fingerprint["sha256"] = digest
            fingerprint["size"] = source.stat().st_size
            sidecar_payload = {
                "version": 1,
                "policy": "sealed-manifest-pure-item-cloned-v2",
                "manifestPath": str(baseline.resolve(strict=True)),
                "manifestSha256": hashlib.sha256(baseline.read_bytes()).hexdigest(),
                "manifestEntryCount": 1,
                "uniqueRegularFileCount": 1,
                "uniqueRegularFileBytes": source.stat().st_size,
                "totalXattrBytes": 4,
                "namespaceEntryCounts": {"local": 1},
                "eventScopeFileCounts": {"local-directory": 1},
                "records": [
                    {
                        "canonicalPath": str(source.resolve(strict=True)),
                        "eventScope": "local-directory",
                        "manifestEntries": [
                            {
                                "logicalId": "lib/source.dart",
                                "namespace": "local",
                                "sha256": digest,
                            }
                        ],
                        "fingerprint": fingerprint,
                    }
                ],
            }
            sidecar.write_text(
                json.dumps(sidecar_payload, sort_keys=True, separators=(",", ":"))
                + "\n",
                encoding="utf-8",
            )
            attestation = {
                "baselineManifestPath": str(baseline.resolve(strict=True)),
                "baselineManifestSha256": hashlib.sha256(
                    baseline.read_bytes()
                ).hexdigest(),
                "baselineSidecarPath": str(sidecar.resolve(strict=True)),
                "baselineSidecarSha256": hashlib.sha256(
                    sidecar.read_bytes()
                ).hexdigest(),
                "baselineSidecarBytes": len(sidecar.read_bytes()),
                "baselineManifestEntryCount": 1,
                "baselineUniqueRegularFileCount": 1,
                "baselineUniqueRegularFileBytes": source.stat().st_size,
                "baselineTotalXattrBytes": 4,
                "baselineNamespaceEntryCounts": {"local": 1},
                "baselineEventScopeFileCounts": {"local-directory": 1},
            }
            watch_paths = [
                str(watched_file.resolve(strict=True)),
                str(watched_directory.resolve(strict=True)),
            ]
            if sidecar_placement == "equal-logical-file":
                watch_paths.append(str(sidecar.resolve(strict=True)))
            ready_value = {
                "version": 3,
                "nonce": "test-nonce",
                "pid": 1234,
                "watcherPid": 5678,
                "watcherBackend": "darwin-fsevents",
                "startedEpochUs": 100,
                "bootstrapEventCount": 0,
                "canaryCreatedObserved": True,
                "canaryRemovedObserved": True,
                "canaryWriteAttemptCount": 1,
                "canaryDeleteAttemptCount": 1,
                "watchPaths": watch_paths,
                "nativeFSEventsWatchRoots": [str(app_root.resolve(strict=True))],
                "suppressedInternalSinkEventCount": 0,
                "cloneReconciliationPolicy": "sealed-manifest-pure-item-cloned-v2",
                **attestation,
            }
            ready = temporary / "ready.json"
            ready.write_text(json.dumps(ready_value), encoding="utf-8")
            return subprocess.run(
                [
                    sys.executable,
                    "-I",
                    "-S",
                    "-B",
                    "-",
                    str(ready),
                    "test-nonce",
                    "1234",
                    "50",
                    str(baseline.resolve(strict=True)),
                    str(sidecar.resolve(strict=True)),
                ],
                input=self._guard_readiness_validator(evidence_name),
                text=True,
                capture_output=True,
                check=False,
            )

    def test_guard_readiness_sidecar_uses_logical_not_compacted_roots(self):
        validators = (
            "bootstrap-source-tree-guard-ready-validated.txt",
            "source-tree-guard-ready-validated.txt",
        )
        for validator in validators:
            with self.subTest(validator=validator, placement="broad-native-only"):
                completed = self._run_guard_readiness_validator(
                    validator,
                    "broad-native-only",
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
            for placement in ("equal-logical-file", "under-logical-directory"):
                with self.subTest(validator=validator, placement=placement):
                    completed = self._run_guard_readiness_validator(
                        validator,
                        placement,
                    )
                    self.assertNotEqual(completed.returncode, 0, completed.stdout)
                    self.assertIn(
                        "readiness identity/canary/baseline proof failed",
                        completed.stderr,
                    )

    def test_rejects_host_language_vm_and_android_toolchain_overrides(self):
        for override in (
            "PYTHON*",
            "JDK_JAVA_OPTIONS",
            "JAVA_TOOL_OPTIONS",
            "_JAVA_OPTIONS",
            "ANDROID_NDK_PATH",
            "ANDROID_NDK_HOME",
            "ANDROID_NDK_ROOT",
            "GRADLE_HOME",
            "GRADLE_USER_HOME",
            "GRADLE_OPTS",
            "KOTLIN_DAEMON_JVM_OPTIONS",
            "ADB_SERVER_SOCKET",
            "ADB_SERVER_ADDRESS",
            "ANDROID_ADB_SERVER_PORT",
            "DYLD_*",
            "LD_PRELOAD",
            "LD_LIBRARY_PATH",
            "ORG_GRADLE_PROJECT_*",
            "TELLTALE_GATE_C_FLUTTER_ROOT",
            "TELLTALE_GATE_C_JDK_ROOT",
            "TELLTALE_GATE_C_SANDBOX_*",
            "FLUTTER_ALREADY_LOCKED",
        ):
            with self.subTest(override=override):
                self.assertIn(override, RUN_SH)

    def test_shell_entrypoints_disable_user_zsh_startup_files(self):
        self.assertTrue(RUN_SH.startswith("#!/bin/zsh -f\n"))
        self.assertTrue(SEALED_SDK_EXEC.startswith("#!/bin/zsh -f\n"))
        self.assertIn("ZDOTDIR", RUN_SH)

    def test_isolates_flutter_config_and_debug_signing_identity(self):
        self.assertNotIn("flutter-config-machine.json", RUN_SH)
        self.assertIn("flutter-config-bindings.json", RUN_SH)
        self.assertIn('if "android-ndk" in value', RUN_SH)
        self.assertIn("ISOLATED_USER_TEMP_PARENT", RUN_SH)
        self.assertIn("XDG_CONFIG_HOME", RUN_SH)
        self.assertIn(
            'ISOLATED_FLUTTER_SETTINGS="$XDG_CONFIG_HOME/settings"',
            RUN_SH,
        )
        self.assertNotIn(
            'ISOLATED_FLUTTER_SETTINGS="$XDG_CONFIG_HOME/flutter/settings"',
            RUN_SH,
        )
        self.assertIn("ANDROID_USER_HOME", RUN_SH)
        self.assertIn("value != expected", RUN_SH)
        self.assertIn('--toolchain-root "$ISOLATED_FLUTTER_SETTINGS"', RUN_SH)
        self.assertIn('--toolchain-root "$SEALED_DEBUG_KEYSTORE"', RUN_SH)
        self.assertIn("android-debug-keystore.pre.sha256", RUN_SH)
        self.assertIn("android-debug-keystore.post.sha256", RUN_SH)

    def test_xdg_config_home_has_one_exclusive_initializer(self):
        setup_start = RUN_SH.index(
            "ISOLATED_USER_TEMP_PARENT=$(mktemp -d /tmp/telltale-gate-user-home.XXXXXX)"
        )
        settings_initializer = RUN_SH.index(
            "path.parent.mkdir(mode=0o700)",
            setup_start,
        )
        shell_setup = RUN_SH[setup_start:settings_initializer]
        mkdir_start = shell_setup.index('mkdir -p "$HOME"')
        mkdir_end = shell_setup.index("\nchmod 700 ", mkdir_start)

        self.assertNotIn(
            '"$XDG_CONFIG_HOME"',
            shell_setup[mkdir_start:mkdir_end],
            "the fresh XDG config directory must be created only by the "
            "exclusive settings initializer",
        )
        self.assertNotIn("exist_ok=True", RUN_SH[settings_initializer:])

    def test_gate_c_never_loads_release_signing_secrets(self):
        self.assertIn(
            "export ORG_GRADLE_PROJECT_telltaleGateCRigDebug=true",
            RUN_SH,
        )
        self.assertIn(
            "Gate C RigDebug Gradle property changed during the live rig",
            RUN_SH,
        )
        self.assertIn(
            'providers.gradleProperty("telltaleGateCRigDebug")',
            ANDROID_BUILD_GRADLE,
        )
        self.assertIn('gateCRigDebugProperty != "true"', ANDROID_BUILD_GRADLE)
        self.assertIn('!it.contains("RigDebug")', ANDROID_BUILD_GRADLE)
        self.assertRegex(
            ANDROID_BUILD_GRADLE,
            r"if \(!gateCRigDebugMode\) \{\s+val file = "
            r'rootProject\.file\("key\.properties"\)',
        )

    def test_gate_c_routes_nested_flutter_tasks_through_sealed_entrypoint(self):
        self.assertTrue(
            SEALED_GRADLE_FLUTTER.is_file(),
            "Gate C Gradle Flutter entrypoint is missing",
        )
        self.assertIn(
            "com.flutter.gradle.tasks.FlutterTask",
            ANDROID_BUILD_GRADLE,
        )
        self.assertNotIn(
            "tasks.withType<FlutterTask>().configureEach",
            ANDROID_BUILD_GRADLE,
        )
        self.assertRegex(
            ANDROID_BUILD_GRADLE,
            r"gradle\.taskGraph\.whenReady\s*\{\s*"
            r"val graphFlutterTasks = allTasks\s*"
            r"\.filterIsInstance<FlutterTask>\(\)",
        )
        self.assertIn(
            'graphFlutterTasks.single().name != "compileFlutterBuildRigDebug"',
            ANDROID_BUILD_GRADLE,
        )
        self.assertIn("graphFlutterTasks.size != 1", ANDROID_BUILD_GRADLE)
        self.assertIn(
            "Gate C task graph does not contain exactly the RigDebug FlutterTask",
            ANDROID_BUILD_GRADLE,
        )
        self.assertRegex(
            ANDROID_BUILD_GRADLE,
            r"val task = graphFlutterTasks\.single\(\)\s*"
            r"task\.flutterExecutable\s*=\s*sealedFlutterEntrypoint",
        )
        self.assertRegex(
            ANDROID_BUILD_GRADLE,
            r"task\.doFirst\s*\{\s*if \(task\.flutterExecutable\?\.canonicalFile "
            r"!= sealedFlutterEntrypoint\.canonicalFile\)",
        )
        self.assertIn(
            "Gate C FlutterTask did not bind the sealed entrypoint",
            ANDROID_BUILD_GRADLE,
        )
        self.assertIn(
            'name != "compileFlutterBuildRigDebug"',
            ANDROID_BUILD_GRADLE,
        )
        self.assertIn(
            "sealed_gradle_flutter.sh",
            ANDROID_BUILD_GRADLE,
        )
        self.assertIn(
            'export TELLTALE_GATE_C_FLUTTER_ROOT="$SEALED_FLUTTER_ROOT"',
            RUN_SH,
        )
        self.assertIn(
            "Gate C nested Flutter root changed during the live rig",
            RUN_SH,
        )
        self.assertIn("TELLTALE_GATE_C_JDK_ROOT", SEALED_GRADLE_FLUTTER_TEXT)
        self.assertIn("JAVA_HOME", SEALED_GRADLE_FLUTTER_TEXT)
        self.assertIn(
            "JAVA_HOME does not match TELLTALE_GATE_C_JDK_ROOT",
            SEALED_GRADLE_FLUTTER_TEXT,
        )

    def test_gate_c_disables_persistent_gradle_daemons_and_binds_the_build_jdk(self):
        build_start = RUN_SH.index("run_guarded_command android-toolchain-build")
        build_end = RUN_SH.index("verify_tested_tree", build_start)
        build = RUN_SH[build_start:build_end]
        self.assertIn("--no-android-gradle-daemon", build)

        self.assertIn("org.gradle.daemon=false", RUN_SH)
        self.assertIn("org.gradle.java.home=", RUN_SH)
        self.assertIn(
            'export TELLTALE_GATE_C_JDK_ROOT="$SEALED_JDK_ROOT"',
            RUN_SH,
        )
        self.assertIn('System.getProperty("java.home")', ANDROID_BUILD_GRADLE)
        self.assertIn("TELLTALE_GATE_C_JDK_ROOT", ANDROID_BUILD_GRADLE)

    def test_gate_c_gradle_properties_enable_full_stacktraces_under_pre_post_hash(self):
        properties_start = RUN_SH.index(
            'ISOLATED_GRADLE_PROPERTIES="$GRADLE_USER_HOME/gradle.properties"'
        )
        payload_start = RUN_SH.index("payload = (", properties_start)
        payload_end = RUN_SH.index("\ndescriptor = os.open(", payload_start)
        payload = RUN_SH[payload_start:payload_end]
        self.assertIn("b'org.gradle.logging.stacktrace=full\\n'", payload)

        reread = RUN_SH.index(
            "if path.read_bytes() != payload:",
            payload_end,
        )
        pre_hash = RUN_SH.index(
            '> "$EVIDENCE/isolated-gradle-properties.pre.sha256"',
            reread,
        )
        post_hash = RUN_SH.index(
            '> "$EVIDENCE/isolated-gradle-properties.post.sha256"',
            pre_hash,
        )
        pre_post_comparison = RUN_SH.index(
            'cmp "$EVIDENCE/isolated-gradle-properties.pre.sha256"',
            post_hash,
        )
        self.assertLess(payload_start, reread)
        self.assertLess(reread, pre_hash)
        self.assertLess(pre_hash, post_hash)
        self.assertLess(post_hash, pre_post_comparison)

    def test_generated_cleanup_rejects_symlinked_ancestor(self):
        marker = (
            '"$PYTHON" -I -S -B - "$APP_ROOT" '
            "\"$EVIDENCE/generated-input-cleanup.json\" <<'PY'\n"
        )
        start = RUN_SH.index(marker) + len(marker)
        body = RUN_SH[start : RUN_SH.index("\nPY\n", start)]
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "app"
            outside = base / "outside"
            root.mkdir()
            outside.mkdir()
            escaped = outside / "flutter_build"
            escaped.mkdir()
            (escaped / "must-survive").write_text("safe", encoding="utf-8")
            (root / ".dart_tool").symlink_to(outside, target_is_directory=True)
            evidence = base / "cleanup.json"

            result = subprocess.run(
                [sys.executable, "-c", body, str(root), str(evidence)],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "refusing symlinked generated-input cleanup path", result.stderr
            )
            self.assertTrue((escaped / "must-survive").is_file())
            self.assertFalse(evidence.exists())

    def test_generated_cleanup_removes_all_approved_backlog_before_sealing(self):
        marker = (
            '"$PYTHON" -I -S -B - "$APP_ROOT" '
            "\"$EVIDENCE/generated-input-cleanup.json\" <<'PY'\n"
        )
        start = RUN_SH.index(marker) + len(marker)
        body = RUN_SH[start : RUN_SH.index("\nPY\n", start)]
        approved = (
            "build",
            "android/.gradle",
            ".dart_tool/flutter_build",
            ".dart_tool/hooks_runner",
            ".dart_tool/test",
        )
        with tempfile.TemporaryDirectory() as temporary:
            temporary_root = Path(temporary).resolve()
            root = temporary_root / "app"
            root.mkdir()
            for relative in approved:
                generated = root / relative
                generated.mkdir(parents=True, exist_ok=True)
                (generated / "backlog").write_text("stale", encoding="utf-8")
            evidence = temporary_root / "cleanup.json"

            result = subprocess.run(
                [sys.executable, "-c", body, str(root), str(evidence)],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                json.loads(evidence.read_text(encoding="utf-8"))["removed"],
                list(approved),
            )
            for relative in approved:
                self.assertFalse((root / relative).exists())

    def test_poison_pythonpath_is_rejected_before_evidence_side_effects(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary) / "must-not-exist"
            environment = {
                "HOME": os.environ.get("HOME", "/tmp"),
                "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                "TELEMETRY_RIG_EVIDENCE_DIR": str(evidence),
                "PYTHONPATH": str(Path(temporary) / "poison"),
            }

            result = subprocess.run(
                ["/bin/zsh", str(HERE / "run.sh"), "poison-device"],
                cwd=HERE.parent.parent,
                env=environment,
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn(
                "host build override is not allowed for Gate C: PYTHONPATH",
                result.stderr,
            )
            self.assertFalse(evidence.exists())

    def test_poison_flutter_lock_override_is_rejected_before_evidence_side_effects(
        self,
    ):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary) / "must-not-exist"
            environment = {
                "HOME": os.environ.get("HOME", "/tmp"),
                "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                "TELEMETRY_RIG_EVIDENCE_DIR": str(evidence),
                "FLUTTER_ALREADY_LOCKED": "false",
            }

            result = subprocess.run(
                ["/bin/zsh", str(HERE / "run.sh"), "poison-device"],
                cwd=HERE.parent.parent,
                env=environment,
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn(
                "host build override is not allowed for Gate C: FLUTTER_ALREADY_LOCKED",
                result.stderr,
            )
            self.assertFalse(evidence.exists())

    def test_inherited_file_descriptors_are_rejected_before_evidence_side_effects(self):
        with tempfile.TemporaryDirectory() as temporary:
            inherited = Path(temporary) / "inherited"
            inherited.write_text("must remain unchanged", encoding="utf-8")
            evidence = Path(temporary) / "must-not-exist"
            descriptor = os.open(inherited, os.O_RDWR)
            try:
                result = subprocess.run(
                    ["/bin/zsh", str(HERE / "run.sh"), "fd-device"],
                    cwd=HERE.parent.parent,
                    env={
                        "HOME": os.environ.get("HOME", "/tmp"),
                        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                        "TELEMETRY_RIG_EVIDENCE_DIR": str(evidence),
                    },
                    pass_fds=(descriptor,),
                    capture_output=True,
                    text=True,
                    timeout=5,
                    check=False,
                )
            finally:
                os.close(descriptor)

            self.assertEqual(result.returncode, 1)
            self.assertIn("inherited file descriptor is not allowed", result.stderr)
            self.assertEqual(
                inherited.read_text(encoding="utf-8"), "must remain unchanged"
            )
            self.assertFalse(evidence.exists())

    def test_uses_fresh_gradle_home_and_binds_daemon_to_sealed_jdk(self):
        preparation = RUN_SH.index('"$PYTHON" -I -S -B "$HERE/prepare_gradle_home.py"')
        kotlin_strategy = RUN_SH.index(
            "kotlin.compiler.execution.strategy=in-process",
            preparation,
        )
        gradle_version = RUN_SH.index("./gradlew --no-daemon --version", preparation)
        gradle_version_scope = RUN_SH.index(
            "run_scoped_sandbox_command gradle-version",
            preparation,
        )
        source_manifest = RUN_SH.index(
            'write_tested_tree_manifest "$EVIDENCE/tested-files.pre.sha256"'
        )
        self.assertLess(preparation, gradle_version)
        self.assertLess(preparation, kotlin_strategy)
        self.assertLess(kotlin_strategy, gradle_version)
        self.assertLess(gradle_version_scope, gradle_version)
        self.assertLess(gradle_version, source_manifest)
        self.assertLess(gradle_version, source_manifest)
        self.assertIn("mktemp -d /tmp/telltale-gradle-home.", RUN_SH)
        self.assertIn('--destination "$GRADLE_USER_HOME"', RUN_SH)
        self.assertIn("export GRADLE_USER_HOME", RUN_SH)
        self.assertIn("Gradle Daemon JVM mismatch", RUN_SH)
        self.assertIn("actual != expected", RUN_SH)
        self.assertIn("kotlin.daemon.useFallbackStrategy=false", RUN_SH)
        self.assertIn(
            "kotlin.project.persistent.dir=",
            RUN_SH,
        )
        self.assertIn(
            'KOTLIN_PROJECT_PERSISTENT_DIR="$ANDROID_SDK_SANDBOX_RUN_TEMP/'
            'kotlin-project-persistent"',
            RUN_SH,
        )
        self.assertIn(
            'KOTLIN_DAEMON_RUN_FILES_DIR="$ANDROID_SDK_SANDBOX_RUN_TEMP/kotlin-daemon"',
            RUN_SH,
        )
        self.assertIn("ISOLATED_GRADLE_PROPERTIES_SHA256", RUN_SH)
        self.assertIn("isolated Gradle properties changed", RUN_SH)
        self.assertIn("cleanup_isolated_gradle_home", RUN_SH)

        forbidden_start = RUN_SH.index("for forbidden in \\")
        forbidden_end = RUN_SH.index("\ndone", forbidden_start)
        forbidden = RUN_SH[forbidden_start:forbidden_end]
        self.assertNotIn("gradle.properties", forbidden)

        cleanup_start = RUN_SH.index("cleanup_isolated_gradle_home() {")
        cleanup_end = RUN_SH.index("\n}\n", cleanup_start)
        cleanup = RUN_SH[cleanup_start:cleanup_end]
        quiescence = cleanup.index("quiesce_gradle_process_scope")
        removal = cleanup.index("shutil.rmtree(gradle_root)")
        self.assertLess(quiescence, removal)
        self.assertNotIn("./gradlew --stop", cleanup)

    def test_android_sdk_write_sandbox_is_preflighted_before_repository_loaders(self):
        preparation = RUN_SH.index(
            '"$PYTHON" -I -S -B "$ANDROID_SDK_SANDBOX_PREFLIGHT" prepare'
        )
        prepared_digest = RUN_SH.index(
            "ANDROID_SDK_SANDBOX_PREPARED_SHA256=$(shasum -a 256",
            preparation,
        )
        gradle_version = RUN_SH.index("./gradlew --no-daemon --version")
        first_flutter = RUN_SH.index("sealed_flutter flutter-version --version")
        first_dart = RUN_SH.index("sealed_dart dart-version --version")
        for invocation in (gradle_version, first_flutter, first_dart):
            with self.subTest(invocation=RUN_SH[invocation : invocation + 48]):
                self.assertLess(preparation, invocation)
                self.assertLess(prepared_digest, invocation)

        self.assertIn(
            'ANDROID_SDK_SANDBOX_EXEC="$HERE/android_sdk_sandbox_exec.sh"',
            RUN_SH,
        )
        self.assertIn(
            'ANDROID_SDK_SANDBOX_PREFLIGHT="$HERE/android_sdk_sandbox_preflight.py"',
            RUN_SH,
        )
        self.assertIn(
            'ANDROID_SDK_SANDBOX_PROFILE="$HERE/android_sdk_write_deny.sb"',
            RUN_SH,
        )
        self.assertIn(
            'ANDROID_SDK_SANDBOX_PROBE="$HERE/android_sdk_sandbox_probe.py"',
            RUN_SH,
        )
        self.assertIn("android-sdk-sandbox.prepare.json", RUN_SH)
        self.assertIn("android-sdk-sandbox.post.json", RUN_SH)

    def test_preflight_binds_exact_session_authority_components(self):
        prepared_start = RUN_SH.index(
            '> "$EVIDENCE/android-sdk-sandbox.prepare-validated.txt"'
        )
        prepared_end = RUN_SH.index(
            "ANDROID_SDK_SANDBOX_PROFILE_SHA256=", prepared_start
        )
        prepared = RUN_SH[prepared_start:prepared_end]
        self.assertIn("'probe', 'sessionProof'", prepared)
        self.assertIn("'processScope': process_scope", prepared)
        self.assertIn("'scopedCommand': scoped_command", prepared)
        self.assertIn("set(value) != {", prepared)
        self.assertIn("set(session_proof) != set(expected_session_paths)", prepared)
        self.assertIn("'authority': evidence.with_name(", prepared)
        self.assertIn("'environment': evidence.with_name(", prepared)
        self.assertIn("'scope': evidence.with_name(", prepared)
        self.assertIn("'result': evidence.with_name(", prepared)
        self.assertIn("'processScopeHelperSha256'", RUN_SH)
        self.assertIn("'scopedCommandHelperSha256'", RUN_SH)
        self.assertIn("'processScopeCleanupSha256'", RUN_SH)

    def test_child_environment_evidence_is_verified_at_every_consumer_boundary(self):
        self.assertIn("credentialNamesAssertedAbsent", SCOPED_COMMAND)
        self.assertIn("child_environment_evidence_path(authority_path)", SCOPED_COMMAND)
        self.assertIn(
            "validate_child_environment_evidence(authority_path",
            ANDROID_SANDBOX_PREFLIGHT,
        )
        self.assertIn('"environment": file_fingerprint(', ANDROID_SANDBOX_PREFLIGHT)

        scoped_start = RUN_SH.index("validate_scoped_sandbox_result() {")
        scoped_end = RUN_SH.index("\nrun_scoped_sandbox_command()", scoped_start)
        scoped = RUN_SH[scoped_start:scoped_end]
        self.assertIn('validate_child_environment_evidence "$authority"', scoped)

        guarded_start = RUN_SH.index("run_guarded_command() {")
        guarded_end = RUN_SH.index("\nverify_tested_tree()", guarded_start)
        guarded = RUN_SH[guarded_start:guarded_end]
        self.assertIn('validate_child_environment_evidence "$scope_authority"', guarded)

        for consumer in (
            OUTER_PROCESS_SCOPE_VALIDATOR,
            OUTER_GATE_RESULT_VERIFIER,
        ):
            with self.subTest(consumer=consumer[:40]):
                self.assertIn("credentialNamesAssertedAbsent", consumer)
                self.assertIn("plannedNamesMatchBarrier", consumer)
                self.assertIn("producerPlannedEnvironmentValuesSha256", consumer)
                self.assertIn("valuesObserved", consumer)
                self.assertIn("postBarrierAddedNames", consumer)
                self.assertIn(
                    "cooperative-sealed-wrapper-pre-release-barrier-v1", consumer
                )
                self.assertNotIn("plannedMatchesBarrier", consumer)
                self.assertNotIn("plannedEnvironmentSha256", consumer)
                self.assertIn(".child-environment.json", consumer)
                self.assertIn("incomplete or extra", consumer)

    def test_every_flutter_dart_and_gradle_process_tree_inherits_sdk_write_denial(self):
        flutter_function = RUN_SH[
            RUN_SH.index("sealed_flutter() {") : RUN_SH.index("sealed_dart() {")
        ]
        dart_function = RUN_SH[
            RUN_SH.index("sealed_dart() {") : RUN_SH.index("SEALED_ANDROID_SDK_ROOT=")
        ]
        self.assertIn(
            'run_scoped_sandbox_command "$label" "$APP_ROOT"', flutter_function
        )
        self.assertIn('"$ANDROID_SDK_SANDBOX_EXEC" --', flutter_function)
        self.assertIn('run_scoped_sandbox_command "$label" "$APP_ROOT"', dart_function)
        self.assertIn('"$ANDROID_SDK_SANDBOX_EXEC" --', dart_function)

        gradle_version = RUN_SH[
            RUN_SH.index("run_scoped_sandbox_command gradle-version") : RUN_SH.index(
                "GRADLE_DIST_ROOT=",
            )
        ]
        self.assertIn(
            '"$ANDROID_SDK_SANDBOX_EXEC" -- ./gradlew --no-daemon --version',
            gradle_version,
        )

        build = RUN_SH[
            RUN_SH.index("run_guarded_command android-toolchain-build") : RUN_SH.index(
                "verify_tested_tree",
                RUN_SH.index("run_guarded_command android-toolchain-build"),
            )
        ]
        lint = RUN_SH[
            RUN_SH.index(
                "run_guarded_command android-toolchain-lint-model"
            ) : RUN_SH.index(
                "verify_tested_tree",
                RUN_SH.index("run_guarded_command android-toolchain-lint-model"),
            )
        ]
        self.assertIn('"$ANDROID_SDK_SANDBOX_EXEC" --', build)
        self.assertIn('"$SEALED_SDK_EXEC" "$SEALED_FLUTTER_ROOT" flutter', build)
        self.assertIn('"$ANDROID_SDK_SANDBOX_EXEC" --', lint)
        self.assertIn("./gradlew --no-daemon :app:generateRigDebugLintModel", lint)

        guarded_start = RUN_SH.index("run_guarded_command() {")
        guarded_end = RUN_SH.index("\nverify_tested_tree()", guarded_start)
        guarded = RUN_SH[guarded_start:guarded_end]
        launch = guarded.index('"$PYTHON" -I -S -B "$HERE/guarded_command.py"')
        checks = [
            match.start()
            for match in re.finditer(
                r"^  assert_android_sdk_sandbox_binding$",
                guarded,
                re.MULTILINE,
            )
        ]
        self.assertEqual(len(checks), 2)
        self.assertLess(checks[0], launch)
        self.assertGreater(checks[1], launch)

        lines = RUN_SH.splitlines()
        raw_loader = re.compile(
            r'^\s*(?:\./gradlew\s|"\$SEALED_SDK_EXEC"\s+'
            r'"\$SEALED_FLUTTER_ROOT"\s+(?:flutter|dart)\s)'
        )
        for index, line in enumerate(lines):
            if raw_loader.match(line) is None:
                continue
            with self.subTest(loader=line.strip()):
                self.assertGreater(index, 0)
                self.assertEqual(
                    lines[index - 1].strip(),
                    '"$ANDROID_SDK_SANDBOX_EXEC" -- \\',
                )

    def test_every_sealed_flutter_invocation_disables_version_checks(self):
        loader = '"$SEALED_SDK_EXEC" "$SEALED_FLUTTER_ROOT" flutter'
        invocation_count = RUN_SH.count(loader)
        logical_run_sh = re.sub(r"\\\n[ \t]*", " ", RUN_SH)
        first_arguments = re.findall(
            rf"{re.escape(loader)}\s+(\S+)",
            logical_run_sh,
        )

        self.assertGreater(invocation_count, 0)
        self.assertEqual(len(first_arguments), invocation_count)
        self.assertEqual(first_arguments, ["--no-version-check"] * invocation_count)

    def test_sdk_write_sandbox_post_attestation_precedes_guard_shutdown(self):
        cuts_complete = RUN_SH.index(
            "GATE_CURRENT_DRIVER=''", RUN_SH.index("for gate_cut in")
        )
        post_attestation = RUN_SH.index(
            '"$PYTHON" -I -S -B "$ANDROID_SDK_SANDBOX_PREFLIGHT" verify',
            cuts_complete,
        )
        guard_shutdown = RUN_SH.index(
            "SOURCE_GUARD_STOP_BEFORE_EPOCH_US=", post_attestation
        )
        self.assertLess(cuts_complete, post_attestation)
        self.assertLess(post_attestation, guard_shutdown)
        self.assertIn(
            '--prepared-evidence "$ANDROID_SDK_SANDBOX_PREPARED_EVIDENCE"', RUN_SH
        )
        self.assertIn(
            '--expected-prepared-sha256 "$ANDROID_SDK_SANDBOX_PREPARED_SHA256"',
            RUN_SH,
        )
        self.assertIn('--output "$ANDROID_SDK_SANDBOX_POST_EVIDENCE"', RUN_SH)

        binding_start = RUN_SH.index("assert_android_sdk_sandbox_binding() {")
        binding_end = RUN_SH.index(
            "\n}\nassert_android_sdk_sandbox_binding", binding_start
        )
        binding = RUN_SH[binding_start:binding_end]
        self.assertIn("Android SDK sandbox prepared evidence changed", binding)

    def test_sdk_write_sandbox_identity_and_attestations_are_sealed(self):
        identity = RUN_SH[
            RUN_SH.index("identity.txt") - 4200 : RUN_SH.index("identity.txt")
        ]
        for field in (
            "android_sdk_sandbox_profile_sha256=",
            "android_sdk_sandbox_wrapper_sha256=",
            "android_sdk_sandbox_probe_sha256=",
            "android_sdk_sandbox_preflight_sha256=",
            "android_sdk_sandbox_exec_sha256=",
            "android_sdk_sandbox_prepare_evidence=",
            "android_sdk_sandbox_post_evidence=",
        ):
            with self.subTest(field=field):
                self.assertIn(field, identity)

        result_start = RUN_SH.index('"$EVIDENCE/runner-result.json"')
        result_contract = RUN_SH[result_start:]
        for field in (
            "androidSdkSandboxPrepareSha256",
            "androidSdkSandboxPostSha256",
            "androidSdkSandboxProfileSha256",
            "androidSdkSandboxWrapperSha256",
            "androidSdkSandboxProbeSha256",
            "androidSdkSandboxPreflightSha256",
            "androidSdkSandboxExecSha256",
        ):
            with self.subTest(field=field):
                self.assertIn(field, result_contract)
        self.assertIn("android-sdk-sandbox.prepare.json", RUN_SH[:result_start])
        self.assertIn("android-sdk-sandbox.post.json", RUN_SH[:result_start])

    def test_gradle_distribution_root_strips_archive_classifier_fail_closed(self):
        marker = (
            'GRADLE_DIST_ROOT=$("$PYTHON" -I -S -B - \\\n'
            '  "$EVIDENCE/gradle-home-preparation.json" '
            "\"$GRADLE_USER_HOME\" <<'PY'\n"
        )
        start = RUN_SH.index(marker) + len(marker)
        body = RUN_SH[start : RUN_SH.index("\nPY\n)", start)]
        for classifier in ("all", "bin"):
            with (
                self.subTest(classifier=classifier),
                tempfile.TemporaryDirectory() as temporary,
            ):
                base = Path(temporary).resolve()
                home = base / "home"
                distribution = f"gradle-9.3.1-{classifier}"
                key_root = home / "wrapper" / "dists" / distribution / "safe1"
                extracted = key_root / "gradle-9.3.1"
                extracted.mkdir(parents=True)
                evidence = base / "gradle-home-preparation.json"
                archive = key_root / f"{distribution}.zip"
                evidence.write_text(
                    json.dumps({"destinationZip": str(archive)}) + "\n",
                    encoding="utf-8",
                )

                result = subprocess.run(
                    [
                        sys.executable,
                        "-I",
                        "-S",
                        "-B",
                        "-c",
                        body,
                        str(evidence),
                        str(home),
                    ],
                    capture_output=True,
                    text=True,
                    timeout=5,
                    check=False,
                )

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), str(extracted.resolve()))

                outside = base / "outside"
                outside.mkdir()
                extracted.rmdir()
                extracted.symlink_to(outside, target_is_directory=True)
                rejected = subprocess.run(
                    [
                        sys.executable,
                        "-I",
                        "-S",
                        "-B",
                        "-c",
                        body,
                        str(evidence),
                        str(home),
                    ],
                    capture_output=True,
                    text=True,
                    timeout=5,
                    check=False,
                )
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn(
                    "prepared Gradle distribution was not extracted safely",
                    rejected.stderr,
                )

    def test_live_guard_watches_and_validates_all_external_toolchain_roots(self):
        guard_launch = RUN_SH.rindex('"$PYTHON" -I -S -B "$HERE/source_tree_guard.py"')
        guard_launched = RUN_SH.index("SOURCE_GUARD_PID=$!", guard_launch)
        ready_validator = RUN_SH.index(
            '"$PYTHON" -I -S -B - "$SOURCE_GUARD_READY"', guard_launched
        )
        ready_validator_body = RUN_SH.index("<<'PY'", ready_validator)
        for root in (
            "$SEALED_ANDROID_SDK_ROOT",
            "$SEALED_JDK_ROOT",
            "$GRADLE_DIST_ROOT",
            "$PYTHON_RUNTIME_ROOT",
        ):
            with self.subTest(root=root):
                self.assertIn(
                    f'--toolchain-root "{root}"',
                    RUN_SH[guard_launch:guard_launched],
                )
                self.assertIn(
                    f'"{root}"',
                    RUN_SH[ready_validator:ready_validator_body],
                )
        self.assertIn(
            "required.issubset(set(watch_paths))",
            RUN_SH[ready_validator_body:],
        )

    def test_python_runtime_is_the_single_exact_authority_after_discovery(self):
        normalization = RUN_SH.index("PYTHON=${PYTHON_RUNTIME_COMMAND:A}")
        remainder = RUN_SH[normalization:]

        self.assertNotIn('"$PYTHON_LAUNCHER" -I -S -B', remainder)
        self.assertIn('PYTHON_SHA256=$(shasum -a 256 "$PYTHON"', remainder)
        self.assertIn(
            'shasum -a 256 "$PYTHON" > "$EVIDENCE/python-executable.pre.sha256"',
            remainder,
        )
        self.assertIn('--python "$PYTHON"', remainder)
        self.assertNotRegex(
            remainder,
            r"(?:launcher|runtime).*(?:either|samefile)|(?:either|samefile).*(?:launcher|runtime)",
        )

    def test_discovers_rig_android_components_under_the_live_guard(self):
        guard_ready = RUN_SH.index(
            "assert_source_guard_live",
            RUN_SH.index("\nSOURCE_GUARD_PID=$!"),
        )
        self.assertIn(
            "android-toolchain-build-supervision.json",
            RUN_SH[guard_ready:],
        )
        rig_build = RUN_SH.index(
            "android-toolchain-build-supervision.json",
            guard_ready,
        )
        self.assertIn(
            "./gradlew --no-daemon :app:generateRigDebugLintModel",
            RUN_SH[rig_build:],
        )
        lint_model = RUN_SH.index(
            "./gradlew --no-daemon :app:generateRigDebugLintModel",
            rig_build,
        )
        self.assertIn(
            '"$HERE/android_toolchain_manifest.py" roots',
            RUN_SH[lint_model:],
        )
        discovery = RUN_SH.index(
            '"$HERE/android_toolchain_manifest.py" roots',
            lint_model,
        )
        self.assertLess(guard_ready, rig_build)
        self.assertLess(rig_build, lint_model)
        self.assertLess(lint_model, discovery)
        self.assertLess(RUN_SH.rindex("verify_tested_tree", 0, rig_build), rig_build)
        self.assertLess(RUN_SH.rindex("verify_tested_tree", 0, lint_model), lint_model)
        self.assertIn("verify_tested_tree", RUN_SH[lint_model:discovery])
        self.assertIn("discoveryModelSha256", ANDROID_TOOLCHAIN_MANIFEST)

    def test_long_build_commands_are_supervised_with_the_live_source_guard(self):
        helper = '"$HERE/guarded_command.py"'
        build = RUN_SH.index("android-toolchain-build.log")
        lint = RUN_SH.index("android-toolchain-lint-model.log", build)
        discovery = RUN_SH.index("android-toolchain.discovery.json", lint)
        helper_function = RUN_SH[
            RUN_SH.index("run_guarded_command()") : RUN_SH.index("verify_tested_tree()")
        ]
        self.assertIn(helper, helper_function)
        self.assertIn('--guard-pid "$SOURCE_GUARD_PID"', helper_function)
        self.assertIn('--guard-ready "$SOURCE_GUARD_READY"', helper_function)
        self.assertIn('--guard-result "$SOURCE_GUARD_RESULT"', helper_function)
        for section in (RUN_SH[build - 600 : lint], RUN_SH[lint - 600 : discovery]):
            with self.subTest(section=section[:80]):
                self.assertIn("run_guarded_command", section)
        self.assertEqual(RUN_SH.count("run_guarded_command android-toolchain-"), 2)
        self.assertNotRegex(
            RUN_SH[build - 200 : discovery],
            r"sealed_flutter build[^\n]*\\\n\s*> ",
        )
        self.assertIn("start_new_session=True", SCOPED_COMMAND)
        self.assertIn("KQ_FILTER_PROC", GUARDED_COMMAND)
        self.assertIn("KQ_NOTE_EXIT", GUARDED_COMMAND)
        self.assertNotIn("os.killpg", GUARDED_COMMAND)
        self.assertIn(
            "scope_result = process_scope.contain_and_write(", GUARDED_COMMAND
        )
        self.assertIn("scope_termination_label(scope_result)", GUARDED_COMMAND)

    def test_guarded_command_stops_the_process_group_when_guard_exits(self):
        self.assertIn('result["guardExitObserved"] = True', GUARDED_COMMAND)
        self.assertNotIn("contain_process_group", GUARDED_COMMAND)
        self.assertIn(
            "scope_result = process_scope.contain_and_write(", GUARDED_COMMAND
        )
        self.assertIn("[args.scope_authority]", GUARDED_COMMAND)
        self.assertIn('result["scopeTermination"] = scope_result', GUARDED_COMMAND)

    def test_guarded_command_allows_success_while_guard_remains_live(self):
        self.assertIn('result["status"] = "completed"', GUARDED_COMMAND)
        self.assertIn('result["commandExitCode"] = command_exit', GUARDED_COMMAND)
        self.assertIn('"guardExitObserved": False', GUARDED_COMMAND)
        self.assertIn('result["termination"] = "natural_exit"', GUARDED_COMMAND)

    def test_guarded_command_contains_a_detached_marked_process_scope(self):
        for option in (
            "--scope-authority",
            "--scope-evidence",
            "--scope-owner-root-pid",
            "--scope-wrapper",
            "--scope-wrapper-sha256",
        ):
            with self.subTest(option=option):
                self.assertIn(
                    f'parser.add_argument("{option}", required=True', GUARDED_COMMAND
                )
        self.assertNotIn("--scope-value", GUARDED_COMMAND)
        self.assertNotIn("--scope-gradle-home", GUARDED_COMMAND)
        self.assertIn("launch_authorized_child(", GUARDED_COMMAND)
        self.assertIn("authority_path=args.scope_authority", GUARDED_COMMAND)

    def test_run_guarded_command_propagates_child_failure_inside_or_list(self):
        function_start = RUN_SH.index("run_guarded_command() {")
        function_end = RUN_SH.index("\nverify_tested_tree()", function_start)
        actual_function = RUN_SH[function_start:function_end]
        self.assertIn("helper_exit=$?", actual_function)
        self.assertIn(
            '(( helper_exit == 0 )) || return "$helper_exit"', actual_function
        )
        self.assertIn('--scope-authority "$scope_authority"', actual_function)
        self.assertIn('--scope-evidence "$scope_evidence"', actual_function)
        self.assertIn('--scope-owner-root-pid "$GATE_OWNER_ROOT_PID"', actual_function)
        self.assertIn('--scope-wrapper "$ANDROID_SDK_SANDBOX_EXEC"', actual_function)
        self.assertIn(
            '--scope-wrapper-sha256 "$ANDROID_SDK_SANDBOX_WRAPPER_SHA256"',
            actual_function,
        )
        for label in ("android-toolchain-build", "android-toolchain-lint-model"):
            call = RUN_SH.index(f"run_guarded_command {label}")
            call_end = RUN_SH.index("\nverify_tested_tree", call)
            self.assertIn("|| die", RUN_SH[call:call_end])

    def test_guarded_command_binding_accepts_completed_zero_exit(self):
        result = self._run_guarded_command_binding_validator(
            status="completed",
            command_exit=0,
            helper_exit=0,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.strip(),
            "guarded_process_scope_binding_verified=true",
        )

    def test_guarded_command_binding_accepts_failed_child_and_propagates_exit(self):
        result = self._run_guarded_command_binding_validator(
            status="command_failed",
            command_exit=23,
            helper_exit=23,
        )

        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(
            result.stdout.strip(),
            "guarded_process_scope_binding_verified=true",
        )

    def test_guarded_command_binding_normalizes_unrepresentable_child_exit(self):
        result = self._run_guarded_command_binding_validator(
            status="command_failed",
            command_exit=126,
            helper_exit=1,
        )

        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(
            result.stdout.strip(),
            "guarded_process_scope_binding_verified=true",
        )

    def test_guarded_command_binding_rejects_status_exit_inconsistency(self):
        result = self._run_guarded_command_binding_validator(
            status="completed",
            command_exit=23,
            helper_exit=23,
        )

        self.assertEqual(result.returncode, 72)
        self.assertIn(
            "guarded command process-scope evidence binding failed",
            result.stderr,
        )

    def test_guarded_command_binding_rejects_helper_exit_mismatch(self):
        result = self._run_guarded_command_binding_validator(
            status="command_failed",
            command_exit=23,
            helper_exit=24,
        )

        self.assertEqual(result.returncode, 72)
        self.assertIn(
            "guarded command process-scope evidence binding failed",
            result.stderr,
        )

    def test_guarded_command_binding_rejects_tampered_authority_hash(self):
        result = self._run_guarded_command_binding_validator(
            status="completed",
            command_exit=0,
            helper_exit=0,
            tamper_authority_sha256=True,
        )

        self.assertEqual(result.returncode, 72)
        self.assertIn(
            "guarded command process-scope evidence binding failed",
            result.stderr,
        )

    def test_supervisor_signal_contains_the_detached_build_process_group(self):
        self.assertIn("class SupervisorSignal", GUARDED_COMMAND)
        self.assertIn(
            "signal.pthread_sigmask(signal.SIG_BLOCK, contained_signals)",
            GUARDED_COMMAND,
        )
        self.assertIn(
            "signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)", GUARDED_COMMAND
        )
        self.assertNotIn("contain_process_group", GUARDED_COMMAND)
        cleanup = RUN_SH.index('cleanup_reap_child "$GUARDED_COMMAND_PID"')
        guard_cleanup = RUN_SH.index('cleanup_reap_child "$SOURCE_GUARD_PID"', cleanup)
        self.assertLess(cleanup, guard_cleanup)
        self.assertIn("GUARDED_COMMAND_PID=$supervisor_pid", RUN_SH)

    def test_launch_signal_is_deferred_until_spawned_session_is_containable(self):
        blocked = GUARDED_COMMAND.index(
            "signal.pthread_sigmask(signal.SIG_BLOCK, contained_signals)"
        )
        launch = GUARDED_COMMAND.index("launch_authorized_child(", blocked)
        authority = GUARDED_COMMAND.index(
            'result["scopeAuthority"] = authority', launch
        )
        restored = GUARDED_COMMAND.index(
            "signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)", authority
        )
        self.assertLess(blocked, launch)
        self.assertLess(launch, authority)
        self.assertLess(authority, restored)
        self.assertIn("start_new_session=True", SCOPED_COMMAND)
        self.assertIn("create_launch_authority(", SCOPED_COMMAND)

    def test_runner_only_term_contains_both_cwd_command_process_trees(self):
        callsite = RUN_SH[
            RUN_SH.index("run_guarded_command android-toolchain-build") : RUN_SH.index(
                '"$PYTHON" -I -S -B "$HERE/android_toolchain_manifest.py" roots'
            )
        ]
        self.assertIn('"$APP_ROOT"', callsite)
        self.assertIn('"$APP_ROOT/android"', callsite)
        self.assertNotIn("\n(\n", callsite)
        self.assertIn(
            'authority_paths=("$PROCESS_SCOPE_AUTHORITY_DIR"/*.process-authority.json(N.))',
            RUN_SH,
        )
        self.assertIn('authority_args+=(--authority "$authority")', RUN_SH)
        self.assertIn('"$PROCESS_SCOPE_HELPER" audit', RUN_SH)
        self.assertIn("remainingOwnedProcesses", RUN_SH)
        self.assertIn("foreignProcesses", RUN_SH)
        self.assertIn("inspectionLimitations", RUN_SH)
        self.assertIn('"authorizedSessions": sorted(', PROCESS_SCOPE)

    def test_final_gradle_quiescence_never_grants_reference_authority(self):
        start = RUN_SH.index("quiesce_gradle_process_scope() {")
        end = RUN_SH.index("\nvalidate_gradle_process_scope_evidence()", start)
        quiesce = RUN_SH[start:end]

        self.assertIn('"$PROCESS_SCOPE_HELPER" audit', quiesce)
        self.assertNotIn('"$PROCESS_SCOPE_HELPER" contain', quiesce)
        self.assertNotIn("--reference-authority", quiesce)
        self.assertNotIn("SCOPE_REFERENCE_ARGS", quiesce)

    def test_final_process_scope_cleanup_is_audit_only_and_never_signals(self):
        start = RUN_SH.index("quiesce_gradle_process_scope() {")
        end = RUN_SH.index("\nvalidate_gradle_process_scope_evidence()", start)
        quiesce = RUN_SH[start:end]
        self.assertIn('"$PROCESS_SCOPE_HELPER" audit', quiesce)
        self.assertNotIn("--freeze-ms", quiesce)
        self.assertIn("TELLTALE_GATE_C_PROCESS_SCOPE_AUDIT", RUN_SH)
        self.assertIn("value.get('mode') != 'audit-only'", RUN_SH)
        self.assertIn('audit = subparsers.add_parser("audit")', PROCESS_SCOPE)

    def test_reference_authority_suffix_is_excluded_from_process_authority_glob(self):
        self.assertIn(
            'authority_paths=("$PROCESS_SCOPE_AUTHORITY_DIR"/'
            "*.process-authority.json(N.))",
            RUN_SH,
        )
        self.assertIn(
            '"$PROCESS_SCOPE_REFERENCE_AUTHORITY_DIR/$label.reference-authority.json"',
            RUN_SH,
        )
        self.assertNotIn(".process-authority.json", ".reference-authority.json")

    def test_all_launch_call_sites_pass_live_exact_reference_authorities(self):
        reference_start = RUN_SH.index("build_scope_reference_args() {")
        reference_end = RUN_SH.index("\nSEALED_DEBUG_KEYSTORE=", reference_start)
        reference_builder = RUN_SH[reference_start:reference_end]
        self.assertIn('"$PROCESS_SCOPE_HELPER" verify-reference', reference_builder)

        preflight_start = RUN_SH.index(
            '"$PYTHON" -I -S -B "$ANDROID_SDK_SANDBOX_PREFLIGHT" prepare'
        )
        preflight_end = RUN_SH.index(
            "PREFLIGHT_PROCESS_SCOPE_AUTHORITY=", preflight_start
        )
        preflight = RUN_SH[preflight_start:preflight_end]
        self.assertIn("build_scope_reference_args --reference-authority", RUN_SH)
        self.assertIn('"${SCOPE_REFERENCE_ARGS[@]}"', preflight)

        scoped_start = RUN_SH.index("run_scoped_sandbox_command() {")
        scoped_end = RUN_SH.index(
            "\nrun_scoped_sandbox_command gradle-version", scoped_start
        )
        scoped = RUN_SH[scoped_start:scoped_end]
        self.assertEqual(
            scoped.count("build_scope_reference_args --reference-authority"),
            2,
        )
        self.assertEqual(scoped.count('"${SCOPE_REFERENCE_ARGS[@]}"'), 2)

        guarded_start = RUN_SH.index("run_guarded_command() {")
        guarded_end = RUN_SH.index("\nverify_tested_tree()", guarded_start)
        guarded = RUN_SH[guarded_start:guarded_end]
        self.assertIn("build_scope_reference_args --scope-reference-authority", guarded)
        self.assertIn('"${SCOPE_REFERENCE_ARGS[@]}"', guarded)

    def test_inline_scope_v3_validator_requires_exact_evidence_fields(self):
        start = RUN_SH.index("validate_gradle_process_scope_evidence() {")
        end = RUN_SH.index("\ncleanup_isolated_gradle_home()", start)
        validator = RUN_SH[start:end]
        required_fields = (
            "'version', 'status', 'marker', 'ownerRoot', 'roots', 'authorities',",
            "'authorizedSessions', 'startedMonotonicNs', 'endedMonotonicNs',",
            "'stoppedProcesses', 'termSentProcesses', 'killSentProcesses',",
            "'remainingOwnedProcesses', 'foreignProcesses', 'inspectionLimitations',",
            "'referenceInspection', 'referenceAuthorities', 'referenceExemptProcesses',",
        )
        for fields in required_fields:
            with self.subTest(fields=fields):
                self.assertIn(fields, validator)
        self.assertIn("set(value) != required", validator)
        self.assertIn("value.get('version') != 3", validator)
        self.assertIn(
            "'identity', 'state', 'executable', 'argv', 'environmentSha256', 'cwd',",
            validator,
        )
        self.assertIn(
            "'root', 'openVnodePaths', 'inspectionErrors', 'vnodeEvidenceMethod',",
            validator,
        )
        self.assertIn("'vnodeEvidenceComplete',", validator)

    def test_reuses_explicit_discovered_components_for_pre_and_post_manifests(self):
        self.assertIn("ANDROID_COMPONENT_ARGS", RUN_SH)
        self.assertGreaterEqual(RUN_SH.count('"${ANDROID_COMPONENT_ARGS[@]}"'), 4)
        self.assertIn("--component-root", RUN_SH)
        self.assertIn("android-toolchain.discovery.json", RUN_SH)
        self.assertIn("android-toolchain.pre.sha256", RUN_SH)
        self.assertIn("android-toolchain.post.sha256", RUN_SH)
        self.assertIn("android-toolchain.roots.json", RUN_SH)
        self.assertIn("android-toolchain.roots.post.json", RUN_SH)
        self.assertIn("discoveryModels", RUN_SH)
        self.assertIn("discoveryModelSha256", RUN_SH)
        self.assertGreaterEqual(RUN_SH.count("components"), 2)
        self.assertGreaterEqual(RUN_SH.count("discoveryModels"), 2)
        self.assertRegex(
            RUN_SH,
            r'cmp "\$EVIDENCE/android-toolchain\.pre\.sha256"\s+"\$EVIDENCE/android-toolchain\.post\.sha256"',
        )
        self.assertRegex(
            RUN_SH,
            r'cmp "\$EVIDENCE/android-toolchain\.roots\.json"\s+"\$EVIDENCE/android-toolchain\.roots\.post\.json"',
        )

    def test_runner_result_seals_android_toolchain_manifest_and_roots(self):
        result_start = RUN_SH.index('"$EVIDENCE/runner-result.json"')
        result_contract = RUN_SH[result_start:]
        self.assertIn("androidToolchainManifestSha256", result_contract)
        self.assertIn("androidToolchainRootsSha256", result_contract)
        self.assertIn("android-toolchain.post.sha256", RUN_SH[:result_start])
        self.assertIn("android-toolchain.roots.post.json", RUN_SH[:result_start])

    def test_generates_fixtures_on_host_without_dart_cli_build_hooks(self):
        self.assertIn(
            "sealed_dart fixture-generator "
            "tool/telemetry_memory_rig/generate_fixtures.dart \\",
            RUN_SH,
        )
        self.assertNotIn(
            "sealed_dart fixture-generator run "
            "tool/telemetry_memory_rig/generate_fixtures.dart",
            RUN_SH,
        )
        fixture_start = RUN_SH.index("# Generate fixtures entirely on the host")
        measure_start = RUN_SH.index(
            "start_scoped_sandbox_command telemetry-memory-measure",
            fixture_start,
        )
        fixture_lane = RUN_SH[fixture_start:measure_start]
        self.assertNotRegex(fixture_lane, r"\bdart\s+run\b")
        self.assertIn("sealed_dart fixture-generator", fixture_lane)
        self.assertNotIn("fixture-generator run", fixture_lane)
        self.assertIn(
            "start_scoped_sandbox_command telemetry-memory-measure "
            '"$APP_ROOT" "$MEASURE_LOG"',
            RUN_SH,
        )
        self.assertIn(
            "GATE_TARGET=integration_test/telemetry_share_crash_rig_test.dart", RUN_SH
        )
        self.assertNotIn("TELEMETRY_MEMORY_PHASE", RUN_SH)

    def test_executed_flutter_and_dart_match_the_sealed_sdk(self):
        self.assertIn("SEALED_FLUTTER_ROOT", RUN_SH)
        self.assertIn('tree_manifest.py" flutter-root', RUN_SH)
        self.assertNotIn("import tree_manifest", RUN_SH)
        self.assertIn("--expected-flutter-root", RUN_SH)
        self.assertIn(
            '--expected-flutter-root "$SEALED_FLUTTER_ROOT"',
            RUN_SH,
        )
        self.assertGreaterEqual(RUN_SH.count("assert_flutter_binding"), 4)
        self.assertIn(
            "FLUTTER override does not match the sealed android/local.properties SDK",
            RUN_SH,
        )
        self.assertIn(
            "DART override does not match the sealed android/local.properties SDK",
            RUN_SH,
        )
        self.assertIn(
            '"$SEALED_SDK_EXEC" "$SEALED_FLUTTER_ROOT" flutter --no-version-check "$@"',
            RUN_SH,
        )
        self.assertIn('"$SEALED_SDK_EXEC" "$SEALED_FLUTTER_ROOT" dart "$@"', RUN_SH)
        self.assertIn("bin/cache/dart-sdk/bin/dart", SEALED_SDK_EXEC)
        self.assertIn("bin/cache/flutter_tools.snapshot", SEALED_SDK_EXEC)
        self.assertIn('--packages="$FLUTTER_PACKAGES"', SEALED_SDK_EXEC)
        self.assertNotIn('bin/flutter" "$@"', SEALED_SDK_EXEC)

    def test_live_guard_never_executes_mutating_sdk_launchers(self):
        guarded = RUN_SH[RUN_SH.index("\nSOURCE_GUARD_PID=$!") :]
        self.assertNotRegex(guarded, r'"\$FLUTTER"\s')
        self.assertNotRegex(guarded, r'"\$DART"\s')
        self.assertGreaterEqual(guarded.count("start_scoped_sandbox_command"), 2)
        self.assertNotIn("${=FLUTTER_TOOL_ARGS", SEALED_SDK_EXEC)
        self.assertIn(
            "sealed_dart fixture-generator",
            guarded,
        )
        self.assertNotIn("sealed_dart fixture-generator run", guarded)

    def test_bootstrap_guard_precedes_first_sdk_execution(self):
        bootstrap_ready = RUN_SH.index("bootstrap_guard_ready_verified=true")
        bootstrap_verify = RUN_SH.index(
            "tested tree changed while establishing the bootstrap guard",
            bootstrap_ready,
        )
        for invocation in (
            '"$SEALED_JDK_ROOT/bin/keytool" -genkeypair',
            '"$HERE/prepare_gradle_home.py"',
            "./gradlew --no-daemon --version",
            "android-toolchain-build-supervision.json",
            "sealed_dart fixture-generator",
        ):
            with self.subTest(invocation=invocation):
                self.assertLess(bootstrap_verify, RUN_SH.index(invocation))
        main_ready = RUN_SH.index("canary_verified=true", bootstrap_verify)
        handoff = RUN_SH.index(
            "bootstrap_unchanged_tree_verified=true",
            main_ready,
        )
        self.assertLess(main_ready, handoff)
        self.assertLess(
            handoff, RUN_SH.index("android-toolchain-build-supervision.json")
        )

    def test_transfers_fixtures_through_host_archive_after_measure_install(self):
        self.assertIn('tar -C "$HOST_FIXTURES" -cf "$FIXTURE_ARCHIVE"', RUN_SH)
        self.assertIn('tar -C app_flutter -xf - < "$FIXTURE_ARCHIVE"', RUN_SH)
        self.assertIn("TELLTALE_MEMORY_FIXTURE_IMPORT_READY", TARGET)

    def test_host_generator_uses_production_codec_and_fixed_byte_contracts(self):
        self.assertIn("TelemetrySessionCodec.encodeHeaderLine", GENERATOR)
        self.assertIn("TelemetrySessionCodec.encodeEventLine", GENERATOR)
        self.assertIn("TelemetrySessionCodec.encodeFooterLine", GENERATOR)
        self.assertIn("return 100 * _mib", GENERATOR)
        self.assertIn("handle.writeFromSync(zeroChunk)", GENERATOR)
        generator_reserve = re.search(r"const _footerReserveBytes = (\d+);", GENERATOR)
        production_reserve = re.search(
            r"static const footerReserveBytes = (\d+);", STORE
        )
        self.assertIsNotNone(generator_reserve)
        self.assertIsNotNone(production_reserve)
        self.assertEqual(generator_reserve.group(1), production_reserve.group(1))

    def test_missing_fixture_import_cannot_enter_baseline(self):
        import_expectation = TARGET.index("host fixture import did not complete")
        baseline = TARGET.index("await _stage('baseline'")
        self.assertLess(import_expectation, baseline)

    def test_assigns_pss_from_latest_timestamped_live_marker(self):
        self.assertIn("tail -n 1", RUN_SH)
        self.assertIn("marker_epoch_us", RUN_SH)
        self.assertIn('stage=$([[ "$marker_edge" == BEGIN ]]', RUN_SH)

    def test_pss_samples_are_pid_bound_timestamped_and_unambiguous(self):
        self.assertIn(
            "sample_start_epoch_us\\tsample_end_epoch_us\\tstage\\t"
            "total_pss_kb\\tmarker_epoch_us\\tpid",
            RUN_SH,
        )
        self.assertIn("MEASURE_PID", RUN_SH)
        self.assertIn("measured package PID changed", RUN_SH)
        self.assertIn('marker_after_sample" == "$sample_marker', RUN_SH)
        self.assertIn("gate_c_adb_total_pss_sample", RUN_SH)
        self.assertIn("time.monotonic_ns()", RUN_SH)
        self.assertIn("sampling_deadline_ns", RUN_SH)

    def test_memory_sampling_uses_monotonic_exact_400ms_cadence(self):
        self.assertIn("sampling_deadline_ns=$(( sampling_started_ns + 400000000 ))", RUN_SH)
        self.assertIn('kill -0 "$test_pid" 2>/dev/null || break', RUN_SH)
        script = f"""
PYTHON={shlex.quote(sys.executable)}
{self._sampling_cadence_helpers()}
gate_c_monotonic_ns() {{ print -r -- 1100000000; }}
sleep() {{ print -r -- "$1"; }}
gate_c_sleep_to_cadence 1400000000
"""
        result = subprocess.run(
            ["/bin/zsh", "-f", "-c", script],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(float(result.stdout.strip()), 0.0)
        self.assertAlmostEqual(float(result.stdout.strip()), 0.3, places=6)
        self.assertNotIn("sleep 0.2", RUN_SH)
        for contract in (
            "MIN_SAMPLES_PER_STAGE = 3",
            "MAX_SAMPLE_GAP_US = 1_000_000",
            "MAX_SAMPLE_DURATION_US = 1_000_000",
            "TOTAL PSS samples do not have a stable PID",
            "sample timestamp is outside its marker window",
            "required stages overlap or are out of epoch order",
        ):
            self.assertIn(contract, ANALYZER)

    def test_memory_sampling_uses_one_framed_capture_transaction(self):
        self.assertIn("gate_c_adb_total_pss_sample", RUN_SH)
        start = RUN_SH.index("sample_marker=$last_marker")
        end = RUN_SH.index("if (( residue_captured == 0 ))", start)
        sample_block = RUN_SH[start:end]
        self.assertIn("gate_c_adb_total_pss_sample", sample_block)
        self.assertIn('elif ! kill -0 "$test_pid" 2>/dev/null; then', sample_block)
        self.assertIn("driver completed in the sampling race", sample_block)
        self.assertNotIn("gate_c_adb_optional_pidof", sample_block)
        self.assertNotIn("shell 'date +%s%N'", sample_block)
        self.assertNotIn("shell dumpsys meminfo", sample_block)
        self.assertNotIn("pss=$(", sample_block)
        self.assertIn('marker_after_sample" == "$sample_marker', sample_block)
        self.assertIn("sample_start_epoch_us", sample_block)
        self.assertIn("sample_end_epoch_us", sample_block)

    def test_maximum_pss_timing_contract_remains_exactly_one_second(self):
        self.assertRegex(ANALYZER, r"MAX_SAMPLE_GAP_US = 1_000_000")
        self.assertRegex(ANALYZER, r"MAX_SAMPLE_DURATION_US = 1_000_000")

    def test_stage_window_covers_required_samples_at_maximum_allowed_gap(self):
        stage_window = re.search(
            r"const Duration\(milliseconds: (\d+)\) - stopwatch\.elapsed",
            TARGET,
        )
        minimum_samples = re.search(
            r"MIN_SAMPLES_PER_STAGE = (\d+)",
            ANALYZER,
        )
        maximum_gap_us = re.search(
            r"MAX_SAMPLE_GAP_US = ([\d_]+)",
            ANALYZER,
        )
        self.assertIsNotNone(stage_window)
        self.assertIsNotNone(minimum_samples)
        self.assertIsNotNone(maximum_gap_us)
        stage_window_us = int(stage_window.group(1)) * 1000
        required_window_us = int(minimum_samples.group(1)) * int(
            maximum_gap_us.group(1).replace("_", "")
        )
        self.assertGreaterEqual(stage_window_us, required_window_us)

    def test_stage_window_timing_starts_after_the_begin_marker(self):
        stage_function = TARGET.index("Future<T> _stage<T>")
        begin_marker = TARGET.index("edge=BEGIN", stage_function)
        stopwatch_start = TARGET.index("Stopwatch()..start()", stage_function)
        remaining_window = TARGET.index("- stopwatch.elapsed", stopwatch_start)
        end_marker = TARGET.index("edge=END", remaining_window)
        self.assertLess(begin_marker, stopwatch_start)
        self.assertLess(stopwatch_start, remaining_window)
        self.assertLess(remaining_window, end_marker)

    def test_collects_run_as_residue_before_waiting_for_measurement_exit(self):
        capture = RUN_SH.index("run-as $PACKAGE find cache files")
        reap = RUN_SH.index('bounded_reap "$test_pid"')
        self.assertLess(capture, reap)
        self.assertIn("residue_status=1", RUN_SH)

    def test_telemetry_shares_use_production_session_actions_export(self):
        self.assertIn("actions.export(_sessionId, TelemetryExportFormat.csv)", TARGET)
        self.assertIn("actions.export(_sessionId, TelemetryExportFormat.json)", TARGET)
        self.assertIn("TELLTALE_MEMORY_PRODUCTION_EXPORT", TARGET)

    def test_other_three_shares_use_production_streaming_sources(self):
        self.assertIn("controller.shareRawTranscript", TARGET)
        self.assertIn("controller.shareRecoveredTranscript", TARGET)
        self.assertIn("controller.sharePidCsv", TARGET)
        self.assertNotIn("TELLTALE_MEMORY_SYNTHETIC_SHARE", TARGET)

    def test_gate_c_is_exactly_gated_and_uses_strict_command_schema(self):
        self.assertIn("TELLTALE_GATE_C_INSTRUMENTATION", CRASH_TARGET)
        self.assertIn("isRigShareCaptureEligible", CRASH_TARGET)
        self.assertIn("androidRigApplicationId", CRASH_TARGET)
        self.assertIn("value.keys.length != 4", CRASH_TARGET)
        self.assertIn("invalid Gate C phase/cut pair", CRASH_TARGET)

    def test_gate_c_runner_force_stops_pulls_then_reinstalls_and_restores(self):
        pre_kill = RUN_SH.index("# Last pre-kill proof")
        force_stop = RUN_SH.index('shell am force-stop "$PACKAGE"', pre_kill)
        pull = RUN_SH.index("tar -C cache -cf - telltale-app-shares", force_stop)
        uninstall = RUN_SH.index('uninstall "$PACKAGE"', force_stop)
        restore = RUN_SH.index("tar -C cache -xf -", uninstall)
        self.assertLess(force_stop, pull)
        self.assertLess(pull, uninstall)
        self.assertLess(uninstall, restore)
        self.assertIn("gate_validate_archive", RUN_SH)
        self.assertIn("TELLTALE_GATE_C_RECOVERY_VERIFIED", RUN_SH)

    def test_gate_c_command_preserves_remote_sh_c_as_one_adb_shell_argument(self):
        function_start = RUN_SH.index("gate_write_command()")
        function_end = RUN_SH.index("\ngate_launch()", function_start)
        function = RUN_SH[function_start:function_end]
        self.assertIn(
            '"$ADB" -s "$SERIAL" shell \\\n'
            '    "run-as $PACKAGE sh -c \'mkdir -p '
            "cache/telltale-memory-rig-control && cat > "
            "cache/telltale-memory-rig-control/command.json.tmp && mv "
            "cache/telltale-memory-rig-control/command.json.tmp "
            "cache/telltale-memory-rig-control/command.json\'\"",
            function,
        )
        self.assertNotIn('shell run-as "$PACKAGE"', function)

    def test_all_gate_remote_sh_c_commands_are_one_adb_shell_argument(self):
        self.assertNotRegex(
            RUN_SH,
            r'shell run-as "\$PACKAGE" \\\n\s+sh -c ',
        )
        self.assertEqual(RUN_SH.count('"run-as $PACKAGE sh -c '), 5)

    def test_gate_c_command_delivery_failure_explicitly_enters_cleanup(self):
        function_start = RUN_SH.index("gate_launch()")
        function_end = RUN_SH.index("\ngate_validate_archive()", function_start)
        function = RUN_SH[function_start:function_end]
        self.assertIn(
            'gate_write_command "$token" "$phase" "$cut" \\\n'
            '    || die "Gate C command delivery failed: $phase/$cut"',
            function,
        )

    def test_gate_c_command_delivery_failure_runs_exit_trap_under_zsh(self):
        function_start = RUN_SH.index("gate_launch()")
        function_end = RUN_SH.index("\ngate_validate_archive()", function_start)
        function = RUN_SH[function_start:function_end]
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / "cleanup-marker.txt"
            script = f"""
set -euo pipefail
die() {{ print -u2 -- "telemetry memory rig: $*"; exit 1; }}
on_exit() {{ print -r -- cleanup > {shlex.quote(str(marker))}; }}
trap on_exit EXIT
verify_tested_tree() {{ :; }}
start_scoped_sandbox_command() {{ SCOPED_COMMAND_PID=17; }}
gate_wait_log() {{ :; }}
gate_write_command() {{ return 23; }}
APP_ROOT=/app
ANDROID_SDK_SANDBOX_EXEC=/sandbox
SEALED_SDK_EXEC=/sealed
SEALED_FLUTTER_ROOT=/flutter
GATE_TARGET=target.dart
SERIAL=device
GATE_DEFINE=()
{function}
gate_launch seed allocated token log
"""
            result = subprocess.run(
                ["/bin/zsh", "-f", "-c", script],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(marker.read_text(encoding="utf-8"), "cleanup\n")
            self.assertIn(
                "Gate C command delivery failed: seed/allocated",
                result.stderr,
            )

    def test_gate_c_scoped_launch_failure_runs_exit_trap_under_zsh(self):
        function_start = RUN_SH.index("gate_launch()")
        function_end = RUN_SH.index("\ngate_validate_archive()", function_start)
        function = RUN_SH[function_start:function_end]
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / "cleanup-marker.txt"
            script = f"""
set -euo pipefail
die() {{ print -u2 -- "telemetry memory rig: $*"; exit 1; }}
on_exit() {{ print -r -- cleanup > {shlex.quote(str(marker))}; }}
trap on_exit EXIT
verify_tested_tree() {{ :; }}
start_scoped_sandbox_command() {{ return 72; }}
gate_wait_log() {{ :; }}
gate_write_command() {{ :; }}
APP_ROOT=/app
ANDROID_SDK_SANDBOX_EXEC=/sandbox
SEALED_SDK_EXEC=/sealed
SEALED_FLUTTER_ROOT=/flutter
GATE_TARGET=target.dart
SERIAL=device
GATE_DEFINE=()
{function}
gate_launch seed allocated token log
"""
            result = subprocess.run(
                ["/bin/zsh", "-f", "-c", script],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(marker.read_text(encoding="utf-8"), "cleanup\n")
            self.assertIn("Gate C scoped driver launch failed", result.stderr)

    def test_gate_c_ack_pull_failure_runs_exit_trap_under_zsh(self):
        function_start = RUN_SH.index("gate_run_cut()")
        function_end = RUN_SH.index("\n\nGATE_CUTS=", function_start)
        function = RUN_SH[function_start:function_end]
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / "cleanup-marker.txt"
            gate_root = Path(temporary) / "cuts"
            script = f"""
set -euo pipefail
die() {{ print -u2 -- "telemetry memory rig: $*"; exit 1; }}
on_exit() {{ print -r -- cleanup > {shlex.quote(str(marker))}; }}
trap on_exit EXIT
ensure_rig_absent() {{ :; }}
gate_launch() {{ GATE_TEST_PID=17; GATE_SCOPED_LABEL=seed; }}
gate_wait_log() {{ :; }}
GATE_ROOT={shlex.quote(str(gate_root))}
ADB=/usr/bin/false
SERIAL=device
PACKAGE=com.example.rig
PYTHON=/usr/bin/false
{function}
gate_run_cut allocated
"""
            result = subprocess.run(
                ["/bin/zsh", "-f", "-c", script],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(marker.read_text(encoding="utf-8"), "cleanup\n")
            self.assertIn("Gate C ack pull failed: allocated", result.stderr)

    def test_gate_c_fallible_checkpoints_use_local_errreturn_boundary(self):
        launch_start = RUN_SH.index("gate_launch()")
        launch_end = RUN_SH.index("\ngate_validate_archive()", launch_start)
        launch = RUN_SH[launch_start:launch_end]
        function_start = RUN_SH.index("gate_run_cut()")
        function_end = RUN_SH.index("\n\nGATE_CUTS=", function_start)
        function = RUN_SH[function_start:function_end]
        reap_start = RUN_SH.index("gate_reap_seed_driver()")
        reap_end = RUN_SH.index("\ngate_run_cut()", reap_start)
        reap = RUN_SH[reap_start:reap_end]
        cuts_start = RUN_SH.index("GATE_CUTS=")
        cuts_end = RUN_SH.index("\nGATE_CURRENT_DRIVER=", cuts_start)
        cuts = RUN_SH[cuts_start:cuts_end]
        self.assertIn("setopt localoptions errreturn", launch)
        self.assertIn("setopt localoptions errreturn", function)
        self.assertNotRegex(function, r"(?m)^\s*local\s+\w+=\$\(")
        self.assertIn("setopt localoptions no_errreturn", reap)
        self.assertEqual(function.count("setopt no_errreturn"), 2)
        self.assertEqual(function.count("setopt errreturn"), 2)
        self.assertIn(
            'token=$(openssl rand -hex 16) \\\n'
            '    || die "Gate C token generation failed: $cut"',
            function,
        )
        self.assertIn(
            '[[ ${#token} == 32 && "$token" != *[^0-9a-f]* ]]',
            function,
        )
        self.assertIn(
            'gate_run_cut "$gate_cut" \\\n'
            '    || die "Gate C cut failed: $gate_cut"',
            cuts,
        )

    def test_gate_c_errreturn_routes_naked_checkpoint_to_cleanup(self):
        function_start = RUN_SH.index("gate_run_cut()")
        function_end = RUN_SH.index("\n\nGATE_CUTS=", function_start)
        function = RUN_SH[function_start:function_end]
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / "cleanup-marker.txt"
            gate_root = Path(temporary) / "not-a-directory"
            gate_root.write_text("sentinel", encoding="utf-8")
            script = f"""
set -euo pipefail
die() {{ print -u2 -- "telemetry memory rig: $*"; exit 1; }}
on_exit() {{ print -r -- cleanup > {shlex.quote(str(marker))}; }}
trap on_exit EXIT
GATE_ROOT={shlex.quote(str(gate_root))}
{function}
gate_run_cut allocated || die "Gate C cut failed: allocated"
"""
            result = subprocess.run(
                ["/bin/zsh", "-f", "-c", script],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(marker.read_text(encoding="utf-8"), "cleanup\n")
            self.assertIn("Gate C cut failed: allocated", result.stderr)

    def test_gate_seed_reap_captures_expected_nonzero_with_errreturn(self):
        function_start = RUN_SH.index("gate_reap_seed_driver()")
        function_end = RUN_SH.index("\ngate_run_cut()", function_start)
        function = RUN_SH[function_start:function_end]
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary) / "seed-driver-exit.txt"
            arguments = Path(temporary) / "bounded-reap-arguments.txt"
            validation = Path(temporary) / "scoped-validation-arguments.txt"
            evidence.write_text(
                "forced_host_termination=none\noutcome=natural_exit\n",
                encoding="utf-8",
            )
            script = f"""
set -euo pipefail
die() {{ print -u2 -- "telemetry memory rig: $*"; exit 1; }}
bounded_reap() {{ print -r -- "$3 $4 $5 $6" > {shlex.quote(str(arguments))}; return 79; }}
validate_scoped_sandbox_result() {{ print -r -- "$1 $2" > {shlex.quote(str(validation))}; }}
GATE_CURRENT_DRIVER=17
CURRENT_DRIVER=17
GRADLE_FORENSIC_RETENTION_LATCH=0
{function}
setopt localoptions errreturn
gate_reap_seed_driver 17 {shlex.quote(str(evidence))} seed
print -r -- "captured=true"
"""
            result = subprocess.run(
                ["/bin/zsh", "-f", "-c", script],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "captured=true\n")
            self.assertEqual(
                arguments.read_text(encoding="utf-8"),
                "gate-seed-driver 30000 2000 2000\n",
            )
            self.assertEqual(
                validation.read_text(encoding="utf-8"),
                "seed command_failed\n",
            )

    def test_gate_c_covers_all_cuts_and_keeps_plugin_evidence_separate(self):
        for cut in (
            "allocated",
            "sourceVerified",
            "handedOffBeforePlatform",
            "platformInvoked",
            "pendingResult",
            "neverResult",
            "realPluginMirror",
        ):
            self.assertIn(cut, RUN_SH)
            self.assertIn(cut, CRASH_TARGET)
        self.assertIn("plugin-observed", RUN_SH)
        self.assertIn("cache/share_plus", RUN_SH)
        forbidden = re.compile(r"(?:rm|delete|restore).*cache/share_plus", re.I)
        self.assertIsNone(forbidden.search(RUN_SH))

    def test_three_post_invocation_cuts_have_distinct_validated_semantics(self):
        for semantic in (
            "invokedBeforeAwait",
            "completablePending",
            "nonCompletablePending",
        ):
            self.assertIn(semantic, CRASH_TARGET)
            self.assertIn(semantic, RUN_SH)
            self.assertIn(semantic, GATE_VALIDATOR)
        self.assertIn("AppShareCrashCut.platformInvoked", CRASH_TARGET)
        self.assertIn(
            "minimumObservationMs = command.cut == 'pendingResult' ? 2000 : 5000",
            CRASH_TARGET,
        )
        for field in ("platformSemantic", "pendingObservationMs"):
            self.assertIn(field, CRASH_TARGET)
            self.assertIn(field, RUN_SH)
            self.assertIn(field, GATE_VALIDATOR)

    def test_source_verified_ack_uses_verified_snapshot_not_null_ledger_fields(self):
        self.assertIn("verifiedBytes: snapshot.bytes", CRASH_TARGET)
        self.assertIn("verifiedFingerprint: snapshot.fingerprint", CRASH_TARGET)

    def test_real_plugin_mirror_reloads_ledger_and_counts_real_bridge(self):
        self.assertIn("ShareLeaseLedger(paths.shares).read(command.id)", CRASH_TARGET)
        self.assertIn("_CountingPlatform(const AppSharePlatformBridge())", CRASH_TARGET)
        self.assertIn("expect(platform.calls, 1)", CRASH_TARGET)
        self.assertIn("ledger-at-observation.json", RUN_SH)
        self.assertIn("rig PID changed before plugin mirror observation", RUN_SH)
        self.assertIn("plugin observation was not pending handoff", RUN_SH)

    def test_archive_and_recovery_validate_exact_group_and_cleanup_margin(self):
        self.assertIn(
            '"$PYTHON" -I -S -B "$HERE/gate_c_validate.py" validate',
            RUN_SH,
        )
        self.assertIn(
            "archive must contain root plus exactly two files", GATE_VALIDATOR
        )
        self.assertIn("ledger/ack mismatch", GATE_VALIDATOR)
        self.assertIn("source parity mismatch", GATE_VALIDATOR)
        self.assertIn("cleanup eligibility margin too small", RUN_SH)
        self.assertIn('cmp "$dir/pre-kill-ledger.json"', RUN_SH)
        self.assertIn("post-recovery-fnv.txt", RUN_SH)

    def test_every_cut_proves_gate_ownership_in_ack_and_host_validation(self):
        self.assertIn("final ownership = await _proveOwnership", CRASH_TARGET)
        self.assertIn("gate.snapshot.isIdle", CRASH_TARGET)
        self.assertIn("ShareError.shareBusy", CRASH_TARGET)
        self.assertIn("ArtifactOperation.delete", CRASH_TARGET)
        for field in ("gateIdle", "secondShareError", "crossFeatureDenied"):
            self.assertIn(field, CRASH_TARGET)
            self.assertIn(field, RUN_SH)
            self.assertIn(field, GATE_VALIDATOR)

    def test_force_stop_identity_and_driver_exit_are_fail_closed(self):
        identity_check = RUN_SH.index("pre_force_cmdline")
        force_stop = RUN_SH.index('shell am force-stop "$PACKAGE"', identity_check)
        self.assertLess(identity_check, force_stop)
        self.assertIn("before_epoch_ns=", RUN_SH)
        self.assertIn("after_epoch_ns=", RUN_SH)
        self.assertIn("exit_code=", BOUNDED_REAP)
        self.assertIn("force-stop timestamps were not monotonic", RUN_SH)
        self.assertIn('bounded_reap "$pid" "$evidence" gate-seed-driver', RUN_SH)
        self.assertIn(
            'bounded_reap "$pid" "$evidence" gate-seed-driver 30000 2000 2000',
            RUN_SH,
        )
        self.assertGreater(30000, 5000 + 5000 + 5000 + 2000)
        self.assertIn("forced_host_termination", RUN_SH)
        self.assertIn("Gate C killed seed driver exited success", RUN_SH)
        self.assertIn("Gate C host driver exited before force-stop", RUN_SH)
        self.assertIn(
            "Gate C seed driver did not exit after force-stop without host termination",
            RUN_SH,
        )

    def test_restore_is_token_bound_revalidated_and_verified_before_root_init(self):
        revalidate = RUN_SH.index("gate_revalidate_restore_bundle")
        restore = RUN_SH.index("tar -C cache -xf -", revalidate)
        self.assertLess(revalidate, restore)
        self.assertIn("archive or token-bound manifest changed", GATE_VALIDATOR)
        target_verify = CRASH_TARGET.index("await _verifyRestoredGroup")
        target_init = CRASH_TARGET.index(
            "await startRigAppPreservingState", target_verify
        )
        self.assertLess(target_verify, target_init)

    def test_post_kill_evidence_has_per_file_and_canonical_inventory_hashes(self):
        self.assertIn("pre-kill-manifest.json", RUN_SH)
        self.assertIn("pre/post-kill file parity mismatch", RUN_SH)
        self.assertIn("post-kill-files.sha256", RUN_SH)
        self.assertIn("post-recovery-inventory.sha256", RUN_SH)
        self.assertIn(
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            RUN_SH,
        )
        self.assertIn("postRecoveryInventorySha256", RUN_SH)

    def test_gate_failure_cleanup_is_scoped_to_driver_and_rig_package(self):
        self.assertIn("GATE_CURRENT_DRIVER", RUN_SH)
        self.assertIn("local current_driver_pid=$CURRENT_DRIVER", RUN_SH)
        self.assertIn("gate_driver_pid=$GATE_CURRENT_DRIVER", RUN_SH)
        self.assertIn('cleanup_reap_child "$gate_driver_pid"', RUN_SH)
        self.assertIn('cleanup_reap_child "$current_driver_pid"', RUN_SH)
        self.assertIn('am force-stop "$PACKAGE"', RUN_SH)
        self.assertNotIn("pkill", RUN_SH)

    def test_preconditions_and_cleanup_use_fail_closed_adb_state_guard(self):
        self.assertIn('source "$HERE/adb_state_guard.sh"', RUN_SH)
        self.assertIn('gate_c_adb_snapshot "$output"', RUN_SH)
        self.assertIn('gate_c_adb_remove_rig_package "$1"', RUN_SH)
        self.assertIn(
            '"$EVIDENCE/final-rig-removal${suffix}.txt"',
            RUN_SH,
        )
        self.assertIn('[[ "$rig_path" == absent && "$rig_pid" == absent ]]', RUN_SH)
        self.assertIn("gate_c_adb_require_online", ADB_STATE_GUARD)
        self.assertIn("rig_path_after=absent", ADB_STATE_GUARD)
        self.assertIn("rig_pid_after=absent", ADB_STATE_GUARD)
        self.assertIn("__TELLTALE_PIDOF_RC__", ADB_STATE_GUARD)
        self.assertIn("gate_c_adb_required_single_pid", RUN_SH)
        recovery_inventory = RUN_SH[
            RUN_SH.index('> "$dir/post-recovery-app-staging.txt"') : RUN_SH.index(
                'LC_ALL=C sort "$dir/post-recovery-app-staging.txt"'
            )
        ]
        self.assertNotIn("|| true", recovery_inventory)
        self.assertIn("recovery inventory probe failed", recovery_inventory)

    def test_failure_cleanup_contains_both_source_guards(self):
        self.assertIn('cleanup_reap_child "$SOURCE_GUARD_PID"', RUN_SH)
        self.assertIn('cleanup_reap_child "$BOOTSTRAP_SOURCE_GUARD_PID"', RUN_SH)
        self.assertIn("reap_bootstrap_guard_for_handoff", RUN_SH)
        self.assertIn('"$clock_failure" == false', RUN_SH)
        self.assertIn("bounded_reap_contain_clock_failure", BOUNDED_REAP)
        self.assertIn('"clock_failure=$clock_failure"', BOUNDED_REAP)

    def test_failed_handoff_reap_is_not_repeated_and_still_preserves_ledger(self):
        marker = "reap_bootstrap_guard_for_handoff() {\n"
        start = RUN_SH.index(marker)
        end = RUN_SH.index("\n}\n\npreserve_guard_event_ledger()", start) + 2
        handoff_function = RUN_SH[start:end]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            script = f"""
set -euo pipefail
{handoff_function}
REAP_COUNT=0
PRESERVE_COUNT=0
EVIDENCE=$1
LIVE_LEDGER=$2
PRESERVED_LEDGER=$3
PRESERVATION_REPORT=$4
bounded_reap() {{
  (( REAP_COUNT += 1 ))
  wait "$1"
}}
preserve_guard_event_ledger() {{
  (( PRESERVE_COUNT += 1 ))
  cp "$1" "$2"
  rm "$1"
  print -r -- verified > "$3"
}}
cleanup() {{
  set +e
  if [[ "$BOOTSTRAP_SOURCE_GUARD_PID" == <-> ]]; then
    bounded_reap "$BOOTSTRAP_SOURCE_GUARD_PID" ignored ignored 0 0 0
  fi
  preserve_guard_event_ledger \
    "$LIVE_LEDGER" "$PRESERVED_LEDGER" "$PRESERVATION_REPORT"
  print -r -- "reaps=$REAP_COUNT preserves=$PRESERVE_COUNT" > "$EVIDENCE/state.txt"
}}
trap cleanup EXIT
print -r -- ledger-evidence > "$LIVE_LEDGER"
( exit 137 ) &
BOOTSTRAP_SOURCE_GUARD_PID=$!
set +e
reap_bootstrap_guard_for_handoff
handoff_exit=$?
set -e
[[ $handoff_exit == 137 && -z "$BOOTSTRAP_SOURCE_GUARD_PID" ]] || exit 99
exit 7
"""
            live = root / "live.jsonl"
            preserved = root / "preserved.jsonl"
            report = root / "preservation.txt"
            result = subprocess.run(
                [
                    "/bin/zsh",
                    "-f",
                    "-c",
                    script,
                    "handoff-regression",
                    str(root),
                    str(live),
                    str(preserved),
                    str(report),
                ],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )

            self.assertEqual(result.returncode, 7, result.stderr)
            self.assertNotIn("not a child", result.stderr)
            self.assertEqual(
                (root / "state.txt").read_text(encoding="utf-8").strip(),
                "reaps=1 preserves=1",
            )
            self.assertFalse(live.exists())
            self.assertEqual(preserved.read_text(encoding="utf-8"), "ledger-evidence\n")
            self.assertEqual(report.read_text(encoding="utf-8"), "verified\n")

    def test_complete_rig_build_input_tree_is_part_of_tested_identity(self):
        self.assertIn('"$HERE/tree_manifest.py" write', RUN_SH)
        self.assertIn('"$HERE/tree_manifest.py" verify', RUN_SH)
        for scope in (
            '"lib"',
            '"integration_test"',
            '"test"',
            '"assets"',
            '"tool/telemetry_memory_rig"',
            '"android/app/src"',
            '"android/gradle/wrapper"',
            '".dart_tool/package_config.json"',
            '".dart_tool/package_graph.json"',
            '".dart_tool/native_assets.yaml"',
            '".dart_tool/lib"',
            '"pubspec.lock"',
            '"android/app/build.gradle.kts"',
            '"android/gradle/verification-metadata.xml"',
            '"android/local.properties"',
        ):
            self.assertIn(scope, TREE_MANIFEST)
        self.assertIn("collect_external_paths", TREE_MANIFEST)
        self.assertIn('f"@package/{name}/{relative}"', TREE_MANIFEST)
        self.assertIn("collect_toolchain_paths", TREE_MANIFEST)
        self.assertIn('f"@toolchain/flutter/{relative}"', TREE_MANIFEST)
        self.assertIn("packages/flutter_tools", TREE_MANIFEST)
        self.assertIn(
            '"packages/flutter_tools/.dart_tool/package_config.json"',
            TREE_MANIFEST,
        )
        self.assertIn("@flutter-tool-package/", TREE_MANIFEST)
        self.assertIn("collect_flutter_tool_roots", SOURCE_TREE_GUARD)
        self.assertIn('"bin/internal"', TREE_MANIFEST)
        self.assertIn('"bin/dart"', TREE_MANIFEST)
        self.assertIn("bin/cache/artifacts/engine/common", TREE_MANIFEST)
        self.assertIn(
            "bin/cache/artifacts/engine/darwin-x64/frontend_server_aot.dart.snapshot",
            TREE_MANIFEST,
        )
        self.assertIn("O_NOFOLLOW", TREE_MANIFEST)
        self.assertIn("before.st_nlink != 1", TREE_MANIFEST)
        self.assertIn("_validate_native_assets", TREE_MANIFEST)
        self.assertIn("clean_external_native_build_caches", TREE_MANIFEST)
        self.assertEqual(RUN_SH.count("clean-external-native-caches"), 2)
        self.assertIn("external-native-cache-cleanup.pre.json", RUN_SH)
        self.assertIn("external-native-cache-cleanup.post.json", RUN_SH)
        self.assertIn("verify-native-cache-freshness", RUN_SH)
        self.assertIn("native-cache-freshness-validated.json", RUN_SH)
        self.assertRegex(
            TREE_MANIFEST,
            r"actual = build_entries\(\s*root,\s*expected_flutter_root=expected_flutter_root,",
        )
        self.assertIn("added=", TREE_MANIFEST)
        self.assertIn("removed=", TREE_MANIFEST)
        self.assertIn("changed=", TREE_MANIFEST)

    def test_native_cache_cleanup_precedes_every_android_build_and_is_hashed(self):
        pre_cleanup = RUN_SH.index(
            '--evidence "$EVIDENCE/external-native-cache-cleanup.pre.json"'
        )
        bootstrap_manifest = RUN_SH.index(
            '--manifest "$EVIDENCE/tested-files.bootstrap.sha256"'
        )
        bootstrap_guard = RUN_SH.index(
            '"$HERE/source_tree_guard.py"', bootstrap_manifest
        )
        gradle_version = RUN_SH.index("./gradlew --no-daemon --version")
        generated_cleanup = RUN_SH.index("generated-input-cleanup.json")
        flutter_gradle_pre = RUN_SH.index("flutter-gradle-generated-cleanup.pre.json")
        flutter_gradle_post = RUN_SH.index("flutter-gradle-generated-cleanup.post.json")
        first_jdk = RUN_SH.index('"$SEALED_JDK_ROOT/bin/keytool"')
        first_flutter = RUN_SH.index("sealed_flutter flutter-version --version")
        first_dart = RUN_SH.index("sealed_dart dart-version --version")
        guarded_build = RUN_SH.index("android-toolchain-build-supervision.json")
        discovery = RUN_SH.index("android-toolchain.discovery.json")
        freshness = RUN_SH.index("verify-native-cache-freshness")
        self.assertLess(pre_cleanup, generated_cleanup)
        self.assertLess(pre_cleanup, flutter_gradle_pre)
        self.assertLess(flutter_gradle_pre, generated_cleanup)
        self.assertLess(generated_cleanup, bootstrap_manifest)
        self.assertLess(bootstrap_manifest, bootstrap_guard)
        self.assertLess(generated_cleanup, first_jdk)
        self.assertLess(bootstrap_guard, gradle_version)
        self.assertLess(generated_cleanup, gradle_version)
        self.assertLess(generated_cleanup, first_flutter)
        self.assertLess(generated_cleanup, first_dart)
        self.assertLess(generated_cleanup, guarded_build)
        self.assertLess(guarded_build, discovery)
        self.assertLess(discovery, freshness)
        self.assertLess(freshness, flutter_gradle_post)
        for key in (
            "androidToolchainDiscoverySha256",
            "externalNativeCacheCleanupPreSha256",
            "externalNativeCacheCleanupPostSha256",
            "flutterGradleGeneratedCleanupPreSha256",
            "flutterGradleGeneratedCleanupPostSha256",
            "generatedInputCleanupSha256",
            "nativeCacheFreshnessValidationSha256",
        ):
            self.assertIn(key, RUN_SH)

    def test_flutter_gradle_generated_cleanup_is_fail_closed_on_all_exit_paths(self):
        function_start = RUN_SH.index("cleanup_flutter_gradle_generated_state() {")
        function_end = RUN_SH.index("\n}\n", function_start)
        cleanup_function = RUN_SH[function_start:function_end]
        self.assertIn("clean-flutter-gradle-generated-state", cleanup_function)
        self.assertIn("--expected-flutter-root", cleanup_function)
        self.assertIn("FLUTTER_GRADLE_GENERATED_DIRTY=0", cleanup_function)

        bootstrap_exit = RUN_SH[
            RUN_SH.index("bootstrap_exit() {") : RUN_SH.index(
                "trap bootstrap_exit EXIT"
            )
        ]
        final_exit = RUN_SH[
            RUN_SH.index("on_exit() {") : RUN_SH.index("trap on_exit EXIT")
        ]
        self.assertIn("cleanup_flutter_gradle_generated_state", bootstrap_exit)
        self.assertIn("cleanup_flutter_gradle_generated_state", final_exit)

    def test_version_and_identity_pipelines_consume_complete_producer_output(self):
        self.assertNotRegex(RUN_SH, r"\|\s*head(?:\s|$)")
        self.assertIn(
            "flutter_version=$(sealed_flutter flutter-version --version "
            "--suppress-analytics | awk 'NR == 1 {print}')",
            RUN_SH,
        )
        self.assertIn('die "sealed Flutter version probe failed"', RUN_SH)
        self.assertIn('die "sealed Flutter version probe was empty"', RUN_SH)
        self.assertIn('die "sealed Flutter version probe was unexpected"', RUN_SH)
        self.assertIn(
            "dart_version=$(sealed_dart dart-version --version)",
            RUN_SH,
        )
        self.assertIn('die "sealed Dart version probe failed"', RUN_SH)
        self.assertIn('die "sealed Dart version probe was empty"', RUN_SH)
        self.assertIn('die "sealed Dart version probe was unexpected"', RUN_SH)
        self.assertNotIn(
            "flutter_version=$(sealed_flutter flutter-version",
            RUN_SH[RUN_SH.index('{\n  print -r -- "serial=$SERIAL"') :],
        )
        self.assertNotIn(
            "dart_version=$(sealed_dart dart-version",
            RUN_SH[RUN_SH.index('{\n  print -r -- "serial=$SERIAL"') :],
        )
        self.assertIn("$ADB version | awk 'NR == 1 {print}'", RUN_SH)
        self.assertIn(
            "grep -E 'versionCode=|versionName=' | awk 'NR <= 2 {print}'",
            RUN_SH,
        )

    def test_scoped_command_keeps_control_diagnostics_off_child_stdout(self):
        with tempfile.TemporaryDirectory() as temporary:
            script = f"""
set -u
EVIDENCE={shlex.quote(temporary)}
PROCESS_SCOPE_AUTHORITY_DIR={shlex.quote(temporary)}
SCOPED_COMMAND=unused
ANDROID_SDK_SANDBOX_EXEC=/bin/true
ANDROID_SDK_SANDBOX_WRAPPER_SHA256={"a" * 64}
GATE_OWNER_ROOT_PID=$$
PROCESS_SCOPE_LAUNCH_ATTEMPT=0
GRADLE_FORENSIC_RETENTION_LATCH=0
SCOPE_REFERENCE_ARGS=()
assert_android_sdk_sandbox_binding() {{ print -r -- control-binding; }}
build_scope_reference_args() {{ SCOPE_REFERENCE_ARGS=(); print -r -- control-reference; }}
validate_scoped_sandbox_result() {{ print -r -- control-validator; }}
fake_python() {{
  while (( $# > 0 )) && [[ $1 != -- ]]; do shift; done
  (( $# > 0 )) || return 64
  shift
  "$@"
}}
PYTHON=fake_python
{self._scoped_sandbox_runner()}
run_scoped_sandbox_command output-contract "$EVIDENCE" /usr/bin/true
"""
            result = subprocess.run(
                ["/bin/zsh", "-f", "-c", script],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertIn("control-binding", result.stderr)
        self.assertIn("control-reference", result.stderr)
        self.assertIn("control-validator", result.stderr)

    def test_empty_dart_version_probe_rejects_scope_diagnostics(self):
        result = self._run_version_probe(
            flutter_body="print -r -- 'Flutter 3.47.0 pinned'",
            dart_body="print -u2 -- scoped-command-diagnostic",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sealed Dart version probe was empty", result.stderr)

    def test_nonzero_version_probe_is_rejected_even_with_output(self):
        for failing_tool in ("flutter", "dart"):
            with self.subTest(failing_tool=failing_tool):
                result = self._run_version_probe(
                    flutter_body=(
                        "print -r -- 'Flutter 3.47.0 pinned'; return 7"
                        if failing_tool == "flutter"
                        else "print -r -- 'Flutter 3.47.0 pinned'"
                    ),
                    dart_body=(
                        "print -r -- 'Dart SDK version: 3.13.0 pinned'; return 7"
                        if failing_tool == "dart"
                        else "print -r -- 'Dart SDK version: 3.13.0 pinned'"
                    ),
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(
                    f"sealed {failing_tool.capitalize()} version probe failed",
                    result.stderr,
                )

    def test_valid_version_probe_keeps_only_tool_output(self):
        result = self._run_version_probe(
            flutter_body=(
                "print -r -- 'Flutter 3.47.0 pinned'; "
                "print -r -- 'Framework revision ignored'"
            ),
            dart_body=(
                "print -u2 -- scoped-command-diagnostic; "
                "print -r -- 'Dart SDK version: 3.13.0 pinned'"
            ),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines(),
            [
                "flutter=Flutter 3.47.0 pinned",
                "dart=Dart SDK version: 3.13.0 pinned",
            ],
        )
        self.assertIn("scoped-command-diagnostic", result.stderr)

    def test_live_tree_is_verified_before_each_flutter_run_and_sealed(self):
        self.assertIn("tested-files.pre.sha256", RUN_SH)
        self.assertIn("tested-files.post.sha256", RUN_SH)
        self.assertIn("verify_tested_tree", RUN_SH)
        self.assertIn("tested tree pre/post manifests differ", RUN_SH)
        measurement = RUN_SH.index(
            "start_scoped_sandbox_command telemetry-memory-measure "
            '"$APP_ROOT" "$MEASURE_LOG"'
        )
        self.assertLess(
            RUN_SH.rindex("verify_tested_tree", 0, measurement), measurement
        )
        gate_launch = RUN_SH.index('start_scoped_sandbox_command "$scope_label"')
        self.assertLess(
            RUN_SH.rindex("verify_tested_tree", 0, gate_launch), gate_launch
        )

    def test_live_guard_records_transient_tree_mutations_and_is_fail_closed(self):
        self.assertIn('"$HERE/source_tree_guard.py"', RUN_SH)
        self.assertEqual(RUN_SH.count("--backend darwin-fsevents"), 2)
        self.assertEqual(RUN_SH.count("--baseline-manifest"), 2)
        self.assertNotIn("command -v fswatch", RUN_SH)
        self.assertNotIn("--fswatch", RUN_SH)
        self.assertNotIn("FSWATCH_", RUN_SH)
        self.assertIn("source_guard_backend=darwin-fsevents", RUN_SH)
        self.assertIn("watcherBackend", RUN_SH)
        self.assertIn("nativeFSEventsWatchRoots", RUN_SH)
        self.assertIn("rawCallbackRecordCount", RUN_SH)
        self.assertIn("classifiedEventCount", RUN_SH)
        self.assertIn("fatalRawRecordCount", RUN_SH)
        self.assertIn("suppressedInternalSinkEventCount", RUN_SH)
        self.assertIn("cloneObservedNoDeltaEventCount", RUN_SH)
        self.assertIn("baselineManifestSha256", RUN_SH)
        self.assertIn("baselineUniqueRegularFileCount", RUN_SH)
        self.assertEqual(RUN_SH.count("--baseline-sidecar"), 2)
        self.assertGreaterEqual(
            RUN_SH.count("sealed-manifest-pure-item-cloned-v2"),
            4,
        )
        self.assertGreaterEqual(RUN_SH.count("0x00410000"), 2)
        self.assertGreaterEqual(
            RUN_SH.count("clone reconciliation proof failed"),
            2,
        )
        self.assertGreaterEqual(RUN_SH.count("raw-darwin-fsevents"), 2)
        self.assertGreaterEqual(RUN_SH.count("classified-darwin-fsevents"), 2)
        self.assertGreaterEqual(RUN_SH.count("guard ledger count mismatch"), 2)
        self.assertIn("flushSyncRequested", RUN_SH)
        self.assertIn("flushSyncCompleted", RUN_SH)
        self.assertIn("drainedSentinelEmitted", RUN_SH)
        self.assertIn("drainedSentinelObserved", RUN_SH)
        self.assertIn('--nonce "$SOURCE_GUARD_NONCE"', RUN_SH)
        self.assertIn("assert_source_guard_live", RUN_SH)
        self.assertIn("source-tree-guard-ready.json", RUN_SH)
        self.assertIn("source-tree-guard-events.jsonl", RUN_SH)
        self.assertIn(
            'BOOTSTRAP_SOURCE_GUARD_EVENTS_LIVE="$ISOLATED_USER_TEMP_PARENT/'
            'bootstrap-source-tree-guard-events.jsonl"',
            RUN_SH,
        )
        self.assertIn(
            'SOURCE_GUARD_EVENTS_LIVE="$ISOLATED_USER_TEMP_PARENT/'
            'source-tree-guard-events.jsonl"',
            RUN_SH,
        )
        self.assertIn('--events-file "$BOOTSTRAP_SOURCE_GUARD_EVENTS_LIVE"', RUN_SH)
        self.assertIn('--events-file "$SOURCE_GUARD_EVENTS_LIVE"', RUN_SH)
        self.assertGreaterEqual(RUN_SH.count("preserve_guard_event_ledger"), 5)
        self.assertIn('"$HERE/guard_ledger.py"', RUN_SH)
        self.assertIn("source-tree-guard-result.json", RUN_SH)
        self.assertIn("canaryCreatedObserved", RUN_SH)
        self.assertIn("canaryRemovedObserved", RUN_SH)
        self.assertIn("violatingEventCount", RUN_SH)
        self.assertIn("watcherTermination", RUN_SH)
        self.assertIn("stale source-tree guard control/evidence exists", RUN_SH)
        self.assertIn('"$PYTHON" -I -S -B "$HERE/source_tree_guard.py"', RUN_SH)
        self.assertNotIn("PYTHONPYCACHEPREFIX", RUN_SH)
        self.assertIn("sys.dont_write_bytecode = True", SOURCE_TREE_GUARD)
        self.assertIn('compile(source_bytes, str(source), "exec"', SOURCE_TREE_GUARD)
        self.assertNotIn("spec_from_file_location", SOURCE_TREE_GUARD)
        self.assertIn("RESULT_VERSION = 3", SOURCE_TREE_GUARD)
        self.assertIn("PURE_ITEM_CLONED_FILE_FLAGS", SOURCE_TREE_GUARD)
        self.assertIn("flistxattr", SOURCE_TREE_GUARD)
        self.assertIn("fgetxattr", SOURCE_TREE_GUARD)
        self.assertIn('bounded_reap "$SOURCE_GUARD_PID"', RUN_SH)
        post_manifest = RUN_SH.index(
            'write_tested_tree_manifest "$EVIDENCE/tested-files.post.sha256"'
        )
        authorized_stop = RUN_SH.index('touch "$SOURCE_GUARD_STOP"', post_manifest)
        self.assertLess(post_manifest, authorized_stop)
        self.assertIn("sourceTreeGuardResultSha256", RUN_SH)

    def test_source_guard_readiness_wait_is_monotonic_bounded_and_shared(self):
        helper = self._source_guard_readiness_waiter()

        timeout_match = re.search(
            r"^SOURCE_GUARD_READY_TIMEOUT_MS=(\d+)$",
            RUN_SH,
            re.MULTILINE,
        )
        self.assertIsNotNone(timeout_match)
        timeout_ms = int(timeout_match.group(1))
        self.assertGreaterEqual(timeout_ms, 300_000)
        self.assertLessEqual(timeout_ms, 600_000)
        self.assertNotIn("bounded_reap_now_ns", helper)
        self.assertEqual(helper.count('"$PYTHON" -I -S -B -'), 1)
        self.assertIn("time.monotonic_ns()", helper)
        self.assertIn("deadline_ns", helper)
        self.assertEqual(helper.count("os.kill(pid, 0)"), 1)
        self.assertGreaterEqual(helper.count("require_live_child()"), 3)
        bootstrap_wait = RUN_SH[
            RUN_SH.index("BOOTSTRAP_SOURCE_GUARD_PID=$!") : RUN_SH.index(
                '"$PYTHON" -I -S -B - "$BOOTSTRAP_SOURCE_GUARD_READY"'
            )
        ]
        source_wait = RUN_SH[
            RUN_SH.index("SOURCE_GUARD_PID=$!") : RUN_SH.index(
                '"$PYTHON" -I -S -B - "$SOURCE_GUARD_READY"'
            )
        ]
        self.assertNotIn("{1..1200}", bootstrap_wait)
        self.assertNotIn("{1..1200}", source_wait)
        self.assertEqual(
            RUN_SH.count(
                'wait_for_live_guard_ready "$BOOTSTRAP_SOURCE_GUARD_PID" '
                '"$BOOTSTRAP_SOURCE_GUARD_READY"'
            ),
            1,
        )
        self.assertEqual(
            RUN_SH.count(
                'wait_for_live_guard_ready "$SOURCE_GUARD_PID" "$SOURCE_GUARD_READY"'
            ),
            1,
        )

    def test_source_guard_readiness_rejects_ready_file_from_dead_guard(self):
        helper = self._source_guard_readiness_waiter()

        with tempfile.TemporaryDirectory() as temporary:
            ready = Path(temporary) / "ready.json"
            ready.write_text("{}\n", encoding="utf-8")
            script = f"""
PYTHON={sys.executable!r}
{helper}
( exit 0 ) &
pid=$!
wait \"$pid\"
wait_for_live_guard_ready \"$pid\" {str(ready)!r} 300000
"""
            result = subprocess.run(
                ["/bin/zsh", "-f", "-c", script],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )

        self.assertEqual(result.returncode, 2, result.stderr)

    def test_source_guard_readiness_accepts_secure_file_from_live_guard(self):
        with tempfile.TemporaryDirectory() as temporary:
            ready = Path(temporary) / "ready.json"
            ready.write_text("{}\n", encoding="utf-8")
            ready.chmod(0o600)

            result = self._run_source_guard_readiness_waiter(ready)

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_source_guard_readiness_times_out_with_live_guard(self):
        with tempfile.TemporaryDirectory() as temporary:
            missing_ready = Path(temporary) / "missing-ready.json"

            started = time.monotonic()
            result = self._run_source_guard_readiness_waiter(
                missing_ready,
                timeout_ms="80",
            )
            elapsed = time.monotonic() - started

        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertGreaterEqual(elapsed, 0.05)
        self.assertLess(elapsed, 2.0)

    def test_source_guard_readiness_rejects_unsafe_ready_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            secure = root / "secure.json"
            secure.write_text("{}\n", encoding="utf-8")
            secure.chmod(0o600)

            symlink = root / "symlink.json"
            symlink.symlink_to(secure)

            directory = root / "directory.json"
            directory.mkdir()

            hardlink = root / "hardlink.json"
            os.link(secure, hardlink)

            permissive = root / "permissive.json"
            permissive.write_text("{}\n", encoding="utf-8")
            permissive.chmod(0o644)

            for name, ready in {
                "symlink": symlink,
                "directory": directory,
                "hardlink": hardlink,
                "permissions": permissive,
            }.items():
                with self.subTest(name=name):
                    result = self._run_source_guard_readiness_waiter(ready)
                    self.assertEqual(result.returncode, 3, result.stderr)

    def test_source_guard_readiness_rejects_invalid_inputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            ready = Path(temporary) / "ready.json"
            ready.write_text("{}\n", encoding="utf-8")
            ready.chmod(0o600)

            cases = {
                "non-numeric-pid": ("not-a-pid", "250", ready),
                "zero-pid": ("0", "250", ready),
                "zero-timeout": ('"$child"', "0", ready),
                "excessive-timeout": ('"$child"', "600001", ready),
                "relative-ready-path": ('"$child"', "250", Path("ready.json")),
            }
            for name, (pid_argument, timeout_ms, ready_file) in cases.items():
                with self.subTest(name=name):
                    result = self._run_source_guard_readiness_waiter(
                        ready_file,
                        pid_argument=pid_argument,
                        timeout_ms=timeout_ms,
                    )
                    self.assertEqual(result.returncode, 64, result.stderr)

    def test_guard_result_validators_reject_forged_ledger_relationships(self):
        raw_a, classified_a = self._valid_guard_pair(1)
        raw_b, classified_b = self._valid_guard_pair(2)
        valid_ledger = [raw_a, classified_a, raw_b, classified_b]

        duplicate_classified = copy.deepcopy(valid_ledger)
        duplicate_classified[3]["callbackRecordSequence"] = 1

        orphan_classified = copy.deepcopy(valid_ledger)
        orphan_classified[3]["callbackRecordSequence"] = 3

        raw_only_fatal_mismatch = copy.deepcopy(valid_ledger[:-1])

        path_mismatch = copy.deepcopy(valid_ledger)
        path_mismatch[1]["path"] = "/forged/different-path.dart"

        event_mismatch = copy.deepcopy(valid_ledger)
        event_mismatch[1]["eventId"] = 999

        illegal_status = copy.deepcopy(valid_ledger)
        illegal_status[1]["cloneReconciliation"]["status"] = "accepted-by-default"

        empty_fingerprints = copy.deepcopy(valid_ledger)
        empty_fingerprints[1]["cloneReconciliation"]["baseline"] = {}
        empty_fingerprints[1]["cloneReconciliation"]["current"] = {}

        baseline_missing_nonmaterial = copy.deepcopy(valid_ledger)
        baseline_missing_nonmaterial[1]["cloneReconciliation"] = {
            "policy": "sealed-manifest-pure-item-cloned-v2",
            "status": "clone-baseline-missing",
        }

        delta_equal = copy.deepcopy(valid_ledger)
        delta_equal[1]["cloneReconciliation"]["status"] = "clone-observed-delta"
        delta_equal[1]["material"] = True
        delta_equal[1]["violates"] = True

        delta_nonmaterial = copy.deepcopy(valid_ledger)
        delta_nonmaterial[1]["cloneReconciliation"]["status"] = "clone-observed-delta"
        delta_nonmaterial[1]["cloneReconciliation"]["current"]["sha256"] = "f" * 64

        violates_count_mismatch = copy.deepcopy(valid_ledger)
        violates_count_mismatch[1].pop("cloneReconciliation")
        violates_count_mismatch[0]["rawFlags"] = 0x00011000
        violates_count_mismatch[1]["flags"] = ["IsFile", "Updated"]
        violates_count_mismatch[1]["material"] = True
        violates_count_mismatch[1]["violates"] = True

        invalid_link_count = copy.deepcopy(valid_ledger)
        invalid_link_count[1]["cloneReconciliation"]["baseline"]["linkCount"] = 2
        invalid_link_count[1]["cloneReconciliation"]["current"]["linkCount"] = 2

        duplicate_xattr_name = copy.deepcopy(valid_ledger)
        duplicate_xattr = {
            "name": "hex:636f6d2e74657374",
            "bytes": 1,
            "sha256": "a" * 64,
        }
        duplicate_xattr_name[1]["cloneReconciliation"]["baseline"]["xattrs"] = [
            duplicate_xattr,
            copy.deepcopy(duplicate_xattr),
        ]
        duplicate_xattr_name[1]["cloneReconciliation"]["current"]["xattrs"] = [
            copy.deepcopy(duplicate_xattr),
            copy.deepcopy(duplicate_xattr),
        ]

        reviewer_boolean_bypass = copy.deepcopy(valid_ledger)
        reviewer_boolean_bypass[1].pop("cloneReconciliation")
        reviewer_boolean_bypass[0]["rawFlags"] = 0x00011000
        reviewer_boolean_bypass[1]["flags"] = ["IsFile", "Updated"]
        reviewer_boolean_bypass[1]["included"] = True
        reviewer_boolean_bypass[1]["material"] = True
        reviewer_boolean_bypass[1]["violates"] = False

        modified_raw_benign_classification = copy.deepcopy(valid_ledger)
        modified_raw_benign_classification[1].pop("cloneReconciliation")
        modified_raw_benign_classification[0]["rawFlags"] = 0x00011000
        modified_raw_benign_classification[1]["flags"] = ["IsFile"]
        modified_raw_benign_classification[1]["included"] = True
        modified_raw_benign_classification[1]["material"] = False
        modified_raw_benign_classification[1]["violates"] = False

        unknown_raw_flags = copy.deepcopy(valid_ledger)
        unknown_raw_flags[0]["rawFlags"] = 0x00810000

        integrity_raw_flags = copy.deepcopy(valid_ledger)
        integrity_raw_flags[0]["rawFlags"] = 0x00010001

        forged_baseline_path = copy.deepcopy(valid_ledger)
        forged_baseline_path[1]["cloneReconciliation"]["baselineCanonicalPath"] = (
            "/forged/not-the-event-path.dart"
        )

        forged_logical_id = copy.deepcopy(valid_ledger)
        forged_logical_id[1]["cloneReconciliation"]["baselineManifestEntries"][0][
            "logicalId"
        ] = "lib/forged.dart"

        forged_scope = copy.deepcopy(valid_ledger)
        forged_scope[1]["scope"] = "external-package"
        forged_scope[1]["cloneReconciliation"]["baselineEventScope"] = (
            "external-package"
        )

        unlisted_external = copy.deepcopy(valid_ledger)
        unlisted_path = "/tmp/unlisted-external-package/source-1.dart"
        unlisted_external[0]["path"] = unlisted_path
        unlisted_external[1]["path"] = unlisted_path
        unlisted_external[1]["scope"] = "external-package"
        unlisted_external[1]["cloneReconciliation"]["baselineCanonicalPath"] = (
            unlisted_path
        )
        unlisted_external[1]["cloneReconciliation"]["baselineEventScope"] = (
            "external-package"
        )

        ignored_generated_no_delta = copy.deepcopy(valid_ledger)
        ignored_path = "/tmp/watched-package/build/generated.dart"
        ignored_generated_no_delta[0]["path"] = ignored_path
        ignored_generated_no_delta[1]["path"] = ignored_path
        ignored_generated_no_delta[1]["included"] = False
        ignored_generated_no_delta[1]["material"] = False
        ignored_generated_no_delta[1]["violates"] = False
        ignored_generated_no_delta[1]["scope"] = "external-package"
        ignored_generated_no_delta[1]["cloneReconciliation"][
            "baselineCanonicalPath"
        ] = ignored_path
        ignored_generated_no_delta[1]["cloneReconciliation"]["baselineEventScope"] = (
            "external-package"
        )

        forged_ledgers = {
            "raw-a-b-classified-a-a": (
                duplicate_classified,
                "classified-darwin-fsevents record key",
            ),
            "orphan-classified-key": (
                orphan_classified,
                "classified record has no raw pair",
            ),
            "raw-only-fatal-count-mismatch": (
                raw_only_fatal_mismatch,
                "ledger count mismatch",
            ),
            "paired-path-mismatch": (
                path_mismatch,
                "paired record identity/flags mismatch",
            ),
            "paired-event-mismatch": (
                event_mismatch,
                "paired record identity/flags mismatch",
            ),
            "illegal-reconciliation-status": (
                illegal_status,
                "reconciliation status is invalid",
            ),
            "empty-no-delta-fingerprints": (
                empty_fingerprints,
                "clone reconciliation proof failed",
            ),
            "baseline-missing-but-nonmaterial": (
                baseline_missing_nonmaterial,
                "clone reconciliation proof failed",
            ),
            "delta-but-equal": (
                delta_equal,
                "clone reconciliation proof failed",
            ),
            "delta-but-nonmaterial": (
                delta_nonmaterial,
                "clone reconciliation proof failed",
            ),
            "classified-violates-result-zero": (
                violates_count_mismatch,
                "ledger count mismatch",
            ),
            "invalid-fingerprint-link-count": (
                invalid_link_count,
                "clone reconciliation proof failed",
            ),
            "duplicate-fingerprint-xattr-name": (
                duplicate_xattr_name,
                "clone reconciliation proof failed",
            ),
            "reviewer-boolean-bypass": (
                reviewer_boolean_bypass,
                "classified boolean invariant failed",
            ),
            "modified-raw-classified-benign": (
                modified_raw_benign_classification,
                "paired record identity/flags mismatch",
            ),
            "unknown-paired-raw-flags": (
                unknown_raw_flags,
                "paired raw flags are invalid",
            ),
            "integrity-paired-raw-flags": (
                integrity_raw_flags,
                "paired raw flags are invalid",
            ),
            "forged-no-delta-baseline-path": (
                forged_baseline_path,
                "clone reconciliation proof failed",
            ),
            "forged-no-delta-logical-id": (
                forged_logical_id,
                "clone reconciliation proof failed",
            ),
            "forged-no-delta-scope": (
                forged_scope,
                "clone reconciliation proof failed",
            ),
            "unlisted-external-no-delta": (
                unlisted_external,
                "clone reconciliation proof failed",
            ),
            "ignored-generated-forged-no-delta": (
                ignored_generated_no_delta,
                "clone reconciliation proof failed",
            ),
        }
        validators = (
            "bootstrap-source-tree-guard-result-validated.txt",
            "source-tree-guard-result-validated.txt",
        )

        for validator in validators:
            with self.subTest(validator=validator, ledger="valid"):
                completed = self._run_guard_result_validator(validator, valid_ledger)
                self.assertEqual(completed.returncode, 0, completed.stderr)
            for ledger_name, (ledger, expected_error) in forged_ledgers.items():
                with self.subTest(validator=validator, ledger=ledger_name):
                    completed = self._run_guard_result_validator(validator, ledger)
                    self.assertNotEqual(completed.returncode, 0, completed.stdout)
                    self.assertIn(expected_error, completed.stderr)

            with self.subTest(
                validator=validator, permission="non-member-group-writable"
            ):
                completed = self._run_guard_result_validator(
                    validator,
                    valid_ledger,
                    artifact_mutation="nonmember-group-writable-valid",
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)

            artifact_forgeries = {
                "current-group-writable-fingerprint": "record content is invalid",
                "world-writable-fingerprint": "record content is invalid",
                "result-schema": "did not prove an unchanged tree",
                "ready-schema": "did not prove an unchanged tree",
                "result-policy": "did not prove an unchanged tree",
                "ready-policy": "did not prove an unchanged tree",
                "sidecar-sha-attestation": "does not match sealed baseline",
                "sidecar-count-attestation": "does not match sealed baseline",
                "observed-count-tampering": "ledger count mismatch",
                "sidecar-resource-cap": "aggregate bytes exceed bounds",
                "sidecar-noncanonical-tampering": "not canonical schema v1",
                "sidecar-logical-id-tampering": "manifest coverage is invalid",
                "sidecar-scope-tampering": "record content is invalid",
                "sidecar-manifest-sha-tampering": "identity is invalid",
            }
            for forgery, expected_error in artifact_forgeries.items():
                with self.subTest(validator=validator, artifact=forgery):
                    completed = self._run_guard_result_validator(
                        validator,
                        valid_ledger,
                        artifact_mutation=forgery,
                    )
                    self.assertNotEqual(completed.returncode, 0, completed.stdout)
                    self.assertIn(expected_error, completed.stderr)

    def test_gradle_dependencies_are_checksum_verified_and_sealed(self):
        self.assertIn("<verify-metadata>true</verify-metadata>", GRADLE_VERIFICATION)
        self.assertIn(
            "<verify-signatures>false</verify-signatures>", GRADLE_VERIFICATION
        )
        self.assertGreater(GRADLE_VERIFICATION.count("<sha256 value="), 100)
        self.assertIn('"android/gradle/verification-metadata.xml"', TREE_MANIFEST)

    def test_fresh_rig_build_metadata_is_checksum_verified(self):
        namespace = {"v": "https://schema.gradle.org/dependency-verification"}
        root = ET.fromstring(GRADLE_VERIFICATION)
        actual = {}
        for component in root.findall(".//v:component", namespace):
            identity = (
                component.get("group"),
                component.get("name"),
                component.get("version"),
            )
            for artifact in component.findall("v:artifact", namespace):
                checksums = artifact.findall("v:sha256", namespace)
                if len(checksums) == 1:
                    actual[(*identity, artifact.get("name"))] = checksums[0].get(
                        "value"
                    )

        expected = {
            (
                "com.google.guava",
                "guava-parent",
                "33.3.1-jre",
                "guava-parent-33.3.1-jre.pom",
            ): "55441db27e8869dfefe053059bdf478bdc7e95585642bf391f0023345fd56287",
            (
                "org.jetbrains.kotlin",
                "kotlin-gradle-plugins-bom",
                "2.2.20",
                "kotlin-gradle-plugins-bom-2.2.20.module",
            ): "3fbb4575ae37c4a776aeb86d8ff93c6aa11b0cf2da75749c5320e25850b0229e",
            (
                "org.jetbrains.kotlin",
                "kotlin-gradle-plugins-bom",
                "2.2.20",
                "kotlin-gradle-plugins-bom-2.2.20.pom",
            ): "3c6d469e915fbb3096ac4cb8c2f46c79d027c3c590e658a10688a1571eb578d8",
            (
                "org.jetbrains.kotlinx",
                "kotlinx-coroutines-bom",
                "1.8.0",
                "kotlinx-coroutines-bom-1.8.0.pom",
            ): "1239e9dbe1397cd5971342956b2511bc3ace7b641842e4372a088dcfa8b9ad55",
            (
                "org.junit",
                "junit-bom",
                "5.10.1",
                "junit-bom-5.10.1.pom",
            ): "21c4b0286f4b20069577ff4b20978a85c100ac8a46b6f1c8672fbaab337bc3f2",
            (
                "org.junit",
                "junit-bom",
                "5.11.0-M2",
                "junit-bom-5.11.0-M2.module",
            ): "86477abcf490d6ca059aa9973cb108d22a506f49d1a5569bb32cc6cbf43c2cce",
            (
                "org.junit",
                "junit-bom",
                "5.8.2",
                "junit-bom-5.8.2.pom",
            ): "836069ca9e8ee3c56e48376222da291263f137bd3fd16d84fdd47efcc3f286e2",
            (
                "org.junit",
                "junit-bom",
                "5.9.2",
                "junit-bom-5.9.2.module",
            ): "ab137ba5a8e32c9b066bf9126a1c76dd5614b724ba5c0b02549772b5e9f4cf1f",
            (
                "org.junit",
                "junit-bom",
                "5.9.3",
                "junit-bom-5.9.3.module",
            ): "b401fd25901e582a524aa5343c4b39e28bc56e24961c1069bf2b4bbfcee46b93",
        }
        for identity, checksum in expected.items():
            with self.subTest(identity=identity):
                self.assertEqual(actual.get(identity), checksum)

    def test_final_cleanup_and_evidence_seal_are_fail_closed(self):
        self.assertIn("final-cleanup${suffix}.txt", RUN_SH)
        self.assertIn('suffix=".retry-$CLEANUP_ATTEMPT"', RUN_SH)
        self.assertIn("while (( CLEANUP_ATTEMPT < 2 ))", RUN_SH)
        self.assertIn("cleanup_verified=", RUN_SH)
        self.assertIn("field_path_unchanged=", RUN_SH)
        self.assertIn("settings_unchanged=", RUN_SH)
        self.assertIn("runner-result.json", RUN_SH)
        self.assertIn("RUN_SHA256SUMS", RUN_SH)
        cleanup = RUN_SH.index("cleanup_rig || die")
        result = RUN_SH.index("runner-result.json", cleanup)
        seal = RUN_SH.index("RUN_SHA256SUMS", result)
        passed = RUN_SH.index("telemetry memory rig: PASS", seal)
        self.assertLess(cleanup, result)
        self.assertLess(result, seal)
        self.assertLess(seal, passed)

    def test_records_fingerprint_limits_plugin_and_build_identity(self):
        self.assertIn("TELLTALE_MEMORY_FINGERPRINT", TARGET)
        self.assertIn("ownership=observedOnly", TARGET)
        self.assertIn("share_plus_version=", RUN_SH)
        self.assertIn("build_fingerprint=", RUN_SH)
        self.assertIn("tested-files.pre.sha256", RUN_SH)

    def test_never_relabels_readiness_markers_as_force_stop_proof(self):
        self.assertIn("Readiness output is not force-stop proof", BLOCKERS)
        self.assertIn("checksum-sealed", BLOCKERS)
        self.assertNotIn("TELLTALE_MEMORY_FORCE_STOP_PROOF", TARGET)
        self.assertIn("host-only tests never substitute", BLOCKERS)

    def test_hard_gates_remain_96_and_48_mib_without_forced_gc(self):
        self.assertIn("PEAK_DELTA_LIMIT_KB = 96 * 1024", ANALYZER)
        self.assertIn("SETTLED_DELTA_LIMIT_KB = 48 * 1024", ANALYZER)
        combined = (RUN_SH + TARGET + ANALYZER + GENERATOR).lower()
        self.assertNotIn("collectallgarbage", combined)
        self.assertNotIn("force_gc", combined)


if __name__ == "__main__":
    unittest.main()
