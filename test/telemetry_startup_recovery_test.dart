import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/app_share_coordinator.dart';
import 'package:torque_obd/state/artifact_operation_gate.dart';
import 'package:torque_obd/state/telemetry_recorder.dart';
import 'package:torque_obd/state/telemetry_runtime.dart';
import 'package:torque_obd/state/telemetry_sessions.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_codec.dart';
import 'package:torque_obd/telemetry/session/telemetry_recorder.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_store.dart';

void main() {
  late Directory root;
  late Directory telemetry;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('telemetry-startup-recovery-');
    telemetry = Directory('${root.path}/telltale-telemetry')..createSync();
  });

  tearDown(() async => root.delete(recursive: true));

  test(
    'inspect is path-free and commit rejects changed stat identity',
    () async {
      const id = '11111111111111111111111111111111';
      final part = File('${telemetry.path}/$id.ndjson.part')
        ..writeAsBytesSync(<int>[..._header(id), ..._value(1)]);
      final store = _store(root);

      final inspection = await store.inspectRecovery();
      expect(inspection.items.single.id, id);
      expect(
        inspection.items.single.classification,
        TelemetryRecoveryClassification.recoverAndInstall,
      );
      part.writeAsBytesSync(_status(2), mode: FileMode.append, flush: true);

      final result = await store.commitRecovery(inspection);

      expect(result.disposition, TelemetryRecoveryRunDisposition.retryable);
      expect(result.byId[id], TelemetryRecoveryOutcome.retryableFailure);
      expect(part.existsSync(), isTrue);
      expect(File('${telemetry.path}/$id.ndjson').existsSync(), isFalse);
    },
  );

  test(
    'revocation before truncate is retryable and leaves bytes unchanged',
    () async {
      const id = '22222222222222222222222222222222';
      final original = <int>[
        ..._header(id),
        ..._value(1),
        ...utf8.encode('{"type":"status"'),
      ];
      final part = File('${telemetry.path}/$id.ndjson.part')
        ..writeAsBytesSync(original);
      final store = _store(root);
      final inspection = await store.inspectRecovery();

      final result = await store.commitRecovery(
        inspection,
        checkpoint: (name) {
          if (name.contains('beforeTruncate')) throw StateError('revoked');
        },
      );

      expect(result.disposition, TelemetryRecoveryRunDisposition.retryable);
      expect(part.readAsBytesSync(), original);
    },
  );

  test(
    'revocation before zero-value delete leaves staging unchanged',
    () async {
      const id = '99999999999999999999999999999999';
      final original = <int>[..._header(id), ..._status(1)];
      final part = File('${telemetry.path}/$id.ndjson.part')
        ..writeAsBytesSync(original);
      final store = _store(root);
      final inspection = await store.inspectRecovery();

      final result = await store.commitRecovery(
        inspection,
        checkpoint: (name) {
          if (name.contains('beforeDelete')) throw StateError('revoked');
        },
      );

      expect(result.disposition, TelemetryRecoveryRunDisposition.retryable);
      expect(part.readAsBytesSync(), original);
    },
  );

  test(
    'revocation before unchanged install leaves staging unchanged',
    () async {
      const id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final prefix = <int>[..._header(id), ..._value(1)];
      final original = <int>[
        ...prefix,
        ...TelemetrySessionCodec.encodeFooterLine(
          TelemetrySessionFooter(
            endedAtUtc: DateTime.utc(2026, 1, 1, 0, 0, 2),
            terminalReason: TelemetryTerminalReason.user,
            valueCount: 1,
            statusCount: 0,
            gapCount: 0,
            bytesBeforeFooter: prefix.length,
          ),
        ),
      ];
      final part = File('${telemetry.path}/$id.ndjson.part')
        ..writeAsBytesSync(original);
      final store = _store(root);
      final inspection = await store.inspectRecovery();

      final result = await store.commitRecovery(
        inspection,
        checkpoint: (name) {
          if (name.contains('beforeRename')) throw StateError('revoked');
        },
      );

      expect(result.disposition, TelemetryRecoveryRunDisposition.retryable);
      expect(part.readAsBytesSync(), original);
      expect(File('${telemetry.path}/$id.ndjson').existsSync(), isFalse);
    },
  );

  for (final boundary in <String>[
    'beforeWrite',
    'beforeFlush',
    'beforeClose',
    'beforeRename',
  ]) {
    test('revocation at $boundary after mutation requires restart', () async {
      final digit =
          (3 +
                  <String>[
                    'beforeWrite',
                    'beforeFlush',
                    'beforeClose',
                    'beforeRename',
                  ].indexOf(boundary))
              .toString();
      final id = digit * 32;
      File('${telemetry.path}/$id.ndjson.part').writeAsBytesSync(<int>[
        ..._header(id),
        ..._value(1),
        ...utf8.encode('{"type":"status"'),
      ]);
      final store = _store(root);
      final inspection = await store.inspectRecovery();
      var laterCheckpointSeen = false;

      final result = await store.commitRecovery(
        inspection,
        checkpoint: (name) {
          if (laterCheckpointSeen) {
            fail('mutation continued after revocation: $name');
          }
          if (name.contains(boundary)) {
            laterCheckpointSeen = true;
            throw StateError('revoked');
          }
        },
      );

      expect(
        result.disposition,
        TelemetryRecoveryRunDisposition.restartRequired,
      );
      expect(result.byId[id], TelemetryRecoveryOutcome.restartRequired);
    });
  }

  test('completed recovery is idempotent across a fresh process', () async {
    const id = '77777777777777777777777777777777';
    File('${telemetry.path}/$id.ndjson.part')
        .writeAsBytesSync(<int>[..._header(id), ..._value(1)]);

    final first = await _store(root).recover();
    final second = await _store(root).recover();
    final installed = File('${telemetry.path}/$id.ndjson').readAsStringSync();

    expect(first.byId[id], TelemetryRecoveryOutcome.recoveredAndInstalled);
    expect(second.byId, isEmpty);
    expect(RegExp('"type":"footer"').allMatches(installed), hasLength(1));
  });

  test('controller is recorder-first and does not freeze policy', () async {
    final policy = _Policy();
    final gate = ArtifactOperationGate();
    final container = _container(
      root: root,
      policy: policy,
      gate: gate,
      progress: const TelemetryRecorderProgress(
        state: TelemetryRecorderState(
          phase: TelemetryRecorderPhase.recording,
          valueCount: 0,
          statusCount: 0,
          gapCount: 0,
        ),
        elapsedUs: 0,
        bytesBeforeFooter: 0,
        effectiveSessionLimit: null,
        sessionId: null,
      ),
    );
    addTearDown(container.dispose);

    final state = await container
        .read(telemetryStartupRecoveryProvider.notifier)
        .initialize();

    expect(state.phase, TelemetryStartupRecoveryPhase.retryable);
    expect(policy.freezeCount, 0);
    expect(gate.snapshot.isIdle, isTrue);
  });

  test('controller caches ready and retries only retryable state', () async {
    final policy = _Policy(denyFreezeCount: 1);
    final gate = ArtifactOperationGate();
    final container = _container(root: root, policy: policy, gate: gate);
    addTearDown(container.dispose);
    final controller = container.read(
      telemetryStartupRecoveryProvider.notifier,
    );

    expect(
      (await controller.initialize()).phase,
      TelemetryStartupRecoveryPhase.retryable,
    );
    expect(
      (await controller.retry()).phase,
      TelemetryStartupRecoveryPhase.ready,
    );
    expect(
      (await controller.initialize()).phase,
      TelemetryStartupRecoveryPhase.ready,
    );
    expect(policy.freezeCount, 2);
    expect(gate.snapshot.isIdle, isTrue);
  });

  test(
    'post-truncate policy revocation caches restart and retains gate',
    () async {
      const id = '88888888888888888888888888888888';
      File('${telemetry.path}/$id.ndjson.part').writeAsBytesSync(<int>[
        ..._header(id),
        ..._value(1),
        ...utf8.encode('{"type":"status"'),
      ]);
      final policy = _Policy(invalidateAtValidation: 5);
      final gate = ArtifactOperationGate();
      final container = _container(root: root, policy: policy, gate: gate);
      addTearDown(container.dispose);
      final controller = container.read(
        telemetryStartupRecoveryProvider.notifier,
      );

      final first = await controller.initialize();
      final second = await controller.retry();

      expect(first.phase, TelemetryStartupRecoveryPhase.restartRequired);
      expect(second.phase, TelemetryStartupRecoveryPhase.restartRequired);
      expect(gate.snapshot.isIdle, isFalse);
      expect(gate.snapshot.operation, ArtifactOperation.recovery);
    },
  );
}

