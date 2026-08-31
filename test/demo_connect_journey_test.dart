/// Demo transport functional coverage for multiplatform CI.
///
/// Two seams, deliberately separate:
/// 1. Real `connectDemo` under a [ProviderContainer] (real async timers) —
///    proves the Demo ECU path works without a physical adapter.
/// 2. Connect-screen UI → dashboard navigation with a fast session mock —
///    proves the Demo card wires into `_connect` and navigates on success.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/obd/telemetry.dart';
import 'package:torque_obd/obd/transport/ble_transport.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_registry.dart';
import 'package:torque_obd/ui/screens/connect/connect_screen.dart';
import 'package:torque_obd/ui/screens/dashboard/dashboard_screen.dart';

class _FastDemoSession extends ObdSession {
  int demoAttempts = 0;

  @override
  ObdConnectionState build() => const ObdConnectionState();

  @override
  Future<bool> connectDemo() async {
    demoAttempts += 1;
    state = const ObdConnectionState(
      phase: ConnectionPhase.connected,
      kind: TransportKind.demo,
      deviceName: 'Demo ECU',
    );
    return true;
  }

  @override
  Future<bool> connectWifi({String? host, int? port}) async => false;

  @override
  Future<bool> connectClassic(DiscoveredDevice device) async => false;

  @override
  Future<bool> connectBle(BleAdapterHandle device) async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('real connectDemo reaches connected and publishes telemetry', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    final session = container.read(obdSessionProvider.notifier);
    expect(await session.connectDemo(), isTrue);
    expect(container.read(obdSessionProvider).phase, ConnectionPhase.connected);
    expect(container.read(obdSessionProvider).kind, TransportKind.demo);

    TelemetrySnapshot? snap;
    final sub = container.listen(
      telemetryProvider,
      (_, next) => snap = next.value,
      fireImmediately: true,
    );
    addTearDown(sub.close);

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (snap == null || snap!.readings.isEmpty) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Demo session produced no telemetry values within 10s');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    await session.disconnect();
    expect(
      container.read(obdSessionProvider).phase,
      isNot(ConnectionPhase.connected),
    );
  });

  testWidgets('Demo card navigates to the dashboard on success', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    late _FastDemoSession session;
    final router = GoRouter(
      routes: [
        GoRoute(
          path: ConnectScreen.path,
          builder: (_, _) => const ConnectScreen(),
        ),
        GoRoute(
          path: DashboardScreen.path,
          builder: (_, _) => const Scaffold(body: Text('dashboard reached')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          obdSessionProvider.overrideWith(() => session = _FastDemoSession()),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // Expand Demo without depending on scroll hit-testing for the start button.
    final demoCard = find.text(TransportKind.demo.label).last;
    await tester.ensureVisible(demoCard);
    await tester.tap(demoCard, warnIfMissed: false);
    await tester.pumpAndSettle();

    final start = find.widgetWithText(FilledButton, '啟動模擬器');
    expect(start, findsOneWidget);
    tester.widget<FilledButton>(start).onPressed!();
    await tester.pumpAndSettle();

    expect(session.demoAttempts, 1);
    expect(find.text('dashboard reached'), findsOneWidget);
  });
}
