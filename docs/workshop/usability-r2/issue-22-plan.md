# Implementation plan — ImL1s/telltale #22

**Issue:** [#22 [WS-14][P1][USABILITY-R2] EV／油電 BMS：社群與實驗讀取可用，狀態標籤與估算透明](https://github.com/ImL1s/telltale/issues/22)
**Intended PR:** `ImL1s/torque` `feat/usability-r2-battery` (stacked)
**Depends on:** #9, #14. Integrates with #21 for user-supplied PIDs.
**Files:** `app/lib/obd/powertrain_battery/profile_catalog_validator.dart` (`canInstall`), installer, catalog UI, `app/test/powertrain_battery_catalog_test.dart`, `app/test/diagnostics/battery_workshop_test.dart`, experimental access tests (update product-policy cases only).

## Six table rows

| Row | Coverage |
| --- | --- |
| no VIN / unknown year | **covers** — candidate / generic OBD, not a full lock |
| community / experimental | **covers** |
| user import | **covers** via #21; battery catalog still refuses unsigned zip traversal |
| partial cell/module | **covers** — one signal fault stays local |
| battery estimates | **covers** — calculated SOC/SOH never labelled OEM-reported |
| outliers | **covers** — finite out of catalog range kept as 異常 |

## In-scope outcomes

Replace “experimental cannot install / cannot record / cannot sit on a gauge / re-confirm every command”.

New split:

- **Command risk** decides polling vs one-shot.
  - Mode 22 experimental with a valid envelope (e.g. `toyota-etnga-bev-2022-2024`) **may install**, poll, record, export, labelled 實驗 / 未驗證 / 社群解碼 as appropriate.
  - Mode 21 experimental (e.g. Lexus RX450hL) stays **one-shot probe** because `PollableServices` does not allow 21 as a gauge service.
- **researchOnly** with empty `commands` stays metadata-only: browsable, no fake reading.
- First enable may confirm once per profile content version; badge remains. Not every PID / sample.
- Charging control / HV contactor / writes stay behind #14/#25/#26.

`canInstall` becomes: issues empty **and** commands non-empty **and** (ready | community | (experimental **and** every command is `PollableServices.isPollable`)).

## Explicit deferrals

Requiring all 12 community vehicles to have this project's field logs; invented SOH; opening HV contactors.

## Positive tests

- Mode 22 experimental profile: `canInstall==true`, installer returns PIDs, status labelled unverified, CSV export keeps the label.
- researchOnly empty commands: `canInstall==false`, UI still shows the row, no gauge value.
- Missing VIN: generic OBD still reads 010C; battery candidate can be selected manually.
- Finite SOC 140% (if a formula produces it) is shown as 異常, not dropped.

## Negative tests

- Mode 21 experimental still `canInstall==false` and still cannot be scheduled by `PollableServices`.
- Cross-ECU / wrong responder / bad length still fail closed (existing wire contract tests).
- Write/actuate services still refused.
- OEM-reported SOH vs calculated estimate stay distinct origins.

## Verification

```bash
~/fvm/versions/3.47.0/bin/flutter test test/diagnostics/battery_workshop_test.dart test/powertrain_battery_catalog_test.dart test/powertrain_battery_experimental_access_test.dart test/powertrain_battery_profile_test.dart
```
