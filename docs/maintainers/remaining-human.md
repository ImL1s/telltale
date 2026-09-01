# Remaining human-only steps (2026-09-01)

Machine-checkable leftovers from the wrap-up goal. None of these
were claimed done from this session.

Attached hardware at check time:

- Phone: Galaxy S24 Ultra `R5CX10VFFBA` (`SM-S9280`)
- Wear: Android emulator `emulator-5554` (`sdk_gwear_arm64`) only
- No physical Wear OS watch, no BLE adapter on a watch, no Play Console session

## Wear BLE Gate 0

`docs/wearos.md` still requires a real watch plus a BLE ELM327 before
claiming Wear BLE works. The emulator has no BLE. Demo-on-emulator is
already recorded there; this check did not add BLE evidence.

Until a maintainer:

1. Builds `flutter build apk --debug --flavor wear`
2. Installs it on a physical Wear OS watch
3. Scans and connects a known BLE adapter (see `docs/hardware-compatibility.md`)
4. Confirms live gauges (not Demo)

Gate 0 stays **unverified**. The Wear battery page also stays unreachable
on a real watch until a provisioning / Data Layer path exists.

## Google Play / store

Preflight that does **not** need a Console click (this tree, after the
Windows/Linux merge):

- `pubspec.yaml` `version: 1.0.7+8` (versionCode 8; 1 and 2 are already used)
- `applicationId` = `com.cbstudio.telltale`
- BLE dependency is `universal_ble`; `flutter_blue_plus` is comment-only
- Privacy policy URL in `docs/maintainers/release.md` is
  `https://iml1s.github.io/telltale/privacy.html` and that page loads
  (last updated 2026-08-29)

Still human-only, per `docs/maintainers/release.md` §5–5.5:

1. Re-read Play Console for the highest consumed versionCode (do not guess)
2. `flutter build appbundle --release --flavor field` with the real keystore
3. Replace the **effective draft** bundle; do not submit an older uploaded AAB
4. Physical-device walkthrough of every user-facing changelog flow on a
   **release** APK, both themes
5. At least one install from the internal testing track (Play App Signing
   splits), which requires uninstalling a locally signed build
6. Wear OS Play track (API 35+, 384×384 screenshots, Wear signing) is
   separate and still unshipped

Do not treat green `flutter test` / `flutter analyze` as Play-ready.

## GitHub Actions billing (torque PR #3 merge blocker)

Private-repo CI for `feat/multiplatform-windows-linux` at `974a0ce`
(run https://github.com/ImL1s/torque/actions/runs/33507389391 )
did **not** execute any job steps. Every check-run annotation is:

> The job was not started because recent account payments have failed
> or your spending limit needs to be increased.

This is not a Flutter failure. Local evidence on that commit:
`flutter analyze` clean, `flutter test` `+1523 ~15`. Do not merge
https://github.com/ImL1s/torque/pull/3 while those checks are red,
and do not treat a billing skip as a green Windows/Linux CI run.

Until a maintainer restores Actions billing / spending limit on the
GitHub account that owns `ImL1s/torque`, PR #3 cannot get a real CI
signal. Public `telltale` Actions may still run (public minutes).

## Dirty main worktree

`/Users/iml1s/Documents/mine/torque` stays dirty at `2503abb` on purpose.
Do not stash, checkout, or commit it. Telemetry on
`feat/multiplatform-windows-linux` is the shipping path.
