#!/usr/bin/env python3
"""Parse Android `dumpsys bluetooth_manager` for a bonded OBD adapter.

Fail-closed: bonded-but-disconnected (ACL BR/EDR:N LE:N) is never a field
pass. Exit codes:
  0 — adapter bonded and at least one ACL link is up (LE or BR/EDR)
  2 — adapter bonded but ACL down (unpowered / out of range)
  3 — adapter name not found in bonded list
  1 — usage / dumpsys parse error
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass


@dataclass(frozen=True)
class BondObservation:
    name: str
    line: str
    acl_bredr: bool | None
    acl_le: bool | None


_ACL_RE = re.compile(
    r"ACL BR/EDR:(?P<br>[YN])\s+LE:(?P<le>[YN])",
    re.IGNORECASE,
)


def parse_bond_lines(text: str, names: tuple[str, ...]) -> list[BondObservation]:
    """Return bonded-device lines whose display name matches any of *names*."""
    wanted = {n.casefold() for n in names}
    observations: list[BondObservation] = []
    for raw in text.splitlines():
        line = raw.rstrip("\n")
        # Bonded inventory lines look like:
        #   XX:XX:… [ DUAL ] […] [ACL BR/EDR:N LE:N] […] OBDBLE
        if "ACL BR/EDR:" not in line:
            continue
        # Display name is after the final ']' (earlier brackets are COD / ACL).
        name = line.rsplit("]", 1)[-1].strip()
        if not name or name.casefold() not in wanted:
            continue
        acl = _ACL_RE.search(line)
        observations.append(
            BondObservation(
                name=name,
                line=line.strip(),
                acl_bredr=(acl.group("br").upper() == "Y") if acl else None,
                acl_le=(acl.group("le").upper() == "Y") if acl else None,
            )
        )
    return observations


def connection_state(text: str) -> str | None:
    for line in text.splitlines():
        if "ConnectionState:" in line:
            return line.strip()
    return None


def evaluate(text: str, names: tuple[str, ...]) -> tuple[int, str]:
    """Return (exit_code, human_summary)."""
    hits = parse_bond_lines(text, names)
    state = connection_state(text) or "ConnectionState: <missing>"
    if not hits:
        return (
            3,
            f"no bonded adapter matching {', '.join(names)}; {state}",
        )
    up = [
        h
        for h in hits
        if h.acl_bredr is True or h.acl_le is True
    ]
    if up:
        detail = "; ".join(
            f"{h.name} BR/EDR={'Y' if h.acl_bredr else 'N'} "
            f"LE={'Y' if h.acl_le else 'N'}"
            for h in up
        )
        return 0, f"ACL up — {detail}; {state}"
    detail = "; ".join(h.line for h in hits)
    return (
        2,
        f"bonded but ACL down (unpowered/out of range) — {detail}; {state}",
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "dumpsys_path",
        nargs="?",
        help="path to dumpsys bluetooth_manager output (stdin if omitted)",
    )
    parser.add_argument(
        "--name",
        action="append",
        dest="names",
        default=None,
        help="bonded display name to accept (repeatable; default OBDBLE, OBDII)",
    )
    parser.add_argument(
        "--evidence",
        help="optional path to write a short pass/fail evidence blob",
    )
    args = parser.parse_args(argv)
    names = tuple(args.names) if args.names else ("OBDBLE", "OBDII")
    if args.dumpsys_path:
        with open(args.dumpsys_path, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    else:
        text = sys.stdin.read()

    code, summary = evaluate(text, names)
    print(summary)
    if args.evidence:
        verdict = {
            0: "PASS — ACL up",
            2: "FAIL — bonded but ACL down (no fake field pass)",
            3: "FAIL — adapter not bonded",
        }.get(code, "FAIL — probe error")
        body = (
            f"field_bt_verify ACL probe\n"
            f"names: {', '.join(names)}\n"
            f"verdict: {verdict}\n"
            f"summary: {summary}\n"
            f"no_fake_field_pass: true\n"
            f"---\n"
        )
        hits = parse_bond_lines(text, names)
        for hit in hits:
            body += hit.line + "\n"
        with open(args.evidence, "w", encoding="utf-8") as fh:
            fh.write(body)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
