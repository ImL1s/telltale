import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/transport/ble_transport.dart';
import 'package:torque_obd/obd/transport/classic_transport.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/obd/transport/wifi_transport.dart';

class _MinimalTransport extends BaseObdTransport {
  @override
  String get displayName => 'fake';

  @override
  TransportKind get kind => TransportKind.demo;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> write(List<int> data) async {}
}

void main() {
  test('base transports expose empty diagnostic metadata by default', () {
    expect(_MinimalTransport().diagnosticMetadata, isEmpty);
  });

  test('Wi-Fi metadata contains only the configured endpoint', () {
    final transport = WifiTransport(host: '192.168.4.1', port: 23);

    expect(transport.diagnosticMetadata.keys, ['host', 'port']);
    expect(transport.diagnosticMetadata, {'host': '192.168.4.1', 'port': 23});
    expect(
      () => transport.diagnosticMetadata['ssid'] = 'OBDII',
      throwsUnsupportedError,
    );
  });

  test('Classic metadata labels the address as an identifier and paired', () {
    final transport = ClassicTransport(
      address: 'AA:BB:CC:DD:EE:FF',
      name: 'OBDII',
    );

    expect(transport.diagnosticMetadata.keys, [
      'deviceIdentifier',
      'deviceName',
      'paired',
    ]);
    expect(transport.diagnosticMetadata, {
      'deviceIdentifier': 'AA:BB:CC:DD:EE:FF',
      'deviceName': 'OBDII',
      'paired': true,
    });
  });

  test('BLE metadata includes only scan RSSI carried by the handle', () {
    final transport = BleTransport(
      const BleAdapterHandle(id: 'AA:BB:CC:DD:EE:FF', name: 'OBDII', rssi: -61),
    );

    expect(transport.diagnosticMetadata, {
      'deviceIdentifier': 'AA:BB:CC:DD:EE:FF',
      'deviceName': 'OBDII',
      'scanRssiDbm': -61,
      'requestedMtu': 185,
      'mtuRequestOutcome': 'notAttempted',
    });
    expect(transport.diagnosticMetadata, isNot(contains('negotiatedMtu')));
  });
}
