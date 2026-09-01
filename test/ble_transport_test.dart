/// `BleTransport` against a scripted BLE peripheral.
///
/// These are the first tests this transport has ever had. It could not be
/// tested before: the previous BLE package exposed no seam between the Dart
/// API and the platform channel, so every assertion about a clone's behaviour
/// lived in a comment. `UniversalBle.setInstance` takes a
/// [UniversalBlePlatform], which means the adapter can be *written* — and the
/// project's rule that a simulator must be as strict as real hardware applies
/// here as much as it does to `DemoTransport`.
///
/// So [_FakeBlePlatform] models the things that actually go wrong with ELM327
/// BLE clones, not the happy path: a peripheral that dumps a banner during the
/// CCCD write, one that only supports indications, one advertising a Chinese
/// name, one advertising no name, one that refuses an MTU bump, and one that
/// drops the link halfway through service discovery.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/transport/ble_transport.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:universal_ble/universal_ble.dart';

const _deviceId = 'AA:BB:CC:DD:EE:FF';
const _nordicService = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
const _nordicWrite = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
const _nordicNotify = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';
const _ffe0Service = '0000ffe0-0000-1000-8000-00805f9b34fb';
const _ffe1Both = '0000ffe1-0000-1000-8000-00805f9b34fb';
const _vendorService = '0000abcd-0000-1000-8000-00805f9b34fb';

/// A GATT profile, as `discoverServices` would report it.
BleService _service(
  String uuid,
  List<(String, List<CharacteristicProperty>)> characteristics, {
  String deviceId = _deviceId,
}) {
  return BleService(uuid, [
    for (final (charUuid, props) in characteristics)
      BleCharacteristic.withMetaData(
        deviceId: deviceId,
        serviceId: uuid,
        uuid: charUuid,
        properties: props,
        descriptors: const [],
      ),
  ]);
}

/// The conventional Nordic UART layout: separate write and notify endpoints.
List<BleService> _nordicProfile() => [
      _service(_nordicService, [
        (_nordicWrite, [CharacteristicProperty.writeWithoutResponse]),
        (_nordicNotify, [CharacteristicProperty.notify]),
      ]),
    ];

class _FakeBlePlatform extends UniversalBlePlatform {
  AvailabilityState availability = AvailabilityState.poweredOn;
  Duration? availabilityDelay;

  /// What `discoverServices` reports.
  List<BleService> services = _nordicProfile();

  /// Advertisements to push once a scan starts.
  List<BleDevice> advertisements = const [];

  Object? connectError;
  Object? discoverError;
  Object? mtuError;

  /// Bytes the peripheral emits the *instant* the CCCD is written.
  ///
  /// Real BLE UART clones do this: whatever was buffered, or a ready banner,
  /// arrives as part of enabling notifications rather than after it. A
  /// transport that subscribes to values only once `subscribe()` has returned
  /// loses them, and the visible symptom is a handshake that fails on one
  /// particular adapter for no apparent reason.
  List<int>? bannerOnSubscribe;

  bool scanning = false;
  bool startScanCalled = false;
  int stopScanCalls = 0;
  int disconnectCalls = 0;
  int? requestedMtu;
  final List<BleInputProperty> inputProperties = [];
  final List<({Uint8List value, BleOutputProperty property})> writes = [];
  final Map<String, bool> _connected = {};

  /// Pretend the peripheral went away on its own.
  void dropLink([String deviceId = _deviceId]) {
    _connected[deviceId] = false;
    updateConnection(deviceId, false);
  }

  @override
  Future<AvailabilityState> getBluetoothAvailabilityState() async {
    final delay = availabilityDelay;
    if (delay != null) await Future<void>.delayed(delay);
    return availability;
  }

  @override
  Future<bool> enableBluetooth() async => true;

  @override
  Future<bool> disableBluetooth() async => true;

  @override
  Future<void> startScan({
    ScanFilter? scanFilter,
    PlatformConfig? platformConfig,
  }) async {
    startScanCalled = true;
    scanning = true;
    for (final device in advertisements) {
      updateScanResult(device);
    }
  }

  @override
  Future<void> stopScan() async {
    stopScanCalls++;
    scanning = false;
  }

  @override
  Future<bool> isScanning() async => scanning;

  @override
  Future<void> connect(
    String deviceId, {
    Duration? connectionTimeout,
    bool autoConnect = false,
    ConnectionPlatformConfig? platformConfig,
  }) async {
    if (connectError != null) throw connectError!;
    _connected[deviceId] = true;
    updateConnection(deviceId, true);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    disconnectCalls++;
    _connected[deviceId] = false;
    updateConnection(deviceId, false);
  }

