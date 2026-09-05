import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/core/share/app_share_platform_bridge.dart';
import 'package:torque_obd/core/share/rig_app_share_platform.dart';
import 'package:torque_obd/main.dart' as app;
import 'package:torque_obd/obd/session_evidence.dart';
import 'package:torque_obd/obd/transcript.dart';
import 'package:torque_obd/obd/transcript_store.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/app_share_coordinator.dart';
import 'package:torque_obd/state/artifact_operation_gate.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/telemetry_recorder.dart';
import 'package:torque_obd/state/telemetry_runtime.dart';
import 'package:torque_obd/state/telemetry_sessions.dart';
import 'package:torque_obd/telemetry/session/telemetry_recorder.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_reader.dart';
import 'package:torque_obd/ui/screens/dashboard/dashboard_screen.dart';

/// Starts the isolated `.rig` app from a state that cannot inherit a prior
/// successful connection or transcript.
Future<void> startCleanRigApp(WidgetTester tester) async {
  await requireIsolatedRigIdentity();
  await (await SharedPreferences.getInstance()).clear();
  final clearOutcome = await TranscriptStore(
    destructivePolicy: const _RigDestructivePolicy(),
  ).clear();
  expect(
    clearOutcome.succeeded,
    isTrue,
    reason: 'rig start refused to clear last-session.log: ${clearOutcome.error}',
  );
  final telemetry = Directory(
    '${(await getApplicationDocumentsDirectory()).path}/telltale-telemetry',
  );
  if (await telemetry.exists()) await telemetry.delete(recursive: true);
  final capturedShares = await rigShareCaptureDirectory();
  if (await capturedShares.exists()) {
    await capturedShares.delete(recursive: true);
  }

  await startRigAppPreservingState(tester);
}

/// Starts the isolated rig identity without deleting durable artifacts.
///
/// Process-kill recovery tests must use this entry point: clearing preferences
/// or Documents here would turn a fresh-root recovery assertion into a test of
/// an empty install.
Future<void> startRigAppPreservingState(WidgetTester tester) async {
  await requireIsolatedRigIdentity();

  unawaited(app.main());
  final ready = await pumpUntil(
    tester,
    () => find.text('選擇連線方式').evaluate().isNotEmpty,
    timeout: const Duration(seconds: 15),
  );
  expect(ready, isTrue, reason: 'the connection screen did not become ready');
}

/// Non-destructively proves the live process is the exact debug rig package.
Future<void> requireIsolatedRigIdentity() async {
  expect(
    Platform.isAndroid,
    isTrue,
    reason:
        'rig integration tests may clear local state only inside the isolated '
        'Android com.cbstudio.telltale.rig package',
  );
  expect(
    kDebugMode,
    isTrue,
    reason: 'rig integration tests refuse to clear state outside a debug build',
  );
  expect(
    isObdTestRigBuild,
    isTrue,
    reason:
        'pass --flavor rig and --dart-define=TELLTALE_TEST_RIG=true so '
        'simulated evidence is never labelled as physical hardware',
  );
  final rawMetadata = await const MethodChannel(
    'com.cbstudio.telltale/platform_metadata',
  ).invokeMethod<Object?>('getPlatformMetadata');
  final applicationId = rawMetadata is Map<Object?, Object?>
      ? rawMetadata['applicationId']
      : null;
  expect(
    applicationId,
    'com.cbstudio.telltale.rig',
    reason:
        'refusing to clear local state: the running package is not the '
        'isolated Android rig app',
  );
}

/// Connects the built-in Demo ECU and waits for live values.
Future<void> connectDemoRig(WidgetTester tester) async {
  final demoHeader = await revealText(tester, 'Demo 模擬器');
  await tester.tap(demoHeader);
  await tester.pumpAndSettle();

  final launchButton = await revealText(tester, '啟動模擬器');
  await tester.tap(launchButton);
  await tester.pump();

  await requireDashboard(tester);
  await requireLivePolling(tester);
}

/// Pumps for up to [timeout], returning true as soon as [predicate] holds.
///
/// `pumpAndSettle` is unsuitable while scanning or polling because the app has
/// intentional animations and timers that do not settle.
Future<bool> pumpUntil(
  WidgetTester tester,
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 30),
  Duration step = const Duration(milliseconds: 250),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return true;
    await tester.pump(step);
  }
  return predicate();
}

