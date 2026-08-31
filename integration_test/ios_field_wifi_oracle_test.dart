/// Field-flavor Wi‑Fi oracle on a real iOS Simulator against host Ircama.
///
/// The Simulator must reach the Mac over the host LAN address (not
/// `127.0.0.1` from the app's perspective — that is the desktop oracle path).
/// Prefer `tool/ios_wifi_oracle/run.sh`, which binds Ircama on `0.0.0.0`,
/// resolves `en0`, and passes the host here:
///
///     flutter test integration_test/ios_field_wifi_oracle_test.dart \
///       -d <ios-simulator-id> --flavor field \
///       --dart-define=WIFI_ORACLE_HOST=<en0-ip> \
///       --dart-define=WIFI_ORACLE_PORT=35000 \
///       --dart-define=WIFI_ORACLE_REQUIRED=true
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/main.dart' as app;
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/obd_session.dart';

import 'rig_support.dart';

const String oracleHost = String.fromEnvironment('WIFI_ORACLE_HOST');
const String oraclePortText = String.fromEnvironment(
  'WIFI_ORACLE_PORT',
  defaultValue: '35000',
);
const bool oracleRequired = bool.fromEnvironment('WIFI_ORACLE_REQUIRED');

Finder fieldWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
  description: 'TextField labelled "$label"',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'iOS field Wi-Fi reaches live telemetry via host LAN ELM327',
    (tester) async {
      expect(
        Platform.isIOS,
        isTrue,
        reason: 'this oracle is an iOS Simulator / device proof',
      );
      expect(kDebugMode, isTrue);

      final host = oracleHost.trim();
      final port = int.tryParse(oraclePortText);
      if (host.isEmpty || port == null || port < 1 || port > 65535) {
        if (oracleRequired) {
          fail(
            'WIFI_ORACLE_HOST/PORT must name a LAN endpoint reachable from '
            'the Simulator (got host="$oracleHost" port="$oraclePortText")',
          );
        }
        return;
      }
      expect(
        host == '127.0.0.1' || host == '::1' || host == 'localhost',
        isFalse,
        reason:
            'use the Mac LAN address (ipconfig getifaddr en0), not loopback; '
            'loopback from the Simulator is a different networking claim',
      );

      await _startCleanFieldApp(tester);
      debugPrint('IOS_FIELD_WIFI phase=app-ready host=$host:$port');

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
      await tester.enterText(hostField, host);
      await tester.enterText(portField, '$port');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      await revealText(tester, '連線');
      final connectButton = find.widgetWithText(FilledButton, '連線');
      expect(connectButton, findsOneWidget);
      await tester.tap(connectButton);
      await tester.pump();

      await requireDashboard(
        tester,
        timeout: const Duration(seconds: 45),
      );
      await requireLivePolling(
        tester,
        timeout: const Duration(seconds: 45),
      );

      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
        listen: false,
      );
      final session = container.read(obdSessionProvider);
      expect(
        session.kind,
        TransportKind.wifi,
        reason: 'must be WifiTransport, not Demo fallback',
      );
      expect(session.phase, ConnectionPhase.connected);
      debugPrint(
        'IOS_FIELD_WIFI phase=pass host=$host:$port '
        'kind=${session.kind?.name}',
      );
    },
  );
}

Future<void> _startCleanFieldApp(WidgetTester tester) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.clear();
  final docs = await getApplicationDocumentsDirectory();
  final telemetry = Directory('${docs.path}/telltale-telemetry');
  if (await telemetry.exists()) {
    await telemetry.delete(recursive: true);
  }

  unawaited(app.main());
  final ready = await pumpUntil(
    tester,
    () => find.text('選擇連線方式').evaluate().isNotEmpty,
    timeout: const Duration(seconds: 30),
  );
  expect(ready, isTrue, reason: 'iOS field app never reached connect screen');
}
