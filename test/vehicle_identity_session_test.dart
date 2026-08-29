import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/obd/transport/demo_transport.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_registry.dart';
import 'package:torque_obd/state/vehicle_identity.dart';

Future<ProviderContainer> _container() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
}

class _DelayedVinTransport extends DemoTransport {
  final vinStarted = Completer<void>();
  final _releaseVin = Completer<void>();

  void releaseVin() {
    if (!_releaseVin.isCompleted) _releaseVin.complete();
  }

  @override
  Future<void> write(List<int> data) async {
    final command = ascii
        .decode(data, allowInvalid: true)
        .trim()
        .toUpperCase()
        .replaceAll(' ', '');
    if (command == '0902') {
      if (!vinStarted.isCompleted) vinStarted.complete();
      await _releaseVin.future;
    }
    await super.write(data);
  }
}

class _ProgrammingErrorVinTransport extends DemoTransport {
  @override
  Future<void> write(List<int> data) async {
    final command = ascii
        .decode(data, allowInvalid: true)
        .trim()
        .toUpperCase()
        .replaceAll(' ', '');
    if (command == '0902') throw StateError('test programming error');
    await super.write(data);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('VIN evidence belongs only to the current OBD connection', () async {
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);

    expect(
      container.read(vehicleIdentityProvider).status,
      VehicleIdentityStatus.notRead,
    );
    expect(await session.connectDemo(), isTrue);

    await session.refreshVehicleIdentity();

    expect(
      container.read(vehicleIdentityProvider),
      VehicleIdentity.vehicleReported('1D4GP00R55B123456'),
    );

    await session.disconnect();
    expect(
      container.read(vehicleIdentityProvider),
      const VehicleIdentity.notRead(),
      reason: 'the next adapter connection may belong to another vehicle',
    );
  });

  test('a retired VIN read cannot overwrite the next connection', () async {
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);
    final oldTransport = _DelayedVinTransport();

    expect(
      await session.connectForTest(oldTransport, TransportKind.demo),
      isTrue,
    );
    final oldRefresh = session.refreshVehicleIdentity();
    await oldTransport.vinStarted.future.timeout(const Duration(seconds: 5));

    await session.disconnect();
    expect(await session.connectDemo(), isTrue);
    await session.refreshVehicleIdentity();
    expect(
      container.read(vehicleIdentityProvider),
      VehicleIdentity.vehicleReported('1D4GP00R55B123456'),
    );

    oldTransport.releaseVin();
    await oldRefresh;

    expect(
      container.read(vehicleIdentityProvider),
      VehicleIdentity.vehicleReported('1D4GP00R55B123456'),
      reason: 'the completed read belongs to the disconnected engine',
    );
  });

  test(
    'unexpected VIN read errors are not flattened into unavailable',
    () async {
      final container = await _container();
      addTearDown(container.dispose);
      final session = container.read(obdSessionProvider.notifier);

      expect(
        await session.connectForTest(
          _ProgrammingErrorVinTransport(),
          TransportKind.demo,
        ),
        isTrue,
      );

      await expectLater(
        session.refreshVehicleIdentity(),
        throwsA(isA<StateError>()),
      );
      expect(
        container.read(vehicleIdentityProvider),
        const VehicleIdentity.notRead(),
        reason: 'programming errors must remain visible to the caller',
      );
    },
  );
}
