#!/usr/bin/env bash
# One-command field Bluetooth verification against a bonded physical adapter.
#
# Preflight parses `dumpsys bluetooth_manager` for OBDBLE/OBDII. Bonded but
# ACL-down is a hard fail — never a fake journey pass. When ACL is up (dongle
# powered, phone in range), builds/installs the field debug APK (unless skipped),
# grants BT permissions, and drives:
#   Connect → BLE/Classic → live PIDs → record → durable session file
#
# Usage (from app/):
#   tool/field_bt_verify/run.sh
#   ANDROID_SERIAL=R5CX10VFFBA tool/field_bt_verify/run.sh
#   tool/field_bt_verify/run.sh --probe-only
#   FIELD_BT_TRANSPORT=classic tool/field_bt_verify/run.sh
#   FIELD_BT_SKIP_INSTALL=1 tool/field_bt_verify/run.sh   # reuse installed field debug
#
# Exit codes:
#   0 — journey PASS (or probe-only with ACL up)
#   2 — ACL down / adapter unpowered (evidence written; no fake pass)
#   3 — adapter not bonded
#   1 — tooling / install / journey failure
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FLUTTER="${FLUTTER:-$HOME/fvm/versions/3.47.0/bin/flutter}"
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
SERIAL="${ANDROID_SERIAL:-R5CX10VFFBA}"
ADAPTER_NAME="${FIELD_BT_ADAPTER_NAME:-OBDBLE}"
TRANSPORT="${FIELD_BT_TRANSPORT:-ble}"
PACKAGE="${FIELD_BT_PACKAGE:-com.cbstudio.telltale}"
EVIDENCE_DIR="${FIELD_BT_EVIDENCE_DIR:-$ROOT/docs/verification}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PROBE_ONLY=0
FORCE_JOURNEY=0
SKIP_INSTALL="${FIELD_BT_SKIP_INSTALL:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --probe-only) PROBE_ONLY=1; shift ;;
    --force-journey) FORCE_JOURNEY=1; shift ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    --serial) SERIAL="${2:?}"; shift 2 ;;
    --transport) TRANSPORT="${2:?}"; shift 2 ;;
    --name) ADAPTER_NAME="${2:?}"; shift 2 ;;
    -h|--help)
      sed -n '2,25p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

cd "$ROOT"

if [[ ! -x "$FLUTTER" ]]; then
  echo "Refusing: Flutter not executable at $FLUTTER" >&2
  exit 1
fi
if [[ ! -x "$ADB" ]]; then
  echo "Refusing: adb not executable at $ADB" >&2
  exit 1
fi

mkdir -p "$EVIDENCE_DIR"
DUMP_DIR="${TMPDIR:-/tmp}/telltale-field-bt-verify"
mkdir -p "$DUMP_DIR"
chmod 700 "$DUMP_DIR" 2>/dev/null || true
DUMP="$DUMP_DIR/dumpsys-$STAMP.txt"
EVIDENCE="$EVIDENCE_DIR/field-bt-probe-$STAMP.txt"
JOURNEY_LOG="$EVIDENCE_DIR/field-bt-journey-$STAMP.log"

echo "field_bt_verify: serial=$SERIAL adapter=$ADAPTER_NAME transport=$TRANSPORT"

if ! "$ADB" -s "$SERIAL" get-state 2>/dev/null | grep -qx device; then
  echo "Refusing: device $SERIAL is not in 'device' state" >&2
  "$ADB" devices -l >&2 || true
  exit 1
fi

# Wake + brief BT settings open so the radio is not fully idle before dumpsys.
"$ADB" -s "$SERIAL" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
"$ADB" -s "$SERIAL" shell cmd bluetooth_manager enable >/dev/null 2>&1 || true
"$ADB" -s "$SERIAL" shell am start -a android.settings.BLUETOOTH_SETTINGS >/dev/null 2>&1 || true
sleep 2

"$ADB" -s "$SERIAL" shell dumpsys bluetooth_manager >"$DUMP" 2>/dev/null || {
  echo "Refusing: dumpsys bluetooth_manager failed" >&2
  exit 1
}

set +e
python3 tool/field_bt_verify/probe_acl.py "$DUMP" \
  --name "$ADAPTER_NAME" --name OBDII \
  --evidence "$EVIDENCE"
