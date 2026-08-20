# What was verified on hardware, and what that is worth

Galaxy S25 Ultra, Android 16, 1080×2340. Every run below was
driven through the real UI — taps and text on the device, not a test harness —
against a build installed with `adb install`.

**There is still no ELM327 adapter and no vehicle.** The strongest link tested
is a real ELM327 protocol implementation over a real TCP socket. What that
does and does not establish is the point of this file; `TEST_EVIDENCE.md`
covers the unit suite.

Round 9 added a proxy in that socket that logs every byte and can hold a reply
back, which is how the timing findings were tested and how one of them was
found to have been testing nothing at all.

## The two links exercised

| | What it is |
|---|---|
| Demo simulator | The in-app `DemoTransport`. Every screen, no hardware. |
| **Wi-Fi → `Ircama/ELM327-emulator`** | The phone's real `WifiTransport` opening a real TCP socket to an ELM327 implementation nobody here wrote, reached over `adb reverse tcp:35000 tcp:35000`. Protocol handshake, framing, timing and error paths are all its, not ours. |

Bluetooth Classic and BLE were exercised as far as an absent adapter allows,
which turned out to be further than expected — see below.

## Verified over the Wi-Fi link

This is the part that resembles a car.

- **Handshake and protocol detection.** `127.0.0.1:35000`, reported as
  `AUTO, ISO 15765-4 (CAN 11/500)` — read from the adapter, not assumed.
- **Live telemetry**: 9–10 PIDs/s, all six gauges reading, `13.7 V` from a real
  `ATRV`.
- **Fast mode correctly *off*.** The status strip showed 單筆模式. The app
  established that batching was not available and fell back rather than
  producing mis-split frames — the failure round 6 was spent preventing.
- **VIN read**: `MAT403096BNL00000`.
- **The headline case.** The emulator does not answer Mode 03/07/0A. The screen
  said:

  > **無法確認** — 車輛沒有回應 Mode 03 查詢，因此無法確認是否有已儲存的故障碼。
  > **這與「沒有故障碼」不是同一件事。**

  and for the optional classes, that it could not tell "the vehicle does not
  support this" from "this connection did not read it". A green
  未偵測到故障碼 here would have been the defect this entire review loop is
  about, produced against a real protocol implementation rather than a fixture.
- **The clear button was absent**, because no result had been established. You
  cannot clear what could not be read.

## Round 9, with the wire visible

Round 9 changed the connection itself — one new command, a lease on every
write, a deadline on every write — so this round was run with a logging TCP
proxy between the phone and the emulator, and with the proxy able to *hold*
a reply back. That turns it from a fixture into a controllable slow ECU, which
is what the lifecycle findings needed and what no unit test can supply.

### `AT PPS`, against an implementation nobody here wrote

Two decisions had no source but a guess: whether protocol `B`/`C` is even a
framed bus (PP 2C / 2E), and whether the adapter handles Response Pending
(PP 2A bit 2). Adding a command to a connection is the riskiest change this
app can make, so the wire log is the evidence:

```
>> b'ATDPN\r'
<< b'A6\r\r>'
>> b'ATPPS\r'
<< b'00:FF F 01:FF F 02:FF F 03:32 F\r … \r2C:E0 F 2D:04 F 2E:80 F 2F:0A F\r\r>'
>> b'ATRV\r'
```

- **It is after the handshake, not inside it.** `ATPPS` appears between
  `ATDPN` and the first poll, exactly as designed — a refusal there cannot
  fail a connection.
- **The format matches the datasheet**, so the parser written from it reads a
  third party's output without adjustment.
- **`2A:38 F` is the trap, present in the wild.** The stored value has bit 2
  *cleared*; the state letter says the parameter is **off**, so what governs is
  the factory default `3C` — bit 2 **set**. A parser that reads the value and
  ignores the letter concludes the opposite of the truth on this very adapter.
  That reading comes from the datasheet's worked example (p.67: "it is enabled
  (oN), while the others are all off") and was flagged as the blocking risk
  before the parser was written.
- `2C:E0` / `2E:80` match the documented defaults, so B and C resolve to *no
  data formatting* — which is why mapping them to ISO 15765-4 was wrong.

### An interrupted scan, with a controller that was genuinely still working

The first attempt at this proved nothing and looked like it had. The emulator
answers `03`/`07`/`0A` immediately, so the whole scan finished in **0.03 s** —
before the app could be backgrounded at all. The timestamps said so; the
screen did not.

With the proxy holding Mode 03 for four seconds, both halves are real:

| | outcome |
|---|---|
| **Control** — 4 s hold, no interruption | Scan completes, correct qualified verdict, connection survives |
| **Interrupted** — same hold, Home at +1.5 s, back at +3 s | 讀取失敗 — 掃描在中途被中斷…請重新掃描 |

and the wire agrees: after the held `03` there is no `07`, no `0A`, no `0902`.
The scan stopped, the previous verdict was discarded rather than left standing,
and the screen says why. The difference between the two rows is the
interruption, not the slowness — which is the pair round 9's H-03 needed.

A nine-second hold instead tears the link down with 轉接器停止回應, which is
correct: past the seven-second global window with no `7F xx 78`, silence is a
dead adapter, and the datasheet says a conforming one would have answered
`NO DATA` long before.

### The headline case, still intact

`無法確認 — 車輛沒有回應 Mode 03 查詢…這與「沒有故障碼」不是同一件事。`
VIN read on the same scan. The clear button absent, because nothing was
established. All of round 9's lease and deadline threading passes through this
path and none of it broke the verdict.

### The clear, which is the only command that changes the vehicle

