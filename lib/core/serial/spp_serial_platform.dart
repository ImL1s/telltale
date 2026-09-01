/// Bluetooth SPP ↔ serial-port bridge (Windows COM / Linux RFCOMM TTY).
///
/// On Windows, pairing a Classic ELM327 commonly creates a "Standard Serial
/// over Bluetooth link (COMx)" device. On Linux, BlueZ exposes the same link
/// as `/dev/rfcomm*` (after bind) or a Bluetooth-backed tty node. Desktop OBD
/// tools open that port at 38400 8N1 rather than speaking Winsock `AF_BTH` /
/// BlueZ SDP with an explicit RFCOMM channel — and the fork's
/// `connect(channel:)` remains Android-only.
///
/// This channel is the honest Classic path on Windows/Linux: enumerate
/// Bluetooth-associated serial nodes, then stream bytes. macOS Classic uses
/// IOBluetooth RFCOMM through `flutter_classic_bluetooth` / [ClassicTransport]
/// instead — Apple does not create per-paired-SPP `cu.*` nodes comparable to
/// Windows COM / Linux rfcomm (only the host incoming serial profile and
/// some profile-specific cu.* names appear).
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

/// A serial node the host associates with a Bluetooth SPP/RFCOMM link.
class SppSerialPortInfo {
  const SppSerialPortInfo({
    required this.portName,
    required this.friendlyName,
    this.hardwareId,
  });

  /// e.g. `COM3` or `/dev/rfcomm0` — also the [DiscoveredDevice.id].
  final String portName;

  /// e.g. `Standard Serial over Bluetooth link (COM3)` /
  /// `Bluetooth RFCOMM (/dev/rfcomm0)`.
  final String friendlyName;

  /// Optional PnP / sysfs hardware id (often contains `BTHENUM` or
  /// `linux-rfcomm`).
  final String? hardwareId;

  factory SppSerialPortInfo.fromMap(Map<Object?, Object?> map) {
    final port = map['portName'] as String? ?? '';
    final friendly = map['friendlyName'] as String? ?? port;
    return SppSerialPortInfo(
      portName: port,
      friendlyName: friendly.isEmpty ? port : friendly,
      hardwareId: map['hardwareId'] as String?,
    );
  }
}

/// Opens one Bluetooth SPP serial port and exposes inbound bytes.
abstract interface class SppSerialSession {
  Future<List<SppSerialPortInfo>> listBluetoothSppPorts();

  Future<void> open({
    required String portName,
    int baudRate = 38400,
  });

  Stream<List<int>> get inbound;

  Future<void> write(List<int> data);

  Future<void> close();
}

/// Production adapter over `com.cbstudio.telltale/spp_serial`.
class MethodChannelSppSerialSession implements SppSerialSession {
  MethodChannelSppSerialSession({
    MethodChannel? methods,
    EventChannel? inbound,
  }) : _methods = methods ?? const MethodChannel(methodChannelName),
       _inbound = inbound ?? const EventChannel(eventChannelName);

  static const methodChannelName = 'com.cbstudio.telltale/spp_serial';
  static const eventChannelName = 'com.cbstudio.telltale/spp_serial/inbound';

  final MethodChannel _methods;
  final EventChannel _inbound;
  StreamSubscription<dynamic>? _inboundSub;
  final _controller = StreamController<List<int>>.broadcast();
  var _open = false;

  @override
  Stream<List<int>> get inbound => _controller.stream;

  @override
  Future<List<SppSerialPortInfo>> listBluetoothSppPorts() async {
    final raw = await _methods.invokeMethod<List<dynamic>>('listPorts');
    if (raw == null) return const [];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map(SppSerialPortInfo.fromMap)
        .where((p) => p.portName.isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<void> open({
    required String portName,
    int baudRate = 38400,
  }) async {
    await close();
    // Subscribe before open so a disconnect/error that races the native read
    // thread startup is not dropped while Dart still thinks the port is open.
    _inboundSub = _inbound.receiveBroadcastStream().listen(
      (event) {
        if (event is Uint8List) {
          _controller.add(List<int>.from(event));
        } else if (event is List) {
          _controller.add(event.whereType<int>().toList(growable: false));
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!_controller.isClosed) {
          _controller.addError(error, stack);
        }
      },
    );
    try {
      await _methods.invokeMethod<void>('open', {
        'portName': portName,
        'baudRate': baudRate,
      });
      _open = true;
    } on Object {
      await _inboundSub?.cancel();
      _inboundSub = null;
      rethrow;
    }
  }

  @override
  Future<void> write(List<int> data) async {
    if (!_open) {
      throw StateError('SPP serial port is not open');
    }
    await _methods.invokeMethod<void>('write', {
      'bytes': Uint8List.fromList(data),
    });
  }

  @override
  Future<void> close() async {
    await _inboundSub?.cancel();
    _inboundSub = null;
    if (!_open) return;
    _open = false;
    try {
      await _methods.invokeMethod<void>('close');
    } on MissingPluginException {
      // Host without the channel (tests / non-desktop).
    } on Object {
      // Best-effort close.
    }
  }
}

/// Whether this host ships the desktop SPP serial Classic path (Windows COM
/// and/or Linux RFCOMM TTY).
///
/// Override in tests — do not mock [Platform.isWindows] / [Platform.isLinux]
/// globally.
@visibleForTesting
bool? sppSerialHostOverride;

bool get sppSerialHostSupported =>
    sppSerialHostOverride ?? (Platform.isWindows || Platform.isLinux);
