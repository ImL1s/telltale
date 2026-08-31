import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/core/theme/app_theme.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/telemetry_sessions.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';
import 'package:torque_obd/ui/screens/telemetry/telemetry_sessions_screen.dart';

void main() {
  testWidgets(
    'history root presents valid and damaged metadata without shell',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            telemetryHistoryAccessProvider.overrideWithValue(
              TelemetryHistoryAccess.permitted,
            ),
            telemetrySessionLibraryProvider.overrideWith(
              (ref) async => _library,
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: const TelemetrySessionsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('可回放的紀錄'), findsOneWidget);
      expect(find.text('損壞的紀錄檔'), findsOneWidget);
      expect(find.text('2/20 組'), findsOneWidget);
      expect(find.text('1.0/100 MiB'), findsOneWidget);
      expect(
        find.textContaining('內建模擬 · demo · ISO 15765-4 CAN'),
        findsOneWidget,
      );
      expect(find.textContaining('3 筆有效值 · 1 個狀態 · 2 個缺口'), findsOneWidget);
      expect(find.textContaining('已手動停止'), findsOneWidget);
      expect(find.textContaining('同一識別碼同時存在完成與未完成檔'), findsOneWidget);
      expect(find.textContaining('檔案時間'), findsOneWidget);
      expect(find.byTooltip('刪除損壞紀錄'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

final _library = TelemetrySessionLibrary(
  sessions: [
    TelemetrySessionProjection(
      id: '00000000000000000000000000000001',
      startedAtUtc: DateTime.utc(2026, 8, 30, 1),
      endedAtUtc: DateTime.utc(2026, 8, 30, 1, 2),
      source: TelemetrySource.demo,
      transport: TransportKind.demo.name,
      protocol: 'ISO 15765-4 CAN',
      signalCount: 2,
      valueCount: 3,
      statusCount: 1,
      gapCount: 2,
      terminalReason: TelemetryTerminalReason.user,
      bytes: 1024 * 1024,
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
  recognizedBytes: 1024 * 1024,
  omittedCount: 0,
  encodedProjectionBytes: 512,
  workerDebugName: 'screen-test-worker',
);