PROBE_RC=$?
set -e

# Keep docs/verification evidence small: bond lines + ConnectionState only.
{
  echo "timestamp_utc: $STAMP"
  echo "device: $SERIAL"
  echo "dumpsys_host_path: $DUMP"
  echo "--- bond excerpt ---"
  strings "$DUMP" | rg -i 'OBDBLE|OBDII|ConnectionState:' | head -20 || true
} >>"$EVIDENCE"

echo "ACL probe exit=$PROBE_RC evidence=$EVIDENCE"

if [[ "$PROBE_ONLY" -eq 1 ]]; then
  if [[ "$PROBE_RC" -eq 0 ]]; then
    echo "probe-only: ACL up — ready for journey (re-run without --probe-only)"
    exit 0
  fi
  echo "probe-only: not a field pass (rc=$PROBE_RC)"
  exit "$PROBE_RC"
fi

if [[ "$PROBE_RC" -ne 0 && "$FORCE_JOURNEY" -ne 1 ]]; then
  echo >&2
  echo "Refusing journey: ACL probe did not pass (rc=$PROBE_RC)." >&2
  echo "Power the dongle / ignition, then re-run. Use --force-journey only to" >&2
  echo "capture a deliberate scan-failure log — it still will not fake a pass." >&2
  echo "Evidence: $EVIDENCE" >&2
  exit "$PROBE_RC"
fi

grant_bt_permissions() {
  local pkg="$1"
  # Android 12+
  "$ADB" -s "$SERIAL" shell pm grant "$pkg" android.permission.BLUETOOTH_SCAN 2>/dev/null || true
  "$ADB" -s "$SERIAL" shell pm grant "$pkg" android.permission.BLUETOOTH_CONNECT 2>/dev/null || true
  # Older / location-tied scan
  "$ADB" -s "$SERIAL" shell pm grant "$pkg" android.permission.ACCESS_FINE_LOCATION 2>/dev/null || true
  "$ADB" -s "$SERIAL" shell pm grant "$pkg" android.permission.ACCESS_COARSE_LOCATION 2>/dev/null || true
}

if [[ "$SKIP_INSTALL" != "1" ]]; then
  echo "Building + installing field debug APK (overwrites $PACKAGE on device)…"
  echo "Set FIELD_BT_SKIP_INSTALL=1 to reuse an already-installed field debug build."
  "$FLUTTER" build apk --debug --flavor field
  APK="$ROOT/build/app/outputs/flutter-apk/app-field-debug.apk"
  if [[ ! -f "$APK" ]]; then
    echo "Refusing: missing $APK" >&2
    exit 1
  fi
  "$ADB" -s "$SERIAL" install -r -g "$APK"
fi

grant_bt_permissions "$PACKAGE"

echo "Driving field BT journey → $JOURNEY_LOG"
set +e
ANDROID_SERIAL="$SERIAL" "$FLUTTER" test \
  integration_test/field_bt_journey_test.dart \
  -d "$SERIAL" \
  --flavor field \
  --dart-define=FIELD_BT_REQUIRED=true \
  --dart-define=FIELD_BT_ADAPTER_NAME="$ADAPTER_NAME" \
  --dart-define=FIELD_BT_TRANSPORT="$TRANSPORT" \
  2>&1 | tee "$JOURNEY_LOG"
JOURNEY_RC=${PIPESTATUS[0]}
set -e

{
  echo "--- journey ---"
  echo "timestamp_utc: $STAMP"
  echo "journey_rc: $JOURNEY_RC"
  echo "log: $JOURNEY_LOG"
  if [[ "$JOURNEY_RC" -eq 0 ]]; then
    echo "verdict: PASS — connect → live PIDs → record"
  else
    echo "verdict: FAIL — journey did not complete (no fake pass)"
  fi
} >>"$EVIDENCE"

if [[ "$JOURNEY_RC" -eq 0 ]]; then
  echo "field_bt_verify: PASS"
  echo "evidence: $EVIDENCE"
  exit 0
fi

echo "field_bt_verify: FAIL (journey_rc=$JOURNEY_RC)" >&2
echo "evidence: $EVIDENCE" >&2
exit 1
