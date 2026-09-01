/// Root ownership and lifecycle coordination for telemetry recording.
library;

export '../telemetry/session/telemetry_session_writer.dart'
    show TelemetryAppendResult;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../obd/pid/pid.dart';
import '../obd/session_boundary.dart';
import '../obd/telemetry.dart';
import '../obd/transport/obd_transport.dart';
import '../telemetry/session/telemetry_recorder.dart';
import '../telemetry/session/telemetry_session.dart';
import '../telemetry/session/telemetry_session_codec.dart';
import '../telemetry/session/telemetry_session_writer.dart'
    show TelemetryAppendResult;
import 'artifact_operation_gate.dart';
import 'obd_session.dart';
import 'pid_mutation_lock.dart';
import 'pid_registry.dart';

const telemetryRecorderDurationLimit = Duration(minutes: 60);

abstract interface class TelemetryDurationLimitHandle {
  void cancel();
}

typedef TelemetryDurationLimitScheduler = TelemetryDurationLimitHandle Function(
  Duration delay,
  void Function() callback,
);

TelemetryDurationLimitHandle _scheduleDurationLimit(
  Duration delay,
  void Function() callback,
) => _TimerDurationLimitHandle(Timer(delay, callback));

final class _TimerDurationLimitHandle implements TelemetryDurationLimitHandle {
  const _TimerDurationLimitHandle(this.timer);

  final Timer timer;

  @override
  void cancel() => timer.cancel();
}

enum TelemetryStartOutcome {
  recording,
  startBusy,
  artifactBusy,
  pidLocked,
  disconnected,
  background,
  speedUnknown,
  moving,
  invalidConfiguration,
  libraryGroupLimit,
  libraryByteLimit,
  noRoomForValue,
  idCollision,
  storageFailure,
  startInvalidatedMoving,
  startInvalidatedSpeedUnknown,
  startInvalidatedBackground,
  startInvalidatedDisconnect,
  startInvalidatedSessionReplacement,
  restartRequired,
}

enum TelemetryStartSafetyInvalidation { speedUnknown, moving }

final class TelemetryStartResult {
  const TelemetryStartResult(this.outcome, [this.detail]);

  final TelemetryStartOutcome outcome;
  final String? detail;
}

final class TelemetryStartRequest {
  TelemetryStartRequest({
    required this.source,
    required this.transport,
    required this.protocol,
    required List<Pid> activePids,
  }) : activePids = List<Pid>.unmodifiable(activePids);

  final TelemetrySource source;
  final TransportKind transport;
  final String protocol;
  final List<Pid> activePids;
}

/// A synchronous view of all values that can revoke Start preparation.
final class TelemetryStartEnvironmentSnapshot {
  const TelemetryStartEnvironmentSnapshot({
    required this.connected,
    required this.foreground,
    required this.connectionGeneration,
    required this.foregroundEpoch,
    required this.safetyEpoch,
    required this.speedKnown,
    required this.speedKmh,
    required this.speedFreshUntilElapsedUs,
    required this.observedElapsedUs,
    this.safetyInvalidation,
  });

  final bool connected;
  final bool foreground;
  final int connectionGeneration;
  final int foregroundEpoch;
  final int safetyEpoch;
  final bool speedKnown;
  final double speedKmh;
  final int speedFreshUntilElapsedUs;
  final int observedElapsedUs;
  final TelemetryStartSafetyInvalidation? safetyInvalidation;
}

abstract interface class TelemetryStartEnvironment {
  /// [checkpoint] is diagnostic only. Reading this method must never await.
  TelemetryStartEnvironmentSnapshot snapshot(String checkpoint);
}

final class StartPreparationPermit {
  const StartPreparationPermit({
    required this.connectionGeneration,
    required this.foregroundEpoch,
    required this.safetyEpoch,
  });

  final int connectionGeneration;
  final int foregroundEpoch;
  final int safetyEpoch;
}

final class TelemetryStorageQuota {
  const TelemetryStorageQuota({
    required this.effectiveSessionLimit,
    required this.sessionLimitIsLibraryBound,
    this.rejection,
  });

  final int effectiveSessionLimit;
  final bool sessionLimitIsLibraryBound;
  final TelemetryQuotaRejection? rejection;
}

enum TelemetryQuotaRejection {
  libraryGroupLimit,
  libraryByteLimit,
  noRoomForValue,
}

enum TelemetryStorageCreateFailure {
  invalidHeader,
  noRoomForValue,
  idCollision,
  staleQuota,
  storageFailure,
  uncontainedFailure,
}

