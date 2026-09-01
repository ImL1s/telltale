import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/telemetry.dart';
import 'package:torque_obd/state/app_runtime.dart';
import 'package:torque_obd/state/app_share_coordinator.dart';
import 'package:torque_obd/state/driving_interaction_safety.dart';
import 'package:torque_obd/state/obd_session.dart';

void main() {
  test(
    'production policy records transient safety edges from live telemetry',
    () async {
      final telemetry = StreamController<TelemetrySnapshot>.broadcast(
        sync: true,
      );
      var input = DrivingSafetyInput(
        connectionPhase: ConnectionPhase.connected,
        connectionEpoch: 1,
        foreground: true,
        foregroundEpoch: 1,
        recorderBlocksArtifacts: false,
        recorderEpoch: 1,
        telemetry: const TelemetrySnapshot(),
        nowUtc: DateTime.utc(2026, 8, 30),
        monotonicUs: 1,
      );
      final container = ProviderContainer(
        overrides: [
          productionDrivingSafetyInputProvider.overrideWithValue(() => input),
          telemetryProvider.overrideWith((ref) => telemetry.stream),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await telemetry.close();
      });

      input = input.copyWith(telemetry: _speed(input.nowUtc, 0));
      final policy = container.read(productionAppSharePolicyProvider);
      final firstTelemetry = Completer<void>();
      final subscription = container.listen<AsyncValue<TelemetrySnapshot>>(
        telemetryProvider,
        (_, next) {
          if (next.value != null && !firstTelemetry.isCompleted) {
            firstTelemetry.complete();
          }
        },
      );
      addTearDown(subscription.close);
      await Future<void>.delayed(Duration.zero);
      telemetry.add(input.telemetry);
      await firstTelemetry.future.timeout(const Duration(seconds: 2));
      final permit = policy.freeze();
      expect(permit, isNotNull);

      input = input.copyWith(
        telemetry: _speed(input.nowUtc, 20),
        monotonicUs: 2,
      );
      telemetry.add(input.telemetry);
      await Future<void>.delayed(Duration.zero);
      input = input.copyWith(
        telemetry: _speed(input.nowUtc, 0),
        monotonicUs: 3,
      );
      telemetry.add(input.telemetry);
      await Future<void>.delayed(Duration.zero);

      expect(
        policy.validate(permit!).cause,
        SharePermitCause.moving,
        reason: 'a moving edge cannot heal before the next Share checkpoint',
      );
    },
  );

  test('production entrypoint overrides every fail-closed root seam', () {
    final main = File('lib/main.dart').readAsStringSync();
    final app = File('lib/app.dart').readAsStringSync();

    expect(main, contains('telemetryRecorderRuntimeProvider.overrideWith'));
    expect(main, contains('appSharePolicyProvider.overrideWith'));
    expect(main, contains('appShareAvailableBytesProvider.overrideWith'));
    expect(app, contains('ref.read(telemetryRecorderControllerProvider)'));
    expect(app, contains('ref.read(appShareCoordinatorProvider)'));
    expect(app, contains('telemetryStartupRecoveryProvider.notifier'));
    expect(app, contains('.initialize()'));
    expect(
      app.indexOf('ref.read(appShareCoordinatorProvider).initialize()'),
      lessThan(app.indexOf('telemetryStartupRecoveryProvider.notifier')),
      reason: 'share reconstruction must complete before telemetry recovery',
    );
    expect(app, contains('outcome?.isReady != true'));
  });
}

TelemetrySnapshot _speed(DateTime at, double value) => TelemetrySnapshot(
  readings: {
    PidLibrary.vehicleSpeed.id: Reading(
      pid: PidLibrary.vehicleSpeed,
      value: value,
      rawBytes: [value.round()],
      timestamp: at,
    ),
  },
  capturedAt: at,
);
