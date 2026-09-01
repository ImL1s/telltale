import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins that every multiplatform claim still has a harness file in the tree.
/// This is not field evidence — it fails closed if a documented runner is
/// deleted while platform-support.md keeps advertising it.
void main() {
  test('harness catalog files exist and entries are well-formed', () {
    final catalogFile = File('docs/verification/harness-catalog.json');
    expect(catalogFile.existsSync(), isTrue, reason: catalogFile.path);

    final decoded = jsonDecode(catalogFile.readAsStringSync());
    expect(decoded, isA<Map<String, Object?>>());
    final catalog = decoded as Map<String, Object?>;
    final entries = catalog['entries'];
    expect(entries, isA<List<Object?>>());
    final list = List<Map<String, Object?>>.from(
      (entries! as List<Object?>).map(
        (row) => Map<String, Object?>.from(row! as Map),
      ),
    );
    expect(list, isNotEmpty);

    final ids = <String>{};
    for (final entry in list) {
      final id = entry['id'] as String?;
      expect(id, isNotEmpty, reason: 'entry missing id');
      expect(ids.add(id!), isTrue, reason: 'duplicate harness id $id');
      expect(entry['claim'], isA<String>());
      expect((entry['claim'] as String).trim(), isNotEmpty);
      expect(entry['ci'], isA<String>());
      expect(entry['hardware'], isA<bool>());

      final files = List<String>.from(entry['files']! as List<Object?>);
      expect(files, isNotEmpty, reason: id);
      for (final relative in files) {
        expect(relative, isNot(startsWith('/')), reason: relative);
        expect(relative, isNot(contains('..')), reason: relative);
        final path = File(relative);
        expect(path.existsSync(), isTrue, reason: '$id missing $relative');
      }
    }

    final requiredIds = {
      'demo-telemetry',
      'wifi-tcp',
      'ble',
      'classic-spp',
      'share-export',
      'packaging-unsigned',
    };
    expect(ids, containsAll(requiredIds));
  });
}
