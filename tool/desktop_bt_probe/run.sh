#!/usr/bin/env bash
# Fail-closed desktop Bluetooth inventory.
#
# Exit 0 only means an OBD-named candidate showed up in the host dump.
# It is NOT connect → PID → record evidence. Use tool/field_bt_verify/run.sh
# on Android for that journey when ACL is up.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT/tool/desktop_bt_probe"

dump_inventory() {
  case "$(uname -s)" in
    Darwin)
      system_profiler SPBluetoothDataType 2>/dev/null || true
      ;;
    Linux)
      {
        echo "rfcomm nodes:"
        ls -l /dev/rfcomm* 2>/dev/null || echo "(none)"
        if command -v bluetoothctl >/dev/null 2>&1; then
          echo "bluetoothctl devices:"
          bluetoothctl devices 2>/dev/null || true
        fi
      }
      ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
      powershell.exe -NoProfile -Command \
        "Get-PnpDevice -Class Bluetooth | Select-Object -ExpandProperty FriendlyName" \
        2>/dev/null || true
      ;;
    *)
      echo "unsupported host $(uname -s)" >&2
      exit 1
      ;;
  esac
}

INVENTORY="$(dump_inventory)"
printf '%s' "$INVENTORY" | python3 -c '
import sys
from probe import evaluate
code, summary = evaluate(sys.stdin.read())
print(summary)
raise SystemExit(code)
'
