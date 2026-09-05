import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/core/theme/app_theme.dart';
import 'package:torque_obd/obd/powertrain_battery/powertrain_battery_catalog.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_mutation_lock.dart';
import 'package:torque_obd/state/pid_registry.dart';
import 'package:torque_obd/state/powertrain_battery_profiles.dart';
import 'package:torque_obd/ui/screens/pids/powertrain_battery_catalog_screen.dart';

const _catalogJson =
    '{"schema_version":3,"profiles":[{"id":"mg-zs-ev","display_name":"MG ZS EV","descriptio'
    'n":"BEV 大電池資料候選","limitations":["尚未由 Telltale 在實車驗證，不能視為已支援。"],"status":"community","e'
    'vidence":"sourceBacked","market":"Synthetic laboratory","make":"MG","model":"ZS EV","y'
    'ear_from":2021,"year_to":2023,"variant":"fixture-v1","powertrain":"BEV","identity_evid'
    'ence":{"market":"exact","year":"exact","model":"exact","variant":"exact"},"source":{"n'
    'ame":"Pinned source","url":"https://github.com/example/source","revision":"aaaaaaaaaaa'
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaa","license":"Apache-2.0","path":"profiles/example.json","'
    'locator":"vehicle/example","artifact_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    'bbbbbbbbbbbbbbbbbbbbbbbb"},"secondary_sources":[{"name":"Independent poller","url":"ht'
    'tps://github.com/example/other","revision":"cccccccccccccccccccccccccccccccccccccccc",'
    '"license":"MIT","path":"src/poller.cpp","locator":"poll table 22B046","artifact_sha256'
    '":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}],"commands":[{"r'
    'equest_header":"781","expected_responder":"789","mode":"22","identifier":"B046","paylo'
    'ad_length":2,"signals":[{"id":"raw-soc","name":"Raw SOC","offset":0,"width":2,"equatio'
    'n":"(A*256+B)/10","unit":"%","min_value":0,"max_value":100,"semantic_kind":"traction_b'
    'attery_soc","recommended":true}]}]},{"id":"ioniq-phev","display_name":"Hyundai Ioniq P'
    'lug-in Hybrid","description":"PHEV 大電池資料候選","limitations":["尚未由 Telltale 在實車驗證，不能視為已支援'
    '。"],"status":"researchOnly","evidence":"sourceBacked","market":"Source-unspecified","m'
    'ake":"Hyundai","model":"Ioniq Plug-in Hybrid","year_from":2021,"year_to":2023,"variant'
    '":"source-unspecified","powertrain":"PHEV","source":{"name":"Pinned source","url":"htt'
    'ps://github.com/example/source","revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",'
    '"license":"Apache-2.0","path":"profiles/example.json","locator":"vehicle/example","art'
    'ifact_sha256":""},"commands":[]},{"id":"prius-hev","display_name":"Toyota Prius","desc'
    'ription":"HEV 大電池資料候選","limitations":["尚未由 Telltale 在實車驗證，不能視為已支援。"],"status":"researc'
    'hOnly","evidence":"sourceBacked","market":"Source-unspecified","make":"Toyota","model"'
    ':"Prius","year_from":2021,"year_to":2023,"variant":"source-unspecified","powertrain":"'
    'HEV","source":{"name":"Pinned source","url":"https://github.com/example/source","revis'
    'ion":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","license":"Apache-2.0","path":"profile'
    's/example.json","locator":"vehicle/example","artifact_sha256":""},"commands":[]},{"id"'
    ':"leaf-bev","display_name":"Nissan Leaf","description":"BEV 大電池資料候選","limitations":["尚'
    '未由 Telltale 在實車驗證，不能視為已支援。"],"status":"researchOnly","evidence":"sourceBacked","market'
    '":"Source-unspecified","make":"Nissan","model":"Leaf","year_from":2021,"year_to":2023,'
    '"variant":"source-unspecified","powertrain":"BEV","source":{"name":"Pinned source","ur'
    'l":"https://github.com/example/source","revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    'aaaaa","license":"Apache-2.0","path":"profiles/example.json","locator":"vehicle/exampl'
    'e","artifact_sha256":""},"commands":[]}]}';

const _manifestJson =
    '{"schema_version":3,"catalog_file":"powertrain_battery_catalog.json","sha256":"08dd58e'
    '4fe2bc18c0da5f6369b282747393e8e30a1cd90d947d0b81776a1bc60","size_bytes":3243,"profile_'
    'count":4,"signal_count":1,"counts_by_powertrain":{"BEV":2,"PHEV":1,"HEV":1}}';