Future<T?> pumpUntilValue<T>(
  WidgetTester tester,
  Future<T?> Function() read, {
  Duration timeout = const Duration(seconds: 10),
  Duration step = const Duration(milliseconds: 200),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final value = await read();
    if (value != null) return value;
    await tester.pump(step);
  }
  return read();
}

Future<void> requireDashboard(
  WidgetTester tester, {
  Duration timeout = const Duration(seconds: 90),
}) async {
  final reached = await pumpUntil(
    tester,
    () => find.text('儀表板').evaluate().isNotEmpty,
    timeout: timeout,
  );
  expect(reached, isTrue, reason: 'the app never reached the dashboard');
}

/// Scrolls the connection wizard until its lazily built sliver contains
/// [text]. Looking up the finder before scrolling is not sufficient: on a
/// phone-sized viewport even the first transport card can be outside the
/// initial sliver cache.
Future<Finder> revealText(WidgetTester tester, String text) async {
  final finder = find.text(text);
  await tester.scrollUntilVisible(
    finder,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  expect(finder, findsOneWidget);
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await tester.pump(const Duration(milliseconds: 300));
  final hitTestable = finder.hitTestable();
  expect(hitTestable, findsOneWidget);
  return hitTestable;
}

bool hasNonZeroPidRate(WidgetTester tester) =>
    tester.widgetList<Text>(find.byType(Text)).any((text) {
      final value = text.data;
      return value != null && RegExp(r'^[1-9]\d* PIDs/s$').hasMatch(value);
    });

Future<void> requireLivePolling(
  WidgetTester tester, {
  Duration timeout = const Duration(seconds: 30),
  String reason = 'the dashboard never received live PIDs',
}) async {
  final polled = await pumpUntil(
    tester,
    () => hasNonZeroPidRate(tester),
    timeout: timeout,
  );
  expect(polled, isTrue, reason: reason);
}

/// Session-owned boundary for a lifecycle resume assertion.
///
/// Unlike the dashboard's `N PIDs/s` label, this evidence is available in both
/// Dashboard and Trends workspaces.
final class PollingResumeBaseline {
  const PollingResumeBaseline({
    required this.newestReadingAt,
    required this.transcriptBoundary,
  });

  final DateTime newestReadingAt;
  final TranscriptEntry transcriptBoundary;
}

PollingResumeBaseline capturePollingResumeBaseline(WidgetTester tester) {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
    listen: false,
  );
  final session = container.read(obdSessionProvider.notifier);
  final engine = session.engine;
  final transcript = session.exportableTranscript;
  expect(engine, isNotNull, reason: 'resume baseline requires a live engine');
  expect(
    engine!.current.readings,
    isNotEmpty,
    reason: 'resume baseline requires at least one PID reading',
  );
  expect(
    transcript?.entries,
    isNotEmpty,
    reason: 'resume baseline requires wire evidence',
  );
  return PollingResumeBaseline(
    newestReadingAt: engine.current.readings.values
        .map((reading) => reading.timestamp)
        .reduce((a, b) => a.isAfter(b) ? a : b),
    transcriptBoundary: transcript!.entries.last,
  );
}

