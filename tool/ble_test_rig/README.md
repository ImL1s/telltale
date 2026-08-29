# Real BLE Test Rig

This macOS-only harness advertises a Nordic UART Service peripheral named
`TelltaleELM` and bridges its CR-terminated commands to Ircama's independent
ELM327 emulator on TCP port 35000. It exercises the app's real GATT connect,
service discovery, CCCD subscription, write, notification, and notification
reassembly paths without an adapter or car.

## Requirements and lifecycle

Run all commands from the Flutter app root: use `cd app` first in the private
`torque` checkout; the public `telltale` repository root is already the app root.

- Apple Silicon macOS with Bluetooth enabled and CPython 3.14
- A second physical device as the BLE central; CoreBluetooth cannot discover a
  peripheral advertised by the same Mac
- For app automation, an attached Android device and the pinned Flutter SDK

```bash
tool/ble_test_rig/run.sh --start     # installs the hash-locked host environment and starts
tool/ble_test_rig/run.sh --status    # succeeds only when both owned processes and advertising are live
tool/ble_test_rig/run.sh --probe     # same-Mac negative control; NOT FOUND is expected
tool/ble_test_rig/run.sh --stop      # stops only this run's verified bridge and emulator PIDs
```

The emulator and BLE host survive the starting shell. Ircama's daemon PID lock
is relocated from its package-global `/tmp` default to the owner-only
`${TMPDIR}/telltale-ble-rig/ircama.pid`. `--stop` verifies a
per-run ownership token before signaling either PID and fails rather than
killing an unowned process. When `RIG_SECONDS` expires, the bridge uses the same
token gate to stop its emulator, so the listener is not left behind. Failed or
interrupted commands also release their OS advisory lock and clean only
processes whose executable, exact argv, token, and start fingerprint match that
run. Expiry reconstructs a missing or partial PID file from that exact identity
before stopping the emulator. The controller mutex remains at
`${DARWIN_USER_TEMP_DIR}/telltale-ble-rig.controller.lock`; using a custom
`TMPDIR` changes only that run's state/evidence directory, so controllers with
different private temporary roots still serialize access to the shared venv,
host app bundle, and port 35000. A lock file's existence does not mean its inode
is currently held.

The bridge carries the controller's selected temporary root into its natural
expiry callback, including when the rig was started with a custom `TMPDIR`.

CoreBluetooth requires a responsible `.app` bundle with Bluetooth purpose
text, so `run.sh` builds `BleHost.app` under the owner-only macOS temporary
directory and launches it through LaunchServices. LaunchServices does not
inherit a terminal's access to protected source trees such as `~/Documents`, so
the controller atomically stages the bridge, probe, emulator entrypoint, exact
process checker, and expiry controller under the owner-only rig state before
launch. It rejects shared, symlinked, or foreign-owned roots and reused rig
directories before executing cached tools. The signed host bundle and its venv
stay under macOS's canonical per-user temporary root even when controller state
uses a custom `TMPDIR`; this keeps the CoreBluetooth TCC code identity stable.
The dependency lock contains hashes for CPython 3.14 Apple Silicon
artifacts; its PyObjC and PyYAML wheels intentionally make it a host lock rather
than a portable Python lock.

## Drive the app

The widget driver cannot approve an Android system permission dialog. For a
fresh install, preinstall the isolated rig APK and grant only the permissions
needed by that Android version:

```bash
FLUTTER=~/fvm/versions/3.47.0/bin/flutter
$FLUTTER build apk --debug --flavor rig \
  --dart-define=TELLTALE_TEST_RIG=true
adb -s <device-id> install -r \
  build/app/outputs/flutter-apk/app-rig-debug.apk

# Android 12 (API 31) and newer:
adb -s <device-id> shell pm grant \
  com.cbstudio.telltale.rig android.permission.BLUETOOTH_SCAN
adb -s <device-id> shell pm grant \
  com.cbstudio.telltale.rig android.permission.BLUETOOTH_CONNECT

# Android 11 (API 30) and older, instead:
adb -s <device-id> shell pm grant \
  com.cbstudio.telltale.rig android.permission.ACCESS_FINE_LOCATION
```

