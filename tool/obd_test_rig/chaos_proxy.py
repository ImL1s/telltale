#!/usr/bin/env python3
"""Deterministic TCP fault proxy for prompt-terminated ELM327 emulators."""

from __future__ import annotations

import argparse
import asyncio
import contextlib
from dataclasses import dataclass
import hmac
import json
import math
import os
import signal
import sys
import time
import uuid
from pathlib import Path
from typing import TextIO


@dataclass(frozen=True)
class Config:
    listen_host: str
    listen_port: int
    upstream_host: str
    upstream_port: int
    chunk_sizes: tuple[int, ...]
    delay_seconds: float
    response_timeout: float
    close_on_command: int | None
    no_prompt_on_command: int | None
    corrupt_on_command: int | None
    armed_fault: str | None
    control_host: str
    control_port: int | None
    control_token: str | None
    disconnect_after_armed_fault: bool
    log_path: str

    def __post_init__(self) -> None:
        configured_faults = sum(
            value is not None
            for value in (
                self.close_on_command,
                self.no_prompt_on_command,
                self.corrupt_on_command,
                self.armed_fault,
            )
        )
        if configured_faults > 1:
            raise ValueError("at most one fault may be configured")
        control_values = (self.control_port, self.control_token)
        if self.armed_fault is None and any(
            value is not None for value in control_values
        ):
            raise ValueError("control options require an armed fault")
        if self.armed_fault is not None and any(
            value is None for value in control_values
        ):
            raise ValueError("armed fault requires control port and token")


class JsonlLogger:
    def __init__(self, path: str, run_id: str | None = None) -> None:
        self.run_id = run_id or uuid.uuid4().hex
        self._seq = 0
        self._owned = path != "-"
        if self._owned:
            flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND
            flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
            descriptor = os.open(path, flags, 0o600)
            try:
                os.fchmod(descriptor, 0o600)
                self._stream = os.fdopen(descriptor, "a", encoding="utf-8")
            except BaseException:
                os.close(descriptor)
                raise
        else:
            self._stream = sys.stdout

    def emit(
        self,
        direction: str,
        data: bytes = b"",
        *,
        fault: str | None = None,
        **fields: object,
    ) -> None:
        self._seq += 1
        record = {
            "run_id": self.run_id,
            "seq": self._seq,
            "monotonic": time.monotonic(),
            "direction": direction,
            "data_hex": data.hex(),
            "fault": fault,
            **fields,
        }
        self._stream.write(json.dumps(record, separators=(",", ":")) + "\n")
        self._stream.flush()

    def close(self) -> None:
        if self._owned:
            self._stream.close()


def _positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def _port(value: str) -> int:
    parsed = int(value)
    if not 1 <= parsed <= 65535:
        raise argparse.ArgumentTypeError("must be in 1..65535")
    return parsed


def _chunk_sizes(value: str) -> tuple[int, ...]:
    try:
        values = tuple(int(item) for item in value.split(","))
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be comma-separated integers") from error
    if not values or any(item <= 0 for item in values):
        raise argparse.ArgumentTypeError("all chunk sizes must be greater than zero")
    return values


def _nonempty(value: str) -> str:
    if not value.strip():
        raise argparse.ArgumentTypeError("must not be empty")
    return value