ProviderContainer _container({
  required Directory root,
  required _Policy policy,
  required ArtifactOperationGate gate,
  TelemetryRecorderProgress? progress,
}) {
  final fixedProgress =
      progress ??
      const TelemetryRecorderProgress(
        state: TelemetryRecorderState.idle(),
        elapsedUs: 0,
        bytesBeforeFooter: 0,
        effectiveSessionLimit: null,
        sessionId: null,
      );
  return ProviderContainer(
    overrides: [
      telemetrySessionStoreProvider.overrideWithValue(_store(root)),
      appSharePolicyProvider.overrideWithValue(policy),
      artifactOperationGateProvider.overrideWithValue(gate),
      telemetryRecorderProgressProvider.overrideWith(
        () => _FixedProgressNotifier(fixedProgress),
      ),
    ],
  );
}

TelemetrySessionStore _store(Directory root) => TelemetrySessionStore(
  documentsDirectory: () async => root,
  nowUtc: () => DateTime.utc(2026, 8, 30, 12),
);

class _FixedProgressNotifier extends TelemetryRecorderProgressNotifier {
  _FixedProgressNotifier(this.value);
  final TelemetryRecorderProgress value;
  @override
  TelemetryRecorderProgress build() => value;
}

class _Policy implements AppSharePolicy {
  _Policy({this.denyFreezeCount = 0, this.invalidateAtValidation});
  final int denyFreezeCount;
  final int? invalidateAtValidation;
  var freezeCount = 0;
  var validationCount = 0;

