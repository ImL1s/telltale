#!/usr/bin/env python3
import argparse
import datetime
import hashlib
import json
import pathlib
import re
import tarfile


SOURCE_LIMIT = 32 * 1024 * 1024
FNV_PATTERN = re.compile(r"^fnv1a64:[0-9a-f]{16}$")
TOKEN_PATTERN = re.compile(r"^[0-9a-f]{32}$")
UTC_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}(?:\d{3})?Z$")
IDS = {
    "allocated": "11000000000000000000000000000001",
    "sourceVerified": "22000000000000000000000000000002",
    "handedOffBeforePlatform": "33000000000000000000000000000003",
    "platformInvoked": "44000000000000000000000000000004",
    "pendingResult": "55000000000000000000000000000005",
    "neverResult": "66000000000000000000000000000006",
    "realPluginMirror": "77000000000000000000000000000007",
}
ACK_KEYS = {
    "version",
    "runToken",
    "phase",
    "cut",
    "id",
    "state",
    "sourceKind",
    "sourceFileName",
    "ledgerFileName",
    "bytes",
    "fingerprint",
    "result",
    "platformCalls",
    "platformSemantic",
    "pendingObservationMs",
    "gateIdle",
    "secondShareError",
    "crossFeatureDenied",
}


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def _decode_json(raw: bytes | str) -> dict:
    value = json.loads(raw, object_pairs_hook=_reject_duplicate_keys)
    if not isinstance(value, dict):
        raise ValueError("JSON root must be an object")
    return value


def _load_json(path: pathlib.Path) -> dict:
    return _decode_json(path.read_bytes())


