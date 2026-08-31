/// Field-flavor Demo journey on a real iOS Simulator.
///
/// Unlike `demo_rig_test.dart`, this does **not** use the Android-only `.rig`
/// package or `TELLTALE_TEST_RIG`. It proves the shipped field identity can
/// reach Demo → live telemetry (and a short record/stop cycle) on iOS.
///
///     flutter test integration_test/ios_field_demo_journey_test.dart \
///       -d <ios-simulator-id> --flavor field
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
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/telemetry_recorder.dart';
import 'package:torque_obd/telemetry/session/telemetry_recorder.dart';

import 'rig_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'iOS field Demo reaches live telemetry and records a short session',
    (tester) async {
      expect(
        Platform.isIOS,
        isTrue,
        reason: 'this journey is an iOS Simulator / device proof',
      );
      expect(kDebugMode, isTrue);

      await _startCleanFieldApp(tester);
      debugPrint('IOS_FIELD_DEMO phase=app-ready');

      final demoHeader = await revealText(tester, 'Demo 模擬器');
      await tester.tap(demoHeader);
      await tester.pump(const Duration(milliseconds: 500));

      final launchButton = await revealText(tester, '啟動模擬器');
      await tester.tap(launchButton);
      await tester.pump();

      await requireDashboard(tester);
      await requireLivePolling(tester);
      debugPrint('IOS_FIELD_DEMO phase=live-polling');

      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
        listen: false,
      );
      final session = container.read(obdSessionProvider.notifier);
      expect(container.read(obdSessionProvider).kind?.name, 'demo');

      // Fresh idle window for the production Start safety gate.
      await session.disconnect();
      final reconnect = session.connectDemo();
      expect(
        await pumpUntil(
          tester,
          () =>
              container.read(obdSessionProvider).phase ==
              ConnectionPhase.connected,
          timeout: const Duration(seconds: 30),
          step: const Duration(milliseconds: 25),
        ),
        isTrue,
        reason: 'fresh Demo reconnect failed on iOS field',
      );
      expect(await reconnect, isTrue);
      debugPrint('IOS_FIELD_DEMO phase=fresh-idle-session');

      final start = find.byKey(const ValueKey('telemetry-start'));
      await Scrollable.ensureVisible(tester.element(start), alignment: 0.5);
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        await pumpUntil(
          tester,
          () =>
              start.evaluate().isNotEmpty &&
              tester.widget<FilledButton>(start).onPressed != null,
          timeout: const Duration(seconds: 5),
          step: const Duration(milliseconds: 25),
        ),
        isTrue,
        reason: 'Start stayed disabled after fresh Demo idle on iOS',
      );
      await tester.tap(start.hitTestable());
      await tester.pump();

      final controller = container.read(telemetryRecorderControllerProvider);
      expect(
        await pumpUntil(
          tester,
          () =>
              controller.state.phase == TelemetryRecorderPhase.recording &&
              controller.state.valueCount > 0,
          timeout: const Duration(seconds: 30),
        ),
        isTrue,
        reason: 'iOS field Demo recording never accepted a value',
      );
      debugPrint('IOS_FIELD_DEMO phase=recording');

      final stop = find.byKey(const ValueKey('telemetry-shell-stop'));
      expect(stop, findsOneWidget);
      await tester.tap(stop.hitTestable());
      await tester.pump();
      expect(
        await pumpUntil(
          tester,
          () =>
              controller.state.phase == TelemetryRecorderPhase.completed ||
              controller.state.phase == TelemetryRecorderPhase.idle,
          timeout: const Duration(seconds: 30),
        ),
        isTrue,
        reason: 'iOS field Demo recording did not finalize',
      );
      final sessionId = controller.progress.sessionId;
      expect(sessionId, isNotNull);
      final documents = await getApplicationDocumentsDirectory();
      expect(
        await File(
          '${documents.path}/telltale-telemetry/$sessionId.ndjson',
        ).exists(),
        isTrue,
      );
      debugPrint('IOS_FIELD_DEMO phase=pass id=$sessionId');
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
