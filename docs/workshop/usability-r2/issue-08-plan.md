# Implementation plan — ImL1s/telltale #8

**Issue:** [#8 [WS-00][EPIC][USABILITY-R2] 車行工作站：最大化可用性、資料狀態透明、風險分級與代理計畫](https://github.com/ImL1s/telltale/issues/8)
**Intended PR:** `ImL1s/torque` `feat/usability-r2-policy` (epic index + shared policy; stacked follow-on PRs named below)
**Base:** current `origin/master` (do not mix the dirty local telemetry worktree)
**Policy:** USABILITY-R2 — 未驗證 ≠ 不可用. Evidence is a label, not a read-only ban.

## Six table rows

| Row | This epic |
| --- | --- |
| 找不到車型 / 無 VIN / 年式未知 → 通用 OBD | **covers** via #9/#21; this PR ships the shared decision |
| 社群 / 實驗 / 無本專案實車驗證 → 只讀可用並標示 | **covers** via #22; this PR ships the shared decision |
| 使用者 PID/設定可匯入，標 使用者提供 | **covers** via #21 |
| 部分參數/電腦失敗只影響該項 | **covers** via #16 |
| 馬力/油耗允許估算並揭露公式與假設 | **covers** via #9/#35 |
| 超出參考範圍的 finite 值保留並標 異常 | **covers** via #9/#16/#35 |

## In-scope outcomes

- One typed model (`availability` / `origin` / `evidence` / `compatibility` / `quality` / `operationRisk`) used by UI, recorder, and exporters.
- Complete implementation plans for #9, #14, #16, #21, #22, #35, #37 (this file is the epic index).
- Tests in **both** directions: 該能用的沒有被錯誤阻擋 **and** 該阻擋的有阻擋.

## Explicit deferrals

UDS / DoIP / J2534 / SocketCAN (#17–#20), motorcycle/heavy (#23–#24), shop ERP (#30–#34, #36), field bench/BOM (#27–#28), Play/production publish, `examples/` parity, force-push of `ImL1s/telltale`.

## Positive tests

- Missing catalog / VIN / year still starts generic OBD polling.
- Community/experimental bounded-read profiles are usable with 未驗證 labels.
- User CSV import is usable and labelled 使用者提供.
- One PID/ECU fault does not zero or block the rest.
- Estimates render as 估算 with formula + assumption disclosure.

## Negative tests

- Bad packet / NaN / Infinity / wrong responder never becomes a normal number.
- 清碼 / 致動 / 刷寫 without preconditions send zero forbidden requests.
- Mixed-evidence export is not upgraded to 已驗證.

## Verification

```bash
cd app
~/fvm/versions/3.47.0/bin/flutter analyze
~/fvm/versions/3.47.0/bin/flutter test test/diagnostics test/workshop test/derived_strip_test.dart test/pid_csv_test.dart test/safety_allowlist_test.dart test/telemetry_export_test.dart
python3 -m unittest discover -s test/tool -p '*workshop*.py' -v
```
