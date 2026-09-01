library;

import '../obd/pid/pid_library.dart';
import '../obd/telemetry.dart';
import 'app_share_coordinator.dart';
import 'obd_session.dart';

enum DrivingSafetyClassification { disconnected, stopped, moving, unknown }

class DrivingSafetyInput {
  const DrivingSafetyInput({
    required this.connectionPhase,
    required this.connectionEpoch,
    required this.foreground,
    required this.foregroundEpoch,
    required this.recorderBlocksArtifacts,
    required this.recorderEpoch,
    required this.telemetry,
    required this.nowUtc,
    required this.monotonicUs,
  });

  final ConnectionPhase connectionPhase;
  final int connectionEpoch;
  final bool foreground;
  final int foregroundEpoch;
  final bool recorderBlocksArtifacts;
  final int recorderEpoch;
  final TelemetrySnapshot telemetry;
  final DateTime nowUtc;
  final int monotonicUs;

  DrivingSafetyInput copyWith({
    ConnectionPhase? connectionPhase,
    int? connectionEpoch,
    bool? foreground,
    int? foregroundEpoch,
    bool? recorderBlocksArtifacts,
    int? recorderEpoch,
    TelemetrySnapshot? telemetry,
    DateTime? nowUtc,
    int? monotonicUs,
  }) => DrivingSafetyInput(
    connectionPhase: connectionPhase ?? this.connectionPhase,
    connectionEpoch: connectionEpoch ?? this.connectionEpoch,
    foreground: foreground ?? this.foreground,
    foregroundEpoch: foregroundEpoch ?? this.foregroundEpoch,
    recorderBlocksArtifacts:
        recorderBlocksArtifacts ?? this.recorderBlocksArtifacts,
    recorderEpoch: recorderEpoch ?? this.recorderEpoch,
    telemetry: telemetry ?? this.telemetry,
    nowUtc: nowUtc ?? this.nowUtc,
    monotonicUs: monotonicUs ?? this.monotonicUs,
  );
}

class DrivingInteractionSafetySnapshot {
  const DrivingInteractionSafetySnapshot({
    required this.classification,
    required this.foreground,
    required this.recorderBlocksArtifacts,
    required this.connectionEpoch,
    required this.foregroundEpoch,
    required this.recorderEpoch,
    required this.safetyEpoch,
  });

  final DrivingSafetyClassification classification;
  final bool foreground;
  final bool recorderBlocksArtifacts;
  final int connectionEpoch;
  final int foregroundEpoch;
  final int recorderEpoch;
  final int safetyEpoch;

  bool get canManageArtifacts =>
      foreground &&
      !recorderBlocksArtifacts &&
      (classification == DrivingSafetyClassification.disconnected ||
          classification == DrivingSafetyClassification.stopped);

  bool get canStartRecording =>
      foreground &&
      !recorderBlocksArtifacts &&
      classification == DrivingSafetyClassification.stopped;
}

class StartPreparationPermit {
  const StartPreparationPermit({
    required this.connectionEpoch,
    required this.foregroundEpoch,
    required this.recorderEpoch,
    required this.safetyEpoch,
  });

  final int connectionEpoch;
  final int foregroundEpoch;
  final int recorderEpoch;
  final int safetyEpoch;
}

class StartPermitValidation {
  const StartPermitValidation.valid() : cause = null;
  const StartPermitValidation.invalid(this.cause);

  final SharePermitCause? cause;
  bool get isValid => cause == null;
}

/// Stateful authority shared by Start, Share, History, and destructive
/// artifact actions.
///
/// It retains a safety epoch so a brief moving/unknown transition cannot be
/// erased by a later stopped sample before the next async checkpoint.
class DrivingInteractionSafetyPolicy implements AppSharePolicy {
  DrivingInteractionSafetyPolicy(this._readInput);

  final DrivingSafetyInput Function() _readInput;
  DrivingSafetyInput? _input;
  DrivingSafetyClassification? _classification;
  int _safetyEpoch = 0;
  SharePermitCause? _lastSafetyCause;

  /// Records a live input edge even when no operation is currently checking a
  /// permit. Production wiring calls this for every telemetry publication so
  /// a brief moving/unknown interval cannot be hidden by a later stopped
  /// sample before the next asynchronous Share checkpoint.
  void synchronize() {
    _refresh();
  }

  DrivingInteractionSafetySnapshot get current {
    final input = _refresh();
    return DrivingInteractionSafetySnapshot(
      classification: _classification!,
      foreground: input.foreground,
      recorderBlocksArtifacts: input.recorderBlocksArtifacts,
      connectionEpoch: input.connectionEpoch,
      foregroundEpoch: input.foregroundEpoch,
      recorderEpoch: input.recorderEpoch,
      safetyEpoch: _safetyEpoch,
    );
  }

  @override
  SharePreparationPermit? freeze() {
    final snapshot = current;
    if (!snapshot.canManageArtifacts) return null;
    return SharePreparationPermit(
      recorderEpoch: snapshot.recorderEpoch,
      foregroundEpoch: snapshot.foregroundEpoch,
      connectionEpoch: snapshot.connectionEpoch,
      safetyEpoch: snapshot.safetyEpoch,
      connectionClass:
          snapshot.classification == DrivingSafetyClassification.disconnected
          ? ShareConnectionClass.disconnected
          : ShareConnectionClass.connected,
    );
  }