`clearDtcs` was reworked twice today — C-04 gave it a per-write lease, C-03
gave it a fallback to the controllers the preceding scan heard, plus a new
refusal when coverage is unknown. It is also the one path the Wi-Fi walk
structurally cannot reach: the emulator answers nothing, so no result is
established, so the button correctly never appears. It was pressed on the demo
link instead, which is the only link that can.

- Scan: three codes, each attributed to controller `7E8`, plus a VIN.
- 清除 offered, and its dialog says what it costs — readiness monitors reset,
  a full drive cycle needed before the vehicle can pass inspection, permanent
  Mode 0A codes not clearable.
- Confirmed, and the auto-rescan came back green:

  > **已回應的控制器都沒有故障碼。**
  > 這代表每個回覆的控制器都回報無故障碼，不代表車上每個模組都已被問到。

That green is the point. C-03 added a refusal for the case where coverage
cannot be established, and this is the case where it *can* — one controller,
censused, acknowledged. Had the new rule been a shade too strict it would have
refused a clear the vehicle plainly performed, which is the over-strictness
round 6 was spent undoing. It did not.

### Re-walked after round 10

Round 10 changed the connection again — the response-pending, protocol-search
and write timers clamped to the caller's budget, the connect-time census
bounded, `B`/`C` resolved from an
observed identifier width when `AT PPS` is unavailable, the `ATH0` restore
given a real exemption, and the clear given the bus refusal its siblings had.
The walk above was repeated on that build:

- Wi-Fi handshake unchanged in shape — `ATPPS` still sits between `ATDPN` and
  the first poll — with six gauges live at 8 PIDs/s and `13.7 V`.

An earlier draft of this section claimed *every* rearm was clamped. It was not:
the one that runs on resume was missed, which round 11 found and fixed. The
sentence has been narrowed to what the walked build actually did.
- The headline fault-code case still reads 這與「沒有故障碼」不是同一件事.
- Demo link: scan, 清除, auto-rescan, back to
  已回應的控制器都沒有故障碼, and `logcat` clean of Flutter errors.

### Two features that had been opened but never used

Both were reachable only on the demo link, and both had been walked as far as
their first screen and no further — which is not the same as having been used.

- **The acceleration timer completed a run.** Every previous walk armed it and
  watched it correctly refuse while the car was moving; none had let it finish.
  Target 50 km/h, waited for the simulated car to come to a stop, armed, and
  it recorded **完成 0 → 50 km/h — 3.4 秒** with a speed trace showing the
  climb against the target line.
- **Delete, from the PID editor.** The trash icon had never been pressed on a
  device. A custom PID was created, enabled, opened and deleted: the counts
  went 已啟用 8 → 7 and 共 27 → 26, the manager came back with 沒有符合的 PID,
  and the dashboard did *not* repopulate with the shipped layout — which is
  round 10's R10-08 behaving correctly on hardware rather than only in a test.

The dashboard on this link also runs **fastMode** at 88 PIDs/s, which the
Wi-Fi link cannot show: the emulator does not support batching, and the app
correctly falls back to 單筆模式 there. Both branches of that decision have now
been seen on a device.

`logcat` clean of Flutter errors throughout.

### Re-walked after round 11

Round 11 replaced the user-CAN mechanism entirely — a slot whose framing was
demonstrated now installs *nothing*, rather than having its identifier width
guessed from a reply — and changed the pending filter, two timer paths and the
editor's save. Both links were walked again on that build:

- Wi-Fi: handshake, telemetry, and the fault-code screen still reading
  無法確認 … 這與「沒有故障碼」不是同一件事 with the VIN alongside it.
- Demo: scan → 清除 → auto-rescan → 已回應的控制器都沒有故障碼.
- `logcat` clean of Flutter errors on both.

### Re-walked after round 12

Round 12 removed the user-CAN promotion outright and narrowed fault-code
coverage back to fault-code evidence, so the connection behaves differently
again. Both links walked on that build: Wi-Fi handshake, telemetry and the
qualified 無法確認 verdict; demo scan → 清除 → auto-rescan →
已回應的控制器都沒有故障碼. `logcat` clean of Flutter errors on both.

### Re-walked after round 13

Round 13 made `supportsObd2` the single bus gate for every consumer — including
the poll loop, which had refused only J1939 — so the risk was refusing a bus
that works. Both links walked: Wi-Fi at 9 PIDs/s with six gauges live and the
qualified 無法確認 verdict, demo scan → 清除 → auto-rescan →
已回應的控制器都沒有故障碼. `logcat` clean on both.

### Re-walked after round 14

The identity extractor now reads every line and picks its pattern from the
bus's header width, which is a change to how *every* headered reply is read —
so both links were walked again. Wi-Fi: handshake, telemetry, VIN
`MAT403096BNL00000` and the qualified 無法確認 verdict. Demo: scan → 清除 →
auto-rescan → 已回應的控制器都沒有故障碼. `logcat` clean of Flutter errors on
both.

### Re-walked after round 15

Round 15 changed how every legacy reply is read — the trailing checksum is no
longer payload — and tightened where identity may come from. Both links walked
on that build: Wi-Fi handshake, telemetry and the qualified 無法確認 verdict;
demo scan → 清除 → auto-rescan → 已回應的控制器都沒有故障碼. `logcat` clean of
Flutter errors on both.

The legacy change is the one this walkthrough *cannot* cover: there is still no
legacy vehicle and no adapter, so J1850 / ISO 9141 / KWP remain fixtures. What
changed is that those fixtures now carry the checksum the datasheet says
`ATH1` prints, which they did not before — so the code and the fixtures agree
with the document rather than with each other.

### Re-walked after round 16

