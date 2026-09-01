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

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';

import 'rig_support.dart';

const String rigHost = String.fromEnvironment('WIFI_RIG_HOST');
const String rigPortText = String.fromEnvironment(
  'WIFI_RIG_PORT',
  defaultValue: '35000',
);
const String expectedTerminalText = String.fromEnvironment(
  'WIFI_RIG_EXPECTED_TERMINAL',
  defaultValue: 'user',
);
const String armedFault = String.fromEnvironment('WIFI_RIG_ARM_FAULT');
const String controlPortText = String.fromEnvironment('WIFI_RIG_CONTROL_PORT');
const String controlToken = String.fromEnvironment('WIFI_RIG_CONTROL_TOKEN');

Finder fieldWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
  description: 'TextField labelled "$label"',
);

Future<void> armNextFault({
  required String host,
  required int port,
  required String token,
  required String fault,
}) async {
  final socket = await Socket.connect(
    host,
    port,
    timeout: const Duration(seconds: 5),
  );
  try {
    socket.write('ARM $token\n');
    await socket.flush();
    final responses = StreamIterator(
      socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter()),
    );
    expect(
      await responses.moveNext().timeout(const Duration(seconds: 5)),
      isTrue,
      reason: 'chaos proxy closed before acknowledging the arm request',
    );
    expect(
      responses.current,
      'ARMED $fault',
      reason:
          'chaos proxy did not acknowledge a post-recording arm request; '
          'received "${responses.current}"',
    );
    expect(
      await responses.moveNext().timeout(const Duration(seconds: 20)),
      isTrue,
      reason: 'chaos proxy acknowledged but never injected the armed fault',
    );
    expect(
      responses.current,
      matches(RegExp('^INJECTED $fault [1-9][0-9]*\$')),
      reason:
          'chaos proxy must prove the selected post-recording fault was '
          'consumed by one concrete command',
    );
  } finally {
    socket.destroy();
  }
}

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
    final expectedTerminals = TelemetryTerminalReason.values.where(
      (value) => value.name == expectedTerminalText,
    );
    expect(
      expectedTerminals,
      hasLength(1),
      reason:
          'WIFI_RIG_EXPECTED_TERMINAL must be a TelemetryTerminalReason name, '
          'got "$expectedTerminalText"',
    );
    final expectedTerminal = expectedTerminals.single;
    final usesArmedFault = armedFault.isNotEmpty;
    expect(
      armedFault,
      anyOf(isEmpty, 'close', 'no_prompt', 'corrupt'),
      reason: 'WIFI_RIG_ARM_FAULT must be empty, close, no_prompt, or corrupt',
    );
    final controlPort = int.tryParse(controlPortText);
    if (usesArmedFault) {
      expect(
        expectedTerminal,
        TelemetryTerminalReason.disconnect,
        reason:
            'the armed device matrix closes the damaged link, so its first '
            'recorder terminal must be disconnect',
      );
      expect(
        controlPort,
        inInclusiveRange(1, 65535),
        reason: 'WIFI_RIG_CONTROL_PORT must be in 1-65535 for an armed fault',
      );
      expect(
        controlToken,
        isNotEmpty,
        reason: 'WIFI_RIG_CONTROL_TOKEN is required for an armed fault',
      );
    } else {
      expect(
        controlPortText,
        isEmpty,
        reason: 'WIFI_RIG_CONTROL_PORT requires WIFI_RIG_ARM_FAULT',
      );
      expect(
        controlToken,
        isEmpty,
        reason: 'WIFI_RIG_CONTROL_TOKEN requires WIFI_RIG_ARM_FAULT',
      );
    }

    await startCleanRigApp(tester);

    final wifiHeader = await revealText(tester, 'Wi-Fi');
    await tester.tap(wifiHeader);
    await tester.pump(const Duration(milliseconds: 500));

    final hostField = fieldWithLabel('IP 位址');
    final portField = fieldWithLabel('埠');
    await tester.scrollUntilVisible(
      hostField,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await Scrollable.ensureVisible(tester.element(hostField), alignment: 0.5);
    await tester.pump(const Duration(milliseconds: 300));
    expect(hostField, findsOneWidget);
    expect(portField, findsOneWidget);
    expect(hostField.hitTestable(), findsOneWidget);
    expect(portField.hitTestable(), findsOneWidget);
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
    final telemetry = await completeTelemetryRigJourney(
      tester,
      expectedTransport: TransportKind.wifi,
      expectedTerminalReason: expectedTerminal,
      afterFirstRecordedValue: usesArmedFault
          ? () => armNextFault(
              host: rigHost.trim(),
              port: controlPort!,
              token: controlToken,
              fault: armedFault,
            )
          : null,
    );
    expect(telemetry.terminalReason, expectedTerminal);
    if (expectedTerminal != TelemetryTerminalReason.user) return;

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

    final resumeBaseline = capturePollingResumeBaseline(tester);
    resumeApp(tester);
    await requirePollingRecoveredAfterResume(
      tester,
      resumeBaseline,
      timeout: const Duration(seconds: 20),
      reason: 'Wi-Fi polling did not recover after resume',
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
      reason: 'resume must prove the Wi-Fi link before polling becomes live',
    );
    resumeApp(tester);
  });
}
