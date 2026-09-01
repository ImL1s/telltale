#!/usr/bin/env python3
"""Unit tests for field_bt_verify/probe_acl.py — no phone required."""

from __future__ import annotations

import unittest

from probe_acl import evaluate, parse_bond_lines


_SAMPLE_DOWN = """
BluetoothAdapterProperties
  ConnectionState: STATE_DISCONNECTED
  Bonded devices: 2
    XX:XX:XX:XX:22:33(Public ) => XX:XX:XX:XX:22:33(Public ) [ DUAL ] [0x010000] [ACL BR/EDR:N LE:N] [ Encryption status(BR/EDR): null LE: null] OBDBLE
        [BR/EDR UUIDs]: SPP
    XX:XX:XX:XX:22:33 | OBDII | 2 | 3 | 65536 | 576 | null | SPP | 41 | 0 | 0 | null | 0 | 0 | 0
"""

_SAMPLE_LE_UP = """
  ConnectionState: STATE_CONNECTED
  Bonded devices: 1
    AA:BB:CC:11:22:33(Public ) => AA:BB:CC:11:22:33(Public ) [ DUAL ] [0x010000] [ACL BR/EDR:N LE:Y] [ Encryption status(BR/EDR): null LE: null] OBDBLE
"""

_SAMPLE_MISSING = """
  ConnectionState: STATE_DISCONNECTED
  Bonded devices: 1
    AA:BB:CC:00:00:01(Public ) => AA:BB:CC:00:00:01(Public ) [ DUAL ] [0x240404] [ACL BR/EDR:N LE:N] [ Encryption status(BR/EDR): null LE: null] Galaxy Buds
"""


class ProbeAclTest(unittest.TestCase):
    def test_bonded_acl_down_is_exit_2(self) -> None:
        code, summary = evaluate(_SAMPLE_DOWN, ("OBDBLE", "OBDII"))
        self.assertEqual(code, 2)
        self.assertIn("ACL down", summary)
        hits = parse_bond_lines(_SAMPLE_DOWN, ("OBDBLE",))
        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0].name, "OBDBLE")
        self.assertFalse(hits[0].acl_bredr)
        self.assertFalse(hits[0].acl_le)

    def test_le_acl_up_is_exit_0(self) -> None:
        code, summary = evaluate(_SAMPLE_LE_UP, ("OBDBLE",))
        self.assertEqual(code, 0)
        self.assertIn("ACL up", summary)

    def test_missing_adapter_is_exit_3(self) -> None:
        code, summary = evaluate(_SAMPLE_MISSING, ("OBDBLE", "OBDII"))
        self.assertEqual(code, 3)
        self.assertIn("no bonded adapter", summary)


if __name__ == "__main__":
    unittest.main()
