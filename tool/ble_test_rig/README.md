# A real BLE peripheral, without an adapter

`ble_transport.dart` has 18 unit tests against a scripted fake platform, and
scanning has been exercised against real hardware. Between those two lies the
part neither can reach: a real GATT connect, a real service discovery, a real
CCCD subscribe, and real notifications carrying an ELM327 conversation. That is
also the part that changed when the BLE package was replaced.

This rig produces it on a Mac. It advertises Nordic UART on the machine's own
radio and forwards every write to [Ircama's
ELM327-emulator](https://github.com/Ircama/ELM327-emulator) over TCP, sending
each reply back as notifications. Neither end of that is this project's code:
the GATT stack is Apple's and the protocol is somebody else's reading of the
same standard — which is the whole point, because a test of my parser against
my simulator agrees with itself.

```bash
./run.sh            # advertise as "TelltaleELM" for 15 minutes
./run.sh --probe    # connect from an independent BLE client, not the app
./run.sh --stop
```

Traffic appears in `/tmp/ble_bridge.log`, one line per direction.

## You need a second device

**A Mac's own central cannot see its own peripheral.** CoreBluetooth does not
loop back, so running the macOS build of this app on the same machine will scan
and find nothing — and that result says nothing about either side. Measured
2026-08-20: an independent `bleak` client on the same Mac reported
`NOT FOUND` for a peripheral that was demonstrably advertising.

Use a phone with the app installed as the central. Connect → Bluetooth LE →
scan → `TelltaleELM`.

## Two things that will waste an hour if you meet them cold

**CoreBluetooth aborts rather than fails.** A process whose `Info.plist` has no
`NSBluetoothAlwaysUsageDescription` dies with `SIGABRT`, no traceback, no
message on stderr — and a bare `python3` has no `Info.plist` at all. The reason
is only visible in `~/Library/Logs/DiagnosticReports/*.ips`, under
`"namespace":"TCC"`. That is why `run.sh` builds a throwaway `.app` around the
interpreter.

**A bundle is not enough on its own.** TCC attributes a request to the
*responsible* process, which for a command run from a shell is the terminal,
not the bundle. The interpreter has to be launched through LaunchServices —
`open -n -a` — so the bundle becomes responsible for itself. `-n` matters too:
without it, `open` hands the arguments to an already-running instance and the
new script never starts, leaving an empty log that reads exactly like a crash.

## What it does and does not establish

It exercises the real platform channel: connect, discover, subscribe, write,
notify, and the app's reassembly of notifications that arrive in MTU-sized
pieces. It does not exercise a real adapter — clone timing, firmware quirks,
`SEARCHING...` on a physical bus, a link that drops when the engine cranks.
Only a real ELM327 in a real car does that, and nothing here substitutes for it.
