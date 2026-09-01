/// Field-flavor journey against a bonded physical BLE/Classic adapter.
///
/// Unlike `ble_rig_test.dart` / `classic_rig_test.dart`, this does **not** use
/// the isolated `.rig` package or a simulated peripheral. It drives the shipped
/// `field` identity on a real Android phone and requires a powered adapter
/// whose display name matches `--dart-define=FIELD_BT_ADAPTER_NAME` (default
/// `OBDBLE`). Absence is a failure, never a skip.
///
/// Prefer the harness:
///
///     tool/field_bt_verify/run.sh
///
/// Direct invocation (phone unlocked, BT on, adapter powered):
///
///     flutter test integration_test/field_bt_journey_test.dart \
///       -d <serial> --flavor field \
///       --dart-define=FIELD_BT_REQUIRED=true \
///       --dart-define=FIELD_BT_ADAPTER_NAME=OBDBLE \
///       --dart-define=FIELD_BT_TRANSPORT=ble
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
import 'package:torque_obd/state/telemetry_recorder.dart';
import 'package:torque_obd/telemetry/session/telemetry_recorder.dart';

import 'rig_support.dart';

const bool _required = bool.fromEnvironment(
  'FIELD_BT_REQUIRED',
  defaultValue: false,
);
const String _adapterName = String.fromEnvironment(
  'FIELD_BT_ADAPTER_NAME',
  defaultValue: 'OBDBLE',
);
const String _transport = String.fromEnvironment(
  'FIELD_BT_TRANSPORT',
  defaultValue: 'ble',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'field BT scan/connect reaches live PIDs and records a short session',
    (tester) async {
      if (!_required) {
        // Refuse a quiet green: this file is only meaningful when the harness
        // (or an operator) opts in with FIELD_BT_REQUIRED=true.
        fail(
          'FIELD_BT_REQUIRED is not set. Run via tool/field_bt_verify/run.sh '
          'or pass --dart-define=FIELD_BT_REQUIRED=true with a powered '
          'adapter in range.',
        );
      }
      expect(Platform.isAndroid, isTrue, reason: 'Android field BT journey');
      expect(kDebugMode, isTrue);

      await _startCleanFieldApp(tester);
      debugPrint('FIELD_BT phase=app-ready adapter=$_adapterName transport=$_transport');

      final kind = await _connectAdapter(tester);
      debugPrint('FIELD_BT phase=connected kind=${kind.name}');

      await requireDashboard(tester, timeout: const Duration(seconds: 120));
      await requireLivePolling(
        tester,
        timeout: const Duration(seconds: 45),
        reason:
            'dashboard never received live PIDs from $_adapterName '
            '($kind). ACL may still be down, or the adapter is not an ELM327.',
      );
      debugPrint('FIELD_BT phase=live-polling');

      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
        listen: false,
      );
      expect(container.read(obdSessionProvider).kind, kind);

      // Prefer Trends so the recorder strip is on-screen (same key as Demo/iOS).
      final switcher = find.byKey(const ValueKey('dashboard-workspace-switch'));
      if (switcher.evaluate().isNotEmpty) {
        await tester.ensureVisible(switcher);
        await tester.pump(const Duration(milliseconds: 100));
        final visible = switcher.hitTestable();
        if (visible.evaluate().isNotEmpty) {
          final rect = tester.getRect(visible);
          await tester.tapAt(
            Offset(rect.right - rect.width / 4, rect.center.dy),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      final start = find.byKey(const ValueKey('telemetry-start'));
      await Scrollable.ensureVisible(tester.element(start), alignment: 0.5);
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        await pumpUntil(
          tester,
          () =>
              start.evaluate().isNotEmpty &&
              tester.widget<FilledButton>(start).onPressed != null,
          timeout: const Duration(seconds: 20),
          step: const Duration(milliseconds: 50),
        ),
        isTrue,
        reason:
            'Start stayed disabled — park the vehicle (speed/safety gate) '
            'and keep the adapter powered',
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
          timeout: const Duration(seconds: 45),
        ),
        isTrue,
        reason: 'field BT recording never accepted a structured value',
      );
      debugPrint('FIELD_BT phase=recording');

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
          timeout: const Duration(seconds: 45),
        ),
        isTrue,
        reason: 'field BT recording did not finalize',
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
      debugPrint('FIELD_BT phase=pass id=$sessionId kind=${kind.name}');
    },
  );
}

