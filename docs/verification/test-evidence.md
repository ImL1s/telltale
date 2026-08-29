# What the test suite establishes, and what it does not

The suite is green. **There is deliberately no test count in this file.**

That number has now been wrong here four times — 323 stated while the suite
ran 328, then 342, then 361, and most recently a figure barely over half the
real total — and each correction was a document catching up with a tree that
had already moved again. `docs/verification/history/review-round-7.md` filed the recurrence as the least
interesting finding in the project and the most repeated. The fourth
occurrence landed here, in the same paragraph as a sentence saying that a
document reporting a count has to be re-read whenever the count moves. At that
point the count is not a fact this file should be carrying: `flutter test` prints it on its last line,
it is never out of date, and a transcription of it here is a claim about the
tree that starts rotting the next time anyone writes a test.

What a count cannot tell you is what *kind* of evidence it is, and that is
what this file is for.

**It is strong automated evidence plus physical-phone rig runs** — BLE/GATT,
Demo, Classic through a mocked plugin boundary, and Wi-Fi over the phone's real
radio including the Android route-lease bind path. Those layers remain separate
from the one bounded purchased-adapter/GT86 observation documented in
`device-verification.md`; a real connection does not retroactively turn any
software fixture into broad vehicle evidence. The maintained overview is the
[rig matrix](rig-matrix.md).

## The oracle surfaces, and what each can be trusted for

| | What it proves | What it cannot |
|---|---|---|
| `test/support/fake_elm327.dart` | That the client handles the framing, faults and multi-ECU shapes *I believe* adapters produce | Anything about shapes I got wrong — it shares the implementation's assumptions by construction |
| `Ircama/ELM327-emulator` (`emulator_integration_test.dart`) | That the client works against an implementation nobody here wrote | 11-bit CAN only; no functional addressing; answers `ATSP3` with `OK` while still reporting `A6`, so it does not refuse — it quietly misleads |
| Ircama through `tool/obd_test_rig/chaos_proxy.py` (`chaos_oracle_test.dart`) | That the real Wi-Fi socket handles deterministic fragmentation and fails closed on peer close, a missing prompt, or a corrupted critical reply | Physical radio loss, adapter reboot behavior, vehicle timing, or any fault shape not injected by this repository's proxy |
| Project-owned `elm327_virtual_server.py` (`freeze_frame_oracle_test.dart`) | That the freeze frame (Mode 02) survives a separately maintained, hash-pinned research-branch oracle — its Mode 02 came from a separate agent review lane and disagreed usefully on first contact: it serves the data PIDs with **no support mask at all**, a shape a mask-first reader renders as "this car has no stored frame". Its seven cases also cover the fault-code classes, the readiness monitors, VIN reassembly, two controllers answering a census, a deadline, and a link that drops mid-session | It is not an independent third-party implementation. It has the same 11-bit CAN-only limit as Ircama's and remains one implementation's reading of J1979, not the standard — where the two readings happen to agree they can still be wrong together |
| Physical BLE rig (`integration_test/ble_rig_test.dart`) | A Samsung `SM-S9280` can scan, hit-test the discovered result, connect through Android GATT, discover Nordic UART, subscribe, exchange ELM327 commands/notifications, poll live data, and persist rig-labelled evidence | The peripheral and ECU are simulated; no CAR25 firmware, real adapter timing, CAN bus, vehicle, Classic RFCOMM, or OS-delivered Doze/lifecycle behavior |
| Wi-Fi rig (`integration_test/wifi_rig_test.dart`) | The shipped wizard connecting over the device's real TCP stack — and, against a non-loopback host, the Android route lease actually binding through `ConnectivityManager` on real hardware — to an ELM327 implementation nobody here wrote | The adversarial network the binder exists for (an internet-less hotspot with cellular armed); dual-STA ambiguity; adapter firmware and timing |
| Demo / Classic rigs (`integration_test/demo_rig_test.dart`, `classic_rig_test.dart`) | The shipped wizard, live polling, lifecycle recovery and simulated-evidence labelling on a physical phone; Classic exercises the plugin boundary through mocked platform channels bridged to the Demo ECU | Demo touches no socket or radio; Classic proves nothing about `BluetoothSocket`, RFCOMM, or a real adapter |
| Other on-device runs (`SM-S9280`) | Layout, theming, text scaling, Android lifecycle, and anything visible | Purchased-adapter or vehicle behavior unless the exported field transcript says otherwise |

