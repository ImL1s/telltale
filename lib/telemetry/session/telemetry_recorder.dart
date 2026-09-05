library;

import '../../obd/pid/pid.dart';
import '../../obd/telemetry.dart';
import 'derived_estimates.dart';
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
FrozenPidDefinition freezePidDefinition(Pid pid, {String? assumptions}) {
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
      evidenceKind: pid.isCustom ? 'userSupplied' : pid.evidenceKind,
      assumptions: assumptions,
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

  void ingest(
    TelemetrySnapshot snapshot, {
    Map<String, double> derivedValues = const {},
  }) {
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

    final started = _header!.startedAtUtc.toUtc();
    // [elapsedUs] must be session-relative (µs since acceptance), not a wall
    // or epoch clock. Absolute clocks make derivedObserved jump decades ahead
    // and every reading looks stale under isStaleAt.
    final elapsed = _nextElapsed();
    final derivedObserved = started.add(Duration(microseconds: elapsed));
    var observedAt = utcNow().toUtc();
    // Any backward wall-clock step (before start or mid-session) must not
    // emit earlier timestamps than the monotonic session axis.
    if (observedAt.isBefore(derivedObserved)) {
      observedAt = derivedObserved;
    }
    for (final entry in _frozen.entries) {
      if (!isAccepting) return;
      final id = entry.key;
      final reading = snapshot.readings[id];
      if (DerivedEstimates.isDerived(entry.value.definition)) {
        final derived = derivedValues[id];
        if (derived == null || !derived.isFinite) {
          if (!(_available[id] ?? false)) continue;
          const status = TelemetryStatus.noAnswer;
          if (_lastStatus[id] == status) continue;
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
          _refreshCounts(statusDelta: 1, gapDelta: 1);
          continue;
        }
        _available[id] = true;
        _lastStatus.remove(id);
        final definition = entry.value.definition;
        final outOfRange =
            (definition.minimum != null && derived < definition.minimum!) ||
            (definition.maximum != null && derived > definition.maximum!);
        onEvent(
          TelemetryEvent.value(
            observedAtUtc: observedAt,
            sourceTimestampUtc: observedAt,
            elapsedUs: elapsed,
            pidId: id,
            value: derived,
            quality: outOfRange
                ? TelemetryQuality.outOfReferenceRange
                : TelemetryQuality.valid,
          ),
        );
        _refreshCounts(valueDelta: 1);
        continue;
      }
      final isFresh =
          reading != null && _isFreshReading(reading, observedAt, started);
      if (isFresh) {
        final rawSourceUtc = reading.timestamp.toUtc();
        // Dedup by the raw sample identity so clamping to session start does
        // not freeze the lane while polling still produces new readings.
        final sourceUs = rawSourceUtc.microsecondsSinceEpoch;
        if (_lastSourceTimestampUs[id] == sourceUs) continue;
        _lastSourceTimestampUs[id] = sourceUs;
        var sourceUtc = rawSourceUtc;
        if (sourceUtc.isBefore(started)) {
          sourceUtc = started;
        }
        if (sourceUtc.isAfter(observedAt)) {
          sourceUtc = observedAt;
        }
        _available[id] = true;
        _lastStatus.remove(id);
        final definition = entry.value.definition;
        final outOfRange =
            (definition.minimum != null &&
                reading.value < definition.minimum!) ||
            (definition.maximum != null && reading.value > definition.maximum!);
        onEvent(
          TelemetryEvent.value(
            observedAtUtc: observedAt,
            sourceTimestampUtc: sourceUtc,
            elapsedUs: elapsed,
            pidId: id,
            value: reading.value,
            quality: outOfRange
                ? TelemetryQuality.outOfReferenceRange
                : TelemetryQuality.valid,
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
      endedAtUtc: _endedAtUtc(),
      terminalReason: state.terminalReason!,
      valueCount: state.valueCount,
      statusCount: state.statusCount,
      gapCount: state.gapCount,
      bytesBeforeFooter: bytesBeforeFooter,
    );
    state = state.copyWith(phase: TelemetryRecorderPhase.completed);
    return footer;
  }

  /// Prefer wall clock, but never persist an end before the header start or
  /// before the monotonic recording end already observed in event lines.
  DateTime _endedAtUtc() {
    final wall = utcNow().toUtc();
    final started = _header?.startedAtUtc;
    if (started == null) return wall;
    final monoUs = _lastElapsedUs < 0 ? 0 : _lastElapsedUs;
    final monoEnd = started.add(Duration(microseconds: monoUs));
    if (wall.isBefore(started) || wall.isBefore(monoEnd)) return monoEnd;
    return wall;
  }

  bool _isFreshReading(Reading reading, DateTime observedAt, DateTime started) {
    if (!reading.value.isFinite) return false;
    final rawUtc = reading.timestamp.toUtc();
    if (rawUtc.isAfter(observedAt)) return false;
    var sampleUtc = rawUtc;
    // Measure sample age on the same axis as [observedAt]. After a backward
    // wall step, observedAt advances to start + elapsed while the reading may
    // still carry the pre-step wall timestamp.
    if (sampleUtc.isBefore(started)) sampleUtc = started;
    return observedAt.difference(sampleUtc) <= reading.maxAge;
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
