/// macOS Classic uses IOBluetooth RFCOMM through flutter_classic_bluetooth —
/// not the Windows/Linux SPP serial channel. These tests pin the product gate
/// and the plugin method-channel contract the wizard/session rely on.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/core/serial/spp_serial_platform.dart';
import 'package:torque_obd/obd/transport/classic_transport.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/ui/screens/connect/connect_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel('flutter_classic_bluetooth/methods');

  tearDown(() {
    sppSerialHostOverride = null;
    classicIoBluetoothHostOverride = null;
    ClassicTransport.attemptsForTest = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, null);
  });

  test('macOS Classic gate is open without SPP serial host', () {
    // analyze/test CI is Linux; Apple smoke is macOS. Assert the IOBluetooth
    // host gate via the test seam — not Platform.isMacOS — so the contract
    // holds on every runner. This is not a field radio pass.
    classicIoBluetoothHostOverride = true;
    sppSerialHostOverride = false;
    expect(classicIoBluetoothHostSupported, isTrue);
    expect(sppSerialHostSupported, isFalse);
    expect(classicTransportAvailable, isTrue);
    expect(classicUnavailableReason, isNot(contains('暫不開放')));
  });

  test('macOS cascade is a single IOBluetooth UUID open', () {
    ClassicTransport.attemptsForTest = null;
    expect(ClassicTransport.macOsAttempts, hasLength(1));
    expect(ClassicTransport.macOsAttempts.single.channel, isNull);
    expect(ClassicTransport.androidAttempts, hasLength(3));
  });

  test('pairedDevices maps plugin bonded rows and fails closed on empty',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
      switch (call.method) {
        case 'getPairedDevices':
          return <Object?>[];
        case 'isEnabled':
          return true;
        case 'isSupported':
          return true;
        default:
          return null;
      }
    });

    final empty = await ClassicTransport.pairedDevices();
    expect(empty, isEmpty);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'getPairedDevices') {
        return [
          {
            'address': 'AA:BB:CC:11:22:33',
            'name': 'OBDBLE',
            'rssi': null,
            'bondState': 'bonded',
            'type': 'classic',
            'uuids': <String>[],
          },
        ];
      }
      return null;
    });

    final devices = await ClassicTransport.pairedDevices();
    expect(devices, hasLength(1));
    expect(devices.single.id, 'AA:BB:CC:11:22:33');
    expect(devices.single.name, 'OBDBLE');
    expect(devices.single.kind, TransportKind.bluetoothClassic);
    expect(devices.single.isPaired, isTrue);
  });

  test('adapter powered-off is reported honestly', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'isEnabled') return false;
      return null;
    });
    expect(await ClassicTransport.isAdapterEnabled(), isFalse);
  });
}
