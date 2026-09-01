#!/usr/bin/env python3
"""Fail-closed validator for lifecycle rig logs."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def _read(path: str) -> str:
    value = Path(path)
    if not value.is_file():
        raise ValueError(f"missing evidence log: {value}")
    return value.read_text(encoding="utf-8", errors="strict")


def verify(home: str, seed: str, recovery: str) -> None:
    home_text = _read(home)
    seed_text = _read(seed)
    recovery_text = _read(recovery)
    home_ready = home_text.find("TELLTALE_LIFECYCLE_READY_HOME")
    home_stored = home_text.find("TELLTALE_LIFECYCLE_HOME_STORED")
    if home_ready < 0 or home_stored <= home_ready:
        raise ValueError("Home markers are absent or out of order")
    seed_match = re.search(
        r"TELLTALE_LIFECYCLE_READY_FORCE_STOP "
        r"session=([0-9a-f]{32}) values=([1-9]\d*) statuses=(\d+) gaps=(\d+)",
        seed_text,
    )
    if seed_match is None:
        raise ValueError("force-stop seed lacks a canonical session/value marker")
    recovered = re.search(
        r"TELLTALE_LIFECYCLE_RECOVERED "
        r"session=([0-9a-f]{32}) values=([1-9]\d*) statuses=(\d+) gaps=(\d+) "
        r"terminal=recoveredAfterInterruption ui=connect-history",
        recovery_text,
    )
    if recovered is None:
        raise ValueError("fresh recovery lacks validated artifact/UI proof")
    if recovered.groups() != seed_match.groups():
        raise ValueError("fresh recovery does not match the killed durable prefix")
    if "All tests passed!" not in home_text or "All tests passed!" not in recovery_text:
        raise ValueError("a required non-killed Flutter target did not pass")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", required=True)
    parser.add_argument("--seed", required=True)
    parser.add_argument("--recovery", required=True)
    args = parser.parse_args()
    verify(args.home, args.seed, args.recovery)


if __name__ == "__main__":
    main()
