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
| Demo connect → live telemetry UI | **pass** (device + `demo_connect_journey_test`) | **wired** (iOS build gate; journey suite runs on macOS host, not an iOS sim) | **pass** (journey + local `Telltale.app` smoke) | **pass** (journey test; device thin) | **pass** (journey test; device thin) |
| Session telemetry record / replay / export | **pass** (unit + rigs; field thin) | **wired** (same Dart stack; device thin) | **pass** (`telemetry_demo_journey` + `desktop_telemetry_share_smoke`; interactive sheet thin) | **pass** (same automated path on Windows runner; sheet soft-fail OK) | **pass** (same automated path on Linux runner; sheet soft-fail OK) |
| `app_share*` prepare → platform handoff | **pass** (native + unit) | **wired** (`share_plus`) | **pass** (native `MethodChannel` + unit) | **wired** (`share_plus`; soft-fail OK if file staged) | **wired** (`share_plus`; soft-fail OK if file staged) |
| Wi‑Fi TCP to adapter | **pass** (+ Android route binder) | **wired** plain TCP | **wired** plain TCP | **wired** plain TCP | **wired** plain TCP |
| BLE scan/connect | **pass** (field) | **wired** CoreBluetooth | **wired** entitlements | **wired** WinRT plugin | **wired** Dart BlueZ/D-Bus (needs BlueZ at runtime) |
| Classic SPP | **pass** | **OS-blocked** (no third-party SPP) | product-gated (unverified) | product-gated | product-gated |
| Transcript export / share | **pass** (via `app_share*`) | **wired** | **wired** / native macOS path | **wired** | **wired** (sheet failure is non-fatal) |
| PID CSV pick/share | **pass** | **wired** | **wired** sandbox | **wired** | **wired** |
| SharedPreferences boot | **pass** | **pass** | **pass** | **pass** | **pass** |
| Wakelock while connected | **pass** | **pass** | **pass** | **wired** | no-op (no plugin; intentional) |
| CI beyond `flutter build` | analyze + full `flutter test` + APKs | build + functional smoke suite | build + functional smoke suite | build + functional smoke suite | build + functional smoke suite |

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

## Desktop / Apple runnable notes

- **macOS:** network client + Bluetooth entitlements; Demo smoke-launched
  locally as `Telltale.app`. SystemChrome orientation skipped on desktop.
  Share uses the native `com.cbstudio.telltale/app_share` channel.
  `default-flavor: field` requires matching Xcode scheme + configs (`field.xcscheme`, `Debug-field`/`Release-field`/`Profile-field`);
  Android-only `rig` stays out of Apple schemes.
- **Windows:** `Telltale` / `telltale.exe`; MSVC coroutine silence for
  `permission_handler_windows` (plural `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS`,
  matching MSVC STL1011’s own suppress token).
- **Linux:** wakelock no-op; Demo / Wi‑Fi / BLE (BlueZ) do not depend on it.
- **iOS:** Classic permanently unavailable; Demo / Wi‑Fi / BLE are the core
  path. Wi‑Fi / guidance copy stays phone-centric on iOS/Android only.
  Same `field` scheme requirement as macOS for `default-flavor`.

## Still deferred (does **not** meet the full functional bar alone)

- Store packaging (MSIX / Flatpak / notarized DMG)
- Classic desktop enablement with device evidence
- Linux / desktop BLE field verification against a real adapter
- Interactive share-sheet target present on every desktop host (file staging
  + soft-fail is proven; human “Save/Share…” confirmation is not)
- iOS simulator/device run of the Demo journey (CI still uses the macOS test host)
- Keyboard/mouse shell density polish
