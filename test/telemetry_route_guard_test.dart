import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torque_obd/core/theme/app_theme.dart';
import 'package:torque_obd/obd/pid/pid.dart';
import 'package:torque_obd/obd/telemetry.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_registry.dart';
import 'package:torque_obd/state/telemetry_recorder.dart';
import 'package:torque_obd/state/telemetry_runtime.dart';
import 'package:torque_obd/state/telemetry_sessions.dart';
import 'package:torque_obd/telemetry/session/telemetry_recorder.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_store.dart';
import 'package:torque_obd/ui/screens/dashboard/dashboard_screen.dart';
import 'package:torque_obd/ui/screens/telemetry/telemetry_session_detail_screen.dart';
import 'package:torque_obd/ui/screens/telemetry/telemetry_sessions_screen.dart';
import 'package:torque_obd/ui/widgets/telemetry/telemetry_history_entry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final phase in const [
    TelemetryRecorderPhase.preparing,
    TelemetryRecorderPhase.recording,
    TelemetryRecorderPhase.finalizing,
  ]) {
    test('history access is blocked throughout ${phase.name}', () {
      expect(
        telemetryHistoryAccess(recorderPhase: phase, safety: null),
        TelemetryHistoryAccess.recorderActive,
      );
    });
  }

  testWidgets(
    'Connect history entry checks access before mounting the library',
    (tester) async {
      var libraryBuilds = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            telemetryHistoryAccessProvider.overrideWithValue(
              TelemetryHistoryAccess.recorderActive,
            ),
            telemetrySessionLibraryProvider.overrideWith((ref) async {
              libraryBuilds++;
              return _emptyLibrary;
            }),
          ],
          child: _app(const Scaffold(body: TelemetryHistoryEntry())),
        ),
      );
      await tester.pump();

      expect(find.text('請先停止並儲存'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
      expect(libraryBuilds, 0);
    },
  );

  testWidgets('/sessions checks access before mounting the library', (
    tester,
  ) async {
    var libraryBuilds = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          telemetryHistoryAccessProvider.overrideWithValue(
            TelemetryHistoryAccess.recorderActive,
          ),
          telemetrySessionLibraryProvider.overrideWith((ref) async {
            libraryBuilds++;
            return _emptyLibrary;
          }),
        ],
        child: _app(const TelemetrySessionsScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('請先停止並儲存'), findsOneWidget);
    expect(libraryBuilds, 0);
  });

  testWidgets('detail checks access before mounting replay', (tester) async {
    var replayBuilds = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          telemetryHistoryAccessProvider.overrideWithValue(
            TelemetryHistoryAccess.recorderActive,
          ),
          telemetrySessionReplayProvider.overrideWith((ref, id) async {
            replayBuilds++;
            return const TelemetryReplayResult.failure(
              TelemetryReplayFailure.notFound,
            );
          }),
        ],
        child: _app(
          const TelemetrySessionDetailScreen(
            sessionId: '00000000000000000000000000000001',
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('請先停止並儲存'), findsOneWidget);
    expect(replayBuilds, 0);
  });

  testWidgets('Dashboard disables history with the exact blocked copy', (
    tester,
  ) async {
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
    var libraryBuilds = 0;
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
          telemetryHistoryAccessProvider.overrideWithValue(
            TelemetryHistoryAccess.recorderActive,
          ),
          telemetrySessionLibraryProvider.overrideWith((ref) async {
            libraryBuilds++;
            return _emptyLibrary;
          }),
        ],
        child: _app(const DashboardScreen()),
      ),
    );
    await tester.pump();

    final button = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('telemetry-history')),
    );
    expect(button.onPressed, isNull);
    expect(
      find.byKey(const ValueKey('telemetry-history-blocked-copy')),
      findsOneWidget,
    );
    expect(find.text('請先停止並儲存'), findsWidgets);
    expect(libraryBuilds, 0);
    expect(tester.takeException(), isNull);
  });

  test(
    'read-only library lookup does not create a missing directory',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'telemetry-read-only-',
      );
      addTearDown(() => root.delete(recursive: true));
      final history = Directory('${root.path}/telltale-telemetry');
      final store = TelemetrySessionStore(documentsDirectory: () async => root);

      final quota = await store.scanQuota();
      final index = await store.listSessions();
      final library = await TelemetrySessionLibraryService(
        documentsDirectory: () async => root,
      ).load();

      expect(quota.groupCount, 0);
      expect(quota.recognizedBytes, 0);
      expect(index.sessions, isEmpty);
      expect(index.damaged, isEmpty);
      expect(library.sessions, isEmpty);
      expect(library.damaged, isEmpty);
      expect(await history.exists(), isFalse);
    },
  );
}

const _emptyLibrary = TelemetrySessionLibrary(
  sessions: [],
  damaged: [],
  groupCount: 0,
  recognizedBytes: 0,
  omittedCount: 0,
  encodedProjectionBytes: 0,
  workerDebugName: 'unused-provider-spy',
);

Widget _app(Widget home) => MaterialApp(theme: AppTheme.dark(), home: home);

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
