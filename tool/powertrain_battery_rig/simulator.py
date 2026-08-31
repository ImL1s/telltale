#!/usr/bin/env python3
"""Deterministic, read-only ELM327 TCP rig for the MG ZS EV profile."""

from __future__ import annotations

import argparse
import asyncio
from dataclasses import dataclass
import json
import os
import re
import sys
import time
from typing import TextIO


_HEX = re.compile(r"^[0-9A-F]+$")
_UNSAFE_SERVICES = frozenset({"04", "10", "11", "14", "27", "2E", "31", "3B", "85"})

# Complete positive Mode 22 payloads: response service, DID, then deterministic
# raw bytes chosen to produce plausible values with the pinned catalog formulas.
MG_MODE22_RESPONSES: dict[str, bytes] = {
    "22B041": bytes.fromhex("62 B0 41 05 A0"),  # DC bus: 360.0 V
    "22B042": bytes.fromhex("62 B0 42 05 A4"),  # pack: 361.0 V
    "22B043": bytes.fromhex("62 B0 43 9D D0"),  # pack current: +10.0 A
    "22B045": bytes.fromhex("62 B0 45 00 64"),  # resistance: 50.0 Ohm
    "22B046": bytes.fromhex("62 B0 46 01 F4"),  # raw SOC: 50.0 %
    "22B056": bytes.fromhex("62 B0 56 82"),     # HV battery: 25.0 C
    "22B05C": bytes.fromhex("62 B0 5C 84"),     # coolant: 26.0 C
    "22B061": bytes.fromhex("62 B0 61 26 7A"),  # SOH: 98.5 %
    "22B058": bytes.fromhex("62 B0 58 10 36 0C"),  # max: 4.150 V, cell 12
    "22B059": bytes.fromhex("62 B0 59 0F F0 27"),  # min: 4.080 V, cell 39
    "22B0CE": bytes.fromhex("62 B0 CE 04 D2"),  # range: 123.4 km
}

# Safe, ordinary Mode 01 values. The rig also assembles compact multi-PID
# requests exactly as the app's CAN scheduler emits them.
MODE01_DATA: dict[str, bytes] = {
    "01": bytes.fromhex("00 07 65 04"),
    "04": bytes.fromhex("40"),
    "05": bytes.fromhex("69"),
    "06": bytes.fromhex("80"),
    "07": bytes.fromhex("80"),
    "0A": bytes.fromhex("40"),
    "0B": bytes.fromhex("64"),
    "0C": bytes.fromhex("1A F8"),
    "0D": bytes.fromhex("3C"),
    "0E": bytes.fromhex("80"),
    "0F": bytes.fromhex("50"),
    "10": bytes.fromhex("01 90"),
    "11": bytes.fromhex("33"),
    "1F": bytes.fromhex("0E 10"),
    "21": bytes.fromhex("00 00"),
    "2C": bytes.fromhex("64"),
    "2F": bytes.fromhex("BF"),
    "33": bytes.fromhex("64"),
    "42": bytes.fromhex("36 98"),
    "43": bytes.fromhex("00 64"),
    "45": bytes.fromhex("00"),
    "46": bytes.fromhex("50"),
    "5C": bytes.fromhex("50"),
    "5E": bytes.fromhex("00 7B"),
}

SUPPORT_MASKS: dict[str, bytes] = {
    "00": bytes.fromhex("BE 3F A8 13"),
    "20": bytes.fromhex("80 1F A0 15"),
    "40": bytes.fromhex("4C 00 00 11"),
    "60": bytes.fromhex("00 00 00 00"),
}


@dataclass(frozen=True)
class Config:
    host: str = "127.0.0.1"
    port: int = 35000
    log_path: str = "-"

    def __post_init__(self) -> None:
        # Port zero is intentionally available to in-process tests only.
        if not 0 <= self.port <= 65535:
            raise ValueError("port must be in 0..65535")
        if not self.host.strip():
            raise ValueError("host must not be empty")


class JsonlLogger:
    """Flushes each exact command and lifecycle transition immediately."""

    def __init__(self, path: str) -> None:
        self._owned = path != "-"
        self._sequence = 0
        if self._owned:
            flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
            flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
            descriptor = os.open(path, flags, 0o600)
            try:
                os.fchmod(descriptor, 0o600)
                self._stream: TextIO = os.fdopen(descriptor, "w", encoding="utf-8")
            except BaseException:
                os.close(descriptor)
                raise
        else:
            self._stream = sys.stdout

    def emit(self, event: str, **fields: object) -> None:
        self._sequence += 1
        record = {
            "sequence": self._sequence,
            "monotonic": time.monotonic(),
            "event": event,
            **fields,
        }
        self._stream.write(json.dumps(record, separators=(",", ":")) + "\n")
        self._stream.flush()

    def close(self) -> None:
        if self._owned:
            self._stream.close()