  @override
  SharePreparationPermit? freeze() {
    freezeCount++;
    if (freezeCount <= denyFreezeCount) return null;
    return const SharePreparationPermit(
      recorderEpoch: 1,
      foregroundEpoch: 1,
      connectionEpoch: 1,
      safetyEpoch: 1,
      connectionClass: ShareConnectionClass.disconnected,
    );
  }

  @override
  SharePermitValidation validate(SharePreparationPermit permit) {
    validationCount++;
    if (validationCount >= (invalidateAtValidation ?? 1 << 30)) {
      return const SharePermitValidation.invalid(SharePermitCause.connection);
    }
    return const SharePermitValidation.valid();
  }
}

List<int> _header(String id) => TelemetrySessionCodec.encodeHeaderLine(
  TelemetrySessionHeader(
    sessionId: id,
    startedAtUtc: DateTime.utc(2026),
    source: TelemetrySource.demo,
    transport: TransportKind.demo,
    protocol: 'AUTO',
    signals: <FrozenPidDefinition>[
      FrozenPidDefinition.freeze(
        const TelemetrySignalDefinition(
          id: '010C',
          name: 'RPM',
          shortName: 'RPM',
          request: '010C',
          header: '',
          unit: 'rpm',
          unitProvenance: UnitProvenance.standardDirectCanonical,
          minimum: 0,
          maximum: 8000,
          isCustom: false,
          variant: '',
          priority: 0,
          equation: '((A*256)+B)/4',
        ),
      ),
    ],
  ),
);

List<int> _value(int second) => TelemetrySessionCodec.encodeEventLine(
  TelemetryEvent.value(
    observedAtUtc: DateTime.utc(2026, 1, 1, 0, 0, second),
    sourceTimestampUtc: DateTime.utc(2026, 1, 1, 0, 0, second),
    elapsedUs: second * Duration.microsecondsPerSecond,
    pidId: '010C',
    value: second.toDouble(),
  ),
);

List<int> _status(int second) => TelemetrySessionCodec.encodeEventLine(
  TelemetryEvent.status(
    observedAtUtc: DateTime.utc(2026, 1, 1, 0, 0, second),
    elapsedUs: second * Duration.microsecondsPerSecond,
    pidId: '010C',
    status: TelemetryStatus.stale,
  ),
);
