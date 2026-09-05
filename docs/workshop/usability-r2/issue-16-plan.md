# Implementation plan — ImL1s/telltale #16

**Issue:** [#16 [WS-08][P1][USABILITY-R2] 修前／修後報告：部分結果照用，逐項保留未驗證／估算／異常狀態](https://github.com/ImL1s/telltale/issues/16)
**Intended PR:** `ImL1s/torque` `feat/usability-r2-export` (stacked)
**Depends on:** #9. **Does not wait for** #12/#13/#15 as blockers for generic-OBD software export.
**Files:** `app/lib/telemetry/session/telemetry_export_codec.dart`, `app/lib/obd/session_evidence.dart`, `app/lib/obd/polling_engine.dart` (keep finite outliers), `app/lib/obd/telemetry.dart` (`Reading.quality`), `app/test/diagnostics/status_export_test.dart`, `app/test/telemetry_export_test.dart`.

## Six table rows

| Row | Coverage |
| --- | --- |
| generic OBD / no VIN | **covers** — scan/save/export still completes |
| community/experimental | **covers** — marks survive export |
| user import | **covers** — 使用者提供 in CSV/JSON |
| partial ECU | **covers** — failed item recorded; others exported |
| estimates | **covers** — 估算 + formula/assumptions in printable/export metadata |
| out-of-range finite | **covers** — value kept + 異常; mixed report not upgraded to 已驗證 |

## In-scope outcomes

- CSV gains explicit status columns (`availability`, `origin`, `evidence`, `quality`, `operation_risk`) filled from the **same** `AvailabilityPolicy` as the live UI. JSON export carries the same keys per event/signal.
- Canonical `.ndjson` stays schemaVersion 1. Optional `quality` on value events is decoded when present and defaults to `valid` when absent so old recordings replay.
- Catalog PIDs no longer drop finite out-of-range values as `formulaError`; they are stored as values with `outOfReferenceRange`.
- One PID timeout/fault becomes a status event for **that** id; other values remain.
- Mixed-evidence never sets `evidence=fieldVerified` on the whole artifact.

## Explicit deferrals

Full shop before/after visit workflow, Mode 06 unknown scaling UI, integration_test workshop journey, legal signatures.

## Positive tests

- Mixed snapshot (unverified community PID, user custom PID, estimate metadata, outlier, one `noAnswer`) round-trips through the **shipped** exporter.
- Reopen/replay still shows those marks.
- Partial failure does not zero sibling PIDs in the written CSV.

## Negative tests

- Non-finite / bad packet is a status/error row, not a numeric success.
- Export of mixed evidence does not contain `fieldVerified` / 已驗證 as a document-level upgrade.
- Existing privacy exclusions (VIN/GPS/account) remain.

## Verification

```bash
~/fvm/versions/3.47.0/bin/flutter test test/diagnostics/status_export_test.dart test/telemetry_export_test.dart test/transcript_test.dart
```
