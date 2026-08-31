#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "source_guard_evidence_validator_test_target",
    HERE / "source_guard_evidence_validator.py",
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load source guard evidence validator")
validator = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = validator
SPEC.loader.exec_module(validator)


def _write_json(
    path: pathlib.Path, value: dict[str, object], *, canonical: bool = False
) -> None:
    separators = (",", ":") if canonical else None
    path.write_text(
        json.dumps(value, sort_keys=True, separators=separators) + "\n",
        encoding="utf-8",
    )


class SourceGuardEvidenceValidatorTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name).resolve()
        self.source = self.root / "source.txt"
        self.source.write_text("sealed\n", encoding="utf-8")
        source_digest = hashlib.sha256(self.source.read_bytes()).hexdigest()
        self.manifest = self.root / "tested-files.sha256"
        self.manifest.write_text(f"{source_digest}  source.txt\n", encoding="utf-8")
        fingerprint = validator._capture_live_fingerprint(self.source)
        xattr_bytes = sum(item["bytes"] for item in fingerprint["xattrs"])
        self.sidecar = self.root / "tested-files.baseline.json"
        sidecar_value = {
            "version": 1,
            "policy": validator.POLICY,
            "manifestPath": str(self.manifest),
            "manifestSha256": hashlib.sha256(self.manifest.read_bytes()).hexdigest(),
            "manifestEntryCount": 1,
            "uniqueRegularFileCount": 1,
            "uniqueRegularFileBytes": fingerprint["size"],
            "totalXattrBytes": xattr_bytes,
            "namespaceEntryCounts": {"local": 1},
            "eventScopeFileCounts": {"exact-file": 1},
            "records": [
                {
                    "canonicalPath": str(self.source),
                    "eventScope": "exact-file",
                    "manifestEntries": [
                        {
                            "logicalId": "source.txt",
                            "namespace": "local",
                            "sha256": source_digest,
                        }
                    ],
                    "fingerprint": fingerprint,
                }
            ],
        }
        _write_json(self.sidecar, sidecar_value, canonical=True)
        attestation = {
            "baselineManifestPath": str(self.manifest),
            "baselineManifestSha256": hashlib.sha256(
                self.manifest.read_bytes()
            ).hexdigest(),
            "baselineSidecarPath": str(self.sidecar),
            "baselineSidecarSha256": hashlib.sha256(
                self.sidecar.read_bytes()
            ).hexdigest(),
            "baselineSidecarBytes": self.sidecar.stat().st_size,
            "baselineManifestEntryCount": 1,
            "baselineUniqueRegularFileCount": 1,
            "baselineUniqueRegularFileBytes": fingerprint["size"],
            "baselineTotalXattrBytes": xattr_bytes,
            "baselineNamespaceEntryCounts": {"local": 1},
            "baselineEventScopeFileCounts": {"exact-file": 1},
        }
        nonce = "0123456789abcdef0123456789abcdef"
        self.ready_value = {
            "version": 3,
            "nonce": nonce,
            "pid": os.getpid(),
            "watcherPid": os.getpid(),
            "watcherBackend": "darwin-fsevents",
            "startedEpochUs": 100,
            "bootstrapEventCount": 0,
            "canaryCreatedObserved": True,
            "canaryRemovedObserved": True,
            "canaryWriteAttemptCount": 1,
            "canaryDeleteAttemptCount": 1,
            "watchPaths": [str(self.source)],
            "nativeFSEventsWatchRoots": [str(self.source)],
            "suppressedInternalSinkEventCount": 0,
            "cloneReconciliationPolicy": validator.POLICY,
            **attestation,
        }
        self.result_value = {
            "version": 3,
            "nonce": nonce,
            "status": "stopped",
            "watcherBackend": "darwin-fsevents",
            "startedEpochUs": 100,
            "endedEpochUs": 300,
            "readyWritten": True,
            "stopRequestedEpochUs": 200,
            "bootstrapEventCount": 0,
            "canaryCreatedObserved": True,
            "canaryRemovedObserved": True,
            "canaryWriteAttemptCount": 1,
            "canaryDeleteAttemptCount": 1,
            "observedEventCount": 1,
            "violatingEventCount": 0,
            "rawCallbackRecordCount": 1,
            "classifiedEventCount": 1,
            "fatalRawRecordCount": 0,
            "suppressedInternalSinkEventCount": 0,
            "cloneObservedNoDeltaEventCount": 0,
            "cloneReconciliationPolicy": validator.POLICY,
            **attestation,
            "finalQueuedRecordCount": 0,
            "guardError": None,
            "watcherStderr": "",
            "watcherTermination": {
                "termSent": False,
                "killSent": False,
                "exitCode": 0,
                "contained": True,
                "flushSyncRequested": True,
                "flushSyncCompleted": True,
                "drainedSentinelEmitted": True,
                "drainedSentinelObserved": True,
            },
        }
        self.raw_record = {
            "recordType": "raw-darwin-fsevents",
            "epoch_us": 150,
            "path": str(self.source),
            "rawFlags": 0x00010000,
            "rawFlagsHex": "0x00010000",
            "eventId": 9,
            "callbackBatchSequence": 1,
            "callbackRecordSequence": 1,
        }
        self.classified_record = {
            "recordType": "classified-darwin-fsevents",
            "epoch_us": 151,
            "path": str(self.source),
            "flags": ["IsFile"],
            "included": True,
            "material": False,
            "scope": "exact-file",
            "ignoredReason": None,
            "violates": False,
            "eventId": 9,
            "callbackBatchSequence": 1,
            "callbackRecordSequence": 1,
        }
        self.ready = self.root / "ready.json"
        self.result = self.root / "result.json"
        self.events = self.root / "events.jsonl"
        self._write_fixture()

    def _write_fixture(self) -> None:
        _write_json(self.ready, self.ready_value)
        _write_json(self.result, self.result_value)
        self.events.write_text(
            "".join(
                json.dumps(record, sort_keys=True) + "\n"
                for record in (self.raw_record, self.classified_record)
            ),
            encoding="utf-8",
        )

    def _validate(self) -> dict[str, object]:
        return validator.validate_completed_guard_evidence(
            self.result,
            self.events,
            self.ready,
            self.manifest,
            self.sidecar,
        )

    @staticmethod
    def _ordered_paths(*paths: pathlib.Path) -> list[str]:
        return sorted(
            {str(path) for path in paths},
            key=lambda item: (len(pathlib.Path(item).parts), item),
        )

    def test_accepts_complete_small_fixture(self) -> None:
        self.assertEqual(
            self._validate(),
            {
                "status": "stopped",
                "observedEventCount": 1,
                "baselineUniqueRegularFileCount": 1,
                "unchangedTreeVerified": True,
            },
        )

    def test_accepts_required_watch_paths_deleted_after_guard(self) -> None:
        deleted_native_root = self.root / "deleted-gradle-distribution"
        deleted_watch_path = deleted_native_root / "lib" / "gradle.jar"
        self.ready_value["watchPaths"] = self._ordered_paths(
            self.source, deleted_watch_path
        )
        self.ready_value["nativeFSEventsWatchRoots"] = self._ordered_paths(
            self.source, deleted_native_root
        )
        self._write_fixture()
        self.assertTrue(self._validate()["unchangedTreeVerified"])

    def test_rejects_noncanonical_missing_watch_path(self) -> None:
        noncanonical = str(self.root / "deleted" / "..")
        self.ready_value["watchPaths"] = [noncanonical]
        self.ready_value["nativeFSEventsWatchRoots"] = [noncanonical]
        self._write_fixture()
        with self.assertRaisesRegex(validator.EvidenceValidationError, "invalid path"):
            self._validate()

    def test_rejects_missing_watch_path_through_symlink(self) -> None:
        external = self.root / "external"
        external.mkdir()
        symlink = self.root / "redirect"
        symlink.symlink_to(external, target_is_directory=True)
        escaped = str(symlink / "deleted-gradle.jar")
        self.ready_value["watchPaths"] = [escaped]
        self.ready_value["nativeFSEventsWatchRoots"] = [escaped]
        self._write_fixture()
        with self.assertRaisesRegex(
            validator.EvidenceValidationError, "non-canonical path"
        ):
            self._validate()

    def test_rejects_control_character_in_missing_watch_path(self) -> None:
        unsafe = str(self.root / "deleted\npath")
        self.ready_value["watchPaths"] = [unsafe]
        self.ready_value["nativeFSEventsWatchRoots"] = [unsafe]
        self._write_fixture()
        with self.assertRaisesRegex(validator.EvidenceValidationError, "invalid path"):
            self._validate()

    def test_rejects_arbitrary_synthetic_result(self) -> None:
        self.result_value["startedEpochUs"] = 99
        _write_json(self.result, self.result_value)
        with self.assertRaisesRegex(
            validator.EvidenceValidationError, "start timestamps"
        ):
            self._validate()

    def test_rejects_duplicate_json_key(self) -> None:
        encoded = json.dumps(self.result_value, sort_keys=True)
        self.result.write_text(
            encoded[:-1] + ',"nonce":"0123456789abcdef0123456789abcdef"}\n',
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            validator.EvidenceValidationError, "duplicate JSON key"
        ):
            self._validate()

    def test_rejects_duplicate_ledger_json_key(self) -> None:
        raw = json.dumps(self.raw_record, sort_keys=True)
        raw = raw[:-1] + ',"eventId":9}'
        self.events.write_text(
            raw + "\n" + json.dumps(self.classified_record, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            validator.EvidenceValidationError, "duplicate JSON key"
        ):
            self._validate()

    def test_rejects_ledger_pair_mismatch(self) -> None:
        self.classified_record["path"] = str(self.root / "different.txt")
        self._write_fixture()
        with self.assertRaisesRegex(
            validator.EvidenceValidationError, "identity or flags"
        ):
            self._validate()

    def test_rejects_attestation_mismatch(self) -> None:
        self.ready_value["baselineManifestSha256"] = "0" * 64
        self._write_fixture()
        with self.assertRaisesRegex(
            validator.EvidenceValidationError, "does not match baseline"
        ):
            self._validate()


if __name__ == "__main__":
    unittest.main()