Round 16 added checksum *validation* to every legacy reply and tightened the
CAN parser to the resolved width — both changes to how replies are accepted at
all, so a mistake here refuses working traffic rather than misreading it. Both
links walked: Wi-Fi handshake, telemetry and the qualified 無法確認 verdict;
demo scan → 清除 → auto-rescan → 已回應的控制器都沒有故障碼. `logcat` clean of
Flutter errors on both.

### Re-walked after round 17, and a gauge going dark on purpose

Round 17 tightened what the census will accept as a responder and loosened
which receive width a user slot may answer on — one refuses more, one refuses
less — so both links were walked again. Wi-Fi handshake, telemetry and the
qualified 無法確認 verdict; demo scan → 清除 → auto-rescan →
已回應的控制器都沒有故障碼. `logcat` clean on both.

One screenshot showed the LOAD gauge reading `--` with 匯流排錯誤 while the
other five read normally, which looked like a regression and was not. The wire
log settles it: the emulator answered `NO DATA` to `0104` four times across the
session, and the gauge recovered to 41.2% once the replies came back.

That is the designed behaviour seen on a real link, and it is worth recording
as such: a PID that stops answering goes dark and says why, rather than
holding the last plausible number it had. The failure this app is built around
is a wrong reading nobody can identify as wrong; a blank tile with a reason on
it is the opposite of that.

### Re-walked after round 18

Round 18 changed what counts as a controller — identifiers are range-checked at
their width, and a fault-code read may no longer establish its own coverage
from a source it discovered while being judged. Both are refusals, so the risk
is turning away a vehicle that works. Both links walked: Wi-Fi handshake,
telemetry, VIN and the qualified 無法確認 verdict; demo scan → 清除 →
auto-rescan → 已回應的控制器都沒有故障碼. `logcat` clean on both.

### Re-walked after round 19

Round 19 changed what the fault-code screen is allowed to *say* — `NO DATA` no
longer claims a category is unsupported or that no fault exists — as well as
which controllers count as having answered. Both links walked: Wi-Fi handshake,
telemetry, VIN `MAT403096BNL00000`, and all three categories reading 無法確認
with the honest "Mode 03 was silent too, so this cannot be told apart" wording.
Demo scan → 清除 → auto-rescan → 已回應的控制器都沒有故障碼. `logcat` clean on
both.

### Re-walked after round 20

Round 20 changed how a reply the adapter marked as damaged is treated: it is
still not data, and the controllers identifiable in it are no longer forgotten.
Both links walked: Wi-Fi handshake, telemetry, VIN and the three qualified
categories; demo scan → 清除 → auto-rescan → 已回應的控制器都沒有故障碼.
`logcat` clean on both.

### Re-walked after round 21

Round 21 added a refusal the clear did not have before — an exchange that
discarded an unresolvable address token marks coverage uncertain, and a clear
will not claim success against it. A refusal is the thing most likely to turn
away a working vehicle, so the clear was the point of this walk. Both links:
Wi-Fi handshake, telemetry and the three qualified categories; demo scan →
清除 → auto-rescan → 已回應的控制器都沒有故障碼. `logcat` clean on both.

### A defect the suite could not have found

Editing a custom PID's mode from `012F` to `0105` and tapping 儲存 did
nothing — no error, no message, the editor simply stayed open and the edit was
gone. `CircularDependencyError` in logcat, out of `PidRegistry.removeCustom`,
which `_save` reaches **only when the edit changes `Pid.id`**. Renaming saves
fine; correcting a mistyped mode does not.

Both editor regression tests written this round — one for Codex's L-02, one
for M-02 — change a name or a header that normalises back to what was stored.
Neither changes the identity. Two tests for two reviewers' findings, both
covering the half that could not break.

Fixed, and the reproduction now runs in the suite. On the device afterwards:
the save closes the editor, logcat is clean, and the definition polls.

### Also walked, on this build

- Custom PID created with the **header field deliberately cleared** — reopening
  the editor shows `7E0`, not blank, and once pointed at a supported PID it
  reads `62.0` live. That is round 9's M-02 end to end: blank → app default →
  transmitted → a real number. Stored as `''` it would have been silently
  marked unsupported, indistinguishable on screen from a car without the
  sensor.
- Six gauges live at 9–10 PIDs/s, `13.4 V` from a real `ATRV`, fast mode
  correctly off.
- 27 definitions in the PID manager, live values per row, search, filter.
  `Fuel Tank Level 012F` and `Fuel Pressure 010A` marked 不支援 while the
  supported ones read — the app declining to invent numbers for PIDs this
  vehicle does not have.
- Performance timer refusing to arm: 「請先完全停車 — 目前 14 km/h」.
- Light theme on a live link, then **1.6× text on top of it**: the dashboard
  reflows to one column, the status chips wrap to three rows, and the fault
  screen's long explanations wrap intact — including the sentence this whole
  review round is about.

## Round 23, after the typed-evidence rewrite

Galaxy S25 Ultra, debug build of `685d34a`, the ELM327 emulator over Wi-Fi on
one pass and the demo link on the other. The commit rewrote how a damaged
exchange decides who was on the bus, so both links were walked end to end
rather than spot-checked.

**Over the emulator.** Connected on `127.0.0.1:35000`, protocol negotiated to
`AUTO, ISO 15765-4 (CAN 11/500)`, six gauges live at 8 PIDs/s on `13.0 V`.
The VIN read whole — `MAT403096BNL00000`, a multi-frame Mode 09 reassembled
correctly.

Then the part worth having. This emulator answers `03` with `7E8 02 41 00` —
a **Mode 01 reply to a Mode 03 request**, which is exactly the stale-reply
case the last four rounds of review have been about. The scan reported:

> 無法確認 — 車輛沒有回應 Mode 03 查詢，因此無法確認是否有已儲存的故障碼。
> 這與「沒有故障碼」不是同一件事。