def parse_config(argv: list[str] | None = None) -> Config:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen-host", type=_nonempty, default="127.0.0.1")
    parser.add_argument("--listen-port", type=_port, default=35001)
    parser.add_argument("--upstream-host", type=_nonempty, default="127.0.0.1")
    parser.add_argument("--upstream-port", type=_port, default=35000)
    parser.add_argument("--chunk-sizes", type=_chunk_sizes, default=(1, 2, 5, 3))
    parser.add_argument("--delay-ms", type=float, default=0.0)
    parser.add_argument("--response-timeout", type=float, default=10.0)
    parser.add_argument("--close-on-command", type=_positive_int)
    parser.add_argument("--no-prompt-on-command", type=_positive_int)
    parser.add_argument("--corrupt-on-command", type=_positive_int)
    parser.add_argument(
        "--arm-next-command",
        choices=("close", "no_prompt", "corrupt"),
        dest="armed_fault",
    )
    parser.add_argument("--control-host", type=_nonempty)
    parser.add_argument("--control-port", type=_port)
    parser.add_argument("--control-token", type=_nonempty)
    parser.add_argument("--disconnect-after-armed-fault", action="store_true")
    parser.add_argument("--log", default="-")
    args = parser.parse_args(argv)
    if not math.isfinite(args.delay_ms) or args.delay_ms < 0:
        parser.error("--delay-ms must be finite and not negative")
    if not math.isfinite(args.response_timeout) or args.response_timeout <= 0:
        parser.error("--response-timeout must be finite and greater than zero")
    faults = [
        value
        for value in (
            args.close_on_command,
            args.no_prompt_on_command,
            args.corrupt_on_command,
            args.armed_fault,
        )
        if value is not None
    ]
    if len(faults) > 1:
        parser.error("at most one fault may be configured")
    control_values = (args.control_port, args.control_token)
    if args.armed_fault is None and any(value is not None for value in control_values):
        parser.error("control options require --arm-next-command")
    if args.armed_fault is not None and any(value is None for value in control_values):
        parser.error(
            "--arm-next-command requires --control-port and --control-token"
        )
    if args.disconnect_after_armed_fault and args.armed_fault is None:
        parser.error("--disconnect-after-armed-fault requires --arm-next-command")
    return Config(
        listen_host=args.listen_host,
        listen_port=args.listen_port,
        upstream_host=args.upstream_host,
        upstream_port=args.upstream_port,
        chunk_sizes=args.chunk_sizes,
        delay_seconds=args.delay_ms / 1000,
        response_timeout=args.response_timeout,
        close_on_command=args.close_on_command,
        no_prompt_on_command=args.no_prompt_on_command,
        corrupt_on_command=args.corrupt_on_command,
        armed_fault=args.armed_fault,
        control_host=args.control_host or args.listen_host,
        control_port=args.control_port,
        control_token=args.control_token,
        disconnect_after_armed_fault=args.disconnect_after_armed_fault,
        log_path=args.log,
    )


