/// End-to-end proof that the built-in Demo ECU is reachable from the shipped
/// connection wizard, produces live telemetry, and persists clearly simulated
/// evidence. No adapter, host process, or network is involved.
///
/// Run with an Android device or emulator attached (set ANDROID_SERIAL when
/// more than one device is connected):
///
///     flutter test integration_test/demo_rig_test.dart -d <device-id> \
///       --flavor rig --dart-define=TELLTALE_TEST_RIG=true
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'rig_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('launch, poll, persist and recover through the Demo ECU', (
    tester,
  ) async {
    await startCleanRigApp(tester);

    final demoHeader = await revealText(tester, 'Demo 模擬器');
    await tester.tap(demoHeader);
    await tester.pumpAndSettle();

    final launchButton = await revealText(tester, '啟動模擬器');
    await tester.tap(launchButton);
    await tester.pump();

    await requireDashboard(tester);
    await requireLivePolling(tester);

    pauseApp(tester);
    final paused = await waitForStoredTranscript(
      tester,
      (value) => value.body.contains('App 進入背景'),
    );
    expect(paused, isNotNull, reason: 'pause did not persist Demo evidence');
    expect(paused!.fromRealHardware, isFalse);
    expect(paused.header, contains('# Telltale 無車測試馬具證據 v1'));
    expect(paused.header, contains('不得視為實體轉接器或實車驗證'));
    expect(paused.header, contains('# 連線方式：Demo 模擬器'));
    expect(paused.header, contains('# 裝置：Demo ECU (2.0L Turbo I4)'));
    expect(paused.header, contains('Torque Demo ECU'));
    expect(paused.body, contains(r'>> ATZ\r'));
    expect(paused.body, contains(r'>> 0100\r'));
    expect(paused.body, contains('  << '));

    resumeApp(tester);
    await requireLivePolling(
      tester,
      timeout: const Duration(seconds: 20),
      reason: 'Demo polling did not recover after resume',
    );

    pauseApp(tester);
    // The predicate demands the full shape the assertion below will read: a
    // snapshot can be persisted after the resume marker but before the probe
    // is recorded, and sampling that window is a race, not a finding. A
    // probe that genuinely never happens still fails here, as a null.
    final recovered = await waitForStoredTranscript(tester, (value) {
      final resumedAt = value.body.lastIndexOf('App 回到前景');
      return resumedAt >= 0 &&
          value.body.indexOf(r'>> ATRV\r', resumedAt) >= resumedAt;
    });
    expect(
      recovered,
      isNotNull,
      reason: 'resume must prove the Demo link before polling becomes live',
    );
    resumeApp(tester);
  });
}
