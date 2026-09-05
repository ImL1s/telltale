# Implementation plan — ImL1s/telltale #21

**Issue:** [#21 [WS-13][P1][USABILITY-R2] OEM 只讀 profile：自動精確匹配＋手動候選／自訂，未驗證也可用](https://github.com/ImL1s/telltale/issues/21)
**Intended PR:** `ImL1s/torque` `feat/usability-r2-profiles` (stacked)
**Depends on:** #9, #14. **Does not wait for** #17 UDS or all transports.
**Files:** `app/lib/obd/pid/pid_csv.dart`, `app/lib/obd/pid/pid.dart` (provenance), connect/session generic-OBD path, `app/test/diagnostics/unverified_profile_test.dart`, `app/test/pid_csv_test.dart`, `app/test/vehicle_identity_session_test.dart`.

## Six table rows

| Row | Coverage |
| --- | --- |
| 找不到車型 / 無 VIN / 年式未知 | **covers** — generic OBD + manual picker + 補參數 |
| community/experimental | **defers executable OEM packs** to #22 for battery; generic custom PID path is in-scope |
| user import | **covers** |
| partial ECU | **covers** |
| estimates | **covers** via profile parameters remaining editable without VIN |
| outliers | **covers** for imported PIDs (presentation bounds, not a drop) |

## In-scope outcomes

- Missing VIN / catalog miss / unknown year never blocks Mode 01 polling. Session stays in 通用 OBD; user can pick a catalog candidate or type parameters.
- CSV/editor import of schema-valid bounded-read PIDs is allowed without a maintainer signature. Mark `evidence=userSupplied` / 使用者提供.
- Import still runs `PollableServices` + formula resource limits. Custom is not a bypass for 2F/2E/31.
- Unknown year does not auto-upgrade a candidate to `compatibility=exact`.

## Explicit deferrals

Toyota/Subaru field qualification, ODX as an OEM database, zip/XML attack surface beyond current CSV, UDS identifier sweep.

## Positive tests

- `readVin` returns null → polling of 010C still produces a reading.
- Catalog miss still allows `VehicleProfile` edits and derived 估算.
- User CSV row `0105` imports, polls, and exports as 使用者提供.
- Two catalog candidates stay `candidate` / `userSelected`, never silent `exact`.

## Negative tests

- CSV `2F011203` still refused (`pid_csv_test`).
- Malformed header / NaN bounds refused.
- Exact match cannot be claimed from unknown year.

## Verification

```bash
~/fvm/versions/3.47.0/bin/flutter test test/diagnostics/unverified_profile_test.dart test/pid_csv_test.dart test/vehicle_identity_session_test.dart test/us_vehicle_profile_application_test.dart
```
