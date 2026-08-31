# Platform support

Telltale is a Flutter app. The Dart package name stays `torque_obd`; the product
identity users see is **Telltale** / `com.cbstudio.telltale`.

## Verification backbone

Private `ImL1s/torque` Actions may be unavailable (billing). **Public
`ImL1s/telltale` CI is the authoritative remote compile matrix** for this
enablement: Android (field/rig APK), Apple (iOS + macOS), Linux, and Windows
jobs on free runners. Product code still originates in private `app/` and is
archive-synced; telltale `.github/` is publish-only and carries the desktop
gates independently.

## Matrix

| Platform | Runner folder | CI compile gate (telltale) | Core transports (OS-allowed) |
|---|---|---|---|
| Android | `android/` | field + rig APK identities | Demo, Wi-Fi, BLE, Classic SPP |
| iOS | `ios/` | `flutter build ios --no-codesign` | Demo, Wi-Fi, BLE |
| macOS | `macos/` | `flutter build macos --debug` | Demo, Wi-Fi, BLE |
| Windows | `windows/` | `flutter build windows --debug` | Demo, Wi-Fi, BLE |
| Linux | `linux/` | `flutter build linux --debug` | Demo, Wi-Fi, BLE (BlueZ/D-Bus) |

“Supported” here means a **runnable app path** with Demo and Wi-Fi at minimum,
plus BLE where the host stack exists — not merely `flutter build` succeeding.
Classic SPP is called out separately below.

## Bluetooth Classic (SPP) — permanent / product host gates

UI predicate: `classicTransportAvailable` → **Android only**. Guidance,
transport cards, and remembered-adapter reconnect all fail closed on the same
predicate.

| Host | Status | Why |
|---|---|---|
| Android | Supported | Verified ELM327 RFCOMM/SPP path |
| iOS | **Permanent OS/API host gate** | Third-party apps cannot open generic SPP; External Accessory / MFi only. Not a product bug and not a CI failure. |
| macOS / Windows / Linux | **Product verification gate** | `flutter_classic_bluetooth` registers plugins, but this app has not field-verified ELM327 SPP on desktop. Card stays greyed until that evidence exists. |

Linux CI / local builds still need `libbluetooth-dev` because
`flutter_classic_bluetooth`'s Linux CMake hard-requires BlueZ headers at
configure time, even while the Classic **card** stays gated off.

## Bluetooth LE

UI predicate: `bleTransportAvailable` → **true on every shipping host**.

`universal_ble` provides:

- Native pigeon plugins on Android, iOS, macOS, Windows (listed in each
  platform’s `generated_plugins.cmake` / registrant).
- A **Dart BlueZ** backend on Linux (`package:bluez` over D-Bus). There is
  intentionally **no** Linux Flutter plugin registrant — absence from
  `linux/flutter/generated_plugins.cmake` is correct, not a missing
  implementation.

Runtime on Linux needs a working BlueZ stack (D-Bus). Compile CI does not need
a Bluetooth adapter. Field evidence with a real ELM327 BLE dongle on Linux is
still desirable; the UI path is no longer blocked by the earlier
`MissingPluginException` misdiagnosis.

## Desktop / Apple runnable notes

- **macOS:** sandbox entitlements include network client + Bluetooth; Demo and
  Wi-Fi TCP are in-tree. Debug Profile also allows JIT + local server for
  tooling.
- **Windows:** runner branded `Telltale` / `telltale.exe`. MSVC needs
  `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS` so 14.51+ does not
  hard-fail `permission_handler_windows` on deprecated
  `<experimental/coroutine>`.
- **Linux:** wakelock is a deliberate no-op (`wakelock_plus` has no Linux
  plugin); Demo / Wi-Fi / BLE do not depend on it.
- **iOS:** Classic permanently unavailable; Demo / Wi-Fi / BLE remain the core
  path. Local-network usage string is set for Wi-Fi adapter joins.

## First enablement vs later work

**Done (compile + scaffold + core transport honesty):** Windows/Linux runners,
public telltale compile matrix, Classic fail-closed (iOS permanent + desktop
unverified), Linux BLE UI enabled via BlueZ Dart path.

**Still deferred:** store packaging (MSIX / Flatpak / notarized DMG), Classic
desktop enablement with device evidence, Linux BLE field verification against
a real adapter, Windows signing for community builds, and shell density tweaks
for keyboard/mouse primary layouts.
