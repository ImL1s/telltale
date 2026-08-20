# Contributing

The short version: run `flutter analyze` and `flutter test`, walk the screens
you touched on a device or an emulator, and say in the pull request what you
checked and what you did not. The rest of this file is the reasoning, and the
two or three things about this project that are not obvious.

## Where this repository sits

This repository is a **mirror**. The source of truth is a private repository
that also holds a reverse-engineered protocol specification, which is why it
cannot be opened. Everything in `lib/`, `test/`, `android/`, `ios/` and `macos/`
is copied here verbatim and is never edited on this side.

A small publish-only set does live here and only here, and is maintained here:
`PRIVACY.md`, `docs/` (the GitHub Pages copy of the privacy policy, which is
the URL registered with Google Play), `store/`, and `.github/workflows/` — CI
differs between the two sides, because the private one also runs the reference
implementations and an oracle whose simulator cannot be published.

That has one consequence for you: a merged pull request is applied by hand on
the private side and arrives back here in the next sync, so the commit that
lands may not carry your SHA. Authorship is preserved in the commit message.
It is not ideal and it is honest.

Issues and pull requests here are read and answered.

## Toolchain

Flutter **3.47.0** / Dart **3.13.0**. Other versions may work; this is the one
that CI runs and the one release builds are made with.

```bash
flutter --version        # expect 3.47.0
flutter pub get
flutter analyze          # expect: No issues found!
flutter test
flutter build apk --debug
```

`flutter analyze` clean is not advisory. The repository has no accepted
warnings, so one new warning is visible; that only stays true while the count
is zero.

## The tests that skip, and why the number matters

`flutter test` reports around **12 skipped**. That is not slack — it is exactly
the two oracle suites, which need an external ELM327 simulator running and skip
themselves when it is absent:

| suite | tests | simulator |
|---|---|---|
| `test/emulator_integration_test.dart` | 5 | [Ircama/ELM327-emulator](https://github.com/Ircama/ELM327-emulator) |
| `test/freeze_frame_oracle_test.dart` | 7 | a second simulator, not in this repository — see below |

**A skipped test and a passing test print the same summary and both exit 0.**
That is why the number is worth knowing: `~12` is the expected reading, `~0`
means you have a simulator up, and anything else means something is being
skipped that you did not intend to skip. CI does not rely on reading the
number — it parses the JSON report and fails the job if an oracle test was
skipped rather than run.

To run the first suite yourself:

```bash
python3 -m venv /tmp/elmvenv
# Two steps, not one. ELM327-emulator ships as an sdist whose build backend
# imports pkg_resources, which setuptools 82 removed, so a plain
# `pip install ELM327-emulator` fails with `No module named 'pkg_resources'`.
# Measured 2026-08-20: 80.10.2 has it, 81.0.0 still has it, 82.0.0 does not.
# It can also appear to work on a machine that already has the wheel cached —
# same day: succeeds from cache, fails under --no-cache-dir.
/tmp/elmvenv/bin/pip install "setuptools<82" wheel
/tmp/elmvenv/bin/pip install --no-build-isolation ELM327-emulator

# -b matters: without it the CLI exits as soon as stdin sees EOF
/tmp/elmvenv/bin/python -m elm -n 35000 -s car -b /tmp/elm_batch.out &
flutter test test/emulator_integration_test.dart
```

Both suites listen on port 35000 and tell each other apart by the answer to
`AT@1`, so only one can run at a time.

The second suite's simulator lives on a branch of the private repository and is
not distributable from here. Its 7 tests will skip for you and run in CI on the
private side. If you are changing freeze-frame handling, say so in the pull
request and it will be run against that oracle before merge.

**Why two, and why third-party at all.** Every other test in this suite is
ultimately this project's parser checked against this project's simulator —
both sides carrying the same reading of J1979, so a misreading agrees with
itself. The oracles are implementations written by other people from the same
standard. Within an hour of being connected, the first one found two real
defects.

## The rules a change is held to

These are not style preferences. Nearly every one is here because its absence
produced a bug that survived a green test suite.

- **A plausible wrong number is worse than no number.** This is the organising
  principle. When an input is missing or a response cannot be attributed, the
  app shows nothing and says why. It does not interpolate, and it does not
  round a guess into something that looks like a measurement.
- **Responses are parsed against a whitelist, never a blacklist.**
  `Elm327Client._parse` accepts only lines that are entirely hex byte pairs.
  Stripping non-hex characters and concatenating what is left turns `DATA
  ERROR` into two bytes read as a sensor value, and shifts a multi-frame
  payload by half a byte because of its length line. Both produce numbers that
  look reasonable.
- **The demo simulator must be at least as harsh as real hardware.** It emits
  the command echo that precedes `ATE0`, `SEARCHING...`, and multi-frame
  responses with length lines and zero padding. It was once more forgiving than
  a real ELM327, and three critical defects lived under 71 green tests because
  of it. Add the realistic framing first, then the test that catches it.
- **The freeze frame is gated on its cause code.** A controller with no stored
  frame does not refuse the request — it answers `00 00` for the cause code and
  then answers every other PID with zeros, which decode to 0 rpm and −40 °C
  under a heading that says "at the moment the fault occurred". Somebody fixes
  a car from that. `DtcDecoder.decodePair` returns null for `0x0000` and the
  gate is built on that existing rule; do not add a second one.
- **Gauge colours come from `context.gaugeColors(hue)`**, never from the light
  or dark palette directly. The two palettes are separately designed rather
  than inversions of each other — dark runs deep to vivid, light runs pastel to
  saturated mid-tone — and mixing them muddies the light dials.
- **The adapter's self-report is a claim, not a fact.** Clones report v1.5 and
  behave like v1.3. State is committed only when the adapter literally answers
  `OK`.

`SPEC_DEVIATIONS.md` records where this app deliberately departs from the
specification it was derived from, and why. Three of those departures fix
commands that would break a connection to a real vehicle — one of them
silently, and only on vehicles that are not 11-bit CAN. Read it before changing
anything in the AT initialisation sequence.

## Before you open a pull request

- `flutter analyze` — no issues.
- `flutter test` — green, with the skip count where you expect it.
- If you touched anything under `lib/obd/`, run the Ircama oracle above.
- If you touched anything with a screen, walk that screen. The built-in **Demo
  simulator** on the connect screen runs every screen with no hardware and no
  car; there is no excuse for an unwalked UI change.
- Say what you verified and what you did not. "Not tested against real
  hardware" is a normal and useful sentence — most contributors will not have
  an adapter, and the maintainer does. An unstated gap is the problem, not the
  gap.

## What will be turned down

- Loosening the response parser to accept more shapes.
- Replacing a throwing check with a bare `assert`. `dart run file.dart` disables
  assertions, and three reference implementations once printed their success
  banner with deliberately broken expectations because of it.
- Making the demo simulator more forgiving so a test passes.
- A test that is skipped, or a timing constant enlarged, in place of the
  underlying fix.
- Anything that shows a computed figure when an input it depends on was not
  measured.

## Licence

GPL-3.0. By contributing you agree your work is licensed the same way.