and the same for 07 and 0A, with no clear button offered. No false all-clear,
no controller invented from the reply, and the distinction between "silent"
and "clean" held on a real ELM327 protocol implementation over a real socket
rather than in a fixture.

**Over the demo link.** 75 PIDs/s with fastMode. Three stored codes — P0301,
P0420, U0123 — each attributed to controller `7E8`, VIN `1D4GP00R55B123456`.
清除 → 確定清除 → the automatic rescan came back
「已回應的控制器都沒有故障碼。」with its own caveat that this is not a
statement about every module on the car.

**Custom PID, created edited and deleted on the device.** `010B`, formula `A`,
unit kPa: saved (26 → 27 definitions), enabled, and immediately polling at
`108 kPa`. Edited to `A/2` from the same screen — the route carried the right
definition, the registry updated with no `CircularDependencyError`, and the
live value halved to `40.5 kPa`. Deleted, back to 26, no crash.

**Acceleration timer**, armed at rest and completed: `0 → 50 km/h 3.4 秒`,
with the speed trace drawn.

**Dark theme** on a live link, then **1.6× device font scale** on top of it:
the dashboard reflows to one gauge per row, the status chips wrap to two rows,
and the fault screen's explanations wrap intact.

`logcat` carried no `E/flutter` and no `FATAL EXCEPTION` across the whole
session.

## Round 23 final, after four reviewers

Same device, debug build of the last round-23 commit. Repeated because the
round changed the reply parser, the demo transport's rendering and the app's
lifecycle handling, so nothing from the earlier walk carried over.

The most useful thing about this pass is what the demo link now *is*. Round 23
made `DemoTransport` honour `ATS0` — it had acknowledged the command and gone
on printing spaces, the same answered-OK-did-nothing pattern this project
refuses from clones. So every reply on the demo link now arrives unspaced,
which is the rendering where a CAN header and its first payload byte run
together and the parser has to tell two readings of the same characters apart.
That path had never been exercised outside fixtures, and the whole of this
round's `_canLine` ranking work exists for it.

**Over the emulator**, unchanged and still correct: `AUTO, ISO 15765-4 (CAN
11/500)`, six gauges at 10 PIDs/s on `13.6 V`, VIN `MAT403096BNL00000`, and
all three fault-code categories reporting 無法確認 against an emulator that
answers Mode 03 with a Mode 01 reply. No clear offered.

**Over the demo link**, at 81 PIDs/s with fastMode and every byte unspaced:
P0301, P0420 and U0123 decoded and attributed to `7E8`, VIN
`1D4GP00R55B123456`. 清除 → the confirmation dialog carried the base warning
and *not* the new incomplete-coverage sentence, which is right — this scan
answered all three categories. The automatic rescan came back
「已回應的控制器沒有故障碼」 in the header, the qualified wording that replaced an
unqualified 未偵測到故障碼 this round.

Also live on the device: Mode 01 PID 01 is now read on every scan and agreed
with Mode 03 both before the clear (lamp on, three codes) and after it (lamp
off, none) — the simulator answering that PID from the same fault list it
serves, so the cross-check has something honest to check against.

Acceleration timer completed `0 → 50 km/h 4.1 秒` with its trace. PID manager
live at 26 definitions. `logcat` carried no `E/flutter` and no
`FATAL EXCEPTION` across the session, and three consecutive full-suite runs at
this commit were 498/498 — one reviewer had reported order-dependent flakiness
and none was reproducible here.

## The release build, at round 23's final commit

Every walk above this line used a debug build, which keeps everything R8 might
remove — so "debug works" is not evidence that the artefact a user would
install works. This one is the signed release APK of `4b8307e`: R8 shrinking
on, icon fonts tree-shaken from 1.9 MB to 7.7 KB, 57.2 MB packaged, signed
with the release key (`CN=Torque OBD2, OU=Development, O=ImL1s, L=Taipei,
C=TW` — the keystore is not in version control and `android/.gitignore`
excludes `key.properties` and `*.jks`; only `key.properties.example` is
tracked).

Installed over a full uninstall, so it also exercised first-run state rather
than inheriting the debug build's preferences.

- **The failure path first, unintentionally and usefully.** A fresh install
  defaults the Wi-Fi host to `192.168.0.10`, so the first attempt failed and
  rendered 「無法連線到 192.168.0.10:35000。請確認手機已連上轉接器的 Wi-Fi
  熱點。」 with the form reopened underneath it. The error path survives R8.
- **Wi-Fi to the ELM327 emulator**: connected, `AUTO, ISO 15765-4 (CAN
  11/500)`, gauges live at 9 PIDs/s on `13.6 V`, VIN read whole. All three
  fault-code categories 無法確認, as they must be against an emulator that
  answers Mode 03 with a Mode 01 reply.
- **A PID faulting mid-session**, which is worth recording: LOAD dropped to
  `--` with 匯流排錯誤 beside it rather than holding its last plausible
  number. That is the rule about frozen gauges, seen happening.
- **Demo**: 81 PIDs/s with fastMode, three codes attributed to `7E8`, 清除 →
  auto-rescan → 「已回應的控制器沒有故障碼」.
- `logcat` carried no `E/flutter`, no `FATAL EXCEPTION`, and — the ones that
  matter for a shrunk build — no `ClassNotFoundException`, `NoSuchMethodError`
  or `MissingPluginException`.

## Verified over Bluetooth, without an adapter

More than anticipated, because the *failure* path exercises nearly everything
the success path would.

- **Classic device enumeration** lists the phone's actual paired devices with
  their addresses — six of them, none an ELM327. The screen says so plainly:
  headsets and speakers appear too, the adapter-looking ones are sorted first,
  and picking wrong costs about half a minute.
