# Implementation plan — ImL1s/telltale #14

**Issue:** [#14 [WS-06][P0][USABILITY-R2] 風險分級操作政策：一般讀取盡量可用，寫入／致動保留安全閘](https://github.com/ImL1s/telltale/issues/14)
**Intended PR:** `ImL1s/torque` `feat/usability-r2-risk` (stacked on `feat/usability-r2-policy`)
**Depends on:** #9 (model). **Does not wait for** DiagnosticLink #13 — generic ELM bounded-read + existing Mode 04 latch is the in-scope floor.
**Files:** `app/lib/diagnostics/operation_risk.dart` (or the risk section of `availability.dart`), `app/test/diagnostics/operation_risk_test.dart`, existing `PollableServices` / `clearDtcs` / experimental probe consents.

## Six table rows

| Row | Coverage |
| --- | --- |
| generic OBD without identity | **covers** — bounded read is allowed |
| community/experimental read-only | **covers** — command risk, not evidence, decides polling vs one-shot |
| user import | **covers** — schema + allowlist; no script/write smuggling |
| partial ECU | **covers** — refuse only the forbidden request |
| estimates | **covers** as `display` / calculated, not a write |
| out-of-range finite | **covers** — range is quality, not a send block |
| 清碼 / 致動 / 刷寫 | **covers** the refuse path |

## In-scope outcomes

Keep availability, evidence, and operation risk as **separate** decisions.

- `display` / user import / estimates: allowed unverified.
- `boundedRead`: Modes 01/02/09/22 with a well-formed envelope. Missing VIN/year/catalog/field artifact is **not** a refusal.
- Mode 21 stays **one-shot** (already not in `PollableServices.allowed`) because the *command* is not a periodic gauge service, not because it is unverified.
- `clear` (Mode 04): existing snapshot + confirm + readback. Unverified data does not skip those gates.
- `stateChange` / `program` (2F/2E/31/11/27/28): still zero wire requests without a later recipe (#25/#26 deferred).

Low friction: no per-PID / per-sample confirm for bounded reads. Connection generation still invalidates live values and write consents.

## Explicit deferrals

#13 DiagnosticLink, #25/#26 actuation/flash recipes, J2534 broker, shop operator ACL.

## Positive tests

- Unverified / no VIN / user-selected candidate / schema-valid custom Mode 01/22: allowed, labelled.
- Reconnect does not re-prompt every PID.
- Partial module failure does not block other bounded reads.

## Negative tests

- `2F` / `2E` / `31` / `11` / `27` / `28` / Mode 04 without latch: **zero** forbidden requests (`safety_allowlist_test`, `clear_latch_test`, new risk tests).
- Command injection and malformed envelopes still refused.
- Expired / cross-connection experimental Mode 21 consent cannot send.
- Out-of-range finite value is **not** treated as a safety refuse.

## Verification

```bash
~/fvm/versions/3.47.0/bin/flutter test test/diagnostics/operation_risk_test.dart test/safety_allowlist_test.dart test/clear_latch_test.dart test/manual_command_test.dart
```
