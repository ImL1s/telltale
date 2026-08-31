# Platform support

Telltale is a Flutter app. The Dart package name stays `torque_obd`; the product
identity users see is **Telltale** / `com.cbstudio.telltale`.

## Matrix

| Platform | Runner folder | CI compile gate | Transports today |
|---|---|---|---|
| Android | `android/` | field + rig APK identities | Demo, Wi-Fi, BLE, Classic SPP |
| iOS | `ios/` | `flutter build ios --no-codesign` | Demo, Wi-Fi, BLE (no Classic SPP — OS limit) |
| macOS | `macos/` | `flutter build macos --debug` | Demo, Wi-Fi, BLE (Classic UI gated off) |
| Windows | `windows/` | `flutter build windows --debug` | Demo, Wi-Fi, BLE (Classic UI gated off) |
| Linux | `linux/` | `flutter build linux --debug` | Demo, Wi-Fi, BLE via BlueZ where available (Classic UI gated off) |

Bluetooth Classic remains **Android-only in the UI** (`classicTransportAvailable`)
even though the dependency tree registers Classic plugins on other hosts. The
ELM327 SPP path is verified on Android; enabling an untested Classic card on
desktop would recreate the “enabled in UI, broken in practice” failure mode.

## First enablement vs later work

**This tranche (compile + scaffold):** add Windows/Linux runners, brand them as
Telltale, and refuse to merge if either desktop target fails to build.

**Later tranches:** store packaging (MSIX / Flatpak / notarized DMG), Classic
desktop enablement with device evidence, Linux BLE field verification, Windows
signing for community builds, and shell density tweaks for keyboard/mouse
primary layouts.
