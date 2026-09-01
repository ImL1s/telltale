import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:torque_obd/core/theme/app_theme.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/telemetry_recorder.dart';
import 'package:torque_obd/telemetry/session/telemetry_recorder.dart';
import 'package:torque_obd/ui/shell.dart';
import 'package:torque_obd/ui/widgets/telemetry/telemetry_status_copy.dart';

void main() {
  testWidgets('recording strip stays above every compact destination', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpShell(
      tester,
      progress: const TelemetryRecorderProgress(
        state: TelemetryRecorderState(
          phase: TelemetryRecorderPhase.recording,
          valueCount: 243,
          statusCount: 7,
          gapCount: 1,
        ),
        elapsedUs: 42 * Duration.microsecondsPerSecond,
        bytesBeforeFooter: 8192,
        effectiveSessionLimit: 1024 * 1024,
        sessionId: 'session-1',
      ),
    );

    expect(find.text('PID 頁面'), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(5));
    expect(find.textContaining('錄製中 00:42'), findsOneWidget);
    expect(find.textContaining('243 筆有效值'), findsOneWidget);
    expect(find.byKey(const ValueKey('telemetry-shell-stop')), findsOneWidget);
    expect(find.text('停止並儲存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'finalizing strip remains readable with rail and 200 percent text',
    (tester) async {
      tester.view.physicalSize = const Size(900, 520);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await _pumpShell(
        tester,
        textScaler: const TextScaler.linear(2),
        progress: const TelemetryRecorderProgress(
          state: TelemetryRecorderState(
            phase: TelemetryRecorderPhase.finalizing,
            valueCount: 501,
            statusCount: 9,
            gapCount: 2,
          ),
          elapsedUs: 65 * Duration.microsecondsPerSecond,
          bytesBeforeFooter: 16384,
          effectiveSessionLimit: 1024 * 1024,
          sessionId: 'session-2',
        ),
      );

      expect(find.byType(NavigationRail), findsOneWidget);
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.destinations, hasLength(5));
      expect(find.textContaining('正在儲存紀錄'), findsOneWidget);
      expect(
        find.textContaining(telemetryPendingOwnerRecoveryCopy),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('telemetry-shell-stop')), findsNothing);
      expect(
        find.byKey(const ValueKey('telemetry-return-to-trends')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('recording strip fits narrow landscape at 200 percent text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpShell(
      tester,
      textScaler: const TextScaler.linear(2),
      progress: const TelemetryRecorderProgress(
        state: TelemetryRecorderState(
          phase: TelemetryRecorderPhase.recording,
          valueCount: 19,
          statusCount: 1,
        ),
        elapsedUs: 9 * Duration.microsecondsPerSecond,
        bytesBeforeFooter: 2048,
        effectiveSessionLimit: 1024 * 1024,
        sessionId: 'session-3',
      ),
    );

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byKey(const ValueKey('telemetry-shell-stop')), findsOneWidget);
    expect(find.textContaining('錄製中 00:09'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('native rail scrolls at 832x384 with 200 percent text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(832, 384);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpShell(
      tester,
      textScaler: const TextScaler.linear(2),
      progress: const TelemetryRecorderProgress(
        state: TelemetryRecorderState(
          phase: TelemetryRecorderPhase.recording,
          valueCount: 19,
          statusCount: 1,
        ),
        elapsedUs: 9 * Duration.microsecondsPerSecond,
        bytesBeforeFooter: 2048,
        effectiveSessionLimit: 1024 * 1024,
        sessionId: 'session-rail-short',
      ),
    );

    final railFinder = find.byType(NavigationRail);
    expect(railFinder, findsOneWidget);
    final rail = tester.widget<NavigationRail>(railFinder);
    expect(rail.scrollable, isTrue);
    expect(rail.destinations, hasLength(5));
    expect(find.text('19 筆有效值'), findsOneWidget);
    expect(find.text('1 個狀態'), findsOneWidget);
    expect(find.text('0 個缺口'), findsOneWidget);
    final settings = find.descendant(of: railFinder, matching: find.text('設定'));
    expect(settings, findsOneWidget);
    await Scrollable.ensureVisible(tester.element(settings), alignment: 0.5);
    await tester.pump();
    expect(settings.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('preparing strip keeps restart guidance visible', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpShell(
      tester,
      progress: const TelemetryRecorderProgress(
        state: TelemetryRecorderState(
          phase: TelemetryRecorderPhase.preparing,
          requiresRestart: true,
        ),
        elapsedUs: 0,
        bytesBeforeFooter: 0,
        effectiveSessionLimit: null,
        sessionId: 'preparing-session',
      ),
    );

    expect(find.textContaining('正在準備錄製'), findsOneWidget);
    expect(
      find.textContaining(telemetryPendingOwnerRecoveryCopy),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('telemetry-shell-stop')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpShell(
  WidgetTester tester, {
  required TelemetryRecorderProgress progress,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  final router = GoRouter(
    initialLocation: '/pids',
    routes: [
      GoRoute(
        path: '/pids',
        builder: (context, state) => const AppShell(
          child: Scaffold(body: Center(child: Text('PID 頁面'))),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        obdSessionProvider.overrideWith(_DisconnectedSession.new),
        telemetryRecorderProgressProvider.overrideWith(
          () => _FixedProgressNotifier(progress),
        ),
      ],
      child: MaterialApp.router(
        theme: AppTheme.dark(),
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: textScaler, disableAnimations: true),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pump();
}

class _DisconnectedSession extends ObdSession {
  @override
  ObdConnectionState build() => const ObdConnectionState();
}

class _FixedProgressNotifier extends TelemetryRecorderProgressNotifier {
  _FixedProgressNotifier(this.value);

  final TelemetryRecorderProgress value;

  @override
  TelemetryRecorderProgress build() => value;
}
