import asyncio, traceback
from bleak import BleakScanner, BleakClient

OUT = "/tmp/ble_client.log"
SVC = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
RX  = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
TX  = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

def log(m):
    with open(OUT, "a") as f: f.write(m + "\n")

async def main():
    log("scanning for TelltaleELM")
    dev = await BleakScanner.find_device_by_name("TelltaleELM", timeout=15.0)
    if dev is None:
        log("NOT FOUND — same-machine peripheral is invisible to this central")
        return
    log(f"found {dev.address} {dev.name!r}")
    got = []
    async with BleakClient(dev) as client:
        log(f"connected: {client.is_connected}")
        for s in client.services:
            log(f"  service {s.uuid}")
            for c in s.characteristics:
                log(f"    char {c.uuid} {c.properties}")
        await client.start_notify(TX, lambda _, data: got.append(bytes(data)))
        log("subscribed to notifications")
        for cmd in (b"ATZ\r", b"ATI\r", b"AT@1\r", b"0100\r"):
            got.clear()
            await client.write_gatt_char(RX, cmd, response=False)
            await asyncio.sleep(3.0)
            log(f"  {cmd!r} -> {b''.join(got)!r}")
        await client.stop_notify(TX)
    log("done")

open(OUT, "w").close()
try:
    asyncio.run(main())
except Exception:
    log("FATAL " + traceback.format_exc())
