# Round 7 review — merged findings

Two independent reviewers, unrestricted, on the tree round 6 left behind.
`REVIEW_ROUND5.md` and `REVIEW_ROUND6.md` record the previous rounds.

- **Codex** (`gpt-5.6-sol`, effort max) — 3 CRITICAL, 9 HIGH, 4 MEDIUM, 1 LOW.
- **Fable 5** — 0 CRITICAL, 9 HIGH, 9 MEDIUM, 9 LOW/NIT, with device access.

Five findings were reached independently by both, which is the strongest
signal either produced: the write deadline (Codex H-01 / Fable F-12), batch
membership (H-02 / F-3 and F-14), the widthless slice (H-03 / F-4), formula
ambiguity (H-04 / F-9) and the fork's connect race (H-08 / F-6).

## What round 7 was about

Round 5's rule was *an unknown must stay unknown*. Round 6 found it
overshooting in both directions. Round 7 found something narrower and worse:
**things the code had already worked out and then discarded.**

- The parser preserved each legacy line's source, and `readVin` grouped by
  sequence number alone — splicing two controllers into one syntactically
  perfect VIN belonging to no vehicle.
- `dataByteCount` stated that a PID without a declared width never joins a
  batch. Nothing enforced it, and the result was 13 km/h for a stationary car.
- A pending controller's identity was recorded, and then every retry attempt
  built its own result list — so the fault the first attempt had proven was
  dropped when the second came back clean.
- Attribution reached `DtcReadException`, the result type and the complete
  rows, and the partial pills rendered the bare code.
- `pidValue` distinguished three reasons for refusing, and reported all three
  as the same one.

The other half was **proxies**: conditions standing in for something they are
only correlated with. `functionalHeader == null` meant "is this legacy" until
legacy buses got functional headers two files away. `_isPositivelySupported`
meant "may this be batched" until the two questions diverged. Each would have
turned a working vehicle into a permanent error through an edit somewhere
else.

## The citation that was not real

The sharpest single finding is Fable F-2. `BusAddressing.engineHeader`
returned `6810F1` for J1850, ISO 9141-2 and ISO 14230-4 alike, justified in a
comment as "the datasheet's own `ATSH` example for a legacy bus (p.42)".

`68 10 F1` appears nowhere in ELM327DSJ. The physical example on that subject
is `AT SH E4 10 F1`, and `E4` is a J1850 *PWM* priority byte. Each family
refutes the constant for its own reason — ISO 9141-2 defines only functional
addressing for OBD, ISO 14230-4 honours just the top two bits of the format
byte where `0x68` selects a different mode from its own `0xC1` default, and
J1850 needs a priority byte chosen per sub-protocol from SAE J2178.

The same file states the correct principle twenty lines above, in
`functionalHeader`: *"guessing one is worse than using the adapter's own
defaults."* It then guessed. A second citation in the same file's header was
also a paraphrase attributed to a page it does not appear on.

For the legacy buses the datasheet is the *only* oracle — no test can catch a
wrong header, because the fixture and the implementation would be wrong
together. Every reference in that file has now been checked against the text.

## Status

**Every finding from both reviewers is closed**, in the app and in the fork,
except the two things this machine cannot do. Suite: **372 pass**.

Three were checked and found *not true of this tree*, which is recorded
because the alternative is fixing something twice: Fable F-1 (a `return`
inside `finally`) and F-19 (a mixed pending reply's failure kind) and F-23 (a
comment about `stop()` not incrementing the epoch) had all already been
fixed. Both reviewers read blobs from before those landed, which is the cost
of reviewing a tree that is still moving — and worth the cost, since the
moving parts were what they found.

What genuinely remains:

| | Why |
|---|---|
| Native instrumentation for the fork's connect-cancellation race | The fix shipped at `f04ef9d` and the Dart half is tested, but the ownership race lives inside a Kotlin worker thread and the plugin has no Android instrumentation harness. The interleaving is argued, not executed. |
| Anything requiring a real adapter or a real vehicle | There is neither. `TEST_EVIDENCE.md` has said so from the first round and still does. |

## Against Codex's own closure bar

The report ends with five conditions for another all-clear. Measured
honestly:

