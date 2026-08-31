import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/session_boundary.dart';
import 'package:torque_obd/obd/telemetry.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/artifact_operation_gate.dart';
import 'package:torque_obd/state/pid_mutation_lock.dart';
import 'package:torque_obd/state/telemetry_recorder.dart';
import 'package:torque_obd/telemetry/session/telemetry_recorder.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';

void main() {
  late DateTime now;
  late int elapsedUs;
  late _Scheduler scheduler;
  late _Storage storage;
  late RootTelemetryRecorder recorder;

  setUp(() {
    now = DateTime.utc(2026, 8, 30);
    elapsedUs = 1000;
    scheduler = _Scheduler();
    storage = _Storage();
    recorder = RootTelemetryRecorder(
      environment: _Environment(() => elapsedUs),
      storage: storage,
      startCommandMutex: StartCommandMutex(),
      artifactGate: ArtifactOperationGate(),
      pidMutationLock: PidMutationLock(),
      utcNow: () => now,
      elapsedUs: () => elapsedUs,
      scheduleDurationLimit: scheduler.schedule,
    );
  });

  test(
    'root owns the exact 60-minute limit without telemetry callbacks',
    () async {
      expect(
        (await recorder.start(_request())).outcome,
        TelemetryStartOutcome.recording,
      );
      final startedAt = elapsedUs;
      expect(scheduler.lastDelay, telemetryRecorderDurationLimit);

      elapsedUs = startedAt + telemetryRecorderDurationLimit.inMicroseconds - 1;
      scheduler.fire();
      expect(recorder.state.phase, TelemetryRecorderPhase.recording);
      expect(scheduler.lastDelay, const Duration(microseconds: 1));

      elapsedUs++;
      scheduler.fire();
      expect(recorder.state.phase, TelemetryRecorderPhase.finalizing);
      expect(
        recorder.state.terminalReason,
        TelemetryTerminalReason.durationLimit,
      );
      await recorder.drainFinalization();
      expect(storage.deleted, isTrue, reason: 'zero-value staging is removed');
      expect(storage.installedFooter, isNull);
      expect(recorder.state.phase, TelemetryRecorderPhase.idle);
    },
  );

  test(
    'user Stop wins when it closes acceptance before the limit callback',
    () async {
      expect(
        (await recorder.start(_request())).outcome,
        TelemetryStartOutcome.recording,
      );
      recorder.onTelemetry(_speed(now, 0));
      recorder.stop();
      scheduler.fireEvenIfCancelled();
      await recorder.drainFinalization();

      expect(
        storage.installedFooter?.terminalReason,
        TelemetryTerminalReason.user,
      );
    },
  );

  test(
    'duration wins when it closes acceptance before a boundary race',
    () async {
      expect(
        (await recorder.start(_request())).outcome,
        TelemetryStartOutcome.recording,
      );
      recorder.onTelemetry(_speed(now, 0));
      final startedAt = elapsedUs;
      elapsedUs = startedAt + telemetryRecorderDurationLimit.inMicroseconds;
      scheduler.fire();
      recorder.onSessionBoundary(
        ObdSessionBoundary(
          reason: ObdSessionBoundaryReason.userDisconnect,
          generation: 1,
          observedAtUtc: DateTime.utc(2026, 8, 30),
        ),
      );
      await recorder.drainFinalization();

      expect(
        storage.installedFooter?.terminalReason,
        TelemetryTerminalReason.durationLimit,
      );
    },
  );

  test(
    'telemetry arriving at the deadline is rejected before append',
    () async {
      expect(
        (await recorder.start(_request())).outcome,
        TelemetryStartOutcome.recording,
      );
      final startedAt = elapsedUs;
      elapsedUs = startedAt + telemetryRecorderDurationLimit.inMicroseconds;
      recorder.onTelemetry(_speed(now, 1));
      await recorder.drainFinalization();

      expect(storage.eventLines, isEmpty);
      expect(storage.deleted, isTrue);
    },
  );
}

TelemetryStartRequest _request() => TelemetryStartRequest(
  source: TelemetrySource.demo,
  transport: TransportKind.demo,
  protocol: 'DEMO',
  activePids: const [PidLibrary.vehicleSpeed],
);

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

final class _Environment implements TelemetryStartEnvironment {
  const _Environment(this.elapsedUs);

  final int Function() elapsedUs;

  @override
  TelemetryStartEnvironmentSnapshot snapshot(String checkpoint) =>
      TelemetryStartEnvironmentSnapshot(
        connected: true,
        foreground: true,
        connectionGeneration: 1,
        foregroundEpoch: 1,
        safetyEpoch: 1,
        speedKnown: true,
        speedKmh: 0,
        speedFreshUntilElapsedUs: elapsedUs() + 10000000,
        observedElapsedUs: elapsedUs(),
      );
}

final class _Scheduler {
  Duration? lastDelay;
  void Function()? _callback;
  _Handle? _handle;

  TelemetryDurationLimitHandle schedule(
    Duration delay,
    void Function() callback,
  ) {
    lastDelay = delay;
    _callback = callback;
    return _handle = _Handle();
  }

  void fire() {
    if (_handle?.cancelled ?? true) return;
    _callback?.call();
  }

  void fireEvenIfCancelled() => _callback?.call();
}

final class _Handle implements TelemetryDurationLimitHandle {
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;
}

final class _Storage implements TelemetryRecorderStorage {
  final List<List<int>> eventLines = <List<int>>[];
  bool deleted = false;
  TelemetrySessionFooter? installedFooter;

  @override
  Future<void> prepareDirectory({
    void Function(String checkpoint)? checkpoint,
  }) async {}

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
  }) async => _Writer(this, headerForId('0123456789abcdef0123456789abcdef'));
}

final class _Writer implements TelemetryStagingWriter {
  _Writer(this.owner, this.header);

  final _Storage owner;
  @override
  final TelemetrySessionHeader header;

  @override
  int get bytesBeforeFooter => 128;

  @override
  Future<void> appendHeader(List<int> line) async {}

  @override
  Future<void> flushHeader() async {}

  @override
  TelemetryAppendResult tryAppendEvent(List<int> line) {
    owner.eventLines.add(line);
    return TelemetryAppendResult.accepted;
  }

  @override
  Future<TelemetryCloseResult> closeForAbort() async =>
      TelemetryCloseResult.closed;

  @override
  Future<TelemetryCleanupResult> deleteZeroValue() async {
    owner.deleted = true;
    return TelemetryCleanupResult.deleted;
  }

  @override
  Future<TelemetryFinalizeResult> finalizeAndInstall(
    TelemetrySessionFooter footer,
  ) async {
    owner.installedFooter = footer;
    return TelemetryFinalizeResult.installed;
  }
}
