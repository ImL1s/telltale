# OBD TCP Chaos Test Rig

This dependency-free Python proxy sits between Telltale's Wi-Fi transport and a
prompt-terminated ELM327 emulator. It deterministically fragments replies and
can inject one-shot connection, missing-prompt, or corruption faults by global
command number. The counter continues across reconnects, so a fault is not
silently replayed after the app reconnects. The configured chunk-size cycle
restarts at the beginning of every emulator reply.

## Start

Run all commands from the Flutter app root: use `cd app` first in the private
`torque` checkout; the public `telltale` repository root is already the app root.

Start Ircama (or another ELM327-compatible TCP emulator) on port `35000`, then:

```bash
python3 tool/obd_test_rig/chaos_proxy.py \
  --listen-host 127.0.0.1 --listen-port 35001 \
  --upstream-host 127.0.0.1 --upstream-port 35000 \
  --chunk-sizes 1,2,5,3 --delay-ms 25 \
  --close-on-command 18 --log chaos.jsonl
```

`127.0.0.1` is the safe default bind. Use `0.0.0.0` only on a trusted test LAN
when a physical phone must connect. Point the app at the Mac's LAN IP and port
`35001`.

Choose at most one fault option for the entire proxy run:

```text
--close-on-command N       close before forwarding command N
--no-prompt-on-command N   forward reply N without its final `>`
--corrupt-on-command N     flip one deterministic payload bit in reply N
```

The proxy permits one active driver connection. A new socket gets a 100 ms
handover grace so the previous app test can finish closing; if the old driver
is still active, the newcomer is closed and logged as `client_rejected`. A
rejected client cannot advance the global command counter or consume the
configured one-shot fault.

## Health and Stop

Keep the proxy in the foreground; `Ctrl-C` performs its verified socket and log
cleanup without trusting a reusable PID. The first JSONL record has
`"event":"ready"`. From a second terminal, confirm the listener with:

```bash
nc -z 127.0.0.1 35001
tail -n 5 chaos.jsonl
```

Drive the isolated Android rig build with:

```bash
~/fvm/versions/3.47.0/bin/flutter test \
  integration_test/wifi_rig_test.dart -d <device-id> \
  --flavor rig \
  --dart-define=TELLTALE_TEST_RIG=true \
  --dart-define=WIFI_RIG_HOST=<host-ip> \
  --dart-define=WIFI_RIG_PORT=35001
```

Each JSONL record includes `run_id`, increasing `seq`, monotonic time,
`direction`, `data_hex`, and `fault`, plus connection/command/chunk metadata.
The file contains raw OBD traffic and may include a VIN or endpoint details. It
is created owner-readable only; review it before sharing and delete it when it
is no longer needed.

## Verify

```bash
python3 -m py_compile tool/obd_test_rig/chaos_proxy.py \
  tool/obd_test_rig/test_chaos_proxy.py
python3 -m unittest discover -s tool/obd_test_rig \
  -p 'test_chaos_proxy.py' -v
```

With Ircama already listening on loopback port `35000`, start a proxy **without
a fault** on port `35001` in one terminal:

```bash
python3 tool/obd_test_rig/chaos_proxy.py \
  --listen-host 127.0.0.1 --listen-port 35001 \
  --upstream-host 127.0.0.1 --upstream-port 35000 \
  --chunk-sizes 1,2,5,3 --delay-ms 1 --log /tmp/chaos-nominal.jsonl
```

In a second terminal, run all five independent emulator tests through its
fragmentation path in required-oracle mode. Stop the foreground proxy with
`Ctrl-C` afterward:

```bash
~/fvm/versions/3.47.0/bin/flutter test test/emulator_integration_test.dart \
  --dart-define=ELM_ORACLE_PORT=35001 \
  --dart-define=ELM_ORACLE_REQUIRED=true
```

`ELM_ORACLE_REQUIRED=true` is mandatory when claiming fragmentation evidence.
Without it, a missing proxy or an absent/unrecognised Ircama upstream marks all
five tests skipped and `flutter test` still exits zero; that is not a nominal
pass.

For each failure case, stop the proxy and start a fresh process with exactly
one of the following controls, then run the matching oracle value:

| `CHAOS_FAULT` | proxy control |
|---|---|
| `close` | `--close-on-command 2` |
| `no_prompt` | `--no-prompt-on-command 2` |
| `corrupt` | `--corrupt-on-command 8` |

```bash
~/fvm/versions/3.47.0/bin/flutter test test/chaos_oracle_test.dart \
  --dart-define=CHAOS_ORACLE=true \
  --dart-define=CHAOS_ORACLE_PORT=35001 \
  --dart-define=CHAOS_FAULT=close
```

Do not reuse one proxy between cases: its command counter intentionally spans
TCP reconnects. CI also checks the exact command prefix and rejects a skipped
oracle, so a green process that never injected its fault cannot pass.

## Scope

This rig exercises TCP framing, fragmentation, delay, timeout, corruption,
disconnect, and reconnect behavior without a car. It does **not** reproduce
Bluetooth/GATT behavior, vehicle bus timing/arbitration, adapter firmware bugs,
electrical faults, ignition transitions, or prove compatibility with a physical
ELM327 clone and ECU.