/// Typed failure shared by the controller contract and concrete storage
/// adapters without making the controller depend on a production adapter.
final class TelemetryStorageCreateException implements Exception {
  const TelemetryStorageCreateException(this.failure);

  final TelemetryStorageCreateFailure failure;

  @override
  String toString() => 'TelemetryStorageCreateException(${failure.name})';
}

enum TelemetryCloseResult { closed, failed }

enum TelemetryCleanupResult { deleted, contained, failed }

enum TelemetryFinalizeResult { installed, preservedFailure, uncontainedFailure }

final class TelemetryRecorderRuntime {
  const TelemetryRecorderRuntime({
    required this.environment,
    required this.storage,
    required this.utcNow,
    required this.elapsedUs,
  });

  final TelemetryStartEnvironment environment;
  final TelemetryRecorderStorage storage;
  final DateTime Function() utcNow;
  final int Function() elapsedUs;
}

/// Returns only a current data emission. Riverpod may retain the previous
/// value while loading or after an error; retained UI data is not safety
/// authority for Start, recording, or Share.
TelemetrySnapshot? authoritativeTelemetryValue(
  AsyncValue<TelemetrySnapshot> value,
) =>
    value is AsyncData<TelemetrySnapshot> && !value.isLoading && !value.hasError
    ? value.value
    : null;

abstract interface class TelemetryStagingWriter {
  TelemetrySessionHeader get header;
  int get bytesBeforeFooter;
  Future<void> appendHeader(List<int> line);
  Future<void> flushHeader();

  /// Synchronous by contract: an OBD callback never awaits filesystem I/O.
  TelemetryAppendResult tryAppendEvent(List<int> line);

  Future<TelemetryCloseResult> closeForAbort();
  Future<TelemetryCleanupResult> deleteZeroValue();
  Future<TelemetryFinalizeResult> finalizeAndInstall(
    TelemetrySessionFooter footer,
  );
}

/// Optional completion edge for storage adapters whose non-blocking append can
/// fail after [tryAppendEvent] has synchronously accepted a line.
abstract interface class TelemetryAppendFailureNotifier {
  void setAppendFailureHandler(void Function()? handler);
}

abstract interface class TelemetryRecorderStorage {
  Future<void> prepareDirectory({void Function(String checkpoint)? checkpoint});
  Future<TelemetryStorageQuota> scanQuota({
    void Function(String checkpoint)? checkpoint,
  });
  Future<TelemetryStagingWriter> createExclusive(
    TelemetrySessionHeader Function(String sessionId) headerForId, {
    required TelemetryStorageQuota quota,
    void Function(String checkpoint)? checkpoint,
  });
}

bool _pidDefinitionsAlwaysSettled() => true;

/// Owns the Start command, artifact gate, PID lock, acceptance gate, and writer.
///
/// The object is deliberately root-scoped rather than screen-scoped. Every
/// boundary method closes acceptance before starting async finalization.
final class RootTelemetryRecorder {
  RootTelemetryRecorder({
    required this.environment,
    required this.storage,
    required this.startCommandMutex,
    required this.artifactGate,
    required this.pidMutationLock,
    required this.utcNow,
    required this.elapsedUs,
    this.scheduleDurationLimit = _scheduleDurationLimit,
    this.pidDefinitionsSettled = _pidDefinitionsAlwaysSettled,
  }) {
    _recorder = _newRecorder();
  }

  final TelemetryStartEnvironment environment;
  final TelemetryRecorderStorage storage;
  final StartCommandMutex startCommandMutex;
  final ArtifactOperationGate artifactGate;
  final PidMutationLock pidMutationLock;
  final DateTime Function() utcNow;
  final int Function() elapsedUs;
  final TelemetryDurationLimitScheduler scheduleDurationLimit;
  final bool Function() pidDefinitionsSettled;
  final StreamController<TelemetryRecorderState> _states =
      StreamController<TelemetryRecorderState>.broadcast(sync: true);

  late TelemetryRecorder _recorder;
  StartCommandToken? _commandToken;
  ArtifactOperationToken? _artifactToken;
  PidMutationToken? _pidToken;
  TelemetryStagingWriter? _writer;
  StartPreparationPermit? _permit;
  Future<void>? _finalization;
  TelemetryDurationLimitHandle? _durationLimitTimer;
  int _ownerSequence = 0;
  int _writerGeneration = 0;
  int _lifecycleEpoch = 0;
  int? _recordingStartedElapsedUs;
  int? _recordingEndedElapsedUs;
  String? _sessionId;
  int? _effectiveSessionLimit;

