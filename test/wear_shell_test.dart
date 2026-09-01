/// The wear shell on a wrist-sized surface.
///
/// Pumped at 227×227 logical pixels — a 454px round face at 2.0 DPR — so the
/// layout assertions run against the geometry the shell actually ships to.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/core/theme/app_theme.dart';
import 'package:torque_obd/obd/telemetry.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_registry.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/state/powertrain_battery_profiles.dart';
import 'package:torque_obd/ui/wear/wear_shell.dart';
import 'package:torque_obd/ui/widgets/gauges/dial_gauge.dart';

import 'support/powertrain_snapshot_fixture.dart';

final class _FixedSession extends ObdSession {
  _FixedSession(this.fixed);

  final ObdConnectionState fixed;

  /// Overridable so a test can flip the connection identity while a
  /// confirmation dialog sits open.
  int fakeGeneration = 0;

  @override
  int get connectionGeneration => fakeGeneration;

  @override
  ObdConnectionState build() => fixed;

  /// Publishes a new connection state mid-test, e.g. a real disconnect
  /// while a dialog sits open.
  void publish(ObdConnectionState next) {
    state = next;
  }
}

Map<String, Object?> _wearProfileJson(String id, {double socScale = 10}) => {
  'id': id,
  'display_name': 'Profile $id',
  'description': 'Installable community fixture.',
  'limitations': ['fixture'],
  'status': 'community',
  'evidence': 'sourceBacked',
  'market': 'Australia',
  'make': 'MG',
  'model': 'ZS EV',
  'year_from': 2021,
  'year_to': 2021,
  'variant': 'Mk1',
  'powertrain': 'BEV',
  'identity_evidence': {
    'market': 'exact',
    'year': 'exact',
    'model': 'exact',
    'variant': 'exact',
  },
  'source': {
    'name': 'primary-$id',
    'url': 'https://example.invalid/$id',
    'revision': 'a' * 40,
    'license': 'Apache-2.0',
    'path': '$id.csv',
    'locator': '22B046',
    'artifact_sha256': 'b' * 64,
  },
  'secondary_sources': [
    {
      'name': 'independent-$id',
      'url': 'https://example.invalid/other-$id',
      'revision': 'c' * 40,
      'license': 'MIT',
      'path': 'poller.cpp',
      'locator': 'poll table',
      'artifact_sha256': 'd' * 64,
    },
  ],
  'commands': [
    {
      'request_header': '781',
      'expected_responder': '789',
      'mode': '22',
      'identifier': 'B046',
      'payload_length': 2,
      'signals': [
        {
          'id': 'soc_display',
          'name': 'Displayed state of charge',
          'offset': 0,
          'width': 2,
          'equation': '(A*256+B)/$socScale',
          'unit': '%',
          'min_value': 0,
          'max_value': 100,
          'semantic_kind': 'stateOfCharge',
          'recommended': true,
        },
      ],
    },
  ],
};

