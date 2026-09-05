import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/driving_interaction_safety.dart';
import 'package:torque_obd/state/telemetry_sessions.dart';
import 'package:torque_obd/telemetry/session/telemetry_recorder.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';
import 'package:torque_obd/ui/screens/telemetry/telemetry_export_sheet.dart';
import 'package:torque_obd/ui/screens/telemetry/telemetry_session_detail_screen.dart';
import 'package:torque_obd/ui/screens/telemetry/telemetry_sessions_screen.dart';

TelemetrySessionLibrary _library() => TelemetrySessionLibrary(
  sessions: [
    TelemetrySessionProjection(
      id: '00000000000000000000000000000001',
      startedAtUtc: DateTime.utc(2026, 8, 30, 1),
      endedAtUtc: DateTime.utc(2026, 8, 30, 1, 2),
      source: TelemetrySource.demo,
      transport: TransportKind.demo.name,
      protocol: 'ISO 15765-4 CAN（11 位元識別碼，500 kbit/s）',
      signalCount: 2,
      valueCount: 10,
      statusCount: 1,
      gapCount: 1,
      terminalReason: TelemetryTerminalReason.user,
      bytes: 1024,
      elapsedDurationUs: 2 * 60 * 1000000,
    ),
  ],
  damaged: [
    DamagedTelemetryProjection(
      id: '00000000000000000000000000000002',
      filesystemModifiedAtUtc: DateTime.utc(2026, 8, 30, 2),
      kind: DamagedTelemetryKind.collision,
    ),
  ],
  groupCount: 2,
  recognizedBytes: 1024,
  omittedCount: 0,
  encodedProjectionBytes: 512,
  workerDebugName: 'test-worker',
);

TelemetryReplayResult _replay() => TelemetryReplayResult.success(
  TelemetrySessionReplay(
    sessionId: '00000000000000000000000000000001',
    startedAtUtc: DateTime.utc(2026, 8, 30, 1),
    endedAtUtc: DateTime.utc(2026, 8, 30, 1, 2),
    source: TelemetrySource.demo,
    transport: TransportKind.demo.name,
    protocol: 'Demo',
    signalCount: 4,
    valueCount: 7,
    statusCount: 1,
    gapCount: 1,
    terminalReason: TelemetryTerminalReason.user,
    elapsedDurationUs: 1000,
    workerDebugName: 'test-worker',
    lanes: const [
      TelemetryReplayLane(
        pidId: '7E0:010C',
        name: 'Engine RPM',
        unit: 'rpm',
        primitives: [
          TelemetryReplayPrimitive(
            kind: TelemetryReplayPrimitiveKind.value,
            elapsedUs: 0,
            value: 1000,
          ),
          TelemetryReplayPrimitive(
            kind: TelemetryReplayPrimitiveKind.gap,
            elapsedUs: 1000,
          ),
        ],
      ),
      TelemetryReplayLane(
        pidId: '7E0:010D',
        name: 'Vehicle Speed',
        unit: 'km/h',
        primitives: [
          TelemetryReplayPrimitive(
            kind: TelemetryReplayPrimitiveKind.value,
            elapsedUs: 0,
            value: 0,
          ),
          TelemetryReplayPrimitive(
            kind: TelemetryReplayPrimitiveKind.value,
            elapsedUs: 1000,
            value: 20,
          ),
        ],
      ),
      TelemetryReplayLane(
        pidId: '7E0:0105',
        name: 'Coolant Temperature',
        unit: '°C',
        primitives: [
          TelemetryReplayPrimitive(
            kind: TelemetryReplayPrimitiveKind.value,
            elapsedUs: 0,
            value: 88,
          ),
          TelemetryReplayPrimitive(
            kind: TelemetryReplayPrimitiveKind.value,
            elapsedUs: 1000,
            value: 90,
          ),
        ],
      ),
      TelemetryReplayLane(
        pidId: '7E0:010F',
        name: 'Intake Air Temperature',
        unit: '°C',
        primitives: [
          TelemetryReplayPrimitive(
            kind: TelemetryReplayPrimitiveKind.value,
            elapsedUs: 0,
            value: 26,
          ),
          TelemetryReplayPrimitive(
            kind: TelemetryReplayPrimitiveKind.value,
            elapsedUs: 1000,
            value: 28,
          ),
        ],
      ),
    ],
  ),
);