def _fnv(data: bytes) -> str:
    value = 0xCBF29CE484222325
    for byte in data:
        value ^= byte
        value = (value * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return f"fnv1a64:{value:016x}"


def _parse_utc(value: object) -> datetime.datetime:
    if not isinstance(value, str) or not UTC_PATTERN.fullmatch(value):
        raise ValueError("ledger timestamp is not canonical UTC")
    parsed = datetime.datetime.fromisoformat(value[:-1] + "+00:00")
    if parsed.utcoffset() != datetime.timedelta(0):
        raise ValueError("ledger timestamp is not UTC")
    fraction = (
        f"{parsed.microsecond:06d}"
        if parsed.microsecond % 1000
        else f"{parsed.microsecond // 1000:03d}"
    )
    canonical = parsed.strftime("%Y-%m-%dT%H:%M:%S.") + fraction + "Z"
    if canonical != value:
        raise ValueError("ledger timestamp is not canonically serialized")
    return parsed


def validate_ack(ack: dict, cut: str) -> None:
    if (
        cut not in IDS
        or set(ack) != ACK_KEYS
        or type(ack.get("version")) is not int
        or ack["version"] != 1
    ):
        raise ValueError("ack schema/cut mismatch")
    if (
        ack.get("cut") != cut
        or ack.get("id") != IDS[cut]
        or not TOKEN_PATTERN.fullmatch(str(ack.get("runToken", "")))
    ):
        raise ValueError("ack identity mismatch")
    phase = "realPluginMirror" if cut == "realPluginMirror" else "seed"
    kind = (
        "rawTranscript"
        if cut in {"allocated", "sourceVerified", "handedOffBeforePlatform"}
        else "pidCsv"
    )
    extension = "txt" if kind == "rawTranscript" else "csv"
    handed = cut not in {"allocated", "sourceVerified"}
    expected_calls = (
        1
        if cut
        in {
            "platformInvoked",
            "pendingResult",
            "neverResult",
            "realPluginMirror",
        }
        else 0
    )
    expected_semantic = {
        "allocated": "notInvoked",
        "sourceVerified": "notInvoked",
        "handedOffBeforePlatform": "notInvoked",
        "platformInvoked": "invokedBeforeAwait",
        "pendingResult": "completablePending",
        "neverResult": "nonCompletablePending",
        "realPluginMirror": "realPluginInvoked",
    }[cut]
    minimum_observation_ms = {
        "allocated": 0,
        "sourceVerified": 0,
        "handedOffBeforePlatform": 0,
        "platformInvoked": 0,
        "pendingResult": 2000,
        "neverResult": 5000,
        "realPluginMirror": 0,
    }[cut]
    if (
        ack.get("phase") != phase
        or ack.get("sourceKind") != kind
        or ack.get("sourceFileName") != f"{IDS[cut]}.{extension}.share"
        or ack.get("ledgerFileName") != f"{IDS[cut]}.lease.json"
        or ack.get("state") != ("handedOffLease" if handed else "allocated")
        or ack.get("result") != ("pending" if handed else None)
        or type(ack.get("platformCalls")) is not int
        or ack["platformCalls"] != expected_calls
        or ack.get("platformSemantic") != expected_semantic
        or type(ack.get("pendingObservationMs")) is not int
        or ack["pendingObservationMs"] < minimum_observation_ms
        or (minimum_observation_ms == 0 and ack["pendingObservationMs"] != 0)
        or ack.get("gateIdle") is not False
        or ack.get("secondShareError") != "shareBusy"
        or ack.get("crossFeatureDenied") is not True
    ):
        raise ValueError("ack semantic mismatch")
    if cut == "allocated":
        if ack.get("bytes") is not None or ack.get("fingerprint") is not None:
            raise ValueError("allocated ack must not claim verified source parity")
    elif (
        type(ack.get("bytes")) is not int
        or not 0 <= ack["bytes"] <= SOURCE_LIMIT
        or not isinstance(ack.get("fingerprint"), str)
        or not FNV_PATTERN.fullmatch(ack["fingerprint"])
    ):
        raise ValueError("ack source parity is invalid")


def inspect_archive(archive: pathlib.Path, ack: dict, cut: str) -> dict:
    validate_ack(ack, cut)
    with tarfile.open(archive, "r:") as stream:
        members = stream.getmembers()
        if len(members) != 3:
            raise ValueError("archive must contain root plus exactly two files")
        roots = [item for item in members if item.isdir()]
        files = [item for item in members if item.isfile()]
        if (
            len(roots) != 1
            or roots[0].name.rstrip("/") != "telltale-app-shares"
            or len(files) != 2
        ):
            raise ValueError("invalid archive topology")
        names = set()
        for item in members:
            path = pathlib.PurePosixPath(item.name)
            if (
                path.is_absolute()
                or ".." in path.parts
                or item.issym()
                or item.islnk()
                or not (item.isdir() or item.isfile())
                or path.parts[0] != "telltale-app-shares"
                or len(path.parts) > 2
            ):
                raise ValueError(f"unsafe archive member: {item.name}")
            if item.isfile():
                names.add(path.name)
        expected_names = {ack["sourceFileName"], ack["ledgerFileName"]}
        if names != expected_names:
            raise ValueError("archive group names mismatch")
        by_name = {pathlib.PurePosixPath(item.name).name: item for item in files}
        source_member = by_name[ack["sourceFileName"]]
        ledger_member = by_name[ack["ledgerFileName"]]
        if source_member.size > SOURCE_LIMIT or ledger_member.size > 4096:
            raise ValueError("archive file bound exceeded")
        source = stream.extractfile(source_member).read()
        ledger_bytes = stream.extractfile(ledger_member).read()
    ledger = _decode_json(ledger_bytes)
    base = {
        "version",
        "id",
        "sourceKind",
        "extension",
        "mimeType",
        "state",
        "createdAtUtc",
    }
    handed = base | {
        "bytes",
        "fingerprint",
        "handedOffAtUtc",
        "cleanupEligibleAtUtc",
        "cleanupDueAtUtc",
        "result",
    }
    expected_keys = base if ack["state"] == "allocated" else handed
    if (
        set(ledger) != expected_keys
        or type(ledger.get("version")) is not int
        or ledger["version"] != 1
    ):
        raise ValueError("ledger schema mismatch")
    created = _parse_utc(ledger.get("createdAtUtc"))
    extension = {
        "rawTranscript": "txt",
        "recoveredTranscript": "txt",
        "telemetryJson": "json",
    }.get(ack["sourceKind"], "csv")
    mime = (
        "text/plain"
        if extension == "txt"
        else ("application/json" if extension == "json" else "text/csv")
    )
    if ledger.get("extension") != extension or ledger.get("mimeType") != mime:
        raise ValueError("ledger media mismatch")
    keys = ("id", "state", "sourceKind", "result")
    if ack["state"] == "handedOffLease":
        keys += ("bytes", "fingerprint")
    if any(ledger.get(key) != ack.get(key) for key in keys):
        raise ValueError("ledger/ack mismatch")
    if ack["state"] == "handedOffLease":
        if (
            type(ledger.get("bytes")) is not int
            or not 0 <= ledger["bytes"] <= SOURCE_LIMIT
        ):
            raise ValueError("ledger byte count is invalid")
        handed = _parse_utc(ledger.get("handedOffAtUtc"))
        eligible = _parse_utc(ledger.get("cleanupEligibleAtUtc"))
        due = _parse_utc(ledger.get("cleanupDueAtUtc"))
        if (
            created > handed
            or eligible != handed + datetime.timedelta(minutes=15)
            or due != handed + datetime.timedelta(hours=24)
        ):
            raise ValueError("ledger cleanup intervals are invalid")
    if len(source) != source_member.size:
        raise ValueError("source size mismatch")
    fingerprint = _fnv(source)
    if cut != "allocated" and (
        len(source) != ack["bytes"] or fingerprint != ack["fingerprint"]
    ):
        raise ValueError("source parity mismatch")
    return {
        "source": source,
        "ledger": ledger_bytes,
        "sourceBytes": len(source),
        "sourceFingerprint": fingerprint,
    }


def build_manifest(
    archive: pathlib.Path,
    ack_path: pathlib.Path,
    token: str,
    cut: str,
) -> dict:
    if not TOKEN_PATTERN.fullmatch(token):
        raise ValueError("invalid manifest token")
    ack = _load_json(ack_path)
    if token != ack.get("runToken"):
        raise ValueError("manifest token does not match ack token")
    inspected = inspect_archive(archive, ack, cut)
    return {
        "version": 1,
        "runToken": token,
        "cut": cut,
        "id": ack["id"],
        "sourceKind": ack["sourceKind"],
        "state": ack["state"],
        "sourceFileName": ack["sourceFileName"],
        "ledgerFileName": ack["ledgerFileName"],
        "sourceBytes": inspected["sourceBytes"],
        "sourceFingerprint": inspected["sourceFingerprint"],
        "result": ack["result"],
        "platformCalls": ack["platformCalls"],
        "platformSemantic": ack["platformSemantic"],
        "pendingObservationMs": ack["pendingObservationMs"],
        "archiveSha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
        "sourceSha256": hashlib.sha256(inspected["source"]).hexdigest(),
        "ledgerSha256": hashlib.sha256(inspected["ledger"]).hexdigest(),
    }


def canonical_json(value: dict) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"


def revalidate_manifest(
    archive: pathlib.Path,
    ack_path: pathlib.Path,
    token: str,
    cut: str,
    expected: dict,
) -> None:
    actual = build_manifest(archive, ack_path, token, cut)
    if canonical_json(actual) != canonical_json(expected):
        raise ValueError("archive or token-bound manifest changed before restore")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("validate", "build", "revalidate"))
    parser.add_argument("--archive", type=pathlib.Path, required=True)
    parser.add_argument("--ack", type=pathlib.Path, required=True)
    parser.add_argument("--cut", required=True)
    parser.add_argument("--token")
    parser.add_argument("--manifest", type=pathlib.Path)
    args = parser.parse_args()
    ack = _load_json(args.ack)
    if args.command == "validate":
        inspect_archive(args.archive, ack, args.cut)
        return
    if args.token is None or args.manifest is None:
        parser.error("build/revalidate require --token and --manifest")
    if args.command == "build":
        actual = build_manifest(args.archive, args.ack, args.token, args.cut)
        args.manifest.write_text(canonical_json(actual), encoding="utf-8")
        return
    expected = _load_json(args.manifest)
    revalidate_manifest(args.archive, args.ack, args.token, args.cut, expected)


if __name__ == "__main__":
    main()
