import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/telemetry_share_crash_rig_test.dart';

void main() {
  const token = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  late List<Map<String, Object?>> fixtures;

  setUpAll(() {
    final result = Process.runSync('python3', <String>[
      'tool/telemetry_memory_rig/emit_restore_manifest_fixtures.py',
    ]);
    expect(
      result.exitCode,
      0,
      reason: 'host fixture generator failed: ${result.stderr}',
    );
    fixtures = (jsonDecode(result.stdout as String) as List<Object?>)
        .map((item) => Map<String, Object?>.from(item! as Map))
        .toList(growable: false);
    expect(fixtures, hasLength(7));
  });

  Map<String, Object?> manifestFor(String cut) {
    final fixture = fixtures.singleWhere((item) => item['cut'] == cut);
    return Map<String, Object?>.from(fixture['manifest']! as Map);
  }

  test('host manifest schema and all seven cut semantics parse exactly', () {
    for (final fixture in fixtures) {
      final cut = fixture['cut']! as String;
      expect(
        () => validateGateCRestoreManifestForTest(
          value: manifestFor(cut),
          runToken: token,
          cut: cut,
        ),
        returnsNormally,
        reason: cut,
      );
    }
  });

  test('semantic, timing, missing, and extra fields fail closed', () {
    final pending = manifestFor('pendingResult');
    for (final changed in <Map<String, Object?>>[
      {...pending, 'platformSemantic': 'nonCompletablePending'},
      {...pending, 'pendingObservationMs': 1999},
      {...pending}..remove('platformCalls'),
      {...pending, 'extra': true},
    ]) {
      expect(
        () => validateGateCRestoreManifestForTest(
          value: changed,
          runToken: token,
          cut: 'pendingResult',
        ),
        throwsFormatException,
      );
    }
  });
}