Widget _scaled(Widget child) => MaterialApp(
  home: MediaQuery(
    data: const MediaQueryData(textScaler: TextScaler.linear(2)),
    child: child,
  ),
);

void _useLandscape200Percent(WidgetTester tester) {
  tester.view.physicalSize = const Size(640, 360);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  test('route guard evaluates recorder before moving policy', () {
    const moving = DrivingInteractionSafetySnapshot(
      classification: DrivingSafetyClassification.moving,
      foreground: true,
      recorderBlocksArtifacts: true,
      connectionEpoch: 1,
      foregroundEpoch: 1,
      recorderEpoch: 1,
      safetyEpoch: 1,
    );
    expect(
      telemetryHistoryAccess(
        recorderPhase: TelemetryRecorderPhase.recording,
        safety: moving,
      ),
      TelemetryHistoryAccess.recorderActive,
    );
    expect(
      telemetryHistoryAccess(
        recorderPhase: TelemetryRecorderPhase.idle,
        safety: moving,
      ),
      TelemetryHistoryAccess.moving,
    );
  });

  testWidgets(
    'history shows valid/corrupt partitions and exact quota at 200%',
    (tester) async {
      _useLandscape200Percent(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            telemetryHistoryAccessProvider.overrideWithValue(
              TelemetryHistoryAccess.permitted,
            ),
            telemetrySessionLibraryProvider.overrideWith(
              (ref) async => _library(),
            ),
          ],
          child: _scaled(const TelemetrySessionsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('可回放的紀錄'), findsOneWidget);
      expect(
        find.text(
          '內建模擬 · demo · ISO 15765-4 CAN（11 位元識別碼，500 kbit/s）\n'
          '02:00 · 2 項訊號\n'
          '10 筆有效值 · 1 個狀態 · 1 個缺口\n'
          '已手動停止',
        ),
        findsOneWidget,
      );
      expect(find.text('2/20 組'), findsOneWidget);
      expect(find.text('0.0/100 MiB'), findsOneWidget);
      final historyRow = tester.getRect(find.byType(ListTile).first);
      expect(historyRow.left, greaterThanOrEqualTo(0));
      expect(historyRow.right, lessThanOrEqualTo(640));
      expect(historyRow.height, greaterThan(100));
      expect(
        tester.getSemantics(find.byType(ListTile).first).label,
        contains('ISO 15765-4 CAN'),
      );
      await tester.scrollUntilVisible(
        find.text('損壞的紀錄檔'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('損壞的紀錄檔'), findsOneWidget);
      expect(find.textContaining('檔案時間'), findsOneWidget);
      expect(find.textContaining('同一識別碼同時存在完成與未完成檔'), findsOneWidget);
      expect(find.byTooltip('刪除損壞紀錄'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('刪除損壞紀錄'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('刪除損壞紀錄'));
      await tester.pumpAndSettle();
      expect(find.text('刪除損壞紀錄？'), findsOneWidget);
      expect(find.textContaining('刪除後無法復原'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('replay keeps source/disclaimer/actions usable at 200%', (
    tester,
  ) async {
    _useLandscape200Percent(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          telemetryHistoryAccessProvider.overrideWithValue(
            TelemetryHistoryAccess.permitted,
          ),
          telemetrySessionReplayProvider.overrideWith(
            (ref, sessionId) async => _replay(),
          ),
        ],
        child: _scaled(
          const TelemetrySessionDetailScreen(
            sessionId: '00000000000000000000000000000001',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('內建模擬'), findsOneWidget);
    expect(find.text('demo · Demo'), findsOneWidget);
    expect(find.text('4 項訊號'), findsOneWidget);
    expect(find.text('7 筆有效值'), findsOneWidget);
    expect(find.text('1 個狀態'), findsOneWidget);
    expect(find.text('1 個缺口'), findsOneWidget);
    expect(find.text('已手動停止'), findsOneWidget);
    expect(find.text(telemetryReplayDisclaimer), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('播放'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('播放'), findsOneWidget);
    expect(find.text('16x'), findsOneWidget);
    await tester.tap(find.text('播放'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.ensureVisible(find.byType(Slider));
    await tester.pump();
    expect(tester.getSize(find.byType(Slider)).width, lessThanOrEqualTo(608));
    final after = tester.widget<Slider>(find.byType(Slider)).value;
    expect(after, greaterThan(0));

    await tester.scrollUntilVisible(
      find.textContaining('Engine RPM ·'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('Engine RPM · -- rpm'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);

    final fourthLane = find.byKey(
      const ValueKey('telemetry-replay-lane-7E0:010F'),
    );
    await tester.scrollUntilVisible(
      fourthLane,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    final fourthRect = tester.getRect(fourthLane);
    expect(fourthRect.left, greaterThanOrEqualTo(0));
    expect(fourthRect.right, lessThanOrEqualTo(640));
    expect(fourthRect.top, lessThan(360));
    expect(fourthRect.bottom, greaterThan(0));
    expect(
      tester.getSemantics(fourthLane).label,
      contains('Intake Air Temperature'),
    );

    await tester.scrollUntilVisible(
      find.text('匯出'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('匯出'), findsOneWidget);
    expect(find.text('刪除'), findsOneWidget);
    for (final button in [
      find.widgetWithText(FilledButton, '匯出'),
      find.widgetWithText(OutlinedButton, '刪除'),
    ]) {
      final rect = tester.getRect(button);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(640));
      expect(rect.height, greaterThanOrEqualTo(48));
    }
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '匯出'))
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '刪除'))
          .onPressed,
      isNotNull,
    );
    expect(
      tester.getSemantics(find.widgetWithText(FilledButton, '匯出')).label,
      contains('匯出'),
    );
    await tester.tap(find.widgetWithText(FilledButton, '匯出'));
    await tester.pumpAndSettle();
    expect(find.text('匯出本機紀錄'), findsOneWidget);
    expect(find.text(telemetryExportDisclosure), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.widgetWithText(OutlinedButton, '刪除'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.widgetWithText(OutlinedButton, '刪除'));
    await tester.pumpAndSettle();
    expect(find.text('刪除本機紀錄？'), findsOneWidget);
    expect(find.textContaining('此操作無法復原'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('denied detail route never starts replay filesystem work', (
    tester,
  ) async {
    var documentReads = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          telemetryHistoryAccessProvider.overrideWithValue(
            TelemetryHistoryAccess.recorderActive,
          ),
          telemetrySessionLibraryServiceProvider.overrideWithValue(
            TelemetrySessionLibraryService(
              documentsDirectory: () async {
                documentReads++;
                return Directory.systemTemp;
              },
            ),
          ),
        ],
        child: _scaled(
          const TelemetrySessionDetailScreen(
            sessionId: '00000000000000000000000000000001',
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('請先停止並儲存'), findsOneWidget);
    expect(documentReads, 0);
  });

  testWidgets('export disclosure is exact before format selection', (
    tester,
  ) async {
    await tester.pumpWidget(
      _scaled(const Scaffold(body: TelemetryExportSheet())),
    );

    expect(find.text(telemetryExportDisclosure), findsOneWidget);
    expect(find.text('匯出 CSV'), findsOneWidget);
    expect(find.text('匯出 JSON'), findsOneWidget);
  });

  testWidgets('export formats stay reachable at 200 percent short landscape', (
    tester,
  ) async {
    _useLandscape200Percent(tester);
    await tester.pumpWidget(
      _scaled(const Scaffold(body: TelemetryExportSheet())),
    );

    expect(tester.takeException(), isNull);
    final sheet = find.byType(SingleChildScrollView);
    expect(sheet, findsOneWidget);
    final scrollable = find.descendant(
      of: sheet,
      matching: find.byType(Scrollable),
    );
    expect(scrollable, findsOneWidget);
    for (final label in const ['匯出 CSV', '匯出 JSON']) {
      final action = find.text(label);
      await tester.scrollUntilVisible(action, 100, scrollable: scrollable);
      await Scrollable.ensureVisible(tester.element(action), alignment: 0.5);
      await tester.pump();
      expect(action.hitTestable(), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });
}