  TelemetryRecorderState get state => _recorder.state;
  Stream<TelemetryRecorderState> get states => _states.stream;
  bool get isAccepting => _recorder.isAccepting;

  TelemetryRecorderProgress get progress {
    final started = _recordingStartedElapsedUs;
    final ended = _recordingEndedElapsedUs;
    final now = ended ?? elapsedUs();
    final elapsed = started == null ? 0 : now - started;
    return TelemetryRecorderProgress(
      state: state,
      elapsedUs: elapsed < 0 ? 0 : elapsed,
      bytesBeforeFooter: _writer?.bytesBeforeFooter ?? 0,
      effectiveSessionLimit: _effectiveSessionLimit,
      sessionId: _sessionId,
    );
  }

  /// Prefer wall clock for the footer, but never persist an end before the
  /// header start or before the monotonic recording end already written in
  /// event lines.
  DateTime _endedAtUtcForFooter() {
    final wall = utcNow().toUtc();
    final started = _recorder.header?.startedAtUtc;
    if (started == null) return wall;
    final startedElapsed = _recordingStartedElapsedUs;
    final endedElapsed = _recordingEndedElapsedUs ?? elapsedUs();
    final monoUs = startedElapsed == null
        ? 0
        : (endedElapsed - startedElapsed < 0
              ? 0
              : endedElapsed - startedElapsed);
    final monoEnd = started.add(Duration(microseconds: monoUs));
    if (wall.isBefore(started) || wall.isBefore(monoEnd)) return monoEnd;
    return wall;
  }

  /// Monotonic evidence for policies that must detect even a brief recorder
  /// transition between two asynchronous checkpoints.
  int get lifecycleEpoch => _lifecycleEpoch;

