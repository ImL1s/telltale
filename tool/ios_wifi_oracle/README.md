# iOS Simulator Wi‑Fi oracle

Proves the **field** iOS identity can handshake with Ircama ELM327-emulator
over plain TCP using the Mac's **LAN** address (`ipconfig getifaddr en0`), then
reach live PID polling.

This is deliberately not `127.0.0.1`: that path is covered by
`tool/desktop_wifi_oracle/run.sh` / `emulator_integration_test.dart` on the
host Dart VM. From the Simulator we exercise the same address family a phone
would use against a Wi‑Fi OBD adapter on the LAN.

## Run

```bash
# Boot an iPhone Simulator first (Xcode → Open Developer Tool → Simulator).
cd app
./tool/ios_wifi_oracle/run.sh
```

Optional overrides:

| Variable | Meaning |
|---|---|
| `WIFI_ORACLE_HOST` | Explicit LAN IPv4 (skips `en0` lookup) |
| `WIFI_ORACLE_IFACE` | Interface for `ipconfig getifaddr` (default `en0`) |
| `ELM_ORACLE_PORT` | TCP port (default `35000`) |
| `IOS_SIM_DEVICE` | Simulator UDID |
| `ELM_BIND_INTERFACE` | Emulator bind (default `0.0.0.0` for this harness) |
| `FLUTTER` | Flutter binary |

## Networking notes

- Ircama is single-client. The harness opens a short host preflight connect,
  then closes it before the Simulator connects.
- `tool/ble_test_rig/emulator_entrypoint.py` defaults to loopback; this script
  sets `ELM_BIND_INTERFACE=0.0.0.0` so `$WIFI_ORACLE_HOST` reaches the process.
  Do not leave a LAN-bound single-session emulator running unattended.
- If `en0` has no IPv4 (Wi‑Fi off / Ethernet-only), set `WIFI_ORACLE_HOST` or
  `WIFI_ORACLE_IFACE` explicitly.
- Personal-firewall / Local Network prompts on newer macOS can block the
  Simulator → host path; allow Terminal/Flutter if the preflight passes but
  the Simulator connect times out.

## Evidence

On success the integration test prints `IOS_FIELD_WIFI phase=pass` and the
script exits 0. Failure is a hard fail when `WIFI_ORACLE_REQUIRED=true`
(always set by `run.sh`).