Keep Bluetooth enabled. With the rig healthy, run from the Flutter app root:

```bash
ANDROID_SERIAL=<device-id> \
  ~/fvm/versions/3.47.0/bin/flutter test \
  integration_test/ble_rig_test.dart -d <device-id> \
  --flavor rig \
  --dart-define=TELLTALE_TEST_RIG=true
```

The integration test must find `TelltaleELM`, complete initialization, and
reach the dashboard; absence is a failure, not a skip. The explicit Android
`rig` flavor uses the isolated `com.cbstudio.telltale.rig` application ID and
`Telltale Rig` label, so it coexists with and does not clear the field app's
local data. The rig Activity may wake and appear over a secure keyguard so an
unattended run is not paused before scanning; that exception exists only in the
isolated rig manifest. Normal `field` builds keep ordinary lock-screen behavior,
use `com.cbstudio.telltale`, and remain valid for physical-adapter debugging.
The bridge accepts commands and sends notifications only when exactly one
central is subscribed; zero, multiple, or mismatched centrals fail closed.

## Fault controls and evidence

Set controls only for `--start`:

```bash
RIG_RESPONSE_DELAY_MS=250 RIG_NOTIFY_CHUNK_SIZE=7 \
  tool/ble_test_rig/run.sh --start
RIG_UPSTREAM_DROP_ON_COMMAND=4 tool/ble_test_rig/run.sh --start
```

`RIG_UPSTREAM_DROP_ON_COMMAND` closes the **upstream TCP emulator connection** and
suppresses that command's reply. It does not disconnect GATT. macOS
CoreBluetooth provides no supported peripheral API to force-disconnect a
central, so `RIG_GATT_DROP_ON_COMMAND` and `RIG_GATT_RESTART_MS` are rejected
rather than producing misleading evidence.

Run the hardware-independent harness checks with:

```bash
zsh -n tool/ble_test_rig/run.sh
python3 -m py_compile tool/ble_test_rig/emulator_entrypoint.py \
  tool/ble_test_rig/bridge.py tool/ble_test_rig/probe.py \
  tool/ble_test_rig/process_identity.py tool/ble_test_rig/test_bridge.py \
  tool/ble_test_rig/test_probe.py tool/ble_test_rig/test_process_identity.py \
  tool/ble_test_rig/test_run_controller.py
python3 -m unittest discover -s tool/ble_test_rig -p 'test_*.py' -v
```

- `/tmp/ble_bridge.log`: structured JSONL commands, notification chunks, faults,
  subscription state, and fatal errors
- `/tmp/ble_client.log`: same-Mac negative-control scan and any raw probe replies
- `${TMPDIR}/telltale-ble-rig/events.jsonl`: lifecycle and exact PID ownership
- `${TMPDIR}/telltale-ble-rig/ircama.pid`: Ircama's private daemon PID lock
- `${TMPDIR}/telltale-ble-rig/pip-check.txt`: dependency consistency
- `${TMPDIR}/telltale-ble-rig/dependency-manifest.txt`: installed exact versions

These evidence files contain raw diagnostic traffic and may contain a VIN,
adapter identifier, or device address. They stay local, are created
owner-readable only, and should be reviewed before sharing. Purge them through
the controller when the evidence is no longer needed; it stops and verifies the
rig first, then preserves state lock inodes (per-run stop locks plus any inert
pre-upgrade controller lock). The canonical host-global controller mutex is
outside the evidence directory and is never purged:

```bash
tool/ble_test_rig/run.sh --purge-evidence
```

Never remove the state directory while the rig may be running. Unlinking a
locked pathname does not release its open inode and can let a second controller
create a different lock file while the first process remains alive.

## Evidence boundary

A successful run from a second device proves the real OS GATT path and
deterministic bridge framing. Starting the rig or running the same-Mac negative
probe alone does not. Neither proves Classic Bluetooth RFCOMM, a physical
clone's firmware/timing, CAN-bus responses, ignition/crank behavior, or
real-car link loss. Those remain physical adapter and vehicle tests.
