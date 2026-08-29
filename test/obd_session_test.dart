import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/obd/dtc/dtc.dart';
import 'package:torque_obd/obd/elm327_client.dart' show InitStatus;
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_registry.dart';
import 'package:torque_obd/state/settings.dart';

Future<ProviderContainer> _container() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  _generationTests();

  group('demo session lifecycle', () {
    test('reports connected once the handshake finishes', () async {
      final container = await _container();
      addTearDown(container.dispose);

      final session = container.read(obdSessionProvider.notifier);
      expect(container.read(obdSessionProvider).isConnected, isFalse);

      final ok = await session.connectDemo();
      expect(ok, isTrue);

      // Regression guard. Handshake progress arrives asynchronously off a
      // broadcast stream, so the final events land after connect() returns.
      // An unconditional `phase = handshaking` write in that listener used to
      // clobber the connected phase, leaving a live session that reported
      // itself offline everywhere except the screen that had already read it.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final state = container.read(obdSessionProvider);
      expect(
        state.phase,
        ConnectionPhase.connected,
        reason: 'late init-progress events must not reset the phase',
      );
      expect(state.isConnected, isTrue);
      expect(state.deviceName, contains('Demo'));
      expect(state.initSteps, isNotEmpty);

      await session.disconnect();
      expect(container.read(obdSessionProvider).isConnected, isFalse);
    });

    test(
      'every critical handshake step succeeds against the simulator',
      () async {
        final container = await _container();
        addTearDown(container.dispose);

        final session = container.read(obdSessionProvider.notifier);
        await session.connectDemo();
        await Future<void>.delayed(const Duration(milliseconds: 250));

        final steps = container.read(obdSessionProvider).initSteps;
        final failures = steps
            .where((s) => s.step.isCritical && s.status == InitStatus.failed)
            .map((s) => s.step.command)
            .toList();
        expect(failures, isEmpty);

        await session.disconnect();
      },
    );

    test('polls telemetry and evaluates formulas', () async {
      final container = await _container();
      addTearDown(container.dispose);

      final session = container.read(obdSessionProvider.notifier);
      await session.connectDemo();

      // Give the polling loop time to complete a few cycles.
      final snapshot = await session.telemetryStream
          .firstWhere((s) => s.readings.length >= 3)
          .timeout(const Duration(seconds: 10));

      expect(snapshot.readings, isNotEmpty);

      final rpm = snapshot.valueOf(PidLibrary.engineRpm);
      expect(rpm, isNotNull);
      expect(rpm, greaterThan(500));
      expect(rpm, lessThan(8000));

      await session.disconnect();
    });

    test('always polls the physics inputs even when they are off the dashboard', () async {
      final container = await _container();
      addTearDown(container.dispose);

      final session = container.read(obdSessionProvider.notifier);
      await session.connectDemo();
      expect(container.read(vehicleProfileProvider).isConfirmed, isFalse);
      await container.read(vehicleProfileProvider.notifier).confirm();

      // The default dashboard has no MAP gauge, but the speed-density
      // derivation needs it — without this the derived strip silently reads 0.
      //
      // Waits for a snapshot carrying *every* physics input: they are polled
      // across separate cycles, so the first snapshot containing one of them
      // will not generally contain the rest.
      final snapshot = await session.telemetryStream
          .firstWhere(
            (s) => PidLibrary.physicsInputs.every(
              (p) => s.readings.containsKey(p.id),
            ),
          )
          .timeout(const Duration(seconds: 15));

      for (final pid in PidLibrary.physicsInputs) {
        expect(
          snapshot.valueOf(pid),
          isNotNull,
          reason: '${pid.shortName} must be polled even when off the dashboard',
        );
      }

      await session.disconnect();
    });

    test('profile confirmation never crosses a connection boundary', () async {
      final container = await _container();
      addTearDown(container.dispose);

      final session = container.read(obdSessionProvider.notifier);
      final profile = container.read(vehicleProfileProvider.notifier);

      expect(await session.connectDemo(), isTrue);
      await profile.confirm();
      expect(container.read(vehicleProfileProvider).isConfirmed, isTrue);

      await session.disconnect();
      expect(container.read(vehicleProfileProvider).isConfirmed, isFalse);

      expect(await session.connectDemo(), isTrue);
      expect(
        container.read(vehicleProfileProvider).isConfirmed,
        isFalse,
        reason: 'the next connection may be a different vehicle',
      );
      await session.disconnect();
    });

    test(
      'unconfirmed profiles poll only profile-independent derived inputs',
      () async {
        final container = await _container();
        addTearDown(container.dispose);

        final session = container.read(obdSessionProvider.notifier);
        await session.connectDemo();

        final measuredOnly = await session.telemetryStream
            .firstWhere(
              (snapshot) =>
                  snapshot.readings.containsKey(PidLibrary.engineFuelRate.id),
            )
            .timeout(const Duration(seconds: 15));
        expect(measuredOnly.valueOf(PidLibrary.engineFuelRate), isNotNull);
        expect(
          measuredOnly.readings,
          isNot(contains(PidLibrary.manifoldPressure.id)),
        );
        expect(measuredOnly.readings, isNot(contains(PidLibrary.mafRate.id)));

        await container.read(vehicleProfileProvider.notifier).confirm();
        final confirmed = await session.telemetryStream
            .firstWhere(
              (snapshot) =>
                  snapshot.readings.containsKey(
                    PidLibrary.manifoldPressure.id,
                  ) &&
                  snapshot.readings.containsKey(PidLibrary.mafRate.id),
            )
            .timeout(const Duration(seconds: 15));
        expect(confirmed.valueOf(PidLibrary.manifoldPressure), isNotNull);
        expect(confirmed.valueOf(PidLibrary.mafRate), isNotNull);

        await session.disconnect();
      },
    );

    test('reads and clears diagnostic trouble codes', () async {
      final container = await _container();
      addTearDown(container.dispose);

      final session = container.read(obdSessionProvider.notifier);
      await session.connectDemo();

      final stored = await session.readDtcs(DtcKind.stored);
      expect(stored.map((d) => d.code), containsAll(['P0301', 'P0420']));

      expect((await session.clearDtcs()).isSuccess, isTrue);
      expect(await session.readDtcs(DtcKind.stored), isEmpty);

      await session.disconnect();
    });

    test('reads the VIN back out of a multi-frame reply', () async {
      final container = await _container();
      addTearDown(container.dispose);

      final session = container.read(obdSessionProvider.notifier);
      await session.connectDemo();

      // Exercises the ISO-TP sequence-prefix stripping in the client.
      expect(await session.readVin(), '1D4GP00R55B123456');

      await session.disconnect();
    });

    test('discovers which PIDs the ECU supports', () async {
      final container = await _container();
      addTearDown(container.dispose);

      final session = container.read(obdSessionProvider.notifier);
      await session.connectDemo();

      final supported = await session.engine!.discoverSupportedPids();
      expect(supported, contains(PidLibrary.engineRpm.modeAndPid));
      expect(supported, contains(PidLibrary.vehicleSpeed.modeAndPid));

      await session.disconnect();
    });
  });
}