  Future<TelemetryStartResult> start(TelemetryStartRequest request) async {
    final command = startCommandMutex.tryAcquire();
    if (command == null) {
      return const TelemetryStartResult(TelemetryStartOutcome.startBusy);
    }
    _commandToken = command;

    final initial = environment.snapshot('initial');
    final initialFailure = _initialFailure(initial);
    if (initialFailure != null) {
      _releaseCommand();
      return TelemetryStartResult(initialFailure);
    }

    if (!pidDefinitionsSettled()) {
      _releaseCommand();
      return const TelemetryStartResult(TelemetryStartOutcome.pidLocked);
    }

    final ownerId = 'telemetry-start-${++_ownerSequence}';
    final artifact = artifactGate.tryAcquire(ownerId, ArtifactOperation.record);
    if (!artifact.acquired) {
      _releaseCommand();
      return const TelemetryStartResult(TelemetryStartOutcome.artifactBusy);
    }
    _artifactToken = artifact.token;

    final pid = pidMutationLock.tryAcquire(ownerId);
    if (pid == null) {
      _releaseArtifact();
      _releaseCommand();
      return const TelemetryStartResult(TelemetryStartOutcome.pidLocked);
    }
    _pidToken = pid;

    late final List<FrozenPidDefinition> definitions;
    try {
      if (request.activePids.isEmpty || request.activePids.length > 32) {
        throw const TelemetryValidationException('signalCount');
      }
      definitions = request.activePids.map(freezePidDefinition).toList();
      if (definitions.map((value) => value.definition.id).toSet().length !=
          definitions.length) {
        throw const TelemetryValidationException('duplicateSignal');
      }
      _permit = StartPreparationPermit(
        connectionGeneration: initial.connectionGeneration,
        foregroundEpoch: initial.foregroundEpoch,
        safetyEpoch: initial.safetyEpoch,
      );
    } on Object catch (error) {
      _releasePidArtifactCommand();
      return TelemetryStartResult(
        TelemetryStartOutcome.invalidConfiguration,
        '$error',
      );
    }

    // Pending preparation is restart-owned. This flag is cleared only by the
    // final synchronous transition to recording. A Future that never resolves
    // therefore cannot be mistaken for a cancellable or released operation.
    _recorder.state = const TelemetryRecorderState(
      phase: TelemetryRecorderPhase.preparing,
      errorCategory: TelemetryRecorderErrorCategory.restartRequired,
      requiresRestart: true,
    );
    // A completed finalization Future belongs only to the previous session.
    // Retaining it would make Stop on a later recording reuse the old Future
    // and skip installation of the new staging artifact.
    _finalization = null;
    _recordingStartedElapsedUs = null;
    _recordingEndedElapsedUs = null;
    _sessionId = null;
    _effectiveSessionLimit = null;
    _invalidateAppendFailureHandler();
    _writer = null;
    _publish();

    final startedAtUtc = utcNow().toUtc();
    void preparationCheckpoint(String checkpoint) {
      final invalid = _revalidate(checkpoint);
      if (invalid != null) {
        throw TelemetryStartPreparationInvalidatedException(invalid);
      }
    }

    try {
      await storage.prepareDirectory(checkpoint: preparationCheckpoint);
      var invalid = _revalidate('afterDirectory');
      if (invalid != null) return await _abortPreparation(invalid);

      final quota = await storage.scanQuota(checkpoint: preparationCheckpoint);
      invalid = _revalidate('afterQuota');
      if (invalid != null) return await _abortPreparation(invalid);
      final quotaFailure = switch (quota.rejection) {
        TelemetryQuotaRejection.libraryGroupLimit =>
          TelemetryStartOutcome.libraryGroupLimit,
        TelemetryQuotaRejection.libraryByteLimit =>
          TelemetryStartOutcome.libraryByteLimit,
        TelemetryQuotaRejection.noRoomForValue =>
          TelemetryStartOutcome.noRoomForValue,
        null => null,
      };
      if (quotaFailure != null) {
        return await _abortPreparation(quotaFailure);
      }
      invalid = _revalidate('beforeCreate');
      if (invalid != null) return await _abortPreparation(invalid);

      late final TelemetryStagingWriter writer;
      try {
        writer = await storage.createExclusive(
          (sessionId) => TelemetrySessionHeader(
            sessionId: sessionId,
            startedAtUtc: startedAtUtc,
            source: request.source,
            transport: request.transport,
            protocol: request.protocol,
            signals: definitions,
          ),
          quota: quota,
          checkpoint: preparationCheckpoint,
        );
      } on TelemetryStorageCreateException catch (error) {
        if (error.failure == TelemetryStorageCreateFailure.uncontainedFailure) {
          _markRestartRequired();
          return TelemetryStartResult(
            TelemetryStartOutcome.restartRequired,
            '$error',
          );
        }
        _resetRecorder();
        _releasePidArtifactCommand();
        _publish();
        return TelemetryStartResult(switch (error.failure) {
          TelemetryStorageCreateFailure.invalidHeader =>
            TelemetryStartOutcome.invalidConfiguration,
          TelemetryStorageCreateFailure.noRoomForValue =>
            TelemetryStartOutcome.noRoomForValue,
          TelemetryStorageCreateFailure.idCollision =>
            TelemetryStartOutcome.idCollision,
          TelemetryStorageCreateFailure.staleQuota ||
          TelemetryStorageCreateFailure.storageFailure =>
            TelemetryStartOutcome.storageFailure,
          TelemetryStorageCreateFailure.uncontainedFailure => throw StateError(
            'handled above',
          ),
        }, '$error');
      }
      _writer = writer;
      if (writer case final TelemetryAppendFailureNotifier notifier) {
        final generation = ++_writerGeneration;
        notifier.setAppendFailureHandler(
          () => _onAppendFailure(writer, generation),
        );
      }
      _sessionId = writer.header.sessionId;
      _effectiveSessionLimit = quota.effectiveSessionLimit;
      invalid = _revalidate('afterCreate');
      if (invalid != null) return await _abortPreparation(invalid);

      final headerLine = TelemetrySessionCodec.encodeHeaderLine(writer.header);
      await writer.appendHeader(headerLine);
      invalid = _revalidate('afterHeaderAppend');
      if (invalid != null) return await _abortPreparation(invalid);

      await writer.flushHeader();
      invalid = _revalidate('afterHeaderFlush');
      if (invalid != null) return await _abortPreparation(invalid);

      // No await is permitted between this check and acceptance opening.
      invalid = _revalidate('beforeAcceptance');
      if (invalid != null) return await _abortPreparation(invalid);
      _recorder = _newRecorder();
      if (!_recorder.prepare(writer.header) || !_recorder.openAcceptance()) {
        return await _abortPreparation(
          TelemetryStartOutcome.invalidConfiguration,
        );
      }
      _recordingStartedElapsedUs = elapsedUs();
      _armDurationLimit();
      _releaseCommand();
      _publish();
      return const TelemetryStartResult(TelemetryStartOutcome.recording);
    } on TelemetryStartPreparationInvalidatedException catch (invalidated) {
      return _abortPreparation(invalidated.outcome);
    } on Object catch (error) {
      if (_writer != null) {
        return await _abortPreparation(
          TelemetryStartOutcome.storageFailure,
          detail: '$error',
        );
      }
      _resetRecorder();
      _releasePidArtifactCommand();
      _publish();
      return TelemetryStartResult(
        TelemetryStartOutcome.storageFailure,
        '$error',
      );
    }
  }