The legacy buses (J1850, ISO 9141-2, KWP2000) and 29-bit CAN are covered
**only by fixtures written from the datasheet by the same person who wrote the
code under test**. That is the weakest part of the evidence, and three of round
5's CRITICAL findings were found exactly there.

The two upstream socket simulators bind port 35000 — `WifiTransport.defaultPort`
— so they can never run in the same pass. The chaos proxy listens separately
and forwards to Ircama, using a fresh process for each fault so its global
command counter cannot leak between cases. A default `flutter test` reports
thirteen skips: seven freeze-frame tests, five Ircama tests, and the explicitly
enabled chaos test. A skipped oracle is not a passing oracle, and the summary
line alone does not distinguish them; CI parses the JSON event stream and
rejects skips in every oracle run.

### The datasheet is another oracle, and it has been misquoted

For the legacy buses it is the *only* oracle: no test can catch a wrong header,
because the fixture and the implementation would be wrong together. So a
citation is load-bearing in a way a comment normally is not — and two in
`addressing.dart` turned out to be fabricated, discovered in round 7 by a
reviewer reading the actual PDF.

One was a paraphrase attributed to a page it is not on. The other invented a
worked example outright: `ATSH 6810F1`, described as "the datasheet's own
example for a legacy bus", is not in the document. The string `68 10 F1` does
not appear anywhere in it. That header was then transmitted to real vehicles on
three protocol families that each reject it for a different reason.

A wrong citation is worse than none, because it stops the next reader from
looking it up.

That sentence used to be followed by "every datasheet reference in
`addressing.dart` has now been grepped, and the ones in `elm327_client.dart`
were checked in the same pass and hold". **The second half was untrue when it
was written.** A third copy of the same fabricated quote was sitting in
`elm327_client.dart`'s init sequence, and the sweep that claimed to have
checked it had grepped three other citations in that file and stopped. It was
found a round later, by reading the file for something else.

So the claim is narrower now, and the method is worth stating because the
obvious method is wrong. The datasheet PDF is two-column, and the extracted
text interleaves the columns **line by line** — a sentence from the left column
is broken up by right-column text between its lines. Searching for a whole
quoted sentence therefore returns nothing even when the sentence is really
there, and two genuine citations were briefly suspected on exactly that basis.

Believing that false negative would have meant "correcting" a correct citation,
which is the original mistake reflected. Fragments, checked individually and in
order, are what actually settles it. Page numbers settle nothing: a page number
is precisely the part a fabricated citation gets right-looking.

Every citation in both files has now been checked that way. New ones should be
quoted rather than paraphrased, and checked before they are written.

## Two failure modes this suite has actually produced

Both are documented in `round5_triggers_test.dart`'s header because both
happened while writing the tests that were supposed to prevent them.

**A test can pass because nothing happened.** An `isNull` expectation is
satisfied by a value that was never fetched. The polling helper now asserts its
own success condition and dumps readings, faults and the command log when it
times out — it used to reach its deadline and return normally, which
reintroduced the exact failure it was built to stop.

**A test can fail for the wrong reason.** Several trigger tests failed inside
`connect()` rather than in the code under test, because a fixture lacked the
handshake's `0100` probe or gave a legacy ECU a CAN-shaped address. That is
more dangerous than a false green: the real fix leaves the test red, which
invites the fix to be "corrected" until the colour comes back.

The habit that catches both: after writing a fix, **remove it and confirm the
test fails** — and read *why* it fails. Several fixes in rounds 5 and 6 were
discovered to be doing nothing this way, including an epoch guard that could
never fire because `stop()` did not increment the epoch.

## Specific things nothing here covers

Named by Codex in round 6, kept as a list rather than a claim:

- Android permission behaviour on API 29 / 30 / 31+ — no instrumentation tests
- Native socket races in the fork: cancel before the socket is registered,
  cancel after it is removed, a blocked `OutputStream.write`, executor
  shutdown draining queued writes