/// A connect attempt that has been superseded must publish nothing.
void _generationTests() {
  group('an attempt overtaken by a disconnect', () {
    test('does not come back and report itself connected', () async {
      final container = await _container();
      addTearDown(container.dispose);
      final session = container.read(obdSessionProvider.notifier);

      // Start the handshake and abandon it before it finishes. The
      // `_connecting` flag only stops two connects overlapping; it does nothing
      // about a disconnect landing mid-handshake, so the older path used to
      // finish, install an engine, and publish `connected` — a live-looking
      // session whose client had already been disposed.
      final connecting = session.connectDemo();
      await session.disconnect();
      final ok = await connecting;

      expect(ok, isFalse, reason: 'the superseded attempt must not succeed');

      // Give any stray continuation a chance to publish before asserting.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final state = container.read(obdSessionProvider);
      expect(state.isConnected, isFalse);
      expect(session.engine, isNull);
    });

    test('a connect after a disconnect still works', () async {
      // The guard must invalidate the abandoned attempt, not the next one.
      final container = await _container();
      addTearDown(container.dispose);
      final session = container.read(obdSessionProvider.notifier);

      final abandoned = session.connectDemo();
      await session.disconnect();
      await abandoned;

      expect(await session.connectDemo(), isTrue);
      expect(container.read(obdSessionProvider).isConnected, isTrue);
      await session.disconnect();
    });
  });
}
