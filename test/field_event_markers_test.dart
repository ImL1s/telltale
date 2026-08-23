import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/ui/widgets/field_event_markers.dart';

void main() {
  testWidgets('a parked passenger can stamp a preset event', (tester) async {
    FieldEventMarker? recorded;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FieldEventMarkerPanel(
            enabled: true,
            onRecord: (marker) async {
              recorded = marker;
              return FieldEventRecordResult.persisted;
            },
          ),
        ),
      ),
    );

    expect(find.text('實車事件標記'), findsOneWidget);
    expect(find.textContaining('只在車輛完全停妥'), findsOneWidget);
    expect(find.text('電門 ON'), findsOneWidget);
    expect(find.text('引擎發動'), findsOneWidget);
    expect(find.text('輕踩油門'), findsOneWidget);
    expect(find.text('道路測試開始'), findsOneWidget);

    await tester.tap(find.text('引擎發動'));
    await tester.pumpAndSettle();

    expect(recorded, FieldEventMarker.engineStarted);
    expect(find.text('已記錄並保存：引擎發動'), findsOneWidget);
  });

  testWidgets('event buttons are disabled without a live session', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FieldEventMarkerPanel(
            enabled: false,
            onRecord: (_) async {
              calls++;
              return FieldEventRecordResult.persisted;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('電門 ON'));
    await tester.pump();
    expect(calls, 0);
  });

  testWidgets('a storage failure is not reported as persisted', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FieldEventMarkerPanel(
            enabled: true,
            onRecord: (_) async => FieldEventRecordResult.memoryOnly,
          ),
        ),
      ),
    );

    await tester.tap(find.text('輕踩油門'));
    await tester.pumpAndSettle();

    expect(find.textContaining('自動保存失敗'), findsOneWidget);
    expect(find.textContaining('請立刻匯出紀錄'), findsOneWidget);
  });
}
