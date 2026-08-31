# Platform support

Telltale is a Flutter app. The Dart package name stays `torque_obd`; the product
identity users see is **Telltale** / `com.cbstudio.telltale`.

## Verification backbone

Private `ImL1s/torque` Actions may be unavailable (billing). **Public
`ImL1s/telltale` CI is the authoritative remote matrix** for multiplatform
enablement. Compile gates are necessary but **not sufficient**: functional
smoke (Demo journey, Wi‑Fi TCP unit path, export, host gates) must also pass
on free runners. Product code still originates in private `app/` and is
archive-synced; telltale `.github/` is publish-only.

## Functional matrix (honest)

Legend: **pass** = exercised by automated test and/or local run evidence on
this branch · **wired** = code path present, field/device evidence still thin ·
**OS-blocked** = host cannot provide the capability · **deferred** = not yet
proven to the full smoothness bar.

| Feature | Android | iOS | macOS | Windows | Linux |
|---|---|---|---|---|---|
| Demo connect → live telemetry UI | **pass** (device + `demo_connect_journey_test`) | **pass** (`integration_test/ios_field_demo_journey_test` on iPhone 17 Pro sim, field flavor) | **pass** (journey + local `Telltale.app` / macOS field share journey) | **pass** (journey test; device thin) | **pass** (journey test; device thin) |
| Session telemetry record / replay / export | **pass** (unit + rigs; field thin) | **pass** (iOS sim Demo record → durable `.ndjson`; export UI thin) | **pass** (`telemetry_demo_journey` + macOS field share journey staged CSV) | **pass** (automated path; sheet soft-fail OK) | **pass** (automated path; sheet soft-fail OK) |
| `app_share*` prepare → platform handoff | **pass** (native + unit) | **wired** (`share_plus` + iPad `sharePositionOrigin` on all export entry points) | **pass** (native capacity + staged immutable file + `app_share` channel; picker target still human) | **wired** (capacity + staging; `shareHandoffFailed` when sheet unavailable — not silent success) | **wired** (capacity + staging; `shareHandoffFailed` when sheet unavailable — not silent success) |
| Wi‑Fi TCP to adapter | **pass** (+ Android route binder) | **pass** (`tool/ios_wifi_oracle/run.sh`: Simulator → host `en0` Ircama on `:35000`, live PIDs, `TransportKind.wifi`) | **pass** (`WifiTransport` → Ircama on `127.0.0.1:35000` via `emulator_integration_test` / `tool/desktop_wifi_oracle/run.sh`) | **pass** (same Dart `WifiTransport` oracle path; Windows-host oracle thin) | **pass** (telltale CI Ircama oracle + same suite) |
| BLE scan/connect | **pass** (field) | **wired** CoreBluetooth | **wired** entitlements | **wired** WinRT plugin | **wired** Dart BlueZ/D-Bus (needs BlueZ at runtime) |
| Classic SPP | **pass** | **OS-blocked** (no third-party SPP) | product-gated (unverified) | product-gated | product-gated |
| Transcript export / share | **pass** (via `app_share*`) | **wired** (popover origin threaded) | **pass** (native macOS path through staging; failed handoff is explicit) | **wired** (staged file + explicit handoff failure copy) | **wired** (staged file + explicit handoff failure copy) |
| PID CSV pick/share | **pass** | **wired** (popover origin threaded) | **wired** sandbox | **wired** | **wired** |
| SharedPreferences boot | **pass** | **pass** | **pass** | **pass** | **pass** |
| Wakelock while connected | **pass** | **pass** | **pass** | **wired** | no-op (no plugin; intentional) |
| CI beyond `flutter build` | analyze + full `flutter test` + APKs | build + functional smoke suite | build + functional smoke + unsigned `.app` zip artifact | build + functional smoke + unsigned Debug zip artifact | build + functional smoke + unsigned bundle tarball artifact |

## Bluetooth Classic (SPP)

UI predicate: `classicTransportAvailable` → **Android only**. Guidance,
transport cards, and remembered-adapter reconnect all fail closed together.
Automated coverage: `which_transport_test`, `remembered_adapter_navigation_test`,
and reconnect host-gate tests. **Classic-on-iOS is not a bug** — the card stays
grey with an explicit OS reason. BLE empty-scan / “which transport” copy never
points at Classic when the host gate is closed.

| Host | Status | Why |
|---|---|---|
| Android | Supported | Verified ELM327 RFCOMM/SPP |
| iOS | **Permanent OS/API host gate** | No generic third-party SPP |
| macOS / Windows / Linux | Product verification gate | Plugins exist; ELM327 SPP not field-verified — card stays grey |

Linux CI still needs `libbluetooth-dev` because `flutter_classic_bluetooth`'s
Linux CMake requires BlueZ headers at configure time.

