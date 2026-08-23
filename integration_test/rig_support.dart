import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/main.dart' as app;
import 'package:torque_obd/obd/session_evidence.dart';
import 'package:torque_obd/obd/transcript_store.dart';

/// Starts the isolated `.rig` app from a state that cannot inherit a prior
/// successful connection or transcript.
Future<void> startCleanRigApp(WidgetTester tester) async {
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
  await (await SharedPreferences.getInstance()).clear();
  await TranscriptStore().clear();

  unawaited(app.main());
  final ready = await pumpUntil(
    tester,
    () => find.text('選擇連線方式').evaluate().isNotEmpty,
    timeout: const Duration(seconds: 15),
  );
  expect(ready, isTrue, reason: 'the connection screen did not become ready');
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
  return finder;
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
