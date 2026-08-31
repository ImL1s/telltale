/// Capability gating for Classic + Windows SPP serial transport.
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
    windowsSppSerialHostOverride = null;
  });

  group('classicTransportAvailable', () {
    test('stays closed when neither Android nor Windows SPP host', () {
      windowsSppSerialHostOverride = false;
      // This macOS/Linux CI host is not Android; override forces Windows off.
      expect(classicTransportAvailable, isFalse);
      expect(classicUnavailableReason, isNot(contains('僅在 Android 驗證過')));
    });

    test('opens when Windows SPP host is asserted', () {
      windowsSppSerialHostOverride = true;
      expect(classicTransportAvailable, isTrue);
    });

    test('unavailable copy names macOS/Linux honestly when gated', () {
      windowsSppSerialHostOverride = false;
      expect(
        classicUnavailableReason.contains('iOS') ||
            classicUnavailableReason.contains('macOS') ||
            classicUnavailableReason.contains('Linux') ||
            classicUnavailableReason.contains('Android'),
        isTrue,
      );
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
