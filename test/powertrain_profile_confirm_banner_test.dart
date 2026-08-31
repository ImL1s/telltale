import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/core/theme/app_theme.dart';
import 'package:torque_obd/obd/powertrain_battery/powertrain_battery_catalog.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_registry.dart';
import 'package:torque_obd/state/powertrain_battery_profiles.dart';
import 'package:torque_obd/ui/widgets/powertrain_profile_confirm_banner.dart';

import 'support/powertrain_snapshot_fixture.dart';

const _profileId = 'banner-profile';

Map<String, Object?> _profileJson({String revision = ''}) => {
  'id': _profileId,
  'display_name': 'Banner profile',
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
    'name': 'primary',
    'url': 'https://example.invalid/source',
    'revision': revision.isEmpty ? 'a' * 40 : revision,
    'license': 'Apache-2.0',
    'path': 'profile.csv',
    'locator': '22B046',
    'artifact_sha256': 'b' * 64,
  },
  'secondary_sources': [
    {
      'name': 'independent',
      'url': 'https://example.invalid/other',
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
          'id': 'raw-soc',
          'name': 'SOC',
          'offset': 0,
          'width': 2,
          'equation': '(A*256+B)/10',
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

final class _ConnectedObdSession extends ObdSession {
  /// Overridable so a test can flip the connection identity while a
  /// confirmation dialog sits open.
  int fakeGeneration = 0;

  @override
  int get connectionGeneration => fakeGeneration;

  @override
  ObdConnectionState build() => const ObdConnectionState(
    phase: ConnectionPhase.connected,
    kind: TransportKind.demo,
    deviceName: 'Test rig',
    protocol: 'ISO 15765-4 CAN 11/500',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(ProviderContainer, PowertrainBatteryCatalogSnapshot)> pumpBanner(
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final snapshot = snapshotOfProfiles([_profileJson()]);
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        obdSessionProvider.overrideWith(_ConnectedObdSession.new),
        powertrainBatteryCatalogLoaderProvider.overrideWithValue(
          () async => snapshot,
        ),
      ],
    );
    await container
        .read(pidRegistryProvider.notifier)
        .installPowertrainProfile(snapshot, _profileId, vehicleYear: 2021);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(body: PowertrainProfileConfirmBanner()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (container, snapshot);
  }

  testWidgets('an installed profile without a grant asks for confirmation', (
    tester,
  ) async {
    final (container, _) = await pumpBanner(tester);
    addTearDown(container.dispose);

    expect(
      find.byKey(const Key('powertrain_profile_confirm_banner')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('powertrain_confirm_connection_banner-profile')),
      findsOneWidget,
    );
    expect(find.text('Banner profile · 2021'), findsOneWidget);
  });

  testWidgets('a stale-generation grant still asks for confirmation', (
    tester,
  ) async {
    final (container, snapshot) = await pumpBanner(tester);
    addTearDown(container.dispose);

    // A grant from some other connection generation. The polling filter
    // already refuses it; the banner must offer re-confirmation instead of
    // hiding the row and leaving dark gauges.
    container
        .read(powertrainProfileAuthorizationsProvider.notifier)
        .authorize(
          snapshot: snapshot,
          profileId: _profileId,
          vehicleYear: 2021,
          connectionGeneration: 7,
        );
    await tester.pump();

    expect(
      find.byKey(const Key('powertrain_confirm_connection_banner-profile')),
      findsOneWidget,
    );
  });

  testWidgets('a stale-revision grant still asks for confirmation', (
    tester,
  ) async {
    final (container, _) = await pumpBanner(tester);
    addTearDown(container.dispose);

    // Same generation, but the grant was issued against a different catalog
    // revision of this profile — the polling filter refuses such a grant, so
    // the banner must ask again rather than hide the row over dark gauges.
    final generation = container
        .read(obdSessionProvider.notifier)
        .connectionGeneration;
    final rehashed = snapshotOfProfiles([_profileJson(revision: 'e' * 40)]);
    container
        .read(powertrainProfileAuthorizationsProvider.notifier)
        .authorize(
          snapshot: rehashed,
          profileId: _profileId,
          vehicleYear: 2021,
          connectionGeneration: generation,
        );
    await tester.pump();

    expect(
      find.byKey(const Key('powertrain_confirm_connection_banner-profile')),
      findsOneWidget,
    );
  });

  testWidgets(
    'a connection that changes under the open dialog is not authorized',
    (tester) async {
      final (container, _) = await pumpBanner(tester);
      addTearDown(container.dispose);

      await tester.tap(
        find.byKey(const Key('powertrain_confirm_connection_banner-profile')),
      );
      await tester.pumpAndSettle();

      // While the driver reads the dialog, the connection becomes a
      // different one — possibly a different car. Accepting now must grant
      // nothing: the statement was about the vehicle at prompt time.
      final session =
          container.read(obdSessionProvider.notifier) as _ConnectedObdSession;
      session.fakeGeneration = 99;
      await tester.tap(
        find.byKey(const Key('powertrain_confirm_connection_accept')),
      );
      await tester.pumpAndSettle();

      expect(container.read(powertrainProfileAuthorizationsProvider), isEmpty);
      expect(find.textContaining('連線已改變'), findsOneWidget);
    },
  );

  testWidgets('a live grant hides the banner', (tester) async {
    final (container, snapshot) = await pumpBanner(tester);
    addTearDown(container.dispose);

    final generation = container
        .read(obdSessionProvider.notifier)
        .connectionGeneration;
    container
        .read(powertrainProfileAuthorizationsProvider.notifier)
        .authorize(
          snapshot: snapshot,
          profileId: _profileId,
          vehicleYear: 2021,
          connectionGeneration: generation,
        );
    await tester.pump();

    expect(
      find.byKey(const Key('powertrain_profile_confirm_banner')),
      findsNothing,
    );
  });
}