Future<ProviderContainer> _pumpWear(
  WidgetTester tester, {
  required bool connected,
  TelemetrySnapshot snapshot = const TelemetrySnapshot(),
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      obdSessionProvider.overrideWith(
        () => _FixedSession(
          connected
              ? const ObdConnectionState(
                  phase: ConnectionPhase.connected,
                  kind: TransportKind.demo,
                  deviceName: 'Demo ECU',
                  protocol: 'ISO 15765-4 CAN 11/500',
                )
              : const ObdConnectionState(),
        ),
      ),
      telemetryProvider.overrideWith((ref) => Stream.value(snapshot)),
    ],
  );
  tester.view.physicalSize = const Size(454, 454);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.dark(), home: const WearShell()),
    ),
  );
  await tester.pump(const Duration(milliseconds: 400));
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('disconnected: Demo and BLE are the only offers', (tester) async {
    final container = await _pumpWear(tester, connected: false);
    addTearDown(container.dispose);

    expect(find.byKey(const Key('wear_connect_demo')), findsOneWidget);
    expect(find.byKey(const Key('wear_scan_ble')), findsOneWidget);
    // No Classic, no Wi-Fi: a watch cannot open RFCOMM, and lying about it
    // with a dead button would be worse than the smaller list.
    expect(find.textContaining('Classic'), findsNothing);
    expect(find.textContaining('Wi-Fi'), findsNothing);
  });

  testWidgets('connected: the dial page shows and taps cycle the reading', (
    tester,
  ) async {
    final container = await _pumpWear(tester, connected: true);
    addTearDown(container.dispose);

    expect(find.byKey(const Key('wear_dial')), findsOneWidget);
    // The dial paints its label; assert on the widget contract instead of
    // rendered text.
    DialGauge gauge() => tester.widget<DialGauge>(find.byType(DialGauge));
    expect(gauge().label, 'Speed');

    await tester.tap(find.byKey(const Key('wear_dial')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(gauge().label, 'RPM');

    await tester.tap(find.byKey(const Key('wear_dial')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(gauge().label, 'Coolant');
  });

  testWidgets('long-press asks before disconnecting', (tester) async {
    final container = await _pumpWear(tester, connected: true);
    addTearDown(container.dispose);

    await tester.longPress(find.byKey(const Key('wear_dial')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('wear_disconnect_confirm')), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wear_disconnect_confirm')), findsNothing);
  });

  testWidgets('no battery page without installed profile signals', (
    tester,
  ) async {
    final container = await _pumpWear(tester, connected: true);
    addTearDown(container.dispose);

    // Swiping past the dial lands on the numbers page, not a battery page.
    await tester.fling(
      find.byKey(const Key('wear_dial')),
      const Offset(-200, 0),
      1000,
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const Key('wear_battery_soc')), findsNothing);
    expect(find.text('Coolant'), findsOneWidget);
    expect(find.text('IAT'), findsOneWidget);
  });
  testWidgets('a stale reading dims instead of glowing its last number', (
    tester,
  ) async {
    final old = DateTime.now().subtract(const Duration(minutes: 5));
    final container = await _pumpWear(
      tester,
      connected: true,
      snapshot: TelemetrySnapshot(
        readings: {
          PidLibrary.vehicleSpeed.id: Reading(
            pid: PidLibrary.vehicleSpeed,
            value: 88,
            rawBytes: const [0x58],
            timestamp: old,
          ),
        },
      ),
    );
    addTearDown(container.dispose);

    final gauge = tester.widget<DialGauge>(find.byType(DialGauge));
    expect(gauge.value, isNull,
        reason: 'a reading that stopped updating is no reading');
    expect(gauge.isStale, isTrue);
  });

  testWidgets('simulated data carries a permanent DEMO badge', (tester) async {
    final container = await _pumpWear(tester, connected: true);
    addTearDown(container.dispose);
    expect(find.byKey(const Key('wear_demo_badge')), findsOneWidget);
  });

  testWidgets('battery page confirms one owner and shows only its signals', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    // Two installed profiles with the same signal id but different scales:
    // if the page ever mixes owners, the number changes and this fails.
    final catalogSnapshot = snapshotOfProfiles([
      _wearProfileJson('aa-first'),
      _wearProfileJson('zz-second', socScale: 20),
    ]);
    // The readings need pid ids that only exist after install, so the stream
    // is a controller fed later rather than a value known now.
    final telemetryController = StreamController<TelemetrySnapshot>.broadcast();
    addTearDown(telemetryController.close);
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        obdSessionProvider.overrideWith(
          () => _FixedSession(
            const ObdConnectionState(
              phase: ConnectionPhase.connected,
              kind: TransportKind.demo,
              deviceName: 'Demo ECU',
              protocol: 'ISO 15765-4 CAN 11/500',
            ),
          ),
        ),
        powertrainBatteryCatalogLoaderProvider.overrideWithValue(
          () async => catalogSnapshot,
        ),
        telemetryProvider.overrideWith((ref) => telemetryController.stream),
      ],
    );
    addTearDown(container.dispose);
    final registry = container.read(pidRegistryProvider.notifier);
    // zz-second installs FIRST, so its pid precedes aa-first's in the
    // unfiltered registry list. An implementation that names aa-first as
    // owner but looks signals up in the whole list finds zz-second's 99
    // and fails below; only owner-scoped lookup yields aa-first's 50.
    await registry.installPowertrainProfile(
      catalogSnapshot,
      'zz-second',
      vehicleYear: 2021,
    );
    await registry.installPowertrainProfile(
      catalogSnapshot,
      'aa-first',
      vehicleYear: 2021,
    );
    final firstPid = registry.profilePids
        .singleWhere((pid) => pid.ownerProfileId == 'aa-first');
    final secondPid = registry.profilePids
        .singleWhere((pid) => pid.ownerProfileId == 'zz-second');

    final now = DateTime.now();
    final telemetry = TelemetrySnapshot(
      readings: {
        firstPid.id: Reading(
          pid: firstPid,
          value: 50,
          rawBytes: const [0x01, 0xF4],
          timestamp: now,
        ),
        secondPid.id: Reading(
          pid: secondPid,
          value: 99,
          rawBytes: const [0x07, 0xBC],
          timestamp: now,
        ),
      },
    );

    tester.view.physicalSize = const Size(454, 454);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.dark(), home: const WearShell()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    telemetryController.add(telemetry);
    await tester.pump(const Duration(milliseconds: 100));

    // Swipe to the battery page and let the page snap finish — a tap
    // during the transition lands on the scroll surface, not the button.
    await tester.fling(
      find.byKey(const Key('wear_dial')),
      const Offset(-200, 0),
      1000,
    );
    await tester.pumpAndSettle();

    // Unconfirmed: the page names the first (sorted) owner and asks.
    expect(find.byKey(const Key('wear_confirm_vehicle')), findsOneWidget);
    expect(find.text('Profile aa-first'), findsOneWidget);

    await tester.tap(find.byKey(const Key('wear_confirm_vehicle')));
    await tester.pumpAndSettle();
    // The dialog carries the full identity, not an abbreviation of it.
    expect(
      find.byKey(const Key('wear_confirm_vehicle_identity')),
      findsOneWidget,
    );
    expect(find.textContaining('2021 MG ZS EV'), findsOneWidget);
    expect(find.textContaining('Mk1 · Australia'), findsOneWidget);
    // The consequence sentence is part of the consent, not decoration.
    expect(find.textContaining('看似合理但錯誤'), findsOneWidget);

    await tester.tap(find.byKey(const Key('wear_confirm_vehicle_accept')));
    await tester.pumpAndSettle();

    // Confirmed: only the confirmed owner's reading may appear — 50.0 from
    // aa-first, never 99.0 from the unconfirmed zz-second.
    expect(find.byKey(const Key('wear_battery_soc')), findsOneWidget);
    expect(find.text('50.0'), findsOneWidget);
    expect(find.text('99.0'), findsNothing);
  });

  testWidgets(
    'a connection that changes under the wear confirm dialog grants nothing',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final catalogSnapshot = snapshotOfProfiles([
        _wearProfileJson('aa-first'),
      ]);
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          obdSessionProvider.overrideWith(
            () => _FixedSession(
              const ObdConnectionState(
                phase: ConnectionPhase.connected,
                kind: TransportKind.demo,
                deviceName: 'Demo ECU',
                protocol: 'ISO 15765-4 CAN 11/500',
              ),
            ),
          ),
          powertrainBatteryCatalogLoaderProvider.overrideWithValue(
            () async => catalogSnapshot,
          ),
          telemetryProvider.overrideWith(
            (ref) => Stream.value(const TelemetrySnapshot()),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(pidRegistryProvider.notifier).installPowertrainProfile(
            catalogSnapshot,
            'aa-first',
            vehicleYear: 2021,
          );

      tester.view.physicalSize = const Size(454, 454);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: AppTheme.dark(), home: const WearShell()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      await tester.fling(
        find.byKey(const Key('wear_dial')),
        const Offset(-200, 0),
        1000,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wear_confirm_vehicle')));
      await tester.pumpAndSettle();

      final session =
          container.read(obdSessionProvider.notifier) as _FixedSession;
      session.fakeGeneration = 99;
      await tester.tap(find.byKey(const Key('wear_confirm_vehicle_accept')));
      await tester.pumpAndSettle();

      expect(container.read(powertrainProfileAuthorizationsProvider), isEmpty);
    },
  );
  testWidgets('a real BLE connection carries no DEMO badge', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        obdSessionProvider.overrideWith(
          () => _FixedSession(
            const ObdConnectionState(
              phase: ConnectionPhase.connected,
              kind: TransportKind.bluetoothLe,
              deviceName: 'OBDLink CX',
              protocol: 'ISO 15765-4 CAN 11/500',
            ),
          ),
        ),
        telemetryProvider.overrideWith(
          (ref) => Stream.value(const TelemetrySnapshot()),
        ),
      ],
    );
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(454, 454);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.dark(), home: const WearShell()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('wear_demo_badge')), findsNothing);
  });

  testWidgets(
    'a disconnect that unmounts the battery page under its open dialog '
    'declines quietly instead of throwing',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final catalogSnapshot = snapshotOfProfiles([
        _wearProfileJson('aa-first'),
      ]);
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          obdSessionProvider.overrideWith(
            () => _FixedSession(
              const ObdConnectionState(
                phase: ConnectionPhase.connected,
                kind: TransportKind.demo,
                deviceName: 'Demo ECU',
                protocol: 'ISO 15765-4 CAN 11/500',
              ),
            ),
          ),
          powertrainBatteryCatalogLoaderProvider.overrideWithValue(
            () async => catalogSnapshot,
          ),
          telemetryProvider.overrideWith(
            (ref) => Stream.value(const TelemetrySnapshot()),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container
          .read(pidRegistryProvider.notifier)
          .installPowertrainProfile(
            catalogSnapshot,
            'aa-first',
            vehicleYear: 2021,
          );

      tester.view.physicalSize = const Size(454, 454);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: AppTheme.dark(), home: const WearShell()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      await tester.fling(
        find.byKey(const Key('wear_dial')),
        const Offset(-200, 0),
        1000,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wear_confirm_vehicle')));
      await tester.pumpAndSettle();

      // The connection drops for real: the shell swaps back to the connect
      // page and the battery page unmounts, but the dialog rides the root
      // navigator and stays up.
      final session =
          container.read(obdSessionProvider.notifier) as _FixedSession;
      session.publish(const ObdConnectionState());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('wear_battery_soc')), findsNothing);
      expect(
        find.byKey(const Key('wear_confirm_vehicle_accept')),
        findsOneWidget,
      );

      // Accepting now must decline quietly — an unmounted element whose ref
      // is still touched would throw here and fail this test.
      await tester.tap(find.byKey(const Key('wear_confirm_vehicle_accept')));
      await tester.pumpAndSettle();
      expect(container.read(powertrainProfileAuthorizationsProvider), isEmpty);
    },
  );
}

