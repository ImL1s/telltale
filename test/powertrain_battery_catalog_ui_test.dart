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
import 'package:torque_obd/ui/screens/pids/powertrain_battery_catalog_screen.dart';

const _catalogJson =
    '{"schema_version":2,"profiles":[{"id":"mg-zs-ev","display_name":"MG ZS EV","description":"'
    'BEV 大電池資料候選","limitations":["尚未由 Telltale 在實車驗證，不能視為已支援。"],"status":"community","evidence"'
    ':"sourceBacked","market":"Synthetic laboratory","make":"MG","model":"ZS EV","year_from":20'
    '21,"year_to":2023,"variant":"fixture-v1","powertrain":"BEV","identity_evidence":{"market":"exact","year":"exact","model":"exact","variant":"exact"},"source":{"name":"Pinned sourc'
    'e","url":"https://github.com/example/source","revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    'aaaaaaa","license":"Apache-2.0","path":"profiles/example.json","locator":"vehicle/example"'
    ',"artifact_sha256":""},"commands":[{"request_header":"781","expected_responder":"789","mod'
    'e":"22","identifier":"B046","payload_length":2,"signals":[{"id":"raw-soc","name":"Raw SOC"'
    ',"offset":0,"width":2,"equation":"(A*256+B)/10","unit":"%","min_value":0,"max_value":100,"'
    'semantic_kind":"traction_battery_soc","recommended":true}]}]},{"id":"ioniq-phev","display_'
    'name":"Hyundai Ioniq Plug-in Hybrid","description":"PHEV 大電池資料候選","limitations":["尚未由 Tell'
    'tale 在實車驗證，不能視為已支援。"],"status":"researchOnly","evidence":"sourceBacked","market":"Source-u'
    'nspecified","make":"Hyundai","model":"Ioniq Plug-in Hybrid","year_from":2021,"year_to":202'
    '3,"variant":"source-unspecified","powertrain":"PHEV","source":{"name":"Pinned source","url'
    '":"https://github.com/example/source","revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    '","license":"Apache-2.0","path":"profiles/example.json","locator":"vehicle/example","artif'
    'act_sha256":""},"commands":[]},{"id":"prius-hev","display_name":"Toyota Prius","descriptio'
    'n":"HEV 大電池資料候選","limitations":["尚未由 Telltale 在實車驗證，不能視為已支援。"],"status":"researchOnly","ev'
    'idence":"sourceBacked","market":"Source-unspecified","make":"Toyota","model":"Prius","year'
    '_from":2021,"year_to":2023,"variant":"source-unspecified","powertrain":"HEV","source":{"na'
    'me":"Pinned source","url":"https://github.com/example/source","revision":"aaaaaaaaaaaaaaaa'
    'aaaaaaaaaaaaaaaaaaaaaaaa","license":"Apache-2.0","path":"profiles/example.json","locator":'
    '"vehicle/example","artifact_sha256":""},"commands":[]},{"id":"leaf-bev","display_name":"Ni'
    'ssan Leaf","description":"BEV 大電池資料候選","limitations":["尚未由 Telltale 在實車驗證，不能視為已支援。"],"stat'
    'us":"researchOnly","evidence":"sourceBacked","market":"Source-unspecified","make":"Nissan"'
    ',"model":"Leaf","year_from":2021,"year_to":2023,"variant":"source-unspecified","powertrain'
    '":"BEV","source":{"name":"Pinned source","url":"https://github.com/example/source","revisi'
    'on":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","license":"Apache-2.0","path":"profiles/exa'
    'mple.json","locator":"vehicle/example","artifact_sha256":""},"commands":[]}]}';

const _manifestJson =
    '{"schema_version":2,"catalog_file":"powertrain_battery_catalog.json","sha256":"0cbc36f4aae'
    'd4316d91a452fb044bfb24dbe2a45d267648c31090dc7ba8aacf3","size_bytes":2877,"profile_count":4'
    ',"signal_count":1,"counts_by_powertrain":{"BEV":2,"PHEV":1,"HEV":1}}';

PowertrainBatteryCatalogSnapshot get _snapshot =>
    PowertrainBatteryCatalogAsset.fromStrings(
      manifestJson: _manifestJson,
      catalogJson: _catalogJson,
    );

final class _ConnectedObdSession extends ObdSession {
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
}) async {
  SharedPreferences.setMockInitialValues({
    if (experimentalAccess) 'powertrain_battery_experiments_enabled_v1': true,
  });
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      powertrainBatteryCatalogLoaderProvider.overrideWithValue(
        () async => snapshot ?? _snapshot,
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

  testWidgets('source maturity never exposes an install action', (
    tester,
  ) async {
    final container = await _pump(tester);
    addTearDown(container.dispose);

    final card = find.byKey(const Key('powertrain_profile_mg-zs-ev'));
    await tester.ensureVisible(card);
    expect(
      find.descendant(of: card, matching: find.text('社群資料')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('此版本不可安裝')),
      findsOneWidget,
    );
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('powertrain_probe_mg-zs-ev')),
    );
    expect(button.onPressed, isNull);
    expect(find.byKey(const Key('powertrain_confirm_install')), findsNothing);
    expect(
      find.byKey(const Key('powertrain_uninstall_mg-zs-ev')),
      findsNothing,
    );
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
        'Australian 2021',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('powertrain_probe_mg-zs-ev-au-2021')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const Key('powertrain_probe_command_mg-zs-ev-au-2021_22B046'),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('powertrain_experimental_identity_evidence')),
        findsOneWidget,
      );
      expect(find.textContaining('版本 未知'), findsOneWidget);
      expect(find.textContaining('未證實欄位：版本'), findsOneWidget);
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
