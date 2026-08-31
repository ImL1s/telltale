#!/usr/bin/env bash
# Bind Ircama on the Mac LAN and prove iOS Simulator Wi‑Fi → live PIDs.
#
# Why not 127.0.0.1: that is the desktop WifiTransport oracle path. From the
# Simulator we want the same address a phone would use for a Wi‑Fi ELM327 —
# the host's en0 (or WIFI_ORACLE_HOST). The BLE entrypoint defaults to
# loopback; this harness overrides ELM_BIND_INTERFACE=0.0.0.0 for the run.
#
# Usage (boot an iPhone Simulator first):
#   tool/ios_wifi_oracle/run.sh
#   IOS_SIM_DEVICE=<udid> tool/ios_wifi_oracle/run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FLUTTER="${FLUTTER:-$HOME/fvm/versions/3.47.0/bin/flutter}"
VENV="${ELM_VENV:-/tmp/elmvenv-torque-wifi}"
PORT="${ELM_ORACLE_PORT:-35000}"
IFACE="${WIFI_ORACLE_IFACE:-en0}"

cd "$ROOT"

resolve_host() {
  if [[ -n "${WIFI_ORACLE_HOST:-}" ]]; then
    printf '%s\n' "$WIFI_ORACLE_HOST"
    return
  fi
  local ip
  ip="$(ipconfig getifaddr "$IFACE" 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    echo "Refusing: no IPv4 on $IFACE; set WIFI_ORACLE_HOST" >&2
    exit 1
  fi
  printf '%s\n' "$ip"
}

resolve_device() {
  if [[ -n "${IOS_SIM_DEVICE:-}" ]]; then
    printf '%s\n' "$IOS_SIM_DEVICE"
    return
  fi
  local udid
  udid="$(
    xcrun simctl list devices booted -j \
      | python3 -c '
import json,sys
d=json.load(sys.stdin)
for devs in d.get("devices",{}).values():
  for x in devs:
    if x.get("state")=="Booted" and "iPhone" in x.get("name",""):
      print(x["udid"]); raise SystemExit
'
  )"
  if [[ -z "$udid" ]]; then
    echo "Refusing: no booted iPhone Simulator; set IOS_SIM_DEVICE" >&2
    exit 1
  fi
  printf '%s\n' "$udid"
}

HOST="$(resolve_host)"
DEVICE="$(resolve_device)"

if [[ ! -x "$VENV/bin/python" ]]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q setuptools==80.10.2 wheel==0.45.1
  env -u GITHUB_RUN_NUMBER "$VENV/bin/pip" install -q --no-build-isolation \
    --no-cache-dir ELM327-emulator==3.0.5
  "$VENV/bin/pip" check
fi

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Refusing: something already listens on :$PORT" >&2
  exit 1
fi

ELM_PID_DIR="$(mktemp -d "${TMPDIR:-/tmp}/telltale-ios-wifi-elm.XXXXXX")"
chmod 700 "$ELM_PID_DIR"
cleanup() {
  if [[ -n "${emulator_pid:-}" ]]; then
    kill "$emulator_pid" 2>/dev/null || true
    wait "$emulator_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# LAN bind: Simulator connects to $HOST:$PORT (en0), not loopback.
ELM_BIND_INTERFACE="${ELM_BIND_INTERFACE:-0.0.0.0}" \
  "$VENV/bin/python" tool/ble_test_rig/emulator_entrypoint.py \
  --pid-directory "$ELM_PID_DIR" \
  -n "$PORT" -s car -d \
  -b "$ELM_PID_DIR/batch.log" >"$ELM_PID_DIR/elm.log" 2>&1 &
emulator_pid=$!

for _ in $(seq 1 50); do
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.1
done
lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1
# Do NOT TCP-probe the emulator: it is single-client, and a throwaway connect
# poisons the Simulator's handshake the same way CI documents for Ircama.

# Confirm the listen is not loopback-only (LAN path must be reachable).
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | grep -E '127\.0\.0\.1|\[::1\]' >/dev/null \
  && ! lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | grep -E '\*:|0\.0\.0\.0' >/dev/null; then
  echo "Refusing: emulator bound loopback-only; set ELM_BIND_INTERFACE=0.0.0.0" >&2
  exit 1
fi
echo "iOS Wi-Fi oracle: device=$DEVICE host=$HOST:$PORT (bind=${ELM_BIND_INTERFACE:-0.0.0.0})"

"$FLUTTER" test integration_test/ios_field_wifi_oracle_test.dart \
  -d "$DEVICE" \
  --flavor field \
  --dart-define=WIFI_ORACLE_HOST="$HOST" \
  --dart-define=WIFI_ORACLE_PORT="$PORT" \
  --dart-define=WIFI_ORACLE_REQUIRED=true

echo "iOS Wi-Fi oracle evidence: PASS (Ircama on $HOST:$PORT from Simulator)"
echo "state dir: $ELM_PID_DIR"
