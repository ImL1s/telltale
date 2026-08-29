import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/core/theme/app_theme.dart';
import 'package:torque_obd/obd/physics/vehicle_evidence.dart';
import 'package:torque_obd/obd/physics/vehicle_profile.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/obd/vehicle_catalog/us_vehicle_catalog.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_registry.dart';
import 'package:torque_obd/state/settings.dart';
import 'package:torque_obd/state/vehicle_catalog.dart';
import 'package:torque_obd/state/vehicle_identity.dart';
import 'package:torque_obd/ui/screens/settings/settings_screen.dart';

const _epaEvidence = EvidenceRef(
  sourceId: 'us-epa-fueleconomy-vehicles',
  publisher: 'U.S. EPA / U.S. DOE',
  sourceUrl: 'https://www.fueleconomy.gov/feg/download.shtml',
  revision: 'Fri, 07 Aug 2026 13:13:33 GMT',
  retrievedAt: '2026-08-29T14:28:23+00:00',
  sha256: '6dc8aed9232a88844e18f0160e94eeaa75abc0dcf8a36286e3166797f4933331',
  market: 'United States',
  locator: 'epa_id=12345',
  year: 2024,
  make: 'Example',
  model: 'Roadster',
  trim: '2.0 RWD 6MT',
);

const _catalogCsv =
    'epa_id,year,make,model,base_model,transmission,drive,fuel_type,fuel_type_primary,fuel_type_secondary,alternative_vehicle_type,displacement_l,cylinders,modified_on\n'
    '1,2020,Alpha,Roadster,Roadster,Manual 6-spd,Rear-Wheel Drive,Premium,Premium Gasoline,,,2.0,4,2020-01-01\n';

const _evCatalogCsv =
    'epa_id,year,make,model,base_model,transmission,drive,fuel_type,fuel_type_primary,fuel_type_secondary,alternative_vehicle_type,displacement_l,cylinders,modified_on\n'
    '2,2020,Alpha,Silent,Silent,Automatic (A1),Front-Wheel Drive,Electricity,Electricity,,EV,,,2020-01-01\n';

String get _catalogManifest => jsonEncode({
  'schema_version': 2,
  'dataset': 'U.S. EPA FuelEconomy.gov Find-a-Car vehicle configurations',
  'coverage': {
    'market': 'United States',
    'vehicle_scope': 'FuelEconomy.gov Find-a-Car configurations',
  },
  'source': {
    'archive_url': 'https://www.fueleconomy.gov/feg/epadata/vehicles.csv.zip',
    'landing_page': 'https://www.fueleconomy.gov/feg/download.shtml',
    'retrieved_at_utc': '2026-08-29T14:28:23+00:00',
    'sha256': 'a' * 64,
  },
  'output': {
    'file': 'us_epa_vehicles.csv',
    'columns': UsVehicleCatalog.requiredColumns,
    'row_count': 1,
    'sha256':
        '55d34c5d52f6018feca6735707c4ae443b939a0f26f69bd52651e70f9f388612',
    'size_bytes': 268,
    'unique_make_count': 1,
    'year_min': 2020,
    'year_max': 2020,
  },
});

String get _evCatalogManifest => jsonEncode({
  'schema_version': 2,
  'dataset': 'U.S. EPA FuelEconomy.gov Find-a-Car vehicle configurations',
  'coverage': {
    'market': 'United States',
    'vehicle_scope': 'FuelEconomy.gov Find-a-Car configurations',
  },
  'source': {
    'archive_url': 'https://www.fueleconomy.gov/feg/epadata/vehicles.csv.zip',
    'landing_page': 'https://www.fueleconomy.gov/feg/download.shtml',
    'retrieved_at_utc': '2026-08-29T14:28:23+00:00',
    'sha256': 'b' * 64,
  },
  'output': {
    'file': 'us_epa_vehicles.csv',
    'columns': UsVehicleCatalog.requiredColumns,
    'row_count': 1,
    'sha256':
        'd7d6208f9538207a1ef1291b91e2acd42a5aff61baac87e9734157687b29b1ae',
    'size_bytes': 264,
    'unique_make_count': 1,
    'year_min': 2020,
    'year_max': 2020,
  },
});

class _DisconnectedSession extends ObdSession {
  @override
  ObdConnectionState build() => const ObdConnectionState();
}

class _ConnectedSession extends ObdSession {
  @override
  ObdConnectionState build() => const ObdConnectionState(
    phase: ConnectionPhase.connected,
    kind: TransportKind.demo,
    deviceName: 'Demo ECU',
  );
}

class _ReportedIdentity extends VehicleIdentityController {
  @override
  VehicleIdentity build() =>
      VehicleIdentity.vehicleReported('1D4GP00R55B123456');
}

class _ExactProfile extends VehicleProfileController {
  @override
  VehicleProfile build() => VehicleProfile.sourced(
    displacementL: SourcedField(
      value: 2.0,
      origin: VehicleFieldOrigin.officialRegistry,
      resolution: EvidenceResolution.verifiedExact,
      evidence: _epaEvidence,
    ),
  );
}

class _ConfirmedGenericProfile extends VehicleProfileController {
  @override
  VehicleProfile build() => const VehicleProfile(isConfirmed: true);
}