  void onTelemetry(TelemetrySnapshot snapshot) {
    if (_expireDurationLimitIfDue()) return;
    if (!_recorder.isAccepting) return;
    try {
      _recorder.ingest(snapshot);
    } on _EventRejected catch (rejected) {
      _beginFinalization(rejected.reason);
    }
    if (_recorder.state.phase == TelemetryRecorderPhase.finalizing) {
      _beginFinalization(
        _recorder.state.terminalReason ??
            TelemetryTerminalReason.configurationChanged,
      );
    }
    _publish();
  }

  void onSessionBoundary(ObdSessionBoundary boundary) {
    final reason = switch (boundary.reason) {
      ObdSessionBoundaryReason.userDisconnect =>
        TelemetryTerminalReason.disconnect,
      ObdSessionBoundaryReason.linkLoss => TelemetryTerminalReason.disconnect,
      ObdSessionBoundaryReason.sessionReplacement =>
        TelemetryTerminalReason.sessionReplacement,
    };
    _beginFinalization(reason);
  }

  void onForegroundChanged(bool foreground) {
    if (!foreground) _beginFinalization(TelemetryTerminalReason.background);
  }

  void stop() => _beginFinalization(TelemetryTerminalReason.user);

  /// Dismisses only a settled, informational result from this process.
  ///
  /// Canonical files are untouched. A restart-owned state cannot be dismissed
  /// because hiding it would also hide the fact that the process still owns
  /// locks or an uncontained staging artifact.
  bool dismissTerminalOutcome() {
    if (state.requiresRestart ||
        (state.phase != TelemetryRecorderPhase.completed &&
            state.phase != TelemetryRecorderPhase.failed)) {
      return false;
    }
    _resetRecorder();
    _publish();
    return true;
  }

  Future<void> drainFinalization() => _finalization ?? Future<void>.value();

  Future<void> dispose() {
    _durationLimitTimer?.cancel();
    _durationLimitTimer = null;
    _invalidateAppendFailureHandler();
    return _states.close();
  }

  void _beginFinalization(TelemetryTerminalReason reason) {
    if (_recorder.state.phase != TelemetryRecorderPhase.recording &&
        _recorder.state.phase != TelemetryRecorderPhase.finalizing) {
      return;
    }
    _durationLimitTimer?.cancel();
    _durationLimitTimer = null;
    _recordingEndedElapsedUs ??= elapsedUs();
    _recorder.stop(reason: reason);
    _publish();
    _finalization ??= _finalize();
  }

  Future<void> _finalize() async {
    final writer = _writer!;
    if (_recorder.state.valueCount == 0) {
      late final TelemetryCloseResult close;
      try {
        close = await writer.closeForAbort();
      } on Object {
        _markRestartRequired();
        return;
      }
      if (close != TelemetryCloseResult.closed) {
        _markRestartRequired();
        return;
      }
      late final TelemetryCleanupResult cleanup;
      try {
        cleanup = await writer.deleteZeroValue();
      } on Object {
        _markRestartRequired();
        return;
      }
      if (cleanup == TelemetryCleanupResult.failed) {
        _markRestartRequired();
        return;
      }
      _resetRecorder();
      _releasePidArtifact();
      _publish();
      return;
    }

    final state = _recorder.state;
    final footer = TelemetrySessionFooter(
      endedAtUtc: _endedAtUtcForFooter(),
      terminalReason: state.terminalReason!,
      valueCount: state.valueCount,
      statusCount: state.statusCount,
      gapCount: state.gapCount,
      bytesBeforeFooter: writer.bytesBeforeFooter,
    );
    late final TelemetryFinalizeResult result;
    try {
      result = await writer.finalizeAndInstall(footer);
    } on Object {
      _markRestartRequired();
      return;
    }
    switch (result) {
      case TelemetryFinalizeResult.installed:
        _invalidateAppendFailureHandler();
        _recorder.complete(bytesBeforeFooter: writer.bytesBeforeFooter);
        _releasePidArtifact();
        break;
      case TelemetryFinalizeResult.preservedFailure:
        _invalidateAppendFailureHandler();
        _recorder.failStorage();
        _releasePidArtifact();
        break;
      case TelemetryFinalizeResult.uncontainedFailure:
        _invalidateAppendFailureHandler();
        _markRestartRequired();
        break;
    }
    _publish();
  }

