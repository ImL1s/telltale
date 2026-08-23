import asyncio
import os
import socket
import sys
from pathlib import Path
import tempfile
import unittest
from unittest import mock

# Keep discovery runnable from the repository root without making this tool a
# product package.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import bridge


class FakeSocket:
    def __init__(self, receives=(), send_error=None):
        self.receives = iter(receives)
        self.send_error = send_error
        self.sent = []
        self.closed = False

    def settimeout(self, timeout):
        self.timeout = timeout

    def sendall(self, data):
        self.sent.append(data)
        if self.send_error:
            raise self.send_error

    def recv(self, size):
        result = next(self.receives)
        if isinstance(result, BaseException):
            raise result
        return result

    def close(self):
        self.closed = True


class AdvancingClock:
    def __init__(self, step=0.0):
        self.value = 0.0
        self.step = step

    def __call__(self):
        result = self.value
        self.value += self.step
        return result


class FramingTests(unittest.TestCase):
    def setUp(self):
        self._temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._temp_dir.cleanup)
        patcher = mock.patch.object(
            bridge,
            "OUT",
            Path(self._temp_dir.name) / "bridge.jsonl",
        )
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_prompt_framing(self):
        self.assertFalse(bridge.prompt_complete(b"OK\r"))
        self.assertTrue(bridge.prompt_complete(b"OK\r>"))
        self.assertTrue(bridge.prompt_complete(b"OK\r>\r\n"))

    def test_fragmented_prompt(self):
        sock = FakeSocket([b"41 00 ", b"BE 3E", b"\r", b">"])
        link = bridge.ElmLink(socket_factory=lambda *a, **k: sock)
        self.assertEqual(link.exchange(b"0100\r"), b"41 00 BE 3E\r>")
        self.assertEqual(sock.sent, [b"0100\r"])

    def test_eof_resets_connection(self):
        sock = FakeSocket([b"OK\r", b""])
        link = bridge.ElmLink(socket_factory=lambda *a, **k: sock)
        with self.assertRaises(ConnectionError):
            link.exchange(b"ATI\r")
        self.assertIsNone(link.sock)
        self.assertTrue(sock.closed)

    def test_timeout_resets_connection(self):
        sock = FakeSocket([socket.timeout()] * 10)
        link = bridge.ElmLink(
            read_timeout=1.0,
            socket_factory=lambda *a, **k: sock,
            clock=AdvancingClock(step=0.4),
        )
        with self.assertRaises(TimeoutError):
            link.exchange(b"ATI\r")
        self.assertIsNone(link.sock)
        self.assertTrue(sock.closed)

    def test_ambiguous_send_failure_is_not_replayed(self):
        sock = FakeSocket(send_error=BrokenPipeError("broken"))
        calls = []

        def factory(*args, **kwargs):
            calls.append((args, kwargs))
            return sock

        link = bridge.ElmLink(socket_factory=factory)
        with self.assertRaises(BrokenPipeError):
            link.exchange(b"ATZ\r")
        self.assertEqual(sock.sent, [b"ATZ\r"])
        self.assertEqual(len(calls), 1)
        self.assertIsNone(link.sock)


class ChunkTests(unittest.TestCase):
    def test_chunk_boundaries(self):
        self.assertEqual(
            bridge.notification_chunks(b"abcdefgh", 3),
            (b"abc", b"def", b"gh"),
        )
        self.assertEqual(bridge.notification_chunks(b"", 3), ())
        with self.assertRaises(ValueError):
            bridge.notification_chunks(b"x", 0)