- **The full three-tier cascade, run against a device that is not an adapter.**
  Secure SDP, then insecure SDP, then explicit channel 1. It took about 45
  seconds — three tiers at their timeout — and ended with a specific message
  naming the device, with the app in a usable state and the list intact.

  That timing is the evidence. The cascade only advances because
  `connect(timeout:)` calls `cancelConnect`, which closes the socket and
  releases the native thread blocked inside `BluetoothSocket.connect()`. Had
  today's fork changes broken that, tier two would have raced tier one for an
  adapter that accepts a single link, and this would have hung rather than
  failing in three bounded steps. The one part of the fork work that seemed
  impossible to check without hardware is checked by its absence.
- **BLE scanning** runs and returns real nearby devices. Permissions granted,
  scan started, results rendered.

Neither transport has ever completed a session, because that needs an adapter.

## Verified through the UI on the demo link

- **Connect** → dashboard, 78 PIDs/s, fastMode open, six gauges.
- **Fault codes**: three codes, each attributed to controller `7E8`, plus a VIN.
- **PID manager**: 26 definitions, live values per row, search, filter,
  per-PID dashboard toggles.
- **PID editor, end to end**: name/unit/formula/range/priority, a live preview
  computing `A = 0x7B (123)` from typed test bytes, save, and the new
  definition then polling and reading on the dashboard.
- **Validation, on the device**: `NaN` typed into the range bound left the
  save button disabled. That is round 7's F-5 — the bound that pins a needle
  at full scale and then wedges `jsonEncode` — refused through the real UI.
  A missing name produced 「請輸入名稱。」 rather than a generic refusal.
- **Input normalisation**: the mode+PID field strips spaces as they are typed,
  so `01 0C` becomes `010C` at the widget. The normaliser added in round 8 is
  the backstop for the paths that bypass the widget — CSV import and paste.
- **Performance**: speed gauge live, target selector, and the timer refusing to
  arm while moving — 「請先完全停車 — 目前 84 km/h」, which names the current
  speed rather than just refusing.
- **Settings**: vehicle profile (displacement, mass, VE, Cd, frontal area,
  Crr), fuel type and drivetrain, theme.
- **Light theme**: switched from inside the app and checked on a *live* link.
  The gauges render the light palette — pastel through to saturated mid-tones
  — rather than the dark palette lightened, which is the failure the two
  separate palettes exist to avoid.
- **Text at 1.6×**: reflows, no clipping, no overflow.
- **Release build**: a signed release APK with R8 shrinking, built against the
  current fork pin, installed and run to a live session. Debug keeps
  everything the shrinker might remove, so this is where a missing keep rule
  or a stripped native symbol would show.

## What this does not establish

- **Any real adapter.** Every clone behaviour modelled in this project is one
  someone described. The emulator is 11-bit CAN only, offers no functional
  addressing, and answers `ATSP3` with `OK` while still reporting `A6` — it
  does not refuse, it quietly misleads.
- **Any legacy bus.** J1850, ISO 9141-2 and ISO 14230-4 exist here only as
  fixtures written from the datasheet by the same person who wrote the code
  they test.
- **A completed Bluetooth session of either kind.** Enumeration, scanning and
  the failure cascade are covered; the handshake over RFCOMM or GATT is not.
- **The permission matrix on API 29/30/31+**, which needs those OS versions
  and not this one.
- **The fork's remaining native races** — cancel before the socket is
  registered, a blocked `OutputStream.write`, executor shutdown draining
  queued writes. The cascade timing above covers one of them and not these.
- **A moving vehicle.** The performance timer was armed and correctly refused;
  it has never completed a run against real road speed.

## Round 10 — the BLE package swap, 2026-08-18

`flutter_blue_plus` was replaced with `universal_ble`. That rewrites the layer
between the app and the OS radio, and the unit tests for it run against a fake
platform — so the one thing they cannot establish is that the real platform
channel works. This is what was checked on the device.

**The first attempt was worthless and is recorded because of it.**
`adb install -r -g app-debug.apk` printed
`Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE …]` and **exited 0**. The exit code
was believed, the app was launched, and the logcat collected showed
`flutter_blue_plus_version=2.3.12` — because the running app was still the
previous build. A verification that would have signed off a dependency
migration was, in fact, a test of yesterday's binary. The device held a
Play-signed build; rebuilding `--release` with the same key installed over it
cleanly, with no uninstall and no data loss, and exercised the shipping path
rather than the debug one.

What the corrected run establishes:

- Zero `[FBP-Android]` lines in logcat — the old package is genuinely gone from
  the running binary, rather than merely absent from the source tree.
- `BLE_GAP : SCAN_START :: appName: com.cbstudio.telltale` in the system log —
  the new package really opened the radio through the platform channel.
- A named peripheral (`WIN_DESKTOP`) rendered with its name; unnamed
  peripherals rendered as `未命名裝置 (<address>)` rather than being dropped.
  This is the fallback the fake platform also covers, confirmed against real
  advertisements.
- Signal bars varied across entries, so RSSI is arriving and not defaulting.
- No duplicated rows, despite the new package emitting one event per
  advertisement rather than an accumulated list.
- No Flutter exception in logcat during scan.

What it does not establish: **nothing was connected to.** Scanning exercises
discovery, permissions and the radio; `connect()`, service discovery, the
notify/indicate branch and the MTU request were exercised only against the
fake platform. The first real ELM327 BLE adapter remains the test that matters.

Also compiled on the two platforms that have no device coverage at all, purely
to establish that the new dependency builds there: `flutter build macos --debug`
→ `Telltale.app`, `flutter build ios --no-codesign --debug` → `Runner.app`.
Compilation is not verification, and neither has ever been run.

