/// Navigation from the remembered-adapter shortcut.
///
/// A reconnect can establish a real session and start polling while leaving
/// the driver on the connection wizard. The normal transport cards all route
/// through `_connect`, but the shortcut had its own path and discarded the
/// returned success value. These tests cross that UI/state/navigation seam.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/obd/transport/ble_transport.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_registry.dart';
import 'package:torque_obd/state/settings.dart';
import 'package:torque_obd/ui/screens/connect/connect_screen.dart';
import 'package:torque_obd/ui/screens/dashboard/dashboard_screen.dart';

class _ReconnectSession extends ObdSession {
  _ReconnectSession(this.succeeds);

  final bool succeeds;
  TransportKind? attemptedKind;
  String? attemptedId;
  int? attemptedPort;

  @override
  ObdConnectionState build() => const ObdConnectionState();

  Future<bool> _complete(TransportKind kind, String id, [int? port]) async {
    attemptedKind = kind;
    attemptedId = id;
    attemptedPort = port;
    if (succeeds) {
      state = ObdConnectionState(
        phase: ConnectionPhase.connected,
        kind: kind,
        deviceName: id,
      );
    }
    return succeeds;
  }

  @override
  Future<bool> connectWifi({String? host, int? port}) =>
      _complete(TransportKind.wifi, host ?? '', port);

  @override
  Future<bool> connectClassic(DiscoveredDevice device) =>
      _complete(TransportKind.bluetoothClassic, device.id);

  @override
  Future<bool> connectBle(BleAdapterHandle device) =>
      _complete(TransportKind.bluetoothLe, device.id);

  @override
  Future<bool> connectDemo() => _complete(TransportKind.demo, 'demo');
}

Future<_ReconnectSession> _pumpShortcut(
  WidgetTester tester, {
  required LastAdapter adapter,
  required bool succeeds,
}) async {
  SharedPreferences.setMockInitialValues({'last_adapter_v1': adapter.encode()});
  final prefs = await SharedPreferences.getInstance();
  late _ReconnectSession session;
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
        obdSessionProvider.overrideWith(
          () => session = _ReconnectSession(succeeds),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.text('直接連線'), findsOneWidget);
  return session;
}

void main() {
  const reconnectable = <LastAdapter>[
    LastAdapter(
      id: '192.168.1.135',
      name: 'Wi-Fi 192.168.1.135',
      kind: TransportKind.wifi,
      port: 35000,
    ),
    LastAdapter(
      id: '00:11:22:33:44:55',
      name: 'OBDII',
      kind: TransportKind.bluetoothClassic,
    ),
    LastAdapter(
      id: 'AA:BB:CC:DD:EE:FF',
      name: 'V-LINK',
      kind: TransportKind.bluetoothLe,
    ),
  ];

  for (final adapter in reconnectable) {
    testWidgets('${adapter.kind.name} success opens the dashboard', (
      tester,
    ) async {
      final session = await _pumpShortcut(
        tester,
        adapter: adapter,
        succeeds: true,
      );

      await tester.tap(find.text('直接連線'));
      await tester.pumpAndSettle();

      expect(find.text('dashboard reached'), findsOneWidget);
      expect(session.attemptedKind, adapter.kind);
      expect(session.attemptedId, adapter.id);
      expect(session.attemptedPort, adapter.port);
    });
  }

  testWidgets('failed reconnect stays on the connection wizard', (
    tester,
  ) async {
    final session = await _pumpShortcut(
      tester,
      adapter: reconnectable.first,
      succeeds: false,
    );

    await tester.tap(find.text('直接連線'));
    await tester.pumpAndSettle();

    expect(find.text('dashboard reached'), findsNothing);
    expect(find.text('直接連線'), findsOneWidget);
    expect(session.attemptedKind, TransportKind.wifi);
  });

  testWidgets('a remembered demo entry neither reconnects nor navigates', (
    tester,
  ) async {
    final session = await _pumpShortcut(
      tester,
      adapter: const LastAdapter(
        id: 'demo',
        name: 'Demo ECU',
        kind: TransportKind.demo,
      ),
      succeeds: true,
    );

    await tester.tap(find.text('直接連線'));
    await tester.pumpAndSettle();

    expect(find.text('dashboard reached'), findsNothing);
    expect(find.text('直接連線'), findsOneWidget);
    expect(session.attemptedKind, isNull);
  });
}