class CentralSessionTrackerTests(unittest.TestCase):
    def test_old_central_generation_cannot_be_reused_by_new_central(self):
        sessions = bridge.CentralSessionTracker(bridge.TX)
        self.assertTrue(sessions.apply(bridge.TX, "central-a", True))
        old_generation = sessions.bind_write("central-a")
        self.assertIsNotNone(old_generation)

        self.assertTrue(sessions.apply(bridge.TX, "central-a", False))
        self.assertTrue(sessions.apply(bridge.TX, "central-b", True))

        self.assertFalse(sessions.is_current(old_generation, "central-a"))
        self.assertIsNone(sessions.bind_write("central-a"))
        self.assertEqual(sessions.active_central_id, "central-b")

    def test_contention_requires_all_centrals_to_leave_and_fresh_subscribe(self):
        sessions = bridge.CentralSessionTracker(bridge.TX)
        sessions.apply(bridge.TX, "central-a", True)
        sessions.apply(bridge.TX, "central-b", True)
        self.assertEqual(sessions.central_count, 2)
        self.assertTrue(sessions.contention_latched)
        self.assertIsNone(sessions.active_central_id)
        self.assertIsNone(sessions.bind_write("central-a"))
        self.assertIsNone(sessions.bind_write("central-b"))

        sessions.apply(bridge.TX, "central-b", False)
        self.assertEqual(sessions.central_count, 1)
        self.assertTrue(sessions.contention_latched)
        self.assertIsNone(sessions.active_central_id)
        self.assertIsNone(sessions.bind_write("central-a"))

        sessions.apply(bridge.TX, "central-a", False)
        self.assertEqual(sessions.central_count, 0)
        self.assertFalse(sessions.contention_latched)
        self.assertIsNone(sessions.active_central_id)

        sessions.apply(bridge.TX, "central-a", True)
        self.assertEqual(sessions.active_central_id, "central-a")
        self.assertIsNotNone(sessions.bind_write("central-a"))

    def test_unrelated_characteristic_and_duplicate_event_do_not_rotate(self):
        sessions = bridge.CentralSessionTracker(bridge.TX)
        self.assertFalse(sessions.apply(bridge.RX, "central-a", True))
        self.assertEqual(sessions.generation, 0)
        self.assertTrue(sessions.apply(bridge.TX, "central-a", True))
        generation = sessions.generation
        self.assertFalse(sessions.apply(bridge.TX, "central-a", True))
        self.assertEqual(sessions.generation, generation)


class FakeIdentifier:
    def __init__(self, value):
        self.value = value

    def UUIDString(self):
        return self.value


class FakeCentral:
    def __init__(self, central_id):
        self.central_id = central_id

    def identifier(self):
        return FakeIdentifier(self.central_id)


class FakeNativeCharacteristic:
    def __init__(self, centrals):
        self.centrals = centrals

    def subscribedCentrals(self):
        return self.centrals


class FakeCharacteristic:
    def __init__(self, centrals):
        self.obj = FakeNativeCharacteristic(centrals)
        self.value = None


class FakePeripheralManager:
    def __init__(self):
        self.calls = []

    def updateValue_forCharacteristic_onSubscribedCentrals_(
        self,
        value,
        characteristic,
        centrals,
    ):
        self.calls.append((value, characteristic, centrals))
        return True


class FakeCentralAwareServer:
    def __init__(self, centrals):
        self.characteristic = FakeCharacteristic(centrals)
        self.peripheral_manager_delegate = mock.Mock()
        self.peripheral_manager_delegate.peripheral_manager = FakePeripheralManager()

    def get_characteristic(self, uuid):
        return self.characteristic


class TargetedNotificationTests(unittest.TestCase):
    def test_targets_the_exact_single_central_and_never_broadcasts(self):
        central = FakeCentral("central-a")
        server = FakeCentralAwareServer([central])

        self.assertTrue(
            bridge.update_value_for_central(
                server,
                bridge.TX,
                b"reply",
                "central-a",
            )
        )

        manager = server.peripheral_manager_delegate.peripheral_manager
        self.assertEqual(len(manager.calls), 1)
        value, characteristic, targets = manager.calls[0]
        self.assertEqual(value, b"reply")
        self.assertIs(characteristic, server.characteristic.obj)
        self.assertEqual(targets, [central])
        self.assertIsNotNone(targets)

    def test_zero_multiple_or_different_central_never_reaches_manager(self):
        cases = (
            [],
            [FakeCentral("central-a"), FakeCentral("central-b")],
            [FakeCentral("central-b")],
        )
        for centrals in cases:
            with self.subTest(central_ids=[c.central_id for c in centrals]):
                server = FakeCentralAwareServer(centrals)
                with self.assertRaises(bridge.SessionChangedError):
                    bridge.update_value_for_central(
                        server,
                        bridge.TX,
                        b"reply",
                        "central-a",
                    )
                manager = server.peripheral_manager_delegate.peripheral_manager
                self.assertEqual(manager.calls, [])


