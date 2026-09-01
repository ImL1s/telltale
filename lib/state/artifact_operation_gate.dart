import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Every operation that may create, replace, move, or delete an app artifact.
enum ArtifactOperation {
  record,
  finalize,
  recovery,
  install,
  delete,
  export,
  rawTranscriptShare,
  recoveredTranscriptShare,
  pidCsvShare,
}

enum ArtifactAcquireFailure { artifactBusy }

/// A read-only projection suitable for UI diagnostics and tests.
class ArtifactOperationSnapshot {
  const ArtifactOperationSnapshot._({this.ownerId, this.operation});

  const ArtifactOperationSnapshot.idle() : this._();

  final String? ownerId;
  final ArtifactOperation? operation;

  bool get isIdle => ownerId == null;
}

/// Capability returned only by [ArtifactOperationGate.tryAcquire].
///
/// The private constructor prevents a caller from fabricating a release token.
final class ArtifactOperationToken {
  ArtifactOperationToken._(this._gate, this._identity);

  final ArtifactOperationGate _gate;
  final Object _identity;
}

class ArtifactAcquireResult {
  const ArtifactAcquireResult._({this.token, this.failure});

  factory ArtifactAcquireResult.acquired(ArtifactOperationToken token) =>
      ArtifactAcquireResult._(token: token);

  const ArtifactAcquireResult.busy()
    : this._(failure: ArtifactAcquireFailure.artifactBusy);

  final ArtifactOperationToken? token;
  final ArtifactAcquireFailure? failure;

  bool get acquired => token != null;
}

/// Root-owned synchronous exclusion for every artifact mutation.
///
/// Acquisition never awaits and contention never changes the current owner.
class ArtifactOperationGate {
  ArtifactOperationToken? _active;
  ArtifactOperationSnapshot _snapshot = const ArtifactOperationSnapshot.idle();

  ArtifactOperationSnapshot get snapshot => _snapshot;

  ArtifactAcquireResult tryAcquire(
    String ownerId,
    ArtifactOperation operation,
  ) {
    if (ownerId.trim().isEmpty) {
      throw ArgumentError.value(ownerId, 'ownerId', 'must not be blank');
    }
    if (_active != null) return const ArtifactAcquireResult.busy();

    final token = ArtifactOperationToken._(this, Object());
    _active = token;
    _snapshot = ArtifactOperationSnapshot._(
      ownerId: ownerId,
      operation: operation,
    );
    return ArtifactAcquireResult.acquired(token);
  }

  void release(ArtifactOperationToken token) {
    if (!identical(token._gate, this) ||
        !identical(_active?._identity, token._identity)) {
      throw StateError('Only the active artifact-operation token may release');
    }
    _active = null;
    _snapshot = const ArtifactOperationSnapshot.idle();
  }
}

final artifactOperationGateProvider = Provider<ArtifactOperationGate>(
  (ref) => ArtifactOperationGate(),
);

final class StartCommandToken {
  StartCommandToken._(this._mutex, this._identity);

  final StartCommandMutex _mutex;
  final Object _identity;
}

/// Separate synchronous mutex for Start command admission.
class StartCommandMutex {
  StartCommandToken? _active;

  bool get isLocked => _active != null;

  StartCommandToken? tryAcquire() {
    if (_active != null) return null;
    final token = StartCommandToken._(this, Object());
    _active = token;
    return token;
  }

  void release(StartCommandToken token) {
    if (!identical(token._mutex, this) ||
        !identical(_active?._identity, token._identity)) {
      throw StateError('Only the active Start-command token may release');
    }
    _active = null;
  }
}

final startCommandMutexProvider = Provider<StartCommandMutex>(
  (ref) => StartCommandMutex(),
);
