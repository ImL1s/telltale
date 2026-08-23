/// End-to-end Wi-Fi ELM327 proof over the device's real TCP stack.
///
/// Start the TCP rig on a host reachable from the device, then run:
///
///     flutter test integration_test/wifi_rig_test.dart -d <device-id> \
///       --flavor rig \
///       --dart-define=TELLTALE_TEST_RIG=true \
///       --dart-define=WIFI_RIG_HOST=<host-ip> \
///       --dart-define=WIFI_RIG_PORT=35000
///
/// Missing or invalid rig configuration is a failure, never a skip. This test
/// also runs under the isolated `.rig` application ID so it cannot clear or
/// inherit the field-test app's preferences and evidence.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'rig_support.dart';

const String rigHost = String.fromEnvironment('WIFI_RIG_HOST');
const String rigPortText = String.fromEnvironment(
  'WIFI_RIG_PORT',
  defaultValue: '35000',
);

Finder fieldWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
  description: 'TextField labelled "$label"',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('connect, poll, persist and recover through the Wi-Fi rig', (
    tester,
  ) async {
    expect(
      rigHost.trim(),
      isNotEmpty,
      reason: 'WIFI_RIG_HOST must name a host reachable from the device',
    );
    final rigPort = int.tryParse(rigPortText);
    expect(
      rigPort,
      isNotNull,
      reason: 'WIFI_RIG_PORT must be an integer, got "$rigPortText"',
    );
    expect(
      rigPort,
      inInclusiveRange(1, 65535),
      reason: 'WIFI_RIG_PORT must be in the range 1-65535',
    );

    await startCleanRigApp(tester);

    final wifiHeader = await revealText(tester, 'Wi-Fi');
    await tester.tap(wifiHeader);
    await tester.pumpAndSettle();

    await revealText(tester, 'IP 位址');
    final hostField = fieldWithLabel('IP 位址');
    final portField = fieldWithLabel('埠');
    expect(hostField, findsOneWidget);
    expect(portField, findsOneWidget);
    await tester.enterText(hostField, rigHost.trim());
    await tester.enterText(portField, '$rigPort');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    await revealText(tester, '連線');
    final connectButton = find.widgetWithText(FilledButton, '連線');
    expect(connectButton, findsOneWidget);
    await tester.tap(connectButton);
    await tester.pump();

    await requireDashboard(tester);
    await requireLivePolling(tester);

    pauseApp(tester);
    final paused = await waitForStoredTranscript(
      tester,
      (value) => value.body.contains('App 進入背景'),
    );
    expect(paused, isNotNull, reason: 'pause did not persist field evidence');
    expect(paused!.fromRealHardware, isFalse);
    expect(paused.header, contains('# Telltale 無車測試馬具證據 v1'));
    expect(paused.header, contains('不得視為實體轉接器或實車驗證'));
    expect(paused.header, contains('# 連線方式：Wi-Fi'));
    expect(paused.header, contains('# 裝置：${rigHost.trim()}:$rigPort'));
    expect(paused.header, contains('OBDII to RS232 Interpreter'));
    expect(paused.header, contains('# 連線資訊.host：${rigHost.trim()}'));
    expect(paused.header, contains('# 連線資訊.port：$rigPort'));
    expect(paused.body, contains(r'>> ATZ\r'));
    expect(paused.body, contains(r'>> 0100\r'));
    expect(paused.body, contains('  << '));

    resumeApp(tester);
    await requireLivePolling(
      tester,
      timeout: const Duration(seconds: 20),
      reason: 'Wi-Fi polling did not recover after resume',
    );

    pauseApp(tester);
    final recovered = await waitForStoredTranscript(
      tester,
      (value) => value.body.contains('App 回到前景'),
    );
    expect(recovered, isNotNull, reason: 'resume marker was not persisted');
    final resumedAt = recovered!.body.lastIndexOf('App 回到前景');
    final probeAt = recovered.body.indexOf(r'>> ATRV\r', resumedAt);
    expect(
      probeAt,
      greaterThan(resumedAt),
      reason: 'resume must prove the Wi-Fi link before polling becomes live',
    );
    resumeApp(tester);
  });
}