class ElmSession:
    """State which a real ELM327 resets for each adapter connection."""

    def __init__(self) -> None:
        self.echo = True
        self.spaces = True
        self.headers = False
        self.protocol_search_pending = True
        self.header = "7DF"

    def respond(self, exact_command: str) -> tuple[str, str | None]:
        command = "".join(exact_command.upper().split())
        echoed = f"{exact_command}\r" if self.echo else ""

        if command == "ATZ":
            self.__init__()
            return echoed + "ELM327 v2.1\r\r>", None
        if command == "ATE0":
            self.echo = False
            return echoed + "OK\r>", None
        if command == "ATE1":
            self.echo = True
            return echoed + "OK\r>", None
        if command in {"ATL0", "ATL1", "ATM0", "ATM1", "ATAT0", "ATAT1", "ATAT2"}:
            return echoed + "OK\r>", None
        if command.startswith("ATST") and len(command) == 6 and _HEX.fullmatch(command[4:]):
            return echoed + "OK\r>", None
        if command == "ATS0":
            self.spaces = False
            return echoed + "OK\r>", None
        if command == "ATS1":
            self.spaces = True
            return echoed + "OK\r>", None
        if command == "ATH0":
            self.headers = False
            return echoed + "OK\r>", None
        if command == "ATH1":
            self.headers = True
            return echoed + "OK\r>", None
        if command == "ATSP0":
            self.protocol_search_pending = True
            self.header = "7DF"
            return echoed + "OK\r>", None
        if command == "ATSP6":
            self.protocol_search_pending = False
            self.header = "7DF"
            return echoed + "OK\r>", None
        if command.startswith("ATSH"):
            header = command[4:]
            if len(header) != 3 or _HEX.fullmatch(header) is None:
                return echoed + "?\r>", "invalid_header"
            self.header = header
            return echoed + "OK\r>", None
        if command == "ATI":
            return echoed + "ELM327 v2.1\r>", None
        if command == "AT@1":
            return echoed + "Telltale read-only MG battery rig\r>", None
        if command == "ATRV":
            return echoed + "13.9V\r>", None
        if command == "ATDP":
            text = "AUTO" if self.protocol_search_pending else "AUTO, ISO 15765-4 (CAN 11/500)"
            return echoed + text + "\r>", None
        if command == "ATDPN":
            return echoed + ("A0" if self.protocol_search_pending else "A6") + "\r>", None
        if command == "ATPPS":
            return echoed + "2C:00 F\r2D:01 F\r2E:80 F\r>", None

        if command.startswith("AT"):
            return echoed + "?\r>", "unknown_at"
        if len(command) < 2 or len(command) % 2 or _HEX.fullmatch(command) is None:
            return echoed + "?\r>", "malformed"

        service = command[:2]
        if service in _UNSAFE_SERVICES:
            return echoed + "NO DATA\r>", "unsafe_service_refused"

        payload: bytes | None = None
        responder = "7E8"
        if service == "01" and self.header in {"7DF", "7E0"}:
            payload = self._mode01(command)
            if payload is not None:
                self.protocol_search_pending = False
        elif service == "22" and self.header == "781":
            payload = MG_MODE22_RESPONSES.get(command)
            responder = "789"

        if payload is None:
            return echoed + "NO DATA\r>", "unsupported_or_wrong_header"
        return echoed + self._format_can(responder, payload) + "\r>", None

    @staticmethod
    def _mode01(command: str) -> bytes | None:
        if len(command) < 4 or len(command) % 2:
            return None
        pids = [command[index : index + 2] for index in range(2, len(command), 2)]
        payload = bytearray((0x41,))
        answered = 0
        for pid in pids:
            data = SUPPORT_MASKS.get(pid) if pid in SUPPORT_MASKS else MODE01_DATA.get(pid)
            if data is None:
                continue
            payload.append(int(pid, 16))
            payload.extend(data)
            answered += 1
        return bytes(payload) if answered else None

    def _format_can(self, responder: str, payload: bytes) -> str:
        if len(payload) <= 7:
            if not self.headers:
                return self._bytes(payload)
            frame = bytes((len(payload),)) + payload + bytes(7 - len(payload))
            separator = " " if self.spaces else ""
            return responder + separator + self._bytes(frame)

        # Standard ISO-TP multi-frame rendering, included for compact Mode 01
        # batches. The MG profile fixtures themselves all fit one CAN frame.
        frames: list[bytes] = []
        frames.append(bytes((0x10 | ((len(payload) >> 8) & 0xF), len(payload) & 0xFF)) + payload[:6])
        offset = 6
        sequence = 1
        while offset < len(payload):
            chunk = payload[offset : offset + 7]
            frames.append(bytes((0x20 | (sequence & 0xF),)) + chunk + bytes(7 - len(chunk)))
            offset += len(chunk)
            sequence += 1
        if self.headers:
            separator = " " if self.spaces else ""
            return "\r".join(responder + separator + self._bytes(frame) for frame in frames)
        lines = [f"{len(payload):03X}"]
        lines.extend(f"{index:X}:{self._bytes(frame[1:] if index else frame[2:])}" for index, frame in enumerate(frames))
        return "\r".join(lines)

    def _bytes(self, value: bytes) -> str:
        separator = " " if self.spaces else ""
        return separator.join(f"{byte:02X}" for byte in value)


