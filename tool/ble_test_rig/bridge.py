"""BLE-to-TCP ELM327 test bridge.

The module is import-safe: CoreBluetooth/bless is imported only by ``main`` so
framing and failure behavior can be unit-tested on any host.
"""
from __future__ import annotations

import asyncio
from dataclasses import dataclass
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import threading
import time
import traceback
from typing import Callable, TextIO

SVC = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
RX = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
TX = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
OUT = Path("/tmp/ble_bridge.log")
ELM_HOST, ELM_PORT = "127.0.0.1", 35000
DEFAULT_NOTIFY_CHUNK_SIZE = 20
MAX_PENDING_WRITES = 64
MAX_COMMAND_BYTES = 4096
MAX_NOTIFY_RETRIES = 200
MAX_NOTIFY_WAIT_SECONDS = 2.0
_log_sequence = 0
_log_lock = threading.Lock()


class SessionChangedError(RuntimeError):
    """The BLE central session changed while a reply was being published."""


def open_private_log(path: Path, *, truncate: bool = False) -> TextIO:
    flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND
    if truncate:
        flags |= os.O_TRUNC
    flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        return os.fdopen(descriptor, "a", encoding="utf-8")
    except BaseException:
        os.close(descriptor)
        raise


def controller_expiry_environment(
    tmp_root: Path,
    base: dict[str, str] | None = None,
) -> dict[str, str]:
    environment = os.environ.copy() if base is None else base.copy()
    environment["TMPDIR"] = f"{tmp_root}{os.sep}"
    return environment


def log_event(event: str, **fields: object) -> None:
    """Append one machine-readable event with stable field ordering."""
    global _log_sequence
    with _log_lock:
        _log_sequence += 1
        record = {
            "event": event,
            "seq": _log_sequence,
            "time_unix_ms": time.time_ns() // 1_000_000,
            **fields,
        }
        payload = json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n"
        with open_private_log(OUT) as handle:
            handle.write(payload)
            handle.flush()


def prompt_complete(data: bytes) -> bool:
    return data.rstrip(b"\r\n ").endswith(b">")


def notification_chunks(data: bytes, size: int) -> tuple[bytes, ...]:
    if size <= 0:
        raise ValueError("chunk size must be positive")
    return tuple(data[index : index + size] for index in range(0, len(data), size))


class CommandAssembler:
    """Reassemble arbitrary BLE writes into CR-terminated ELM commands."""

    def __init__(self, max_bytes: int = MAX_COMMAND_BYTES) -> None:
        if max_bytes <= 0:
            raise ValueError("max_bytes must be positive")
        self.max_bytes = max_bytes
        self._pending = bytearray()

    @property
    def pending_size(self) -> int:
        return len(self._pending)

    def clear(self) -> int:
        """Discard a partial command and return its byte count."""
        discarded = len(self._pending)
        self._pending.clear()
        return discarded

    def feed(self, fragment: bytes) -> tuple[bytes, ...]:
        if len(self._pending) + len(fragment) > self.max_bytes:
            self._pending.clear()
            raise BufferError("unterminated ELM command exceeded framing limit")
        self._pending.extend(fragment)
        commands: list[bytes] = []
        while True:
            try:
                end = self._pending.index(0x0D)
            except ValueError:
                return tuple(commands)
            commands.append(bytes(self._pending[: end + 1]))
            del self._pending[: end + 1]


class CentralSessionTracker:
    """Track the one TX-subscribed central allowed to own an ELM session."""

    def __init__(self, tx_uuid: str) -> None:
        self.tx_uuid = tx_uuid.lower()
        self.generation = 0
        self._central_ids: set[str] = set()
        self._contention_latched = False

    @property
    def central_count(self) -> int:
        return len(self._central_ids)

    @property
    def active_central_id(self) -> str | None:
        if self._contention_latched or len(self._central_ids) != 1:
            return None
        return next(iter(self._central_ids))

    @property
    def contention_latched(self) -> bool:
        return self._contention_latched

    def apply(
        self,
        characteristic_uuid: str,
        central_id: str,
        subscribed: bool,
    ) -> bool:
        """Apply an exact CoreBluetooth event; return whether ownership changed."""
        if characteristic_uuid.lower() != self.tx_uuid or not central_id:
            return False
        before = set(self._central_ids)
        if subscribed:
            self._central_ids.add(central_id)
        else:
            self._central_ids.discard(central_id)
        if self._central_ids == before:
            return False
        if len(self._central_ids) > 1:
            self._contention_latched = True
        elif not self._central_ids:
            # Once two centrals overlap, no remaining central may silently
            # inherit a new upstream session. Only an empty set followed by a
            # fresh subscription restores ownership.
            self._contention_latched = False
        self.generation += 1
        return True

    def bind_write(self, central_id: str) -> int | None:
        if self.active_central_id != central_id:
            return None
        return self.generation

    def is_current(self, generation: int, central_id: str) -> bool:
        return generation == self.generation and self.active_central_id == central_id


