#!/usr/bin/env python3
"""Emit manifests built by the host validator for Dart schema-parity tests."""

from __future__ import annotations

import io
import json
import pathlib
import tarfile
import tempfile

from gate_c_validate import IDS, _fnv, build_manifest


TOKEN = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SEMANTICS = {
    "allocated": ("notInvoked", 0, 0),
    "sourceVerified": ("notInvoked", 0, 0),
    "handedOffBeforePlatform": ("notInvoked", 0, 0),
    "platformInvoked": ("invokedBeforeAwait", 1, 0),
    "pendingResult": ("completablePending", 1, 2000),
    "neverResult": ("nonCompletablePending", 1, 5000),
    "realPluginMirror": ("realPluginInvoked", 1, 0),
}


def _ledger(cut: str, source: bytes) -> dict[str, object]:
    identifier = IDS[cut]
    raw = cut in {"allocated", "sourceVerified", "handedOffBeforePlatform"}
    allocated = cut in {"allocated", "sourceVerified"}
    ledger: dict[str, object] = {
        "version": 1,
        "id": identifier,
        "sourceKind": "rawTranscript" if raw else "pidCsv",
        "extension": "txt" if raw else "csv",
        "mimeType": "text/plain" if raw else "text/csv",
        "state": "allocated" if allocated else "handedOffLease",
        "createdAtUtc": "2026-08-30T00:00:00.000Z",
    }
    if not allocated:
        ledger.update(
            {
                "bytes": len(source),
                "fingerprint": _fnv(source),
                "handedOffAtUtc": "2026-08-30T00:01:00.000Z",
                "cleanupEligibleAtUtc": "2026-08-30T00:16:00.000Z",
                "cleanupDueAtUtc": "2026-08-31T00:01:00.000Z",
                "result": "pending",
            }
        )
    return ledger


def _ack(cut: str, source: bytes) -> dict[str, object | None]:
    identifier = IDS[cut]
    raw = cut in {"allocated", "sourceVerified", "handedOffBeforePlatform"}
    allocated = cut in {"allocated", "sourceVerified"}
    semantic, platform_calls, observation_ms = SEMANTICS[cut]
    return {
        "version": 1,
        "runToken": TOKEN,
        "phase": "realPluginMirror" if cut == "realPluginMirror" else "seed",
        "cut": cut,
        "id": identifier,
        "state": "allocated" if allocated else "handedOffLease",
        "sourceKind": "rawTranscript" if raw else "pidCsv",
        "sourceFileName": f"{identifier}.{'txt' if raw else 'csv'}.share",
        "ledgerFileName": f"{identifier}.lease.json",
        "bytes": None if cut == "allocated" else len(source),
        "fingerprint": None if cut == "allocated" else _fnv(source),
        "result": None if allocated else "pending",
        "platformCalls": platform_calls,
        "platformSemantic": semantic,
        "pendingObservationMs": observation_ms,
        "gateIdle": False,
        "secondShareError": "shareBusy",
        "crossFeatureDenied": True,
    }


def _add_bytes(stream: tarfile.TarFile, name: str, data: bytes) -> None:
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = 0o600
    stream.addfile(info, io.BytesIO(data))


def build_all() -> list[dict[str, object]]:
    manifests: list[dict[str, object]] = []
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        for cut, identifier in IDS.items():
            source = f"Gate C manifest fixture: {cut}\n".encode()
            ack = _ack(cut, source)
            ledger_bytes = json.dumps(
                _ledger(cut, source), separators=(",", ":")
            ).encode()
            archive = root / f"{cut}.tar"
            ack_path = root / f"{cut}.ack.json"
            ack_path.write_text(json.dumps(ack), encoding="utf-8")
            with tarfile.open(archive, "w:") as stream:
                directory = tarfile.TarInfo("telltale-app-shares")
                directory.type = tarfile.DIRTYPE
                directory.mode = 0o700
                stream.addfile(directory)
                _add_bytes(
                    stream,
                    f"telltale-app-shares/{ack['sourceFileName']}",
                    source,
                )
                _add_bytes(
                    stream,
                    f"telltale-app-shares/{identifier}.lease.json",
                    ledger_bytes,
                )
            manifests.append(
                {
                    "cut": cut,
                    "manifest": build_manifest(archive, ack_path, TOKEN, cut),
                }
            )
    return manifests


def main() -> None:
    print(json.dumps(build_all(), separators=(",", ":")))


if __name__ == "__main__":
    main()
