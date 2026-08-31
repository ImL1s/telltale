/// Capability gating for Classic + desktop SPP serial transport.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/core/serial/spp_serial_platform.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/obd/transport/serial_transport.dart';
import 'package:torque_obd/ui/screens/connect/connect_screen.dart';

class _FakeSppSession implements SppSerialSession {
  _FakeSppSession({
    this.ports = const [],
    this.openError,
  });

  final List<SppSerialPortInfo> ports;
  final Object? openError;
  final inboundController = StreamController<List<int>>.broadcast();
  final written = <List<int>>[];
  var openCount = 0;
  var closeCount = 0;
  String? openedPort;
  int? openedBaud;

  @override
  Stream<List<int>> get inbound => inboundController.stream;

  @override
  Future<List<SppSerialPortInfo>> listBluetoothSppPorts() async => ports;

  @override
  Future<void> open({
    required String portName,
    int baudRate = 38400,
  }) async {
    openCount++;
    openedPort = portName;
    openedBaud = baudRate;
    if (openError != null) throw openError!;
  }

  @override
  Future<void> write(List<int> data) async {
    written.add(List<int>.from(data));
  }

  @override
  Future<void> close() async {
    closeCount++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    sppSerialHostOverride = null;
  });

  group('classicTransportAvailable', () {
    test('stays closed when neither Android nor SPP serial host', () {
      sppSerialHostOverride = false;
      // This macOS CI host is not Android; override forces desktop SPP off.
      expect(classicTransportAvailable, isFalse);
      expect(classicUnavailableReason, isNot(contains('僅在 Android 驗證過')));
    });

    test('opens when desktop SPP serial host is asserted', () {
      sppSerialHostOverride = true;
      expect(classicTransportAvailable, isTrue);
    });

    test('unavailable copy names macOS honestly when gated', () {
      sppSerialHostOverride = false;
      expect(
        classicUnavailableReason.contains('iOS') ||
            classicUnavailableReason.contains('macOS') ||
            classicUnavailableReason.contains('Android'),
        isTrue,
      );
      expect(classicUnavailableReason, isNot(contains('Linux Classic')));
    });
  });

  group('SerialTransport', () {
    test('maps Bluetooth COM ports to Classic discovered devices', () async {
      final session = _FakeSppSession(
        ports: const [
          SppSerialPortInfo(
            portName: 'COM7',
            friendlyName: 'Standard Serial over Bluetooth link (COM7)',
            hardwareId: 'BTHENUM\\{00001101...}',
          ),
        ],
      );
      final devices = await SerialTransport.bluetoothSppDevices(session: session);
      expect(devices, hasLength(1));
      expect(devices.single.id, 'COM7');
      expect(devices.single.kind, TransportKind.bluetoothClassic);
      expect(devices.single.isPaired, isTrue);
      expect(devices.single.name, contains('Bluetooth'));
    });

    test('maps Linux RFCOMM nodes to Classic discovered devices', () async {
      final session = _FakeSppSession(
        ports: const [
          SppSerialPortInfo(
            portName: '/dev/rfcomm0',
            friendlyName: 'Bluetooth RFCOMM (/dev/rfcomm0)',
            hardwareId: 'linux-rfcomm',
          ),
        ],
      );
      final devices = await SerialTransport.bluetoothSppDevices(session: session);
      expect(devices.single.id, '/dev/rfcomm0');
      expect(devices.single.kind, TransportKind.bluetoothClassic);
      expect(devices.single.name, contains('rfcomm'));
    });

    test('connect opens the COM port and streams inbound bytes', () async {
      final session = _FakeSppSession();
      final transport = SerialTransport(
        portName: 'COM3',
        displayLabel: 'OBDBLE',
        session: session,
      );
      await transport.connect();
      expect(transport.isConnected, isTrue);
      expect(session.openedPort, 'COM3');
      expect(session.openedBaud, 38400);

      final first = transport.incoming.first;
      session.inboundController.add([0x41, 0x54]);
      expect(await first, [0x41, 0x54]);

      await transport.write([0x41, 0x54, 0x5a]);
      expect(session.written.single, [0x41, 0x54, 0x5a]);

      await transport.disconnect();
      expect(transport.isConnected, isFalse);
      expect(session.closeCount, greaterThan(0));
    });

    test('open failure surfaces a driver-facing TransportException', () async {
      final session = _FakeSppSession(openError: Exception('access denied'));
      final transport = SerialTransport(
        portName: 'COM9',
        session: session,
      );
      await expectLater(
        transport.connect(),
        throwsA(
          isA<TransportException>().having(
            (e) => e.message,
            'message',
            contains('無法開啟'),
          ),
        ),
      );
      expect(transport.isConnected, isFalse);
    });

    test('inbound stream errors mark the Classic link disconnected', () async {
      final session = _FakeSppSession();
      final transport = SerialTransport(
        portName: 'COM4',
        displayLabel: 'OBDBLE',
        session: session,
      );
      await transport.connect();
      expect(transport.isConnected, isTrue);

      // Mirrors the native ReadLoop: permanent ReadFile failures Error the
      // EventChannel so SerialTransport can drop the session instead of
      // spinning on a dead COM handle.
      session.inboundController.addError(
        PlatformException(code: 'read_failed', message: 'ReadFile failed'),
      );
      await pumpEventQueue();
      expect(transport.isConnected, isFalse);
    });

    test('write before connect is WriteRefusedException', () async {
      final transport = SerialTransport(
        portName: 'COM1',
        session: _FakeSppSession(),
      );
      await expectLater(
        transport.write([1]),
        throwsA(isA<WriteRefusedException>()),
      );
    });
  });

  group('MethodChannelSppSerialSession', () {
    const methods = MethodChannel(MethodChannelSppSerialSession.methodChannelName);

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methods, null);
    });

    test('listPorts maps native maps into SppSerialPortInfo', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methods, (call) async {
        expect(call.method, 'listPorts');
        return [
          {
            'portName': 'COM5',
            'friendlyName': 'Standard Serial over Bluetooth link (COM5)',
            'hardwareId': 'BTHENUM\\x',
          },
        ];
      });
      final session = MethodChannelSppSerialSession(methods: methods);
      final ports = await session.listBluetoothSppPorts();
      expect(ports.single.portName, 'COM5');
      expect(ports.single.friendlyName, contains('Bluetooth'));
    });
  });
}