class CommandAssemblerTests(unittest.TestCase):
    def test_reassembles_fragmented_command(self):
        assembler = bridge.CommandAssembler()
        for fragment in (b"A", b"T", b"Z"):
            self.assertEqual(assembler.feed(fragment), ())
        self.assertEqual(assembler.feed(b"\r"), (b"ATZ\r",))
        self.assertEqual(assembler.pending_size, 0)

    def test_emits_multiple_commands_and_preserves_remainder(self):
        assembler = bridge.CommandAssembler()
        self.assertEqual(
            assembler.feed(b"ATE0\rATL0\r010"),
            (b"ATE0\r", b"ATL0\r"),
        )
        self.assertEqual(assembler.pending_size, 3)
        self.assertEqual(assembler.feed(b"0\r"), (b"0100\r",))

    def test_preserves_empty_repeat_command(self):
        self.assertEqual(bridge.CommandAssembler().feed(b"\r"), (b"\r",))

    def test_overflow_clears_partial_command(self):
        assembler = bridge.CommandAssembler(max_bytes=4)
        assembler.feed(b"AT")
        with self.assertRaises(BufferError):
            assembler.feed(b"Z12")
        self.assertEqual(assembler.pending_size, 0)

    def test_clear_discards_only_partial_session_bytes(self):
        assembler = bridge.CommandAssembler()
        assembler.feed(b"AT")
        self.assertEqual(assembler.clear(), 2)
        self.assertEqual(assembler.pending_size, 0)
        self.assertEqual(assembler.feed(b"I\r"), (b"I\r",))
        self.assertEqual(assembler.clear(), 0)


class NotificationBackpressureTests(unittest.IsolatedAsyncioTestCase):
    def readiness(self):
        return bridge.NotificationReadiness(asyncio.get_running_loop())

    async def wait_for_calls(self, calls, count):
        for _ in range(20):
            if len(calls) >= count:
                return
            await asyncio.sleep(0)
        self.fail(f"expected {count} calls, got {len(calls)}")

    async def test_retries_in_order_until_accepted(self):
        results = iter((False, False, True))
        calls = []

        def update():
            calls.append(len(calls) + 1)
            return next(results)

        readiness = self.readiness()
        task = asyncio.create_task(
            bridge.publish_notification(update, readiness, max_retries=2)
        )
        await asyncio.sleep(0)
        self.assertEqual(calls, [1])
        readiness.mark_ready()
        await self.wait_for_calls(calls, 2)
        self.assertEqual(calls, [1, 2])
        readiness.mark_ready()
        retries = await task
        self.assertEqual(retries, 2)
        self.assertEqual(calls, [1, 2, 3])

    async def test_fails_at_fixed_retry_boundary(self):
        calls = []

        def reject():
            calls.append(True)
            return False

        readiness = self.readiness()
        task = asyncio.create_task(
            bridge.publish_notification(reject, readiness, max_retries=2)
        )
        await asyncio.sleep(0)
        readiness.mark_ready()
        await self.wait_for_calls(calls, 2)
        readiness.mark_ready()
        with self.assertRaises(TimeoutError):
            await task
        self.assertEqual(len(calls), 3)

    async def test_fails_at_fixed_deadline_without_polling(self):
        calls = []

        with self.assertRaises(TimeoutError):
            await bridge.publish_notification(
                lambda: calls.append(True) or False,
                self.readiness(),
                max_retries=200,
                timeout=0.001,
            )
        self.assertEqual(calls, [True])

    async def test_ready_callback_during_rejected_update_is_not_lost(self):
        readiness = self.readiness()
        calls = []

        def update():
            calls.append(True)
            if len(calls) == 1:
                readiness.mark_ready()
                return False
            return True

        retries = await bridge.publish_notification(
            update,
            readiness,
            max_retries=1,
        )
        self.assertEqual(retries, 1)
        self.assertEqual(calls, [True, True])

    async def test_session_change_aborts_before_another_publish_attempt(self):
        current = True
        calls = []

        def update():
            nonlocal current
            calls.append(True)
            current = False
            return False

        readiness = self.readiness()
        task = asyncio.create_task(
            bridge.publish_notification(
                update,
                readiness,
                should_continue=lambda: current,
                max_retries=2,
            )
        )
        await asyncio.sleep(0)
        readiness.mark_ready()
        with self.assertRaises(bridge.SessionChangedError):
            await task
        self.assertEqual(len(calls), 1)
    async def test_stale_ready_callback_cannot_publish_changed_generation(self):
        readiness = self.readiness()
        generation = 4
        current_generation = generation
        calls = []

        def update():
            calls.append(current_generation)
            return False

        task = asyncio.create_task(
            bridge.publish_notification(
                update,
                readiness,
                should_continue=lambda: current_generation == generation,
                max_retries=2,
            )
        )
        await asyncio.sleep(0)
        current_generation += 1
        readiness.mark_ready()
        with self.assertRaises(bridge.SessionChangedError):
            await task
        self.assertEqual(calls, [generation])


