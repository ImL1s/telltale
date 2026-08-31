import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/core/share/app_share_platform_bridge.dart';
import 'package:torque_obd/core/share/share_lease_ledger.dart';
import 'package:torque_obd/state/app_share_coordinator.dart';
import 'package:torque_obd/state/artifact_operation_gate.dart';

void main() {
  test(
    'one coordinator writes a durable lease before invoking platform',
    () async {
      final dir = Directory.systemTemp.createTempSync('share-coordinator');
      addTearDown(() => dir.deleteSync(recursive: true));
      final platform = _Platform();
      final coordinator = AppShareCoordinator(
        rootDirectory: () async => dir,
        policy: _Policy(),
        artifactGate: ArtifactOperationGate(),
        platform: platform,
        idSource: () => '0123456789abcdef0123456789abcdef',
        nowUtc: () => DateTime.utc(2026),
        availableBytes: (_) async => 64 * 1024 * 1024,
      );
      expect(
        await coordinator.initialize(),
        AppShareInitializationOutcome.ready,
      );
      final outcome = await coordinator.share(
        AppShareRequest(
          sourceKind: ShareSourceKind.pidCsv,
          subject: 'PID',
          streamFactory: () => Stream.value('hello'.codeUnits),
        ),
      );
      expect(outcome.result, AppShareResult.selected);
      expect(platform.calls, 1);
      final record = await ShareLeaseLedger(dir)
          .read('0123456789abcdef0123456789abcdef');
      expect(record!.state, ShareLeaseState.handedOffLease);
      expect(record.result, 'selected');
    },
  );

  test('failed and unavailable handoffs surface shareHandoffFailed', () async {
    for (final result in const [
      AppShareResult.failed,
      AppShareResult.unavailable,
    ]) {
      final dir = Directory.systemTemp.createTempSync('share-handoff-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final platform = _Platform()..result = result;
      final coordinator = AppShareCoordinator(
        rootDirectory: () async => dir,
        policy: _Policy(),
        artifactGate: ArtifactOperationGate(),
        platform: platform,
        idSource: () => 'fedcba9876543210fedcba9876543210',
        nowUtc: () => DateTime.utc(2026),
        availableBytes: (_) async => 64 * 1024 * 1024,
      );
      expect(
        await coordinator.initialize(),
        AppShareInitializationOutcome.ready,
      );
      final outcome = await coordinator.share(
        AppShareRequest(
          sourceKind: ShareSourceKind.pidCsv,
          subject: 'PID',
          streamFactory: () => Stream.value('staged'.codeUnits),
        ),
      );
      expect(outcome.result, result);
      expect(outcome.error, ShareError.shareHandoffFailed);
      expect(
        outcome.userFacingError,
        '檔案已準備完成，但系統分享介面無法開啟。',
      );
      expect(File(platform.lastPath!).existsSync(), isTrue);
    }
  });

  test('dismissed handoff stays a cancellation without error', () async {
    final dir = Directory.systemTemp.createTempSync('share-dismissed-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final platform = _Platform()..result = AppShareResult.dismissed;
    final coordinator = AppShareCoordinator(
      rootDirectory: () async => dir,
      policy: _Policy(),
      artifactGate: ArtifactOperationGate(),
      platform: platform,
      idSource: () => '11111111111111111111111111111111',
      nowUtc: () => DateTime.utc(2026),
      availableBytes: (_) async => 64 * 1024 * 1024,
    );
    expect(
      await coordinator.initialize(),
      AppShareInitializationOutcome.ready,
    );
    final outcome = await coordinator.share(
      AppShareRequest(
        sourceKind: ShareSourceKind.pidCsv,
        subject: 'PID',
        streamFactory: () => Stream.value('staged'.codeUnits),
      ),
    );
    expect(outcome.result, AppShareResult.dismissed);
    expect(outcome.error, isNull);
  });
}

class _Platform implements AppSharePlatform {
  int calls = 0;
  AppShareResult result = AppShareResult.selected;
  String? lastPath;
  @override
  Future<AppShareResult> share(AppSharePlatformRequest request) async {
    calls++;
    lastPath = request.path;
    expect(File(request.path).existsSync(), isTrue);
    return result;
  }
}

class _Policy implements AppSharePolicy {
  int checks = 0;
  @override
  SharePreparationPermit? freeze() => const SharePreparationPermit(
    recorderEpoch: 1,
    foregroundEpoch: 1,
    connectionEpoch: 1,
    safetyEpoch: 1,
    connectionClass: ShareConnectionClass.disconnected,
  );
  @override
  SharePermitValidation validate(SharePreparationPermit permit) {
    checks++;
    return const SharePermitValidation.valid();
  }
}