Future<void> _pumpSettings(
  WidgetTester tester, {
  bool connected = false,
  bool reportedVin = false,
  bool exactProfile = false,
  bool confirmedGenericProfile = false,
  UsVehicleCatalog? catalog,
  Future<UsVehicleCatalog> Function()? catalogLoader,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  tester.view.physicalSize = const Size(1080, 2200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        obdSessionProvider.overrideWith(
          connected ? _ConnectedSession.new : _DisconnectedSession.new,
        ),
        if (reportedVin)
          vehicleIdentityProvider.overrideWith(_ReportedIdentity.new),
        if (exactProfile)
          vehicleProfileProvider.overrideWith(_ExactProfile.new),
        if (confirmedGenericProfile)
          vehicleProfileProvider.overrideWith(_ConfirmedGenericProfile.new),
        if (catalogLoader != null)
          usVehicleCatalogLoaderProvider.overrideWithValue(catalogLoader)
        else if (catalog != null)
          usVehicleCatalogLoaderProvider.overrideWithValue(() async => catalog),
      ],
      child: MaterialApp(theme: AppTheme.dark(), home: const SettingsScreen()),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('generic profile values are never presented as verified data', (
    tester,
  ) async {
    await _pumpSettings(tester);

    expect(find.textContaining('沒有欄位已精確解析到這次車輛'), findsOneWidget);
    expect(find.textContaining('官方精確 0 / 8 欄'), findsOneWidget);
    expect(find.textContaining('通用 8 / 8 欄'), findsOneWidget);
    expect(find.textContaining('VIN 尚未讀取'), findsOneWidget);
  });

  testWidgets('an exact EPA configuration applies only supported fields', (
    tester,
  ) async {
    final catalog = UsVehicleCatalog.fromStrings(
      manifestJson: _catalogManifest,
      csv: _catalogCsv,
    );
    await _pumpSettings(tester, catalog: catalog);

    await tester.tap(find.text('從官方目錄選擇'));
    await tester.pumpAndSettle();
    expect(find.textContaining('僅限美國市場'), findsOneWidget);

    await tester.tap(find.byKey(const Key('us_epa_year')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2020').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('us_epa_make')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alpha').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('us_epa_model')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Roadster').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('us_epa_config_1')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('套用 2 個官方欄位'));
    await tester.pumpAndSettle();

    expect(find.textContaining('官方精確 2 / 8 欄'), findsOneWidget);
    expect(find.textContaining('2020 Alpha Roadster'), findsOneWidget);
  });

  testWidgets(
    'a zero-compatible-field row is browsable but cannot be applied',
    (tester) async {
      final catalog = UsVehicleCatalog.fromStrings(
        manifestJson: _evCatalogManifest,
        csv: _evCatalogCsv,
      );
      await _pumpSettings(tester, catalog: catalog);

      await tester.tap(find.text('從官方目錄選擇'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('us_epa_year')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2020').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('us_epa_make')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alpha').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('us_epa_model')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Silent').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('us_epa_config_2')));
      await tester.pumpAndSettle();

      expect(find.textContaining('沒有能安全套用'), findsOneWidget);
      await tester.tap(find.text('關閉（沒有可套用欄位）'));
      await tester.pumpAndSettle();

      expect(find.textContaining('官方精確 0 / 8 欄'), findsOneWidget);
      expect(find.textContaining('沒有欄位已精確解析到這次車輛'), findsOneWidget);
    },
  );

  testWidgets('catalog corruption is handled but programming errors surface', (
    tester,
  ) async {
    await _pumpSettings(
      tester,
      catalogLoader: () async =>
          throw const UsVehicleCatalogException('bad fixture'),
    );
    await tester.tap(find.text('從官方目錄選擇'));
    await tester.pump();
    expect(find.textContaining('官方離線目錄損壞'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _pumpSettings(
      tester,
      catalogLoader: () async => throw StateError('programming defect'),
    );
    final originalOnError = FlutterError.onError;
    FlutterErrorDetails? reported;
    try {
      FlutterError.onError = (details) => reported = details;
      await tester.tap(find.text('從官方目錄選擇'));
      await tester.pump();
    } finally {
      FlutterError.onError = originalOnError;
    }
    expect(reported?.exception, isA<StateError>());
    expect(reported?.library, 'Telltale vehicle catalog');
  });

  testWidgets('exact fields name their official source and bounded coverage', (
    tester,
  ) async {
    await _pumpSettings(tester, exactProfile: true);

    expect(find.textContaining('官方精確 1 / 8 欄'), findsOneWidget);
    expect(find.textContaining('U.S. EPA / U.S. DOE'), findsOneWidget);
    expect(find.textContaining('只有排氣量'), findsOneWidget);
    expect(find.textContaining('其他欄位仍須逐項確認'), findsOneWidget);
  });

  testWidgets('source and current-vehicle resolution are separate axes', (
    tester,
  ) async {
    await _pumpSettings(tester, confirmedGenericProfile: true);

    expect(find.textContaining('本次確認 8 / 8 欄'), findsOneWidget);
    expect(find.textContaining('未解析 0 / 8 欄'), findsOneWidget);
    expect(find.textContaining('通用 8 / 8 欄'), findsOneWidget);
    expect(find.textContaining('官方／原廠 0 / 8 欄'), findsOneWidget);
  });

  testWidgets('a vehicle-reported VIN is labelled as identity, not a profile', (
    tester,
  ) async {
    await _pumpSettings(tester, connected: true, reportedVin: true);

    expect(find.text('1D4GP00R55B123456'), findsOneWidget);
    expect(find.textContaining('回報 VIN'), findsWidgets);
    expect(find.textContaining('不代表車型規格已驗證'), findsOneWidget);
    expect(find.textContaining('診斷紀錄仍可能包含 VIN'), findsOneWidget);
  });
}