class AdvertisingHealthTests(unittest.IsolatedAsyncioTestCase):
    async def test_loss_is_reported_before_monitor_fails(self):
        states = iter((True, False))
        reported = []

        with self.assertRaisesRegex(RuntimeError, "advertising stopped"):
            await bridge.monitor_advertising(
                lambda: next(states),
                reported.append,
                interval=0.0001,
            )

        self.assertEqual(reported, [True, False])

    async def test_invalid_interval_fails_closed(self):
        with self.assertRaises(ValueError):
            await bridge.monitor_advertising(lambda: True, lambda _: None, interval=0)


class MainTests(unittest.TestCase):
    def test_expiry_callback_receives_the_controller_tmp_root(self):
        environment = bridge.controller_expiry_environment(
            Path("/private/custom-tmp"),
            {"KEEP": "yes", "TMPDIR": "/wrong/"},
        )

        self.assertEqual(environment["TMPDIR"], "/private/custom-tmp/")
        self.assertEqual(environment["KEEP"], "yes")

    def test_log_is_restricted_before_bridge_starts(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "bridge.jsonl"
            output.write_text("old\n", encoding="utf-8")
            output.chmod(0o644)
            with mock.patch.object(bridge, "OUT", output), mock.patch.object(
                bridge,
                "run_bridge",
                new=mock.AsyncMock(return_value=None),
            ):
                result = bridge.main(
                    [
                        "1",
                        str(Path(directory) / "bridge.pid"),
                        "0",
                        "20",
                        "0",
                        "0" * 32,
                        directory,
                    ]
                )
            self.assertEqual(result, 0)
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)

    @unittest.skipUnless(hasattr(os, "O_NOFOLLOW"), "O_NOFOLLOW unavailable")
    def test_log_symlink_is_refused_without_modifying_target(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "target"
            output = Path(directory) / "bridge.jsonl"
            target.write_text("keep\n", encoding="utf-8")
            output.symlink_to(target)
            with mock.patch.object(bridge, "OUT", output), mock.patch.object(
                bridge,
                "run_bridge",
                new=mock.AsyncMock(return_value=None),
            ):
                with self.assertRaises(OSError):
                    bridge.main(
                        [
                            "1",
                            str(Path(directory) / "bridge.pid"),
                            "0",
                            "20",
                            "0",
                            "0" * 32,
                            directory,
                        ]
                    )
            self.assertEqual(target.read_text(encoding="utf-8"), "keep\n")


class FaultConfigTests(unittest.TestCase):
    def test_defaults_and_valid_values(self):
        self.assertEqual(bridge.FaultConfig.from_strings(), bridge.FaultConfig())
        self.assertEqual(
            bridge.FaultConfig.from_strings("125", "7", "4"),
            bridge.FaultConfig(125, 7, 4),
        )

    def test_invalid_values_fail_closed(self):
        for values in [
            ("-1", "20", "0"),
            ("60001", "20", "0"),
            ("0", "0", "0"),
            ("0", "513", "0"),
            ("0", "20", "-1"),
            ("bad", "20", "0"),
        ]:
            with self.subTest(values=values), self.assertRaises(ValueError):
                bridge.FaultConfig.from_strings(*values)


if __name__ == "__main__":
    unittest.main()
