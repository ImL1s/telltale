# Workshop pilot vs software availability

USABILITY-R2 splits two exits:

- **A `core-obd-available`:** software tests pass and labels are honest. Missing field logs do not block generic OBD, community/experimental bounded reads, user imports, estimates, or partial exports.
- **B `field-qualified`:** the same software plus per-vehicle field artifact hashes. This is how a reading earns **已驗證**. Absence of B is not a failure of A.

Pilot shops, BOM, and radio soak remain optional evidence for B. They are not a gate for shipping labelled unverified read-only features.

Run:

```bash
python3 tool/workshop/run_release_gate.py \
  --profile core-obd-available \
  --evidence test/tool/fixtures/core_obd_available.json
```
