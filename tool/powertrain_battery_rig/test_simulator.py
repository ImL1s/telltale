from __future__ import annotations

import argparse
import asyncio
import io
import json
import unittest

from simulator import Config, ElmSession, JsonlLogger, MG_MODE22_RESPONSES, RigServer, parse_config


class MemoryLogger(JsonlLogger):
    def __init__(self) -> None:
        self._owned = False
        self._sequence = 0
        self._stream = io.StringIO()

    @property
    def records(self) -> list[dict[str, object]]:
        return [json.loads(line) for line in self._stream.getvalue().splitlines()]


class ElmSessionTest(unittest.TestCase):
    def setUp(self) -> None:
        self.session = ElmSession()
        self.session.respond("ATE0")
        self.session.respond("ATS0")
        self.session.respond("ATH1")

    def test_every_catalog_did_has_source_correct_789_positive_response(self) -> None:
        self.session.respond("ATSH 781")
        self.assertEqual(11, len(MG_MODE22_RESPONSES))
        for request, payload in MG_MODE22_RESPONSES.items():
            response, refusal = self.session.respond(request)
            self.assertIsNone(refusal, request)
            self.assertTrue(response.startswith(f"7890{len(payload):X}62{request[2:]}"), response)
            self.assertTrue(response.endswith("\r>"), response)

    def test_wrong_header_and_unknown_or_unsafe_requests_never_get_vehicle_data(self) -> None:
        self.session.respond("ATSH 780")
        self.assertEqual(("NO DATA\r>", "unsupported_or_wrong_header"), self.session.respond("22B046"))
        self.session.respond("ATSH 781")
        self.assertEqual(("NO DATA\r>", "unsupported_or_wrong_header"), self.session.respond("22FFFF"))
        for request in ("1003", "1101", "14", "2701", "2EB0460000", "3101FF00"):
            response, refusal = self.session.respond(request)
            self.assertEqual("NO DATA\r>", response)
            self.assertEqual("unsafe_service_refused", refusal)

    def test_prompt_framing_echo_and_formatting_are_stateful(self) -> None:
        session = ElmSession()
        self.assertEqual("ATZ\rELM327 v2.1\r\r>", session.respond("ATZ")[0])
        self.assertEqual("ATE0\rOK\r>", session.respond("ATE0")[0])
        self.assertEqual("OK\r>", session.respond("ATS0")[0])
        self.assertEqual("4100BE3FA813\r>", session.respond("0100")[0])
        self.assertEqual("AUTO, ISO 15765-4 (CAN 11/500)\r>", session.respond("ATDP")[0])
        self.assertTrue(all(session.respond(command)[0].endswith(">") for command in ("ATI", "?", "04", "ATSHZZZ")))

    def test_standard_compact_mode01_poll_is_deterministic(self) -> None:
        self.session.respond("ATSH7E0")
        response, refusal = self.session.respond("010C0D05")
        self.assertIsNone(refusal)
        self.assertEqual(
            "7E81008410C1AF80D3C\r7E82105690000000000\r>",
            response,
        )


class RigServerTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.logger = MemoryLogger()
        self.server = RigServer(Config(port=0), self.logger)
        await self.server.start()

    async def asyncTearDown(self) -> None:
        await self.server.close()

    async def test_tcp_lifecycle_prompt_and_exact_command_log(self) -> None:
        reader, writer = await asyncio.open_connection(*self.server.address)
        writer.write(b"ATZ\rATE0\rATSH 781\rATH1\r22B046\r")
        await writer.drain()
        replies = [await asyncio.wait_for(reader.readuntil(b">"), 1) for _ in range(5)]
        self.assertEqual(b"ATZ\rELM327 v2.1\r\r>", replies[0])
        self.assertEqual(b"ATE0\rOK\r>", replies[1])
        self.assertEqual(b"789 05 62 B0 46 01 F4 00 00\r>", replies[4])
        commands = [record for record in self.logger.records if record["event"] == "command"]
        self.assertEqual(["ATZ", "ATE0", "ATSH 781", "ATH1", "22B046"], [r["command"] for r in commands])
        self.assertEqual("4154534820373831", commands[2]["command_hex"])
        writer.close()
        await writer.wait_closed()

    async def test_start_twice_fails_and_close_releases_ephemeral_port(self) -> None:
        port = self.server.address[1]
        with self.assertRaisesRegex(RuntimeError, "already listening"):
            await self.server.start()
        await self.server.close()
        replacement = await asyncio.start_server(lambda _r, w: w.close(), "127.0.0.1", port)
        replacement.close()
        await replacement.wait_closed()


class ConfigTest(unittest.TestCase):
    def test_localhost_is_default_and_cli_rejects_invalid_ports(self) -> None:
        self.assertEqual(Config(), parse_config([]))
        for value in ("0", "65536", "nope"):
            with self.assertRaises(SystemExit):
                parse_config(["--port", value])

    def test_config_rejects_empty_host_and_out_of_range_port(self) -> None:
        for kwargs in ({"host": " "}, {"port": -1}, {"port": 65536}):
            with self.assertRaises(ValueError):
                Config(**kwargs)  # type: ignore[arg-type]


if __name__ == "__main__":
    unittest.main()
