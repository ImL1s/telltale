/// Builds verified in-memory catalog snapshots for tests.
///
/// Install and authorize accept only a [PowertrainBatteryCatalogSnapshot],
/// and its constructor is private on purpose — the sole way in is
/// [PowertrainBatteryCatalogAsset.fromStrings], which runs the manifest
/// SHA-256 check and full catalog validation. Tests therefore build real
/// snapshots through the same gate instead of bypassing it: a fixture that
/// stops validating fails the test, which is the point.
library;

import 'dart:convert';

import 'package:torque_obd/obd/powertrain_battery/powertrain_battery_catalog.dart';

PowertrainBatteryCatalogSnapshot snapshotOfProfiles(
  List<Map<String, Object?>> profiles,
) {
  final catalogJson = jsonEncode({'schema_version': 3, 'profiles': profiles});
  final bytes = utf8.encode(catalogJson);
  final counts = <String, int>{};
  var signals = 0;
  for (final profile in profiles) {
    final powertrain = profile['powertrain'] as String;
    counts[powertrain] = (counts[powertrain] ?? 0) + 1;
    for (final command
        in (profile['commands'] as List<Object?>? ?? const <Object?>[])) {
      signals += ((command as Map<String, Object?>)['signals']! as List).length;
    }
  }
  final manifestJson = jsonEncode({
    'schema_version': 3,
    'catalog_file': 'powertrain_battery_catalog.json',
    'sha256': PowertrainBatteryCatalogAsset.sha256Hex(bytes),
    'size_bytes': bytes.length,
    'profile_count': profiles.length,
    'signal_count': signals,
    'counts_by_powertrain': counts,
  });
  return PowertrainBatteryCatalogAsset.fromStrings(
    manifestJson: manifestJson,
    catalogJson: catalogJson,
  );
}