  @override
  Future<List<BleService>> discoverServices(
    String deviceId,
    bool withDescriptors,
  ) async {
    if (discoverError != null) throw discoverError!;
    return services;
  }

  @override
  Future<void> setNotifiable(
    String deviceId,
    String service,
    String characteristic,
    BleInputProperty bleInputProperty,
  ) async {
    inputProperties.add(bleInputProperty);
    final banner = bannerOnSubscribe;
    if (banner != null && bleInputProperty != BleInputProperty.disabled) {
      updateCharacteristicValue(
        deviceId,
        characteristic,
        Uint8List.fromList(banner),
        null,
      );
    }
  }

  @override
  Future<Uint8List> readValue(
    String deviceId,
    String service,
    String characteristic, {
    Duration? timeout,
  }) async =>
      Uint8List(0);

  @override
  Future<void> writeValue(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value,
    BleOutputProperty bleOutputProperty,
  ) async {
    writes.add((value: value, property: bleOutputProperty));
  }

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async {
    requestedMtu = expectedMtu;
    if (mtuError != null) throw mtuError!;
    return expectedMtu;
  }

  @override
  Future<int> readRssi(String deviceId) async => -60;

  @override
  Future<void> requestConnectionPriority(
    String deviceId,
    BleConnectionPriority priority,
  ) async {}

  @override
  Future<bool> isPaired(String deviceId) async => false;

  @override
  Future<bool> pair(String deviceId) async => true;

  @override
  Future<void> unpair(String deviceId) async {}

  @override
  Future<BleConnectionState> getConnectionState(String deviceId) async =>
      (_connected[deviceId] ?? false)
          ? BleConnectionState.connected
          : BleConnectionState.disconnected;

  @override
  Future<List<BleDevice>> getSystemDevices(List<String>? withServices) async =>
      const [];
}