/// Proves resume through the production session rather than through visible UI.
///
/// Requires the resume marker, its `ATRV` probe and response, plus a PID reading
/// newer than [baseline], while the engine and transport remain live.
Future<void> requirePollingRecoveredAfterResume(
  WidgetTester tester,
  PollingResumeBaseline baseline, {
  Duration timeout = const Duration(seconds: 20),
  String reason = 'polling did not recover after resume',
}) async {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
    listen: false,
  );

  bool recovered() {
    final state = container.read(obdSessionProvider);
    final session = container.read(obdSessionProvider.notifier);
    final engine = session.engine;
    final client = session.client;
    final transcript = session.exportableTranscript;
    if (state.phase != ConnectionPhase.connected ||
        !session.isForeground ||
        engine == null ||
        !engine.isRunning ||
        client == null ||
        !client.transport.isConnected ||
        transcript == null) {
      return false;
    }

    final entries = transcript.entries;
    final boundaryAt = entries.indexWhere(
      (entry) => identical(entry, baseline.transcriptBoundary),
    );
    if (boundaryAt < 0) return false;
    final resumedAt = entries.indexWhere(
      (entry) =>
          entry.direction == TranscriptDirection.note &&
          entry.note == 'App 回到前景',
      boundaryAt + 1,
    );
    if (resumedAt < 0) return false;
    final probeAt = entries.indexWhere(
      (entry) =>
          entry.direction == TranscriptDirection.out && entry.text == r'ATRV\r',
      resumedAt + 1,
    );
    if (probeAt < 0) return false;
    final probeResponseAt = entries.indexWhere(
      (entry) => entry.direction == TranscriptDirection.incoming,
      probeAt + 1,
    );
    if (probeResponseAt < 0) return false;
    return engine.current.readings.values.any(
      (reading) => reading.timestamp.isAfter(baseline.newestReadingAt),
    );
  }

  if (await pumpUntil(tester, recovered, timeout: timeout)) return;

  final state = container.read(obdSessionProvider);
  final session = container.read(obdSessionProvider.notifier);
  final transcript = session.exportableTranscript?.frozenCopy().render(
    header: session.exportableTranscriptHeader,
  );
  fail(
    '$reason\n'
    'phase=${state.phase.name} kind=${state.kind?.name} '
    'error=${state.error}\n'
    'foreground=${session.isForeground} generation=${session.generation} '
    'engineRunning=${session.engine?.isRunning} '
    'transportConnected=${session.client?.transport.isConnected}\n'
    'baselineReading=${baseline.newestReadingAt.toIso8601String()} '
    'newestReading=${_newestReadingAt(session)?.toIso8601String()}\n'
    'transcript tail:\n${_tail(transcript ?? '<none>', 5000)}',
  );
}

DateTime? _newestReadingAt(ObdSession session) {
  final readings = session.engine?.current.readings.values;
  if (readings == null || readings.isEmpty) return null;
  return readings
      .map((reading) => reading.timestamp)
      .reduce((a, b) => a.isAfter(b) ? a : b);
}

String _tail(String value, int limit) =>
    value.length <= limit ? value : value.substring(value.length - limit);

final class TelemetryRigJourneyEvidence {
  const TelemetryRigJourneyEvidence({
    required this.sessionId,
    required this.terminalReason,
    required this.valueCount,
    required this.statusCount,
    required this.gapCount,
  });

  final String sessionId;
  final TelemetryTerminalReason terminalReason;
  final int valueCount;
  final int statusCount;
  final int gapCount;
}

