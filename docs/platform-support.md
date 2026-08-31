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
**OS-blocked** = host cannot provide the capability · **deferred** = not on
this branch / not yet proven.

| Feature | Android | iOS | macOS | Windows | Linux |
|---|---|---|---|---|---|
| Demo connect → live telemetry UI | **pass** (device + `demo_connect_journey_test`) | **pass** (journey test; sim/device thin) | **pass** (journey + local `Telltale.app` smoke) | **pass** (journey test; device thin) | **pass** (journey test; device thin) |
| Wi‑Fi TCP to adapter | **pass** (+ Android route binder) | **wired** plain TCP | **wired** plain TCP | **wired** plain TCP | **wired** plain TCP |
| BLE scan/connect | **pass** (field) | **wired** CoreBluetooth | **wired** entitlements | **wired** WinRT plugin | **wired** Dart BlueZ/D-Bus (needs BlueZ at runtime) |
| Classic SPP | **pass** | **OS-blocked** (no third-party SPP) | product-gated (unverified) | product-gated | product-gated |
| Transcript export / share | **pass** | **wired** share_plus | **wired** share_plus | **wired** share_plus | **wired** (Dart share + url_launcher; weaker UX) |
| PID CSV pick/share | **pass** | **wired** | **wired** sandbox | **wired** | **wired** |
| SharedPreferences boot | **pass** | **pass** | **pass** | **pass** | **pass** |
| Wakelock while connected | **pass** | **pass** | **pass** | **wired** | no-op (no plugin; intentional) |
| Session telemetry / `app_share*` stack | on `master` checkout, **deferred on this branch** | — | — | — | — |
| CI beyond `flutter build` | analyze + full `flutter test` + APKs | build + functional smoke suite | build + functional smoke suite | build + functional smoke suite | build + functional smoke suite |

## Bluetooth Classic (SPP)

UI predicate: `classicTransportAvailable` → **Android only**. Guidance,
transport cards, and remembered-adapter reconnect all fail closed together.

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

## Desktop / Apple runnable notes

- **macOS:** network client + Bluetooth entitlements; Demo smoke-launched
  locally as `Telltale.app`. SystemChrome orientation skipped on desktop.
- **Windows:** `Telltale` / `telltale.exe`; MSVC coroutine silence for
  `permission_handler_windows`.
- **Linux:** wakelock no-op; Demo / Wi‑Fi / BLE (BlueZ) do not depend on it.
- **iOS:** Classic permanently unavailable; Demo / Wi‑Fi / BLE are the core
  path. Wi‑Fi / guidance copy stays phone-centric on iOS/Android only.

## Still deferred (does **not** meet the full functional bar alone)

- Store packaging (MSIX / Flatpak / notarized DMG)
- Classic desktop enablement with device evidence
- Linux / desktop BLE field verification against a real adapter
- Bringing `master`’s session telemetry / `app_share*` stack onto this branch
- Keyboard/mouse shell density polish
