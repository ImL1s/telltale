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

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:torque_obd/core/share/rig_app_share_platform.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/telemetry_recorder.dart';
import 'package:torque_obd/state/telemetry_runtime.dart';
import 'package:torque_obd/telemetry/session/telemetry_recorder.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_reader.dart';
import 'package:torque_obd/ui/screens/dashboard/dashboard_screen.dart';

import 'rig_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('launch, poll, persist and recover through the Demo ECU', (
    tester,
  ) async {
    await startCleanRigApp(tester);
    debugPrint('DEMO_RIG phase=app-ready');

    final demoHeader = await revealText(tester, 'Demo 模擬器');
    await tester.tap(demoHeader);
    await tester.pump(const Duration(milliseconds: 500));

    final launchButton = await revealText(tester, '啟動模擬器');
    await tester.tap(launchButton);
    await tester.pump();

    await requireDashboard(tester);
    await requireLivePolling(tester);
    debugPrint('DEMO_RIG phase=live-polling');

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
    await tester.pump(const Duration(seconds: 2));

    debugPrint('DEMO_RIG phase=lifecycle-recovered');
    await _recordAndInspectTelemetryJourney(tester);
  });
}

Future<void> _recordAndInspectTelemetryJourney(WidgetTester tester) async {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
    listen: false,
  );
  // The lifecycle proof above intentionally lets the Demo drive cycle move.
  // Start must still obey the exact fresh <=5 km/h production rule, so create
  // a new Demo session and use its initial idle window instead of weakening
  // the safety authority for simulated data.
  final session = container.read(obdSessionProvider.notifier);
  await session.disconnect();
  final reconnect = session.connectDemo();
  expect(
    await pumpUntil(
      tester,
      () =>
          container.read(obdSessionProvider).phase == ConnectionPhase.connected,
      timeout: const Duration(seconds: 30),
      step: const Duration(milliseconds: 25),
    ),
    isTrue,
    reason: 'fresh Demo session did not reconnect for the Start proof',
  );
  expect(await reconnect, isTrue);
  debugPrint('DEMO_RIG phase=fresh-idle-session');

  final start = find.byKey(const ValueKey('telemetry-start'));
  await Scrollable.ensureVisible(tester.element(start), alignment: 0.5);
  await tester.pump(const Duration(milliseconds: 50));
  expect(
    await pumpUntil(
      tester,
      () =>
          start.evaluate().isNotEmpty &&
          tester.widget<FilledButton>(start).onPressed != null,
      timeout: const Duration(seconds: 2),
      step: const Duration(milliseconds: 25),
    ),
    isTrue,
    reason: 'fresh Demo idle sample did not enable Start',
  );
  expect(start.hitTestable(), findsOneWidget);
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
    reason: 'Demo telemetry recording never accepted its first value',
  );
  debugPrint('DEMO_RIG phase=recording');

  // Choose the Trends workspace and prove a selected lane observes the same
  // live Demo stream while the root recorder remains active.
  final switcher = find.byKey(const ValueKey('dashboard-workspace-switch'));
  // At large accessibility scales the recorder card legitimately occupies
  // the whole viewport, so ensuring Start above can evict the earlier toolbar
  // sliver. Scroll back toward the top until the production switch is built
  // instead of assuming it remains in the widget tree off-screen.
  final dashboard = find.byType(CustomScrollView);
  expect(dashboard, findsOneWidget);
  final dashboardScrollable = find.descendant(
    of: dashboard,
    matching: find.byType(Scrollable),
  );
  expect(dashboardScrollable, findsOneWidget);
  final scrollPosition = tester
      .state<ScrollableState>(dashboardScrollable)
      .position;
  scrollPosition.jumpTo(scrollPosition.minScrollExtent);
  await tester.pump();
  expect(switcher, findsOneWidget);
  await Scrollable.ensureVisible(tester.element(switcher), alignment: 0.5);
  await tester.pump(const Duration(milliseconds: 100));
  final visibleSwitcher = switcher.hitTestable();
  expect(visibleSwitcher, findsOneWidget);
  final switcherRect = tester.getRect(visibleSwitcher);
  await tester.tapAt(
    Offset(switcherRect.right - switcherRect.width / 4, switcherRect.center.dy),
  );
  await tester.pump(const Duration(milliseconds: 100));
  expect(
    tester.widget<SegmentedButton<DashboardWorkspaceMode>>(switcher).selected,
    {DashboardWorkspaceMode.trends},
  );
  // Trends is another lazy sliver. Move the same dashboard position toward
  // its content before resolving text; the connection-wizard helper cannot
  // safely choose among every Scrollable mounted by the dashboard shell.
  scrollPosition.jumpTo(scrollPosition.maxScrollExtent);
  await tester.pump(const Duration(milliseconds: 100));
  final simulatedSource = find.text('內建模擬資料');
  expect(simulatedSource, findsOneWidget);
  await Scrollable.ensureVisible(
    tester.element(simulatedSource),
    alignment: 0.5,
  );
  await tester.pump(const Duration(milliseconds: 100));
  expect(find.byKey(const ValueKey('telemetry-lane-selector')), findsOneWidget);

  // Every shell destination must retain the root-owned recording strip. This
  // is widget navigation on a physical phone; it is not radio/car evidence.
  for (final destination in const ['PID', '故障碼', '性能', '設定', '儀表板']) {
    final navigation = find.byWidgetPredicate(
      (widget) => widget is NavigationBar || widget is NavigationRail,
      description: 'responsive app navigation',
    );
    expect(navigation, findsOneWidget);
    final label = find.descendant(
      of: navigation,
      matching: find.text(destination),
    );
    expect(label, findsOneWidget);
    // A labelled NavigationRail scrolls at short landscape heights, while a
    // compact phone uses a fixed NavigationBar. The same journey must operate
    // both responsive shells instead of assuming portrait navigation.
    await Scrollable.ensureVisible(tester.element(label), alignment: 0.5);
    await tester.pump(const Duration(milliseconds: 50));
    final target = label.hitTestable();
    expect(target, findsOneWidget);
    await tester.tap(target);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('telemetry-shell-stop')),
      findsOneWidget,
      reason: 'recording controls disappeared on $destination',
    );
  }
  await tester.tap(find.byKey(const ValueKey('telemetry-shell-stop')));
  await tester.pump();
  expect(
    await pumpUntil(
      tester,
      () => controller.state.phase == TelemetryRecorderPhase.completed,
      timeout: const Duration(seconds: 30),
    ),
    isTrue,
    reason: 'Demo telemetry recording did not finalize',
  );
  debugPrint('DEMO_RIG phase=recorded');

  final documents = await getApplicationDocumentsDirectory();
  final id = controller.progress.sessionId;
  expect(id, isNotNull);
  final file = File('${documents.path}/telltale-telemetry/$id.ndjson');
  expect(await file.exists(), isTrue);
  final result = await const TelemetrySessionReader().read(
    FileTelemetryChunkSource(file),
  );
  expect(result.isValid, isTrue);
  expect(result.footerSeen, isTrue);
  expect(result.valueCount, greaterThan(0));
  expect(result.sessionHeader?.source, TelemetrySource.demo);
  expect(result.sessionFooter?.terminalReason, TelemetryTerminalReason.user);
  final header = result.sessionHeader!;

  // The Demo speed intentionally cycles. Freeze the safety boundary before
  // entering History so route access cannot oscillate while the replay worker
  // is loading or while an export is being copied.
  await session.disconnect();
  await tester.pump();
  expect(
    container.read(obdSessionProvider).phase,
    ConnectionPhase.disconnected,
  );
  debugPrint('DEMO_RIG phase=disconnected-for-history');

  // Continue through the shipped root History route rather than constructing
  // a parallel reader/export/delete journey in the test. The rig-only final
  // Share sink captures the immutable coordinator hand-off without opening an
  // Android chooser or claiming external delivery.
  final history = find.byKey(const ValueKey('telemetry-open-history'));
  final completedDashboard = find.byType(CustomScrollView);
  expect(completedDashboard, findsOneWidget);
  final completedDashboardScrollable = find.descendant(
    of: completedDashboard,
    matching: find.byType(Scrollable),
  );
  expect(completedDashboardScrollable, findsOneWidget);
  final completedPosition = tester
      .state<ScrollableState>(completedDashboardScrollable)
      .position;
  completedPosition.jumpTo(completedPosition.minScrollExtent);
  await tester.pump();
  expect(history, findsOneWidget);
  await Scrollable.ensureVisible(tester.element(history), alignment: 0.5);
  await tester.pump(const Duration(milliseconds: 100));
  final visibleHistory = history.hitTestable();
  expect(visibleHistory, findsOneWidget);
  await tester.tap(visibleHistory);
  await tester.pump();
  expect(
    await pumpUntil(
      tester,
      () => find.byType(ListView).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 20),
    ),
    isTrue,
    reason: 'root History did not load its local library',
  );
  final historyList = find.byType(ListView);
  expect(historyList, findsOneWidget);
  final historyScrollable = find.descendant(
    of: historyList,
    matching: find.byType(Scrollable),
  );
  expect(historyScrollable, findsOneWidget);
  final sessionTile = find.byIcon(Icons.chevron_right);
  await tester.scrollUntilVisible(
    sessionTile,
    200,
    scrollable: historyScrollable,
  );
  expect(sessionTile, findsOneWidget);
  expect(find.text('本機紀錄'), findsOneWidget);
  expect(find.textContaining('${result.valueCount} 筆有效值'), findsOneWidget);
  expect(find.textContaining('${result.statusCount} 個狀態'), findsOneWidget);
  expect(find.textContaining('${result.gapCount} 個缺口'), findsOneWidget);
  expect(find.textContaining('內建模擬'), findsOneWidget);
  debugPrint('DEMO_RIG phase=history');

  await tester.tap(sessionTile.last);
  await tester.pump();
  expect(
    await pumpUntil(
      tester,
      () => find.text('紀錄回放').evaluate().isNotEmpty,
      timeout: const Duration(seconds: 20),
    ),
    isTrue,
    reason: 'root replay route did not load the completed Demo session',
  );
  final replayList = find.byType(ListView);
  expect(
    await pumpUntil(
      tester,
      () => replayList.evaluate().isNotEmpty,
      timeout: const Duration(seconds: 20),
    ),
    isTrue,
    reason: 'root replay route did not finish loading the Demo session',
  );
  expect(replayList, findsOneWidget);
  final replayScrollable = find.descendant(
    of: replayList,
    matching: find.byType(Scrollable),
  );
  expect(replayScrollable, findsOneWidget);
  await tester.scrollUntilVisible(
    find.text('離線抽樣回放'),
    200,
    scrollable: replayScrollable,
  );
  expect(find.text('離線抽樣回放'), findsOneWidget);
  expect(find.text('內建模擬'), findsOneWidget);
  expect(
    find.text('${header.transport.name} · ${header.protocol}'),
    findsOneWidget,
  );
  expect(find.text('${result.valueCount} 筆有效值'), findsOneWidget);
  expect(find.text('${result.statusCount} 個狀態'), findsOneWidget);
  expect(find.text('${result.gapCount} 個缺口'), findsOneWidget);
  debugPrint('DEMO_RIG phase=replay');

  await tester.tap(find.text('16x'));
  await tester.pump();
  await tester.tap(find.text('播放'));
  await tester.pump();
  expect(find.text('暫停'), findsOneWidget);
  await tester.tap(find.text('暫停'));
  await tester.pump();
  expect(find.text('播放'), findsOneWidget);
  await tester.drag(find.byType(Slider), const Offset(120, 0));
  await tester.pump();
  expect(find.text('播放'), findsOneWidget);

  // The export still goes through the shipped detail UI, action layer,
  // coordinator, and rig-only final hand-off sink.

  final captureRoot = await rigShareCaptureDirectory();
  if (await captureRoot.exists()) await captureRoot.delete(recursive: true);
  final export = await revealText(tester, '匯出');
  await tester.tap(export);
  await tester.pump(const Duration(milliseconds: 500));
  await _tapVisible(tester, find.text('匯出 CSV'));
  await tester.pump();
  final csvFile = await _waitForCapturedExport(tester, captureRoot, 'csv');

  final exportAgain = await revealText(tester, '匯出');
  await tester.tap(exportAgain);
  await tester.pump(const Duration(milliseconds: 500));
  await _tapVisible(tester, find.text('匯出 JSON'));
  await tester.pump();
  final jsonFile = await _waitForCapturedExport(tester, captureRoot, 'json');
  debugPrint('DEMO_RIG phase=exports-captured');

  final csvText = await csvFile.readAsString();
  final jsonText = await jsonFile.readAsString();
  expect(csvText, contains('# source=demo'));
  expect(csvText, contains('# value_count=${result.valueCount}'));
  expect(jsonText, contains('"source":"demo"'));
  final decoded = jsonDecode(jsonText) as Map<String, dynamic>;
  expect(
    decoded['privacyExclusions'],
    containsAll(const [
      'VIN',
      'GPS',
      'account',
      'vehicleProfile',
      'adapterAddress',
      'rawDiagnosticTraffic',
    ]),
  );
  final payload = <String, Object?>{
    'header': decoded['header'],
    'events': decoded['events'],
    'footer': decoded['footer'],
  };
  final payloadText = jsonEncode(payload);
  final csvPayload = csvText
      .split('\r\n')
      .where((line) => line.isNotEmpty && !line.startsWith('#'))
      .join('\r\n');
  for (final excluded in const [
    'VIN',
    'GPS',
    'adapterAddress',
    'vehicleProfile',
    'account',
    'rawDiagnosticTraffic',
  ]) {
    expect(payloadText, isNot(contains('"$excluded"')));
    expect(csvPayload, isNot(contains(excluded)));
  }

  final delete = await revealText(tester, '刪除');
  await tester.tap(delete);
  await tester.pump(const Duration(milliseconds: 500));
  await _tapVisible(tester, find.widgetWithText(FilledButton, '刪除'));
  await tester.pump();
  expect(
    await pumpUntil(
      tester,
      () => find.textContaining('還沒有本機紀錄').evaluate().isNotEmpty,
      timeout: const Duration(seconds: 20),
    ),
    isTrue,
    reason: 'root delete did not refresh History after removing the session',
  );
  final quota = await container.read(telemetrySessionStoreProvider).scanQuota();
  expect(quota.groupCount, 0);
  expect(quota.recognizedBytes, 0);
  expect(await file.exists(), isFalse);
  debugPrint('DEMO_RIG phase=complete');
}

Future<void> _tapVisible(WidgetTester tester, Finder target) async {
  expect(target, findsOneWidget);
  await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
  await tester.pump(const Duration(milliseconds: 100));
  final hitTestable = target.hitTestable();
  expect(hitTestable, findsOneWidget);
  await tester.tap(hitTestable);
}

Future<File> _waitForCapturedExport(
  WidgetTester tester,
  Directory root,
  String extension,
) async {
  final captured = await pumpUntilValue<File>(tester, () async {
    if (!await root.exists()) return null;
    final matches = await root
        .list(followLinks: false)
        .where(
          (entity) => entity is File && entity.path.endsWith('.$extension'),
        )
        .cast<File>()
        .toList();
    return matches.length == 1 ? matches.single : null;
  }, timeout: const Duration(seconds: 20));
  expect(captured, isNotNull, reason: 'rig Share did not capture .$extension');
  return captured!;
}
