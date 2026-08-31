library;

import '../../obd/pid/pid.dart';
import '../../obd/telemetry.dart';
import 'telemetry_session.dart';

enum TelemetryRecorderPhase {
  idle,
  preparing,
  recording,
  finalizing,
  completed,
  failed,
}

enum TelemetryRecorderErrorCategory { validation, storage, restartRequired }

class TelemetryRecorderState {
  const TelemetryRecorderState({
    required this.phase,
    this.terminalReason,
    this.errorCategory,
    this.valueCount = 0,
    this.statusCount = 0,
    this.gapCount = 0,
    this.requiresRestart = false,
  });

  const TelemetryRecorderState.idle()
    : this(phase: TelemetryRecorderPhase.idle);

  final TelemetryRecorderPhase phase;
  final TelemetryTerminalReason? terminalReason;
  final TelemetryRecorderErrorCategory? errorCategory;
  final int valueCount;
  final int statusCount;
  final int gapCount;
  final bool requiresRestart;

  TelemetryRecorderState copyWith({
    TelemetryRecorderPhase? phase,
    TelemetryTerminalReason? terminalReason,
    TelemetryRecorderErrorCategory? errorCategory,
    int? valueCount,
    int? statusCount,
    int? gapCount,
    bool? requiresRestart,
  }) => TelemetryRecorderState(
    phase: phase ?? this.phase,
    terminalReason: terminalReason ?? this.terminalReason,
    errorCategory: errorCategory ?? this.errorCategory,
    valueCount: valueCount ?? this.valueCount,
    statusCount: statusCount ?? this.statusCount,
    gapCount: gapCount ?? this.gapCount,
    requiresRestart: requiresRestart ?? this.requiresRestart,
  );
}

/// Converts the live PID definition to the exact immutable recording form.
FrozenPidDefinition freezePidDefinition(Pid pid) {
  final provenance = pid.isCustom
      ? UnitProvenance.userDefined
      : pid.isMode01 && pid.header == kDefaultHeader && pid.variant == null
      ? UnitProvenance.standardDirectCanonical
      : UnitProvenance.shippedDerivedOrVariant;
  return FrozenPidDefinition.freeze(
    TelemetrySignalDefinition(
      id: pid.id,
      name: pid.name,
      shortName: pid.shortName,
      request: pid.modeAndPid,
      header: pid.header,
      unit: pid.units,
      unitProvenance: provenance,
      minimum: pid.minValue,
      maximum: pid.maxValue,
      isCustom: pid.isCustom,
      variant: pid.variant ?? '',
      priority: pid.priority.index,
      equation: pid.equation,
    ),
  );
}

/// Pure acceptance/terminal state machine.
///
/// Storage ownership is deliberately outside this class. A root controller can
/// synchronously close this gate and then drain its writer without making an
/// OBD callback await file I/O.
class TelemetryRecorder {
  TelemetryRecorder({
    required this.utcNow,
    required this.elapsedUs,
    required this.onEvent,
  });

  final DateTime Function() utcNow;
  final int Function() elapsedUs;
  final void Function(TelemetryEvent event) onEvent;
  final Map<String, FrozenPidDefinition> _frozen =
      <String, FrozenPidDefinition>{};
  final Map<String, int> _lastSourceTimestampUs = <String, int>{};
  final Map<String, bool> _available = <String, bool>{};
  final Map<String, TelemetryStatus> _lastStatus = <String, TelemetryStatus>{};
  TelemetrySessionHeader? _header;
  int _lastElapsedUs = 0;

  TelemetryRecorderState state = const TelemetryRecorderState.idle();

  TelemetrySessionHeader? get header => _header;
  bool get isAccepting => state.phase == TelemetryRecorderPhase.recording;

  bool prepare(TelemetrySessionHeader header) {
    if (state.phase != TelemetryRecorderPhase.idle) return false;
    _header = header;
    _frozen
      ..clear()
      ..addEntries(
        header.signals.map(
          (definition) => MapEntry(definition.definition.id, definition),
        ),
      );
    state = const TelemetryRecorderState(
      phase: TelemetryRecorderPhase.preparing,
    );
    return true;
  }

  /// Opens acceptance without yielding. The root coordinator calls this only
  /// immediately after its final Start-permit validation.
  bool openAcceptance() {
    if (state.phase != TelemetryRecorderPhase.preparing) return false;
    state = state.copyWith(phase: TelemetryRecorderPhase.recording);
    return true;
  }

