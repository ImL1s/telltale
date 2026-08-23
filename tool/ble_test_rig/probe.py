#!/usr/bin/env python3
"""Same-Mac BLE negative control with a private, symlink-safe transcript."""

from __future__ import annotations

import asyncio
import os
from pathlib import Path
import traceback
from typing import TextIO

SVC = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
RX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
TX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
OUT = Path("/tmp/ble_client.log")


def open_private_log(path: Path = OUT) -> TextIO:
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        return os.fdopen(descriptor, "w", encoding="utf-8")
    except BaseException:
        os.close(descriptor)
        raise


def log(stream: TextIO, message: str) -> None:
    stream.write(message + "\n")
    stream.flush()


async def probe(stream: TextIO) -> None:
    # Keep the module importable without the host-only BLE dependencies so the
    # private-log boundary can be unit tested on every CI runner.
    from bleak import BleakClient, BleakScanner

    log(stream, "scanning for TelltaleELM")
    device = await BleakScanner.find_device_by_name("TelltaleELM", timeout=15.0)
    if device is None:
        log(stream, "NOT FOUND — same-machine peripheral is invisible to this central")
        return
    log(stream, f"found {device.address} {device.name!r}")
    received: list[bytes] = []
    async with BleakClient(device) as client:
        log(stream, f"connected: {client.is_connected}")
        for service in client.services:
            log(stream, f"  service {service.uuid}")
            for characteristic in service.characteristics:
                log(
                    stream,
                    f"    char {characteristic.uuid} {characteristic.properties}",
                )
        await client.start_notify(
            TX,
            lambda _, data: received.append(bytes(data)),
        )
        log(stream, "subscribed to notifications")
        for command in (b"ATZ\r", b"ATI\r", b"AT@1\r", b"0100\r"):
            received.clear()
            await client.write_gatt_char(RX, command, response=False)
            await asyncio.sleep(3.0)
            log(stream, f"  {command!r} -> {b''.join(received)!r}")
        await client.stop_notify(TX)
    log(stream, "done")


def main() -> None:
    os.umask(0o077)
    with open_private_log() as stream:
        try:
            asyncio.run(probe(stream))
        except Exception:
            log(stream, "FATAL " + traceback.format_exc())


if __name__ == "__main__":
    main()
OUT = Path("/tmp/ble_client.log")
