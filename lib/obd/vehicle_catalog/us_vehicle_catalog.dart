/// Integrity-checked, offline U.S. EPA vehicle identity catalog.
///
/// This catalog contains only fields published in FuelEconomy.gov's
/// Find-a-Car download. It deliberately does not infer curb mass, power,
/// torque, drag coefficient, frontal area, or volumetric efficiency.
library;

import 'dart:convert';

import 'package:csv/csv.dart';
import 'package:flutter/services.dart';

class UsVehicleCatalogException implements Exception {
  const UsVehicleCatalogException(this.message);

  final String message;

  @override
  String toString() => 'UsVehicleCatalogException: $message';
}

class UsEpaVehicleConfiguration {
  const UsEpaVehicleConfiguration({
    required this.epaId,
    required this.year,
    required this.make,
    required this.model,
    required this.baseModel,
    required this.transmission,
    required this.drive,
    required this.fuelType,
    required this.fuelTypePrimary,
    required this.fuelTypeSecondary,
    required this.alternativeVehicleType,
    required this.displacementL,
    required this.cylinders,
    required this.modifiedOn,
  });

  final int epaId;
  final int year;
  final String make;
  final String model;
  final String baseModel;
  final String transmission;
  final String drive;
  final String fuelType;
  final String fuelTypePrimary;
  final String fuelTypeSecondary;
  final String alternativeVehicleType;
  final double? displacementL;
  final int? cylinders;
  final String modifiedOn;

  Map<String, Object?> toJson() => {
    'epa_id': epaId,
    'year': year,
    'make': make,
    'model': model,
    'base_model': baseModel,
    'transmission': transmission,
    'drive': drive,
    'fuel_type': fuelType,
    'fuel_type_primary': fuelTypePrimary,
    'fuel_type_secondary': fuelTypeSecondary,
    'alternative_vehicle_type': alternativeVehicleType,
    'displacement_l': displacementL,
    'cylinders': cylinders,
    'modified_on': modifiedOn,
  };
}

class UsVehicleCatalog {
  UsVehicleCatalog._({
    required Map<int, UsEpaVehicleConfiguration> byId,
    required this.snapshotSha256,
    required this.retrievedAtUtc,
  }) : _byId = Map.unmodifiable(byId) {
    final years = <int>{};
    final makesByYear = <int, Set<String>>{};
    final modelsByYearMake = <int, Map<String, Set<String>>>{};
    final configurations =
        <int, Map<String, Map<String, List<UsEpaVehicleConfiguration>>>>{};

    for (final configuration in _byId.values) {
      years.add(configuration.year);
      makesByYear
          .putIfAbsent(configuration.year, () => {})
          .add(configuration.make);
      modelsByYearMake
          .putIfAbsent(configuration.year, () => {})
          .putIfAbsent(configuration.make, () => {})
          .add(configuration.model);
      configurations
          .putIfAbsent(configuration.year, () => {})
          .putIfAbsent(configuration.make, () => {})
          .putIfAbsent(configuration.model, () => [])
          .add(configuration);
    }

    _years = years.toList()..sort();
    _makesByYear = Map<int, List<String>>.unmodifiable({
      for (final entry in makesByYear.entries)
        entry.key: List<String>.unmodifiable(entry.value.toList()..sort()),
    });
    _modelsByYearMake = Map<int, Map<String, List<String>>>.unmodifiable({
      for (final yearEntry in modelsByYearMake.entries)
        yearEntry.key: Map<String, List<String>>.unmodifiable({
          for (final makeEntry in yearEntry.value.entries)
            makeEntry.key: List<String>.unmodifiable(
              makeEntry.value.toList()..sort(),
            ),
        }),
    });
    _configurations =
        Map<
          int,
          Map<String, Map<String, List<UsEpaVehicleConfiguration>>>
        >.unmodifiable({
          for (final yearEntry in configurations.entries)
            yearEntry.key:
                Map<
                  String,
                  Map<String, List<UsEpaVehicleConfiguration>>
                >.unmodifiable({
                  for (final makeEntry in yearEntry.value.entries)
                    makeEntry.key:
                        Map<
                          String,
                          List<UsEpaVehicleConfiguration>
                        >.unmodifiable({
                          for (final modelEntry in makeEntry.value.entries)
                            modelEntry.key:
                                List<UsEpaVehicleConfiguration>.unmodifiable(
                                  modelEntry.value,
                                ),
                        }),
                }),
        });
  }

  static const catalogAsset = 'assets/vehicle_catalog/us_epa_vehicles.csv';
  static const manifestAsset =
      'assets/vehicle_catalog/us_epa_vehicles.manifest.json';