class NotificationReadiness:
    """Bridge CoreBluetooth's readiness callback into the asyncio worker."""

    def __init__(self, loop: asyncio.AbstractEventLoop) -> None:
        self._loop = loop
        self._event = asyncio.Event()
        self._lock = threading.Lock()
        self._sequence = 0

    def snapshot(self) -> int:
        with self._lock:
            return self._sequence

    def mark_ready(self) -> None:
        with self._lock:
            self._sequence += 1
        self._loop.call_soon_threadsafe(self._event.set)

    async def wait_after(self, sequence: int, timeout: float) -> None:
        while True:
            with self._lock:
                if self._sequence > sequence:
                    return
                self._event.clear()
                # Recheck while holding the same lock used by mark_ready so a
                # callback cannot be lost between observation and clearing.
                if self._sequence > sequence:
                    return
            await asyncio.wait_for(self._event.wait(), timeout=timeout)


def update_value_for_central(
    server: object,
    characteristic_uuid: str,
    value: bytes,
    expected_central_id: str,
) -> bool:
    """Notify exactly one still-subscribed central, never Bless's broadcast."""
    characteristic = server.get_characteristic(characteristic_uuid)
    if characteristic is None:
        raise SessionChangedError("notify characteristic disappeared")
    centrals = list(characteristic.obj.subscribedCentrals() or ())
    if len(centrals) != 1:
        raise SessionChangedError("expected exactly one subscribed central")
    central = centrals[0]
    actual_central_id = str(central.identifier().UUIDString())
    if actual_central_id != expected_central_id:
        raise SessionChangedError("subscribed central changed")
    characteristic.value = value
    manager = server.peripheral_manager_delegate.peripheral_manager
    return bool(
        manager.updateValue_forCharacteristic_onSubscribedCentrals_(
            value,
            characteristic.obj,
            [central],
        )
    )


async def publish_notification(
    update: Callable[[], bool],
    readiness: NotificationReadiness,
    *,
    should_continue: Callable[[], bool] = lambda: True,
    max_retries: int = MAX_NOTIFY_RETRIES,
    timeout: float = MAX_NOTIFY_WAIT_SECONDS,
) -> int:
    """Publish after native readiness callbacks, or fail at fixed boundaries."""
    if max_retries < 0:
        raise ValueError("max_retries must not be negative")
    if timeout <= 0:
        raise ValueError("timeout must be positive")
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    for retries in range(max_retries + 1):
        if not should_continue():
            raise SessionChangedError("BLE central session changed")
        ready_sequence = readiness.snapshot()
        if update():
            return retries
        if retries == max_retries:
            break
        remaining = deadline - loop.time()
        if remaining <= 0:
            break
        try:
            await readiness.wait_after(ready_sequence, remaining)
        except asyncio.TimeoutError:
            break
    raise TimeoutError("CoreBluetooth notification queue stayed full")


async def monitor_advertising(
    probe: Callable[[], bool],
    report: Callable[[bool], None],
    *,
    interval: float = 1.0,
) -> None:
    """Publish fresh health and fail as soon as advertising is lost."""
    if interval <= 0:
        raise ValueError("advertising health interval must be positive")
    while True:
        advertising = probe()
        report(advertising)
        if not advertising:
            raise RuntimeError("CoreBluetooth advertising stopped")
        await asyncio.sleep(interval)


@dataclass(frozen=True)
class FaultConfig:
    response_delay_ms: int = 0
    notify_chunk_size: int = DEFAULT_NOTIFY_CHUNK_SIZE
    upstream_drop_on_command: int = 0

    @classmethod
    def from_strings(
        cls,
        delay: str = "0",
        chunk_size: str = str(DEFAULT_NOTIFY_CHUNK_SIZE),
        drop_on_command: str = "0",
    ) -> "FaultConfig":
        try:
            parsed = cls(int(delay), int(chunk_size), int(drop_on_command))
        except ValueError as exc:
            raise ValueError("fault controls must be integers") from exc
        if not 0 <= parsed.response_delay_ms <= 60_000:
            raise ValueError("response delay must be between 0 and 60000 ms")
        if not 1 <= parsed.notify_chunk_size <= 512:
            raise ValueError("notification chunk size must be between 1 and 512")
        if parsed.upstream_drop_on_command < 0:
            raise ValueError("drop-on-command must be zero or positive")
        return parsed


