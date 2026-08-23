/// Transport abstraction over the four physical links Torque supports:
/// Bluetooth Classic RFCOMM, Bluetooth LE, Wi-Fi TCP, plus a built-in
/// simulator.
///
/// Transports deal only in bytes. Prompt framing, the AT handshake and the
/// error matrix all live in `Elm327Client`, so every link shares one
/// implementation of the tricky parts.
library;

import 'dart:async';

enum TransportKind {
  bluetoothClassic('Bluetooth Classic', 'RFCOMM / SPP — 最常見的平價 ELM327'),
  bluetoothLe('Bluetooth LE', 'GATT UART — 較新的低功耗轉接器'),
  wifi('Wi-Fi', 'TCP 通訊埠，多為 192.168.0.10:35000'),
  demo('Demo 模擬器', '內建模擬 ECU，無需硬體即可完整體驗');

  const TransportKind(this.label, this.description);

  final String label;
  final String description;

  /// Bluetooth Classic SPP is Android-only in practice: iOS does not expose
  /// RFCOMM to third-party apps outside MFi.
  bool get isAndroidOnly => this == TransportKind.bluetoothClassic;
}

/// A link the user can pick in the connection wizard.
class DiscoveredDevice {
  final String id;
  final String name;
  final TransportKind kind;

  /// Signal strength in dBm where the link reports it, else null.
  final int? rssi;

  /// True when the OS already has a bond with this device.
  final bool isPaired;

  const DiscoveredDevice({
    required this.id,
    required this.name,
    required this.kind,
    this.rssi,
    this.isPaired = false,
  });

  /// Rough 0–4 bar strength from RSSI, or null when there is no RSSI to judge.
  ///
  /// Null rather than four. This returned *full strength* for a device with no
  /// signal reading at all — and a bonded Classic device has none until
  /// something scans, which is most of the list most of the time. Unknown
  /// rendered as best is the failure this whole codebase is arranged against,
  /// arriving in the one place it would be dismissed as cosmetic: it is the
  /// bar somebody uses to pick which of five similarly-named devices is the
  /// one in the car in front of them.
  ///
  /// Thresholds are the conventional Wi-Fi/BLE ones: −55 excellent, −67 good,
  /// −78 fair, −90 the edge of usable.
  int? get signalBars {
    final value = rssi;
    if (value == null) return null;
    if (value >= -55) return 4;
    if (value >= -67) return 3;
    if (value >= -78) return 2;
    if (value >= -90) return 1;
    return 0;
  }

  @override
  bool operator ==(Object other) =>
      other is DiscoveredDevice && other.id == id && other.kind == kind;

  @override
  int get hashCode => Object.hash(id, kind);
}

/// Raised for link-level failures. The connection wizard shows [message]
/// verbatim, so it is written for a driver rather than a developer.
class TransportException implements Exception {
  final String message;
  final Object? cause;

  const TransportException(this.message, [this.cause]);

  @override
  String toString() => 'TransportException: $message';
}

/// The transport refused a write before any byte left the app.
///
/// Every transport opens `write` with the same precondition — no socket, no
/// characteristic, no connection — and it is the one point in the stack where
/// "nothing was transmitted" is a fact rather than an inference. Everything
/// deeper has already handed bytes to an OS buffer, a GATT queue or an RFCOMM
/// stream, and a failure there says nothing about whether the adapter saw
/// them.
///
/// The distinction is not academic. `PollingEngine.clearDtcs` decides from the
/// write audit whether repeating a global Mode 04 could reach a controller
/// that has already erased its memory. Without this type the audit had to
/// record the command *before* calling `write`, so a write rejected at the
/// guard was reported as "sent, do not retry" — locking the button on a clear
/// that had provably not happened, and stranding somebody who could safely
/// have tapped it again.
///
/// Recording before the write stays the default, because that is the
/// conservative direction: an unknown failure must read as possibly-sent. This
/// only subtracts the cases where the transport itself says otherwise.
class WriteRefusedException extends TransportException {
  const WriteRefusedException(super.message);
}

/// The request cannot be addressed on this bus, and retrying will not help.
///
/// Separate from its parent because the polling loop treats a
/// [TransportException] as a timeout — yield, let the watchdog recover, try
/// again — which is right for a link that dropped and wrong for a structural
/// condition. Retried silently, this one produces a gauge that is dark forever
/// with nothing on screen to say why, which is the failure it was raised to
/// prevent.
/// The operation's owner expired before its bytes went out.
///
/// A distinct type because it is not a failure of the link or the vehicle:
/// nothing was transmitted and nothing is wrong. Callers that would otherwise
/// mark a PID faulty or a scan broken should recognise it as "the app stopped
/// asking", which is what it is.
class OperationRetiredException extends TransportException {
  const OperationRetiredException(super.message);

  @override
  String toString() => 'OperationRetiredException: $message';
}

class UnaddressableRequestException extends TransportException {
  const UnaddressableRequestException(super.message);

  @override
  String toString() => 'UnaddressableRequestException: $message';
}

abstract class ObdTransport {
  TransportKind get kind;

  /// Human-readable identity of what we are connected to.
  String get displayName;

  /// Stable, read-only facts already known about this transport.
  ///
  /// Implementations must not perform I/O to populate this projection. Keys
  /// are emitted in a deterministic order so exported diagnostics remain
  /// readable and diffable. Device identifiers are verbatim platform values,
  /// not anonymized identifiers.
  Map<String, Object> get diagnosticMetadata;

  bool get isConnected;

  /// Raw bytes as they arrive. Chunk boundaries are arbitrary — BLE in
  /// particular splits replies across notifications — so consumers must
  /// reassemble rather than assume one chunk is one reply.
  Stream<List<int>> get incoming;

  /// Emits false when the link drops so the UI can react without polling.
  Stream<bool> get connectionChanges;

  Future<void> connect();

  Future<void> disconnect();

  Future<void> write(List<int> data);
}

/// Shared plumbing: broadcast controllers and connection bookkeeping that all
/// four transports need identically.
abstract class BaseObdTransport implements ObdTransport {
  final _incoming = StreamController<List<int>>.broadcast();
  final _connectionChanges = StreamController<bool>.broadcast();
  bool _connected = false;

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  @override
  Stream<bool> get connectionChanges => _connectionChanges.stream;

  @override
  bool get isConnected => _connected;

  /// Test and simulator transports have no link-specific metadata by default.
  @override
  Map<String, Object> get diagnosticMetadata => const {};

  /// Publishes received bytes to listeners.
  void emitBytes(List<int> data) {
    if (!_incoming.isClosed && data.isNotEmpty) _incoming.add(data);
  }

  /// Records a connection state change, ignoring no-op transitions.
  void setConnected(bool value) {
    if (_connected == value) return;
    _connected = value;
    if (!_connectionChanges.isClosed) _connectionChanges.add(value);
  }

  /// Releases the controllers. Subclasses must call this from [disconnect]
  /// only when the transport is being discarded, not on a transient drop.
  Future<void> disposeStreams() async {
    await _incoming.close();
    await _connectionChanges.close();
  }
}
