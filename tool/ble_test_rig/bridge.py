"""A real BLE peripheral in front of an ELM327 this project did not write.

The app's BLE transport has 18 unit tests against a scripted fake platform, and
scanning has been exercised on real hardware. What has never run is the middle:
a real GATT connect, a real service discovery, a real CCCD subscribe, and real
notifications carrying an ELM327 conversation.

This closes that. bless advertises Nordic UART on this Mac's radio; every write
is forwarded to Ircama's ELM327-emulator over TCP, and every byte it answers is
sent back as a notification. Neither end of the protocol is mine.
"""
import asyncio
import socket
import sys
import traceback

from bless import (
    BlessServer,
    GATTCharacteristicProperties,
    GATTAttributePermissions,
)

SVC = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
RX = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"  # central writes here
TX = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"  # peripheral notifies here

OUT = "/tmp/ble_bridge.log"
ELM_HOST, ELM_PORT = "127.0.0.1", 35000


def log(msg):
    with open(OUT, "a") as f:
        f.write(msg + "\n")


class ElmLink:
    """One TCP connection to the emulator, opened lazily."""

    def __init__(self):
        self.sock = None

    def connect(self):
        self.sock = socket.create_connection((ELM_HOST, ELM_PORT), timeout=5)
        self.sock.settimeout(0.4)
        log("bridge: connected to the emulator")

    def exchange(self, data: bytes) -> bytes:
        if self.sock is None:
            self.connect()
        self.sock.sendall(data)
        # Read until the prompt, which is how a real ELM327 frames a reply.
        out = b""
        deadline = asyncio.get_event_loop().time() + 6.0
        while asyncio.get_event_loop().time() < deadline:
            try:
                chunk = self.sock.recv(4096)
            except socket.timeout:
                if out.endswith(b">"):
                    break
                continue
            if not chunk:
                break
            out += chunk
            if out.endswith(b">"):
                break
        return out


async def main():
    open(OUT, "w").close()
    log("main entered")
    link = ElmLink()
    server = BlessServer(name="TelltaleELM")

    await server.add_new_service(SVC)
    await server.add_new_characteristic(
        SVC,
        RX,
        GATTCharacteristicProperties.write
        | GATTCharacteristicProperties.write_without_response,
        None,
        GATTAttributePermissions.writeable,
    )
    # notify only, and no cached value: CoreBluetooth refuses a characteristic
    # that has both — "Characteristics with cached values must be read-only".
    await server.add_new_characteristic(
        SVC,
        TX,
        GATTCharacteristicProperties.notify,
        None,
        GATTAttributePermissions.readable,
    )

    def on_write(characteristic, value, **kwargs):
        try:
            data = bytes(value)
            log(f"<- {data!r}")
            reply = link.exchange(data)
            log(f"-> {reply!r}")
            char = server.get_characteristic(TX)
            # Notifications are bounded by the negotiated MTU; a real adapter
            # splits the same way, so the app has to reassemble either way.
            for i in range(0, len(reply), 20):
                char.value = reply[i : i + 20]
                server.update_value(SVC, TX)
        except Exception:
            log("EXC " + traceback.format_exc())

    server.write_request_func = on_write
    server.read_request_func = lambda characteristic, **kw: characteristic.value

    ok = await server.start()
    log(f"advertising TelltaleELM: {ok}")
    seconds = int(sys.argv[1]) if len(sys.argv) > 1 else 600
    await asyncio.sleep(seconds)
    await server.stop()
    log("stopped")


try:
    asyncio.run(main())
except Exception:
    log("FATAL " + traceback.format_exc())
