import 'package:flutter_riverpod/flutter_riverpod.dart';

enum PidMutationFailure { locked }

const kPidMutationLockedMessage = '請先停止並儲存';

class PidMutationOutcome {
  const PidMutationOutcome._({required this.applied, this.failure});

  const PidMutationOutcome.applied() : this._(applied: true);

  const PidMutationOutcome.noChange() : this._(applied: false);

  const PidMutationOutcome.locked()
    : this._(applied: false, failure: PidMutationFailure.locked);

  final bool applied;
  final PidMutationFailure? failure;

  bool get isLocked => failure == PidMutationFailure.locked;

  @override
  bool operator ==(Object other) =>
      other is PidMutationOutcome &&
      other.applied == applied &&
      other.failure == failure;

  @override
  int get hashCode => Object.hash(applied, failure);
}

final class PidMutationToken {
  PidMutationToken._(this._lock, this._identity);

  final PidMutationLock _lock;
  final Object _identity;
}

/// Freezes active PID membership, ordering, and definitions for a recording.
class PidMutationLock {
  PidMutationToken? _active;
  String? _ownerId;

  bool get isLocked => _active != null;
  String? get ownerId => _ownerId;

  PidMutationToken? tryAcquire(String ownerId) {
    if (ownerId.trim().isEmpty) {
      throw ArgumentError.value(ownerId, 'ownerId', 'must not be blank');
    }
    if (_active != null) return null;
    final token = PidMutationToken._(this, Object());
    _active = token;
    _ownerId = ownerId;
    return token;
  }

  void release(PidMutationToken token) {
    if (!identical(token._lock, this) ||
        !identical(_active?._identity, token._identity)) {
      throw StateError('Only the active PID-mutation token may release');
    }
    _active = null;
    _ownerId = null;
  }
}

final pidMutationLockProvider = Provider<PidMutationLock>(
  (ref) => PidMutationLock(),
);