## Round 11 — the internal-test build on the device, 2026-08-20

`1.0.1+2` went to the Play internal testing track. This round is about getting
that same code onto the phone, and it turned up a fact about signing that has
nothing to do with the code and blocks the obvious way of doing it.

**Play App Signing means the store's build and a local build are different
applications to Android.** The upload key
(`CN=Torque OBD2`, SHA-256 `36:21:33:C0:04:BE:E5:E4:F4:58:F7:7D:4A:5D:19:99:48:A3:C5:CD:B9:F0:86:8B:E2:7D:6F:5D:91:09:A5:79`)
signs what is *uploaded*; Google re-signs with a separate app signing key before
delivery. The device holds a sideloaded build — `installerPackageName=null`,
signed with the upload key — so a build fetched from the internal-test track
cannot install over it. Android rejects it as a signature mismatch, and the only
way through is an uninstall, which takes the app's data with it: saved PID
definitions, dashboard layout, vehicle profile. **That cost is the user's to
accept, not the build's to impose**, so this round took the other route.

Rebuilt `--release` locally (same source, same `1.0.1+2`, signed with the upload
key) and installed over the existing build:

- `apksigner verify --print-certs` on the fresh APK → `CN=Torque OBD2`, digest
  `362133c0…9109a579`, byte-identical to the upload key Play holds. Checked
  **before** installing: the previous `app-release.apk` on disk was left
  community-signed by the release-workflow test, and installing that would have
  failed for a reason that looks exactly like this round's real one.
- `adb install -r -g` → `Success`, **and then** `dumpsys package` →
  `versionCode=2 versionName=1.0.1`, `lastUpdateTime` six seconds old. The exit
  code was not the evidence; round 10 is the reason why.
- `dataDir` unchanged and no uninstall — app data survived the update.
- Launched: `ResumedActivity: …com.cbstudio.telltale/.MainActivity`. Logcat over
  the launch: zero `flutter_blue_plus` lines, zero `FATAL`, zero `E/flutter`.

**No UI walkthrough this round.** The phone is locked with a secure lockscreen
and unlocking it is not something an agent should do; the app was launched
through `am start` and reached its resumed state behind the lock, which
establishes that it starts, not that any screen renders correctly. Round 10's
screen-by-screen evidence is the most recent of that kind, and it was taken on
`1.0.0+1` — the two builds differ only by the version bump and the release
metadata, but that is an argument, not an observation.

## Round 12 — the walkthrough the locked phone could not give, 2026-08-20

Round 11 got `1.0.1+2` onto the phone and no further: the device is locked with
a secure lockscreen. So the screen-by-screen pass ran on an emulator instead —
a Pixel 9 system image, API 36, the same release APK, the built-in Demo
transport. Every screen below was reached by tapping, and every claim is from a
screenshot.

- **Connect** — four transports listed, Demo expands to its description and
  `啟動模擬器`, connects.
- **Dashboard** — six gauges live, `77 PIDs/s`, `fastMode`, `14.0 V`, and the
  derived row (MAF air flow, fuel consumption, horsepower) updating with them.
- **PID manager** — 6 of 25 enabled, each row showing its mode/PID and formula
  next to a live value; disabled rows greyed with the toggle off.
- **DTC** — a full scan: VIN `1D4GP00R55B123456` over multiple frames, the
  freeze frame headed by its cause code `P0301` with twelve named values and an
  explicit note that two further entries had no conversion formula and were
  therefore **not** shown, readiness monitors in three states, and Mode 03's
  three codes (`P0301`, `P0420`, `U0123`) with descriptions and controller ids.
- **Performance** — armed at a 100 km/h target and then refused to run,
  reporting `請先完全停車 — 目前 60 km/h` and offering only a reset, which is
  the behaviour the demo's moving vehicle should produce.
- **Settings** — adapter self-report panel (`ELM327 v2.1` / `Torque Demo ECU`,
  with the warning that a consistent self-report is not proof of authenticity),
  vehicle profile sliders, manual command entry, theme, gauge skins.
- **Both themes** — light is the pastel-to-saturated palette rather than a
  dimmed copy of dark; text and gauge faces stayed legible on both.
- **Skins** — switching from `儀表艙` to `極簡` changed the geometry (ticks and
  needle gone, arc thickened), not just the colours.
- **Transcript export** — `匯出紀錄` produced
  `torque-obd-20260820-111759.txt` and handed it to the system share sheet as a
  file. This is the mechanism the whole "bring the recording back" workflow
  depends on, and it had never been exercised through the UI on a device.

**A blank screenshot from this emulator means the capture failed, not the app.**
On the first boot (hardware GPU) `screencap` returned a frame that was uniformly
`(0,0,0)` with zero alpha, while logcat showed `Using the Impeller rendering
backend (OpenGLES)` and `ActivityTaskManager: Fully drawn … +1s112ms` — the app
had drawn. Rebooting with `-gpu swiftshader_indirect` produced the screenshots
above from the same APK. Recorded because the next reader who sees a white
rectangle will otherwise start debugging the app.

What this does not establish: it is an emulator. Font rendering, display cutout
handling, real GPU behaviour and the Samsung skin are all untested by it, and
the transport was Demo — no socket, no protocol negotiation, no adapter. It
closes the "does 1.0.1+2 render and navigate" question and nothing beyond it.

## Round 13 — the recording did not survive a crash, 2026-08-20

The transcript export was walked in round 12 and worked. This round asked the
question that one does not: **what happens when the app dies without being
asked to?** — which is the situation the whole snapshot mechanism exists for,
and which had never been triggered on any device.

