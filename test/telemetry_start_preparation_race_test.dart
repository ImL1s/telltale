import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/artifact_operation_gate.dart';
import 'package:torque_obd/state/pid_mutation_lock.dart';
import 'package:torque_obd/state/telemetry_recorder.dart';
import 'package:torque_obd/telemetry/session/telemetry_recorder.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';

void main() {
  late _Environment environment;
  late _Storage storage;
  late StartCommandMutex command;
  late ArtifactOperationGate artifacts;
  late PidMutationLock pids;
  late RootTelemetryRecorder controller;

  setUp(() {
    environment = _Environment();
    storage = _Storage(environment);
    command = StartCommandMutex();
    artifacts = ArtifactOperationGate();
    pids = PidMutationLock();
    controller = RootTelemetryRecorder(
      environment: environment,
      storage: storage,
      startCommandMutex: command,
      artifactGate: artifacts,
      pidMutationLock: pids,
      utcNow: () => environment.now,
      elapsedUs: () => environment.elapsedUs,
    );
  });

  test(
    'Start acquires synchronously in order and revalidates after every await',
    () async {
      final result = await controller.start(_request());

      expect(result.outcome, TelemetryStartOutcome.recording);
      expect(storage.order, <String>[
        'directory',
        'quota',
        'create',
        'appendHeader',
        'flushHeader',
      ]);
      expect(environment.validationCheckpoints, <String>[
        'initial',
        'afterDirectory',
        'afterQuota',
        'beforeCreate',
        'afterCreate',
        'afterHeaderAppend',
        'afterHeaderFlush',
        'beforeAcceptance',
      ]);
      expect(controller.state.phase, TelemetryRecorderPhase.recording);
      expect(
        command.isLocked,
        isFalse,
        reason: 'Start token releases at acceptance',
      );
      expect(artifacts.snapshot.operation, ArtifactOperation.record);
      expect(pids.isLocked, isTrue);
    },
  );

  test(
    'renewed fresh stopped speed keeps Start preparation authorized',
    () async {
      environment.invalidateAt = 'afterQuota';
      environment.invalidation = (value) {
        value.elapsedUs = 3000000;
        value.speedKmh = 3;
        value.speedFreshUntilElapsedUs = 5000000;
      };

      final result = await controller.start(_request());

      expect(result.outcome, TelemetryStartOutcome.recording);
      expect(controller.state.phase, TelemetryRecorderPhase.recording);
    },
  );

  test(
    'observed unknown then renewed stopped reports speedUnknown invalidation',
    () async {
      environment.invalidateAt = 'afterQuota';
      environment.invalidation = (value) {
        value.safetyEpoch++;
        value.safetyInvalidation =
            TelemetryStartSafetyInvalidation.speedUnknown;
        value.elapsedUs = 3000000;
        value.speedKmh = 3;
        value.speedFreshUntilElapsedUs = 5000000;
      };

      final result = await controller.start(_request());

      expect(
        result.outcome,
        TelemetryStartOutcome.startInvalidatedSpeedUnknown,
      );
    },
  );

  for (final race in <String>[
    'afterDirectory',
    'afterQuota',
    'beforeCreate',
    'afterCreate',
    'afterHeaderAppend',
    'afterHeaderFlush',
    'beforeAcceptance',
  ]) {
    test(
      '$race moving race aborts, removes zero-value staging, and rolls back',
      () async {
        environment.invalidateAt = race;
        final result = await controller.start(_request());

        expect(result.outcome, TelemetryStartOutcome.startInvalidatedMoving);
        expect(controller.state.phase, TelemetryRecorderPhase.idle);
        expect(controller.isAccepting, isFalse);
        expect(storage.eventLines, isEmpty);
        expect(
          storage.deleted,
          race == 'afterDirectory' ||
                  race == 'afterQuota' ||
                  race == 'beforeCreate'
              ? isFalse
              : isTrue,
        );
        expect(command.isLocked, isFalse);
        expect(artifacts.snapshot.isIdle, isTrue);
        expect(pids.isLocked, isFalse);
      },
    );
  }

  final invalidations =
      <
        String,
        ({
          TelemetryStartOutcome outcome,
          void Function(_Environment value) apply,
        })
      >{
        'background': (
          outcome: TelemetryStartOutcome.startInvalidatedBackground,
          apply: (value) {
            value.foreground = false;
            value.foregroundEpoch++;
          },
        ),
        'disconnect': (
          outcome: TelemetryStartOutcome.startInvalidatedDisconnect,
          apply: (value) => value.connected = false,
        ),
        'replacement': (
          outcome: TelemetryStartOutcome.startInvalidatedSessionReplacement,
          apply: (value) => value.generation++,
        ),
        'stale speed': (
          outcome: TelemetryStartOutcome.startInvalidatedSpeedUnknown,
          apply: (value) => value.elapsedUs += 3000000,
        ),
      };
  for (final entry in invalidations.entries) {
    test('${entry.key} race has a typed abort and complete rollback', () async {
      environment.invalidateAt = 'afterQuota';
      environment.invalidation = entry.value.apply;

      final result = await controller.start(_request());

      expect(result.outcome, entry.value.outcome);
      expect(controller.state.phase, TelemetryRecorderPhase.idle);
      expect(command.isLocked, isFalse);
      expect(artifacts.snapshot.isIdle, isTrue);
      expect(pids.isLocked, isFalse);
    });
  }

  test('close failure is fail-closed and retains every owner', () async {
    environment.invalidateAt = 'afterHeaderAppend';
    storage.closeResult = TelemetryCloseResult.failed;

    final result = await controller.start(_request());

    expect(result.outcome, TelemetryStartOutcome.restartRequired);
    expect(controller.state.phase, TelemetryRecorderPhase.preparing);
    expect(controller.state.requiresRestart, isTrue);
    expect(storage.deleted, isFalse);
    expect(command.isLocked, isTrue);
    expect(artifacts.snapshot.operation, ArtifactOperation.record);
    expect(pids.isLocked, isTrue);
  });

  test(
    'never-completing close is not cancelled and retains every owner',
    () async {
      environment.invalidateAt = 'afterHeaderAppend';
      storage.neverClose = true;

      final future = controller.start(_request());
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.phase, TelemetryRecorderPhase.preparing);
      expect(controller.state.requiresRestart, isTrue);
      expect(command.isLocked, isTrue);
      expect(artifacts.snapshot.operation, ArtifactOperation.record);
      expect(pids.isLocked, isTrue);
      expect(await _completesSoon(future), isFalse);
    },
  );

  test(
    'never-completing preparation retains ownership without fake timeout',
    () async {
      storage.neverAt = 'quota';
      final future = controller.start(_request());
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.phase, TelemetryRecorderPhase.preparing);
      expect(controller.state.requiresRestart, isTrue);
      expect(command.isLocked, isTrue);
      expect(artifacts.snapshot.operation, ArtifactOperation.record);
      expect(pids.isLocked, isTrue);
      expect(await _completesSoon(future), isFalse);
    },
  );

  test(
    'typed quota rejection is consumed before create and releases owners',
    () async {
      storage.quota = const TelemetryStorageQuota(
        effectiveSessionLimit: 0,
        sessionLimitIsLibraryBound: true,
        rejection: TelemetryQuotaRejection.libraryGroupLimit,
      );

      final result = await controller.start(_request());

      expect(result.outcome, TelemetryStartOutcome.libraryGroupLimit);
      expect(storage.order, <String>['directory', 'quota']);
      expect(command.isLocked, isFalse);
      expect(artifacts.snapshot.isIdle, isTrue);
      expect(pids.isLocked, isFalse);
    },
  );

  test(
    'typed admission failures acquire and roll back only owned gates',
    () async {
      environment.connected = false;
      expect(
        (await controller.start(_request())).outcome,
        TelemetryStartOutcome.disconnected,
      );
      expect(artifacts.snapshot.isIdle, isTrue);
      expect(pids.isLocked, isFalse);

      environment.connected = true;
      final other = artifacts
          .tryAcquire('share', ArtifactOperation.export)
          .token!;
      expect(
        (await controller.start(_request())).outcome,
        TelemetryStartOutcome.artifactBusy,
      );
      expect(command.isLocked, isFalse);
      artifacts.release(other);

      final pidOwner = pids.tryAcquire('other')!;
      expect(
        (await controller.start(_request())).outcome,
        TelemetryStartOutcome.pidLocked,
      );
      expect(command.isLocked, isFalse);
      expect(artifacts.snapshot.isIdle, isTrue);
      pids.release(pidOwner);

      final invalid = TelemetryStartRequest(
        source: TelemetrySource.demo,
        transport: TransportKind.demo,
        protocol: 'AUTO',
        activePids: const [],
      );
      expect(
        (await controller.start(invalid)).outcome,
        TelemetryStartOutcome.invalidConfiguration,
      );
      expect(
        storage.order,
        isEmpty,
        reason: 'freeze fails before the first await',
      );
      expect(command.isLocked, isFalse);
      expect(artifacts.snapshot.isIdle, isTrue);
      expect(pids.isLocked, isFalse);
    },
  );

  test(
    'unexpected pre-writer failure publishes the restored idle state',
    () async {
      storage.failureAt = 'directory';
      final states = <TelemetryRecorderPhase>[];
      final subscription = controller.states.listen(
        (state) => states.add(state.phase),
      );
      addTearDown(subscription.cancel);

      final result = await controller.start(_request());

      expect(result.outcome, TelemetryStartOutcome.storageFailure);
      expect(states, <TelemetryRecorderPhase>[
        TelemetryRecorderPhase.preparing,
        TelemetryRecorderPhase.idle,
      ]);
      expect(controller.state.phase, TelemetryRecorderPhase.idle);
    },
  );
}