  static const requiredColumns = <String>[
    'epa_id',
    'year',
    'make',
    'model',
    'base_model',
    'transmission',
    'drive',
    'fuel_type',
    'fuel_type_primary',
    'fuel_type_secondary',
    'alternative_vehicle_type',
    'displacement_l',
    'cylinders',
    'modified_on',
  ];

  final Map<int, UsEpaVehicleConfiguration> _byId;
  late final List<int> _years;
  late final Map<int, List<String>> _makesByYear;
  late final Map<int, Map<String, List<String>>> _modelsByYearMake;
  late final Map<int, Map<String, Map<String, List<UsEpaVehicleConfiguration>>>>
  _configurations;

  final String snapshotSha256;
  final DateTime retrievedAtUtc;

  int get length => _byId.length;
  List<int> get years => List.unmodifiable(_years);

  static Future<UsVehicleCatalog> load([AssetBundle? bundle]) async {
    final assets = bundle ?? rootBundle;
    try {
      final values = await Future.wait([
        assets.loadString(manifestAsset),
        assets.loadString(catalogAsset),
      ]);
      return UsVehicleCatalog.fromStrings(
        manifestJson: values[0],
        csv: values[1],
      );
    } on UsVehicleCatalogException {
      rethrow;
    } catch (error) {
      throw UsVehicleCatalogException('cannot load bundled catalog: $error');
    }
  }

  factory UsVehicleCatalog.fromStrings({
    required String manifestJson,
    required String csv,
  }) {
    try {
      final manifest = _Manifest.parse(manifestJson);
      final csvBytes = utf8.encode(csv);
      final actualHash = _sha256Hex(csvBytes);
      if (manifest.sha256 != actualHash) {
        throw const UsVehicleCatalogException(
          'catalog SHA-256 does not match its manifest',
        );
      }
      if (manifest.sizeBytes != csvBytes.length) {
        throw const UsVehicleCatalogException(
          'catalog byte size does not match its manifest',
        );
      }

      final decoded = Csv(autoDetect: false, lineDelimiter: '\n').decode(csv);
      if (decoded.isEmpty) {
        throw const UsVehicleCatalogException('catalog CSV is empty');
      }
      final header = decoded.first.map((value) => value.toString()).toList();
      if (!_sameStrings(header, requiredColumns)) {
        throw const UsVehicleCatalogException(
          'catalog CSV columns do not match schema version 2',
        );
      }

      final byId = <int, UsEpaVehicleConfiguration>{};
      final makes = <String>{};
      int? previousId;
      int? yearMin;
      int? yearMax;
      for (var index = 1; index < decoded.length; index++) {
        final values = decoded[index];
        final rowNumber = index + 1;
        if (values.length != requiredColumns.length) {
          throw UsVehicleCatalogException(
            'catalog row $rowNumber has ${values.length} columns; '
            'expected ${requiredColumns.length}',
          );
        }
        final fields = values.map((value) => value.toString()).toList();
        if (fields.any((value) => value.contains('\u0000'))) {
          throw UsVehicleCatalogException(
            'catalog row $rowNumber contains a NUL byte',
          );
        }

        final epaId = _positiveInt(fields[0], 'EPA id', rowNumber);
        final year = _positiveInt(fields[1], 'year', rowNumber);
        if (year < 1984) {
          throw UsVehicleCatalogException(
            'catalog row $rowNumber has a year below 1984',
          );
        }
        if (previousId != null && epaId <= previousId) {
          throw const UsVehicleCatalogException(
            'catalog EPA ids must be unique and strictly increasing',
          );
        }
        previousId = epaId;

        final make = fields[2];
        final model = fields[3];
        if (make.trim().isEmpty || model.trim().isEmpty) {
          throw UsVehicleCatalogException(
            'catalog row $rowNumber has an empty make or model',
          );
        }
        if (make != make.trim() || model != model.trim()) {
          throw UsVehicleCatalogException(
            'catalog row $rowNumber has padded make or model text',
          );
        }

        final displacement = _optionalPositiveDouble(
          fields[11],
          'displacement',
          rowNumber,
        );
        final cylinders = _optionalPositiveInt(
          fields[12],
          'cylinders',
          rowNumber,
        );
        final configuration = UsEpaVehicleConfiguration(
          epaId: epaId,
          year: year,
          make: make,
          model: model,
          baseModel: fields[4],
          transmission: fields[5],
          drive: fields[6],
          fuelType: fields[7],
          fuelTypePrimary: fields[8],
          fuelTypeSecondary: fields[9],
          alternativeVehicleType: fields[10],
          displacementL: displacement,
          cylinders: cylinders,
          modifiedOn: fields[13],
        );
        byId[epaId] = configuration;
        makes.add(make);
        yearMin = yearMin == null || year < yearMin ? year : yearMin;
        yearMax = yearMax == null || year > yearMax ? year : yearMax;
      }

      if (byId.isEmpty) {
        throw const UsVehicleCatalogException(
          'catalog CSV has no vehicle configurations',
        );
      }
      if (byId.length != manifest.rowCount ||
          makes.length != manifest.uniqueMakeCount ||
          yearMin != manifest.yearMin ||
          yearMax != manifest.yearMax) {
        throw const UsVehicleCatalogException(
          'catalog contents do not match manifest statistics',
        );
      }

      return UsVehicleCatalog._(
        byId: byId,
        snapshotSha256: manifest.sha256,
        retrievedAtUtc: manifest.retrievedAtUtc,
      );
    } on UsVehicleCatalogException {
      rethrow;
    } on FormatException catch (error) {
      throw UsVehicleCatalogException('invalid catalog format: $error');
    }
  }

