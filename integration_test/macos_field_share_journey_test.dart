/// Field-flavor Demo → record → export/share proof on a real macOS host.
///
/// [NSSharingServicePicker] still needs a human target. This journey proves the
/// production path through native capacity, session finalize, and the macOS
/// `app_share` channel with a staged immutable file. The channel is mocked only
/// at the final invoke so the test does not hang on the OS picker.
///
///     flutter test integration_test/macos_field_share_journey_test.dart \
///       -d macos --flavor field
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/main.dart' as app;
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/telemetry_recorder.dart';
import 'package:torque_obd/state/telemetry_sessions.dart';
import 'package:torque_obd/telemetry/session/telemetry_recorder.dart';
import 'package:torque_obd/ui/screens/connect/connect_screen.dart';
import 'package:torque_obd/ui/screens/dashboard/dashboard_screen.dart';

import 'rig_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'macOS field Demo records then stages export through real capacity',
    (tester) async {
      expect(Platform.isMacOS, isTrue);
      expect(kDebugMode, isTrue);

      await _startCleanFieldApp(tester);
      debugPrint('MACOS_FIELD_SHARE phase=app-ready');

      final capacity = await const MethodChannel(
        'com.cbstudio.telltale/app_storage_capacity',
      ).invokeMethod<Object?>('getAvailableBytes');
      expect(capacity, isA<int>());
      expect(capacity as int, greaterThan(0));
      debugPrint('MACOS_FIELD_SHARE phase=capacity-ok bytes=$capacity');

      // Desktop window chrome can leave the Demo card non-hit-testable even
      // when the connect route is up. Drive the same production connectDemo
      // path the card uses once Connect is ready.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
        listen: false,
      );
      final session = container.read(obdSessionProvider.notifier);
      final connected = session.connectDemo();
      expect(
        await pumpUntil(
          tester,
          () =>
              container.read(obdSessionProvider).phase ==
              ConnectionPhase.connected,
          timeout: const Duration(seconds: 30),
          step: const Duration(milliseconds: 25),
        ),
        isTrue,
        reason: 'macOS connectDemo did not reach connected',
      );
      expect(await connected, isTrue);
      final connectScreen = find.byType(ConnectScreen);
      expect(connectScreen, findsOneWidget);
      GoRouter.of(tester.element(connectScreen)).go(DashboardScreen.path);
      await tester.pump();
      await requireDashboard(tester);
      await requireLivePolling(tester);
      debugPrint('MACOS_FIELD_SHARE phase=live-polling');

      await session.disconnect();
      final reconnect = session.connectDemo();
      expect(
        await pumpUntil(
          tester,
          () =>
              container.read(obdSessionProvider).phase ==
              ConnectionPhase.connected,
          timeout: const Duration(seconds: 30),
          step: const Duration(milliseconds: 25),
        ),
        isTrue,
      );
      expect(await reconnect, isTrue);
      await requireLivePolling(tester);

      final start = find.byKey(const ValueKey('telemetry-start'));
      await Scrollable.ensureVisible(tester.element(start), alignment: 0.5);
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        await pumpUntil(
          tester,
          () =>
              start.evaluate().isNotEmpty &&
              tester.widget<FilledButton>(start).onPressed != null,
          timeout: const Duration(seconds: 5),
          step: const Duration(milliseconds: 25),
        ),
        isTrue,
      );
      await tester.tap(start.hitTestable());
      await tester.pump();
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
      );
      debugPrint('MACOS_FIELD_SHARE phase=recording');

      final stop = find.byKey(const ValueKey('telemetry-shell-stop'));
      await tester.tap(stop.hitTestable());
      await tester.pump();
      expect(
        await pumpUntil(
          tester,
          () => controller.state.phase == TelemetryRecorderPhase.completed,
          timeout: const Duration(seconds: 30),
        ),
        isTrue,
      );
      final sessionId = controller.progress.sessionId;
      expect(sessionId, isNotNull);
      debugPrint('MACOS_FIELD_SHARE phase=stopped id=$sessionId');

      await session.disconnect();
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        container.read(obdSessionProvider).phase,
        ConnectionPhase.disconnected,
      );

      final shareCalls = <MethodCall>[];
      String? stagedPath;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('com.cbstudio.telltale/app_share'),
        (call) async {
          shareCalls.add(call);
          final args = Map<Object?, Object?>.from(call.arguments! as Map);
          final path = args['path'] as String?;
          expect(path, isNotNull);
          expect(File(path!).existsSync(), isTrue);
          expect(File(path).lengthSync(), greaterThan(0));
          stagedPath = path;
          return 'selected';
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('com.cbstudio.telltale/app_share'),
          null,
        );
      });

      final export = await container
          .read(telemetrySessionActionsProvider)
          .export(sessionId!, TelemetryExportFormat.csv);
      expect(
        export.isSuccess,
        isTrue,
        reason:
            'export failed: failure=${export.failure} '
            'message=${export.userFacingMessage}',
      );
      expect(shareCalls, hasLength(1));
      expect(shareCalls.single.method, 'shareFile');
      expect(stagedPath, isNotNull);
      expect(File(stagedPath!).existsSync(), isTrue);
      debugPrint('MACOS_FIELD_SHARE phase=handoff-ok path=$stagedPath');
      debugPrint(
        'MACOS_FIELD_SHARE note=NSSharingServicePicker still requires a '
        'human target; staged-file channel handoff is proven above',
      );
      debugPrint('MACOS_FIELD_SHARE phase=pass');
    },
  );
}

Future<void> _startCleanFieldApp(WidgetTester tester) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.clear();
  final docs = await getApplicationDocumentsDirectory();
  final telemetry = Directory('${docs.path}/telltale-telemetry');
  if (await telemetry.exists()) {
    await telemetry.delete(recursive: true);
  }
  // Desktop integration_test often starts inactive/hidden. Share startup and
  // ObdSession both require a resumed edge before Connect is exposed.
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  debugPrint('MACOS_FIELD_SHARE phase=calling-main');
  unawaited(
    app.main().catchError((Object error, StackTrace stack) {
      debugPrint('MACOS_FIELD_SHARE MAIN_ERROR $error\n$stack');
    }),
  );
  final ready = await pumpUntil(
    tester,
    () {
      if (find.text('選擇連線方式').evaluate().isNotEmpty ||
          find.text('Demo 模擬器').evaluate().isNotEmpty) {
        return true;
      }
      final retry = find.text('重試');
      if (retry.evaluate().isNotEmpty) {
        // Keep forcing resumed and retry until share init admits.
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        final hit = retry.hitTestable();
        if (hit.evaluate().isNotEmpty) {
          // Fire-and-forget tap; pumpUntil continues on next iteration.
          tester.tap(hit);
        }
      }
      return false;
    },
    timeout: const Duration(seconds: 60),
    step: const Duration(milliseconds: 200),
  );
  if (!ready) {
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data)
        .whereType<String>()
        .take(40)
        .join(' | ');
    debugPrint('MACOS_FIELD_SHARE phase=ui-dump $texts');
  }
  expect(
    ready,
    isTrue,
    reason: 'macOS field app never reached connect/demo UI',
  );
}