void main() {
  late _FakeBlePlatform fake;

  setUp(() {
    fake = _FakeBlePlatform();
    UniversalBle.setInstance(fake);
  });

  const handle = BleAdapterHandle(id: _deviceId, name: 'OBDII');

  group('connect', () {
    test('a banner emitted during the CCCD write is not lost', () async {
      fake.bannerOnSubscribe = [0x45, 0x4c, 0x4d]; // "ELM"
      final transport = BleTransport(handle);
      final received = <List<int>>[];
      final sub = transport.incoming.listen(received.add);

      await transport.connect();
      // The value arrives on a later microtask than the CCCD write; give the
      // stream one turn to deliver before asserting.
      await Future<void>.delayed(Duration.zero);

      expect(transport.isConnected, isTrue);
      expect(
        received,
        isNotEmpty,
        reason: 'the peripheral spoke while notifications were being enabled, '
            'so subscribing after the await would have dropped its first frame',
      );
      expect(received.first, [0x45, 0x4c, 0x4d]);
      await sub.cancel();
    });

    test('an indicate-only adapter connects', () async {
      // A whole family of clones only ever indicates. The two are different
      // CCCD writes and different calls, each of which throws when the
      // characteristic lacks the matching property — so asking blindly for
      // notifications locks these adapters out entirely.
      fake.services = [
        _service(_ffe0Service, [
          (_ffe1Both, [
            CharacteristicProperty.write,
            CharacteristicProperty.indicate,
          ]),
        ]),
      ];

      final transport = BleTransport(handle);
      await transport.connect();

      expect(transport.isConnected, isTrue);
      expect(fake.inputProperties, [BleInputProperty.indication]);
      expect(
        transport.diagnosticMetadata,
        containsPair('subscriptionKind', 'indication'),
      );
    });

    test('a notify-capable adapter subscribes to notifications', () async {
      final transport = BleTransport(handle);
      await transport.connect();

      expect(fake.inputProperties, [BleInputProperty.notification]);
      expect(transport.diagnosticMetadata, containsPair('requestedMtu', 185));
      expect(
        transport.diagnosticMetadata,
        containsPair('mtuRequestOutcome', 'succeeded'),
      );
      expect(
        transport.diagnosticMetadata,
        containsPair('selectedServiceUuid', _nordicService),
      );
      expect(
        transport.diagnosticMetadata,
        containsPair('selectedWriteCharacteristicUuid', _nordicWrite),
      );
      expect(
        transport.diagnosticMetadata,
        containsPair('selectedNotifyCharacteristicUuid', _nordicNotify),
      );
      expect(
        transport.diagnosticMetadata,
        containsPair('subscriptionKind', 'notification'),
      );
      expect(transport.diagnosticMetadata, isNot(contains('negotiatedMtu')));
    });

    test('a refused MTU costs throughput, not the link', () async {
      // The previous package took the MTU as a connect argument, so a stack
      // that refused it failed the whole connection. A transport that works
      // slowly beats one that does not open.
      fake.mtuError = Exception('MTU negotiation unsupported');

      final transport = BleTransport(handle);
      await transport.connect();

      expect(fake.requestedMtu, 185);
      expect(transport.isConnected, isTrue);
      expect(
        transport.diagnosticMetadata,
        containsPair('mtuRequestOutcome', 'failed'),
      );
    });

    test('a device with no serial endpoint is refused and the link released',
        () async {
      fake.services = [
        _service(_vendorService, [
          (_ffe1Both, [CharacteristicProperty.read]),
        ]),
      ];

      final transport = BleTransport(handle);
      await expectLater(
        transport.connect(),
        throwsA(
          isA<TransportException>().having(
            (e) => e.message,
            'message',
            contains('沒有可用的序列埠特徵值'),
          ),
        ),
      );

      expect(transport.isConnected, isFalse);
      expect(
        fake.disconnectCalls,
        greaterThan(0),
        reason: 'a link held open after a failed setup makes the retry fail '
            'with "already connected"',
      );
    });

    test('a failure during discovery releases the link', () async {
      fake.discoverError = Exception('GATT 133');

      final transport = BleTransport(handle);
      await expectLater(transport.connect(), throwsA(isA<Exception>()));

      expect(transport.isConnected, isFalse);
      expect(fake.disconnectCalls, greaterThan(0));
    });

    test('a refused connection is reported in the driver\'s language',
        () async {
      fake.connectError = Exception('device not found');

      final transport = BleTransport(handle);
      await expectLater(
        transport.connect(),
        throwsA(
          isA<TransportException>().having(
            (e) => e.message,
            'message',
            contains('請確認轉接器已通電且在範圍內'),
          ),
        ),
      );
    });

    test('the preferred UART family wins over an unknown one', () async {
      // Both services can write and notify, so the fallback would accept
      // either. Order must not decide it: a device whose services arrive in a
      // different order between connections would otherwise pick a different
      // endpoint each time.
      fake.services = [
        _service(_vendorService, [
          (_ffe1Both, [
            CharacteristicProperty.write,
            CharacteristicProperty.notify,
          ]),
        ]),
        ..._nordicProfile(),
      ];

      final transport = BleTransport(handle);
      await transport.connect();
      await transport.write([0x01]);

      expect(fake.writes, hasLength(1));
      // Nordic's write endpoint is write-without-response; the vendor one is
      // not, so the property recorded says which service was chosen.
      expect(fake.writes.single.property, BleOutputProperty.withoutResponse);
    });

    test('a dropped link is reported to the session', () async {
      final transport = BleTransport(handle);
      await transport.connect();

      final changes = <bool>[];
      final sub = transport.connectionChanges.listen(changes.add);
      fake.dropLink();
      await Future<void>.delayed(Duration.zero);

      expect(changes, [false]);
      expect(transport.isConnected, isFalse);
      await sub.cancel();
    });
  });

  group('write', () {
    test('refuses before the link is up, and says nothing was sent', () async {
      final transport = BleTransport(handle);
      await expectLater(
        transport.write([0x01]),
        throwsA(isA<WriteRefusedException>()),
      );
      expect(fake.writes, isEmpty);
    });

    test('uses write-without-response when the endpoint allows it', () async {
      final transport = BleTransport(handle);
      await transport.connect();
      await transport.write([0x30, 0x31, 0x30, 0x30, 0x0d]);

      expect(fake.writes.single.property, BleOutputProperty.withoutResponse);
      expect(fake.writes.single.value, [0x30, 0x31, 0x30, 0x30, 0x0d]);
    });

    test('falls back to an acknowledged write when it does not', () async {
      fake.services = [
        _service(_ffe0Service, [
          (_ffe1Both, [
            CharacteristicProperty.write,
            CharacteristicProperty.notify,
          ]),
        ]),
      ];

      final transport = BleTransport(handle);
      await transport.connect();
      await transport.write([0x01]);

      expect(fake.writes.single.property, BleOutputProperty.withResponse);
    });
  });

  group('scanEntries', () {
    test('keeps a non-ASCII adapter name', () async {
      // `BleDevice.name` has already had every non-ASCII character stripped by
      // the package's own constructor, so a Chinese-named adapter arrives with
      // an empty `name` and a full `rawName`. Reading only `name` would show
      // every such adapter as unnamed — the locale assumption this project
      // keeps having to unlearn.
      fake.advertisements = [
        BleDevice(deviceId: _deviceId, name: '藍牙診斷器', rssi: -55),
      ];

      final entries = await BleTransport.scanEntries(
        timeout: const Duration(milliseconds: 50),
      ).toList();

      expect(entries, hasLength(1));
      expect(entries.single.$2, '藍牙診斷器');
      expect(entries.single.$3, -55);
    });

    test('shows the address of an adapter that advertises no name', () async {
      // Cheap clones advertise nothing. Dropping them leaves the user looking
      // at a scan that cannot see hardware a foot away.
      fake.advertisements = [
        BleDevice(deviceId: _deviceId, name: null, rssi: -70),
      ];

      final entries = await BleTransport.scanEntries(
        timeout: const Duration(milliseconds: 50),
      ).toList();

      expect(entries.single.$2, contains(_deviceId));
    });

    test('keeps a missing scan RSSI unknown', () async {
      fake.advertisements = [
        BleDevice(deviceId: _deviceId, name: 'OBDII', rssi: null),
      ];

      final entries = await BleTransport.scanEntries(
        timeout: const Duration(milliseconds: 50),
      ).toList();

      expect(entries.single.$3, isNull);
    });

    test('closes when the scan deadline expires, and stops the radio',
        () async {
      // The scan itself takes no duration: there is no plugin-side timer and
      // no "is scanning" stream to observe. This deadline is the only thing
      // that ends it, so a caller awaiting the stream would otherwise believe
      // a scan is running for the life of the screen.
      fake.advertisements = [
        BleDevice(deviceId: _deviceId, name: 'OBDII', rssi: -60),
      ];

      final stopwatch = Stopwatch()..start();
      await BleTransport.scanEntries(
        timeout: const Duration(milliseconds: 80),
      ).toList();
      stopwatch.stop();

      expect(fake.startScanCalled, isTrue);
      expect(fake.stopScanCalls, greaterThan(0));
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(70));
    });

    test('a radio that is powered off fails immediately with clear copy',
        () async {
      fake.availability = AvailabilityState.poweredOff;

      await expectLater(
        BleTransport.scanEntries(timeout: const Duration(milliseconds: 50))
            .toList(),
        throwsA(
          isA<BleRadioUnavailableException>().having(
            (e) => e.message,
            'message',
            contains('藍牙未開啟'),
          ),
        ),
      );
      expect(fake.startScanCalled, isFalse);
    });

    test('cancelling during availability does not start a global scan',
        () async {
      fake.availabilityDelay = const Duration(milliseconds: 40);
      final subscription = BleTransport.scanEntries(
        timeout: const Duration(seconds: 2),
      ).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await subscription.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(fake.startScanCalled, isFalse);
      expect(fake.scanning, isFalse);
    });

    test('unauthorized radio maps to permission guidance', () async {
      fake.availability = AvailabilityState.unauthorized;

      await expectLater(
        BleTransport.scanEntries(timeout: const Duration(milliseconds: 50))
            .toList(),
        throwsA(
          isA<BleRadioUnavailableException>().having(
            (e) => e.message,
            'message',
            contains('藍牙權限'),
          ),
        ),
      );
    });

    test('BlueZ/D-Bus failures map to service guidance', () {
      expect(
        BleTransport.userFacingScanFailure(
          Exception('org.bluez.Error.Failed: Failed to connect to socket'),
        ),
        contains('BlueZ'),
      );
    });
  });

  group('BleAdapterHandle', () {
    test('rebuilds from a stored address without a scan', () {
      // What the "reconnect to last adapter" shortcut relies on: on a fresh
      // launch there is no scan result to have held on to.
      const remembered = BleAdapterHandle(id: _deviceId, name: 'OBDII');
      expect(BleTransport(remembered).displayName, 'OBDII');
    });

    test('falls back to the address when the remembered name is empty', () {
      const remembered = BleAdapterHandle(id: _deviceId, name: '');
      expect(BleTransport(remembered).displayName, _deviceId);
    });

    test('scan RSSI is evidence, not part of adapter identity', () {
      const first = BleAdapterHandle(id: _deviceId, name: 'OBDII', rssi: -55);
      const later = BleAdapterHandle(id: _deviceId, name: 'OBDII', rssi: -72);

      expect(first, later);
      expect(first.hashCode, later.hashCode);
    });
  });
}