## Bluetooth LE

`bleTransportAvailable` → **true** on every shipping host.

- Android / iOS / macOS / Windows: `universal_ble` native plugins.
- Linux: Dart BlueZ backend (`package:bluez` over D-Bus). **No** Flutter
  plugin registrant is expected. Runtime needs BlueZ; compile CI does not need
  an adapter. Field evidence with a real ELM327 BLE dongle on Linux is still
  required before calling Linux BLE “mature”.

Automated coverage stays at transport-gate / reconnect UX level unless a
device or simulator is attached; do not treat green CI as a field BLE pass.
This machine currently has **no ELM327-named BLE adapter** paired — leave
BLE/Classic field rows as blocked-by-hardware.

## Desktop / Apple runnable notes

- **macOS:** network client + Bluetooth entitlements; Demo smoke-launched
  locally as `Telltale.app`. SystemChrome orientation skipped on desktop.
  Share uses the native `com.cbstudio.telltale/app_share` channel after
  `app_storage_capacity`. Field debug share journey
  (`integration_test/macos_field_share_journey_test.dart`) proves capacity →
  Demo record → immutable staged CSV handoff; the OS picker itself is still a
  human step. Failed/unavailable handoffs return `shareHandoffFailed` with
  clear copy (file staged, sheet did not open) — never a silent success.
  Desktop Wi‑Fi functional evidence: `tool/desktop_wifi_oracle/run.sh` starts
  Ircama with `-d` (required on macOS background shells) and runs
  `emulator_integration_test.dart` (`ELM_ORACLE_REQUIRED`) proving handshake,
  VIN, live RPM/speed polling, record, and export over `WifiTransport`.
  Unsigned packaging: `tool/packaging/macos_dmg.sh` (notarization called out,
  not automated). `default-flavor: field` requires matching Xcode scheme +
  configs (`field.xcscheme`, `Debug-field`/`Release-field`/`Profile-field`);
  Android-only `rig` stays out of Apple schemes.
- **Windows / Linux:** runners now register
  `com.cbstudio.telltale/app_storage_capacity` (`GetDiskFreeSpaceExW` /
  `statvfs`) so share preflight is no longer a permanent `shareSpaceUnknown`
  dead-end. When the interactive sheet cannot open, UX reports staged-but-
  handoff-failed instead of pretending the picker confirmed. Packaging:
  `tool/packaging/windows_zip.sh` / `linux_tarball.sh` (MSIX / AppImage /
  Flatpak stubs documented beside them).
- **Windows:** `Telltale` / `telltale.exe`; MSVC coroutine silence for
  `permission_handler_windows` (plural `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS`,
  matching MSVC STL1011’s own suppress token).
- **Linux:** wakelock no-op; Demo / Wi‑Fi / BLE (BlueZ) do not depend on it.
  Public telltale CI runs the Ircama Wi‑Fi oracle on Linux runners.
- **iOS:** Classic permanently unavailable; Demo / Wi‑Fi / BLE are the core
  path. Field Simulator evidence:
  `integration_test/ios_field_demo_journey_test.dart` (Demo → live PIDs →
  record → durable session file) and
  `tool/ios_wifi_oracle/run.sh` / `ios_field_wifi_oracle_test.dart` (Simulator
  → host LAN `en0` Ircama → handshake → live PIDs on `TransportKind.wifi`).
  The BLE entrypoint stays loopback-only by default; the iOS Wi‑Fi harness
  sets `ELM_BIND_INTERFACE=0.0.0.0` for that run only. Same `field` scheme
  requirement as macOS for `default-flavor`. All share entry points
  (telemetry, raw/recovered transcript, PID CSV) accept `sharePositionOrigin`
  for iPad popovers.

## Hardware inventory (this workstation, 2026-09-01)

- Android attached: `R5CX10VFFBA` (S24 Ultra), `RFCNC0WNT9H`, `emulator-5554`.
- Bluetooth controller on; paired accessories are phones/keyboards/earbuds —
  **no ELM327-named BLE/Classic adapter**. BLE/Classic field rows stay
  hardware-blocked.
- iOS Simulator Demo + LAN Wi‑Fi oracle already evidenced on this branch
  (host `en0` = `192.168.1.135` at time of proof).

## Still deferred (does **not** meet the full functional bar alone)

- Store packaging (signed MSIX / Flathub Flatpak / notarized DMG) — unsigned
  zip/tarball/DMG recipes exist under `tool/packaging/` and CI uploads debug
  archives
- Classic desktop enablement with device evidence
- Linux / desktop BLE field verification against a real adapter
- Human confirmation of every desktop share-sheet target (macOS staging +
  channel handoff is proven; picker selection is not automated)
- Keyboard/mouse shell density polish