PowertrainBatteryCatalogSnapshot get _snapshot =>
    PowertrainBatteryCatalogAsset.fromStrings(
      manifestJson: _manifestJson,
      catalogJson: _catalogJson,
    );

const _uncorroboratedCatalogJson =
    '{"schema_version":3,"profiles":[{"id":"mg-zs-ev","display_name":"MG ZS EV","descriptio'
    'n":"BEV 大電池資料候選","limitations":["尚未由 Telltale 在實車驗證，不能視為已支援。"],"status":"community","e'
    'vidence":"sourceBacked","market":"Synthetic laboratory","make":"MG","model":"ZS EV","y'
    'ear_from":2021,"year_to":2023,"variant":"fixture-v1","powertrain":"BEV","identity_evid'
    'ence":{"market":"exact","year":"exact","model":"exact","variant":"exact"},"source":{"n'
    'ame":"Pinned source","url":"https://github.com/example/source","revision":"aaaaaaaaaaa'
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaa","license":"Apache-2.0","path":"profiles/example.json","'
    'locator":"vehicle/example","artifact_sha256":""},"commands":[{"request_header":"781","'
    'expected_responder":"789","mode":"22","identifier":"B046","payload_length":2,"signals"'
    ':[{"id":"raw-soc","name":"Raw SOC","offset":0,"width":2,"equation":"(A*256+B)/10","uni'
    't":"%","min_value":0,"max_value":100,"semantic_kind":"traction_battery_soc","recommend'
    'ed":true}]}]},{"id":"ioniq-phev","display_name":"Hyundai Ioniq Plug-in Hybrid","descri'
    'ption":"PHEV 大電池資料候選","limitations":["尚未由 Telltale 在實車驗證，不能視為已支援。"],"status":"research'
    'Only","evidence":"sourceBacked","market":"Source-unspecified","make":"Hyundai","model"'
    ':"Ioniq Plug-in Hybrid","year_from":2021,"year_to":2023,"variant":"source-unspecified"'
    ',"powertrain":"PHEV","source":{"name":"Pinned source","url":"https://github.com/exampl'
    'e/source","revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","license":"Apache-2.0"'
    ',"path":"profiles/example.json","locator":"vehicle/example","artifact_sha256":""},"com'
    'mands":[]},{"id":"prius-hev","display_name":"Toyota Prius","description":"HEV 大電池資料候選"'
    ',"limitations":["尚未由 Telltale 在實車驗證，不能視為已支援。"],"status":"researchOnly","evidence":"sou'
    'rceBacked","market":"Source-unspecified","make":"Toyota","model":"Prius","year_from":2'
    '021,"year_to":2023,"variant":"source-unspecified","powertrain":"HEV","source":{"name":'
    '"Pinned source","url":"https://github.com/example/source","revision":"aaaaaaaaaaaaaaaa'
    'aaaaaaaaaaaaaaaaaaaaaaaa","license":"Apache-2.0","path":"profiles/example.json","locat'
    'or":"vehicle/example","artifact_sha256":""},"commands":[]},{"id":"leaf-bev","display_n'
    'ame":"Nissan Leaf","description":"BEV 大電池資料候選","limitations":["尚未由 Telltale 在實車驗證，不能視為'
    '已支援。"],"status":"researchOnly","evidence":"sourceBacked","market":"Source-unspecified"'
    ',"make":"Nissan","model":"Leaf","year_from":2021,"year_to":2023,"variant":"source-unsp'
    'ecified","powertrain":"BEV","source":{"name":"Pinned source","url":"https://github.com'
    '/example/source","revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","license":"Apac'
    'he-2.0","path":"profiles/example.json","locator":"vehicle/example","artifact_sha256":"'
    '"},"commands":[]}]}';

const _uncorroboratedManifestJson =
    '{"schema_version":3,"catalog_file":"powertrain_battery_catalog.json","sha256":"5e0a9d6'
    '6d4568f410b56f45762c900c412d39fe7f4440fd5007a441188daafe1","size_bytes":2877,"profile_'
    'count":4,"signal_count":1,"counts_by_powertrain":{"BEV":2,"PHEV":1,"HEV":1}}';

PowertrainBatteryCatalogSnapshot get _uncorroboratedSnapshot =>
    PowertrainBatteryCatalogAsset.fromStrings(
      manifestJson: _uncorroboratedManifestJson,
      catalogJson: _uncorroboratedCatalogJson,
    );