  Future<TelemetryStartResult> _abortPreparation(
    TelemetryStartOutcome outcome, {
    String? detail,
  }) async {
    final writer = _writer;
    if (writer == null) {
      _resetRecorder();
      _releasePidArtifactCommand();
      _publish();
      return TelemetryStartResult(outcome, detail);
    }
    late final TelemetryCloseResult close;
    try {
      close = await writer.closeForAbort();
    } on Object {
      _markRestartRequired();
      return const TelemetryStartResult(TelemetryStartOutcome.restartRequired);
    }
    if (close != TelemetryCloseResult.closed) {
      _markRestartRequired();
      return const TelemetryStartResult(TelemetryStartOutcome.restartRequired);
    }
    late final TelemetryCleanupResult cleanup;
    try {
      cleanup = await writer.deleteZeroValue();
    } on Object {
      _markRestartRequired();
      return const TelemetryStartResult(TelemetryStartOutcome.restartRequired);
    }
    if (cleanup == TelemetryCleanupResult.failed) {
      _markRestartRequired();
      return const TelemetryStartResult(TelemetryStartOutcome.restartRequired);
    }
    _resetRecorder();
    _releasePidArtifactCommand();
    _publish();
    return TelemetryStartResult(outcome, detail);
  }

  TelemetryStartOutcome? _initialFailure(
    TelemetryStartEnvironmentSnapshot value,
  ) {
    if (!value.connected) return TelemetryStartOutcome.disconnected;
    if (!value.foreground) return TelemetryStartOutcome.background;
    if (!value.speedKnown ||
        !value.speedKmh.isFinite ||
        value.observedElapsedUs > value.speedFreshUntilElapsedUs) {
      return TelemetryStartOutcome.speedUnknown;
    }
    if (value.speedKmh > 5) return TelemetryStartOutcome.moving;
    return null;
  }

  TelemetryRecorder _newRecorder() => TelemetryRecorder(
    utcNow: utcNow,
    // Wall/epoch clocks are fine for duration limits and progress, but the
    // session recorder treats elapsedUs as microseconds since acceptance —
    // adding an absolute epoch timestamp onto startedAtUtc invents a future
    // observation time and marks every live reading stale.
    elapsedUs: _sessionElapsedUs,
    onEvent: _appendEventSynchronously,
  );

  int _sessionElapsedUs() {
    final started = _recordingStartedElapsedUs;
    if (started == null) return 0;
    final delta = elapsedUs() - started;
    return delta < 0 ? 0 : delta;
  }

  void _appendEventSynchronously(TelemetryEvent event) {
    final result = _writer!.tryAppendEvent(
      TelemetrySessionCodec.encodeEventLine(event),
    );
    if (result == TelemetryAppendResult.accepted) return;
    final reason = switch (result) {
      TelemetryAppendResult.storageBackpressure =>
        TelemetryTerminalReason.storageBackpressure,
      TelemetryAppendResult.sessionSizeLimit =>
        TelemetryTerminalReason.sessionSizeLimit,
      TelemetryAppendResult.librarySizeLimit =>
        TelemetryTerminalReason.librarySizeLimit,
      _ => TelemetryTerminalReason.storageFailure,
    };
    throw _EventRejected(reason);
  }

  void _onAppendFailure(TelemetryStagingWriter writer, int generation) {
    if (!identical(_writer, writer) || generation != _writerGeneration) return;
    _beginFinalization(TelemetryTerminalReason.storageFailure);
  }

  TelemetryStartOutcome? _revalidate(String checkpoint) {
    final current = environment.snapshot(checkpoint);
    final permit = _permit!;
    if (current.connectionGeneration != permit.connectionGeneration) {
      return TelemetryStartOutcome.startInvalidatedSessionReplacement;
    }
    if (!current.connected) {
      return TelemetryStartOutcome.startInvalidatedDisconnect;
    }
    if (!current.foreground ||
        current.foregroundEpoch != permit.foregroundEpoch) {
      return TelemetryStartOutcome.startInvalidatedBackground;
    }
    // Fresh stopped readings may renew the current freshness window. The
    // safety epoch still proves that no observed moving/unknown edge occurred
    // while preparation awaited storage.
    if (!current.speedKnown ||
        !current.speedKmh.isFinite ||
        current.observedElapsedUs > current.speedFreshUntilElapsedUs) {
      return TelemetryStartOutcome.startInvalidatedSpeedUnknown;
    }
    if (current.speedKmh > 5 || current.safetyEpoch != permit.safetyEpoch) {
      return switch (current.safetyInvalidation) {
        TelemetryStartSafetyInvalidation.speedUnknown =>
          TelemetryStartOutcome.startInvalidatedSpeedUnknown,
        TelemetryStartSafetyInvalidation.moving ||
        null => TelemetryStartOutcome.startInvalidatedMoving,
      };
    }
    return null;
  }

