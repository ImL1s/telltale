from __future__ import annotations

import asyncio
import io
import json
import os
import stat
import tempfile
import unittest
from unittest import mock

from chaos_proxy import ChaosProxy, Config, JsonlLogger, parse_config


class FakeElm:
    def __init__(self) -> None:
        self.commands: list[bytes] = []
        self.server: asyncio.Server | None = None

    async def start(self) -> None:
        self.server = await asyncio.start_server(self._serve, "127.0.0.1", 0)

    @property
    def port(self) -> int:
        assert self.server is not None and self.server.sockets
        return int(self.server.sockets[0].getsockname()[1])

    async def close(self) -> None:
        assert self.server is not None
        self.server.close()
        await self.server.wait_closed()

    async def _serve(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            while True:
                command = await reader.readuntil(b"\r")
                self.commands.append(command)
                response = command.rstrip(b"\r") + b"\rOK\r>"
                for byte in response:
                    writer.write(bytes((byte,)))
                    await writer.drain()
                    await asyncio.sleep(0)
        except (asyncio.IncompleteReadError, ConnectionResetError):
            pass
        finally:
            writer.close()
            await writer.wait_closed()


class MemoryLogger(JsonlLogger):
    def __init__(self) -> None:
        self.run_id = "test-run"
        self._seq = 0
        self._owned = False
        self._stream = io.StringIO()

    @property
    def records(self) -> list[dict[str, object]]:
        return [json.loads(line) for line in self._stream.getvalue().splitlines()]


def config(upstream_port: int, **overrides: object) -> Config:
    values: dict[str, object] = {
        "listen_host": "127.0.0.1",
        "listen_port": 0,
        "upstream_host": "127.0.0.1",
        "upstream_port": upstream_port,
        "chunk_sizes": (1, 2, 3),
        "delay_seconds": 0,
        "response_timeout": 1,
        "close_on_command": None,
        "no_prompt_on_command": None,
        "corrupt_on_command": None,
        "log_path": "-",
    }
    values.update(overrides)
    return Config(**values)  # type: ignore[arg-type]


class ChaosProxyTest(unittest.IsolatedAsyncioTestCase):
    _READ_TIMEOUT = 1.0

    async def asyncSetUp(self) -> None:
        self.elm = FakeElm()
        await self.elm.start()
        self.logger = MemoryLogger()
        self.proxy = ChaosProxy(config(self.elm.port), self.logger)
        await self.proxy.start()

    async def asyncTearDown(self) -> None:
        await self.proxy.close()
        await self.elm.close()

    async def connect(self) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
        return await asyncio.wait_for(
            asyncio.open_connection(*self.proxy.address),
            self._READ_TIMEOUT,
        )

    async def read_until(
        self,
        reader: asyncio.StreamReader,
        separator: bytes,
    ) -> bytes:
        return await asyncio.wait_for(
            reader.readuntil(separator),
            self._READ_TIMEOUT,
        )

    async def read_exactly(
        self,
        reader: asyncio.StreamReader,
        count: int,
    ) -> bytes:
        return await asyncio.wait_for(
            reader.readexactly(count),
            self._READ_TIMEOUT,
        )

    async def read_to_eof(self, reader: asyncio.StreamReader) -> bytes:
        return await asyncio.wait_for(reader.read(), self._READ_TIMEOUT)

    async def test_fragmented_command_and_reply_preserve_order_without_replay(self) -> None:
        reader, writer = await self.connect()
        writer.write(b"AT")
        await writer.drain()
        await asyncio.sleep(0.02)
        self.assertEqual([], self.elm.commands)
        writer.write(b"Z\r")
        await writer.drain()
        self.assertEqual(b"ATZ\rOK\r>", await self.read_until(reader, b">"))
        self.assertEqual([b"ATZ\r"], self.elm.commands)
        chunks = [
            bytes.fromhex(record["data_hex"])
            for record in self.logger.records
            if record["direction"] == "upstream_to_client"
        ]
        self.assertEqual(b"ATZ\rOK\r>", b"".join(chunks))
        self.assertEqual([1, 2, 3, 1, 1], [len(chunk) for chunk in chunks])
        records = self.logger.records
        self.assertTrue(
            all(
                {"run_id", "seq", "monotonic", "direction", "data_hex", "fault"}
                <= record.keys()
                for record in records
            )
        )
        self.assertEqual(list(range(1, len(records) + 1)), [r["seq"] for r in records])
        await self._close_client(writer)

    async def test_no_prompt_fault_strips_only_prompt(self) -> None:
        await self._restart(no_prompt_on_command=1)
        reader, writer = await self.connect()
        writer.write(b"ATI\r")
        await writer.drain()
        self.assertEqual(b"ATI\rOK\r", await self.read_exactly(reader, 7))
        with self.assertRaises(asyncio.TimeoutError):
            await asyncio.wait_for(reader.read(1), 0.03)
        await self._close_client(writer)

    async def test_close_fault_accepts_reconnect_and_does_not_replay_fault(self) -> None:
        await self._restart(close_on_command=1)
        reader, writer = await self.connect()
        writer.write(b"ATZ\r")
        await writer.drain()
        self.assertEqual(b"", await self.read_to_eof(reader))
        await self._close_client(writer)
        reader2, writer2 = await self.connect()
        writer2.write(b"ATI\r")
        await writer2.drain()
        self.assertEqual(b"ATI\rOK\r>", await self.read_until(reader2, b">"))
        self.assertEqual([b"ATI\r"], self.elm.commands)
        await self._close_client(writer2)

    async def test_corrupt_fault_changes_one_payload_byte_and_keeps_prompt(self) -> None:
        await self._restart(corrupt_on_command=1)
        reader, writer = await self.connect()
        writer.write(b"ATI\r")
        await writer.drain()
        response = await self.read_until(reader, b">")
        self.assertNotEqual(b"ATI\rOK\r>", response)
        self.assertEqual(b">", response[-1:])
        self.assertEqual(len(b"ATI\rOK\r>"), len(response))
        await self._close_client(writer)

    async def test_concurrent_client_is_rejected_without_consuming_fault(self) -> None:
        await self._restart(close_on_command=1)
        reader, writer = await self.connect()
        reader2, writer2 = await self.connect()
        self.assertEqual(b"", await self.read_to_eof(reader2))

        writer.write(b"ATZ\r")
        await writer.drain()
        self.assertEqual(b"", await self.read_to_eof(reader))
        self.assertEqual([], self.elm.commands)
        faults = [
            record
            for record in self.logger.records
            if record["direction"] == "fault"
        ]
        self.assertEqual([1], [record["command"] for record in faults])
        rejected = [
            record
            for record in self.logger.records
            if record.get("event") == "client_rejected"
        ]
        self.assertEqual(
            ["active_driver_exists"],
            [record["reason"] for record in rejected],
        )
        await self._close_client(writer2)
        await self._close_client(writer)

    async def test_new_client_can_take_over_during_close_handover(self) -> None:
        reader, writer = await self.connect()
        writer.write(b"ATI\r")
        await writer.drain()
        self.assertEqual(b"ATI\rOK\r>", await self.read_until(reader, b">"))

        async def close_previous() -> None:
            await asyncio.sleep(0.02)
            writer.close()
            await writer.wait_closed()

        close_task = asyncio.create_task(close_previous())
        reader2, writer2 = await self.connect()
        writer2.write(b"ATZ\r")
        await writer2.drain()
        self.assertEqual(b"ATZ\rOK\r>", await self.read_until(reader2, b">"))
        await close_task
        await self._close_client(writer2)
        rejected = [
            record
            for record in self.logger.records
            if record.get("event") == "client_rejected"
        ]
        self.assertEqual([], rejected)

    async def _restart(self, **overrides: object) -> None:
        await self.proxy.close()
        self.logger = MemoryLogger()
        self.proxy = ChaosProxy(config(self.elm.port, **overrides), self.logger)
        await self.proxy.start()

    async def _close_client(self, writer: asyncio.StreamWriter) -> None:
        writer.close()
        await writer.wait_closed()
        for _ in range(20):
            if not self.proxy._clients:
                return
            await asyncio.sleep(0.005)


class ConfigTest(unittest.TestCase):
    def test_file_logger_restricts_existing_log_permissions(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "chaos.jsonl")
            with open(path, "w", encoding="utf-8"):
                pass
            os.chmod(path, 0o644)
            logger = JsonlLogger(path)
            logger.close()
            self.assertEqual(0o600, stat.S_IMODE(os.stat(path).st_mode))

    @unittest.skipUnless(hasattr(os, "O_NOFOLLOW"), "O_NOFOLLOW unavailable")
    def test_file_logger_refuses_symlink_target(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = os.path.join(directory, "target")
            link = os.path.join(directory, "chaos.jsonl")
            with open(target, "w", encoding="utf-8") as stream:
                stream.write("keep\n")
            os.symlink(target, link)

            with self.assertRaises(OSError):
                JsonlLogger(link)
            with open(target, encoding="utf-8") as stream:
                self.assertEqual("keep\n", stream.read())

    def test_default_bind_is_loopback(self) -> None:
        self.assertEqual("127.0.0.1", parse_config([]).listen_host)

    def test_rejects_malformed_chunk_cycle(self) -> None:
        with mock.patch("sys.stderr", io.StringIO()), self.assertRaises(SystemExit):
            parse_config(["--chunk-sizes", "2,0,x"])

    def test_rejects_multiple_faults_even_on_different_commands(self) -> None:
        for arguments in (
            ["--close-on-command", "3", "--no-prompt-on-command", "3"],
            ["--close-on-command", "2", "--corrupt-on-command", "7"],
        ):
            with self.subTest(arguments=arguments):
                with mock.patch("sys.stderr", io.StringIO()), self.assertRaises(
                    SystemExit
                ) as exit_context:
                    parse_config(arguments)
                self.assertEqual(2, exit_context.exception.code)

    def test_config_rejects_multiple_faults_without_cli(self) -> None:
        with self.assertRaisesRegex(ValueError, "at most one fault"):
            config(
                35000,
                close_on_command=2,
                no_prompt_on_command=7,
            )

    def test_rejects_empty_host_and_non_finite_delay(self) -> None:
        for arguments in (["--listen-host", ""], ["--delay-ms", "nan"]):
            with self.subTest(arguments=arguments):
                with mock.patch("sys.stderr", io.StringIO()), self.assertRaises(
                    SystemExit
                ):
                    parse_config(arguments)


if __name__ == "__main__":
    unittest.main()
