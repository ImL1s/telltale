import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/obd/vehicle_catalog/us_vehicle_catalog.dart';

const _csv =
    'epa_id,year,make,model,base_model,transmission,drive,fuel_type,fuel_type_primary,fuel_type_secondary,alternative_vehicle_type,displacement_l,cylinders,modified_on\n'
    '1,2020,Alpha,Roadster,Roadster,Manual 6-spd,Rear-Wheel Drive,Premium,Premium Gasoline,,,2.0,4,2020-01-01\n'
    '2,2021,Beta,City,City,Automatic,Front-Wheel Drive,Regular,Regular Gasoline,,,1.5,4,2021-01-01\n'
    '3,2021,Beta,City Sport,City,Manual,Front-Wheel Drive,Regular,Regular Gasoline,,,1.6,4,2021-01-02\n';

String _manifest({
  String sha256 =
      '8911153d80715b6904a9d277474ada78dbe694f7097d6c59f67e93e23d33dc66',
  int sizeBytes = 459,
  int rowCount = 3,
  int uniqueMakeCount = 2,
  int yearMin = 2020,
  int yearMax = 2021,
  int schemaVersion = 2,
  List<String> columns = UsVehicleCatalog.requiredColumns,
}) => jsonEncode({
  'schema_version': schemaVersion,
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
    'columns': columns,
    'row_count': rowCount,
    'sha256': sha256,
    'size_bytes': sizeBytes,
    'unique_make_count': uniqueMakeCount,
    'year_min': yearMin,
    'year_max': yearMax,
  },
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('U.S. EPA vehicle catalog', () {
    test('parses a verified snapshot and supports exact queries', () {
      final catalog = UsVehicleCatalog.fromStrings(
        manifestJson: _manifest(),
        csv: _csv,
      );

      expect(catalog.length, 3);
      expect(catalog.years, [2020, 2021]);
      expect(catalog.makes(), ['Alpha', 'Beta']);
      expect(catalog.makes(year: 2021), ['Beta']);
      expect(catalog.models(year: 2021, make: 'Beta'), ['City', 'City Sport']);
      expect(
        catalog.configurations(year: 2021, make: 'Beta', model: 'City'),
        hasLength(1),
      );

      final city = catalog.byEpaId(2)!;
      expect(city.year, 2021);
      expect(city.make, 'Beta');
      expect(city.model, 'City');
      expect(city.displacementL, 1.5);
      expect(city.cylinders, 4);
      expect(catalog.byEpaId(999), isNull);
    });

    test(
      'loads the bundled official snapshot with manifest statistics',
      () async {
        final catalog = await UsVehicleCatalog.load(rootBundle);

        expect(catalog.length, 50242);
        expect(catalog.years.first, 1984);
        expect(catalog.years.last, 2027);
        expect(catalog.makes(), hasLength(146));
        expect(catalog.byEpaId(1)?.make, 'Alfa Romeo');
        expect(catalog.byEpaId(29472)?.displacementL, isNull);
        expect(catalog.byEpaId(29472)?.cylinders, isNull);
        expect(catalog.byEpaId(36023)?.displacementL, isNull);
      },
    );

    test('rejects a manifest that broadens market or changes source', () {
      final changedMarket = _manifest().replaceFirst('United States', 'Global');
      final changedSource = _manifest().replaceFirst(
        'www.fueleconomy.gov/feg/epadata',
        'example.test/epadata',
      );

      for (final manifest in [changedMarket, changedSource]) {
        expect(
          () => UsVehicleCatalog.fromStrings(manifestJson: manifest, csv: _csv),
          throwsA(isA<UsVehicleCatalogException>()),
        );
      }
    });

    test('rejects unsupported schema, columns, hash, size, and statistics', () {
      final cases = <String>[
        _manifest(schemaVersion: 1),
        _manifest(columns: [...UsVehicleCatalog.requiredColumns]..removeLast()),
        _manifest(sha256: '${'0' * 63}1'),
        _manifest(sizeBytes: 430),
        _manifest(rowCount: 4),
        _manifest(uniqueMakeCount: 3),
        _manifest(yearMin: 2019),
        _manifest(yearMax: 2022),
      ];

      for (final manifest in cases) {
        expect(
          () => UsVehicleCatalog.fromStrings(manifestJson: manifest, csv: _csv),
          throwsA(isA<UsVehicleCatalogException>()),
        );
      }
    });

    test('rejects duplicate, unsorted, malformed, and incomplete rows', () {
      final header = _csv.substring(0, _csv.indexOf('\n') + 1);
      final first = _csv.split('\n')[1];
      final second = _csv.split('\n')[2];
      final malformed = <String>[
        '$header$first\n$first\n',
        '$header$second\n$first\n',
        _csv.replaceFirst('1,2020', 'zero,2020'),
        _csv.replaceFirst('1,2020', '1,1983'),
        _csv.replaceFirst('Alpha,Roadster', ',Roadster'),
        _csv.replaceFirst(',2.0,4,', ',-2.0,4,'),
        _csv.replaceFirst(',2.0,4,', ',2.0,4.5,'),
        _csv.replaceFirst('Alpha', 'Al\u0000pha'),
      ];

      for (final csv in malformed) {
        expect(
          () =>
              UsVehicleCatalog.fromStrings(manifestJson: _manifest(), csv: csv),
          throwsA(isA<UsVehicleCatalogException>()),
        );
      }
    });

    test('queries are exact and never infer unsupported vehicle physics', () {
      final catalog = UsVehicleCatalog.fromStrings(
        manifestJson: _manifest(),
        csv: _csv,
      );
      final config = catalog.byEpaId(1)!;

      expect(catalog.models(year: 2020, make: 'alpha'), isEmpty);
      expect(config.toJson(), isNot(contains('mass_kg')));
      expect(config.toJson(), isNot(contains('horsepower')));
      expect(config.toJson(), isNot(contains('torque')));
      expect(config.toJson(), isNot(contains('drag_coefficient')));
      expect(config.toJson(), isNot(contains('volumetric_efficiency')));
    });
  });
}