/// Exercises the shipped root recorder and the production session action
/// classes after a transport has reached live polling. Only the final platform
/// Share invocation is replaced, so the test can inspect the immutable export
/// instead of opening Android's chooser.
Future<TelemetryRigJourneyEvidence> completeTelemetryRigJourney(
  WidgetTester tester, {
  required TransportKind expectedTransport,
  TelemetryTerminalReason expectedTerminalReason = TelemetryTerminalReason.user,
  FutureOr<void> Function()? afterFirstRecordedValue,
}) async {
  final switcher = find.byKey(const ValueKey('dashboard-workspace-switch'));
  expect(switcher, findsOneWidget);
  await tester.ensureVisible(switcher);
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
  await revealText(tester, '測試馬具資料');

  final start = find.byKey(const ValueKey('telemetry-start'));
  await Scrollable.ensureVisible(tester.element(start), alignment: 0.5);
  await tester.pump(const Duration(milliseconds: 100));
  expect(
    await pumpUntil(
      tester,
      () =>
          start.evaluate().isNotEmpty &&
          tester.widget<FilledButton>(start).onPressed != null,
      timeout: const Duration(seconds: 10),
      step: const Duration(milliseconds: 50),
    ),
    isTrue,
    reason:
        '${expectedTransport.name} never produced a fresh stopped speed '
        'sample for Start',
  );
  expect(start.hitTestable(), findsOneWidget);
  await tester.tap(start.hitTestable());
  await tester.pump();

  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
    listen: false,
  );
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
    reason:
        '${expectedTransport.name} recorder never accepted its first '
        'structured value',
  );
  final afterFirstValue = afterFirstRecordedValue;
  if (afterFirstValue != null) await afterFirstValue();

  if (expectedTerminalReason == TelemetryTerminalReason.user) {
    final stop = find.byKey(const ValueKey('telemetry-stop'));
    expect(stop, findsOneWidget);
    await tester.ensureVisible(stop);
    await tester.pump(const Duration(milliseconds: 100));
    expect(stop.hitTestable(), findsOneWidget);
    await tester.tap(stop.hitTestable());
    await tester.pump();
  }
  expect(
    await pumpUntil(
      tester,
      () => controller.state.phase == TelemetryRecorderPhase.completed,
      timeout: const Duration(seconds: 30),
    ),
    isTrue,
    reason:
        '${expectedTransport.name} recorder did not reach its first expected '
        '${expectedTerminalReason.name} terminal',
  );

  final sessionId = controller.progress.sessionId;
  expect(sessionId, isNotNull);
  final documents = await getApplicationDocumentsDirectory();
  final file = File('${documents.path}/telltale-telemetry/$sessionId.ndjson');
  expect(await file.exists(), isTrue);
  final read = await const TelemetrySessionReader().read(
    FileTelemetryChunkSource(file),
  );
  expect(read.isValid, isTrue);
  expect(read.footerSeen, isTrue);
  expect(read.valueCount, greaterThan(0));
  expect(read.sessionHeader?.source, TelemetrySource.simulatedRig);
  expect(read.sessionHeader?.transport, expectedTransport);
  expect(read.sessionFooter?.terminalReason, expectedTerminalReason);
  expect(read.sessionFooter?.valueCount, read.valueCount);
  expect(read.sessionFooter?.statusCount, read.statusCount);
  expect(read.sessionFooter?.gapCount, read.gapCount);

  final service = TelemetrySessionLibraryService(
    documentsDirectory: () async => documents,
  );
  final library = await service.load();
  final projection = library.sessions.singleWhere(
    (item) => item.id == sessionId,
  );
  expect(projection.source, TelemetrySource.simulatedRig);
  expect(projection.transport, expectedTransport.name);
  expect(projection.valueCount, read.valueCount);
  expect(projection.statusCount, read.statusCount);
  expect(projection.gapCount, read.gapCount);
  expect(projection.terminalReason, expectedTerminalReason);

  final replayResult = await service.replay(sessionId!);
  expect(replayResult.failure, isNull);
  final replay = replayResult.replay!;
  expect(replay.source, TelemetrySource.simulatedRig);
  expect(replay.transport, expectedTransport.name);
  expect(replay.valueCount, read.valueCount);
  expect(replay.statusCount, read.statusCount);
  expect(replay.gapCount, read.gapCount);
  expect(replay.terminalReason, expectedTerminalReason);
  expect(replay.lanes, isNotEmpty);

  final shareRoot = Directory(
    '${(await getApplicationCacheDirectory()).path}/telemetry-rig-share',
  );
  if (await shareRoot.exists()) await shareRoot.delete(recursive: true);
  addTearDown(() async {
    if (await shareRoot.exists()) await shareRoot.delete(recursive: true);
  });
  final platform = _CapturingRigSharePlatform();
  final policy = _PermittingRigSharePolicy();
  var shareSequence = 0;
  final gate = container.read(artifactOperationGateProvider);
  final coordinator = AppShareCoordinator(
    rootDirectory: () async => shareRoot,
    policy: policy,
    artifactGate: gate,
    platform: platform,
    idSource: () => (++shareSequence).toRadixString(16).padLeft(32, '0'),
    nowUtc: () => DateTime.now().toUtc(),
    availableBytes: (_) async => 64 * 1024 * 1024,
  );
  expect(await coordinator.initialize(), AppShareInitializationOutcome.ready);
  final store = container.read(telemetrySessionStoreProvider);
  final actions = TelemetrySessionActions(
    documentsDirectory: () async => documents,
    store: store,
    shareCoordinator: coordinator,
    artifactGate: gate,
    sharePolicy: policy,
    readRecorderPhase: () => controller.state.phase,
  );
  expect(
    (await actions.export(sessionId, TelemetryExportFormat.csv)).isSuccess,
    isTrue,
  );
  expect(
    (await actions.export(sessionId, TelemetryExportFormat.json)).isSuccess,
    isTrue,
  );
  final csv = utf8.decode(platform.byExtension['csv']!);
  final jsonText = utf8.decode(platform.byExtension['json']!);
  final decoded = jsonDecode(jsonText) as Map<String, dynamic>;
  final footer = decoded['footer'] as Map<String, dynamic>;
  expect(csv, contains('# source=simulatedRig'));
  expect(csv, contains('# transport=${expectedTransport.name}'));
  expect(csv, contains('# terminal_reason=${expectedTerminalReason.name}'));
  expect(csv, contains('# value_count=${read.valueCount}'));
  expect(csv, contains('# status_count=${read.statusCount}'));
  expect(csv, contains('# gap_count=${read.gapCount}'));
  expect(decoded['privacyExclusions'], containsAll(_privacyExclusions));
  expect(footer['terminalReason'], expectedTerminalReason.name);
  expect(footer['valueCount'], read.valueCount);
  expect(footer['statusCount'], read.statusCount);
  expect(footer['gapCount'], read.gapCount);
  final payload = jsonEncode({
    'header': decoded['header'],
    'events': decoded['events'],
    'footer': decoded['footer'],
  });
  final csvPayload = csv
      .split('\r\n')
      .where((line) => line.isNotEmpty && !line.startsWith('#'))
      .join('\r\n');
  for (final forbidden in _privacyExclusions) {
    expect(csvPayload, isNot(contains(forbidden)));
    expect(payload, isNot(contains('"$forbidden"')));
  }

  expect((await actions.delete(sessionId, confirmed: true)).isSuccess, isTrue);
  container.invalidate(telemetrySessionLibraryProvider);
  final refreshed = await container.read(
    telemetrySessionLibraryProvider.future,
  );
  final quota = await store.scanQuota();
  expect(refreshed.sessions, isEmpty);
  expect(refreshed.damaged, isEmpty);
  expect(quota.groupCount, 0);
  expect(quota.recognizedBytes, 0);
  expect(await file.exists(), isFalse);

  return TelemetryRigJourneyEvidence(
    sessionId: sessionId,
    terminalReason: expectedTerminalReason,
    valueCount: read.valueCount,
    statusCount: read.statusCount,
    gapCount: read.gapCount,
  );
}

