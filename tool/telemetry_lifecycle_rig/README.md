# Telemetry Android lifecycle rig

Runs only against the isolated Android rig identity. The wrapper waits for a
durably accepted Demo value, sends an actual Android Home key event, then uses
`am force-stop` during a separate recording and verifies recovery in a fresh
test process.

```bash
cd app
tool/telemetry_lifecycle_rig/run.sh <adb-serial>
```

The killed seed is required to exit non-zero. Its failure is accepted only
after the readiness marker captures a canonical session ID and the exact
durable value/status/gap counts. The fresh-root target must recover that same
session and counts, append exactly one `recoveredAfterInterruption` footer,
show the retained outcome on Connect, and open the matching row through the
root History UI. Home and recovery must independently exit green; the Python
verifier fails closed on marker order, identity/count drift, missing terminal
reason, or missing UI proof. Evidence is written to
`.omx/logs/telemetry-lifecycle-rig-*` unless overridden with
`TELEMETRY_RIG_EVIDENCE_DIR`.

This is physical-phone Android lifecycle/storage evidence using Demo data. It
does not exercise a socket, Bluetooth radio, adapter, ECU, or vehicle.
