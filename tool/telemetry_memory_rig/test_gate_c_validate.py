import io
import json
import pathlib
import tarfile
import tempfile
import unittest

from gate_c_validate import (
    _fnv,
    build_manifest,
    inspect_archive,
    revalidate_manifest,
    validate_ack,
)


ID = "44000000000000000000000000000004"


def fixture(root: pathlib.Path):
    source = b"pid-bytes"
    fingerprint = _fnv(source)
    ledger = {
        "version": 1,
        "id": ID,
        "sourceKind": "pidCsv",
        "extension": "csv",
        "mimeType": "text/csv",
        "state": "handedOffLease",
        "createdAtUtc": "2026-08-30T00:00:00.000Z",
        "bytes": len(source),
        "fingerprint": fingerprint,
        "handedOffAtUtc": "2026-08-30T00:00:01.000Z",
        "cleanupEligibleAtUtc": "2026-08-30T00:15:01.000Z",
        "cleanupDueAtUtc": "2026-08-31T00:00:01.000Z",
        "result": "pending",
    }
    ack = {
        "version": 1,
        "runToken": "a" * 32,
        "phase": "seed",
        "cut": "platformInvoked",
        "id": ID,
        "sourceKind": "pidCsv",
        "state": "handedOffLease",
        "sourceFileName": f"{ID}.csv.share",
        "ledgerFileName": f"{ID}.lease.json",
        "bytes": len(source),
        "fingerprint": fingerprint,
        "result": "pending",
        "platformCalls": 1,
        "platformSemantic": "invokedBeforeAwait",
        "pendingObservationMs": 0,
        "gateIdle": False,
        "secondShareError": "shareBusy",
        "crossFeatureDenied": True,
    }
    ack_path = root / "ack.json"
    ack_path.write_text(json.dumps(ack))
    archive = root / "group.tar"
    write_archive(archive, ack, ledger, source)
    return archive, ack_path, ack, ledger, source


def write_archive(
    archive,
    ack,
    ledger,
    source,
    *,
    extra=None,
    symlink=False,
    ledger_bytes=None,
):
    with tarfile.open(archive, "w") as stream:
        directory = tarfile.TarInfo("telltale-app-shares/")
        directory.type = tarfile.DIRTYPE
        stream.addfile(directory)
        for name, data in (
            (ack["sourceFileName"], source),
            (
                ack["ledgerFileName"],
                json.dumps(ledger).encode() if ledger_bytes is None else ledger_bytes,
            ),
        ):
            item = tarfile.TarInfo("telltale-app-shares/" + name)
            item.size = len(data)
            stream.addfile(item, io.BytesIO(data))
        if extra:
            item = tarfile.TarInfo("telltale-app-shares/" + extra)
            item.size = 1
            stream.addfile(item, io.BytesIO(b"x"))
        if symlink:
            item = tarfile.TarInfo("telltale-app-shares/link")
            item.type = tarfile.SYMTYPE
            item.linkname = "/tmp/x"
            stream.addfile(item)


class GateCValidateTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_valid_group_builds_token_bound_manifest(self):
        archive, ack_path, ack, _, _ = fixture(self.root)
        manifest = build_manifest(archive, ack_path, "a" * 32, "platformInvoked")
        self.assertEqual(manifest["runToken"], "a" * 32)
        self.assertEqual(manifest["sourceBytes"], ack["bytes"])
        self.assertEqual(manifest["platformCalls"], 1)
        self.assertEqual(manifest["platformSemantic"], "invokedBeforeAwait")
        self.assertEqual(manifest["pendingObservationMs"], 0)

    def test_extra_member_and_link_cannot_false_pass(self):
        archive, ack_path, ack, ledger, source = fixture(self.root)
        write_archive(archive, ack, ledger, source, extra="extra.tmp")
        with self.assertRaises(ValueError):
            inspect_archive(archive, ack, "platformInvoked")
        write_archive(archive, ack, ledger, source, symlink=True)
        with self.assertRaises(ValueError):
            inspect_archive(archive, ack, "platformInvoked")

    def test_ledger_schema_and_source_mismatch_cannot_false_pass(self):
        archive, ack_path, ack, ledger, source = fixture(self.root)
        ledger["extra"] = True
        write_archive(archive, ack, ledger, source)
        with self.assertRaises(ValueError):
            inspect_archive(archive, ack, "platformInvoked")
        ledger.pop("extra")
        write_archive(archive, ack, ledger, source + b"changed")
        with self.assertRaises(ValueError):
            inspect_archive(archive, ack, "platformInvoked")

    def test_invalid_token_cannot_build_manifest(self):
        archive, ack_path, _, _, _ = fixture(self.root)
        with self.assertRaises(ValueError):
            build_manifest(archive, ack_path, "../token", "platformInvoked")

    def test_valid_but_different_token_cannot_build_manifest(self):
        archive, ack_path, _, _, _ = fixture(self.root)
        with self.assertRaises(ValueError):
            build_manifest(archive, ack_path, "b" * 32, "platformInvoked")

    def test_wrong_cleanup_intervals_cannot_false_pass(self):
        archive, _, ack, ledger, source = fixture(self.root)
        for field, wrong in (
            ("cleanupEligibleAtUtc", "2026-08-30T00:14:01.000Z"),
            ("cleanupDueAtUtc", "2026-08-30T23:00:01.000Z"),
        ):
            changed = dict(ledger)
            changed[field] = wrong
            write_archive(archive, ack, changed, source)
            with self.assertRaises(ValueError):
                inspect_archive(archive, ack, "platformInvoked")

    def test_noncanonical_utc_serialization_cannot_false_pass(self):
        archive, _, ack, ledger, source = fixture(self.root)
        for wrong in (
            "2026-08-30T00:00:01.000+00:00",
            "2026-08-30T00:00:01.000000Z",
        ):
            changed = dict(ledger)
            changed["handedOffAtUtc"] = wrong
            write_archive(archive, ack, changed, source)
            with self.assertRaises(ValueError):
                inspect_archive(archive, ack, "platformInvoked")

    def test_ack_without_ownership_proof_cannot_false_pass(self):
        archive, _, ack, _, _ = fixture(self.root)
        ack["crossFeatureDenied"] = False
        with self.assertRaises(ValueError):
            inspect_archive(archive, ack, "platformInvoked")

    def test_boolean_ack_numeric_fields_cannot_false_pass(self):
        archive, _, ack, _, _ = fixture(self.root)
        for field in (
            "version",
            "platformCalls",
            "pendingObservationMs",
            "bytes",
        ):
            changed = dict(ack)
            changed[field] = True
            with self.assertRaises(ValueError):
                inspect_archive(archive, changed, "platformInvoked")

    def test_cut_platform_semantic_is_exact_and_required(self):
        archive, _, ack, _, _ = fixture(self.root)
        for semantic in (
            "notInvoked",
            "completablePending",
            "nonCompletablePending",
            "realPluginInvoked",
            "invokedBeforeAwait ",
        ):
            changed = dict(ack, platformSemantic=semantic)
            with self.assertRaises(ValueError):
                inspect_archive(archive, changed, "platformInvoked")
        changed = dict(ack)
        changed.pop("platformSemantic")
        with self.assertRaises(ValueError):
            inspect_archive(archive, changed, "platformInvoked")

    def test_pending_cut_minimums_are_fail_closed(self):
        _, _, ack, _, _ = fixture(self.root)
        cases = (
            ("pendingResult", "completablePending", 1999),
            ("neverResult", "nonCompletablePending", 4999),
        )
        for cut, semantic, observation in cases:
            changed = dict(
                ack,
                cut=cut,
                id={
                    "pendingResult": "55000000000000000000000000000005",
                    "neverResult": "66000000000000000000000000000006",
                }[cut],
                platformSemantic=semantic,
                pendingObservationMs=observation,
            )
            changed["sourceFileName"] = f"{changed['id']}.csv.share"
            changed["ledgerFileName"] = f"{changed['id']}.lease.json"
            with self.assertRaises(ValueError):
                validate_ack(changed, cut)

            changed["pendingObservationMs"] = observation + 1
            validate_ack(changed, cut)

    def test_every_cut_requires_its_exact_semantic_calls_and_minimum(self):
        _, _, base, _, _ = fixture(self.root)
        cases = {
            "allocated": ("notInvoked", 0, 0),
            "sourceVerified": ("notInvoked", 0, 0),
            "handedOffBeforePlatform": ("notInvoked", 0, 0),
            "platformInvoked": ("invokedBeforeAwait", 1, 0),
            "pendingResult": ("completablePending", 1, 2000),
            "neverResult": ("nonCompletablePending", 1, 5000),
            "realPluginMirror": ("realPluginInvoked", 1, 0),
        }
        ids = {
            "allocated": "11000000000000000000000000000001",
            "sourceVerified": "22000000000000000000000000000002",
            "handedOffBeforePlatform": "33000000000000000000000000000003",
            "platformInvoked": "44000000000000000000000000000004",
            "pendingResult": "55000000000000000000000000000005",
            "neverResult": "66000000000000000000000000000006",
            "realPluginMirror": "77000000000000000000000000000007",
        }
        for cut, (semantic, calls, observation) in cases.items():
            raw = cut in {
                "allocated",
                "sourceVerified",
                "handedOffBeforePlatform",
            }
            handed = cut not in {"allocated", "sourceVerified"}
            identifier = ids[cut]
            changed = dict(
                base,
                phase="realPluginMirror" if cut == "realPluginMirror" else "seed",
                cut=cut,
                id=identifier,
                sourceKind="rawTranscript" if raw else "pidCsv",
                state="handedOffLease" if handed else "allocated",
                sourceFileName=f"{identifier}.{'txt' if raw else 'csv'}.share",
                ledgerFileName=f"{identifier}.lease.json",
                bytes=base["bytes"] if cut != "allocated" else None,
                fingerprint=base["fingerprint"] if cut != "allocated" else None,
                result="pending" if handed else None,
                platformCalls=calls,
                platformSemantic=semantic,
                pendingObservationMs=observation,
            )
            validate_ack(changed, cut)
            with self.assertRaises(ValueError):
                validate_ack(dict(changed, platformCalls=calls + 1), cut)
            with self.assertRaises(ValueError):
                validate_ack(dict(changed, platformSemantic=semantic + "x"), cut)

    def test_non_pending_cut_rejects_fabricated_observation(self):
        archive, _, ack, _, _ = fixture(self.root)
        changed = dict(ack, pendingObservationMs=1)
        with self.assertRaises(ValueError):
            inspect_archive(archive, changed, "platformInvoked")

    def test_boolean_ledger_numeric_fields_cannot_false_pass(self):
        archive, _, ack, ledger, _ = fixture(self.root)
        changed = dict(ledger)
        changed["version"] = True
        write_archive(archive, ack, changed, b"pid-bytes")
        with self.assertRaises(ValueError):
            inspect_archive(archive, ack, "platformInvoked")

        source = b"x"
        ack = dict(ack, bytes=1, fingerprint=_fnv(source))
        changed = dict(ledger, bytes=True, fingerprint=_fnv(source))
        write_archive(archive, ack, changed, source)
        with self.assertRaises(ValueError):
            inspect_archive(archive, ack, "platformInvoked")

    def test_changed_archive_or_token_cannot_revalidate_manifest(self):
        archive, ack_path, ack, ledger, source = fixture(self.root)
        manifest = build_manifest(archive, ack_path, "a" * 32, "platformInvoked")
        revalidate_manifest(archive, ack_path, "a" * 32, "platformInvoked", manifest)
        write_archive(archive, ack, ledger, source + b"changed")
        with self.assertRaises(ValueError):
            revalidate_manifest(
                archive, ack_path, "a" * 32, "platformInvoked", manifest
            )
        write_archive(archive, ack, ledger, source)
        with self.assertRaises(ValueError):
            revalidate_manifest(
                archive, ack_path, "b" * 32, "platformInvoked", manifest
            )

    def test_duplicate_ack_and_ledger_keys_are_rejected(self):
        archive, ack_path, ack, ledger, source = fixture(self.root)
        ack_text = json.dumps(ack)
        ack_path.write_text(ack_text[:-1] + ',"runToken":"' + "a" * 32 + '"}')
        with self.assertRaisesRegex(ValueError, "duplicate JSON key"):
            build_manifest(archive, ack_path, "a" * 32, "platformInvoked")

        ack_path.write_text(json.dumps(ack))
        ledger_text = json.dumps(ledger)
        write_archive(
            archive,
            ack,
            ledger,
            source,
            ledger_bytes=(ledger_text[:-1] + ',"version":1}').encode(),
        )
        with self.assertRaisesRegex(ValueError, "duplicate JSON key"):
            inspect_archive(archive, ack, "platformInvoked")


if __name__ == "__main__":
    unittest.main()