const _privacyExclusions = <String>[
  'VIN',
  'GPS',
  'account',
  'fullVehicleProfile',
  'adapterAddress',
  'rawDiagnosticTraffic',
];

final class _CapturingRigSharePlatform implements AppSharePlatform {
  final Map<String, List<int>> byExtension = <String, List<int>>{};

  @override
  Future<AppShareResult> share(AppSharePlatformRequest request) async {
    byExtension[request.fileName.split('.').last] = await File(request.path)
        .readAsBytes();
    return AppShareResult.selected;
  }
}

final class _PermittingRigSharePolicy implements AppSharePolicy {
  @override
  SharePreparationPermit? freeze() => const SharePreparationPermit(
    recorderEpoch: 1,
    foregroundEpoch: 1,
    connectionEpoch: 1,
    safetyEpoch: 1,
    connectionClass: ShareConnectionClass.connected,
  );

  @override
  SharePermitValidation validate(SharePreparationPermit permit) =>
      const SharePermitValidation.valid();
}

void pauseApp(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
}

void resumeApp(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

Future<StoredTranscript?> waitForStoredTranscript(
  WidgetTester tester,
  bool Function(StoredTranscript value) predicate,
) => pumpUntilValue<StoredTranscript>(tester, () async {
  final value = await TranscriptStore().load();
  return value != null && predicate(value) ? value : null;
});

/// Rig-only policy: identity is already gated to the isolated Android package.
final class _RigDestructivePolicy implements AppSharePolicy {
  const _RigDestructivePolicy();

  @override
  SharePreparationPermit? freeze() => const SharePreparationPermit(
    recorderEpoch: 1,
    foregroundEpoch: 1,
    connectionEpoch: 1,
    safetyEpoch: 1,
    connectionClass: ShareConnectionClass.disconnected,
  );

  @override
  SharePermitValidation validate(SharePreparationPermit permit) =>
      const SharePermitValidation.valid();
}
