import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/session_boundary.dart';
import 'package:torque_obd/obd/telemetry.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/artifact_operation_gate.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_mutation_lock.dart';
import 'package:torque_obd/state/pid_registry.dart';
import 'package:torque_obd/state/telemetry_recorder.dart';
import 'package:torque_obd/telemetry/session/telemetry_recorder.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'actual hidden lifecycle edge closes root acceptance synchronously',
    () async {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final rig = _Rig();
      final snapshots = StreamController<TelemetrySnapshot>.broadcast(
        sync: true,
      );
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          telemetryRecorderRuntimeProvider.overrideWithValue(
            TelemetryRecorderRuntime(
              environment: rig,
              storage: rig.storage,
              utcNow: () => rig.now,
              elapsedUs: () => rig.elapsedUs,
            ),
          ),
          telemetryProvider.overrideWith((ref) => snapshots.stream),
        ],
      );
      addTearDown(() async {
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        container.dispose();
        await snapshots.close();
      });

      final controller = container.read(telemetryRecorderControllerProvider);
      expect(
        (await controller.start(rig.request)).outcome,
        TelemetryStartOutcome.recording,
      );
      final session = container.read(obdSessionProvider.notifier);
      final before = session.pauseEpoch;

      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      expect(controller.isAccepting, isFalse);
      expect(
        controller.state.terminalReason,
        TelemetryTerminalReason.background,
      );
      expect(session.pauseEpoch, before + 1);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(session.pauseEpoch, before + 1);
    },
  );

  test('non-autoDispose root provider eagerly binds heartbeat and boundary streams', () async {
    final rig = _Rig();
    final snapshots = StreamController<TelemetrySnapshot>.broadcast(sync: true);
    final boundaries = StreamController<ObdSessionBoundary>.broadcast(
      sync: true,
    );
    final foreground = StreamController<bool>.broadcast(sync: true);
    final container = ProviderContainer(
      overrides: [
        telemetryRecorderRuntimeProvider.overrideWithValue(
          TelemetryRecorderRuntime(
            environment: rig,
            storage: rig.storage,
            utcNow: () => rig.now,
            elapsedUs: () => rig.elapsedUs,
          ),
        ),
        telemetryProvider.overrideWith((ref) => snapshots.stream),
        telemetryRecorderBoundaryStreamProvider.overrideWithValue(
          boundaries.stream,
        ),
        telemetryRecorderForegroundStreamProvider.overrideWithValue(
          foreground.stream,
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await snapshots.close();
      await boundaries.close();
      await foreground.close();
    });

    final controller = container.read(telemetryRecorderControllerProvider);
    await controller.start(rig.request);
    final rootAnchor = container.listen(
      telemetryRecorderControllerProvider,
      (_, _) {},
    );
    addTearDown(rootAnchor.close);
    final transient = container.listen(
      telemetryRecorderControllerProvider,
      (_, _) {},
    );
    transient.close();

    await Future<void>.delayed(Duration.zero);
    snapshots.add(_snapshot(rig.now, 850));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(
      controller.state.valueCount,
      1,
      reason: 'root subscription survives the routed listener leaving',
    );
    foreground.add(false);
    expect(
      controller.isAccepting,
      isFalse,
      reason: 'the synchronous pause edge closes acceptance immediately',
    );
    boundaries.add(
      ObdSessionBoundary(
        generation: 1,
        observedAtUtc: rig.now,
        reason: ObdSessionBoundaryReason.linkLoss,
      ),
    );
    expect(controller.isAccepting, isFalse);
  });

  test('heartbeat staleness is recorded and synchronous boundary closes acceptance', () async {
    final rig = _Rig();
    final controller = rig.controller;
    expect(
      (await controller.start(rig.request)).outcome,
      TelemetryStartOutcome.recording,
    );

    controller.onTelemetry(_snapshot(rig.now, 900));
    rig.now = rig.now.add(const Duration(seconds: 3));
    rig.elapsedUs += const Duration(seconds: 3).inMicroseconds;
    controller.onTelemetry(const TelemetrySnapshot());
    expect(controller.state.valueCount, 1);
    expect(
      controller.state.statusCount,
      1,
      reason: 'the root consumes heartbeat provider snapshots',
    );
    expect(controller.state.gapCount, 1);

    controller.onSessionBoundary(
      ObdSessionBoundary(
        generation: 1,
        observedAtUtc: rig.now,
        reason: ObdSessionBoundaryReason.linkLoss,
      ),
    );
    expect(controller.isAccepting, isFalse);
    controller.onTelemetry(_snapshot(rig.now, 1200));
    expect(
      controller.state.valueCount,
      1,
      reason: 'post-boundary callbacks are rejected synchronously',
    );

    await controller.drainFinalization();
    expect(controller.state.phase, TelemetryRecorderPhase.completed);
    expect(controller.state.terminalReason, TelemetryTerminalReason.disconnect);
    expect(rig.storage.writer.installed, isTrue);
    expect(rig.artifacts.snapshot.isIdle, isTrue);
    expect(rig.pids.isLocked, isFalse);
  });

  test('background is first-terminal-wins and retained after shell listeners leave', () async {
    final rig = _Rig();
    final controller = rig.controller;
    await controller.start(rig.request);
    controller.onForegroundChanged(false);
    controller.onSessionBoundary(
      ObdSessionBoundary(
        generation: 1,
        observedAtUtc: rig.now,
        reason: ObdSessionBoundaryReason.sessionReplacement,
      ),
    );

    expect(controller.state.phase, TelemetryRecorderPhase.finalizing);
    expect(controller.state.terminalReason, TelemetryTerminalReason.background);
    await controller.drainFinalization();
    expect(
      controller.state.phase,
      TelemetryRecorderPhase.idle,
      reason: 'zero-value finalization removes staging, not a fake session',
    );
    expect(rig.storage.writer.deleted, isTrue);
  });

  test(
    'append never awaits OBD callback and backpressure closes synchronously',
    () async {
      final rig = _Rig();
      await rig.controller.start(rig.request);
      rig.storage.writer.appendResult =
          TelemetryAppendResult.storageBackpressure;

      rig.controller.onTelemetry(_snapshot(rig.now, 1000));

      expect(rig.controller.isAccepting, isFalse);
      expect(rig.controller.state.phase, TelemetryRecorderPhase.finalizing);
      expect(
        rig.controller.state.terminalReason,
        TelemetryTerminalReason.storageBackpressure,
      );
      expect(
        rig.controller.state.valueCount,
        0,
        reason: 'the line rejected by the writer is not counted',
      );
      expect(rig.artifacts.snapshot.operation, ArtifactOperation.record);
      expect(rig.pids.isLocked, isTrue);
    },
  );

  test(
    'async append failure wins terminal reason when it completes first',
    () async {
      final rig = _Rig();
      await rig.controller.start(rig.request);
      rig.controller.onTelemetry(_snapshot(rig.now, 1000));

      rig.storage.writer.failAppend();
      expect(rig.controller.isAccepting, isFalse);
      expect(
        rig.controller.state.terminalReason,
        TelemetryTerminalReason.storageFailure,
      );

      rig.controller.stop();
      expect(
        rig.controller.state.terminalReason,
        TelemetryTerminalReason.storageFailure,
      );
      await rig.controller.drainFinalization();
    },
  );

  test(
    'user terminal reason wins when selected before async append failure',
    () async {
      final rig = _Rig();
      await rig.controller.start(rig.request);
      rig.controller.onTelemetry(_snapshot(rig.now, 1000));

      rig.controller.stop();
      rig.storage.writer.failAppend();

      expect(rig.controller.state.terminalReason, TelemetryTerminalReason.user);
      await rig.controller.drainFinalization();
    },
  );

  test('retained callback from writer A cannot stop recording B', () async {
    final rig = _Rig();
    final writerA = rig.storage.writer;
    await rig.controller.start(rig.request);
    writerA.retainAppendFailureHandler();
    rig.controller.onTelemetry(_snapshot(rig.now, 1000));
    rig.controller.stop();
    await rig.controller.drainFinalization();

    rig.storage.writer = _LifecycleWriter();
    rig.now = rig.now.add(const Duration(seconds: 1));
    rig.elapsedUs += const Duration(seconds: 1).inMicroseconds;
    expect(
      (await rig.controller.start(rig.request)).outcome,
      TelemetryStartOutcome.recording,
    );

    writerA.invokeRetainedAppendFailure();

    expect(rig.controller.isAccepting, isTrue);
    expect(rig.controller.state.terminalReason, isNull);
  });

  test(
    'a second recording owns and drains a fresh finalization future',
    () async {
      final rig = _Rig();

      expect(
        (await rig.controller.start(rig.request)).outcome,
        TelemetryStartOutcome.recording,
      );
      rig.controller.onTelemetry(_snapshot(rig.now, 900));
      rig.controller.stop();
      await rig.controller.drainFinalization();
      expect(rig.controller.state.phase, TelemetryRecorderPhase.completed);

      rig.storage.writer.installed = false;
      rig.now = rig.now.add(const Duration(seconds: 1));
      rig.elapsedUs += const Duration(seconds: 1).inMicroseconds;
      expect(
        (await rig.controller.start(rig.request)).outcome,
        TelemetryStartOutcome.recording,
      );
      rig.controller.onTelemetry(_snapshot(rig.now, 1000));
      rig.controller.stop();
      await rig.controller.drainFinalization();

      expect(rig.storage.writer.installed, isTrue);
      expect(rig.controller.state.phase, TelemetryRecorderPhase.completed);
    },
  );

  test(
    'settled result can be dismissed without touching canonical storage',
    () async {
      final rig = _Rig();
      await rig.controller.start(rig.request);
      rig.controller.onTelemetry(_snapshot(rig.now, 900));
      rig.controller.stop();
      await rig.controller.drainFinalization();

      expect(rig.storage.writer.installed, isTrue);
      expect(rig.controller.dismissTerminalOutcome(), isTrue);
      expect(rig.controller.state.phase, TelemetryRecorderPhase.idle);
      expect(rig.storage.writer.installed, isTrue);
      expect(rig.controller.dismissTerminalOutcome(), isFalse);
    },
  );

  test('restart-owned finalization cannot be dismissed', () async {
    final rig = _Rig();
    rig.storage.writer.finalizeResult =
        TelemetryFinalizeResult.uncontainedFailure;
    await rig.controller.start(rig.request);
    rig.controller.onTelemetry(_snapshot(rig.now, 900));
    rig.controller.stop();
    await rig.controller.drainFinalization();

    expect(rig.controller.state.requiresRestart, isTrue);
    expect(rig.controller.state.phase, TelemetryRecorderPhase.finalizing);
    expect(rig.controller.dismissTerminalOutcome(), isFalse);
    expect(rig.controller.state.phase, TelemetryRecorderPhase.finalizing);
  });
}