final class _ConnectedObdSession extends ObdSession {
  /// Overridable so a test can flip the connection identity while the
  /// install dialog sits open.
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

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  PowertrainBatteryCatalogSnapshot? snapshot,
  bool experimentalAccess = false,
  bool connected = false,
  bool loadError = false,
}) async {
  SharedPreferences.setMockInitialValues({
    if (experimentalAccess) 'powertrain_battery_experiments_enabled_v1': true,
  });
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      powertrainBatteryCatalogLoaderProvider.overrideWithValue(
        loadError
            ? () async => throw const PowertrainBatteryCatalogAssetException(
                'fixture integrity failure',
              )
            : () async => snapshot ?? _snapshot,
      ),
      if (connected) obdSessionProvider.overrideWith(_ConnectedObdSession.new),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: const PowertrainBatteryCatalogScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('catalog searches and filters PHEV, HEV and BEV separately', (
    tester,
  ) async {
    final container = await _pump(tester);
    addTearDown(container.dispose);

    expect(find.textContaining('4 個車型'), findsOneWidget);
    expect(find.text('Hyundai Ioniq Plug-in Hybrid'), findsOneWidget);

    await tester.tap(find.byKey(const Key('powertrain_filter_PHEV')));
    await tester.pumpAndSettle();
    expect(find.text('Hyundai Ioniq Plug-in Hybrid'), findsOneWidget);
    expect(find.text('Toyota Prius'), findsNothing);
    expect(find.text('MG ZS EV'), findsNothing);

    await tester.tap(find.byKey(const Key('powertrain_filter_all')));
    await tester.enterText(
      find.byKey(const Key('powertrain_profile_search')),
      'Prius',
    );
    await tester.pumpAndSettle();
    expect(find.text('Toyota Prius'), findsOneWidget);
    expect(find.text('Hyundai Ioniq Plug-in Hybrid'), findsNothing);
  });

  testWidgets('research-only PHEV shows evidence and cannot install', (
    tester,
  ) async {
    final container = await _pump(tester);
    addTearDown(container.dispose);

    final card = find.byKey(const Key('powertrain_profile_ioniq-phev'));
    await tester.ensureVisible(card);
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.text('僅研究')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('僅研究，不會查詢')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.textContaining('Apache-2.0')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.textContaining('尚未由 Telltale')),
      findsOneWidget,
    );
    final button = tester.widget<FilledButton>(
      find.descendant(of: card, matching: find.byType(FilledButton)),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('a corroborated community profile installs and uninstalls', (
    tester,
  ) async {
    final container = await _pump(tester);
    addTearDown(container.dispose);

    final card = find.byKey(const Key('powertrain_profile_mg-zs-ev'));
    await tester.ensureVisible(card);
    expect(
      find.descendant(of: card, matching: find.text('社群資料 · 未驗證')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('powertrain_install_mg-zs-ev')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('powertrain_install_disclosure')),
      findsOneWidget,
    );

    // Nothing installs before the identity acknowledgement.
    var confirm = tester.widget<FilledButton>(
      find.byKey(const Key('powertrain_confirm_install')),
    );
    expect(confirm.onPressed, isNull);

    await tester.tap(find.byKey(const Key('powertrain_install_identity_ack')));
    await tester.pump();
    confirm = tester.widget<FilledButton>(
      find.byKey(const Key('powertrain_confirm_install')),
    );
    expect(confirm.onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('powertrain_confirm_install')));
    await tester.pumpAndSettle();

    final registry = container.read(pidRegistryProvider.notifier);
    expect(registry.installedPowertrainProfileIds, {'mg-zs-ev'});
    expect(registry.profilePids, hasLength(1));
    expect(registry.installedVehicleYear('mg-zs-ev'), 2021);

    // Installation alone must not authorize polling for any connection.
    expect(container.read(powertrainProfileAuthorizationsProvider), isEmpty);

    await tester.tap(find.byKey(const Key('powertrain_uninstall_mg-zs-ev')));
    await tester.pumpAndSettle();
    expect(registry.installedPowertrainProfileIds, isEmpty);
    expect(registry.profilePids, isEmpty);
  });

  testWidgets(
    'recording lock refuses catalog uninstall without removing signals',
    (tester) async {
      final container = await _pump(tester);
      addTearDown(container.dispose);
      await container
          .read(pidRegistryProvider.notifier)
          .installPowertrainProfile(_snapshot, 'mg-zs-ev', vehicleYear: 2021);
      await tester.pumpAndSettle();
      expect(
        container
            .read(pidRegistryProvider.notifier)
            .installedPowertrainProfileIds,
        {'mg-zs-ev'},
      );

      final token = container
          .read(pidMutationLockProvider)
          .tryAcquire('recording')!;
      await tester.ensureVisible(
        find.byKey(const Key('powertrain_uninstall_mg-zs-ev')),
      );
      await tester.tap(find.byKey(const Key('powertrain_uninstall_mg-zs-ev')));
      await tester.pumpAndSettle();

      expect(find.text(kPidMutationLockedMessage), findsOneWidget);
      expect(
        container
            .read(pidRegistryProvider.notifier)
            .installedPowertrainProfileIds,
        {'mg-zs-ev'},
      );
      container.read(pidMutationLockProvider).release(token);
    },
  );

  testWidgets(
    'an install accepted after the connection changed grants nothing',
    (tester) async {
      final container = await _pump(tester, connected: true);
      addTearDown(container.dispose);

      final card = find.byKey(const Key('powertrain_profile_mg-zs-ev'));
      await tester.ensureVisible(card);
      await tester.tap(find.byKey(const Key('powertrain_install_mg-zs-ev')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('powertrain_install_identity_ack')),
      );
      await tester.pump();

      // The connection the dialog was opened against goes away while it sits
      // open. The install itself may proceed — definitions are inert — but
      // the in-gesture authorization must not attach to whatever connected
      // next; the dashboard banner will ask for that connection instead.
      final session =
          container.read(obdSessionProvider.notifier) as _ConnectedObdSession;
      session.fakeGeneration = 99;
      await tester.tap(find.byKey(const Key('powertrain_confirm_install')));
      await tester.pumpAndSettle();

      final registry = container.read(pidRegistryProvider.notifier);
      expect(registry.installedPowertrainProfileIds, {'mg-zs-ev'});
      expect(container.read(powertrainProfileAuthorizationsProvider), isEmpty);
    },
  );

  testWidgets('an uncorroborated community profile fails the whole catalog', (
    tester,
  ) async {
    // Same tier label, but with the corroboration stripped: no secondary
    // source and no pinned artifact. Enforcement happens at catalog load —
    // an invalid community entry makes the whole bundle unavailable rather
    // than shipping with a closed button.
    expect(
      () => _uncorroboratedSnapshot,
      throwsA(
        isA<PowertrainBatteryCatalogAssetException>().having(
          (error) => error.toString(),
          'message',
          contains('missing_source_artifact_hash'),
        ),
      ),
    );

    final container = await _pump(tester, loadError: true);
    addTearDown(container.dispose);
    expect(find.text('離線目錄無法載入'), findsOneWidget);
  });

  testWidgets(
    'experimental probe names unknown identity fields and requires both acknowledgements',
    (tester) async {
      final production = await tester.runAsync(
        PowertrainBatteryCatalogAsset.load,
      );
      final container = await _pump(
        tester,
        snapshot: production!,
        experimentalAccess: true,
        connected: true,
      );
      addTearDown(container.dispose);

      await tester.enterText(
        find.byKey(const Key('powertrain_profile_search')),
        'RX450hL',
      );
      await tester.pumpAndSettle();
      final probeButton = find.byKey(
        const Key('powertrain_probe_lexus-rx450hl-2020-source-vehicle'),
      );
      await tester.ensureVisible(probeButton);
      await tester.pumpAndSettle();
      await tester.tap(probeButton);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const Key(
            'powertrain_probe_command_lexus-rx450hl-2020-source-vehicle_2161',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('powertrain_experimental_identity_evidence')),
        findsOneWidget,
      );
      expect(find.textContaining('市場 未知'), findsOneWidget);
      expect(find.textContaining('未證實欄位：市場'), findsOneWidget);
      final disclosure = find.byKey(
        const Key('powertrain_experimental_data_disclosure'),
      );
      expect(disclosure, findsOneWidget);
      final disclosureText = tester.widget<Text>(disclosure).data!;
      expect(disclosureText, contains('ELM327'));
      expect(disclosureText, contains('本機診斷紀錄'));
      expect(disclosureText, contains('不會由此功能自動上傳'));
      expect(disclosureText, contains('取消不影響一般 OBD 功能'));
      var confirm = tester.widget<FilledButton>(
        find.byKey(const Key('powertrain_confirm_experimental_probe')),
      );
      expect(confirm.onPressed, isNull);

      await tester.tap(
        find.byKey(const Key('powertrain_experimental_identity_ack')),
      );
      await tester.pump();
      confirm = tester.widget<FilledButton>(
        find.byKey(const Key('powertrain_confirm_experimental_probe')),
      );
      expect(confirm.onPressed, isNull);

      await tester.tap(
        find.byKey(const Key('powertrain_experimental_parked_ack')),
      );
      await tester.pump();
      confirm = tester.widget<FilledButton>(
        find.byKey(const Key('powertrain_confirm_experimental_probe')),
      );
      expect(confirm.onPressed, isNotNull);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    },
  );
}
