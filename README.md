**English** | [繁體中文](README.zh-TW.md)

# Telltale

[![CI](https://github.com/ImL1s/telltale/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/ImL1s/telltale/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/ImL1s/telltale?include_prereleases&sort=semver&label=latest%20release)](https://github.com/ImL1s/telltale/releases)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

Telltale is an open-source Flutter app for real-time vehicle telemetry and OBD2
fault diagnosis through an ELM327-compatible adapter. It is designed to expose
uncertainty instead of turning malformed, incomplete, or conflicting replies
into confident-looking results.

> **A plausible wrong number is worse than no number.**

## Download and install

**[Download an APK from GitHub Releases](https://github.com/ImL1s/telltale/releases).**
Open the newest prerelease and select its `.apk` asset. Release binaries are not
stored in the source tree.

GitHub APKs use a community signing key. They cannot update, or be updated by,
the Google Play build. Switching between them requires uninstalling Telltale;
export anything you need first because uninstalling removes local app data.

## What it supports

- Bluetooth Classic using RFCOMM/SPP
- Bluetooth LE using a GATT UART service
- Wi-Fi adapters using a local TCP connection
- A built-in Demo ECU that needs no adapter or vehicle
- Live PID dashboards, fault codes, freeze frames, readiness, custom PIDs, and
  user-triggered diagnostic transcript export

Android is the primary physically tested platform for device, UI, and BLE-rig
paths. iOS and macOS currently have compile gates, not equivalent physical-
adapter or vehicle evidence. Bluetooth Classic
is Android-only in practice because Apple platforms do not expose general
RFCOMM/SPP accessories to third-party apps.

## Build and test

Use the pinned Flutter 3.47.0 toolchain:

```bash
git clone https://github.com/ImL1s/telltale.git
cd telltale
FLUTTER="$HOME/fvm/versions/3.47.0/bin/flutter"
"$FLUTTER" pub get
"$FLUTTER" analyze
"$FLUTTER" test
"$FLUTTER" build apk --debug --flavor field
```

For a self-signed release build, follow
[the maintainer release guide](docs/maintainers/release.md). The `field` flavor
is the real-use application; the isolated `rig` flavor is test infrastructure.

## Verification boundary

The real Samsung-to-Mac BLE GATT radio path has passed with a simulated ELM327
peripheral. This proves physical BLE discovery, GATT connection, UART writes,
and notifications on that path. It does **not** verify a purchased adapter such
as CAR25, its firmware or profile, an ECU/CAN bus, or any real vehicle.

Verification reports describe bounded evidence, not certification or a safety
guarantee. Start with [test evidence](docs/verification/test-evidence.md) and
[device verification](docs/verification/device-verification.md).

## Repository layout

| Path | Purpose |
| --- | --- |
| `lib/` | App, state, UI, ELM327 protocol, and transports |
| `test/` | Unit, contract, parser, and widget tests |
| `integration_test/` | Device and isolated rig flows |
| `tool/` | Deterministic simulators and verification tooling |
| `android/`, `ios/`, `macos/` | Platform integration |
| `assets/` | Bundled fonts and icons |

## Documentation

| Document | Purpose |
| --- | --- |
| [Documentation index](docs/README.md) | All user, evidence, and maintainer documents |
| [Field guide](docs/field-guide.zh-TW.md) | Safe real-car workflow and troubleshooting (zh-TW) |
| [Protocol deviations](docs/protocol-deviations.zh-TW.md) | Standards and hardware-behaviour notes (zh-TW) |
| [Changelog](CHANGELOG.md) | User-visible changes by version |
| [Contributing](CONTRIBUTING.md) | Development and pull-request requirements |

## Privacy and safe use

Telltale proactively uploads nothing. Local diagnostic exports can contain VIN,
device, adapter, and fault identifiers. You control explicit export and sharing;
operating-system backup may also copy private app data according to device
settings. Read [the repository policy](PRIVACY.md) or the
[published privacy policy](https://iml1s.github.io/telltale/privacy.html).

Use the app only while parked or as a passenger. Save diagnostic evidence before
clearing DTCs, and do not treat this app as a substitute for professional
inspection. See [SECURITY.md](SECURITY.md) for private vulnerability reporting
and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community expectations.

## Licence and disclaimer

Contributions are welcome under the [contributor guide](CONTRIBUTING.md).
Telltale is licensed under [GPL-3.0](LICENSE). It is not affiliated with Ian
Hawkins' Torque or Torque Pro and is neither an official nor derivative version
of either product. Use it at your own risk; no diagnostic result guarantees that
a vehicle is safe to operate.
