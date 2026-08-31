# Powertrain battery TCP rig

This is a dependency-free, deterministic ELM327 TCP simulator for exercising
Telltale's standard CAN polling and the catalogued **MG ZS EV Australian 2021**
powertrain-battery profile.

It listens on localhost by default, logs every exact command as JSONL, preserves
ELM327 prompt framing, and returns headered Mode 22 responses only when the
caller selects request header `781`. Every catalogued MG DID responds from CAN
ID `789`. Unknown requests, requests on the wrong header, and diagnostic
session/write/security/reset services return `NO DATA`; they are never executed.

## Run

```bash
cd app/tool/powertrain_battery_rig
python3 simulator.py --log /tmp/telltale-powertrain-battery-rig.jsonl
```

The default endpoint is `127.0.0.1:35000`. Binding to a LAN interface for a
phone test is an explicit operator choice:

```bash
python3 simulator.py --host 0.0.0.0 --port 35000 --log /tmp/telltale-rig.jsonl
```

Stop with `Ctrl-C`. The log records readiness, connections, exact command text
and bytes, rendered responses, refusal reasons, disconnects, and shutdown.

## Verify

```bash
cd app/tool/powertrain_battery_rig
python3 -m unittest -v test_simulator.py
python3 -m py_compile simulator.py test_simulator.py
```

## Evidence boundary

The raw fixture values and identifiers are deterministic synthetic data shaped
to the formulas in Telltale's pinned MG catalog source. A passing host or phone
test proves TCP transport, ELM prompt/header parsing, source attribution, and
profile wiring. It does **not** prove that a physical adapter, BMS, vehicle
variant, year, market, scaling, current sign, or value is correct. Only a
read-only trace from the explicitly matched real vehicle can provide that
physical-vehicle evidence.

The rig never performs vehicle writes, clears DTCs, starts diagnostic sessions,
unlocks security access, resets ECUs, or brute-force scans identifiers.