- BLE: an immediate notification race during CCCD enablement, MTU refusal on a
  physical adapter, indication-only hardware, and notification reordering under
  radio loss
- Real 29-bit and legacy rendering from actual hardware, as opposed to from the
  datasheet's worked examples
- Clone adapters generally — every clone behaviour modelled here is one someone
  described, not one that was observed

## Known gaps, written down rather than half-built

- **J1850 has no restore header, and the reason is a missing source rather
  than a missing idea.** A custom PID with an explicit header on protocol 1 or
  2 leaves the app unable to return to a known addressing state, so built-in
  queries are refused rather than sent to whichever controller the custom PID
  selected. ELM327DSJ gives J1850 no default request header — its Periodic
  Messages section covers ISO 9141 and KWP only — and its J1850 examples are
  non-legislated addressing. Round 8 supplied `616AF1` (PWM) and `686AF1`
  (VPW), sourced to ELM320 documentation not held here. Either would lift the
  refusal for its sub-protocol the moment it is verified against a primary
  source; the two are now separate enum members precisely so that one can be
  answered without the other.

- **The census-before-scan ordering is asserted, not raced.** A fault-code
  scan now waits for the responder census instead of reasoning from whatever
  the unawaited call at connect happened to leave behind — a hole every test
  for the silence check missed, because they all took the census by hand
  first. The test for the fix checks the postcondition; the demo transport
  answers fast enough that the unawaited census lands before a scan finishes
  anyway, so removing the await leaves it green. Isolating it needs a
  transport slow enough to lose the race, and `ObdSession` accepts no injected
  transport.

  Round 23 had an independent reviewer find this and reproduce the mutation,
  which is what the note is for. It also sharpened *why* a slow transport is
  not on its own enough: the link is serial, so a scan started without the
  await still queues behind the census's own commands and reads a populated
  census regardless. The case that actually differs is a census **abandoned on
  its deadline** — `_responders` null and `_censusAttempted` still false when
  the read reasons about coverage, which is the branch that closes a category
  making no coverage claim at all. Reproducing that needs a transport that can
  stall one specific command, not merely a slow one. Recorded here rather than
  approximated with a seam that would produce a test passing for the wrong
  reason.

- **`R6 M-3` does not prove the batching gate.** It asserts that no multi-PID
  request goes out while capability is unverified, and that holds in its
  fixture whether or not the gate exists: the physics inputs are merged in
  unanswered, so the scheduler's head is usually an unbatchable PID and returns
  alone. Breaking the gate leaves the test green. The claim that batching can
  happen at all is carried by `R7 H-02`, which asserts a multi-PID command
  really does go out before asserting what is excluded from it — the two are
  only meaningful together, and the file says so.

- **The acceleration gap-reset is not covered.** `_trackAcceleration` resets
  the smoothed derivative when more than three seconds separate two speed
  samples, so a hard launch cannot be paired with a later steady cruise. The
  test that claimed to cover it never started the poll loop, so the reset was
  structurally unreachable from it — neutering the reset left the test green.
  It has been renamed to what it does establish (unknown is not zero).
  
  Isolating the reset needs an observable that outlives `accelerationMaxAge`,
  which expires the value after two seconds regardless — so the obvious test,
  "assert null after a four-second gap", would pass for the wrong reason. That
  is the trap this file exists to describe, so the gap is recorded instead of
  papered over.

- **A widthless custom PID whose data begins with `0x41` is refused.** Round 8
  gave the cost a real address: a custom definition on `0122` whose controller
  answers `41 22 41 00 01`. The data `41 00 01` is one complete answer, and the
  parser cannot tell it from `41 00` followed by the start of a second reply,
  because without a declared width nothing bounds the slice.
  
  Narrowing the check to "a second answer to *this* PID" would accept that
  case and reopen the one it was built for — an adapter gluing a different
  PID's late reply onto the same line, where a formula reads the unrelated
  service byte and publishes a plausible number. This app ranks a confident
  wrong number below a visible refusal, so the refusal stands. It is a
  limitation of the parser rather than of the vehicle, and it is written down
  here because a user meeting it would otherwise reasonably conclude their car
  lacks the sensor.

