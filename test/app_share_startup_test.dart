import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/core/share/app_share_platform_bridge.dart';
import 'package:torque_obd/core/share/share_lease_ledger.dart';
import 'package:torque_obd/state/app_share_coordinator.dart';
import 'package:torque_obd/state/artifact_operation_gate.dart';

void main() {
  test(
    'initialize removes allocated crash residue and releases artifact gate',
    () async {
      final directory = Directory.systemTemp.createTempSync('share-startup');
      addTearDown(() => directory.deleteSync(recursive: true));
      const id = '0123456789abcdef0123456789abcdef';
      final record = ShareLeaseRecord.allocated(
        id: id,
        sourceKind: ShareSourceKind.pidCsv,
        createdAtUtc: DateTime.utc(2026),
      );
      await ShareLeaseLedger(directory).install(record);
      await File('${directory.path}/${record.sourceFileName}')
          .writeAsString('incomplete');
      final gate = ArtifactOperationGate();
      final coordinator = _coordinator(directory: directory, gate: gate);

      final outcome = await coordinator.initialize();

      expect(outcome, AppShareInitializationOutcome.ready);
      expect(directory.listSync(), isEmpty);
      expect(gate.snapshot.isIdle, isTrue);
    },
  );

  test(
    'initialize blocks permanently when staging contains an unknown entry',
    () async {
      final directory = Directory.systemTemp.createTempSync('share-startup');
      addTearDown(() => directory.deleteSync(recursive: true));
      await File('${directory.path}/unknown.bin').writeAsString('unsafe');
      final gate = ArtifactOperationGate();
      final coordinator = _coordinator(directory: directory, gate: gate);

      final first = await coordinator.initialize();
      final retry = await coordinator.initialize();

      expect(first, AppShareInitializationOutcome.blocked);
      expect(retry, AppShareInitializationOutcome.blocked);
      expect(gate.snapshot.ownerId, 'share-startup');
      expect(gate.snapshot.operation, ArtifactOperation.recovery);
    },
  );

  test('blocked startup prevents share platform invocation', () async {
    final directory = Directory.systemTemp.createTempSync('share-startup');
    addTearDown(() => directory.deleteSync(recursive: true));
    await File('${directory.path}/unknown.bin').writeAsString('unsafe');
    final platform = _Platform();
    final coordinator = _coordinator(
      directory: directory,
      gate: ArtifactOperationGate(),
      platform: platform,
    );

    expect(
      await coordinator.initialize(),
      AppShareInitializationOutcome.blocked,
    );

    final outcome = await coordinator.share(_request());

    expect(outcome.error, ShareError.shareCleanupRequired);
    expect(platform.calls, 0);
  });

  test(
    'share rejects pending startup and admits only after reconstruction',
    () async {
      final directory = Directory.systemTemp.createTempSync('share-startup');
      addTearDown(() => directory.deleteSync(recursive: true));
      final root = Completer<Directory>();
      final platform = _Platform();
      final coordinator = _coordinator(
        directory: directory,
        gate: ArtifactOperationGate(),
        platform: platform,
        rootDirectory: () => root.future,
      );

      final initialization = coordinator.initialize();
      final pendingShare = await coordinator.share(_request());

      expect(platform.calls, 0);
      expect(pendingShare.error, ShareError.shareCleanupRequired);
      root.complete(directory);
      expect(await initialization, AppShareInitializationOutcome.ready);
      expect(
        (await coordinator.share(_request())).result,
        AppShareResult.selected,
      );
      expect(platform.calls, 1);
    },
  );

  test('policy denied startup is explicit and retryable', () async {
    final directory = Directory.systemTemp.createTempSync('share-startup');
    addTearDown(() => directory.deleteSync(recursive: true));
    final policy = _Policy(allowed: false);
    final coordinator = _coordinator(
      directory: directory,
      gate: ArtifactOperationGate(),
      policy: policy,
    );

    expect(
      await coordinator.initialize(),
      AppShareInitializationOutcome.policyDenied,
    );
    policy.allowed = true;
    expect(await coordinator.initialize(), AppShareInitializationOutcome.ready);
  });

  test('artifact busy startup is explicit and retryable', () async {
    final directory = Directory.systemTemp.createTempSync('share-startup');
    addTearDown(() => directory.deleteSync(recursive: true));
    final gate = ArtifactOperationGate();
    final blocker = gate.tryAcquire('test-owner', ArtifactOperation.record);
    final coordinator = _coordinator(directory: directory, gate: gate);

    expect(
      await coordinator.initialize(),
      AppShareInitializationOutcome.artifactBusy,
    );
    gate.release(blocker.token!);
    expect(await coordinator.initialize(), AppShareInitializationOutcome.ready);
  });

  test('ready startup result is cached without reconstructing again', () async {
    final directory = Directory.systemTemp.createTempSync('share-startup');
    addTearDown(() => directory.deleteSync(recursive: true));
    var rootCalls = 0;
    final coordinator = _coordinator(
      directory: directory,
      gate: ArtifactOperationGate(),
      rootDirectory: () async {
        rootCalls++;
        return directory;
      },
    );

    expect(await coordinator.initialize(), AppShareInitializationOutcome.ready);
    expect(await coordinator.initialize(), AppShareInitializationOutcome.ready);
    expect(rootCalls, 1);
  });
}

AppShareCoordinator _coordinator({
  required Directory directory,
  required ArtifactOperationGate gate,
  AppSharePlatform? platform,
  _Policy? policy,
  Future<Directory> Function()? rootDirectory,
}) => AppShareCoordinator(
  rootDirectory: rootDirectory ?? () async => directory,
  policy: policy ?? _Policy(),
  artifactGate: gate,
  platform: platform ?? _Platform(),
  idSource: () => 'fedcba9876543210fedcba9876543210',
  nowUtc: () => DateTime.utc(2026),
  availableBytes: (_) async => 64 * 1024 * 1024,
);

AppShareRequest _request() => AppShareRequest(
  sourceKind: ShareSourceKind.pidCsv,
  subject: 'PID',
  streamFactory: () => Stream.value('hello'.codeUnits),
);

class _Platform implements AppSharePlatform {
  int calls = 0;

  @override
  Future<AppShareResult> share(AppSharePlatformRequest request) async {
    calls++;
    return AppShareResult.selected;
  }
}

class _Policy implements AppSharePolicy {
  _Policy({this.allowed = true});

  bool allowed;

  @override
  SharePreparationPermit? freeze() => allowed
      ? const SharePreparationPermit(
          recorderEpoch: 1,
          foregroundEpoch: 1,
          connectionEpoch: 1,
          safetyEpoch: 1,
          connectionClass: ShareConnectionClass.disconnected,
        )
      : null;

  @override
  SharePermitValidation validate(SharePreparationPermit permit) =>
      const SharePermitValidation.valid();
}