  UsEpaVehicleConfiguration? byEpaId(int epaId) => _byId[epaId];

  List<String> makes({int? year}) {
    if (year != null) return _makesByYear[year] ?? const [];
    final all = <String>{};
    for (final values in _makesByYear.values) {
      all.addAll(values);
    }
    return List.unmodifiable(all.toList()..sort());
  }

  List<String> models({required int year, required String make}) =>
      _modelsByYearMake[year]?[make] ?? const [];

  List<UsEpaVehicleConfiguration> configurations({
    required int year,
    required String make,
    required String model,
  }) => _configurations[year]?[make]?[model] ?? const [];
}

class _Manifest {
  const _Manifest({
    required this.sha256,
    required this.sizeBytes,
    required this.rowCount,
    required this.uniqueMakeCount,
    required this.yearMin,
    required this.yearMax,
    required this.retrievedAtUtc,
  });

  final String sha256;
  final int sizeBytes;
  final int rowCount;
  final int uniqueMakeCount;
  final int yearMin;
  final int yearMax;
  final DateTime retrievedAtUtc;

  static _Manifest parse(String manifestJson) {
    final Object? decoded = jsonDecode(manifestJson);
    final root = _stringMap(decoded, 'manifest');
    if (root['schema_version'] != 2) {
      throw const UsVehicleCatalogException(
        'unsupported vehicle catalog schema version',
      );
    }
    final coverage = _stringMap(root['coverage'], 'coverage');
    if (root['dataset'] !=
            'U.S. EPA FuelEconomy.gov Find-a-Car vehicle configurations' ||
        coverage['market'] != 'United States' ||
        coverage['vehicle_scope'] !=
            'FuelEconomy.gov Find-a-Car configurations') {
      throw const UsVehicleCatalogException(
        'manifest does not identify the U.S. EPA catalog scope',
      );
    }

    final source = _stringMap(root['source'], 'source');
    if (source['archive_url'] !=
            'https://www.fueleconomy.gov/feg/epadata/vehicles.csv.zip' ||
        source['landing_page'] !=
            'https://www.fueleconomy.gov/feg/download.shtml') {
      throw const UsVehicleCatalogException(
        'manifest source URLs do not identify the official EPA download',
      );
    }
    final sourceHash = _requiredString(source['sha256'], 'source.sha256');
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sourceHash)) {
      throw const UsVehicleCatalogException(
        'source.sha256 is not a lowercase SHA-256 digest',
      );
    }
    final retrievedText = _requiredString(
      source['retrieved_at_utc'],
      'source.retrieved_at_utc',
    );
    final retrievedAt = DateTime.tryParse(retrievedText);
    if (retrievedAt == null || !retrievedAt.isUtc) {
      throw const UsVehicleCatalogException(
        'source.retrieved_at_utc must be an ISO-8601 UTC timestamp',
      );
    }

    final output = _stringMap(root['output'], 'output');
    if (output['file'] != 'us_epa_vehicles.csv') {
      throw const UsVehicleCatalogException('unexpected catalog output file');
    }
    final rawColumns = output['columns'];
    if (rawColumns is! List<Object?> ||
        !_sameStrings(
          rawColumns.map((value) => value.toString()).toList(),
          UsVehicleCatalog.requiredColumns,
        )) {
      throw const UsVehicleCatalogException(
        'manifest columns do not match schema version 2',
      );
    }
    final hash = _requiredString(output['sha256'], 'output.sha256');
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw const UsVehicleCatalogException(
        'output.sha256 is not a lowercase SHA-256 digest',
      );
    }

    return _Manifest(
      sha256: hash,
      sizeBytes: _positiveJsonInt(output['size_bytes'], 'output.size_bytes'),
      rowCount: _positiveJsonInt(output['row_count'], 'output.row_count'),
      uniqueMakeCount: _positiveJsonInt(
        output['unique_make_count'],
        'output.unique_make_count',
      ),
      yearMin: _positiveJsonInt(output['year_min'], 'output.year_min'),
      yearMax: _positiveJsonInt(output['year_max'], 'output.year_max'),
      retrievedAtUtc: retrievedAt,
    );
  }
}