- ~~The definition-generation guard is reasoned, not demonstrated.~~
  **Demonstrated, and it was not enough.** The first attempt at a test passed
  with the guard removed, and this file recorded that rather than adjusting the
  test until it went green. Round 8's reviewer supplied the way round the
  obstacle, and it needed no in-flight work at all: inject the scheduler,
  enqueue a request built from the old definition, swap in one with the same
  id, and start. The queued object is dequeued *after* the swap, so the
  generation check passes.
  
  Written that way the test failed against the shipped code — raw `0x0A`
  published as 100 for a gauge whose surviving definition says 10 — because
  retiring queued work *by id* does nothing when the id is unchanged and only
  the formula was edited, which is the ordinary case. Survivors are re-pointed
  at the current definition now.
  
  The lesson is about the record rather than the code: "I could not test this"
  was true of the approach and not of the property, and writing it down is what
  let someone else supply the missing move.

The entry that used to live here — "a legacy vehicle's global scan is not
attribution-checked", filed as needing hardware before the risk could be judged
— was closed in round 7 without any, and the way it closed is worth keeping:

> The gate read `functionalHeader == null`, which stood in for "is this a
> legacy bus". Two states were sharing that branch and they want opposite
> answers. An adapter that answers `OK` to `ATH1` and then prints nothing is
> contradicting itself, and nothing it says can be trusted. An adapter that
> answers `?` is merely limited: the request still reached the bus, so any
> codes it returns are real, and only the *coverage* claim has to be given up.
> Separating them made the second case a qualified result rather than either a
> false all-clear or a hard error — no hardware needed, because the missing
> information was never on the wire.

The proxy was also a latent trap: giving the legacy buses functional headers of
their own, two files away, would have flipped every one of them into the
hard-failing branch. That is the shape to watch for — a condition standing in
for something it is only correlated with.

## Round 23 findings that were deliberately not repaired

Written down so they stop being rediscovered. Both were raised by an
independent reviewer, both were checked, and both are being kept as they are.

- **The legacy checksum is mandatory** (`elm327_client.dart`,
  `_parseHeaderedLegacy`). J1850's CRC-8 and ISO 9141/KWP's running sum are
  both verified correct against the standards, and a line that fails either is
  refused as `DATA ERROR`. A clone that omits checksums on legacy replies
  therefore cannot complete any scan on ISO 9141, KWP or J1850, where other
  tools cope.

  Kept, because the failure is an error and never a wrong answer, and because
  the alternative — accepting an unverifiable legacy line — reopens the exact
  defect this check was added for: a checksum byte read as fault-code data.
  It is nonetheless the one place in this codebase where strictness rests on
  an assumption about rendering that no hardware has confirmed, and it is the
  first thing to re-examine when a real legacy adapter is available.

- **`_parse`'s fall-through can return a headerless line as a successful
  payload.** With headers on, a line that matches neither the legacy nor the
  CAN grammar and does not look headered reaches the unattributed whitelist
  and comes back `isSuccess`. `7E8 02 43 00` losing exactly its `7E8 ` prefix
  to BLE fragmentation is the shape.

  Kept, because every current consumer catches it downstream: batched polls
  check the `41 <pid>` echo per frame, and global reads go through
  `_rejectAnonymous`. So the observable result today is a faulted PID rather
  than a wrong number. It is recorded here as defence-in-depth owed rather
  than a live defect, because the client's own error contract is void on that
  path and a future consumer trusting `isSuccess` would inherit the hole.

## What would move this from unit evidence to hardware evidence

In order of value:

1. A stationary hardware-in-the-loop run: one real adapter, one real car,
   ignition on, engine off. Most of the protocol findings above would be
   confirmed or refuted in an afternoon.
2. The API 29/30/31+ permission matrix on real devices.
3. A second adapter of a different make, ideally a cheap clone, since almost
   every protocol fix in rounds 4-6 is about clone behaviour.

Until then, a green suite means the code does what I believe an adapter would
ask of it. It does not mean the app works in a car.