  void _markRestartRequired() {
    _invalidateAppendFailureHandler();
    _recorder.state = _recorder.state.copyWith(
      errorCategory: TelemetryRecorderErrorCategory.restartRequired,
      requiresRestart: true,
    );
    _publish();
  }

  void _resetRecorder() {
    _durationLimitTimer?.cancel();
    _durationLimitTimer = null;
    _invalidateAppendFailureHandler();
    _writer = null;
    _permit = null;
    _finalization = null;
    _recordingStartedElapsedUs = null;
    _recordingEndedElapsedUs = null;
    _sessionId = null;
    _effectiveSessionLimit = null;
    _recorder = _newRecorder();
  }

  void _invalidateAppendFailureHandler() {
    _writerGeneration++;
    final writer = _writer;
    if (writer case final TelemetryAppendFailureNotifier notifier) {
      notifier.setAppendFailureHandler(null);
    }
  }

  void _armDurationLimit() {
    _durationLimitTimer?.cancel();
    _durationLimitTimer = scheduleDurationLimit(
      telemetryRecorderDurationLimit,
      _expireDurationLimit,
    );
  }

  void _expireDurationLimit() {
    _durationLimitTimer = null;
    if (_expireDurationLimitIfDue()) return;
    final started = _recordingStartedElapsedUs;
    if (started == null || !_recorder.isAccepting) return;
    final remainingUs =
        telemetryRecorderDurationLimit.inMicroseconds - (elapsedUs() - started);
    _durationLimitTimer = scheduleDurationLimit(
      Duration(microseconds: remainingUs <= 0 ? 1 : remainingUs),
      _expireDurationLimit,
    );
  }

  bool _expireDurationLimitIfDue() {
    final started = _recordingStartedElapsedUs;
    if (started == null || !_recorder.isAccepting) return false;
    if (elapsedUs() - started < telemetryRecorderDurationLimit.inMicroseconds) {
      return false;
    }
    _beginFinalization(TelemetryTerminalReason.durationLimit);
    return true;
  }

  void _releasePidArtifactCommand() {
    _releasePidArtifact();
    _releaseCommand();
  }

  void _releasePidArtifact() {
    final pid = _pidToken;
    if (pid != null) {
      pidMutationLock.release(pid);
      _pidToken = null;
    }
    _releaseArtifact();
  }

  void _releaseArtifact() {
    final artifact = _artifactToken;
    if (artifact != null) {
      artifactGate.release(artifact);
      _artifactToken = null;
    }
  }

  void _releaseCommand() {
    final command = _commandToken;
    if (command != null) {
      startCommandMutex.release(command);
      _commandToken = null;
    }
  }

  void _publish() {
    _lifecycleEpoch++;
    if (!_states.isClosed) _states.add(state);
  }
}

final class TelemetryRecorderProgress {
  const TelemetryRecorderProgress({
    required this.state,
    required this.elapsedUs,
    required this.bytesBeforeFooter,
    required this.effectiveSessionLimit,
    required this.sessionId,
  });

  final TelemetryRecorderState state;
  final int elapsedUs;
  final int bytesBeforeFooter;
  final int? effectiveSessionLimit;
  final String? sessionId;
}

final class _EventRejected implements Exception {
  const _EventRejected(this.reason);

  final TelemetryTerminalReason reason;
}

/// Internal control-flow signal used by production storage checkpoints.
///
/// Storage layers may catch this only long enough to contain an artifact, then
/// must rethrow it so the root can preserve the typed invalidation outcome.
final class TelemetryStartPreparationInvalidatedException implements Exception {
  const TelemetryStartPreparationInvalidatedException(this.outcome);

  final TelemetryStartOutcome outcome;
}

/// Override seam for application wiring. The default cannot create artifacts.
final telemetryRecorderRuntimeProvider = Provider<TelemetryRecorderRuntime>(
  (ref) => TelemetryRecorderRuntime(
    environment: const _FailClosedEnvironment(),
    storage: const _FailClosedStorage(),
    utcNow: () => DateTime.now().toUtc(),
    elapsedUs: () => DateTime.now().microsecondsSinceEpoch,
  ),
);

