# Review round 4 — three independent reviewers, commit `27f58eb`

Reviewers, all given the same unrestricted brief (whole `app/`, nothing off limits):

| Reviewer | Model | Special access |
|---|---|---|
| Fable | `claude-fable-5` | Live Galaxy S25 Ultra — walked all seven screens, both themes, landscape, 1.8× text |
| Codex | `gpt-5.6-sol`, effort `max` | Read the installed plugin sources in `.pub-cache`, ran the Dart analyzer |
| GPT-5.6 Pro | ChatGPT web + @GitHub connector | Read the private repo directly |

The reviewers' own full reports are not published; what survived triage is below.

## Verdict

**Codex: BLOCK.** Not usable for real-vehicle driving, and its readings must not be
presented as trustworthy. Concur — see the convergence below.

The prior three rounds asked "is this code correct?" and got a defensible yes. The right
question was "what does this code do when the car does not behave like my simulator?",
and the answer is: it produces confident, plausible, wrong output.

Codex named the common root better than I had: **validity is implicit.**

- "no recognised ELM error string" is treated as a successful command
- "non-null reading" is treated as current, with no maximum age
- "empty list" is treated as a verified clean DTC result
- absent inputs to derived maths are replaced with `0` or `20 °C`
- multi-frame metadata is discarded before integrity is proved

## Cross-reviewer convergence — the highest-confidence findings

Findings two reviewers reached independently, from different angles. These are not
opinions.

### 1. Legacy multi-message DTC flattening fabricates fault codes
`Fable C-1` ≡ `Codex C-10`. **I verified this by hand.**

On non-CAN buses each Mode 03 message begins with its own `43` and carries up to three
codes, one message per line. `_parse` concatenates every hex line; `decodeResponse`
strips only the first `43`. Every subsequent `43` stays in the payload and shifts the
two-byte pairing.

```
43 01 43 01 96 02 34
43 01 33 00 00 00 00
```
→ `(01,43)(01,96)(02,34)` **`(43,01)(33,00)`** → P0143, P0196, P0234, **C0301, P3300**.
The last two do not exist on the car. Trigger needs 4+ codes, i.e. a second message.

`DemoTransport` only ever speaks CAN, so no test has ever executed this path.

### 2. Global OBD requests inherit whatever header ran last
`Fable H-2` ≡ `Codex C-02`. **Verified**: `polling_engine.dart:130,162,168` use bare
`client.send()`; only the batch path at `:286` uses `sendOnHeader()`.

Worse than the "wrong ECU" framing: `7E0` is a *physical* address, so Mode 03/04/09 ask
the ECM alone rather than all emissions-relevant ECUs. A TCM fault is invisible; a clear
can report success while codes remain.

### 3. No app-lifecycle policy for a live session
`Fable H-4` ≡ `Codex H-06`. **Mechanism verified in code** (`elm327_client.dart:636-637`):
the `_pending == null` guard added in round 2 covers only the idle case, and the poller
keeps a command outstanding almost continuously. Wall-clock elapsed while the process is
frozen is not evidence of adapter silence, but the watchdog treats it as such.

**I could not reproduce it on device** — Samsung's Freecess logged
`skipping freeze com.prowl.torque_obd` throughout both a 50 s and a 200 s background
window, so the precondition never occurred. An adb-connected app appears to be exempt
from freezing. Unreproduced, not refuted.

### 4. macOS cannot reach any real hardware
`Fable H-3` ≡ `Codex H-07`. **Verified**: `Release.entitlements` contains only
`app-sandbox`; Debug has `network.server` (inbound) rather than `network.client`; the
macOS `Info.plist` contains no Bluetooth usage string at all. Wi-Fi is refused by the
sandbox and BLE is terminated by TCC. Only Demo works.

### 5. The simulator is still the root cause of false confidence
`Fable`'s framing ≡ `Codex M-01`. Round 1 established this and I only half-fixed it: I
made `DemoTransport` emit realistic *CAN* framing. It still cannot produce a legacy bus,
a broken clone, a lost notification, or a refusal — so it still certifies as passing
exactly the code that has never been exercised.

## Codex-only CRITICALs that matter most

- **C-01 `ATSH 7E0` is sent unconditionally after protocol detection.** A three-hex-digit
  `ATSH` is an 11-bit CAN header. J1850/ISO 9141/KWP need protocol-specific three-byte
  headers; 29-bit CAN needs four bytes. Every vehicle on protocols 1–5, 7, 9 can pair and
  then be completely unusable. This is precisely the failure the owner named.