class RigServer:
    def __init__(self, config: Config, logger: JsonlLogger) -> None:
        self.config = config
        self.logger = logger
        self.server: asyncio.Server | None = None
        self._clients: set[asyncio.Task[None]] = set()
        self._connection_sequence = 0

    @property
    def address(self) -> tuple[str, int]:
        if self.server is None or not self.server.sockets:
            raise RuntimeError("rig is not listening")
        host, port = self.server.sockets[0].getsockname()[:2]
        return str(host), int(port)

    async def start(self) -> None:
        if self.server is not None:
            raise RuntimeError("rig is already listening")
        self.server = await asyncio.start_server(self._accept, self.config.host, self.config.port)
        host, port = self.address
        self.logger.emit("ready", host=host, port=port)

    async def close(self) -> None:
        if self.server is None:
            return
        self.server.close()
        await self.server.wait_closed()
        tasks = list(self._clients)
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        self.server = None
        self.logger.emit("stopped")

    def _accept(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        task = asyncio.create_task(self._serve(reader, writer))
        self._clients.add(task)
        task.add_done_callback(self._clients.discard)

    async def _serve(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self._connection_sequence += 1
        connection = self._connection_sequence
        peer = writer.get_extra_info("peername")
        self.logger.emit("connected", connection=connection, peer=str(peer))
        session = ElmSession()
        try:
            while True:
                raw = await reader.readuntil(b"\r")
                try:
                    exact = raw[:-1].decode("ascii")
                except UnicodeDecodeError:
                    exact = raw[:-1].decode("ascii", errors="replace")
                    response, refusal = "?\r>", "non_ascii"
                else:
                    response, refusal = session.respond(exact)
                self.logger.emit(
                    "command",
                    connection=connection,
                    command=exact,
                    command_hex=raw[:-1].hex(),
                    response=response,
                    refusal=refusal,
                )
                writer.write(response.encode("ascii"))
                await writer.drain()
        except (asyncio.IncompleteReadError, ConnectionResetError, BrokenPipeError):
            pass
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except (ConnectionResetError, BrokenPipeError):
                pass
            self.logger.emit("disconnected", connection=connection)


def _cli_port(value: str) -> int:
    try:
        port = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be an integer") from error
    if not 1 <= port <= 65535:
        raise argparse.ArgumentTypeError("must be in 1..65535")
    return port


def parse_config(argv: list[str] | None = None) -> Config:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1", help="listen address; defaults to localhost")
    parser.add_argument("--port", type=_cli_port, default=35000)
    parser.add_argument("--log", default="-", help="JSONL command log path, or - for stdout")
    args = parser.parse_args(argv)
    try:
        return Config(host=args.host, port=args.port, log_path=args.log)
    except ValueError as error:
        parser.error(str(error))


async def _run(config: Config) -> None:
    logger = JsonlLogger(config.log_path)
    server = RigServer(config, logger)
    try:
        await server.start()
        await asyncio.Event().wait()
    finally:
        await server.close()
        logger.close()


def main(argv: list[str] | None = None) -> int:
    try:
        asyncio.run(_run(parse_config(argv)))
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
