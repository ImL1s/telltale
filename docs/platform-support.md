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

| Platform | Runner folder | CI compile gate (telltale) | Transports today |
|---|---|---|---|
| Android | `android/` | field + rig APK identities | Demo, Wi-Fi, BLE, Classic SPP |
| iOS | `ios/` | `flutter build ios --no-codesign` | Demo, Wi-Fi, BLE (no Classic SPP — OS limit) |
| macOS | `macos/` | `flutter build macos --debug` | Demo, Wi-Fi, BLE (Classic UI gated off) |
| Windows | `windows/` | `flutter build windows --debug` | Demo, Wi-Fi, BLE (Classic UI gated off) |
| Linux | `linux/` | `flutter build linux --debug` | Demo, Wi-Fi (BLE + Classic UI gated off) |

Bluetooth Classic remains **Android-only in the UI** (`classicTransportAvailable`)
even though the dependency tree registers Classic plugins on other hosts. The
ELM327 SPP path is verified on Android; enabling an untested Classic card on
desktop would recreate the “enabled in UI, broken in practice” failure mode.
Linux CI / local builds still need `libbluetooth-dev` because
`flutter_classic_bluetooth`'s Linux CMake hard-requires BlueZ headers at
configure time.

Bluetooth LE is gated off on Linux (`bleTransportAvailable`): `universal_ble`
has no Linux plugin registrant, so a live BLE card would only surface
`MissingPluginException`. Windows/macOS/iOS/Android keep BLE enabled where the
plugin registers.

Windows CI needs `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS` in
`windows/CMakeLists.txt` so MSVC 14.51+ does not hard-fail
`permission_handler_windows` on deprecated `<experimental/coroutine>`.

## First enablement vs later work

**This tranche (compile + scaffold):** add Windows/Linux runners, brand them as
Telltale, and refuse to merge if either desktop target fails to build on
public telltale CI.

**Later tranches:** store packaging (MSIX / Flatpak / notarized DMG), Classic
desktop enablement with device evidence, Linux BLE (BlueZ / `universal_ble`
Linux registrant) with field verification, Windows signing for community
builds, and shell density tweaks for keyboard/mouse primary layouts.