- **C-05 the handshake accepts `OK`, arbitrary text, or a bare `>` as proof of a vehicle.**
  `isSuccess` means only "no classified adapter error". The `0100` probe I added in round 2
  is never checked for a well-formed `41 00` plus four support bytes.
- **C-07 a malformed or timed-out single-PID poll leaves the previous reading looking live
  indefinitely.** Invalidation is gated on `batch.length > 1`; staleness in the UI means
  `reading == null`, with no maximum age. A driver keeps seeing a believable, obsolete
  coolant temperature.
- **C-15 the custom-PID editor can repeatedly transmit ECU write/control services.** Any
  hex string can be scheduled: `2F` InputOutputControlByIdentifier, `2E` WriteDataByIdentifier,
  `31` RoutineControl. A telemetry reader that can actuate an ECU is a vehicle-safety
  boundary, not an input-validation nit.
- **C-06 resync clears `_outOfSync` in `finally` whether or not a prompt was seen** — so a
  late reply can be handed to the *next* command. Fable independently found the milder
  cost of the same code (a wasted 3 s wait); Codex found the correctness hole.

## GPT-5.6 Pro — the third reviewer

Arrived after ~90 minutes of generation. Verified before use: the ownership
token was present, and all 15 `lib/**.dart` paths it cites exist in the repo, so
the @GitHub connector genuinely read the private source rather than writing a
plausible report from the prompt alone.

It converged independently on the addressing model (its C1/C2 ≡ Codex C-01/C-02),
which makes that **three reviewers on three different paths reaching the same
conclusion** — the strongest signal in this whole round.

It also found a sub-defect the other two missed, now **verified and fixed**:

> `_captureIdentity()` sets `_currentHeader = '7E0'` even when `ATSH 7E0`
> returned `?`, because state capture runs before response validation.

Confirmed — the `case 'ATSH 7E0':` branch recorded the header with no reference
to the response at all. Following the thread found something worse underneath:
`_currentHeader` was *initialised* to `'7E0'`, a claim the app had no evidence
for before sending anything. Since `sendOnHeader` skips the switch when it
believes the header already matches, the very first addressed query could go out
on whatever header the adapter actually held. It is now `String?`, unknown until
the adapter answers `OK`.

GPT-only findings still open, added to the phase tasks:

- **C11** BARO-dependent formulas always assume sea-level pressure.
- **C12** missing MAP or IAT becomes a confident `0.0` fuel/air reading (≡ Codex C-17).
- **H2** an old BLE teardown can disconnect a newly established session.
- **H3** `VAL{}` dependencies are neither scheduled, scoped, nor expired.
- **H5** BLE scanning is broken when location is denied on Android 6–11.
- **H7** the Android release variant is signed with the debug key.
- **H8** acceleration survives a telemetry gap and produces false horsepower on recovery.
- **H9** the simulator's 80 PIDs/s cannot represent a genuine ELM327's prompt
  timing. **This one invalidates a number I have been quoting**: the throughput
  figure from the device walkthrough measures my simulator's latency model, not
  an adapter.
- **M1** BLE discovery excludes unnamed adapters; UART selection can bind
  unrelated characteristics.
- **M3** the stale-gauge fade drops contrast so far that the failure state is
  hard to read — the opposite of its purpose.
- **M6** the PIDs/s indicator does not decay when the bus stops answering.

## Rendering performance — measured, not guessed

Codex raised this as **M-09, explicitly marked `[GUESS — profiling required]`**. I profiled
it, so it is no longer a guess.

`dumpsys gfxinfo` reports `Total frames rendered: 0` for Flutter — it measures the Android
HWUI pipeline and Flutter renders through its own engine to a separate surface.
`SurfaceFlinger --latency` has been gutted on modern Android. GPU/CPU counters worked.

| Screen | GPU busy | App CPU |
|---|---|---|
| Dashboard, 6 live gauges | **64.9 %** | **116 %** |
| Settings, no gauges | **0 %** (GPU idle) | **6.6 %** |

Polling continues on the settings screen, so ~110 % CPU and the entire GPU load is gauge
rendering alone. Causes, all verified in source:

