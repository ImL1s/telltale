# Implementation plan — ImL1s/telltale #9

**Issue:** [#9 [WS-01][P0][USABILITY-R2] 最大化可用性：資料狀態、功能可用性、操作風險分離與能力矩陣](https://github.com/ImL1s/telltale/issues/9)
**Intended PR:** `ImL1s/torque` `feat/usability-r2-policy`
**Depends on:** none
**Files:** `app/lib/diagnostics/availability.dart`, `app/docs/workshop/capabilities.json`, `app/docs/workshop/capabilities.schema.json`, `app/tool/workshop/validate_capabilities.py`, `app/test/diagnostics/availability_policy_test.dart`, `app/test/tool/test_workshop_capabilities.py`

## Six table rows

All six **covered** by the shared `AvailabilityPolicy` (this is the model every later issue must call; they must not invent a second `supported` bool).

## In-scope outcomes

Versioned capability matrix + runtime typed model:

- `availability`: usable / usableWithNotice / rawOnly / unavailable (+ reason, next step)
- `origin`: ecuReported / calculated / userEntered / demo
- `evidence`: fieldVerified / community / experimental / userSupplied / notTested / unknown
- `compatibility`: exact / candidate / userSelected / unknown / knownMismatch
- `quality`: valid / tentativeDecode / outOfReferenceRange / stale / invalid / partial
- `operationRisk`: display / boundedRead / clear / stateChange / program

Decisions:

1. No catalog / no VIN / unknown year → generic OBD `usableWithNotice`.
2. One PID/ECU failure → that item `partial`/`unavailable`; others unchanged.
3. Community/experimental bounded read → `usableWithNotice`, never a blanket ban.
4. User import → `origin=userEntered`, `evidence=userSupplied`.
5. Estimates → `origin=calculated`, disclose formula + inputs + assumptions; missing required input blanks **that** estimate only.
6. Finite out-of-range → keep value, `quality=outOfReferenceRange`.
7. Bad packet / non-finite → `rawOnly`/`invalid`, never a normal number.
8. Field verification only flips `evidence` to `fieldVerified` (已驗證 badge). It is not a prerequisite for shipping labelled read-only features.

## Explicit deferrals

Shop coverage counts, UDS/DoIP, field artifact collection, confidence percentages, invented SOH, filling missing inputs with silent defaults.

## Positive tests (`availability_policy_test.dart`)

- generic OBD with empty catalog, null VIN, unknown year is `usableWithNotice`.
- community + experimental bounded-read commands are `usableWithNotice`.
- user-supplied PID is usable and labelled 使用者提供.
- estimate with disclosed mass origin is shown as 估算, never 實測.
- finite 999 °C coolant is kept as 異常.
- research-only metadata with no commands is browsable and has no fake reading.

## Negative tests

- NaN / Infinity / wrong SID → not `usable`.
- known electrical/protocol mismatch stays `unavailable` for that item.
- `operationRisk` for Mode 04 / 2F / 2E / 31 is never derived from evidence level.
- capabilities.json with a forged `fieldVerified` and no artifact hash fails the Python validator.

## Verification

```bash
~/fvm/versions/3.47.0/bin/flutter test test/diagnostics/availability_policy_test.dart
python3 -m unittest discover -s app/test/tool -p '*workshop_capabilities*.py' -v
python3 app/tool/workshop/validate_capabilities.py app/docs/workshop/capabilities.json
```
