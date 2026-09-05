#!/usr/bin/env python3
"""Validate docs/workshop/capabilities.json against USABILITY-R2 rules."""

from __future__ import annotations

import json
import sys
from pathlib import Path

ALLOWED_AVAILABILITY = {
    "usable",
    "usableWithNotice",
    "rawOnly",
    "unavailable",
}
ALLOWED_ORIGIN = {"ecuReported", "calculated", "userEntered", "demo"}
ALLOWED_EVIDENCE = {
    "fieldVerified",
    "community",
    "experimental",
    "userSupplied",
    "notTested",
    "unknown",
}
ALLOWED_COMPAT = {
    "exact",
    "candidate",
    "userSelected",
    "unknown",
    "knownMismatch",
}
ALLOWED_QUALITY = {
    "valid",
    "tentativeDecode",
    "outOfReferenceRange",
    "stale",
    "invalid",
    "partial",
}
ALLOWED_RISK = {"display", "boundedRead", "clear", "stateChange", "program"}


def validate(path: Path) -> list[str]:
    errors: list[str] = []
    data = json.loads(path.read_text())
    if data.get("schemaVersion") != 1:
        errors.append("schemaVersion must be 1")
    if data.get("policy") != "USABILITY-R2":
        errors.append("policy must be USABILITY-R2")
    capabilities = data.get("capabilities")
    if not isinstance(capabilities, list) or not capabilities:
        errors.append("capabilities must be a non-empty list")
        return errors
    ids: set[str] = set()
    for index, item in enumerate(capabilities):
        prefix = f"capabilities[{index}]"
        if not isinstance(item, dict):
            errors.append(f"{prefix} must be an object")
            continue
        ident = item.get("id")
        if not ident or ident in ids:
            errors.append(f"{prefix}.id missing or duplicate")
        ids.add(ident)
        if item.get("availability") not in ALLOWED_AVAILABILITY:
            errors.append(f"{prefix}.availability invalid")
        if item.get("origin") not in ALLOWED_ORIGIN:
            errors.append(f"{prefix}.origin invalid")
        if item.get("evidence") not in ALLOWED_EVIDENCE:
            errors.append(f"{prefix}.evidence invalid")
        if item.get("compatibility") not in ALLOWED_COMPAT:
            errors.append(f"{prefix}.compatibility invalid")
        if item.get("quality") not in ALLOWED_QUALITY:
            errors.append(f"{prefix}.quality invalid")
        if item.get("operationRisk") not in ALLOWED_RISK:
            errors.append(f"{prefix}.operationRisk invalid")
        if item.get("evidence") == "fieldVerified":
            digest = item.get("fieldArtifactSha256") or ""
            if (
                not isinstance(digest, str)
                or len(digest) != 64
                or any(ch not in "0123456789abcdef" for ch in digest)
            ):
                errors.append(
                    f"{prefix}: fieldVerified requires a 64-char lowercase SHA-256"
                )
        if item.get("operationRisk") in {"stateChange", "program"} and item.get(
            "availability"
        ) in {"usable", "usableWithNotice"}:
            errors.append(
                f"{prefix}: write/actuate cannot be usable without a recipe"
            )
        if item.get("operationRisk") == "clear" and item.get(
            "availability"
        ) in {"usable", "usableWithNotice"}:
            if item.get("requiresClearSnapshot") is not True or item.get(
                "requiresUserConfirm"
            ) is not True:
                errors.append(
                    f"{prefix}: usable clear requires snapshot and user confirm"
                )
        if item.get("requiresFieldArtifact") is True and item.get(
            "availability"
        ) == "unavailable":
            errors.append(
                f"{prefix}: missing field artifact must not mark generic reads unavailable"
            )
    return errors


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: validate_capabilities.py <capabilities.json>", file=sys.stderr)
        return 2
    path = Path(argv[1])
    errors = validate(path)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print(f"OK {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
