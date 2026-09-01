import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/state/artifact_operation_gate.dart';

void main() {
  group('ArtifactOperationGate', () {
    test('grants exactly one synchronous unforgeable ownership token', () {
      final gate = ArtifactOperationGate();

      final first = gate.tryAcquire('recorder-1', ArtifactOperation.record);
      expect(first.acquired, isTrue);
      expect(first.token, isNotNull);
      expect(gate.snapshot.ownerId, 'recorder-1');
      expect(gate.snapshot.operation, ArtifactOperation.record);

      final blocked = gate.tryAcquire('share-1', ArtifactOperation.export);
      expect(blocked.acquired, isFalse);
      expect(blocked.failure, ArtifactAcquireFailure.artifactBusy);
      expect(
        gate.snapshot.ownerId,
        'recorder-1',
        reason: 'contention cannot mutate ownership',
      );

      gate.release(first.token!);
      expect(gate.snapshot.isIdle, isTrue);
    });

    test(
      'only the active token can release and an old token cannot repeat',
      () {
        final gate = ArtifactOperationGate();
        final token = gate
            .tryAcquire('owner', ArtifactOperation.recovery)
            .token!;

        gate.release(token);
        expect(() => gate.release(token), throwsStateError);

        final next = gate.tryAcquire('next', ArtifactOperation.delete).token!;
        expect(() => gate.release(token), throwsStateError);
        expect(gate.snapshot.ownerId, 'next');
        gate.release(next);
      },
    );

    test('blank owner ids are rejected before state changes', () {
      final gate = ArtifactOperationGate();
      expect(
        () => gate.tryAcquire('  ', ArtifactOperation.install),
        throwsArgumentError,
      );
      expect(gate.snapshot.isIdle, isTrue);
    });
  });

  group('StartCommandMutex', () {
    test('serializes Start commands independently of artifact ownership', () {
      final mutex = StartCommandMutex();
      final first = mutex.tryAcquire();
      expect(first, isNotNull);
      expect(mutex.tryAcquire(), isNull);
      mutex.release(first!);
      expect(mutex.tryAcquire(), isNotNull);
    });
  });
}