Map<String, Object?> _stringMap(Object? value, String name) {
  if (value is! Map<String, Object?>) {
    throw UsVehicleCatalogException('$name must be a JSON object');
  }
  return value;
}

String _requiredString(Object? value, String name) {
  if (value is! String || value.trim().isEmpty) {
    throw UsVehicleCatalogException('$name must be a non-empty string');
  }
  return value;
}

int _positiveJsonInt(Object? value, String name) {
  if (value is! int || value <= 0) {
    throw UsVehicleCatalogException('$name must be a positive integer');
  }
  return value;
}

int _positiveInt(String value, String name, int rowNumber) {
  final parsed = int.tryParse(value);
  if (parsed == null || parsed <= 0 || parsed.toString() != value) {
    throw UsVehicleCatalogException(
      'catalog row $rowNumber has an invalid $name',
    );
  }
  return parsed;
}

int? _optionalPositiveInt(String value, String name, int rowNumber) {
  if (value.isEmpty || value == 'NA') return null;
  return _positiveInt(value, name, rowNumber);
}

double? _optionalPositiveDouble(String value, String name, int rowNumber) {
  if (value.isEmpty || value == 'NA' || value == '0') return null;
  final parsed = double.tryParse(value);
  if (parsed == null || !parsed.isFinite || parsed <= 0) {
    throw UsVehicleCatalogException(
      'catalog row $rowNumber has an invalid $name',
    );
  }
  return parsed;
}

bool _sameStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

// SHA-256 is kept here rather than importing `package:crypto`, which is only a
// transitive dependency of this application. This keeps the offline catalog
// verifier self-contained and avoids silently relying on another package's
// dependency graph.
String _sha256Hex(List<int> input) {
  const initial = <int>[
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ];
  const constants = <int>[
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];
  const mask = 0xffffffff;
  int rotateRight(int value, int count) =>
      ((value >>> count) | (value << (32 - count))) & mask;

  final bytes = List<int>.of(input)..add(0x80);
  while (bytes.length % 64 != 56) {
    bytes.add(0);
  }
  final bitLength = input.length * 8;
  for (var shift = 56; shift >= 0; shift -= 8) {
    bytes.add((bitLength >>> shift) & 0xff);
  }

  final hash = List<int>.of(initial);
  final words = List<int>.filled(64, 0);
  for (var offset = 0; offset < bytes.length; offset += 64) {
    for (var index = 0; index < 16; index++) {
      final start = offset + index * 4;
      words[index] =
          (bytes[start] << 24) |
          (bytes[start + 1] << 16) |
          (bytes[start + 2] << 8) |
          bytes[start + 3];
    }
    for (var index = 16; index < 64; index++) {
      final s0 =
          rotateRight(words[index - 15], 7) ^
          rotateRight(words[index - 15], 18) ^
          (words[index - 15] >>> 3);
      final s1 =
          rotateRight(words[index - 2], 17) ^
          rotateRight(words[index - 2], 19) ^
          (words[index - 2] >>> 10);
      words[index] = (words[index - 16] + s0 + words[index - 7] + s1) & mask;
    }

    var a = hash[0];
    var b = hash[1];
    var c = hash[2];
    var d = hash[3];
    var e = hash[4];
    var f = hash[5];
    var g = hash[6];
    var h = hash[7];
    for (var index = 0; index < 64; index++) {
      final sum1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25);
      final choose = (e & f) ^ ((~e) & g);
      final temp1 =
          (h + sum1 + choose + constants[index] + words[index]) & mask;
      final sum0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22);
      final majority = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (sum0 + majority) & mask;
      h = g;
      g = f;
      f = e;
      e = (d + temp1) & mask;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & mask;
    }
    hash[0] = (hash[0] + a) & mask;
    hash[1] = (hash[1] + b) & mask;
    hash[2] = (hash[2] + c) & mask;
    hash[3] = (hash[3] + d) & mask;
    hash[4] = (hash[4] + e) & mask;
    hash[5] = (hash[5] + f) & mask;
    hash[6] = (hash[6] + g) & mask;
    hash[7] = (hash[7] + h) & mask;
  }
  return hash.map((value) => value.toRadixString(16).padLeft(8, '0')).join();
}