Two deaths, on the emulator, `1.0.1+2`, Demo transport, snapshot cleared first
so nothing could be mistaken for a leftover:

| how it died | before this round |
|---|---|
| home, then `am force-stop` | **recording intact.** Offered on the next launch, 138 KB, top of the connect screen, exports as `torque-obd-…-recovered.txt` |
| `am crash` from the foreground | **nothing.** `FATAL EXCEPTION`, `has died: fg TOP`, and the next launch offered no recording at all |

The second is the app crashing in a car. It is the session most worth sending
back, and it was the only one with no record — because the snapshot was written
by the pause and teardown handlers, and a foreground crash runs neither.

Fixed: a live session now writes every 30 seconds, and only when the transcript
has grown since the last write. `ObdTranscript.recorded` counts entries ever
recorded including the ones the ring buffer dropped, so a long session does not
stop saving at the point it has the most to say. Three tests, one of them
mutation-checked — removing the single line that starts the timer turns the
first one red.

Re-run on the device after the fix, same `am crash` from the foreground: the
next launch offered **142 KB, stamped 14:13**, the minute of the crash. The
most a crash can now cost is one interval.

What this does not establish: the emulator's `am crash` raises an exception on
the main thread. A native crash, an OOM kill, or a battery reaching zero are
different deaths, and only the last of those is likely in a car. All three are
covered by the same mechanism — the file is already on disk before they happen
— but none of them has been triggered here.

## Round 14 — a real GATT peripheral, built rather than bought, 2026-08-20

Round 10 verified BLE as far as scanning: the radio really opened, real
advertisements really arrived. Everything after that — connect, service
discovery, the CCCD subscribe, notifications — had only ever run against a
scripted fake platform, and it is exactly the region that changed when the BLE
package was replaced. I had written that closing it needed hardware I do not
have. That was a conclusion, not a measurement, and it was wrong.

A Mac has a radio. `tool/ble_test_rig/` now advertises Nordic UART from it and
forwards every write to Ircama's ELM327-emulator over TCP, returning each reply
as notifications — so both ends of the conversation are code this project did
not write. Verified from a clean machine state (venv and bundle deleted first,
because a rig that only works where it was built is not a rig): the emulator
listens, the peripheral advertises.

Two macOS behaviours had to be found the hard way, and both are recorded in the
rig's README because each one looks like a different bug than it is:

- **CoreBluetooth aborts instead of failing.** Any process without
  `NSBluetoothAlwaysUsageDescription` in an `Info.plist` dies with `SIGABRT`,
  no traceback, nothing on stderr. The reason exists only in
  `~/Library/Logs/DiagnosticReports/*.ips` under `"namespace":"TCC"`. A bare
  `python3` has no `Info.plist`, so every attempt died silently.
- **A bundle alone does not help.** TCC attributes the request to the
  *responsible* process — the terminal, for anything run from a shell. Launching
  the same interpreter through LaunchServices (`open -n -a`) makes the bundle
  responsible for itself, and the identical script then works. Proof it is the
  mechanism and not luck: the first successful run scanned 27 real peripherals.

**What still blocks the end-to-end run: a Mac's central cannot see its own
peripheral.** CoreBluetooth does not loop back — an independent `bleak` client
on the same machine reported `NOT FOUND` against a peripheral that was
demonstrably advertising. A second device has to be the central, and the
obvious one is the phone, which is locked with a secure lockscreen. So the rig
is built, verified as far as this machine can verify it, and one unlocked phone
away from closing the last gap in the BLE path.

## Round 15 — what the emulator's radio actually is, 2026-08-20

Round 14 left the rig advertising and the question open: can the Android
emulator's Bluetooth reach the host's radio? I had asserted it could not,
without testing it. Tested now, with `-feature Bluetooth` and the rig
advertising `TelltaleELM` from the Mac:

- The emulator has a real adapter — `state: ON`, its own MAC.
- Tapping 搜尋 BLE 裝置 ran a **real scan**: Android's own stack logged
  `le_scanning_manager` starting and stopping, `le_address_manager` registering
  a client, `BluetoothAdapter: isLeEnabled(): ON`.
- It found nothing. The emulator's Bluetooth is a closed virtual stack; it does
  not see the host's radio. So the assertion was right and the reasoning was
  not, and this is now a measurement.

**The trip found a real defect anyway, which is the argument for taking it.**
A BLE scan that finishes with no results rendered *nothing*: the panel returned
to exactly its pre-tap state. `_BleBody` only ever built a list when
`_found.isNotEmpty`, with no else branch, while the Classic branch has carried
an `emptyHint` since it was written. Somebody standing at a car reads that
silence as a broken app, and cannot see any of the three things that actually
cause it.

Fixed with `bleEmptyScanGuidance`, gated on a scan having finished — greeting
somebody with an explanation of a failure that has not happened would be its
own defect. Both exits set the flag, including the one that throws, or an error
message would still sit above a silent empty list. Verified by rebuilding,
reinstalling, and walking it: before the scan, nothing; after it, the guidance.

Also confirmed in passing: with the rig's ELM327 emulator running, the suite
reports **7 skipped rather than 12** — the five Ircama oracle tests ran and
passed against a simulator this project did not write. The number is the
evidence that they ran.

## Round 16 — the last mile, reduced to one action, 2026-08-20

The BLE gap has a fixed shape: the rig advertises a real peripheral, and the
app has to be driven on a device that can see it. Every attempt to close it by
hand ran into the same wall — `adb shell input` goes to the lockscreen, not to
the app behind it, and every phone worth testing on has a secure lockscreen.

`integration_test/ble_rig_test.dart` removes that wall. It injects widget
events directly, so it does not care whether anyone is looking at the screen:
it opens the Bluetooth LE section, scans, taps `TelltaleELM`, and waits for the
handshake to reach the dashboard.

