import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torque_obd/core/theme/app_theme.dart';
import 'package:torque_obd/obd/pid/pid.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/telemetry.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_registry.dart';
import 'package:torque_obd/state/telemetry_recorder.dart';
import 'package:torque_obd/state/telemetry_runtime.dart';
import 'package:torque_obd/state/telemetry_trends.dart';
import 'package:torque_obd/telemetry/session/telemetry_recorder.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';
import 'package:torque_obd/telemetry/session/timeline_downsampler.dart';
import 'package:torque_obd/ui/screens/dashboard/dashboard_screen.dart';
import 'package:torque_obd/ui/screens/dashboard/telemetry_workspace.dart';
import 'package:torque_obd/ui/widgets/telemetry/live_trend_card.dart';
import 'package:torque_obd/ui/widgets/telemetry/telemetry_recorder_panel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('chart separates value segments and exposes unavailable reason', (
    tester,
  ) async {
    const pid = PidLibrary.engineRpm;
    final lane = TelemetryTrendLane(
      pid: pid,
      primitives: const [
        TimelineValue(elapsedUs: 0, value: 1200, segmentId: 'a'),
        TimelineValue(elapsedUs: 1000000, value: 1800, segmentId: 'a'),
        TimelineGap(elapsedUs: 2000000, gapId: 'gap'),
        TimelineStatus(elapsedUs: 2000000, status: 'stale'),
        TimelineValue(
          elapsedUs: 3000000,
          value: 2200,
          segmentId: 'b',
          breakBefore: true,
        ),
      ],
      currentValue: null,
      currentStatus: TelemetryStatus.stale,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: LiveTrendCard(
            lane: lane,
            windowEndElapsedUs: 3000000,
            recordingLabel: '未錄製',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('資料已過期'), findsOneWidget);
    expect(find.text('--'), findsOneWidget);
    final chart = tester.widget<LineChart>(find.byType(LineChart));
    expect(chart.data.lineBarsData, hasLength(2));
    expect(chart.data.lineBarsData.first.spots, hasLength(2));
    expect(chart.data.lineBarsData.last.spots, hasLength(1));
    expect(chart.data.extraLinesData.verticalLines, hasLength(2));

    final semantics = tester.getSemantics(find.byType(LiveTrendCard));
    expect(semantics.label, contains('資料已過期'));
    expect(semantics.label, contains('最近 60 秒'));
  });

  testWidgets('disconnected card never carries the last value as current', (
    tester,
  ) async {
    const pid = PidLibrary.engineRpm;
    final lane = TelemetryTrendLane(
      pid: pid,
      primitives: const [
        TimelineValue(elapsedUs: 0, value: 2400, segmentId: 'a'),
      ],
      currentValue: 2400,
      currentStatus: null,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: LiveTrendCard(
            lane: lane,
            windowEndElapsedUs: 0,
            recordingLabel: '未錄製',
            isConnected: false,
          ),
        ),
      ),
    );

    expect(find.text('目前未連線'), findsOneWidget);
    expect(find.text('--'), findsOneWidget);
    expect(find.text('2400'), findsNothing);
    expect(
      tester.getSemantics(find.byType(LiveTrendCard)).label,
      contains('目前未連線'),
    );
  });

  testWidgets('dashboard uses a full-width local gauges and trends switch', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final now = DateTime.now().toUtc();
    final environment = LiveTelemetryStartEnvironment(
      readConnection: () => const TelemetryConnectionSnapshot(
        connected: false,
        foreground: true,
        connectionGeneration: 0,
        foregroundEpoch: 1,
      ),
      utcNow: () => now,
      elapsedUs: () => 0,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          obdSessionProvider.overrideWith(_DisconnectedSession.new),
          activePidsProvider.overrideWith(() => _FixedActivePids(const [])),
          telemetryProvider.overrideWith(
            (ref) => Stream.value(const TelemetrySnapshot()),
          ),
          liveTelemetryStartEnvironmentProvider.overrideWithValue(environment),
          currentTelemetryConnectionEvidenceProvider.overrideWithValue(null),
          telemetryRecorderProgressProvider.overrideWith(
            () => _FixedProgressNotifier(
              const TelemetryRecorderProgress(
                state: TelemetryRecorderState.idle(),
                elapsedUs: 0,
                bytesBeforeFooter: 0,
                effectiveSessionLimit: null,
                sessionId: null,
              ),
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const DashboardScreen(),
        ),
      ),
    );
    await tester.pump();

    final switcher = find.byKey(const ValueKey('dashboard-workspace-switch'));
    expect(switcher, findsOneWidget);
    expect(tester.getSize(switcher).width, greaterThan(330));
    await tester.tap(find.text('趨勢'));
    await tester.pump();

    expect(find.text('趨勢訊號'), findsOneWidget);
    expect(find.text('目前未連線'), findsOneWidget);
    expect(find.text('沒有可用的趨勢訊號'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'workspace shows at most four aligned lanes at 200 percent text',
    (tester) async {
      tester.view.physicalSize = const Size(640, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final active = PidLibrary.all
          .where(
            (pid) =>
                pid.isMode01 &&
                pid.header == kDefaultHeader &&
                pid.variant == null,
          )
          .take(5)
          .toList();
      final now = DateTime.now().toUtc();
      final readings = <String, Reading>{
        for (var index = 0; index < active.length; index++)
          active[index].id: Reading(
            pid: active[index],
            value: 10 + index.toDouble(),
            rawBytes: const [0],
            timestamp: now,
          ),
        PidLibrary.vehicleSpeed.id: Reading(
          pid: PidLibrary.vehicleSpeed,
          value: 0,
          rawBytes: const [0],
          timestamp: now,
        ),
      };
      final snapshot = TelemetrySnapshot(readings: readings, capturedAt: now);
      final environment = LiveTelemetryStartEnvironment(
        readConnection: () => const TelemetryConnectionSnapshot(
          connected: true,
          foreground: true,
          connectionGeneration: 1,
          foregroundEpoch: 1,
        ),
        utcNow: () => now,
        elapsedUs: () => 1000000,
      )..observeTelemetry(snapshot);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(preferences),
            activePidsProvider.overrideWith(() => _FixedActivePids(active)),
            telemetryProvider.overrideWith((ref) => Stream.value(snapshot)),
            liveTelemetryStartEnvironmentProvider.overrideWithValue(
              environment,
            ),
            currentTelemetryConnectionEvidenceProvider.overrideWithValue(
              const TelemetryConnectionEvidence(
                source: TelemetrySource.demo,
                transport: TransportKind.demo,
                protocol: 'ISO 15765-4 CAN',
              ),
            ),
            telemetryRecorderProgressProvider.overrideWith(
              () => _FixedProgressNotifier(
                const TelemetryRecorderProgress(
                  state: TelemetryRecorderState(
                    phase: TelemetryRecorderPhase.recording,
                    valueCount: 12,
                  ),
                  elapsedUs: 0,
                  bytesBeforeFooter: 0,
                  effectiveSessionLimit: null,
                  sessionId: null,
                ),
              ),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.dark(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: const Scaffold(
              body: SafeArea(
                child: SingleChildScrollView(child: TelemetryWorkspace()),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(LiveTrendCard), findsNWidgets(4));
      expect(find.text('內建模擬資料'), findsOneWidget);
      for (final card in tester.widgetList<LiveTrendCard>(
        find.byType(LiveTrendCard),
      )) {
        expect(card.lane.isAvailable, isTrue);
      }
      for (final element in find.byType(LiveTrendCard).evaluate()) {
        final rect = tester.getRect(find.byWidget(element.widget));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(640));
        expect(rect.width, greaterThan(560));
      }
      expect(
        tester.getSemantics(find.byType(LiveTrendCard).first).label,
        contains('顯示最近 60 秒趨勢'),
      );
      final selector = tester.widget<ActionChip>(
        find.byKey(const ValueKey('telemetry-lane-selector')),
      );
      expect(selector.onPressed, isNotNull);
      await tester.ensureVisible(find.byType(LiveTrendCard).last);
      await tester.pump();
      final lastCard = tester.getRect(find.byType(LiveTrendCard).last);
      expect(lastCard.top, lessThan(360));
      expect(lastCard.bottom, greaterThan(0));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('recorder panel keeps privacy status and Stop usable at 200%', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 1136);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final active = [PidLibrary.engineRpm, PidLibrary.vehicleSpeed];
    final now = DateTime.now().toUtc();
    final snapshot = TelemetrySnapshot(
      readings: {
        PidLibrary.vehicleSpeed.id: Reading(
          pid: PidLibrary.vehicleSpeed,
          value: 0,
          rawBytes: const [0],
          timestamp: now,
        ),
      },
      capturedAt: now,
    );
    final environment = LiveTelemetryStartEnvironment(
      readConnection: () => const TelemetryConnectionSnapshot(
        connected: true,
        foreground: true,
        connectionGeneration: 1,
        foregroundEpoch: 1,
      ),
      utcNow: () => now,
      elapsedUs: () => 1000000,
    )..observeTelemetry(snapshot);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          obdSessionProvider.overrideWith(_DisconnectedSession.new),
          activePidsProvider.overrideWith(() => _FixedActivePids(active)),
          telemetryProvider.overrideWith((ref) => Stream.value(snapshot)),
          liveTelemetryStartEnvironmentProvider.overrideWithValue(environment),
          currentTelemetryConnectionEvidenceProvider.overrideWithValue(
            const TelemetryConnectionEvidence(
              source: TelemetrySource.demo,
              transport: TransportKind.demo,
              protocol: 'ISO 15765-4 CAN',
            ),
          ),
          telemetryRecorderProgressProvider.overrideWith(
            () => _FixedProgressNotifier(
              const TelemetryRecorderProgress(
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
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: const Scaffold(
            body: SafeArea(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(16),
                child: TelemetryRecorderPanel(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('不含位置、VIN 或帳號資料'), findsOneWidget);
    expect(find.textContaining('全部 2 項已啟用訊號'), findsOneWidget);
    expect(find.textContaining('估算馬力與估算油耗'), findsOneWidget);
    expect(find.textContaining('車輛假設'), findsOneWidget);
    expect(find.text('243 筆有效值'), findsOneWidget);
    expect(find.text('8.0 KiB / 1.0 MiB'), findsOneWidget);
    expect(find.text('00:42'), findsOneWidget);
    final stop = find.byKey(const ValueKey('telemetry-stop'));
    expect(stop, findsOneWidget);
    expect(tester.getSize(stop).height, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
  });
}

class _FixedActivePids extends ActivePids {
  _FixedActivePids(this.value);

  final List<Pid> value;

  @override
  List<Pid> build() => value;
}

class _FixedProgressNotifier extends TelemetryRecorderProgressNotifier {
  _FixedProgressNotifier(this.value);

  final TelemetryRecorderProgress value;

  @override
  TelemetryRecorderProgress build() => value;
}

class _DisconnectedSession extends ObdSession {
  @override
  ObdConnectionState build() => const ObdConnectionState();
}
