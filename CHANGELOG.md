# Changelog

Versions read `x.y.z+N`. The left half is what a person sees; `N` is the
Android `versionCode`, which Google Play requires to increase strictly and
which therefore does not always move in step with the name.

Dates are the date the build was made, not the date it reached anyone.

## Unreleased

No changes yet.

## 1.0.4+5 — 2026-08-24

This is the field-evidence build: a real-car failure should come home with
enough context to reproduce and explain it, without a laptop or a second app.

### Added

- **Every connection now carries a versioned evidence header.** The exported
  transcript records the app/build, phone and Android version, configured
  vehicle profile, transport endpoint or adapter identifier, BLE scan RSSI,
  MTU/subscription outcome, protocol, adapter identity and bus facts. Missing
  facts stay `unknown`; the app does not infer a successful result.
- **Four one-tap real-car event markers** — ignition on, engine started,
  throttle blip and road test started — place physical events on the same
  monotonic timeline as the raw OBD bytes and request an immediate snapshot,
  reporting if it remains memory-only. Demo sessions cannot create these
  markers. They live in Settings → Diagnostic records and are intended for a
  stopped vehicle or a passenger.
- Lifecycle and link events are recorded automatically: app background/resume,
  user disconnect and unexpected adapter loss.
- Added isolated Android BLE and Wi-Fi rig drivers. The explicit `rig` flavor
  uses `com.cbstudio.telltale.rig`, clears only its own state, and labels
  exported transcripts as simulated; the `field` flavor keeps physical
  adapter debugging under `com.cbstudio.telltale`.
- Added a deterministic TCP chaos proxy and CI oracle for fragmented replies,
  peer close, missing prompt, and corrupted critical initialization replies.
- Added a hash-locked macOS CoreBluetooth-to-Ircama rig with owner-only logs,
  exact process ownership, bounded lifetime, and fail-closed single-central
  notification routing.
- Added a conventional public documentation index, security policy, conduct
  policy, and a source-controlled privacy policy.

### Fixed

- Remembered-adapter direct connect now opens the dashboard after a successful
  handshake instead of leaving the connected session behind the connect page.
- Android rig evidence now fails closed when the native application-identity
  channel is unavailable or times out, so an unverified `.rig` session cannot
  create real-car markers or replace stored physical evidence.
- A transport that closes during the handshake or its post-handshake probes is
  reported immediately and cannot briefly commit an already-dead session.
- Interrupted, expired, or failed rig commands now remove only their owned
  bridge, emulator, and listener state, then release the OS advisory controller
  lock; no orphaned test service or stale held mutex is left running.
- Rig stop now rediscovers exact kernel identities when PID files are missing or
  partial, and evidence cleanup runs through `--purge-evidence` without
  unlinking live controller-lock inodes.
- Rig startup now retries the complete ownership/listener/advertising snapshot
  when LaunchServices exposes a still-settling process identity, instead of
  tearing down a healthy bridge after one transient check.
- The macOS BLE host now runs owner-private staged scripts outside protected
  source folders and keeps one stable bundle/venv identity across custom
  `TMPDIR` runs, avoiding LaunchServices file-access stalls and stale
  CoreBluetooth TCC grants.
- The physical BLE integration test now scrolls the discovered rig's actionable
  tile into a narrow phone viewport and taps only a hit-testable `InkWell`, so
  an off-screen text finder cannot report a successful tap without attempting
  GATT.

### Changed

- Long recordings preserve the first 200 handshake entries and the newest
  traffic instead of evicting the handshake first. Any omitted middle range is
  labelled with its count and elapsed-time range.
- Snapshot and share operations freeze one atomic transcript/header pair before
  awaiting storage, so later traffic or a new connection cannot relabel or
  extend the evidence being written.
- The evidence header warns that raw OBD traffic can contain VIN and device or
  adapter identifiers. The app never proactively uploads it; operating-system
  backup follows the device's settings, and sharing remains an explicit action.
- Public-facing guides, maintainer notes, and historical verification records
  now live under `docs/`; the repository root keeps only standard project files.
- The README now leads with APK download, supported transports, signing-lineage
  warnings, privacy, and the exact boundary between a physical BLE rig and a
  purchased adapter or vehicle.
- Field and rig guides now work from both the private `torque/app/` layout and
  the public `telltale` repository root, and the field guide identifies GitHub
  APKs as community-signed rather than Play-signed.
- Corrected the recorded `SM-S9280` model name to Galaxy S24 Ultra and pinned
  the Gradle 9.3.1 distribution checksum used by Android builds.

These are no-car test facilities. They do not upgrade simulated sessions into
real adapter, ECU, or vehicle evidence.

## 1.0.3+4 — 2026-08-20

Two defects found by driving 1.0.2 on a phone against real Bluetooth hardware
that misbehaves. Both were true statements a person standing at a car could do
nothing with — the same shape as the empty-scan panel fixed in 1.0.2, and found
the same way.

### Fixed

- **A raw Dart exception is no longer shown to the driver.** Connecting to a
  peripheral that accepts the link and then answers nothing produced
  `TimeoutException after 0:00:10.000000: Future not completed` on screen. The
  message now names the two causes worth checking — an adapter on a switched
  socket has no power until the ignition is on, and another app may be holding
  the link. The exception itself is kept in the transcript, which is where it
  is useful.
- **A recording under a kilobyte is no longer labelled `0 KB`.** A failed
  handshake is a few hundred bytes, so the recording with the most diagnostic
  value in it was the one displayed as empty — directly beneath a sentence
  promising it had been kept. Nobody exports a file the app has called empty.

## 1.0.2+3 — 2026-08-20

Both fixes are failures that only show up where nobody can watch them: a car,
with the app in one hand.

### Fixed

- **A BLE scan that finds nothing now says so, and says what to do.** The panel
  returned to exactly the state it was in before the tap: no message, no
  result, no next step. Bluetooth Classic has had an equivalent since it was
  written. This is the connect screen's worst moment to be silent — somebody is
  at a car with an adapter plugged in, and the three things that actually cause
  it (no power until the ignition is on, out of range, or a Classic adapter
  that can never appear in a BLE list) are all invisible from a blank panel.
  The guidance is ordered by how often each one is the answer.

- **A crash no longer takes the recording with it.** The snapshot that lets a
  session be read after the app dies was written only by the pause and
  teardown handlers, so it covered the app being backgrounded and then killed
  — and covered nothing at all when the process died in the foreground.
  Measured on a Pixel 9: home then `am force-stop` left the recording intact
  and offered on the next launch; `am crash` from the foreground left nothing.
  The second is the app crashing in a car, which is the session most worth
  sending back. A live session now writes every 30 seconds, and only when
  there are new bytes to write, so the most a crash can cost is one interval.

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
  permission the app asks for has changed. Rationale in `docs/protocol-deviations.zh-TW.md` §5.

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