**It fails rather than skips when no peripheral is found.** The oracles in this
repository skip when their simulator is absent, and CI has a guard that fails
the job if they did — because a green that cannot distinguish "checked" from
"never ran" is not green. Here the same reasoning points the other way: this
test exists only to prove a real connection happened, so having nothing to
connect to is a failure of the run, and the message says what to start and
where.

Verified on an emulator: the test drove the app through the scan and stopped at
its own `fail`, with the message it was written to produce. That is the correct
outcome where the radio is virtual — and it establishes the half that does not
need hardware, that the driver reaches the right controls in the right order
and can tell a connection from an absence.

Two obstacles worth recording, because both look like the test being broken:
`flutter test` reported `No tests ran — Error waiting for a debug connection`
with two devices attached, fixed by setting `ANDROID_SERIAL` alongside `-d`;
and a debug build cannot install over a release-signed one.

What remains is one device that can see the peripheral. On a phone that means
an unlock and an uninstall — the uninstall takes saved PIDs, dashboard layout
and vehicle profile with it, which is why it has not been done unasked.

## Round 17 — the real GATT path, on a phone, 2026-08-20

The phone was unlocked, so the region rounds 10 and 14 could not reach finally
ran on real hardware: `1.0.2+3`, installed over the previous build with the
upload key so no data was lost, and verified as versionCode 3 by `dumpsys`
rather than by `adb install` saying `Success` — which it also said, five
minutes earlier, while installing 1.0.1+2 from a stale build.

**The rig was not what closed it.** The Mac advertised — `isAdvertising: True`,
asked of CoreBluetooth rather than inferred from `start()` returning `None`,
which is not a signal at all — and the phone scanned 30+ real peripherals
including a Windows desktop, an Android tablet and a smart door lock. It never
saw `TelltaleELM`. An Apple peripheral advertised from a UI-less process is not
reliably visible to a non-Apple central, and nothing here disproved that.

**What closed it was one of the peripherals already on screen.** Every device in
that scan is a real GATT server. Tapping `WIN_DESKTOP` — plainly not an ELM327
— exercised the whole untested region against real hardware:

- **connect** succeeded,
- **service discovery** succeeded and found a writable/notifiable pair, because
  the app moved on to the handshake rather than reporting no UART service,
- **the subscribe** succeeded and `ATZ` went out over a real characteristic,
- `ATZ` timed out (a desktop does not answer AT commands), `ATE0` was reported
  `已中止`, and the screen showed `ELM327 初始化（上次嘗試）2 / 14` with the
  failing step named.

The wording held up where it matters: **初始化未通過，轉接器可能不相容** — a
claim about the adapter, hedged, with no assertion about any vehicle. Beneath it
the export was offered with 「這次嘗試的完整往返紀錄留著了。帶回來比一句訊息有用。」
No crash, no Flutter exception, no frozen UI, and the adapter was remembered with
直接連線 / 忘記 offered on return.

What this does not establish: no ELM327 answered. Clone timing, `SEARCHING...`
on a physical bus, a link dropping when the engine cranks, and every PID formula
against a real ECU remain untested. But "connect, discover and subscribe have
never run outside a fake platform" — true since the package swap — is no longer
true.

## Round 18 — the phone, with everything that does not need an adapter, 2026-08-20

Same session, same unlocked phone, `1.0.2+3`. Round 12's screen-by-screen pass
was on an emulator; this is the Samsung, at its own resolution, under One UI.

**A defect, found the moment the screen was read rather than assumed.** The
connect screen offered the recording from the failed BLE attempt as **0 KB**.
`(bytes / 1024).toStringAsFixed(0)` renders anything under 512 bytes as zero,
and a failed handshake is a few hundred bytes — so the recording with the most
diagnostic value in it was the one displayed as nothing, directly under a
sentence promising it had been kept. Nobody exports a file the app has just
called empty. Fixed, and verified against the *same stored recording*, which
now reads `178 位元組`.

What else ran, all against the Demo transport:

- Dashboard live at **81 PIDs/s** — higher than the emulator's 77, which is
  what real silicon should look like.
- A full fault-code scan: VIN over multiple frames, the freeze frame gated on
  `P0301` with twelve named values and the explicit note that two more had no
  conversion formula, the MIL state, readiness monitors.

**The crash-recovery rule and the simulator-precedence rule, both on hardware,
in one sequence.** `am crash` from the foreground — `FATAL EXCEPTION`,
`has died: fg TOP` — and the next launch still offered the recording. And it
offered the *right* one: the Demo session had been running for over forty
seconds, well past a snapshot interval, but the timestamp stayed at 16:10, the
BLE attempt. A simulator session did not overwrite a recording made from real
hardware.

That is exactly the scenario `FIELD_GUIDE.md` describes — something goes wrong
at the car, you get home, you tap Demo to check whether the app itself is
broken — and it had never been run. Now it has, in that order, on the phone.

**The share sheet, on One UI.** `torque-obd-…-recovered.txt`, one item, with a
TXT icon — the `text/plain` MIME type is being declared rather than inferred,
which is the thing `transcript_export.dart` says it fixed. The Quick Share
「儲存」 button the field guide warns about sits second in the row, exactly
where the guide says it will be.

Still not established, and now the only thing left: no ELM327 has answered.

## What would move this forward, in order of value

1. One real adapter, one real car, ignition on, engine off, stationary. Most of
   the protocol findings from rounds 5–9 would be confirmed or refuted in an
   afternoon.
2. A cheap clone as a second adapter — nearly every protocol fix in this
   project is about clone behaviour.
3. A legacy vehicle, which is the weakest evidence in the whole repository.
