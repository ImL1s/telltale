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

A small publish-only set lives here and is maintained on the public side:
`.github/`, `store/`, and the GitHub Pages shell files `docs/.nojekyll`,
`docs/index.html`, and `docs/privacy.html`. Product Markdown documentation and
`PRIVACY.md` come from the private source of truth. CI differs between the two
sides because the private repository also runs the reference implementations
and an oracle whose simulator cannot be published.

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
flutter build apk --debug --flavor field
```

`flutter analyze` clean is not advisory. The repository has no accepted
warnings, so one new warning is visible; that only stays true while the count
is zero.

## The tests that skip, and why the number matters

`flutter test` reports around **13 skipped**. That is not slack — it is exactly
the externally driven oracle files, which skip unless their required emulator
or fault proxy is running and explicitly enabled:

| suite | tests | simulator |
|---|---|---|
| `test/emulator_integration_test.dart` | 5 | [Ircama/ELM327-emulator](https://github.com/Ircama/ELM327-emulator) |
| `test/freeze_frame_oracle_test.dart` | 7 | a second simulator, not in this repository — see below |
| `test/chaos_oracle_test.dart` | 1 | Ircama through `tool/obd_test_rig/chaos_proxy.py` |

**A skipped test and a passing test print the same summary and both exit 0.**
That is why the number is worth knowing: `~13` is the expected default and `~8`
means Ircama alone is running; other counts deserve inspection. CI does not
rely on reading the number — it parses each oracle's JSON report and fails the
job if a test was skipped rather than run. The chaos job also verifies the
exact commands that reached the proxy before each injected fault.

To run the first suite yourself:

```bash
python3 -m venv /tmp/elmvenv
# Two steps, not one. ELM327-emulator ships as an sdist whose build backend
# imports pkg_resources, which setuptools 82 removed, so a plain
# `pip install ELM327-emulator` fails with `No module named 'pkg_resources'`.
# Measured 2026-08-20: 80.10.2 has it, 81.0.0 still has it, 82.0.0 does not.
# It can also appear to work on a machine that already has the wheel cached —
# same day: succeeds from cache, fails under --no-cache-dir.
/tmp/elmvenv/bin/pip install setuptools==80.10.2 wheel==0.45.1
env -u GITHUB_RUN_NUMBER /tmp/elmvenv/bin/pip install \
  --no-build-isolation ELM327-emulator==3.0.5
/tmp/elmvenv/bin/pip check

# The fail-fast subshell cleans up immediately after the test, not when your
# terminal exits. The wrapper rejects a missing/shared PID directory, binds
# loopback only, and does not depend on an open stdin. Invoke Bash explicitly:
# a Markdown `bash` fence is syntax highlighting, not a shell selection.
/bin/bash <<'BASH'
(
  set -e
  ELM_PID_DIR="$(mktemp -d "${TMPDIR:-/tmp}/telltale-elm.XXXXXX")"
  readonly ELM_PID_DIR
  chmod 700 "$ELM_PID_DIR"
  ELM_PID=''

  cleanup_elm() {
    rc=$?
    trap - EXIT
    if [ -n "$ELM_PID" ] && jobs -pr | grep -Fxq -- "$ELM_PID"; then
      kill "$ELM_PID" 2>/dev/null || true
    fi
    if [ -n "$ELM_PID" ]; then
      wait "$ELM_PID" 2>/dev/null || true
    fi
    rm -rf -- "${ELM_PID_DIR:?}"
    exit "$rc"
  }
  trap cleanup_elm EXIT

  /tmp/elmvenv/bin/python tool/ble_test_rig/emulator_entrypoint.py \
    --pid-directory "$ELM_PID_DIR" \
    -n 35000 -s car -b "$ELM_PID_DIR/batch.out" \
    > "$ELM_PID_DIR/emulator.log" 2>&1 &
  ELM_PID=$!
  flutter test test/emulator_integration_test.dart \
    --dart-define=ELM_ORACLE_REQUIRED=true
)
BASH
```

The `ELM_ORACLE_REQUIRED` define turns a missing or unrecognised listener into
a test failure. Do not omit it when claiming oracle evidence; the default full
suite intentionally marks an unavailable external oracle as skipped.

Both suites listen on port 35000 and tell each other apart by the answer to
`AT@1`, so only one can run at a time.

The second suite's simulator lives on a branch of the private repository and is
not distributable from here. Its 7 tests will skip for you and run in CI on the
private side. If you are changing freeze-frame handling, say so in the pull
request and it will be run against that oracle before merge.

`tool/obd_test_rig/README.md` documents the no-fault fragmentation pass and the
three fresh-process fault runs (`close`, `no_prompt`, and `corrupt`). These use
the real `WifiTransport` socket and fail closed during initialization.

### Bluetooth LE, without an adapter

`tool/ble_test_rig/` advertises a real Nordic UART peripheral from a Mac and
puts the same third-party ELM327 emulator behind it, so a phone running the app
can be taken through a real GATT connect, discovery, subscribe and notification
stream with no hardware and no car. Its README explains the two macOS traps
that make it look broken when it is not — and the one that makes it look
working when it is not: a Mac cannot see its own peripheral, so scanning from
the same machine finds nothing and proves nothing.

The Android driver uses the isolated `com.cbstudio.telltale.rig` debug package,
marks stored evidence as simulated, and cannot approve a system permission
dialog. Follow the README's preinstall and `adb shell pm grant` steps on a fresh
phone. A passing run requires exactly one subscribed BLE central.

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

`docs/protocol-deviations.zh-TW.md` records where this app deliberately departs from the
specification it was derived from, and why. Three of those departures fix
commands that would break a connection to a real vehicle — one of them
silently, and only on vehicles that are not 11-bit CAN. Read it before changing
anything in the AT initialisation sequence.

## Before you open a pull request

- `flutter analyze` — no issues.
- `flutter test` — green, with the skip count where you expect it.
- If you touched anything under `lib/obd/`, run the Ircama oracle above.
- If you touched socket framing, timeouts, or initialization, also run the TCP
  chaos oracle described in `tool/obd_test_rig/README.md`.
- If you touched BLE transport code, run the bridge/probe unit tests; report the
  physical-phone GATT integration separately if no second device was available.
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
