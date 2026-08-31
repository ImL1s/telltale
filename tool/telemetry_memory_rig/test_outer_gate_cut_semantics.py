from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import shutil
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path


HERE = Path(__file__).resolve().parent


def _load(name: str, path: Path):
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"could not load {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


verifier = _load("test_outer_gate_cut_verifier", HERE / "outer_gate_result_verifier.py")
gate = _load("test_outer_gate_cut_helper", HERE / "gate_c_validate.py")


def _write(path: Path, value: bytes | str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(value.encode() if isinstance(value, str) else value)
    path.chmod(0o600)


def _private_directories(root: Path) -> None:
    for path in (root, *root.rglob("*")):
        if path.is_dir():
            path.chmod(0o700)


def _tar(
    path: Path, source_name: str, source: bytes, ledger_name: str, ledger: bytes
) -> None:
    with tarfile.open(path, "w") as stream:
        directory = tarfile.TarInfo("telltale-app-shares/")
        directory.type = tarfile.DIRTYPE
        stream.addfile(directory)
        for name, value in ((source_name, source), (ledger_name, ledger)):
            item = tarfile.TarInfo(f"telltale-app-shares/{name}")
            item.size = len(value)
            stream.addfile(item, io.BytesIO(value))
    path.chmod(0o600)


def _driver_exit(recovery: bool) -> str:
    natural, term, kill = (120000, 5000, 5000) if recovery else (30000, 2000, 2000)
    exit_code = 0 if recovery else 1
    label = "gate-recovery-driver" if recovery else "gate-seed-driver"
    return (
        "version=1\n"
        f"label={label}\n"
        "pid=321\n"
        "start_monotonic_ns=1000000\n"
        "end_monotonic_ns=3000000\n"
        "elapsed_ms=2\n"
        f"natural_timeout_ms={natural}\n"
        f"term_timeout_ms={term}\n"
        f"kill_timeout_ms={kill}\n"
        "natural_exit_observed=true\n"
        "term_sent=false\n"
        "kill_sent=false\n"
        "forced_host_termination=none\n"
        "outcome=natural_exit\n"
        f"exit_code={exit_code}\n"
        "clock_failure=false\n"
        "clock_failure_stage=none\n"
    )


class OuterGateCutSemanticsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve(strict=True)
        self.rig = self.root / "app" / "tool" / "telemetry_memory_rig"
        self.evidence = self.root / "evidence"
        self.rig.mkdir(parents=True)
        self.evidence.mkdir()
        self.helper = self.rig / "gate_c_validate.py"
        shutil.copyfile(HERE / "gate_c_validate.py", self.helper)
        self.helper.chmod(0o600)
        helper_sha = hashlib.sha256(self.helper.read_bytes()).hexdigest()
        _write(
            self.evidence / "tested-files.post.sha256",
            f"{helper_sha}  tool/telemetry_memory_rig/gate_c_validate.py\n",
        )
        _write(
            self.evidence / "identity.txt",
            "serial=DEVICE123\npackage=com.cbstudio.telltale.rig\n",
        )
        (self.evidence / "cuts").mkdir()
        (self.evidence / "process-scope-authorities").mkdir()
        (self.evidence / "process-scope-reference-authorities").mkdir()
        self.scope_roots = {"gradleUserHome": str(self.root / "gradle")}
        self.owner = {
            "pid": 90,
            "ppid": 1,
            "uid": __import__("os").getuid(),
            "pgid": 90,
            "sid": 90,
            "startSec": 1,
            "startUsec": 0,
        }
        self.subject = {**self.owner, "pid": 91, "ppid": 90, "pgid": 91, "sid": 91}
        executable = self.root / "python3"
        program = self.root / "source_tree_guard.py"
        _write(executable, "python\n")
        _write(program, "guard\n")
        ready_path = self.evidence / "source-tree-guard-ready.json"
        nonce = "f" * 32
        _write(ready_path, json.dumps({"pid": 91, "nonce": nonce}) + "\n")
        readiness = {
            "path": str(ready_path),
            "sha256": hashlib.sha256(ready_path.read_bytes()).hexdigest(),
            "nonce": nonce,
            "stopPath": str(self.evidence / "source-tree-guard.stop"),
            "resultPath": str(self.evidence / "source-tree-guard-result.json"),
        }
        self.reference_path = (
            self.evidence
            / "process-scope-reference-authorities"
            / "source-guard.reference-authority.json"
        )
        reference = {
            "version": 1,
            "kind": "source-guard-reference-exemption",
            "exemptionId": "e" * 32,
            "ownerRoot": self.owner,
            "subject": self.subject,
            "executable": {
                "path": str(executable),
                "sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
            },
            "program": {
                "path": str(program),
                "sha256": hashlib.sha256(program.read_bytes()).hexdigest(),
            },
            "argv": [str(executable), "-I", "-S", "-B", str(program)],
            "readiness": readiness,
            "roots": self.scope_roots,
            "allowedRootKeys": ["gradleUserHome"],
        }
        _write(self.reference_path, json.dumps(reference, sort_keys=True) + "\n")
        self.reference_entry = {
            "path": str(self.reference_path),
            "sha256": hashlib.sha256(self.reference_path.read_bytes()).hexdigest(),
            "exemptionId": "e" * 32,
        }
        self.reference_exemption = {
            "exemptionId": "e" * 32,
            "process": {"identity": self.subject},
            "reasons": ["gradleUserHome:open-vnode"],
        }
        for cut in verifier.CUTS:
            self._write_cut(cut)
        _private_directories(self.root)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _write_scoped_result(self, label: str, status: str) -> None:
        authority_path = (
            self.evidence
            / "process-scope-authorities"
            / f"{label}.process-authority.json"
        )
        scope_path = self.evidence / f"{label}.process-scope.json"
        result_path = self.evidence / f"{label}.scoped-command.json"
        authority = {"ownerRoot": self.owner, "leader": {"pid": 123}}
        scope = {
            "status": "quiescent",
            "roots": self.scope_roots,
            "remainingOwnedProcesses": [],
            "foreignProcesses": [],
            "referenceAuthorities": [self.reference_entry],
            "referenceExemptProcesses": [self.reference_exemption],
            "inspectionLimitations": [],
        }
        _write(authority_path, json.dumps(authority) + "\n")
        _write(scope_path, json.dumps(scope) + "\n")
        result = {
            "version": 1,
            "label": label,
            "status": status,
            "commandExitCode": 0 if status == "completed" else 1,
            "authority": authority,
            "scopeTermination": scope,
            "authoritySha256": hashlib.sha256(authority_path.read_bytes()).hexdigest(),
            "childPid": 123,
            "scopeEvidenceSha256": hashlib.sha256(scope_path.read_bytes()).hexdigest(),
        }
        _write(result_path, json.dumps(result, sort_keys=True) + "\n")

    def _write_cut(self, cut: str) -> None:
        cut_dir = self.evidence / "cuts" / cut
        cut_dir.mkdir()
        _write(
            cut_dir / "fresh-install-precondition.txt",
            "serial=DEVICE123\n"
            "device_state=device\n"
            "rig_path_before=absent\n"
            "rig_pid_before=absent\n"
            "force_stop=not-needed\n"
            "uninstall=not-needed\n"
            "rig_path_after=absent\n"
            "rig_pid_after=absent\n",
        )
        identifier = gate.IDS[cut]
        raw = cut in {"allocated", "sourceVerified", "handedOffBeforePlatform"}
        handed = cut not in {"allocated", "sourceVerified"}
        source = f"source:{cut}".encode()
        source_name = f"{identifier}.{'txt' if raw else 'csv'}.share"
        ledger_name = f"{identifier}.lease.json"
        fingerprint = gate._fnv(source)
        ack = {
            "version": 1,
            "runToken": hashlib.md5(cut.encode()).hexdigest(),
            "phase": "realPluginMirror" if cut == "realPluginMirror" else "seed",
            "cut": cut,
            "id": identifier,
            "state": "handedOffLease" if handed else "allocated",
            "sourceKind": "rawTranscript" if raw else "pidCsv",
            "sourceFileName": source_name,
            "ledgerFileName": ledger_name,
            "bytes": None if cut == "allocated" else len(source),
            "fingerprint": None if cut == "allocated" else fingerprint,
            "result": "pending" if handed else None,
            "platformCalls": 1
            if cut
            in {"platformInvoked", "pendingResult", "neverResult", "realPluginMirror"}
            else 0,
            "platformSemantic": {
                "allocated": "notInvoked",
                "sourceVerified": "notInvoked",
                "handedOffBeforePlatform": "notInvoked",
                "platformInvoked": "invokedBeforeAwait",
                "pendingResult": "completablePending",
                "neverResult": "nonCompletablePending",
                "realPluginMirror": "realPluginInvoked",
            }[cut],
            "pendingObservationMs": {"pendingResult": 2000, "neverResult": 5000}.get(
                cut, 0
            ),
            "gateIdle": False,
            "secondShareError": "shareBusy",
            "crossFeatureDenied": True,
        }
        ledger = {
            "version": 1,
            "id": identifier,
            "sourceKind": ack["sourceKind"],
            "extension": "txt" if raw else "csv",
            "mimeType": "text/plain" if raw else "text/csv",
            "state": ack["state"],
            "createdAtUtc": "2026-08-30T00:00:00.000Z",
        }
        if handed:
            ledger.update(
                {
                    "bytes": len(source),
                    "fingerprint": fingerprint,
                    "handedOffAtUtc": "2026-08-30T00:00:01.000Z",
                    "cleanupEligibleAtUtc": "2026-08-30T00:15:01.000Z",
                    "cleanupDueAtUtc": "2026-08-31T00:00:01.000Z",
                    "result": "pending",
                }
            )
        ledger_bytes = json.dumps(
            ledger, sort_keys=True, separators=(",", ":")
        ).encode()
        ack_path = cut_dir / "ack.json"
        _write(ack_path, json.dumps(ack, sort_keys=True, separators=(",", ":")) + "\n")
        pre_tar = cut_dir / "pre-kill-app-staging.tar"
        post_tar = cut_dir / "post-kill-app-staging.tar"
        _tar(pre_tar, source_name, source, ledger_name, ledger_bytes)
        _tar(post_tar, source_name, source, ledger_name, ledger_bytes)
        pre = gate.build_manifest(pre_tar, ack_path, ack["runToken"], cut)
        restore = gate.build_manifest(post_tar, ack_path, ack["runToken"], cut)
        _write(cut_dir / "pre-kill-manifest.json", json.dumps(pre) + "\n")
        _write(cut_dir / "restore-manifest.json", json.dumps(restore) + "\n")
        _write(
            cut_dir / "post-kill-files.sha256",
            f"{restore['sourceSha256']}  {source_name}\n"
            f"{restore['ledgerSha256']}  {ledger_name}\n",
        )
        _write(cut_dir / "pre-kill-ledger.json", ledger_bytes)
        staging_lines = sorted(
            (
                f"cache/telltale-app-shares/{source_name} {len(source)}\n",
                f"cache/telltale-app-shares/{ledger_name} {len(ledger_bytes)}\n",
            )
        )
        _write(cut_dir / "pre-kill-app-staging.txt", "".join(staging_lines))
        if cut != "allocated":
            _write(cut_dir / "pre-kill-source.bin", source)
            _write(
                cut_dir / "pre-kill-source-parity.txt",
                f"bytes={len(source)}\nfingerprint={fingerprint}\n",
            )
        _write(
            cut_dir / "ack-process-identity.txt",
            "pid=700\nuid=10000\npackage=com.cbstudio.telltale.rig\n"
            "cmdline=com.cbstudio.telltale.rig\n"
            "package_path=package:/data/app/rig/base.apk\n",
        )
        _write(
            cut_dir / "force-stop-command.txt",
            "before_epoch_ns=10\n"
            "command=adb -s DEVICE123 shell am force-stop com.cbstudio.telltale.rig\n"
            "exit_code=0\nafter_epoch_ns=11\nbefore_pid=700\nbefore_uid=10000\n"
            "before_cmdline=com.cbstudio.telltale.rig\nafter_pid=\n",
        )
        _write(cut_dir / "seed-driver-exit.txt", _driver_exit(False))
        _write(cut_dir / "recovery-driver-exit.txt", _driver_exit(True))
        seed_phase = "realpluginmirror" if cut == "realPluginMirror" else "seed"
        self._write_scoped_result(f"gate-{seed_phase}-{cut.lower()}", "command_failed")
        self._write_scoped_result(f"gate-recover-{cut.lower()}", "completed")
        _write(
            cut_dir / "recovery-process-identity.txt",
            "pid=701\nuid=10001\npackage=com.cbstudio.telltale.rig\n"
            "cmdline=com.cbstudio.telltale.rig\n"
            "package_path=package:/data/app/rig/base.apk\n",
        )
        retained = cut in verifier.RETAINED_GATE_CUTS
        inventory = cut_dir / "post-recovery-inventory.canonical"
        inventory_text = ""
        if retained:
            inventory_text = "".join(staging_lines)
        _write(cut_dir / "post-recovery-app-staging.txt", inventory_text)
        _write(cut_dir / "post-recovery-app-staging.stderr", b"")
        _write(inventory, inventory_text)
        inventory_sha = hashlib.sha256(inventory.read_bytes()).hexdigest()
        _write(
            cut_dir / "post-recovery-inventory.sha256",
            f"{inventory_sha}  {inventory}\n",
        )
        reconstruction = {
            "version": 1,
            "runToken": restore["runToken"],
            "cut": cut,
            "archiveSha256": restore["archiveSha256"],
            "sourceSha256": restore["sourceSha256"],
            "ledgerSha256": restore["ledgerSha256"],
            "platformCalls": restore["platformCalls"],
            "platformSemantic": restore["platformSemantic"],
            "pendingObservationMs": restore["pendingObservationMs"],
            "postRecoveryInventorySha256": inventory_sha,
            "classification": "retained" if retained else "cleaned",
            "verified": True,
        }
        _write(cut_dir / "reconstruction.json", json.dumps(reconstruction) + "\n")
        if retained:
            post_ledger = cut_dir / "post-recovery-ledger.json"
            post_source = cut_dir / "post-recovery-source.bin"
            _write(post_ledger, ledger_bytes)
            _write(post_source, source)
            _write(
                cut_dir / "post-recovery.sha256",
                f"{restore['ledgerSha256']}  {post_ledger}\n"
                f"{restore['sourceSha256']}  {post_source}\n",
            )
            _write(
                cut_dir / "post-recovery-fnv.txt",
                f"bytes={len(source)}\nfingerprint={fingerprint}\n",
            )
        _write(
            cut_dir / "seed.log",
            "TELLTALE_GATE_C_COMMAND_READY\n"
            f"TELLTALE_GATE_C_CUT_READY token={ack['runToken']} cut={cut}\n",
        )
        _write(
            cut_dir / "recovery.log",
            f"TELLTALE_GATE_C_RESTORE_READY token={ack['runToken']}\n"
            f"TELLTALE_GATE_C_RECOVERY_VERIFIED token={ack['runToken']} cut={cut}\n",
        )
        if cut == "realPluginMirror":
            plugin = cut_dir / "plugin-observed"
            plugin.mkdir()
            plugin_name = "mirror.csv"
            _write(
                plugin / "listing.txt",
                f"cache/share_plus/{plugin_name} {len(source)}\n",
            )
            _write(plugin / "ledger-at-observation.json", ledger_bytes)
            source_sha = hashlib.sha256(source).hexdigest()
            _write(
                plugin / "parity.txt",
                f"staged_sha256={source_sha}\nplugin_sha256={source_sha}\n"
                f"bytes={len(source)}\nprocess=700\n",
            )
            mirror = plugin / "mirror.tar"
            with tarfile.open(mirror, "w") as stream:
                directory = tarfile.TarInfo("share_plus/")
                directory.type = tarfile.DIRTYPE
                stream.addfile(directory)
                item = tarfile.TarInfo(f"share_plus/{plugin_name}")
                item.size = len(source)
                stream.addfile(item, io.BytesIO(source))
            mirror.chmod(0o600)
            mirror_sha = hashlib.sha256(mirror.read_bytes()).hexdigest()
            _write(plugin / "mirror.sha256", f"{mirror_sha}  {mirror}\n")

    def test_accepts_complete_producer_schema_fixture(self) -> None:
        verifier._verify_gate_cut_semantics(self.evidence, self.rig)

    def test_rejects_legacy_seed_reap_timeout_without_containment_headroom(
        self,
    ) -> None:
        target = self.evidence / "cuts" / "allocated" / "seed-driver-exit.txt"
        _write(
            target,
            target.read_text().replace(
                "natural_timeout_ms=30000", "natural_timeout_ms=10000"
            ),
        )
        with self.assertRaisesRegex(verifier.VerificationError, "driver exit"):
            verifier._verify_gate_cut_semantics(self.evidence, self.rig)

    def test_rejects_hash_consistent_reconstruction_forgery(self) -> None:
        target = self.evidence / "cuts" / "neverResult" / "reconstruction.json"
        value = json.loads(target.read_text())
        value["classification"] = "cleaned"
        _write(target, json.dumps(value) + "\n")
        with self.assertRaisesRegex(verifier.VerificationError, "reconstruction"):
            verifier._verify_gate_cut_semantics(self.evidence, self.rig)

    def test_rejects_force_stop_forgery(self) -> None:
        target = self.evidence / "cuts" / "allocated" / "force-stop-command.txt"
        _write(target, target.read_text().replace("after_pid=\n", "after_pid=700\n"))
        with self.assertRaisesRegex(verifier.VerificationError, "force-stop"):
            verifier._verify_gate_cut_semantics(self.evidence, self.rig)

    def test_rejects_plugin_parity_forgery(self) -> None:
        parity = (
            self.evidence
            / "cuts"
            / "realPluginMirror"
            / "plugin-observed"
            / "parity.txt"
        )
        _write(parity, parity.read_text().replace("staged_sha256=", "staged_sha256=0"))
        with self.assertRaisesRegex(verifier.VerificationError, "mirror parity"):
            verifier._verify_gate_cut_semantics(self.evidence, self.rig)

    def test_rejects_duplicate_ack_keys(self) -> None:
        target = self.evidence / "cuts" / "platformInvoked" / "ack.json"
        text = target.read_text()
        _write(target, text[:-2] + ',"version":1}\n')
        with self.assertRaisesRegex(verifier.VerificationError, "duplicate JSON key"):
            verifier._verify_gate_cut_semantics(self.evidence, self.rig)

    def test_rejects_forged_fresh_install_precondition(self) -> None:
        target = (
            self.evidence / "cuts" / "sourceVerified" / "fresh-install-precondition.txt"
        )
        _write(
            target,
            target.read_text().replace("rig_pid_after=absent", "rig_pid_after=700"),
        )
        with self.assertRaisesRegex(verifier.VerificationError, "fresh-install"):
            verifier._verify_gate_cut_semantics(self.evidence, self.rig)

    def test_rejects_canonical_inventory_not_derived_from_raw_probe(self) -> None:
        target = (
            self.evidence / "cuts" / "pendingResult" / "post-recovery-app-staging.txt"
        )
        _write(target, "")
        with self.assertRaisesRegex(verifier.VerificationError, "sorted raw"):
            verifier._verify_gate_cut_semantics(self.evidence, self.rig)

    def test_rejects_pre_kill_staging_not_derived_from_archive(self) -> None:
        target = self.evidence / "cuts" / "neverResult" / "pre-kill-app-staging.txt"
        _write(target, target.read_text() + "cache/telltale-app-shares/extra 1\n")
        with self.assertRaisesRegex(verifier.VerificationError, "pre-kill staging"):
            verifier._verify_gate_cut_semantics(self.evidence, self.rig)

    def test_rejects_recovery_inventory_stderr(self) -> None:
        target = (
            self.evidence / "cuts" / "allocated" / "post-recovery-app-staging.stderr"
        )
        _write(target, "permission denied\n")
        with self.assertRaisesRegex(verifier.VerificationError, "emitted stderr"):
            verifier._verify_gate_cut_semantics(self.evidence, self.rig)


if __name__ == "__main__":
    unittest.main()
