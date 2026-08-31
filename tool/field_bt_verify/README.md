# Field Bluetooth verification (physical adapter)

One command to run when the OBD dongle is powered and the phone is in range.
Proves **Connect → live PIDs → short record** on the shipped Android `field`
flavor against a bonded adapter (default name `OBDBLE` / `OBDII`).

This is **not** the macOS `ble_test_rig` (synthetic `TelltaleELM` peripheral).
It is also **not** a skip-on-absence gate: bonded-but-ACL-down is a hard fail
and never reported as a field pass.

## Requirements

- Attached Android phone (default serial `R5CX10VFFBA`)
- Bluetooth ON; adapter bonded (System Settings)
- Dongle powered (vehicle ignition / USB) so ACL LE or BR/EDR is **Y**
- Pinned Flutter: `~/fvm/versions/3.47.0/bin/flutter`

## Usage

From the Flutter app root (`app/` in the private repo, repo root on telltale):

```bash
tool/field_bt_verify/run.sh
```

Useful variants:

```bash
# ACL / bonded inventory only — no APK install, no journey
tool/field_bt_verify/run.sh --probe-only

# Classic SPP instead of BLE (OBDBLE also exposes SPP)
FIELD_BT_TRANSPORT=classic tool/field_bt_verify/run.sh

# Reuse an already-installed field debug build
FIELD_BT_SKIP_INSTALL=1 tool/field_bt_verify/run.sh

# Deliberately attempt the journey even when ACL is down (still fails closed)
tool/field_bt_verify/run.sh --force-journey
```

## What it writes

Under `docs/verification/`:

| File | Contents |
|---|---|
| `field-bt-dumpsys-<utc>.txt` | Raw `dumpsys bluetooth_manager` |
| `field-bt-probe-<utc>.txt` | Pass/fail ACL verdict + OBD string hits |
| `field-bt-journey-<utc>.log` | Flutter integration-test output (journey runs only) |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Journey PASS (or `--probe-only` with ACL up) |
| 2 | Bonded but ACL down — dongle unpowered / out of range |
| 3 | Expected adapter name not in bonded list |
| 1 | Tooling, install, or journey failure |

## Install warning

A full journey builds and installs **`app-field-debug.apk`** over
`com.cbstudio.telltale`. That replaces a Play-signed build on the phone until
you reinstall from the store. Use `FIELD_BT_SKIP_INSTALL=1` when a field debug
build is already present, or `--probe-only` when you only want the ACL check.

## Harness checks (no phone)

```bash
python3 -m unittest discover -s tool/field_bt_verify -p 'test_*.py' -v
zsh -n tool/field_bt_verify/run.sh
```
