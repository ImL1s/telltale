/// Android lifecycle/process-kill telemetry target for
/// `tool/telemetry_lifecycle_rig/run.sh`.
///
/// The shell wrapper performs the real Home and force-stop actions. This Dart
/// target prints a marker only after a value is durably accepted, then checks
/// the artifact from a separate fresh process. It is Demo-only evidence: no
/// socket, radio, adapter, ECU, or vehicle is involved.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:torque_obd/state/telemetry_recorder.dart';
import 'package:torque_obd/state/telemetry_sessions.dart';
import 'package:torque_obd/telemetry/session/telemetry_recorder.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_reader.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_store.dart';

import 'rig_support.dart';

const _phase = String.fromEnvironment('TELEMETRY_LIFECYCLE_PHASE');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('actual Android lifecycle telemetry target: $_phase', (
    tester,
  ) async {
    expect(
      const {'home', 'force_stop_seed', 'recover'},
      contains(_phase),
      reason:
          'set TELEMETRY_LIFECYCLE_PHASE to home, force_stop_seed, or recover',
    );
    switch (_phase) {
      case 'home':
        await _homeTarget(tester);
      case 'force_stop_seed':
        await _forceStopSeedTarget(tester);
      case 'recover':
        await _recoveryTarget(tester);
    }
  });
}

Future<void> _homeTarget(WidgetTester tester) async {
  await startCleanRigApp(tester);
  await connectDemoRig(tester);
  final controller = await _startRecording(tester);
  debugPrint('TELLTALE_LIFECYCLE_READY_HOME');

  final hidden = await pumpUntil(
    tester,
    () => WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed,
    timeout: const Duration(seconds: 45),
  );
  expect(hidden, isTrue, reason: 'wrapper did not send a real Android Home');
  final completed = await pumpUntil(
    tester,
    () => controller.state.phase == TelemetryRecorderPhase.completed,
    timeout: const Duration(seconds: 30),
  );
  expect(completed, isTrue, reason: 'background did not finalize recording');
  expect(controller.state.terminalReason, TelemetryTerminalReason.background);
  final artifact = await _singleTelemetryArtifact(extension: '.ndjson');
  final result = await const TelemetrySessionReader().read(
    FileTelemetryChunkSource(artifact),
  );
  expect(result.isValid, isTrue);
  expect(result.footerSeen, isTrue);
  expect(result.valueCount, greaterThan(0));
  expect(result.sessionHeader?.source, TelemetrySource.demo);
  expect(
    result.sessionFooter?.terminalReason,
    TelemetryTerminalReason.background,
  );
  expect(
    RegExp('"type":"footer"').allMatches(await artifact.readAsString()),
    hasLength(1),
  );
  debugPrint(
    'TELLTALE_LIFECYCLE_HOME_STORED '
    'values=${result.valueCount} statuses=${result.statusCount} '
    'gaps=${result.gapCount}',
  );
}

Future<void> _forceStopSeedTarget(WidgetTester tester) async {
  await startCleanRigApp(tester);
  await connectDemoRig(tester);
  final controller = await _startRecording(tester);
  final id = controller.progress.sessionId;
  expect(id, isNotNull);
  final staging = await _singleTelemetryArtifact(extension: '.ndjson.part');
  TelemetryReadResult? prefix;
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (DateTime.now().isBefore(deadline)) {
    final candidate = await const TelemetrySessionReader().read(
      FileTelemetryChunkSource(staging),
      allowIncompleteTail: true,
    );
    if (candidate.isValid && candidate.valueCount > 0) {
      prefix = candidate;
      break;
    }
    await tester.pump(const Duration(milliseconds: 250));
  }
  expect(
    prefix,
    isNotNull,
    reason: 'writer never flushed a positive-value prefix before force-stop',
  );
  final durablePrefix = prefix!;
  expect(durablePrefix.isValid, isTrue);
  expect(durablePrefix.footerSeen, isFalse);
  expect(durablePrefix.valueCount, greaterThan(0));
  debugPrint(
    'TELLTALE_LIFECYCLE_READY_FORCE_STOP '
    'session=$id values=${durablePrefix.valueCount} '
    'statuses=${durablePrefix.statusCount} gaps=${durablePrefix.gapCount}',
  );

  // The wrapper must terminate this process. Reaching the timeout is a hard
  // failure rather than a passing test that never exercised force-stop.
  final killed = Completer<void>();
  await killed.future.timeout(
    const Duration(minutes: 5),
    onTimeout: () =>
        fail('adb force-stop was not observed within five minutes'),
  );
}