class ChaosProxy:
    _driver_handover_grace = 0.1

    def __init__(self, config: Config, logger: JsonlLogger) -> None:
        self.config = config
        self.logger = logger
        self.server: asyncio.Server | None = None
        self.control_server: asyncio.Server | None = None
        self._command_seq = 0
        self._connection_seq = 0
        self._clients: set[asyncio.Task[None]] = set()
        self._active_client: asyncio.Task[None] | None = None
        self._driver_lock = asyncio.Lock()
        self._armed = False
        self._armed_fault_consumed = False
        self._armed_fault_injected = asyncio.Event()
        self._armed_fault_command: int | None = None

    @property
    def address(self) -> tuple[str, int]:
        if self.server is None or not self.server.sockets:
            raise RuntimeError("proxy is not listening")
        host, port = self.server.sockets[0].getsockname()[:2]
        return str(host), int(port)

    async def start(self) -> None:
        self.server = await asyncio.start_server(
            self._accept,
            self.config.listen_host,
            self.config.listen_port,
        )
        host, port = self.address
        self.logger.emit(
            "lifecycle",
            event="ready",
            listen_host=host,
            listen_port=port,
            upstream_host=self.config.upstream_host,
            upstream_port=self.config.upstream_port,
        )
        if self.config.control_port is not None:
            self.control_server = await asyncio.start_server(
                self._accept_control,
                self.config.control_host,
                self.config.control_port,
            )
            assert self.control_server.sockets
            control_host, control_port = self.control_server.sockets[0].getsockname()[
                :2
            ]
            self.logger.emit(
                "lifecycle",
                event="control_ready",
                control_host=str(control_host),
                control_port=int(control_port),
                armed_fault=self.config.armed_fault,
            )

    async def close(self) -> None:
        if self.control_server is not None:
            self.control_server.close()
        if self.server is not None:
            self.server.close()
        tasks = list(self._clients)
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        if self.server is not None:
            await self.server.wait_closed()
            self.server = None
        if self.control_server is not None:
            await self.control_server.wait_closed()
            self.control_server = None
        self.logger.emit("lifecycle", event="stopped")

    def _accept_control(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
    ) -> None:
        task = asyncio.create_task(self._serve_control(reader, writer))
        self._track_client(task)

    async def _serve_control(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
    ) -> None:
        peer = writer.get_extra_info("peername")
        outcome = "REJECTED"
        try:
            line = await asyncio.wait_for(
                reader.readuntil(b"\n"),
                timeout=self.config.response_timeout,
            )
            prefix = b"ARM "
            supplied = line[len(prefix) : -1] if line.startswith(prefix) else b""
            expected_token = str(self.config.control_token).encode()
            if not line.endswith(b"\n") or not hmac.compare_digest(
                supplied,
                expected_token,
            ):
                outcome = "INVALID"
            elif self._armed_fault_consumed:
                outcome = "CONSUMED"
            elif self._armed:
                outcome = "ALREADY_ARMED"
            else:
                # No await is permitted between this state transition and its
                # acknowledgement. Once the device receives ARMED, the next
                # driver command is unambiguously the fault target.
                self._armed = True
                outcome = "ARMED"
            self.logger.emit(
                "control",
                event=outcome.lower(),
                peer=str(peer),
                armed_fault=self.config.armed_fault,
            )
            writer.write(f"{outcome} {self.config.armed_fault}\n".encode())
            await writer.drain()
            if outcome == "ARMED":
                await asyncio.wait_for(
                    self._armed_fault_injected.wait(),
                    timeout=self.config.response_timeout * 4,
                )
                writer.write(
                    f"INJECTED {self.config.armed_fault} "
                    f"{self._armed_fault_command}\n".encode()
                )
                await writer.drain()
        except (OSError, asyncio.TimeoutError, asyncio.IncompleteReadError):
            self.logger.emit("control", event="control_error", peer=str(peer))
        finally:
            await _close_writer(writer)

    def _accept(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        task = asyncio.create_task(self._admit_client(reader, writer))
        self._track_client(task)

    def _track_client(
        self,
        task: asyncio.Task[None],
    ) -> None:
        self._clients.add(task)
        task.add_done_callback(self._client_done)

    def _client_done(self, task: asyncio.Task[None]) -> None:
        self._clients.discard(task)

    async def _admit_client(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        try:
            await asyncio.wait_for(
                self._driver_lock.acquire(),
                timeout=self._driver_handover_grace,
            )
        except asyncio.TimeoutError:
            await self._reject_client(writer)
            return
        task = asyncio.current_task()
        self._active_client = task
        try:
            await self._serve_client(reader, writer)
        finally:
            if self._active_client is task:
                self._active_client = None
            self._driver_lock.release()

    async def _reject_client(self, writer: asyncio.StreamWriter) -> None:
        peer = writer.get_extra_info("peername")
        self.logger.emit(
            "lifecycle",
            event="client_rejected",
            reason="active_driver_exists",
            peer=str(peer),
        )
        await _close_writer(writer)

    async def _serve_client(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        self._connection_seq += 1
        connection = self._connection_seq
        peer = writer.get_extra_info("peername")
        self.logger.emit(
            "lifecycle",
            event="client_connected",
            connection=connection,
            peer=str(peer),
        )
        upstream_writer: asyncio.StreamWriter | None = None
        try:
            upstream_reader, upstream_writer = await asyncio.open_connection(
                self.config.upstream_host, self.config.upstream_port
            )
            while True:
                try:
                    command = await reader.readuntil(b"\r")
                except (asyncio.IncompleteReadError, ConnectionResetError):
                    break
                self._command_seq += 1
                command_seq = self._command_seq
                self.logger.emit(
                    "client_to_upstream",
                    command,
                    connection=connection,
                    command=command_seq,
                )
                armed_fault = self._consume_armed_fault()
                close_fault = (
                    command_seq == self.config.close_on_command
                    or armed_fault == "close"
                )
                if close_fault:
                    self.logger.emit(
                        "fault",
                        fault="close",
                        connection=connection,
                        command=command_seq,
                        armed=armed_fault is not None,
                    )
                    if armed_fault is not None:
                        self._mark_armed_fault_injected(command_seq)
                    return

                upstream_writer.write(command)
                await upstream_writer.drain()
                response = await asyncio.wait_for(
                    upstream_reader.readuntil(b">"),
                    timeout=self.config.response_timeout,
                )
                fault: str | None = None
                if (
                    command_seq == self.config.no_prompt_on_command
                    or armed_fault == "no_prompt"
                ):
                    response = response[:-1]
                    fault = "no_prompt"
                elif (
                    command_seq == self.config.corrupt_on_command
                    or armed_fault == "corrupt"
                ):
                    response = _corrupt(response)
                    fault = "corrupt"
                if fault is not None:
                    self.logger.emit(
                        "fault",
                        fault=fault,
                        connection=connection,
                        command=command_seq,
                        armed=armed_fault is not None,
                    )
                await self._write_chunks(
                    writer,
                    response,
                    connection=connection,
                    command=command_seq,
                    fault=fault,
                )
                if armed_fault is not None:
                    self._mark_armed_fault_injected(command_seq)
                if (
                    armed_fault is not None
                    and self.config.disconnect_after_armed_fault
                ):
                    self.logger.emit(
                        "fault",
                        fault="post_fault_close",
                        connection=connection,
                        command=command_seq,
                        after=armed_fault,
                        armed=True,
                    )
                    return
        except asyncio.CancelledError:
            raise
        except (
            OSError,
            asyncio.TimeoutError,
            asyncio.IncompleteReadError,
            asyncio.LimitOverrunError,
        ) as error:
            self.logger.emit(
                "lifecycle",
                fault="upstream_error",
                event=type(error).__name__,
                connection=connection,
            )
        finally:
            await _close_writer(writer)
            if upstream_writer is not None:
                await _close_writer(upstream_writer)
            self.logger.emit(
                "lifecycle",
                event="client_disconnected",
                connection=connection,
            )

    def _consume_armed_fault(self) -> str | None:
        if not self._armed or self._armed_fault_consumed:
            return None
        self._armed = False
        self._armed_fault_consumed = True
        return self.config.armed_fault

    def _mark_armed_fault_injected(self, command: int) -> None:
        self._armed_fault_command = command
        self._armed_fault_injected.set()

    async def _write_chunks(
        self,
        writer: asyncio.StreamWriter,
        response: bytes,
        *,
        connection: int,
        command: int,
        fault: str | None,
    ) -> None:
        offset = 0
        chunk_index = 0
        while offset < len(response):
            size = self.config.chunk_sizes[chunk_index % len(self.config.chunk_sizes)]
            chunk = response[offset : offset + size]
            writer.write(chunk)
            await writer.drain()
            self.logger.emit(
                "upstream_to_client",
                chunk,
                fault=fault,
                connection=connection,
                command=command,
                chunk=chunk_index,
            )
            offset += len(chunk)
            chunk_index += 1
            if self.config.delay_seconds:
                await asyncio.sleep(self.config.delay_seconds)


def _corrupt(response: bytes) -> bytes:
    mutable = bytearray(response)
    for index, value in enumerate(mutable):
        if value not in b"\r\n >":
            mutable[index] = value ^ 0x01
            return bytes(mutable)
    return response


async def _close_writer(writer: asyncio.StreamWriter) -> None:
    writer.close()
    try:
        await asyncio.wait_for(writer.wait_closed(), timeout=0.5)
    except (ConnectionError, asyncio.TimeoutError):
        transport = writer.transport
        transport.abort()


async def run(config: Config) -> None:
    logger = JsonlLogger(config.log_path)
    proxy = ChaosProxy(config, logger)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signum in (signal.SIGINT, signal.SIGTERM):
        with contextlib.suppress(NotImplementedError):
            loop.add_signal_handler(signum, stop.set)
    try:
        await proxy.start()
        await stop.wait()
    finally:
        await proxy.close()
        logger.close()


def main() -> None:
    os.umask(0o077)
    try:
        asyncio.run(run(parse_config()))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