final telemetryRecorderBoundaryStreamProvider =
    Provider<Stream<ObdSessionBoundary>>(
      (ref) => ref.read(obdSessionProvider.notifier).sessionBoundaries,
    );

final telemetryRecorderForegroundStreamProvider = Provider<Stream<bool>>(
  (ref) => ref.read(obdSessionProvider.notifier).foregroundChanges,
);

/// Non-autoDispose root controller. The app shell must eagerly read this once.
final telemetryRecorderControllerProvider = Provider<RootTelemetryRecorder>((
  ref,
) {
  final runtime = ref.watch(telemetryRecorderRuntimeProvider);
  final controller = RootTelemetryRecorder(
    environment: runtime.environment,
    storage: runtime.storage,
    startCommandMutex: ref.watch(startCommandMutexProvider),
    artifactGate: ref.watch(artifactOperationGateProvider),
    pidMutationLock: ref.watch(pidMutationLockProvider),
    utcNow: runtime.utcNow,
    elapsedUs: runtime.elapsedUs,
    pidDefinitionsSettled: () =>
        ref.read(pidRegistryProvider.notifier).pidDefinitionsReadyForRecording,
  );
  ref.listen(telemetryProvider, (_, next) {
    final value = authoritativeTelemetryValue(next);
    if (value != null) controller.onTelemetry(value);
  });
  final boundaries = ref
      .read(telemetryRecorderBoundaryStreamProvider)
      .listen(controller.onSessionBoundary);
  final foreground = ref
      .read(telemetryRecorderForegroundStreamProvider)
      .listen(controller.onForegroundChanged);
  ref.onDispose(() {
    unawaited(boundaries.cancel());
    unawaited(foreground.cancel());
    unawaited(controller.dispose());
  });
  return controller;
});

/// Seeded, root-stable UI projection. Phase transitions are delivered from the
/// controller's synchronous stream; the timer advances elapsed copy without
/// making recording ownership screen-local.
class TelemetryRecorderProgressNotifier
    extends Notifier<TelemetryRecorderProgress> {
  StreamSubscription<TelemetryRecorderState>? _states;
  Timer? _ticker;

  @override
  TelemetryRecorderProgress build() {
    final controller = ref.read(telemetryRecorderControllerProvider);
    _states = controller.states.listen((_) => state = controller.progress);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final phase = controller.state.phase;
      if (phase == TelemetryRecorderPhase.preparing ||
          phase == TelemetryRecorderPhase.recording ||
          phase == TelemetryRecorderPhase.finalizing) {
        state = controller.progress;
      }
    });
    ref.onDispose(() {
      unawaited(_states?.cancel());
      _ticker?.cancel();
    });
    return controller.progress;
  }
}

final telemetryRecorderProgressProvider =
    NotifierProvider<
      TelemetryRecorderProgressNotifier,
      TelemetryRecorderProgress
    >(TelemetryRecorderProgressNotifier.new);

final class _FailClosedEnvironment implements TelemetryStartEnvironment {
  const _FailClosedEnvironment();

  @override
  TelemetryStartEnvironmentSnapshot snapshot(String checkpoint) =>
      const TelemetryStartEnvironmentSnapshot(
        connected: false,
        foreground: false,
        connectionGeneration: -1,
        foregroundEpoch: -1,
        safetyEpoch: -1,
        speedKnown: false,
        speedKmh: double.nan,
        speedFreshUntilElapsedUs: -1,
        observedElapsedUs: 0,
      );
}

final class _FailClosedStorage implements TelemetryRecorderStorage {
  const _FailClosedStorage();

  @override
  Future<void> prepareDirectory({
    void Function(String checkpoint)? checkpoint,
  }) => Future<void>.error(StateError('telemetry storage is not wired'));

  @override
  Future<TelemetryStorageQuota> scanQuota({
    void Function(String checkpoint)? checkpoint,
  }) => Future<TelemetryStorageQuota>.error(
    StateError('telemetry storage is not wired'),
  );

  @override
  Future<TelemetryStagingWriter> createExclusive(
    TelemetrySessionHeader Function(String sessionId) headerForId, {
    required TelemetryStorageQuota quota,
    void Function(String checkpoint)? checkpoint,
  }) => Future<TelemetryStagingWriter>.error(
    StateError('telemetry storage is not wired'),
  );
}
