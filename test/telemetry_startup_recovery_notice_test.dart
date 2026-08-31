import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/state/app_share_coordinator.dart';
import 'package:torque_obd/state/artifact_operation_gate.dart';
import 'package:torque_obd/state/telemetry_recorder.dart';
import 'package:torque_obd/state/telemetry_runtime.dart';
import 'package:torque_obd/state/telemetry_sessions.dart';
import 'package:torque_obd/telemetry/session/telemetry_recorder.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_store.dart';
import 'package:torque_obd/ui/widgets/telemetry/telemetry_startup_recovery_notice.dart';

void main() {
  testWidgets('startup notice labels damaged data and can be dismissed', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync(
      'telemetry-recovery-notice-',
    );
    addTearDown(() => root.deleteSync(recursive: true));
    final telemetry = Directory('${root.path}/telltale-telemetry')
      ..createSync();
    const id = '11111111111111111111111111111111';
    File('${telemetry.path}/$id.ndjson.part')
        .writeAsStringSync('not-json\n', flush: true);
    final container = ProviderContainer(
      overrides: [
        telemetrySessionStoreProvider.overrideWithValue(
          TelemetrySessionStore(documentsDirectory: () async => root),
        ),
        appSharePolicyProvider.overrideWithValue(const _AllowedPolicy()),
        artifactOperationGateProvider.overrideWithValue(
          ArtifactOperationGate(),
        ),
        telemetryRecorderProgressProvider.overrideWith(
          () => _IdleProgressNotifier(),
        ),
        telemetryHistoryAccessProvider.overrideWithValue(
          TelemetryHistoryAccess.permitted,
        ),
      ],
    );
    addTearDown(container.dispose);

    final recovery = await tester.runAsync(() async {
      return container
          .read(telemetryStartupRecoveryProvider.notifier)
          .initialize();
    });
    expect(recovery, isNotNull);
    expect(recovery!.phase, TelemetryStartupRecoveryPhase.ready);
    expect(
      recovery.items.single.outcome,
      TelemetryRecoveryOutcome.corruptDeleteOnly,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: TelemetryStartupRecoveryNotice()),
        ),
      ),
    );

    expect(find.text('啟動紀錄檢查已完成'), findsOneWidget);
    expect(find.textContaining('1 組損壞或衝突檔未自動修改'), findsOneWidget);
    expect(find.textContaining('不會用於回放或匯出'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('telemetry-recovery-open-history')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('telemetry-recovery-dismiss')));
    await tester.pump();

    expect(find.text('啟動紀錄檢查已完成'), findsNothing);
  });
}

final class _IdleProgressNotifier extends TelemetryRecorderProgressNotifier {
  @override
  TelemetryRecorderProgress build() => const TelemetryRecorderProgress(
    state: TelemetryRecorderState.idle(),
    elapsedUs: 0,
    bytesBeforeFooter: 0,
    effectiveSessionLimit: null,
    sessionId: null,
  );
}

final class _AllowedPolicy implements AppSharePolicy {
  const _AllowedPolicy();

  @override
  SharePreparationPermit? freeze() => const SharePreparationPermit(
    recorderEpoch: 1,
    foregroundEpoch: 1,
    connectionEpoch: 1,
    safetyEpoch: 1,
    connectionClass: ShareConnectionClass.disconnected,
  );

  @override
  SharePermitValidation validate(SharePreparationPermit permit) =>
      const SharePermitValidation.valid();
}