Future<TransportKind> _connectAdapter(WidgetTester tester) async {
  final mode = _transport.toLowerCase().trim();
  switch (mode) {
    case 'ble':
      await _connectBle(tester);
      return TransportKind.bluetoothLe;
    case 'classic':
      await _connectClassic(tester);
      return TransportKind.bluetoothClassic;
    case 'auto':
      try {
        await _connectBle(tester);
        return TransportKind.bluetoothLe;
      } catch (bleError) {
        debugPrint('FIELD_BT BLE path failed ($bleError); trying Classic');
        await _connectClassic(tester);
        return TransportKind.bluetoothClassic;
      }
    default:
      fail(
        'unknown FIELD_BT_TRANSPORT="$mode" (expected ble|classic|auto)',
      );
  }
}

Future<void> _connectBle(WidgetTester tester) async {
  final bleHeader = await revealText(tester, 'Bluetooth LE');
  await tester.tap(bleHeader);
  await tester.pump(const Duration(milliseconds: 500));

  final scanButton = await revealText(tester, '搜尋 BLE 裝置');
  await tester.tap(scanButton);
  await tester.pump();

  final found = await pumpUntil(
    tester,
    () => find.text(_adapterName).evaluate().isNotEmpty,
    timeout: const Duration(seconds: 45),
  );
  if (!found) {
    fail(
      'no BLE peripheral named "$_adapterName" in 45s.\n'
      'Power the dongle (ignition ON), keep the phone unlocked, and re-run '
      'tool/field_bt_verify/run.sh. Bonded-but-ACL-down is not a pass.',
    );
  }
  await _tapNamedDevice(tester, _adapterName);
}

Future<void> _connectClassic(WidgetTester tester) async {
  final classicHeader = await revealText(tester, 'Bluetooth Classic');
  await tester.tap(classicHeader);
  await tester.pump(const Duration(milliseconds: 800));

  // Classic lists bonded devices; wait for the bonded name to appear.
  final found = await pumpUntil(
    tester,
    () => find.text(_adapterName).evaluate().isNotEmpty,
    timeout: const Duration(seconds: 30),
  );
  if (!found) {
    // OBDII is the alternate bond name Samsung sometimes shows.
    final alt = await pumpUntil(
      tester,
      () => find.text('OBDII').evaluate().isNotEmpty,
      timeout: const Duration(seconds: 5),
    );
    if (!alt) {
      fail(
        'no Classic bonded device named "$_adapterName" (or OBDII).\n'
        'Pair in system Settings first; App cannot pair for you.',
      );
    }
    await _tapNamedDevice(tester, 'OBDII');
    return;
  }
  await _tapNamedDevice(tester, _adapterName);
}

Future<void> _tapNamedDevice(WidgetTester tester, String name) async {
  final label = find.text(name);
  final tile = find
      .ancestor(of: label, matching: find.byType(InkWell))
      .hitTestable();
  final resultsScroll = find
      .ancestor(of: label, matching: find.byType(Scrollable))
      .first;
  try {
    await tester.scrollUntilVisible(tile, 300, scrollable: resultsScroll);
  } on StateError catch (error) {
    fail('discovered "$name" was not visible or tappable: $error');
  }
  expect(tile, findsOneWidget, reason: '"$name" tile not tappable');
  await tester.tap(tile);
  await tester.pump();
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
  expect(ready, isTrue, reason: 'Android field app never reached connect screen');
}
