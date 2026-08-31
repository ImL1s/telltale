import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/core/theme/app_theme.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/telemetry_sessions.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';
import 'package:torque_obd/ui/screens/telemetry/telemetry_session_detail_screen.dart';

void main() {
  testWidgets('detail exposes labels speeds scrubber and sampled disclaimer', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          telemetryHistoryAccessProvider.overrideWithValue(
            TelemetryHistoryAccess.permitted,
          ),
          telemetrySessionReplayProvider.overrideWith(
            (ref, id) async => _replay,
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const TelemetrySessionDetailScreen(
            sessionId: '00000000000000000000000000000001',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('內建模擬'), findsOneWidget);
    expect(find.text('demo · ISO 15765-4 CAN'), findsOneWidget);
    expect(find.text('2 項訊號'), findsOneWidget);
    expect(find.text('3 筆有效值'), findsOneWidget);
    expect(find.text('1 個狀態'), findsOneWidget);
    expect(find.text('2 個缺口'), findsOneWidget);
    expect(find.text('已手動停止'), findsOneWidget);
    expect(find.text(telemetryReplayDisclaimer), findsOneWidget);
    expect(find.text('1x'), findsOneWidget);
    expect(find.text('4x'), findsOneWidget);
    expect(find.text('16x'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.text('4 個抽樣節點 · 1 個中斷'), findsOneWidget);
    expect(
      tester
          .getSemantics(
            find.byKey(const ValueKey('telemetry-replay-lane-7E0:010C')),
          )
          .label,
      contains('1 個中斷'),
    );

    await tester.tap(find.text('16x'));
    await tester.tap(find.text('播放'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester.widget<Slider>(find.byType(Slider)).value,
      greaterThan(0.04),
      reason: 'playback speed follows canonical elapsed time, not wall clock',
    );

    await tester.drag(find.byType(Slider), const Offset(80, 0));
    await tester.pump();
    expect(find.text('播放'), findsOneWidget, reason: 'scrubbing pauses replay');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('denied history access stops and resets mounted playback', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          telemetryHistoryAccessProvider.overrideWith(
            (ref) => ref.watch(_accessProvider),
          ),
          telemetrySessionReplayProvider.overrideWith(
            (ref, id) async => _replay,
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const TelemetrySessionDetailScreen(
            sessionId: '00000000000000000000000000000001',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('播放'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.widget<Slider>(find.byType(Slider)).value, greaterThan(0));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(TelemetrySessionDetailScreen)),
    );
    container
        .read(_accessProvider.notifier)
        .setAccess(TelemetryHistoryAccess.moving);
    await tester.pump();
    expect(find.text('請停車後操作'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));

    container
        .read(_accessProvider.notifier)
        .setAccess(TelemetryHistoryAccess.permitted);
    await tester.pumpAndSettle();
    expect(find.text('播放'), findsOneWidget);
    expect(tester.widget<Slider>(find.byType(Slider)).value, 0);
  });
}

final _accessProvider =
    NotifierProvider<_AccessNotifier, TelemetryHistoryAccess>(
      _AccessNotifier.new,
    );

class _AccessNotifier extends Notifier<TelemetryHistoryAccess> {
  @override
  TelemetryHistoryAccess build() => TelemetryHistoryAccess.permitted;

  void setAccess(TelemetryHistoryAccess value) => state = value;
}

final _replay = TelemetryReplayResult.success(
  TelemetrySessionReplay(
    sessionId: '00000000000000000000000000000001',
    startedAtUtc: DateTime.utc(2026, 8, 30, 1),
    endedAtUtc: DateTime.utc(2026, 8, 30, 3),
    source: TelemetrySource.demo,
    transport: TransportKind.demo.name,
    protocol: 'ISO 15765-4 CAN',
    signalCount: 2,
    valueCount: 3,
    statusCount: 1,
    gapCount: 2,
    terminalReason: TelemetryTerminalReason.user,
    elapsedDurationUs: 60000000,
    workerDebugName: 'detail-test-worker',
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
            elapsedUs: 30000000,
          ),
          TelemetryReplayPrimitive(
            kind: TelemetryReplayPrimitiveKind.status,
            elapsedUs: 30000000,
          ),
          TelemetryReplayPrimitive(
            kind: TelemetryReplayPrimitiveKind.value,
            elapsedUs: 60000000,
            value: 2000,
            breakBefore: true,
          ),
        ],
      ),
    ],
  ),
);