class ElmLink:
    """One lazy TCP connection; failed exchanges are never replayed."""

    def __init__(
        self,
        host: str = ELM_HOST,
        port: int = ELM_PORT,
        *,
        connect_timeout: float = 5.0,
        read_timeout: float = 6.0,
        socket_factory: Callable[..., socket.socket] = socket.create_connection,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.host = host
        self.port = port
        self.connect_timeout = connect_timeout
        self.read_timeout = read_timeout
        self.socket_factory = socket_factory
        self.clock = clock
        self.sock: socket.socket | None = None

    def connect(self) -> None:
        self.close()
        self.sock = self.socket_factory(
            (self.host, self.port), timeout=self.connect_timeout
        )
        self.sock.settimeout(min(0.4, self.read_timeout))
        log_event("elm_connected", host=self.host, port=self.port)

    def close(self) -> None:
        sock, self.sock = self.sock, None
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass

    def exchange(self, data: bytes) -> bytes:
        """Send once and read a prompt; ambiguous failures close and raise."""
        if self.sock is None:
            self.connect()
        assert self.sock is not None
        try:
            self.sock.sendall(data)
            output = bytearray()
            deadline = self.clock() + self.read_timeout
            while self.clock() < deadline:
                try:
                    chunk = self.sock.recv(4096)
                except socket.timeout:
                    continue
                if not chunk:
                    raise ConnectionError("ELM emulator closed before prompt")
                output.extend(chunk)
                if prompt_complete(output):
                    return bytes(output)
            raise TimeoutError("ELM emulator response timed out before prompt")
        except BaseException:
            # Never reconnect/replay here: sendall may have delivered the
            # command before reporting failure. The next new command may open
            # a fresh connection.
            self.close()
            raise


def create_central_aware_server(name: str):
    """Backport central identity and targeted notifications to bless 0.3.0.

    Imports stay local so framing/unit tests remain runnable on non-macOS
    hosts. The pinned backend receives exact CoreBluetooth central identities,
    but its public API discards them and broadcasts notifications; this small
    adapter preserves the existing callbacks while exposing identity to the
    rig. Refuse any other bless version because these private seams are
    intentionally version-specific.
    """
    from importlib.metadata import version

    from CoreBluetooth import CBATTErrorSuccess
    from bless import BlessServer
    from bless.backends.corebluetooth.peripheral_manager_delegate import (
        PeripheralManagerDelegate,
    )
    from bless.backends.server import BaseBlessServer

    if version("bless") != "0.3.0":
        raise RuntimeError("central-aware adapter requires bless 0.3.0")

    class CentralAwarePeripheralManagerDelegate(PeripheralManagerDelegate):
        def peripheralManagerIsReadyToUpdateSubscribers_(self, manager):
            callback = getattr(self, "notification_ready_func", None)
            if callback is not None:
                callback()

        def peripheralManager_central_didSubscribeToCharacteristic_(
            self,
            manager,
            central,
            characteristic,
        ):
            central_id = str(central.identifier().UUIDString())
            characteristic_uuid = str(characteristic.UUID().UUIDString())
            values = self._central_subscriptions.setdefault(central_id, [])
            if characteristic_uuid not in values:
                values.append(characteristic_uuid)
            callback = getattr(self, "subscription_event_func", None)
            if callback is not None:
                callback(characteristic_uuid, central_id, True)

        def peripheralManager_central_didUnsubscribeFromCharacteristic_(
            self,
            manager,
            central,
            characteristic,
        ):
            central_id = str(central.identifier().UUIDString())
            characteristic_uuid = str(characteristic.UUID().UUIDString())
            values = self._central_subscriptions.get(central_id)
            if values is not None and characteristic_uuid in values:
                values.remove(characteristic_uuid)
                if not values:
                    self._central_subscriptions.pop(central_id, None)
            callback = getattr(self, "subscription_event_func", None)
            if callback is not None:
                callback(characteristic_uuid, central_id, False)

        def peripheralManager_didReceiveWriteRequests_(self, manager, requests):
            for request in requests:
                characteristic_uuid = str(
                    request.characteristic().UUID().UUIDString()
                )
                central_id = str(request.central().identifier().UUIDString())
                value = bytearray(request.value())
                callback = getattr(self, "central_write_request_func", None)
                if callback is None:
                    self.write_request_func(characteristic_uuid, value)
                else:
                    callback(characteristic_uuid, value, central_id)
            if requests:
                manager.respondToRequest_withResult_(
                    requests[0],
                    CBATTErrorSuccess,
                )

    class CentralAwareBlessServer(BlessServer):
        def __init__(self, server_name: str, loop=None, **kwargs) -> None:
            # Do not call BlessServer.__init__: it would allocate an untracked
            # delegate and a second CBPeripheralManager before we replace it.
            BaseBlessServer.__init__(self, loop=loop, **kwargs)
            self.name = server_name
            self.central_write_request_func = None
            self.subscription_event_func = None
            self.notification_ready_func = None
            delegate = CentralAwarePeripheralManagerDelegate.alloc().init()
            delegate.read_request_func = self.read_request
            delegate.write_request_func = self.write_request
            delegate.central_write_request_func = self._route_central_write
            delegate.subscription_event_func = self._route_subscription
            delegate.notification_ready_func = self._route_notification_ready
            self.peripheral_manager_delegate = delegate

        def _route_central_write(
            self,
            characteristic_uuid,
            value,
            central_id,
        ) -> None:
            callback = self.central_write_request_func
            if callback is None:
                self.write_request(characteristic_uuid, value)
                return
            callback(characteristic_uuid, value, central_id)

        def _route_subscription(
            self,
            characteristic_uuid,
            central_id,
            subscribed,
        ) -> None:
            callback = self.subscription_event_func
            if callback is not None:
                callback(characteristic_uuid, central_id, subscribed)

        def _route_notification_ready(self) -> None:
            callback = self.notification_ready_func
            if callback is not None:
                callback()

    return CentralAwareBlessServer(name)


async def run_bridge(
    seconds: int,
    pid_file: Path,
    faults: FaultConfig,
    ownership_token: str,
    controller_tmp_root: Path,
) -> None:
    from bless import (
        GATTAttributePermissions,
        GATTCharacteristicProperties,
    )

    pid_file.write_text(f"{os.getpid()} {ownership_token}\n", encoding="ascii")
    log_event(
        "bridge_started",
        pid=os.getpid(),
        faults=faults.__dict__,
    )
    link = ElmLink()
    server = create_central_aware_server("TelltaleELM")
    queue: asyncio.Queue[tuple[int, str, int, bytes]] = asyncio.Queue(
        MAX_PENDING_WRITES
    )
    assembler = CommandAssembler()
    sessions = CentralSessionTracker(TX)
    next_command_id = 0
    upstream_faulted_generation: int | None = None
    event_loop = asyncio.get_running_loop()
    notification_readiness = NotificationReadiness(event_loop)

    def advertising_state() -> bool:
        manager = server.peripheral_manager_delegate.peripheral_manager
        return bool(manager.isAdvertising())

    def report_advertising(advertising: bool) -> None:
        log_event(
            "advertising_health",
            pid=os.getpid(),
            is_advertising=advertising,
        )

    def apply_subscription(
        characteristic_uuid: str,
        central_id: str,
        subscribed: bool,
    ) -> None:
        nonlocal upstream_faulted_generation
        changed = sessions.apply(
            characteristic_uuid,
            central_id,
            subscribed,
        )
        log_event(
            "subscription_state",
            subscribed=subscribed,
            central_id=central_id,
            characteristic_uuid=characteristic_uuid,
            central_count=sessions.central_count,
            generation=sessions.generation,
            ownership_changed=changed,
        )
        if changed:
            upstream_faulted_generation = None
            discarded = assembler.clear()
            link.close()
            log_event(
                "central_session_reset",
                generation=sessions.generation,
                active_central_id=sessions.active_central_id,
                central_count=sessions.central_count,
                discarded_partial_bytes=discarded,
            )

    def session_is_current(generation: int, central_id: str) -> bool:
        return sessions.is_current(generation, central_id)

    await server.add_new_service(SVC)
    await server.add_new_characteristic(
        SVC,
        RX,
        GATTCharacteristicProperties.write
        | GATTCharacteristicProperties.write_without_response,
        None,
        GATTAttributePermissions.writeable,
    )
    await server.add_new_characteristic(
        SVC,
        TX,
        GATTCharacteristicProperties.notify,
        None,
        GATTAttributePermissions.readable,
    )

    async def process_writes() -> None:
        nonlocal upstream_faulted_generation
        while True:
            generation, central_id, command_id, data = await queue.get()
            try:
                if not session_is_current(generation, central_id):
                    log_event(
                        "command_discarded_stale_session",
                        command_id=command_id,
                        generation=generation,
                        current_generation=sessions.generation,
                        central_id=central_id,
                    )
                    continue
                if upstream_faulted_generation == generation:
                    log_event(
                        "command_rejected_upstream_fault",
                        command_id=command_id,
                        generation=generation,
                        central_id=central_id,
                    )
                    continue
                log_event(
                    "central_write",
                    command_id=command_id,
                    generation=generation,
                    central_id=central_id,
                    size=len(data),
                    data_hex=data.hex(),
                )
                if faults.upstream_drop_on_command == command_id:
                    link.close()
                    upstream_faulted_generation = generation
                    log_event(
                        "upstream_tcp_drop",
                        command_id=command_id,
                        generation=generation,
                        central_id=central_id,
                    )
                    continue
                try:
                    reply = await asyncio.to_thread(link.exchange, data)
                except Exception:
                    # An ELM TCP failure makes adapter state unknowable. Do not
                    # silently create a fresh emulator session for later BLE
                    # writes; require the app to disconnect/reconnect first.
                    if session_is_current(generation, central_id):
                        upstream_faulted_generation = generation
                    raise
                if not session_is_current(generation, central_id):
                    log_event(
                        "response_discarded_stale_session",
                        command_id=command_id,
                        generation=generation,
                        current_generation=sessions.generation,
                        central_id=central_id,
                    )
                    continue
                if faults.response_delay_ms:
                    await asyncio.sleep(faults.response_delay_ms / 1000)
                if not session_is_current(generation, central_id):
                    log_event(
                        "response_discarded_stale_session",
                        command_id=command_id,
                        generation=generation,
                        current_generation=sessions.generation,
                        central_id=central_id,
                    )
                    continue
                chunks = notification_chunks(reply, faults.notify_chunk_size)
                for index, chunk in enumerate(chunks):
                    if not session_is_current(generation, central_id):
                        raise SessionChangedError(
                            "BLE central changed before reply completed"
                        )
                    # Wait for CoreBluetooth's native readiness callback after
                    # a rejected update. Every attempt revalidates the session
                    # and resolves the one exact central; the backend's
                    # broadcast path is intentionally never used.
                    retries = await publish_notification(
                        lambda: update_value_for_central(
                            server,
                            TX,
                            chunk,
                            central_id,
                        ),
                        notification_readiness,
                        should_continue=lambda: session_is_current(
                            generation,
                            central_id,
                        ),
                    )
                    log_event(
                        "notify_chunk",
                        command_id=command_id,
                        chunk_index=index,
                        chunk_count=len(chunks),
                        size=len(chunk),
                        data_hex=chunk.hex(),
                        backpressure_retries=retries,
                    )
                    # Preserve order while yielding to CoreBluetooth between
                    # notifications instead of blocking its callback thread.
                    await asyncio.sleep(0)
            except SessionChangedError as exc:
                log_event(
                    "response_discarded_stale_session",
                    command_id=command_id,
                    generation=generation,
                    current_generation=sessions.generation,
                    central_id=central_id,
                    error=str(exc),
                )
            except Exception as exc:
                log_event(
                    "command_error",
                    command_id=command_id,
                    central_id=central_id,
                    error_type=type(exc).__name__,
                    error=str(exc),
                )
            finally:
                queue.task_done()

    def handle_fragment(
        characteristic_uuid: str,
        central_id: str,
        fragment: bytes,
    ) -> None:
        nonlocal next_command_id
        if characteristic_uuid.lower() != RX.lower():
            log_event(
                "write_rejected_wrong_characteristic",
                characteristic_uuid=characteristic_uuid,
                central_id=central_id,
                size=len(fragment),
            )
            return
        generation = sessions.bind_write(central_id)
        if generation is None:
            log_event(
                "write_rejected_central_ownership",
                central_id=central_id,
                central_count=sessions.central_count,
                size=len(fragment),
            )
            return
        try:
            commands = assembler.feed(fragment)
        except BufferError as exc:
            log_event("framing_error", central_id=central_id, error=str(exc))
            return
        for command in commands:
            next_command_id += 1
            command_id = next_command_id
            try:
                queue.put_nowait(
                    (generation, central_id, command_id, command)
                )
            except asyncio.QueueFull:
                log_event(
                    "command_rejected_backpressure",
                    command_id=command_id,
                    central_id=central_id,
                    size=len(command),
                )
                break

    def on_write(
        characteristic_uuid: str,
        value: bytes,
        central_id: str,
    ) -> None:
        event_loop.call_soon_threadsafe(
            handle_fragment,
            characteristic_uuid,
            central_id,
            bytes(value),
        )

    def on_subscription(
        characteristic_uuid: str,
        central_id: str,
        subscribed: bool,
    ) -> None:
        event_loop.call_soon_threadsafe(
            apply_subscription,
            characteristic_uuid,
            central_id,
            subscribed,
        )

    # The custom delegate always supplies central identity. Keep the legacy
    # callback defined only so a missing hook fails closed rather than raising
    # on CoreBluetooth's dispatch queue.
    server.write_request_func = lambda characteristic, value: log_event(
        "write_rejected_missing_central_identity",
        size=len(value),
    )
    server.central_write_request_func = on_write
    server.subscription_event_func = on_subscription
    server.notification_ready_func = notification_readiness.mark_ready
    server.read_request_func = lambda characteristic, **kw: characteristic.value
    worker = asyncio.create_task(process_writes(), name="process_writes")
    tasks: list[asyncio.Task[object]] = [worker]
    try:
        start_result = await server.start()
        advertising = False
        try:
            advertising = advertising_state()
        except Exception as exc:
            log_event("advertising_probe_error", error=str(exc))
        log_event(
            "advertising_state",
            is_advertising=advertising,
            start_result=start_result,
        )
        if not advertising:
            raise RuntimeError("CoreBluetooth did not enter advertising state")
        health = asyncio.create_task(
            monitor_advertising(advertising_state, report_advertising),
            name="monitor_advertising",
        )
        lifetime = asyncio.create_task(
            asyncio.sleep(seconds),
            name="rig_lifetime",
        )
        tasks.extend((health, lifetime))
        done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        if lifetime not in done:
            completed = next(iter(done))
            await completed
            raise RuntimeError(f"bridge task {completed.get_name()} stopped early")
    finally:
        for task in tasks:
            task.cancel()
        results = await asyncio.gather(*tasks, return_exceptions=True)
        for task, result in zip(tasks, results):
            if isinstance(result, BaseException) and not isinstance(
                result,
                asyncio.CancelledError,
            ):
                log_event(
                    "background_task_error",
                    task=task.get_name(),
                    error_type=type(result).__name__,
                    error=str(result),
                )
        link.close()
        try:
            await server.stop()
            log_event("bridge_stopped")
        finally:
            try:
                pid_file.unlink()
            except FileNotFoundError:
                pass
            # The ELM emulator is an independent daemon. On natural timeout or
            # a bridge startup failure, ask the token-gated shell controller to
            # stop only the emulator from this run. A manual --stop sends
            # SIGTERM to this process and separately performs the same cleanup.
            controller = Path(__file__).with_name("run.sh")
            expiry_environment = controller_expiry_environment(controller_tmp_root)
            completed = await asyncio.to_thread(
                subprocess.run,
                [str(controller), "--expire", ownership_token],
                capture_output=True,
                text=True,
                env=expiry_environment,
                # Another controller may be finishing its hash-checked host
                # setup under the global lock. Wait longer than the lock's
                # bounded acquisition rather than abandoning this emulator.
                timeout=70,
                check=False,
            )
            log_event(
                "emulator_expiry",
                returncode=completed.returncode,
                stdout=completed.stdout.strip(),
                stderr=completed.stderr.strip(),
            )
            if completed.returncode != 0:
                raise RuntimeError(
                    "owned ELM emulator cleanup failed: "
                    f"{completed.stderr.strip()}"
                )


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 7:
        raise SystemExit(
            "usage: bridge.py SECONDS PID_FILE DELAY_MS CHUNK_SIZE "
            "UPSTREAM_DROP_ON_COMMAND OWNERSHIP_TOKEN CONTROLLER_TMP_ROOT"
        )
    seconds = int(args[0])
    if seconds <= 0:
        raise SystemExit("SECONDS must be positive")
    faults = FaultConfig.from_strings(*args[2:5])
    os.umask(0o077)
    with open_private_log(OUT, truncate=True):
        pass
    try:
        asyncio.run(
            run_bridge(seconds, Path(args[1]), faults, args[5], Path(args[6]))
        )
        return 0
    except Exception:
        log_event("fatal", traceback=traceback.format_exc())
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
