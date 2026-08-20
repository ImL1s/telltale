# Changelog

Versions read `x.y.z+N`. The left half is what a person sees; `N` is the
Android `versionCode`, which Google Play requires to increase strictly and
which therefore does not always move in step with the name.

Dates are the date the build was made, not the date it reached anyone.

## 1.0.1+2 — 2026-08-18

Published to Google Play's internal testing track, replacing 1.0.0+1, and
attached to the production draft. The production submission is still a draft.

### Changed

- **Bluetooth LE now runs on `universal_ble` 2.1.1 (BSD-3-Clause).** The
  previous package's licence requires a paid commercial licence for "any use …
  by or for a for-profit company or corporation — including commercial use by
  individuals", and this app is sold; the code declared a non-profit licence,
  which was false. The same licence also reserves the right to send build-time
  telemetry — package name, app name, version, date — which does not sit with a
  privacy policy that says nothing is collected. The replacement has neither
  term, and the merged `AndroidManifest.xml` is byte-for-byte unchanged, so no
  permission the app asks for has changed. Rationale in `SPEC_DEVIATIONS.md` §5.

  Four behavioural differences between the two packages had to be handled.
  Three of them would otherwise have been real bugs and are listed under Fixed
  below. The fourth changed only what the app must not do: the new package
  emits one event per advertisement rather than an accumulated list, so a
  consumer that appends would now duplicate every repeat advertisement. The
  scan screen already upserted by id, so nothing about the list changed.

### Fixed

- **Adapters that only support `indicate` now connect.** In the previous
  package one call subscribed either way; in the new one notify and indicate
  are separate calls that throw when the property is absent. A clone that
  indicates rather than notifies would never have completed a connection.
- **Adapters with a non-ASCII name are shown by name.** `BleDevice` strips
  non-ASCII characters in its constructor, so every Chinese-named adapter would
  have appeared as `未命名裝置`. The name now falls back through the raw
  advertisement before giving up, and giving up prints the address rather than
  nothing.
- **A refused MTU negotiation costs throughput, not the connection.** MTU is
  requested after the link is up rather than as part of `connect()`, so an
  adapter that refuses 185 bytes still works, more slowly.
- **A safety refusal is no longer reported as a fact about the car.** When the
  allowlist rejected a service that is not read-only, the screen said
  `此車輛不支援` — a claim about the vehicle with no evidence about the vehicle
  behind it. It has its own fault state now.
- **Horsepower and torque disappear together when acceleration is missing.**
  The rule that hides an unmeasured figure lived in one widget that no test
  loaded by any path.

### Internal

No user-visible change, recorded because they are the reason to trust the rest.

- `BleTransport` has unit tests for the first time — 18, against a scripted
  peripheral that emits a banner during the CCCD write, indicates instead of
  notifying, advertises a CJK name, advertises nothing, refuses an MTU, and
  drops the link mid-discovery. The new package's `setInstance` is what made a
  seam possible; the previous one had none.
- **The reference implementations' assertions were never running.**
  `dart run file.dart` disables assertions, so all three Dart examples printed
  their success banner and exited 0 with deliberately broken expectations.
  They now use throwing checks, which are honest with or without the flag.
- **An oracle had silently stopped checking.** One integration test armed its
  completer 400 ms after `ATZ`, shorter than the emulator's modelled reset, so
  a late banner satisfied it and the identifying answer never arrived: five
  tests skipped and the suite still exited 0 — three of six consecutive runs
  did that, and all six were green. Fixed by waiting for evidence in both
  phases: the polling drain its sibling already used for the second phase,
  extended to the reset as well, rather than a bigger constant.
- The three-language parity contract in `CLAUDE.md` claimed identical class
  names, method decomposition and test cases; eight places said otherwise. The
  implementations were aligned to the claim rather than the claim weakened, and
  the two exceptions that remain on purpose are now named.
- 44 findings from a 13-agent adversarial audit closed.
- CI runs on both repositories: analyze, the full test suite, an Android build,
  and the Ircama ELM327 oracle behind a guard that fails the job if its tests
  were skipped rather than run. The private repository additionally runs the
  three-language reference suite and the second, freeze-frame oracle, whose
  simulator lives on a branch that cannot be published.

## 1.0.0+1 — 2026-08-17

Google Play internal testing only. Never published publicly, and superseded by
1.0.1 before it was.

First release. Real-time telemetry over an ELM327 adapter, on Android, iOS and
macOS:

- Four transports — Bluetooth Classic (RFCOMM/SPP), Bluetooth LE (GATT UART),
  Wi-Fi (TCP), and a built-in demo simulator that models a 2.0 L turbo four so
  every screen can be used without hardware.
- ELM327 handshake with the adapter's self-report treated as a claim rather
  than a fact, an error matrix over the adapter's refusals, and a watchdog.
- The J1979 PID library with a formula engine, priority scheduling, and
  `fastMode` batching that refuses a batched response it cannot attribute.
- Diagnostic trouble codes over Modes 03, 07 and 0A, clearing over Mode 04,
  and freeze-frame data over Mode 02 — gated on the cause code, because a
  controller with no stored frame answers every PID with zeros rather than
  refusing, and those zeros decode to a precise, entirely fictional record.
- Emissions readiness monitors, VIN over Mode 09.
- Derived figures — speed-density mass air flow, fuel consumption, wheel
  horsepower and torque — each hidden rather than guessed when an input is
  missing.
- Custom PIDs with a formula editor, import and export.
- A verbatim transcript of every exchange with the adapter, kept across an app
  kill and exportable as a file, which is the way to bring a failure home from
  a car park.
- Five gauge skins that differ in geometry rather than colour, and light and
  dark palettes that are separately designed rather than inversions.
