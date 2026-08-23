# Round 6 review — merged findings

Two independent reviewers, again unrestricted, on the tree that round 5 left
behind. `docs/verification/history/review-round-5.md` records the previous round.

- **Codex** (`gpt-5.6-sol`, effort max) — 16 CRITICAL, 9 HIGH, 8 MEDIUM, 4 LOW.
- **Fable 5** — 3 CRITICAL, 5 HIGH, 11 MEDIUM, with device access.

Both read a moving tree: several round-6 fixes landed while they were working,
so a few findings are reviews of those fixes rather than of round 5's output.
That turned out to be the most useful part.

## What round 6 was actually about

Round 5's principle was **an unknown must stay unknown**. Round 6 found it
overshooting in *both* directions, which is the thing worth remembering.

**Not far enough — the fix reached the layer I examined and stopped.**

- Staleness was anchored to a wall clock, which fixed the *answer*. Nothing
  re-asked the question, so a frozen link kept full-brightness gauges for three
  minutes on a device, and the only thing that dimmed them was switching tabs.
- `DtcReadException.partial` carried the codes a broken scan had found, the
  result type exposed them, and no widget ever read the list.
- `voltageMaxAge` expired the value in the client's getter while the snapshot
  held a plain double copied at publish time, and the status pill fell back to
  the handshake reading anyway.
- The epoch guard suppressed a departed poll loop's *publication* and not its
  *writes*, so the stale result rode out on the next loop's snapshot with a
  fresh timestamp.

**Too far — the app refused what it could read.**

- The engine's support mask was treated as a statement about every controller,
  so a custom `7E1:010D` was greyed out as unsupported on the strength of the
  ECM's answer.
- A custom PID's *formula* was treated as its wire schema, so `010C` defined as
  `A` rejected a perfectly valid `41 0C 1A F8`.
- One verified support block licensed every PID into a batch, which a
  partial-map ECU answers short — disabling fast mode for the session.
- The attribution gate added this round would have refused every legacy
  fault-code scan outright, because `_headeredCanLine` had only ever matched
  three- and eight-digit CAN identifiers and no legacy reply could be
  attributed at all.

## Status

Every CRITICAL and every HIGH from both reviewers is closed, along with the
MEDIUM and LOW findings worth acting on. Suite: **328 pass**.

One is deliberately not done, and it is not a defect:

| | Why |
|---|---|
| ~~Codex M-08 — `License.nonprofit` on the BLE connect~~ | **Closed 2026-08-18.** The condition this row named did arrive — the app went to Google Play at US$4.99, which makes the distribution commercial and the `nonprofit` declaration false. Resolved by removing the dependency rather than buying the licence: `flutter_blue_plus` was replaced with `universal_ble` (BSD-3-Clause), which imposes no commercial term and no build-time telemetry. See `docs/protocol-deviations.zh-TW.md` §5. |
| ~~Codex M-07's second half~~ | Done after all: a read now waits out a pending controller, two extra attempts two seconds apart. A **clear** deliberately does not retry — re-issuing Mode 04 resets the readiness monitors a second time, costing the vehicle another drive cycle before it can pass an emissions test, so the user is told to rescan instead. |

## Checked against something other than the suite

The test suite is the thing this round put under suspicion, so the fixes that
could be were verified elsewhere.

| Finding | How |
|---|---|
| Fable C-1, zombie session | On the device, against the real ELM327 emulator over `adb reverse`, frozen with `kill -STOP`: the app disconnects and explains itself within 12 seconds. Before the fix Fable measured four minutes of a green, frozen, confidently-connected dashboard. |
| Codex M-04, signing gate | Built with the keystore present (succeeds) and with it moved aside (refuses, naming `packageRelease, assembleRelease`). The keystore was restored and compared byte-for-byte. |
| Codex M-05, merged permissions | Read out of the merged release manifest: `ACCESS_COARSE_LOCATION` gained its `maxSdkVersion="30"`, `BLUETOOTH_ADVERTISE` is gone. |
| Codex C-07, stale writes | With the guard removed, the reading's timestamp advances to three seconds *after* `stop()` returned. |
| Codex C-11 / Fable M-9, VAL ambiguity | With the detection removed, the second definition's value is served to the first's reference. |
| Whole-app smoke | Demo connect, fault-code scan, three codes and a VIN, on the device — through the *headered* path now that the simulator implements `ATH1`. |
| Fable M-8, shipped derived PIDs | The boost gauge reads 56.0 kPa on the device: `A-VAL{0133}` resolving through dependency scheduling and a controller-scoped, aged cache — the chain Fable reported in round 5 as a permanent formula error. |

## The fork moved four times

Codex H-05 and Fable M-5 are fixed in the plugin rather than here, so they have
no row above. The pinned commit went `01f6491` → `2909bad` (socket leaks,
cancellation, main-thread writes, manifest) → `24c2a64` (`androidSdkInt`) →
`3a84997` (attempt-id cancellation, action-scoped permissions) → `791c6b1`
(orphaned writes answered on close).

## One regression, caught before it shipped

Extending the foreground policy to support discovery (Codex H-03) made a pause
`break` out of the loop — *after* it had cleared the verified-block set. So
backgrounding for five seconds during discovery left that set permanently
empty, batching never opened, and fast mode was dead for the session: the exact
failure the batching gate was added to prevent, re-entered through the pause
added to stop discovery leaking into the background. Nothing would have asked
again either, because `_connectInner` fires discovery once.

Discovery accumulates rather than resetting now, reports whether it finished,
and a resume re-runs it when it did not. It is the seventh time this project
has produced "the fix introduced the next defect", and the first time it was
caught in the same session.

## The simulator was the clone

The most consequential finding is Fable C-2. `DemoTransport` answered `OK` to
every unrecognised AT command, `ATH1` included, and never printed a header —
which is exactly the lying-clone behaviour the app is least able to survive.
Every demo fault-code scan therefore reached its result through the client's
"headers were requested but none arrived, parse it unattributed anyway"
fallback, and **eight tests had pinned that fallback as expected behaviour**.

A simulator more permissive than the hardware certifies paths no real adapter
takes. It implements what it implements now, acknowledges what it can honour,
and answers `?` to the rest.

See `docs/verification/test-evidence.md` for what the suite does and does not establish.