  @override
  SharePermitValidation validate(SharePreparationPermit permit) {
    final input = _refresh();
    if (input.recorderEpoch != permit.recorderEpoch ||
        input.recorderBlocksArtifacts) {
      return const SharePermitValidation.invalid(SharePermitCause.recorder);
    }
    if (!input.foreground || input.foregroundEpoch != permit.foregroundEpoch) {
      return const SharePermitValidation.invalid(SharePermitCause.foreground);
    }
    if (input.connectionEpoch != permit.connectionEpoch) {
      return const SharePermitValidation.invalid(SharePermitCause.connection);
    }
    final classification = _classification!;
    if (permit.connectionClass == ShareConnectionClass.disconnected) {
      if (classification != DrivingSafetyClassification.disconnected) {
        return const SharePermitValidation.invalid(SharePermitCause.connection);
      }
    } else {
      final cause = _causeFor(classification);
      if (cause != null) return SharePermitValidation.invalid(cause);
    }
    if (_safetyEpoch != permit.safetyEpoch) {
      return SharePermitValidation.invalid(
        _lastSafetyCause ?? SharePermitCause.connection,
      );
    }
    return const SharePermitValidation.valid();
  }

  StartPreparationPermit? freezeStart() {
    final input = _refresh();
    if (!current.canStartRecording) return null;
    final reading = _freshSpeed(input);
    if (reading == null) return null;
    final age = input.nowUtc.toUtc().difference(reading.timestamp.toUtc());
    final remaining = reading.maxAge - age;
    if (remaining <= Duration.zero) return null;
    return StartPreparationPermit(
      connectionEpoch: input.connectionEpoch,
      foregroundEpoch: input.foregroundEpoch,
      recorderEpoch: input.recorderEpoch,
      safetyEpoch: _safetyEpoch,
    );
  }

  StartPermitValidation validateStart(StartPreparationPermit permit) {
    final input = _refresh();
    if (input.recorderEpoch != permit.recorderEpoch ||
        input.recorderBlocksArtifacts) {
      return const StartPermitValidation.invalid(SharePermitCause.recorder);
    }
    if (!input.foreground || input.foregroundEpoch != permit.foregroundEpoch) {
      return const StartPermitValidation.invalid(SharePermitCause.foreground);
    }
    if (input.connectionEpoch != permit.connectionEpoch ||
        input.connectionPhase != ConnectionPhase.connected) {
      return const StartPermitValidation.invalid(SharePermitCause.connection);
    }
    // Validate the current reading rather than the reading that created the
    // permit. A continuously stopped stream may renew freshness, while the
    // safety epoch preserves any observed moving/unknown revocation edge.
    final cause = _causeFor(_classification!);
    if (cause != null) return StartPermitValidation.invalid(cause);
    if (_safetyEpoch != permit.safetyEpoch) {
      return StartPermitValidation.invalid(
        _lastSafetyCause ?? SharePermitCause.connection,
      );
    }
    return const StartPermitValidation.valid();
  }

  DrivingSafetyInput _refresh() {
    final next = _readInput();
    final nextClassification = _classify(next);
    final previous = _input;
    if (previous != null &&
        (previous.connectionEpoch != next.connectionEpoch ||
            _classification != nextClassification)) {
      _safetyEpoch++;
      final cause = _causeFor(nextClassification);
      if (cause != null) _lastSafetyCause = cause;
    }
    _input = next;
    _classification = nextClassification;
    return next;
  }

  static DrivingSafetyClassification _classify(DrivingSafetyInput input) {
    if (input.connectionPhase == ConnectionPhase.disconnected ||
        input.connectionPhase == ConnectionPhase.failed) {
      return DrivingSafetyClassification.disconnected;
    }
    if (input.connectionPhase != ConnectionPhase.connected) {
      return DrivingSafetyClassification.unknown;
    }
    final reading = _freshSpeed(input);
    if (reading == null) return DrivingSafetyClassification.unknown;
    return reading.value <= 5
        ? DrivingSafetyClassification.stopped
        : DrivingSafetyClassification.moving;
  }

  static Reading? _freshSpeed(DrivingSafetyInput input) {
    final id = PidLibrary.vehicleSpeed.id;
    if (input.telemetry.faults.containsKey(id)) return null;
    final reading = input.telemetry.readings[id];
    if (reading == null ||
        !reading.value.isFinite ||
        reading.timestamp.toUtc().isAfter(input.nowUtc.toUtc()) ||
        reading.isStaleAt(input.nowUtc.toUtc())) {
      return null;
    }
    return reading;
  }

  static SharePermitCause? _causeFor(
    DrivingSafetyClassification classification,
  ) => switch (classification) {
    DrivingSafetyClassification.moving => SharePermitCause.moving,
    DrivingSafetyClassification.unknown => SharePermitCause.speedUnknown,
    DrivingSafetyClassification.disconnected => SharePermitCause.connection,
    DrivingSafetyClassification.stopped => null,
  };
}
