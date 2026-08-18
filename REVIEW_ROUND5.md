# Round 5 review — merged findings

Two independent reviewers read the whole app plus the forked Bluetooth plugin,
with no restriction on focus:

- **Codex** (`gpt-5.6-sol`, effort max) — 13 CRITICAL, 6 HIGH, 4 MEDIUM, 2 LOW.
  Reviewed committed HEAD from a clean worktree. Could not run the test suite:
  its sandbox denies Flutter's bind to `127.0.0.1:0`, and it says so rather than
  claiming a pass.
- **Fable 5** — 4 CRITICAL, 9 HIGH, 16 MEDIUM. Had device access (S25 Ultra) and
  verified several findings on hardware rather than by reading.

The two agreed on three CRITICAL defects by independent derivation. Where they
overlap, the merged entry keeps both IDs so either report can be traced.

Codex reviewed the fork at `a95894a`; the app now pins `01f6491`. The delta
between them is the purge of leaked session-state files plus `.gitignore` /
`.pubignore` — **no plugin code changed**, so the review applies unaltered.

## The shape of it

Round 4's root cause was named as *validity is implicit*. Round 5 says the fixes
made validity explicit **only where someone looked**. The 25 merged findings fall
into four groups, and they have a dependency order — attribution has to be
trustworthy before completeness can be, and completeness before provenance:

1. **Adapter state machine** — the app's model of the adapter drifts from the
   adapter. State is committed on send rather than on acknowledgement, and a
   failed restore leaves no way to know.
2. **Completeness** — a partial answer is accepted as a whole one. A prefix
   parses, a suffix is ignored, one ECU's refusal is outvoted by another's
   answer, and the UI then declares the vehicle clean.
3. **Provenance** — values have no timestamp, no source, and no session epoch,
   so a stale or foreign reading is combined with fresh ones and shown as
   current.
4. **Lifecycle, platform, fork** — races and packaging.

## Status

| # | Codex | Fable | Defect | Group | Status |
|---|---|---|---|---|---|
| 1 | C-01 | C5-2 | `_resync()` declared success without ever observing a prompt | state | **fixed** `d2e963d` |
| 2 | C-02 | C5-1 | Classic timeout branch unreachable — cascade raced up to 3 RFCOMM sockets | state | **fixed** `d2e963d` |
| 3 | C-03 | C5-4 | Undetermined protocol decoded as CAN, fabricating DTCs | state | **fixed** `d2e963d` |
| 4 | C-04 | — | Legacy "global" request inherits the last custom physical header | state | **fixed** `b7ec8c4` |
| 5 | C-05 | H5-2 | Header state committed before ACK; `sendGlobal()` accepts un-attributed data | state | **fixed** `b7ec8c4` |
| 6 | C-06 | — | Mode 01 accepts a valid prefix and ignores an arbitrary suffix | completeness | **fixed** `b7ec8c4` |
| 7 | C-07 | — | DTC decoder discards a dangling byte instead of rejecting | completeness | **fixed** `b7ec8c4` |
| 8 | C-08 | — | One ECU's explicit refusal ignored when another answers | completeness | **fixed** `b7ec8c4` |
| 9 | C-09 | — | Blanket green all-clear while categories are known unanswered | ui | **fixed** `5b8a93d` |
| 10 | — | C5-3 | Multi-ECU last-writer-wins: another controller's bytes overwrite a good reading | completeness | **fixed** `b7ec8c4` |
| 11 | C-11 | M5-3 | `VAL{}` drops controller identity and freshness | provenance | **fixed** `9cbdc67` |
| 12 | C-10 | M5-4 | Acceleration survives a data gap, combined with fresh RPM as current power | provenance | **fixed** `896d027` |
| 13 | C-12 | H5-4 | Absent barometric pressure replaced with sea-level 101.3 kPa | provenance | **fixed** `9cbdc67` |
| 14 | C-13 | — | Adapter voltage has no age and survives every failed refresh | provenance | **fixed** `896d027` |
| 15 | H-01 | H5-3, H5-6, M5-5 | Lifecycle ownership not generation-based; three foreground-only holes | lifecycle | **fixed** `3108769` |
| 16 | H-02 | H5-1 | Temporary absence becomes permanent unsupported; fastMode self-destructs | completeness | **fixed** `5cb371a` |
| 17 | H-03 | — | Mode 02 request accepted without the freeze-frame byte | completeness | **fixed** `4f41b9a` |
| 18 | H-04 | — | Permission handling conflates scanning with paired-device connection | platform | **fixed** `e798966` |
| 19 | H-05 | H5-8, H5-9 | Fork: socket leaked on every failure path; write blocks the main thread | fork | **fixed** fork `2909bad` |
| 20 | H-06 | M5-16 | A release build silently succeeds with the debug signing key | platform | **fixed** `5cb371a` |
| 21 | — | H5-5 | DTC scan results wiped by a single tab switch | ui | **fixed** `bb33c74` |
| 22 | — | H5-7 | Fork manifest merges `bluetooth required="true"` into the app | fork | **fixed** fork `2909bad` |
| 23 | M-03 | M5-7 | Contrast below the tested floor; VIN row overflows at 2× text scale | ui | **fixed** `8dd2a9d`, `4cc13a6` |
| 24 | M-04 | M5-11 | Emulator lane turns green silently when the oracle is absent | tests | **fixed** `4cc13a6` |
| 25 | — | M5-1, M5-2 | Staleness anchored to last publish; PID manager bypasses the contract | provenance | **fixed** `e5dc234` |