Future<void> _recoveryTarget(WidgetTester tester) async {
  await startRigAppPreservingState(tester);
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
    listen: false,
  );
  final startupReady = await pumpUntil(
    tester,
    () =>
        container.read(telemetryStartupRecoveryProvider).phase ==
        TelemetryStartupRecoveryPhase.ready,
    timeout: const Duration(seconds: 20),
  );
  expect(
    startupReady,
    isTrue,
    reason: 'fresh root did not finish telemetry startup recovery',
  );
  final startupRecovery = container.read(telemetryStartupRecoveryProvider);
  expect(startupRecovery.items, hasLength(1));
  final startupItem = startupRecovery.items.single;
  expect(
    startupItem.outcome,
    TelemetryRecoveryOutcome.recoveredAndInstalled,
    reason: 'fresh root did not retain the interrupted positive-value prefix',
  );

  final root = Directory(
    '${(await getApplicationDocumentsDirectory()).path}/telltale-telemetry',
  );
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  File? recovered;
  while (DateTime.now().isBefore(deadline)) {
    final entities = root.existsSync()
        ? root.listSync(followLinks: false).whereType<File>().toList()
        : const <File>[];
    final finalFiles = entities
        .where((file) => file.path.endsWith('.ndjson'))
        .toList();
    final stagingFiles = entities
        .where((file) => file.path.endsWith('.ndjson.part'))
        .toList();
    if (finalFiles.length == 1 && stagingFiles.isEmpty) {
      recovered = finalFiles.single;
      break;
    }
    await tester.pump(const Duration(milliseconds: 250));
  }
  expect(
    recovered,
    isNotNull,
    reason:
        'fresh app startup did not recover the killed .ndjson.part artifact',
  );
  final result = await const TelemetrySessionReader().read(
    FileTelemetryChunkSource(recovered!),
  );
  expect(result.isValid, isTrue);
  expect(result.footerSeen, isTrue);
  expect(result.valueCount, greaterThan(0));
  expect(result.sessionHeader?.source, TelemetrySource.demo);
  expect(result.sessionHeader?.sessionId, startupItem.id);
  expect(result.valueCount, startupItem.valueCount);
  expect(result.statusCount, startupItem.statusCount);
  expect(result.gapCount, startupItem.gapCount);
  expect(
    result.sessionFooter?.terminalReason,
    TelemetryTerminalReason.recoveredAfterInterruption,
  );
  expect(result.sessionFooter?.valueCount, result.valueCount);
  expect(result.sessionFooter?.statusCount, result.statusCount);
  expect(result.sessionFooter?.gapCount, result.gapCount);
  expect(
    RegExp('"type":"footer"').allMatches(await recovered.readAsString()),
    hasLength(1),
  );

  final recoveryNotice = find.byKey(
    const ValueKey('telemetry-recovery-open-history'),
  );
  expect(
    await pumpUntil(tester, () => recoveryNotice.evaluate().isNotEmpty),
    isTrue,
    reason: 'Connect did not display the retained startup recovery outcome',
  );
  expect(find.text('啟動紀錄檢查已完成'), findsOneWidget);
  expect(find.text('1 組中斷紀錄已完成安全封存'), findsOneWidget);
  await tester.tap(recoveryNotice);
  expect(
    await pumpUntil(tester, () => find.text('本機紀錄').evaluate().isNotEmpty),
    isTrue,
    reason: 'recovery notice did not open root History UI',
  );
  expect(
    await pumpUntil(
      tester,
      () => find
          .textContaining('${result.valueCount} 筆有效值')
          .evaluate()
          .isNotEmpty,
    ),
    isTrue,
    reason: 'History did not render the retained recovered artifact',
  );
  expect(find.textContaining('上次中斷後已復原'), findsOneWidget);
  debugPrint(
    'TELLTALE_LIFECYCLE_RECOVERED '
    'session=${startupItem.id} values=${result.valueCount} '
    'statuses=${result.statusCount} gaps=${result.gapCount} '
    'terminal=recoveredAfterInterruption ui=connect-history',
  );
}

Future<RootTelemetryRecorder> _startRecording(WidgetTester tester) async {
  final start = find.byKey(const ValueKey('telemetry-start'));
  await tester.scrollUntilVisible(
    start,
    250,
    scrollable: find.byType(Scrollable).first,
  );
  expect(start, findsOneWidget);
  await tester.tap(start);
  await tester.pump();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
    listen: false,
  );
  final controller = container.read(telemetryRecorderControllerProvider);
  final recording = await pumpUntil(
    tester,
    () =>
        controller.state.phase == TelemetryRecorderPhase.recording &&
        controller.state.valueCount > 0,
    timeout: const Duration(seconds: 30),
  );
  expect(
    recording,
    isTrue,
    reason: 'Demo recorder never durably accepted a value',
  );
  return controller;
}

Future<File> _singleTelemetryArtifact({required String extension}) async {
  final root = Directory(
    '${(await getApplicationDocumentsDirectory()).path}/telltale-telemetry',
  );
  final files = root
      .listSync(followLinks: false)
      .whereType<File>()
      .where((file) => file.path.endsWith(extension))
      .toList();
  expect(files, hasLength(1));
  return files.single;
}