TelemetrySnapshot _snapshot(DateTime now, double value) => TelemetrySnapshot(
  readings: {
    PidLibrary.engineRpm.id: Reading(
      pid: PidLibrary.engineRpm,
      value: value,
      rawBytes: const [0x10],
      timestamp: now,
    ),
  },
  capturedAt: now,
);

final class _Rig implements TelemetryStartEnvironment {
  _Rig() {
    controller = RootTelemetryRecorder(
      environment: this,
      storage: storage,
      startCommandMutex: command,
      artifactGate: artifacts,
      pidMutationLock: pids,
      utcNow: () => now,
      elapsedUs: () => elapsedUs,
    );
  }

  DateTime now = DateTime.utc(2026, 8, 30);
  int elapsedUs = 0;
  bool foreground = true;
  final command = StartCommandMutex();
  final artifacts = ArtifactOperationGate();
  final pids = PidMutationLock();
  final storage = _LifecycleStorage();
  late final RootTelemetryRecorder controller;
  final request = TelemetryStartRequest(
    source: TelemetrySource.demo,
    transport: TransportKind.demo,
    protocol: 'AUTO',
    activePids: const [PidLibrary.engineRpm],
  );

  @override
  TelemetryStartEnvironmentSnapshot snapshot(String checkpoint) =>
      TelemetryStartEnvironmentSnapshot(
        connected: true,
        foreground: foreground,
        connectionGeneration: 1,
        foregroundEpoch: foreground ? 1 : 2,
        safetyEpoch: 1,
        speedKnown: true,
        speedKmh: 0,
        speedFreshUntilElapsedUs: elapsedUs + 2000000,
        observedElapsedUs: elapsedUs,
      );
}