  void ingest(TelemetrySnapshot snapshot) {
    if (!isAccepting) return;

    // Validate every live definition before accepting any value from this
    // snapshot. A changed equation must not let an earlier map entry slip into
    // the canonical session before the mismatch is observed.
    for (final entry in snapshot.readings.entries) {
      final expected = _frozen[entry.key];
      if (expected == null) continue;
      FrozenPidDefinition current;
      try {
        current = freezePidDefinition(entry.value.pid);
      } on Object {
        stop(reason: TelemetryTerminalReason.configurationChanged);
        return;
      }
      if (!expected.matchesExact(current)) {
        stop(reason: TelemetryTerminalReason.configurationChanged);
        return;
      }
    }

    final observedAt = utcNow().toUtc();
    final elapsed = _nextElapsed();
    for (final entry in _frozen.entries) {
      if (!isAccepting) return;
      final id = entry.key;
      final reading = snapshot.readings[id];
      final isFresh =
          reading != null &&
          reading.value.isFinite &&
          !reading.timestamp.toUtc().isAfter(observedAt) &&
          !reading.isStaleAt(observedAt);
      if (isFresh) {
        final sourceUtc = reading.timestamp.toUtc();
        final sourceUs = sourceUtc.microsecondsSinceEpoch;
        // Do not reopen an unavailable lane without a new value line. Wall
        // clocks can jump backward so an already-recorded sample looks fresh
        // again; marking available here would invent a second gap when it
        // ages out, and the strict reader rejects that footer mismatch.
        if (_lastSourceTimestampUs[id] == sourceUs) continue;
        _lastSourceTimestampUs[id] = sourceUs;
        _available[id] = true;
        _lastStatus.remove(id);
        onEvent(
          TelemetryEvent.value(
            observedAtUtc: observedAt,
            sourceTimestampUtc: sourceUtc,
            elapsedUs: elapsed,
            pidId: id,
            value: reading.value,
          ),
        );
        _refreshCounts(valueDelta: 1);
        continue;
      }

      // A non-finite live object is invalid input rather than an unavailable
      // vehicle observation. It creates no canonical line.
      if (reading != null && !reading.value.isFinite) continue;
      final status = _statusFor(snapshot.faults[id]);
      if (_lastStatus[id] == status) continue;
      final opensGap = _available[id] ?? false;
      _available[id] = false;
      _lastStatus[id] = status;
      onEvent(
        TelemetryEvent.status(
          observedAtUtc: observedAt,
          elapsedUs: elapsed,
          pidId: id,
          status: status,
        ),
      );
      _refreshCounts(statusDelta: 1, gapDelta: opensGap ? 1 : 0);
    }
  }

  void stop({TelemetryTerminalReason reason = TelemetryTerminalReason.user}) {
    if (state.phase != TelemetryRecorderPhase.preparing &&
        state.phase != TelemetryRecorderPhase.recording &&
        state.phase != TelemetryRecorderPhase.finalizing) {
      return;
    }
    state = state.copyWith(
      phase: TelemetryRecorderPhase.finalizing,
      terminalReason: state.terminalReason ?? reason,
    );
  }

  TelemetrySessionFooter complete({required int bytesBeforeFooter}) {
    if (state.phase != TelemetryRecorderPhase.finalizing ||
        state.terminalReason == null) {
      throw StateError('Recorder is not ready to complete');
    }
    final footer = TelemetrySessionFooter(
      endedAtUtc: utcNow().toUtc(),
      terminalReason: state.terminalReason!,
      valueCount: state.valueCount,
      statusCount: state.statusCount,
      gapCount: state.gapCount,
      bytesBeforeFooter: bytesBeforeFooter,
    );
    state = state.copyWith(phase: TelemetryRecorderPhase.completed);
    return footer;
  }

  void failStorage({bool restartRequired = false}) {
    if (state.phase != TelemetryRecorderPhase.preparing &&
        state.phase != TelemetryRecorderPhase.recording &&
        state.phase != TelemetryRecorderPhase.finalizing) {
      return;
    }
    stop(reason: TelemetryTerminalReason.storageFailure);
    state = state.copyWith(
      phase: restartRequired
          ? TelemetryRecorderPhase.finalizing
          : TelemetryRecorderPhase.failed,
      errorCategory: restartRequired
          ? TelemetryRecorderErrorCategory.restartRequired
          : TelemetryRecorderErrorCategory.storage,
      requiresRestart: restartRequired,
    );
  }

  int _nextElapsed() {
    final candidate = elapsedUs();
    if (candidate > _lastElapsedUs) _lastElapsedUs = candidate;
    return _lastElapsedUs;
  }

  void _refreshCounts({
    int valueDelta = 0,
    int statusDelta = 0,
    int gapDelta = 0,
  }) {
    state = state.copyWith(
      valueCount: state.valueCount + valueDelta,
      statusCount: state.statusCount + statusDelta,
      gapCount: state.gapCount + gapDelta,
    );
  }

  static TelemetryStatus _statusFor(PidFault? fault) => switch (fault) {
    null => TelemetryStatus.stale,
    PidFault.unsupported => TelemetryStatus.unsupported,
    PidFault.formulaError => TelemetryStatus.formulaError,
    PidFault.busError => TelemetryStatus.busError,
    PidFault.headerNotOnThisBus => TelemetryStatus.headerMismatch,
    PidFault.refusedUnsafeService => TelemetryStatus.unsafeServiceRefusal,
    PidFault.noAnswer => TelemetryStatus.noAnswer,
  };
}
