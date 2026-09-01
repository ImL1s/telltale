import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/core/share/app_share_platform_bridge.dart';
import 'package:torque_obd/core/share/share_lease_ledger.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/telemetry.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/app_share_coordinator.dart';
import 'package:torque_obd/state/artifact_operation_gate.dart';
import 'package:torque_obd/state/driving_interaction_safety.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_mutation_lock.dart';
import 'package:torque_obd/state/telemetry_recorder.dart';
import 'package:torque_obd/state/telemetry_runtime.dart';
import 'package:torque_obd/telemetry/session/telemetry_recorder.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';

void main() {
  test('only AsyncData is authoritative for Start and Share safety', () {
    final stopped = _speed(DateTime.utc(2026, 8, 30), 0);
    expect(authoritativeTelemetryValue(AsyncData(stopped)), same(stopped));
    expect(
      authoritativeTelemetryValue(const AsyncLoading<TelemetrySnapshot>()),
      isNull,
    );
    expect(
      authoritativeTelemetryValue(
        AsyncError<TelemetrySnapshot>(StateError('failed'), StackTrace.empty),
      ),
      isNull,
    );
  });

  test(
    'stopped-loading-stopped during Start revokes the permit before create',
    () async {
      final now = DateTime.utc(2026, 8, 30);
      var elapsedUs = 1000;
      final environment = LiveTelemetryStartEnvironment(
        readConnection: () => const TelemetryConnectionSnapshot(
          connected: true,
          foreground: true,
          connectionGeneration: 1,
          foregroundEpoch: 1,
        ),
        utcNow: () => now,
        elapsedUs: () => elapsedUs,
      )..observeTelemetry(_speed(now, 0));
      final storage = _RevokingStorage(() {
        environment.revokeTelemetryAuthority();
        elapsedUs++;
        environment.observeTelemetry(_speed(now, 0));
      });
      final recorder = RootTelemetryRecorder(
        environment: environment,
        storage: storage,
        startCommandMutex: StartCommandMutex(),
        artifactGate: ArtifactOperationGate(),
        pidMutationLock: PidMutationLock(),
        utcNow: () => now,
        elapsedUs: () => elapsedUs,
      );

      final result = await recorder.start(
        TelemetryStartRequest(
          source: TelemetrySource.demo,
          transport: TransportKind.demo,
          protocol: 'DEMO',
          activePids: const [PidLibrary.vehicleSpeed],
        ),
      );

      expect(
        result.outcome,
        TelemetryStartOutcome.startInvalidatedSpeedUnknown,
      );
      expect(storage.createCalls, 0);
      expect(recorder.state.phase, TelemetryRecorderPhase.idle);
    },
  );

  test('stopped-loading-stopped during Share creates no lease and invokes no platform', () async {
    final root = await Directory.systemTemp.createTemp('safety-authority-');
    addTearDown(() => root.delete(recursive: true));
    final now = DateTime.utc(2026, 8, 30);
    AsyncValue<TelemetrySnapshot> telemetry = AsyncData(_speed(now, 0));
    var monotonicUs = 1;
    late final DrivingInteractionSafetyPolicy policy;
    DrivingSafetyInput input() => DrivingSafetyInput(
      connectionPhase: ConnectionPhase.connected,
      connectionEpoch: 1,
      foreground: true,
      foregroundEpoch: 1,
      recorderBlocksArtifacts: false,
      recorderEpoch: 1,
      telemetry:
          authoritativeTelemetryValue(telemetry) ?? const TelemetrySnapshot(),
      nowUtc: now,
      monotonicUs: monotonicUs,
    );
    policy = DrivingInteractionSafetyPolicy(input);
    final platform = _Platform();
    var rootCalls = 0;
    final coordinator = AppShareCoordinator(
      rootDirectory: () async {
        rootCalls++;
        if (rootCalls == 2) {
          telemetry = const AsyncLoading<TelemetrySnapshot>();
          monotonicUs++;
          policy.synchronize();
          telemetry = AsyncData(_speed(now, 0));
          monotonicUs++;
          policy.synchronize();
        }
        return root;
      },
      policy: policy,
      artifactGate: ArtifactOperationGate(),
      platform: platform,
      idSource: () => '0123456789abcdef0123456789abcdef',
      nowUtc: () => now,
      availableBytes: (_) async => 64 * 1024 * 1024,
    );
    expect(await coordinator.initialize(), AppShareInitializationOutcome.ready);

    final result = await coordinator.share(
      AppShareRequest(
        sourceKind: ShareSourceKind.telemetryJson,
        subject: 'session',
        streamFactory: () => Stream.value([1, 2, 3]),
      ),
    );

    expect(result.error, ShareError.shareSafetyChangedSpeedUnknown);
    expect(platform.calls, 0);
    expect(
      root.listSync(),
      isEmpty,
      reason: 'revocation happened before lease/source allocation',
    );
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

final class _RevokingStorage implements TelemetryRecorderStorage {
  _RevokingStorage(this.revoke);

  final void Function() revoke;
  int createCalls = 0;

  @override
  Future<void> prepareDirectory({
    void Function(String checkpoint)? checkpoint,
  }) async {
    revoke();
  }

  @override
  Future<TelemetryStorageQuota> scanQuota({
    void Function(String checkpoint)? checkpoint,
  }) async => const TelemetryStorageQuota(
    effectiveSessionLimit: 1024 * 1024,
    sessionLimitIsLibraryBound: false,
  );

  @override
  Future<TelemetryStagingWriter> createExclusive(
    TelemetrySessionHeader Function(String sessionId) headerForId, {
    required TelemetryStorageQuota quota,
    void Function(String checkpoint)? checkpoint,
  }) {
    createCalls++;
    throw StateError('create must not be called');
  }
}

final class _Platform implements AppSharePlatform {
  int calls = 0;

  @override
  Future<AppShareResult> share(AppSharePlatformRequest request) async {
    calls++;
    return AppShareResult.selected;
  }
}
