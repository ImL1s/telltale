# Implementation plan — ImL1s/telltale #35

**Issue:** [#35 [WS-27][P1][USABILITY-R2] UI/UX：先能用、逐數值揭露狀態、局部降級與完整車行流程](https://github.com/ImL1s/telltale/issues/35)
**Intended PR:** `ImL1s/torque` `feat/usability-r2-ui` (stacked)
**Depends on:** #9. **Does not wait for** shop #30–#33.
**Files:** `app/lib/ui/widgets/status/datum_status_badge.dart`, `app/lib/ui/screens/dashboard/dashboard_screen.dart` (`_DerivedStrip`, `_GaugeTile`), settings copy, `app/test/workshop/ui/datum_status_badge_test.dart`, `app/test/derived_strip_test.dart`.

## Six table rows

All six **covered** on the live dashboard / settings / (generic) history surfaces. Full shop journey **deferred**.

## In-scope outcomes

- Remove the derived-strip veto `if (!profile.isConfirmed) hide 馬力`. Estimates show as **估算**, with mass/VE/aero origin (手動輸入 vs 通用預設 vs 官方型錄) and a way to inspect formula/assumptions.
- Gauge tiles show a short badge (未驗證 / 使用者提供 / 估算 / 異常 / 已驗證 / 剛更新 / stale) from `AvailabilityPolicy`, not a warning wall.
- Finite out-of-range: keep the numeric readout; needle may clamp to the dial; footnote 異常.
- One ECU/PID fault: that tile shows its reason; siblings keep values.
- No master “ignore all warnings”. Clear/actuate still uses the existing dedicated confirmations.
- Ordinary reads do not re-confirm every parameter.

Illustrative copy (not a required string):

> 電池 SOC：67% · 社群解碼 · 本車未驗證 · 剛更新
> 馬力：145 hp · 估算 · 車重為手動輸入

## Explicit deferrals

`integration_test/workshop_journey_test.dart` shop quote/parts flow, 200% a11y golden suite expansion beyond existing dashboard tests.

## Positive tests

- Unconfirmed profile + rpm/speed/accel present → 引擎馬力 visible, labelled 估算, not 實測.
- Confirmed path still works (mirror so the gate is not a permanent hide).
- Custom PID tile shows 使用者提供.
- Out-of-range finite reading still shows the number plus 異常.
- 20 gauge updates do not spawn confirm dialogs.

## Negative tests

- Missing accel still hides horsepower (`derived_strip_test` keep that group).
- Unsupported PID still says 此車輛不支援 for **that** tile only.
- Clear-codes button still requires the existing latch (DTC screen tests).

## Verification

```bash
~/fvm/versions/3.47.0/bin/flutter test test/workshop/ui/datum_status_badge_test.dart test/derived_strip_test.dart test/derived_provenance_test.dart test/vehicle_profile_provenance_ui_test.dart test/dtc_screen_button_test.dart
```
