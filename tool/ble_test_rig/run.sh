#!/bin/zsh
# A real BLE peripheral, in front of an ELM327 this project did not write.
#
# The app's BLE transport has unit tests against a scripted fake platform, and
# scanning has been exercised on real hardware. What those cannot reach is the
# middle: a real GATT connect, a real service discovery, a real CCCD subscribe,
# and real notifications carrying an ELM327 conversation. This rig produces
# exactly that, on a Mac, with no adapter and no car.
#
#   ./run.sh              start the emulator and advertise as "TelltaleELM"
#   ./run.sh --probe      connect to it from an independent BLE client
#   ./run.sh --stop       stop both
#
# READ THIS BEFORE YOU TRUST A NEGATIVE RESULT: a Mac's own central cannot see
# its own peripheral. CoreBluetooth does not loop back, so the macOS build of
# this app running on the same machine will scan and find nothing, and that
# says nothing about either of them. Use a second device as the central — a
# phone with the app installed is the obvious one.
#
# Requires: python3, and Bluetooth turned on. Everything else is created here.
set -euo pipefail

HERE=${0:a:h}
VENV=${TMPDIR:-/tmp}/telltale-ble-rig-venv
APP=${TMPDIR:-/tmp}/BleHost.app
PIDS=${TMPDIR:-/tmp}/telltale-ble-rig
mkdir -p "$PIDS"

stop() {
  for name in emulator bridge; do
    if [[ -f "$PIDS/$name.pid" ]]; then
      kill "$(cat "$PIDS/$name.pid")" 2>/dev/null || true
      rm -f "$PIDS/$name.pid"
      echo "stopped $name"
    fi
  done
  # The bridge is launched through LaunchServices, so its pid is not ours to
  # record. It exits on its own timer; this closes the port it fronts.
}

if [[ "${1:-}" == "--stop" ]]; then stop; exit 0; fi

# 1. The venv. ELM327-emulator is sdist-only and its build backend imports
#    pkg_resources, which setuptools 82 removed (81.0.0 still has it), so the
#    build frontend is pinned and isolation disabled.
if [[ ! -x "$VENV/bin/python" ]]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet "setuptools<82" wheel
  "$VENV/bin/pip" install --quiet --no-build-isolation ELM327-emulator
  "$VENV/bin/pip" install --quiet bless bleak
fi

# 2. The bundle. CoreBluetooth aborts — SIGABRT, no error, no traceback — for
#    any process whose Info.plist lacks NSBluetoothAlwaysUsageDescription, and
#    a bare python3 has no Info.plist at all. TCC attributes the request to the
#    *responsible* process, so running the interpreter from inside a bundle is
#    not enough either: it has to be launched through LaunchServices with
#    `open`, which makes the bundle responsible for itself.
REAL=$(python3 -c 'import os,sys; print(os.path.realpath(sys.executable))')
PREFIX=$("$VENV/bin/python" -c 'import sys; print(sys.base_prefix)')
SITE=$("$VENV/bin/python" -c 'import site; print(site.getsitepackages()[0])')

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$REAL" "$APP/Contents/MacOS/BleHost"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>BleHost</string>
  <key>CFBundleIdentifier</key><string>local.telltale.blehost</string>
  <key>CFBundleName</key><string>BleHost</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSEnvironment</key>
  <dict>
    <key>PYTHONHOME</key><string>${PREFIX}</string>
    <key>PYTHONPATH</key><string>${SITE}</string>
    <key>PYTHONUNBUFFERED</key><string>1</string>
  </dict>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Advertises a simulated ELM327 so the Telltale app can be tested without a car.</string>
  <key>NSBluetoothPeripheralUsageDescription</key>
  <string>Advertises a simulated ELM327 for local testing.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

if [[ "${1:-}" == "--probe" ]]; then
  rm -f /tmp/ble_client.log
  # -n matters: without it `open` reuses the running instance and the second
  # script never starts, leaving an empty log that reads like a crash.
  open -n -a "$APP" --args -u "$HERE/probe.py"
  echo "probing; results in /tmp/ble_client.log"
  exit 0
fi

stop

# 3. The emulator. -b is required: without a batch file this CLI exits the
#    moment its stdin sees EOF, which is what a backgrounded launch gives it.
"$VENV/bin/python" -m elm -n 35000 -s car -b "$PIDS/elm_batch.out" \
  > "$PIDS/emulator.log" 2>&1 &
echo $! > "$PIDS/emulator.pid"

for _ in {1..30}; do
  lsof -nP -iTCP:35000 -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 1
done
lsof -nP -iTCP:35000 -sTCP:LISTEN >/dev/null 2>&1 \
  || { echo "the ELM327 emulator never listened on 35000" >&2; exit 1; }
echo "emulator listening on 35000"

rm -f /tmp/ble_bridge.log
open -n -a "$APP" --args -u "$HERE/bridge.py" "${RIG_SECONDS:-900}"
# Wait for the evidence, not for a guess. A fixed sleep here reported failure
# on the first run of a freshly created venv, where the imports are slower —
# and the peripheral had in fact started a second later.
for _ in {1..40}; do
  grep -q advertising /tmp/ble_bridge.log 2>/dev/null && break
  grep -q FATAL /tmp/ble_bridge.log 2>/dev/null && break
  sleep 1
done
grep -q advertising /tmp/ble_bridge.log 2>/dev/null \
  || { echo "the peripheral did not start; see /tmp/ble_bridge.log" >&2; exit 1; }

echo
echo "advertising as TelltaleELM for ${RIG_SECONDS:-900}s."
echo "On a second device: open Telltale, choose Bluetooth LE, scan, and connect"
echo "to TelltaleELM. Traffic appears in /tmp/ble_bridge.log."
echo "Stop with: $0 --stop"
