#!/usr/bin/env python3
"""Split availability (A) from field-qualified (B) release exits."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

PHYSICAL_FIELD_KINDS = frozenset({"physicalVehicle", "fieldAppConnection"})


def _require_bool(evidence: dict, key: str) -> bool | None:
    if key not in evidence:
        return None
    value = evidence[key]
    if isinstance(value, bool):
        return value
    raise ValueError(f"{key} must be a boolean")


def load_profiles(path: Path) -> dict:
    return json.loads(path.read_text())["profiles"]


def evaluate(profile_id: str, profiles: dict, evidence: dict) -> tuple[int, str]:
    profile = profiles.get(profile_id)
    if profile is None:
        return 2, f"unknown profile {profile_id}"
    if profile.get("deferred"):
        return 1, f"deferred: {profile.get('reason', 'not-implemented')}"

    try:
        software_ok = _require_bool(evidence, "softwarePass")
        skipped = _require_bool(evidence, "softwareSkipped")
    except ValueError as error:
        return 1, str(error)

    if profile.get("requiresSoftwarePass"):
        if software_ok is not True:
            return 1, "software tests did not pass"
        if skipped is True:
            return 1, "software tests did not pass"

    if evidence.get("unknownTransactionMarkedSuccess"):
        return 1, "unknown transaction cannot be marked success"
    if evidence.get("badPacketAsNumber"):
        return 1, "bad packet must not become a number"

    artifacts = evidence.get("fieldArtifacts") or []
    if profile.get("requiresFieldArtifacts"):
        if not artifacts:
            return 1, "field-qualified requires field artifacts"
        for artifact in artifacts:
            kind = artifact.get("kind")
            if kind not in PHYSICAL_FIELD_KINDS:
                return 1, "field artifact kind is not physical"
            digest = artifact.get("sha256", "")
            if len(digest) != 64 or any(
                ch not in "0123456789abcdef" for ch in digest
            ):
                return 1, "invalid field artifact sha256"
        return 0, "field-qualified"

    # Exit A: missing field artifacts is not a failure.
    return 0, "available"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", required=True)
    parser.add_argument("--evidence", required=True)
    parser.add_argument(
        "--profiles",
        default=str(Path(__file__).with_name("release_profiles.json")),
    )
    args = parser.parse_args()
    profiles = load_profiles(Path(args.profiles))
    evidence = json.loads(Path(args.evidence).read_text())
    code, message = evaluate(args.profile, profiles, evidence)
    print(message)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