**Every CRITICAL and every HIGH is closed** — all 13 of Codex's CRITICALs, all
4 of Fable's, and every HIGH from both, deduped to the entries above. Each
CRITICAL carries a test built from the reviewer's own trigger bytes in
`test/round5_triggers_test.dart`. Suite: 285 pass.

Four fixes were verified against something other than the test suite, because
the test suite is the thing under suspicion:

| Finding | How it was checked |
|---|---|
| H-06 signing gate | Built the AAB and read the certificate out of it: `CN=Torque OBD2, O=ImL1s`, SHA384withRSA 4096-bit — not the debug key |
| H5-7 manifest merge | Compared merged manifests either side of the fork change: `required="true"` before, `"false"` after |
| H5-5 tab switch | On the device: scan, tap 性能, tap back — the three codes and the VIN are still there |
| M-04 emulator lane | Pointed it at a dead port; the runner now reports `~5: All tests skipped` with a reason, where it used to report `+5: All tests passed` |
| M5-8 Wi-Fi memory | Typed `192.168.4.77`, let it fail, force-stopped, relaunched — the address is still there |
| M5-15 cleared layout | Turned off all six gauges, force-stopped, relaunched — still 已啟用 0 項 |
| M5-7 text scale | `font_scale 2.0`: the full VIN renders inside its panel, no overflow stripes |
| M5-9 list copy | The hint renders above a list of the phone's actual bonded devices — earbuds, a desktop, a game controller |
| H-01 resume | Backgrounded a live demo session for five seconds; on resume the gauges advance rather than holding pre-pause values |
| M5-5 late publish | Measured rather than argued: with the guard removed, an extra snapshot lands 560ms after `stop()` returns |

**Every finding in the table above is closed**, and so are the MEDIUM items
from the reviewers' own files that were worth acting on: the Mode 07 card's
copy (M5-6), the deliberately-cleared dashboard being overridden (M5-15), the
Wi-Fi address not being remembered (M5-8), the paired list offering headphones
and an ELM327 with equal prominence (M5-9), and macOS missing
`NSLocalNetworkUsageDescription` (M5-16).

One was deliberately not done as specified. M5-9 asks for a Class-of-Device
filter; the forked plugin does not report Class of Device, and guessing an
adapter from its name would eventually hide someone's adapter because they
renamed it. Likely adapters are sorted to the top and the list says what it
contains, which costs nothing when the guess is wrong. Exposing Class of Device
from the fork is the real fix and is worth doing deliberately rather than in
passing.

Remaining MEDIUM/LOW from both reports are tracked in the reviewers' own
unpublished reports and folded into the group they belong to.

## What each reviewer could not check

Neither reviewer has driven a real ELM327 or a real car — nor has this app, ever.
Codex could not execute the suite at all. Fable's device findings are real
observations; its wire-level findings are derived from source, and it labels
which is which. The legacy (J1850 / ISO 9141-2 / KWP2000) and 29-bit CAN paths
remain covered only by fixtures written from the datasheet by the same person who
wrote the code under test — which is exactly where three of this round's
CRITICALs were found.

## What the walkthrough could not show

Honest limits on the device evidence above, so it is not read as more than it
is:

- **No ELM327 is paired with this phone**, so the Classic list's adapter-first
  sorting could not be demonstrated — only that the list and its hint render.
- **The demo ECU answers all three DTC classes**, so the `partialClean` amber
  panel and the rewritten Mode 07 copy are unreachable on device. Their evidence
  is `round5_triggers_test.dart` and the unit tests, not a screenshot.
- **The pause-blank window is shorter than a frame on the demo transport**,
  which replies instantly. The resume path was verified by its outcome — values
  advancing rather than freezing — not by catching the empty snapshot visually.
- **The light theme's contrast is arithmetic**, checked in `contrast_test.dart`.
  The screenshot confirms nothing looks broken; it cannot confirm a ratio.
