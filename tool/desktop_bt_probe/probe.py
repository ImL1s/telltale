#!/usr/bin/env python3
"""Fail-closed desktop Bluetooth inventory. Never reports a connect→PID pass."""

from __future__ import annotations

import re
from typing import Iterable

# Names we have actually seen on ELM327 clones in this project.
_ADAPTER_NAME = re.compile(
    r"\b(OBD(?:BLE|II)?|ELM327|V-?LINK|Vgate|OBDII)\b",
    re.IGNORECASE,
)


def candidate_names(inventory: str, extra: Iterable[str] = ()) -> list[str]:
    names = []
    for raw in extra:
        token = raw.strip()
        if token:
            names.append(token)
    for match in _ADAPTER_NAME.finditer(inventory):
        token = match.group(0)
        if token not in names:
            names.append(token)
    return names


def evaluate(inventory: str, extra: Iterable[str] = ()) -> tuple[int, str]:
    """Return (exit_code, summary).

    0 = an OBD-named candidate appears in inventory (still not a field journey)
    2 = Bluetooth inventory present but no OBD-named adapter
    3 = empty inventory (radio off / permission / no dump)
    """
    text = inventory.strip()
    if not text:
        return 3, "empty Bluetooth inventory"
    hits = candidate_names(text, extra)
    if not hits:
        return 2, "no OBD-named adapter in desktop inventory"
    return 0, "candidates: " + ", ".join(hits)
