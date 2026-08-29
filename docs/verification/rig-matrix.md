# Verification rig matrix / 可驗證馬具矩陣

Inventory date: 2026-08-29. This is an evidence map, not a compatibility list.
"Available" below means either reproducibly runnable from this repository or
described on a current first-party product page. Commercial rigs marked
**identified only** have not been purchased or run by this project.

本頁是證據分層，不是「全車型認證」。模擬器能驗 App、解析與傳輸邏輯；
只有實車只讀測試能證明某一部車、某一支轉接器與某一支手機的組合。

## Evidence ladder

| Level | Rig / surface | Status | What it establishes | What it does **not** establish |
| --- | --- | --- | --- | --- |
| L0 | `test/support/fake_elm327.dart` and unit/contract/widget tests | Run in CI | Parser, scheduler, formula, evidence and fail-closed behaviour for every modelled ELM327 bus family, including injected malformed replies | It is project-authored, in-process evidence. Fixture and production code can share the same mistaken assumption. |
| L0 | Built-in Demo ECU + `integration_test/demo_rig_test.dart` | Runnable; passed in recorded physical-device runs | Shipped UI, session lifecycle, Mode 01/03/04/09 flows and simulated-evidence labelling | No OS socket/radio, adapter, OBD connector, ECU or vehicle. |
| L1 | [Ircama/ELM327-emulator](https://github.com/Ircama/ELM327-emulator) v3.0.5 + `emulator_integration_test.dart` | Hash-locked external oracle in CI | The client works against an independently implemented ELM327 conversation; the repo exercises its 11-bit CAN scenario over TCP | Its default scenario is not a GT86 or any real vehicle. It does not prove adapter firmware, electrical CAN, timing or vehicle support. Its CC BY-NC-SA code is not copied into the app. |
| L1 | Ircama through `tool/obd_test_rig/chaos_proxy.py` + `chaos_oracle_test.dart` | Run in CI | Real TCP framing plus deterministic fragmentation, delay, peer close, missing prompt and critical-reply corruption | Physical radio loss, adapter reset, CAN arbitration and uninjected faults. |
| L1 | Project-owned `elm327_virtual_server.py` + `freeze_frame_oracle_test.dart` | Fetched from a reviewed private research-branch commit, hash-pinned, and required in CI | A separately maintained oracle's Mode 02, DTC classes, readiness, VIN reassembly, multi-controller census, deadline and mid-session drop shapes | It is not an independent third-party implementation; it is still a software server and currently an 11-bit CAN oracle. |
| L2 | Android Wi-Fi rig + `integration_test/wifi_rig_test.dart` | Runnable on Android device/emulator | Shipped wizard and real Android TCP path; on a non-loopback physical run, Android route binding | A purchased Wi-Fi adapter or an ECU/vehicle. |
| L2 | macOS CoreBluetooth peripheral/bridge + Android `integration_test/ble_rig_test.dart` | Physical Samsung-to-Mac run passed | Real BLE scan, GATT connect, service discovery, CCCD, UART writes, notifications and reassembly | The peripheral/ECU are simulated; it does not certify a commercial BLE adapter. |
| L2- | `integration_test/classic_rig_test.dart` | Plugin-boundary rig | Wizard selection and Flutter method/event-channel wiring for Classic | It mocks the native boundary. It does **not** prove Android `BluetoothSocket`, RFCOMM or radio behaviour. |
| L3 | [Freematics OBD-II Emulator MK2](https://freematics.com/pages/products/freematics-obd-emulator-mk2/) | **Identified only; not purchased/run** | With a real ELM/BLE/Wi-Fi adapter plugged into its OBD socket, it can exercise physical power/pinout and selectable CAN 11/29-bit, ISO 9141-2 and KWP paths; the vendor lists optional J1850 support | It is not a vehicle and cannot reproduce a GT86 ECU, real bus load/arbitration, ignition/crank, harness faults or proprietary services. |
| L3 | [ECUsim 2000](https://www.obdsol.com/solutions/development-tools/obd-simulators/ecusim-2000/) | **Identified only; availability and configuration must be confirmed before purchase** | The vendor describes all five legislated protocol families: J1850 PWM/VPW, ISO 9141, ISO 14230 KWP and ISO 15765 CAN | No project run exists, so it currently contributes no product evidence. It is also not a real vehicle. |
| L4 | Purchased CL-OBDII-M25B + Samsung `SM-S9280` + one Toyota GT86 | One bounded 2026-08-27 field observation | BLE, adapter and one real CAN 11-bit/500 kbit/s vehicle session worked together; a private transcript supplied real response/framing regression shapes | No other unit, phone, model year, trim, ECU, PID accuracy, DTC coverage or vehicle model. |

The ELM protocol terminology is cross-checked against the
[ELM Electronics OBD product documentation](https://elmelectronics.com/products/ics/obd/).
External product pages can change; re-check model, protocol options, licence,
stock and price before spending money.

## Protocol coverage and the honest gap

| Bus family | External/software oracle | Physical OBD simulator | Real vehicle evidence |
| --- | --- | --- | --- |
| ISO 15765-4 CAN 11-bit / 500 kbit/s | Ircama, virtual server, Demo, FakeElm327 | Identified but not yet run | One GT86 setup |
| ISO 15765-4 CAN 11-bit / 250 kbit/s | FakeElm327 only | Freematics/ECUsim identified, not run | None |
| ISO 15765-4 CAN 29-bit / 500 or 250 kbit/s | FakeElm327 only | Freematics/ECUsim identified, not run | None |
| ISO 9141-2 | FakeElm327 only | Freematics/ECUsim identified, not run | None |
| ISO 14230-4 KWP (5-baud / fast) | FakeElm327 only | Freematics/ECUsim identified, not run | None |
| SAE J1850 PWM / VPW | FakeElm327 only | Optional Freematics configuration or ECUsim identified, not run | None |

This is why the product must not say "all vehicles verified." The generic fix
is fail-closed instead: raw OBD readings remain available, while horsepower,
torque and consumption estimates stay hidden until the driver reviews and
confirms the complete vehicle profile for that connection. Editing any profile
field or starting another connection invalidates that confirmation. A VIN
alone cannot supply loaded mass, volumetric
efficiency, frontal area, rolling resistance or actual drivetrain losses.

## Reproducible checks

From the repository's public-app root:

```bash
FLUTTER="$HOME/fvm/versions/3.47.0/bin/flutter"
"$FLUTTER" pub get
"$FLUTTER" analyze
"$FLUTTER" test

python3 -m unittest discover -s tool/ble_test_rig -p 'test_*.py' -v
python3 -m unittest discover -s tool/obd_test_rig -p 'test_*.py' -v
```

The external-oracle job in `.github/workflows/ci.yml` starts both software
oracles, runs the Flutter tests in required mode, parses the JSON test events,
and fails if any oracle case was skipped. A green ordinary `flutter test` with
the oracle port closed is not oracle evidence.

## Field-data privacy boundary

The private GT86 export is not committed because it contains a VIN and device
identifiers. Public regression fixtures retain only protocol shapes and
synthetic sensor bytes: split reset/banner delivery, support masks, a
`7F 01 12` negative response, and a three-segment headers-off batch. They do
not contain a VIN, MAC address, UUID, session identifier or vehicle-unique
payload.
