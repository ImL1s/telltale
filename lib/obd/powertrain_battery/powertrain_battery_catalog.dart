/// Hash-checked loader for the bundled powertrain battery research catalog.
library;

import 'dart:convert';

import 'package:flutter/services.dart';

import 'powertrain_battery_profile.dart';
import 'profile_catalog_validator.dart';

final class PowertrainBatteryCatalogAsset {
  static const String catalogAsset =
      'assets/powertrain_battery/powertrain_battery_catalog.json';
  static const String manifestAsset =
      'assets/powertrain_battery/powertrain_battery_catalog.manifest.json';

  const PowertrainBatteryCatalogAsset._();

  static Future<PowertrainBatteryCatalogSnapshot> load([
    AssetBundle? bundle,
  ]) async {
    final assets = bundle ?? rootBundle;
    try {
      final values = await Future.wait([
        assets.loadString(manifestAsset),
        assets.loadString(catalogAsset),
      ]);
      return fromStrings(manifestJson: values[0], catalogJson: values[1]);
    } on PowertrainBatteryCatalogAssetException {
      rethrow;
    } catch (error) {
      throw PowertrainBatteryCatalogAssetException(
        'cannot load bundled powertrain battery catalog: $error',
      );
    }
  }

  static PowertrainBatteryCatalogSnapshot fromStrings({
    required String manifestJson,
    required String catalogJson,
  }) {
    try {
      final manifest = _PowertrainBatteryCatalogManifest.parse(manifestJson);
      final bytes = utf8.encode(catalogJson);
      if (_sha256Hex(bytes) != manifest.sha256) {
        throw const PowertrainBatteryCatalogAssetException(
          'catalog SHA-256 does not match its manifest',
        );
      }
      if (bytes.length != manifest.sizeBytes) {
        throw const PowertrainBatteryCatalogAssetException(
          'catalog byte size does not match its manifest',
        );
      }

      final catalog = PowertrainBatteryCatalog.fromJsonString(catalogJson);
      const validator = PowertrainBatteryProfileCatalogValidator();
      final validation = validator.validateCatalog(catalog);
      if (!validation.isValid) {
        throw PowertrainBatteryCatalogAssetException(
          'catalog validation failed: ${validation.issues.first}',
        );
      }

      final profileCount = catalog.profiles.length;
      final signalCount = catalog.profiles.fold<int>(
        0,
        (total, profile) =>
            total +
            profile.commands.fold<int>(
              0,
              (commandTotal, command) => commandTotal + command.signals.length,
            ),
      );
      final countsByPowertrain = <String, int>{};
      for (final profile in catalog.profiles) {
        countsByPowertrain.update(
          profile.powertrain,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      }
      if (profileCount != manifest.profileCount ||
          signalCount != manifest.signalCount ||
          !_sameCounts(countsByPowertrain, manifest.countsByPowertrain)) {
        throw const PowertrainBatteryCatalogAssetException(
          'catalog statistics do not match its manifest',
        );
      }

      return PowertrainBatteryCatalogSnapshot._(
        catalog: catalog,
        catalogSha256: manifest.sha256,
        profileCount: profileCount,
        signalCount: signalCount,
        countsByPowertrain: countsByPowertrain,
      );
    } on PowertrainBatteryCatalogAssetException {
      rethrow;
    } on PowertrainBatteryProfileFormatException catch (error) {
      throw PowertrainBatteryCatalogAssetException(error.message);
    } on FormatException catch (error) {
      throw PowertrainBatteryCatalogAssetException(
        'manifest is not valid JSON: ${error.message}',
      );
    } catch (error) {
      throw PowertrainBatteryCatalogAssetException(
        'invalid bundled powertrain battery catalog: $error',
      );
    }
  }
}

final class PowertrainBatteryCatalogSnapshot {
  PowertrainBatteryCatalogSnapshot._({
    required this.catalog,
    required this.catalogSha256,
    required this.profileCount,
    required this.signalCount,
    required Map<String, int> countsByPowertrain,
  }) : countsByPowertrain = Map.unmodifiable(countsByPowertrain);

  final PowertrainBatteryCatalog catalog;
  final String catalogSha256;
  final int profileCount;
  final int signalCount;
  final Map<String, int> countsByPowertrain;
}

final class PowertrainBatteryCatalogAssetException implements Exception {
  const PowertrainBatteryCatalogAssetException(this.message);

  final String message;

  @override
  String toString() => 'PowertrainBatteryCatalogAssetException: $message';
}

final class _PowertrainBatteryCatalogManifest {
  const _PowertrainBatteryCatalogManifest({
    required this.sha256,
    required this.sizeBytes,
    required this.profileCount,
    required this.signalCount,
    required this.countsByPowertrain,
  });

  final String sha256;
  final int sizeBytes;
  final int profileCount;
  final int signalCount;
  final Map<String, int> countsByPowertrain;

  static _PowertrainBatteryCatalogManifest parse(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const PowertrainBatteryCatalogAssetException(
        'manifest must be a JSON object',
      );
    }
    final json = decoded.cast<String, Object?>();
    final schemaVersion = _integer(json['schema_version'], 'schema_version');
    if (schemaVersion != PowertrainBatteryCatalog.supportedSchemaVersion) {
      throw PowertrainBatteryCatalogAssetException(
        'unsupported manifest schema_version $schemaVersion',
      );
    }
    if (json['catalog_file'] != 'powertrain_battery_catalog.json') {
      throw const PowertrainBatteryCatalogAssetException(
        'manifest catalog_file is not the bundled catalog',
      );
    }
    final sha256 = _string(json['sha256'], 'sha256');
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      throw const PowertrainBatteryCatalogAssetException(
        'manifest sha256 is not a lowercase digest',
      );
    }
    final countsValue = json['counts_by_powertrain'];
    if (countsValue is! Map) {
      throw const PowertrainBatteryCatalogAssetException(
        'counts_by_powertrain must be an object',
      );
    }
    final counts = <String, int>{};
    for (final entry in countsValue.entries) {
      if (entry.key is! String ||
          entry.value is! int ||
          entry.value as int < 0) {
        throw const PowertrainBatteryCatalogAssetException(
          'counts_by_powertrain contains an invalid entry',
        );
      }
      counts[entry.key as String] = entry.value as int;
    }
    return _PowertrainBatteryCatalogManifest(
      sha256: sha256,
      sizeBytes: _nonNegativeInteger(json['size_bytes'], 'size_bytes'),
      profileCount: _nonNegativeInteger(json['profile_count'], 'profile_count'),
      signalCount: _nonNegativeInteger(json['signal_count'], 'signal_count'),
      countsByPowertrain: Map.unmodifiable(counts),
    );
  }
}

String _string(Object? value, String path) {
  if (value is! String || value.isEmpty) {
    throw PowertrainBatteryCatalogAssetException('$path must be a string');
  }
  return value;
}

int _integer(Object? value, String path) {
  if (value is! int) {
    throw PowertrainBatteryCatalogAssetException('$path must be an integer');
  }
  return value;
}

int _nonNegativeInteger(Object? value, String path) {
  final integer = _integer(value, path);
  if (integer < 0) {
    throw PowertrainBatteryCatalogAssetException('$path must be non-negative');
  }
  return integer;
}

bool _sameCounts(Map<String, int> left, Map<String, int> right) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) return false;
  }
  return true;
}

// Self-contained SHA-256 avoids adding a runtime dependency solely for the
// checked-in catalog integrity gate.
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
