import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/core/hash/fnv1a64.dart';
import 'package:torque_obd/core/share/app_share_cache.dart';
import 'package:torque_obd/core/share/share_lease_ledger.dart';

void main() {
  test(
    'write-ahead ledger transitions allocated then handed-off lease',
    () async {
      final dir = Directory.systemTemp.createTempSync('share-ledger');
      addTearDown(() => dir.deleteSync(recursive: true));
      final ledger = ShareLeaseLedger(dir);
      final allocated = ShareLeaseRecord.allocated(
        id: '0123456789abcdef0123456789abcdef',
        sourceKind: ShareSourceKind.pidCsv,
        createdAtUtc: DateTime.utc(2026),
      );
      await ledger.install(allocated);
      expect(
        (await ledger.read(allocated.id))!.state,
        ShareLeaseState.allocated,
      );
      final handed = allocated.handedOff(
        bytes: 12,
        fingerprint: 'fnv1a64:0123456789abcdef',
        atUtc: DateTime.utc(2026, 1, 1, 0, 1),
      );
      await ledger.transition(expected: allocated, next: handed);
      final restored = await ledger.read(allocated.id);
      expect(restored!.state, ShareLeaseState.handedOffLease);
      expect(restored.cleanupEligibleAtUtc, DateTime.utc(2026, 1, 1, 0, 16));
      expect(restored.cleanupDueAtUtc, DateTime.utc(2026, 1, 2, 0, 1));
    },
  );

  test('corrupt staging blocks reconstruction and admission', () async {
    final dir = Directory.systemTemp.createTempSync('share-corrupt');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/cccccccccccccccccccccccccccccccc.lease.json')
        .writeAsStringSync('{bad');
    await expectLater(
      AppShareCache(dir).reconstructAndClean(DateTime.utc(2026)),
      throwsA(isA<FileSystemException>()),
    );
  });

  test(
    'missing handed-off source is recognized OS eviction and is cleaned',
    () async {
      final dir = Directory.systemTemp.createTempSync('share-missing');
      addTearDown(() => dir.deleteSync(recursive: true));
      final ledger = ShareLeaseLedger(dir);
      final record =
          ShareLeaseRecord.allocated(
            id: 'dddddddddddddddddddddddddddddddd',
            sourceKind: ShareSourceKind.pidCsv,
            createdAtUtc: DateTime.utc(2026),
          ).handedOff(
            bytes: 1,
            fingerprint: 'fnv1a64:af63bc4c8601b62c',
            atUtc: DateTime.utc(2026),
          );
      await ledger.install(record);
      expect(
        await AppShareCache(dir).reconstructAndClean(DateTime.utc(2026)),
        isEmpty,
      );
      expect(await ledger.read(record.id), isNull);
    },
  );

  test('fresh root cleans a durable allocated ledger temp residue', () async {
    final dir = Directory.systemTemp.createTempSync('share-allocated-temp');
    addTearDown(() => dir.deleteSync(recursive: true));
    const id = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
    final record = ShareLeaseRecord.allocated(
      id: id,
      sourceKind: ShareSourceKind.rawTranscript,
      createdAtUtc: DateTime.utc(2026),
    );
    final installed = ShareLeaseLedger.encode(record);
    File('${dir.path}/$id.lease.json.tmp').writeAsBytesSync(installed);
    File('${dir.path}/${record.sourceFileName}').writeAsBytesSync([1, 2, 3]);

    expect(
      await AppShareCache(dir).reconstructAndClean(DateTime.utc(2026)),
      isEmpty,
    );
    expect(dir.listSync(), isEmpty);
  });

  test(
    'valid result-update temp is removed without losing handed-off lease',
    () async {
      final dir = Directory.systemTemp.createTempSync('share-result-temp');
      addTearDown(() => dir.deleteSync(recursive: true));
      const id = 'ffffffffffffffffffffffffffffffff';
      final bytes = [1, 2, 3];
      final hash = Fnv1a64()..add(bytes);
      final handed =
          ShareLeaseRecord.allocated(
            id: id,
            sourceKind: ShareSourceKind.pidCsv,
            createdAtUtc: DateTime.utc(2026),
          ).handedOff(
            bytes: bytes.length,
            fingerprint: hash.fingerprint,
            atUtc: DateTime.utc(2026),
          );
      final ledger = ShareLeaseLedger(dir);
      await ledger.install(handed);
      File('${dir.path}/$id.lease.json.tmp').writeAsBytesSync(
        ShareLeaseLedger.encode(
          handed.withResult('selected', DateTime.utc(2026, 1, 1, 0, 1)),
        ),
      );
      File('${dir.path}/${handed.sourceFileName}').writeAsBytesSync(bytes);

      final restored = await AppShareCache(dir)
          .reconstructAndClean(DateTime.utc(2026, 1, 1, 0, 2));
      expect(restored, hasLength(1));
      expect(File('${dir.path}/$id.lease.json.tmp').existsSync(), isFalse);
      expect((await ledger.read(id))!.state, ShareLeaseState.handedOffLease);
    },
  );

  test(
    'corrupt, symlink, and near-match temp residue remain blocked',
    () async {
      for (final fixture in ['corrupt', 'symlink', 'near-match']) {
        final dir = Directory.systemTemp.createTempSync('share-$fixture');
        addTearDown(() => dir.deleteSync(recursive: true));
        const id = 'abababababababababababababababab';
        if (fixture == 'corrupt') {
          File('${dir.path}/$id.lease.json.tmp').writeAsStringSync('{bad');
        } else if (fixture == 'symlink') {
          final target = File('${dir.path}/target')..writeAsStringSync('{}');
          Link('${dir.path}/$id.lease.json.tmp').createSync(target.path);
        } else {
          File('${dir.path}/$id.lease.json.tmp.bak').writeAsStringSync('{}');
        }
        await expectLater(
          AppShareCache(dir).reconstructAndClean(DateTime.utc(2026)),
          throwsA(isA<FileSystemException>()),
        );
      }
    },
  );

  test(
    'interrupted corrupt temp beside valid main ledger is discarded',
    () async {
      final dir = Directory.systemTemp.createTempSync('share-interrupted-tmp');
      addTearDown(() => dir.deleteSync(recursive: true));
      const id = 'acacacacacacacacacacacacacacacac';
      final bytes = [9, 8, 7];
      final hash = Fnv1a64()..add(bytes);
      final handed =
          ShareLeaseRecord.allocated(
            id: id,
            sourceKind: ShareSourceKind.pidCsv,
            createdAtUtc: DateTime.utc(2026),
          ).handedOff(
            bytes: bytes.length,
            fingerprint: hash.fingerprint,
            atUtc: DateTime.utc(2026),
          );
      final ledger = ShareLeaseLedger(dir);
      await ledger.install(handed);
      File('${dir.path}/${handed.sourceFileName}').writeAsBytesSync(bytes);
      // Crash mid-transition: `.tmp` created/partially written, rename never
      // committed. Installed main remains the authority.
      File('${dir.path}/$id.lease.json.tmp').writeAsStringSync('{partial');

      final restored = await AppShareCache(dir)
          .reconstructAndClean(DateTime.utc(2026, 1, 1, 0, 2));
      expect(restored, hasLength(1));
      expect(File('${dir.path}/$id.lease.json.tmp').existsSync(), isFalse);
      expect((await ledger.read(id))!.state, ShareLeaseState.handedOffLease);
    },
  );

  test(
    'symlink temp beside valid main ledger still blocks',
    () async {
      final dir = Directory.systemTemp.createTempSync('share-symlink-main');
      addTearDown(() => dir.deleteSync(recursive: true));
      const id = 'adadadadadadadadadadadadadadadad';
      final bytes = [4, 5, 6];
      final hash = Fnv1a64()..add(bytes);
      final handed =
          ShareLeaseRecord.allocated(
            id: id,
            sourceKind: ShareSourceKind.pidCsv,
            createdAtUtc: DateTime.utc(2026),
          ).handedOff(
            bytes: bytes.length,
            fingerprint: hash.fingerprint,
            atUtc: DateTime.utc(2026),
          );
      await ShareLeaseLedger(dir).install(handed);
      File('${dir.path}/${handed.sourceFileName}').writeAsBytesSync(bytes);
      final target = File('${dir.path}/target')..writeAsStringSync('{}');
      Link('${dir.path}/$id.lease.json.tmp').createSync(target.path);

      await expectLater(
        AppShareCache(dir).reconstructAndClean(DateTime.utc(2026, 1, 1, 0, 2)),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test(
    'strict ledger rejects unknown keys and invalid handed-off metadata',
    () {
      final allocated = ShareLeaseRecord.allocated(
        id: '12121212121212121212121212121212',
        sourceKind: ShareSourceKind.pidCsv,
        createdAtUtc: DateTime.utc(2026),
      ).toJson();
      expect(
        ShareLeaseRecord.fromJson({...allocated, 'private': 'leak'}),
        isNull,
      );
      final handed = ShareLeaseRecord.fromJson({
        ...allocated,
        'state': ShareLeaseState.handedOffLease.name,
        'bytes': 1,
        'fingerprint': 'sha256:not-allowed',
        'handedOffAtUtc': DateTime.utc(2026).toIso8601String(),
        'cleanupEligibleAtUtc': DateTime.utc(
          2026,
          1,
          1,
          0,
          15,
        ).toIso8601String(),
        'cleanupDueAtUtc': DateTime.utc(2026, 1, 2).toIso8601String(),
        'result': 'delivered',
      });
      expect(handed, isNull);
    },
  );

  test('create-only install and transition reject changed state', () async {
    final dir = Directory.systemTemp.createTempSync('share-create-only');
    addTearDown(() => dir.deleteSync(recursive: true));
    final ledger = ShareLeaseLedger(dir);
    final allocated = ShareLeaseRecord.allocated(
      id: '34343434343434343434343434343434',
      sourceKind: ShareSourceKind.pidCsv,
      createdAtUtc: DateTime.utc(2026),
    );
    await ledger.install(allocated);
    final file = File('${dir.path}/${allocated.ledgerFileName}');
    final before = file.readAsBytesSync();

    await expectLater(
      ledger.install(allocated),
      throwsA(isA<FileSystemException>()),
    );
    expect(file.readAsBytesSync(), before);

    final changedKind =
        ShareLeaseRecord.allocated(
          id: allocated.id,
          sourceKind: ShareSourceKind.telemetryCsv,
          createdAtUtc: allocated.createdAtUtc,
        ).handedOff(
          bytes: 1,
          fingerprint: 'fnv1a64:af63bc4c8601b62c',
          atUtc: DateTime.utc(2026, 1, 1, 0, 1),
        );
    await expectLater(
      ledger.transition(expected: allocated, next: changedKind),
      throwsA(isA<FileSystemException>()),
    );
    expect(file.readAsBytesSync(), before);
  });
}
