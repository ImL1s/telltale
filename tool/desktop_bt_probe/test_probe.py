#!/usr/bin/env python3
"""Unit tests for desktop_bt_probe — no adapter required."""

from __future__ import annotations

import unittest

from probe import evaluate


_MACOS_NO_OBD = """
Bluetooth Controller:
  Address: AA:BB:CC:00:00:01
  State: On
Devices (Paired, Configured, etc.):
  Galaxy Buds:
    Address: 11:22:33:44:55:66
  Magic Keyboard:
    Address: 22:33:44:55:66:77
"""

_MACOS_WITH_OBD = """
Devices (Paired, Configured, etc.):
  OBDBLE:
    Address: AA:BB:CC:11:22:33
    Paired: Yes
"""

_LINUX_RFCOMM = """
crw-rw---- 1 root dialout 216, 0 /dev/rfcomm0
"""


class DesktopBtProbeTest(unittest.TestCase):
    def test_empty_inventory_is_exit_3(self) -> None:
        code, summary = evaluate("   ")
        self.assertEqual(code, 3)
        self.assertIn("empty", summary)

    def test_paired_phones_only_is_exit_2(self) -> None:
        code, summary = evaluate(_MACOS_NO_OBD)
        self.assertEqual(code, 2)
        self.assertIn("no OBD-named adapter", summary)

    def test_obdble_is_exit_0_not_a_journey(self) -> None:
        code, summary = evaluate(_MACOS_WITH_OBD)
        self.assertEqual(code, 0)
        self.assertIn("OBDBLE", summary)

    def test_rfcomm_node_without_obd_name_is_still_exit_2(self) -> None:
        code, summary = evaluate(_LINUX_RFCOMM)
        self.assertEqual(code, 2)


if __name__ == "__main__":
    unittest.main()