Future<bool> _completesSoon(Future<Object?> future) async {
  final marker = Object();
  return !identical(
    await Future.any<Object?>(<Future<Object?>>[
      future,
      Future<Object?>.delayed(const Duration(milliseconds: 20), () => marker),
    ]),
    marker,
  );
}

TelemetryStartRequest _request() => TelemetryStartRequest(
  source: TelemetrySource.demo,
  transport: TransportKind.demo,
  protocol: 'AUTO',
  activePids: const [PidLibrary.engineRpm],
);

final class _Environment implements TelemetryStartEnvironment {
  DateTime now = DateTime.utc(2026, 8, 30);
  int elapsedUs = 0;
  bool connected = true;
  bool foreground = true;
  int generation = 7;
  int foregroundEpoch = 2;
  int safetyEpoch = 4;
  TelemetryStartSafetyInvalidation? safetyInvalidation;
  bool speedKnown = true;
  double speedKmh = 0;
  int speedFreshUntilElapsedUs = 2000000;
  String? invalidateAt;
  void Function(_Environment value)? invalidation;
  final List<String> validationCheckpoints = <String>[];

  @override
  TelemetryStartEnvironmentSnapshot snapshot(String checkpoint) {
    validationCheckpoints.add(checkpoint);
    if (checkpoint == invalidateAt) {
      final change = invalidation;
      if (change == null) {
        speedKmh = 20;
        safetyEpoch++;
      } else {
        change(this);
      }
    }
    return TelemetryStartEnvironmentSnapshot(
      connected: connected,
      foreground: foreground,
      connectionGeneration: generation,
      foregroundEpoch: foregroundEpoch,
      safetyEpoch: safetyEpoch,
      speedKnown: speedKnown,
      speedKmh: speedKmh,
      speedFreshUntilElapsedUs: speedFreshUntilElapsedUs,
      observedElapsedUs: elapsedUs,
      safetyInvalidation: safetyInvalidation,
    );
  }
}