| | |
|---|---|
| 1. C-01 to C-03 with hostile transcripts failing pre-fix for the intended reason | **Done.** Each was removed and the failure *read*: `[]` for the misfire, `1HGCM82633A004352` character for character, `[]` for the damaged peer. |
| 2. Lifecycle, scan deadlines and pending transactions own the send boundary | **Done.** `mayTransmit` is consulted inside the serialized chain immediately before every write; the scan deadline is passed into `readDtcs` rather than wrapped around it, and removing that check sends three Mode 03 requests where one is allowed. |
| 3. Controller-scoped, explicit-width evidence before batching; frame boundaries retained for custom responses | **Done.** H-02 and H-03. |
| 4. Native Android tests for connect cancellation ownership and action-specific permission callbacks | **Partly.** The fork's races are fixed at `f04ef9d` and the Dart half is tested, but the plugin has no Android instrumentation harness, so the Kotlin interleaving is argued rather than executed. |
| 5. Transcripts from one real CAN adapter and one real legacy vehicle before calling the global scan vehicle-wide | **Not done, and not possible here.** No adapter and no vehicle. `TEST_EVIDENCE.md` has said so from the start and still does. |

## Checked against something other than the suite

| Finding | How |
|---|---|
| F-2, the invented header | Grepped `68 10 F1`, `6C10F1`, `E410F1`, `686AF1` against the datasheet text directly. Only the ones now in the code are there. |
| H-09, response pending | Datasheet p.45 settles it: from v2.1 the adapter changes its own timeout to five seconds on `7F xx 78`, for CAN and KWP "as per the standard" — and names the multi-ECU case it does not handle. The retry now exists only where the adapter's own handling does not reach. |
| F-5, NaN ranges | Run against Dart 3.13: `tryParse('NaN')` succeeds, every comparison is false, `clamp(0, 1)` returns **1.0**, `jsonEncode` throws. All four claims hold. |
| F-9, first half | *Not* reproducible on this tree. `setActivePids` calls `clearCache()`, which clears `_ambiguous`; the reviewer read a blob from before that landed. |
| F-1 | Already fixed before the report was written, same cause. |
| F-17, the fake's spacing | The app's handshake sends `ATS0`, so real hardware answers unspaced — and the primary oracle acknowledged it and kept printing spaces, certifying the one rendering no adapter produces. It honours it now, and a test asserts the raw line has no spaces and still parses. |
| F-13, ambient pressure | With the mirrored rule removed, `BARO` returns the second definition's 1010.0 instead of refusing. |
| F-25, frame padding | The reviewer flagged its own premise as a guess from datasheet memory, so it was checked rather than adopted — and the datasheet settles it: `7E8 06 41 00 BE 3F B8 13 00`, six bytes declared, six delivered, one `00` filling the frame to eight. The demo padded its multi-frame branch and not its single-frame one, so the shipped simulator never produced the shape real hardware prints most often. |
| The fork bump | Rebuilt against `f04ef9d`, installed on the device, demo connected: 76 PIDs/s, fastMode open, all six gauges reading. |
| The emulator lane | Run against a live `Ircama/ELM327-emulator` on `127.0.0.1:35000` rather than skipped — five tests, fifteen seconds of real socket work. That lane reports itself as *skipped* when the emulator is absent, which is deliberate, and it means "372 pass" is only three oracles deep when someone has actually started it. |
| The release build | Not just debug. A signed release APK with R8 shrinking, built against the new fork pin, installed and run: 78 PIDs/s, fastMode open, six gauges live. Debug builds keep everything the shrinker might remove, so this is where a missing keep rule or a stripped native symbol shows up. |
| Whole app | On the device: demo connect, 78 PIDs/s with fastMode open, six gauges reading, then a fault-code scan returning three codes each attributed to controller `7E8` and a VIN. That exercises the derived support mask, the batching gate, the attribution rekey and the pre-write lifecycle check on one path. |

Every fix in this round was removed after it was written and confirmed to fail
— and the failure read, not just observed. Two were kept for the reason they
failed rather than that they did: without the refusal type the gauge is dark
with `faults: {}`, and without the accumulator `readDtcs` returns `[]` for a
car with a confirmed misfire.

## One test deleted rather than fixed

The definition-generation guard (Codex H-04) ships without a test. The one
written for it passed with the guard removed — at the moment the definitions
were swapped, no request from the old set happened to be outstanding — and
provoking that state needs control over which PID is in flight that the
scheduler does not offer.

It was deleted rather than adjusted until it went green. A test that passes
either way is worse than none, and `TEST_EVIDENCE.md` lists the guard as
reasoned rather than demonstrated. This project has shipped that mistake
twice: the `014` artifact test reverted the day before, and the heartbeat test
Codex caught this round, which had pinned "a stopped engine keeps publishing"
as desired behaviour.

## The count that kept being wrong

`TEST_EVIDENCE.md` claimed 323 tests while the suite ran 328, then 342, then
361. Codex filed it as L-01 — closure documents not true of the tree — and it
is the least interesting finding here and the most repeated. A document that
reports a number has to be re-read whenever the number moves.

See `TEST_EVIDENCE.md` for what the suite does and does not establish.
