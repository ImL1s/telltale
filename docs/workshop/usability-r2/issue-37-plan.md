# Implementation plan — ImL1s/telltale #37

**Issue:** [#37 [WS-29][P1][USABILITY-R2] 可用性發版與實測標章分離：未驗證只讀可發布，風險操作另驗收](https://github.com/ImL1s/telltale/issues/37)
**Intended PR:** `ImL1s/torque` `feat/usability-r2-release` (stacked)
**Depends on:** #9. Software gate does **not** wait for #11/#12 field oracles.
**Files:** `app/tool/workshop/release_profiles.json`, `app/tool/workshop/run_release_gate.py`, `app/docs/verification/workshop-pilot.md`, `app/test/tool/test_workshop_release.py`.

## Six table rows

All six **covered** as release-gate predicates (A = available software, B = field-qualified badge). Shop-connected / OEM-program profiles **deferred** as `not-in-this-goal`.

## In-scope outcomes

Two exits:

- **A `core-obd-available`:** software tests pass, labels correct, no field artifact required. Unknown vehicle / community / experimental bounded-read / partial ECU still **pass A**.
- **B `field-qualified`:** same software plus per-vehicle field artifact hashes. Missing field **fails B** and must not be rewritten as pass A failure.

Release profiles in JSON: `core-obd-available`, `field-qualified`. Others (`shop-mvp-available`, `oem-program`, …) are listed as deferred with `availability=unavailable` reason `not-implemented`.

README/capability matrix counts **usable** vs **field-verified** separately. Catalog row counts are not coverage.

## Explicit deferrals

Pilot shop, Play upload, Windows/Linux field soak, SBOM/signing beyond current CI.

## Positive tests

- Manifest with passing software, zero field artifacts → A pass, B fail.
- Community/experimental/partial flags present → A still pass if labels exist.

## Negative tests

- Requesting B with empty artifacts → nonzero exit.
- Simulation labelled as field → reject.
- Software skip/fail → A fail (no continue-on-error).
- Unknown transaction / write without recipe cannot be marked success.

## Verification

```bash
python3 -m unittest discover -s app/test/tool -p '*workshop_release*.py' -v
python3 app/tool/workshop/run_release_gate.py --profile core-obd-available --evidence app/test/tool/fixtures/core_obd_available.json
python3 app/tool/workshop/run_release_gate.py --profile field-qualified --evidence app/test/tool/fixtures/core_obd_available.json ; test $? -ne 0
```