1. **The two-layer split is only half done.** `dial_gauge.dart:105` wraps the *static*
   chrome in a `RepaintBoundary`; the *dynamic* painter at `:121` has none, and
   `dashboard_screen.dart` uses `Column`/`Row`/`Wrap` rather than `GridView.builder`, which
   is what would have added per-child boundaries automatically. All six dynamic layers,
   six readouts, twelve endpoint labels and the panel chrome share one layer, so any one
   gauge's change re-rasterises all of it.
2. **Repaints run at display rate, not data rate.** `TweenAnimationBuilder` (`:117`) runs a
   180 ms animation per value change; at ~72 samples/s across six gauges the animations
   overlap continuously, so the shared layer repaints at 120 Hz permanently.
3. **12 `MaskFilter.blur` passes per frame** (`:471` arc glow, `:523` needle glow, × 6).
   Each forces an offscreen render target plus convolution — the most expensive thing a
   tile-based mobile GPU does.
4. **`ui.Gradient.sweep` is rebuilt inside `paint()`** (`:452`) — a native shader allocated
   720×/s.

Per second at 120 Hz: 720 widget rebuilds, 720 painter allocations, 720 shader
allocations, 1 440 blur passes.

Fixes: drive the painter from the animation via `CustomPainter(repaint: animation)` with
`shouldRepaint => false` (the idiom in Flutter's own docs) instead of rebuilding the widget
each tick; wrap the dynamic painter in its own `RepaintBoundary`; cache the shader; and
replace both `MaskFilter.blur` calls with two or three progressively wider translucent
strokes, which reads the same and needs no offscreen pass.

(The glow cannot be moved to the static layer: the arc glow follows the value sweep and the
needle glow follows the needle. Both are inherently dynamic.)

## What was checked and is genuinely correct

Both reviewers confirmed independently: all 23 built-in Mode 01 formulas against J1979;
the support-bitmask bit31→PID+1 mapping; the `ATCRA`/`ATCFC0` omissions; the hex whitelist;
`0100` ordered before `ATDP`/`ATDPN`; resync not sending a bare `\r`; teardown detaching
handles before the first await. The visual design is above hobby grade — Fable called the
dark theme flagship-quality and the connect wizard's live per-command handshake the app's
smartest UX decision.

The problem is not the parts that were examined three times. It is the parts the simulator
made unexaminable.

## Could not be tested here

- No real ELM327 adapter and no vehicle. Every protocol finding above is derived from the
  datasheet and J1979, not observed.
- App freezing (Samsung declined to freeze an adb-connected app).
- Codex could not run `flutter test` in its sandbox (`127.0.0.1:0` bind refused); it did not
  claim a fresh 141-pass run. The analyzer run was clean.


---

## Validation against an oracle this project did not write

Every other test in this suite is ultimately my code checking my own
assumptions — which is the exact failure mode that produced four rounds of
findings. `Ircama/ELM327-emulator` is an independent implementation: its
framing, timing and quirks come from someone else's reading of the datasheet,
so it can disagree with mine, and it did.

Run it with:

```bash
"$SP/harness/elmvenv/bin/python" -m elm -n 35000 -s car -b batch.log &
```

`test/emulator_integration_test.dart` then drives the real `WifiTransport`
against `127.0.0.1:35000`, and skips itself when the emulator is not running.

### What it caught

**A defect I introduced in this very round.** The headered-CAN line pattern
matched by shape, and `ATS0` — which this app's own handshake enables — strips
the spaces from replies. `4100BE3FA813` then splits perfectly well into a
29-bit ID `4100BE3F` and a two-byte payload, so an ordinary Mode 01 support
mask was read as a malformed ISO-TP frame and the handshake failed on `0100`.
No test of mine could have found it: my fake emits spaces.

The fix is to gate the headered parser on the client's own `ATH` state rather
than on the shape of the line. The adapter's header mode is not a guess — this
client is the one that sets it.

**A second one underneath it.** With headers on, an AT command's
acknowledgement still carries no header, so `OK` was routed through the
headered parser, found no addressed lines, and was rejected — which made
`sendGlobal` report that the adapter had refused the very header switch it had
just acknowledged.

### What it could not validate, and why

- **Functional addressing.** With `7DF` selected the emulator answers Mode 03
  with `NO DATA`, though it answers the same request on the engine's physical
  address. `7DF` is the functional address the datasheet names for 11-bit CAN,
  so this is a limitation of the oracle rather than of the app — and it makes a
  good fixture for the property that matters most: an unanswered scan is
  reported as a failure, never as a clean bill of health.
- **Legacy and 29-bit buses.** The emulator only speaks 11-bit CAN, and its
  failure mode is the worst kind: `ATSP3` answers `OK` while `ATDPN` keeps
  reporting `A6`. It does not refuse, it quietly misleads. Those paths are
  still covered only by fixtures I wrote from the datasheet.
- **Mode 03 consistency.** It answers `41 00` in one state and `43 00` in
  another, and its author documents that it deliberately returns wrong service
  bytes. That is useful as an adversarial input — the app must refuse a reply
  whose service byte does not match the request — but not as a source of truth.

### On the device

The phone connected to the emulator over Wi-Fi and read live telemetry:
protocol correctly detected as `ISO 15765-4 (CAN 11/500)`, `13.2 V` from the
emulator's own `ATRV`, all six gauges live, provenance shown as
"MAF 感測器 · 化學計量比推算", zero errors in logcat. It also fell back from
fastMode to single-PID reads on its own, having found that this adapter does
not handle batched requests — adaptive behaviour, against an implementation
nobody wrote to accommodate it.


---

## C-03 revisited: is there a better Bluetooth Classic package?

The finding: `flutter_classic_bluetooth` 0.1.8 calls only
`createRfcommSocketToServiceRecord` and its insecure twin, both of which need
the device to publish a usable SPP SDP record. Clones that simply listen on
RFCOMM channel 1 without one pair normally and cannot be connected to.

Surveyed pub.dev in August 2026. What exists:

| Package | Latest | Likes / downloads | Platforms | Explicit channel or reflection fallback |
|---|---|---|---|---|
| `flutter_classic_bluetooth` *(current)* | 0.1.8, 15 days ago | 45 / 1.39k | Android, Windows, macOS, Linux, iOS (MFi) | **No** — verified by reading its Android source |
| `flutter_blue_classic` | 0.1.1, 49 days ago | 37 / 2.73k | Android only | Not documented |
| `flutter_bluetooth_classic_serial` | 1.3.2, 10 months ago | 6 / 523 | Android, iOS, desktop | Not documented |
| `flutter_spp_bluetooth_serial` | 0.1.5, 2 months ago | 2 / 106 | Android only | Not documented |
| `bluetooth_rfcomm_flutter` | 0.2.0, 14 days ago | 0 / 314 | Android, iOS (MFi) | **Yes** — `channel:` parameter |
| `flutter_bluetooth_serial` | 0.4.0, 4 years ago | — | Android only | **Yes** — reflection, but abandoned |

Two packages have the capability and neither is usable:

- `flutter_bluetooth_serial` has the classic reflection fallback and has been
  unmaintained for four years, Android only.
- `bluetooth_rfcomm_flutter` has the better API — an explicit `channel:`,
  documented as "needed when a device doesn't advertise SDP", which is exactly
  the right shape — but its own README says: *"Neither the Android nor the iOS
  backend has been manually verified on a device yet — treat both as
  best-effort for now."* Zero stars, zero likes, 314 downloads.

**Resolved by forking rather than swapping.** Moving to a package whose author
states the Android backend is unverified would trade a known limitation for an
unknown one, in an app whose entire history of defects is confident-wrong
behaviour. Moving to an abandoned one is worse.

`flutter_classic_bluetooth` is the right base — most maintained, broadest
platform coverage — and the missing piece is roughly forty lines. So:
https://github.com/ImL1s/flutter_classic_bluetooth adds `connect(channel:)`,
which opens the socket through Android's hidden `createRfcommSocket(int)` and
skips service discovery entirely. `uuid` is ignored on that path, out-of-range
channels are refused before any I/O, and a build that does not expose the
method says so rather than failing generically. The argument is omitted from
the platform call when unset, so existing behaviour is unchanged. Four tests
cover it; the plugin's own suite goes from 128 to 132.

`app/pubspec.yaml` pins the dependency to a commit rather than a branch, so it
cannot move underneath a build.

The transport now walks three tiers — secure by UUID, insecure by UUID,
insecure on channel 1 — each starting only after the previous has genuinely
terminated, because a Dart-side timeout leaves the native socket blocked in
`BluetoothSocket.connect()` and racing them would let a late success register
a link Dart no longer owns.

Whether to offer this upstream is a separate decision; the fork stands on its
own either way.