final class _LifecycleStorage implements TelemetryRecorderStorage {
  _LifecycleWriter writer = _LifecycleWriter();

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
    TelemetrySessionHeader Function(String id) headerForId, {
    required TelemetryStorageQuota quota,
    void Function(String checkpoint)? checkpoint,
  }) async {
    writer.header = headerForId('0123456789abcdef0123456789abcdef');
    return writer;
  }
}

final class _LifecycleWriter
    implements TelemetryStagingWriter, TelemetryAppendFailureNotifier {
  @override
  late TelemetrySessionHeader header;
  TelemetryAppendResult appendResult = TelemetryAppendResult.accepted;
  TelemetryFinalizeResult finalizeResult = TelemetryFinalizeResult.installed;
  bool installed = false;
  bool deleted = false;
  void Function()? _appendFailureHandler;
  void Function()? _retainedAppendFailureHandler;

  @override
  void setAppendFailureHandler(void Function()? handler) {
    _appendFailureHandler = handler;
  }

  void failAppend() => _appendFailureHandler?.call();

  void retainAppendFailureHandler() {
    _retainedAppendFailureHandler = _appendFailureHandler;
  }

  void invokeRetainedAppendFailure() => _retainedAppendFailureHandler?.call();

  @override
  int get bytesBeforeFooter => 512;

  @override
  Future<void> appendHeader(List<int> line) async {}

  @override
  Future<void> flushHeader() async {}

  @override
  TelemetryAppendResult tryAppendEvent(List<int> line) => appendResult;

  @override
  Future<TelemetryCloseResult> closeForAbort() async =>
      TelemetryCloseResult.closed;

  @override
  Future<TelemetryCleanupResult> deleteZeroValue() async {
    deleted = true;
    return TelemetryCleanupResult.deleted;
  }

  @override
  Future<TelemetryFinalizeResult> finalizeAndInstall(
    TelemetrySessionFooter footer,
  ) async {
    installed = finalizeResult == TelemetryFinalizeResult.installed;
    return finalizeResult;
  }
}
