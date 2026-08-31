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
}

class _Platform implements AppSharePlatform {
  int calls = 0;
  @override
  Future<AppShareResult> share(AppSharePlatformRequest request) async {
    calls++;
    expect(File(request.path).readAsStringSync(), 'hello');
    return AppShareResult.selected;
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
