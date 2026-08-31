#!/usr/bin/env python3
"""Regenerates the powertrain battery catalog manifest from the catalog JSON.

The manifest pins the catalog's SHA-256, byte size, schema version and the
statistics the loader cross-checks (profile count, signal count, counts by
powertrain). Editing the catalog without rerunning this script makes the
whole catalog fail closed at load, so this is a required step of every data
change, not an optimization.

Usage:
    python3 tool/update_powertrain_battery_manifest.py [--check]

--check verifies the committed manifest matches the catalog and exits
non-zero on drift, without writing anything. CI runs the check; humans run
the default write mode.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from collections import Counter
from pathlib import Path

CATALOG = Path(__file__).resolve().parent.parent / (
    "assets/powertrain_battery/powertrain_battery_catalog.json"
)
MANIFEST = CATALOG.with_name("powertrain_battery_catalog.manifest.json")


def build_manifest() -> dict:
    raw = CATALOG.read_bytes()
    catalog = json.loads(raw)
    profiles = catalog["profiles"]
    counts = Counter(profile["powertrain"] for profile in profiles)
    signal_count = sum(
        len(command["signals"])
        for profile in profiles
        for command in profile.get("commands", [])
    )
    return {
        "schema_version": catalog["schema_version"],
        "catalog_file": CATALOG.name,
        "sha256": hashlib.sha256(raw).hexdigest(),
        "size_bytes": len(raw),
        "profile_count": len(profiles),
        "signal_count": signal_count,
        "counts_by_powertrain": dict(sorted(counts.items())),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    manifest = build_manifest()
    rendered = json.dumps(manifest, indent=2) + "\n"

    if args.check:
        current = MANIFEST.read_text() if MANIFEST.exists() else ""
        if current != rendered:
            sys.stderr.write(
                "manifest is stale; run "
                "python3 tool/update_powertrain_battery_manifest.py\n"
            )
            return 1
        print("manifest matches catalog")
        return 0

    MANIFEST.write_text(rendered)
    print(
        f"wrote {MANIFEST.name}: {manifest['profile_count']} profiles, "
        f"{manifest['signal_count']} signals, sha256 {manifest['sha256'][:12]}…"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