final class _Storage implements TelemetryRecorderStorage {
  _Storage(this.environment);

  final _Environment environment;
  final List<String> order = <String>[];
  final List<List<int>> eventLines = <List<int>>[];
  String? neverAt;
  String? failureAt;
  TelemetryCloseResult closeResult = TelemetryCloseResult.closed;
  bool neverClose = false;
  bool deleted = false;
  TelemetryStorageQuota quota = const TelemetryStorageQuota(
    effectiveSessionLimit: 1024 * 1024,
    sessionLimitIsLibraryBound: false,
  );

  Future<void> _step(String name) {
    order.add(name);
    environment.elapsedUs += 10;
    if (failureAt == name) throw StateError(name);
    if (neverAt == name) return Completer<void>().future;
    return Future<void>.value();
  }

  @override
  Future<void> prepareDirectory({
    void Function(String checkpoint)? checkpoint,
  }) => _step('directory');

  @override
  Future<TelemetryStorageQuota> scanQuota({
    void Function(String checkpoint)? checkpoint,
  }) async {
    await _step('quota');
    return quota;
  }

  @override
  Future<TelemetryStagingWriter> createExclusive(
    TelemetrySessionHeader Function(String id) headerForId, {
    required TelemetryStorageQuota quota,
    void Function(String checkpoint)? checkpoint,
  }) async {
    await _step('create');
    return _Writer(this, headerForId('0123456789abcdef0123456789abcdef'));
  }
}

final class _Writer implements TelemetryStagingWriter {
  _Writer(this.owner, this.header);
  final _Storage owner;
  @override
  final TelemetrySessionHeader header;

  @override
  int get bytesBeforeFooter => 256;

  @override
  Future<void> appendHeader(List<int> line) => owner._step('appendHeader');

  @override
  Future<void> flushHeader() => owner._step('flushHeader');

  @override
  TelemetryAppendResult tryAppendEvent(List<int> line) {
    owner.eventLines.add(line);
    return TelemetryAppendResult.accepted;
  }

  @override
  Future<TelemetryCloseResult> closeForAbort() {
    if (owner.neverClose) return Completer<TelemetryCloseResult>().future;
    return Future<TelemetryCloseResult>.value(owner.closeResult);
  }

  @override
  Future<TelemetryCleanupResult> deleteZeroValue() async {
    owner.deleted = true;
    return TelemetryCleanupResult.deleted;
  }

  @override
  Future<TelemetryFinalizeResult> finalizeAndInstall(
    TelemetrySessionFooter footer,
  ) async => TelemetryFinalizeResult.installed;
}
