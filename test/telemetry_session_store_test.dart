import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_codec.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_store.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('telemetry_store_test_');
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('uses only telltale-telemetry and exclusive 32-hex ids', () async {
    final ids = <String>['a' * 32, 'b' * 32].iterator;
    final store = TelemetrySessionStore(
      documentsDirectory: () async => root,
      idSource: () {
        ids.moveNext();
        return ids.current;
      },
    );
    final telemetry = Directory('${root.path}/telltale-telemetry');
    await telemetry.create();
    await File('${telemetry.path}/${'a' * 32}.ndjson.part')
        .writeAsString('owned');

    final created = await store.createStaging(
      headerLineForId: _headerLine,
      minimalValueLineBytes: 3,
    );

    expect(created.outcome, TelemetryCreateOutcome.created);
    expect(created.sessionId, 'b' * 32);
    expect(await File('${root.path}/last-session.log').exists(), isFalse);
    expect(created.file!.path, endsWith('${'b' * 32}.ndjson.part'));
  });

  test('eight collisions fail without overwriting either artifact', () async {
    final id = 'c' * 32;
    final store = TelemetrySessionStore(
      documentsDirectory: () async => root,
      idSource: () => id,
    );
    final telemetry = Directory('${root.path}/telltale-telemetry');
    await telemetry.create();
    final existing = File('${telemetry.path}/$id.ndjson')
      ..writeAsStringSync('keep');

    final result = await store.createStaging(
      headerLineForId: _headerLine,
      minimalValueLineBytes: 3,
    );

    expect(result.outcome, TelemetryCreateOutcome.idCollision);
    expect(await existing.readAsString(), 'keep');
    expect(telemetry.listSync(), hasLength(1));
  });

  test('install refuses destination collision and preserves part', () async {
    final id = 'd' * 32;
    final telemetry = Directory('${root.path}/telltale-telemetry')
      ..createSync();
    final part = File('${telemetry.path}/$id.ndjson.part')
      ..writeAsStringSync('part');
    final finalFile = File('${telemetry.path}/$id.ndjson')
      ..writeAsStringSync('final');
    final store = TelemetrySessionStore(documentsDirectory: () async => root);

    expect(await store.install(id), TelemetryInstallOutcome.destinationExists);
    expect(await part.readAsString(), 'part');
    expect(await finalFile.readAsString(), 'final');
  });

  test(
    'delete validates opaque id and removes only recognized group',
    () async {
      final id = 'e' * 32;
      final telemetry = Directory('${root.path}/telltale-telemetry')
        ..createSync();
      File('${telemetry.path}/$id.ndjson').writeAsStringSync('a');
      File('${telemetry.path}/$id.ndjson.part').writeAsStringSync('b');
      final unrelated = File('${root.path}/last-session.log')
        ..writeAsStringSync('keep');
      final store = TelemetrySessionStore(documentsDirectory: () async => root);

      expect(
        await store.deleteGroup('../$id'),
        TelemetryDeleteOutcome.invalidId,
      );
      expect(await store.deleteGroup(id), TelemetryDeleteOutcome.deleted);
      expect(await unrelated.readAsString(), 'keep');
      expect(telemetry.listSync(), isEmpty);
    },
  );

  test(
    'deleteStaging never deletes final and rejects non-regular part',
    () async {
      final id = 'f' * 32;
      final telemetry = Directory('${root.path}/telltale-telemetry')
        ..createSync();
      final finalFile = File('${telemetry.path}/$id.ndjson')
        ..writeAsStringSync('final');
      final part = File('${telemetry.path}/$id.ndjson.part')
        ..writeAsStringSync('part');
      final store = TelemetrySessionStore(documentsDirectory: () async => root);

      expect(await store.deleteStaging(id), TelemetryDeleteOutcome.deleted);
      expect(await part.exists(), isFalse);
      expect(await finalFile.readAsString(), 'final');

      await Link(part.path).create(finalFile.path);
      expect(
        await store.deleteStaging(id),
        TelemetryDeleteOutcome.storageError,
      );
      expect(await Link(part.path).exists(), isTrue);
      expect(await finalFile.readAsString(), 'final');
    },
  );

  for (final failure in const <String>['open', 'write', 'flush']) {
    test(
      '$failure failure cleans exact exclusive part before storageError',
      () async {
        final io = _FailingExclusiveCreateIo(failureAt: failure);
        final store = TelemetrySessionStore(
          documentsDirectory: () async => root,
          idSource: () => '9' * 32,
          exclusiveCreateIo: io,
        );

        final result = await store.createStaging(
          headerLineForId: _headerLine,
          minimalValueLineBytes: 3,
        );

        expect(result.outcome, TelemetryCreateOutcome.storageError);
        expect(io.type, FileSystemEntityType.notFound);
        expect(io.deleted, isTrue);
        if (failure != 'open') expect(io.closeCalls, 1);
      },
    );
  }

  test('close failure after exclusive create is uncontained', () async {
    final io = _FailingExclusiveCreateIo(failureAt: 'close');
    final store = TelemetrySessionStore(
      documentsDirectory: () async => root,
      idSource: () => '8' * 32,
      exclusiveCreateIo: io,
    );

    final result = await store.createStaging(
      headerLineForId: _headerLine,
      minimalValueLineBytes: 3,
    );

    expect(result.outcome, TelemetryCreateOutcome.uncontainedFailure);
    expect(io.type, FileSystemEntityType.file);
    expect(io.deleted, isFalse);
  });

  test(
    'create-then-throw is uncontained rather than an id collision',
    () async {
      final io = _FailingExclusiveCreateIo(failureAt: 'create');
      final store = TelemetrySessionStore(
        documentsDirectory: () async => root,
        idSource: () => '6' * 32,
        exclusiveCreateIo: io,
      );

      final result = await store.createStaging(
        headerLineForId: _headerLine,
        minimalValueLineBytes: 3,
      );

      expect(result.outcome, TelemetryCreateOutcome.uncontainedFailure);
      expect(io.type, FileSystemEntityType.file);
      expect(io.deleted, isFalse);
    },
  );

  test('never-completing exclusive create never reports a collision', () async {
    final io = _FailingExclusiveCreateIo(failureAt: 'neverCreate');
    final store = TelemetrySessionStore(
      documentsDirectory: () async => root,
      idSource: () => '5' * 32,
      exclusiveCreateIo: io,
    );

    final future = store.createStaging(
      headerLineForId: _headerLine,
      minimalValueLineBytes: 3,
    );

    expect(await _completesSoon(future), isFalse);
    expect(io.type, FileSystemEntityType.notFound);
  });

  test('checkpoint invalidation after create deletes the exact part', () async {
    final io = _FailingExclusiveCreateIo(failureAt: 'none');
    final store = TelemetrySessionStore(
      documentsDirectory: () async => root,
      idSource: () => '4' * 32,
      exclusiveCreateIo: io,
    );

    await expectLater(
      store.createStaging(
        headerLineForId: _headerLine,
        minimalValueLineBytes: 3,
        checkpoint: (checkpoint) {
          if (checkpoint == 'store.afterExclusiveCreate.0') {
            throw StateError('revoked');
          }
        },
      ),
      throwsStateError,
    );
    expect(io.type, FileSystemEntityType.notFound);
    expect(io.deleted, isTrue);
  });

  test('never-completing cleanup never reports a releasable failure', () async {
    final io = _FailingExclusiveCreateIo(failureAt: 'open', neverDelete: true);
    final store = TelemetrySessionStore(
      documentsDirectory: () async => root,
      idSource: () => '7' * 32,
      exclusiveCreateIo: io,
    );

    final future = store.createStaging(
      headerLineForId: _headerLine,
      minimalValueLineBytes: 3,
    );

    expect(await _completesSoon(future), isFalse);
    expect(io.type, FileSystemEntityType.file);
  });

  test(
    'lists trusted starts and labels corrupt entries with file time',
    () async {
      final telemetry = Directory('${root.path}/telltale-telemetry')
        ..createSync();
      final oldId = '1' * 32;
      final newId = '2' * 32;
      final corruptId = '3' * 32;
      File('${telemetry.path}/$oldId.ndjson')
          .writeAsBytesSync(_completeSession(oldId, DateTime.utc(2026, 1, 1)));
      File('${telemetry.path}/$newId.ndjson')
          .writeAsBytesSync(_completeSession(newId, DateTime.utc(2026, 1, 2)));
      final corrupt = File('${telemetry.path}/$corruptId.ndjson')
        ..writeAsStringSync(
          '{"type":"header","schemaVersion":1,"sessionId":"$corruptId",'
          '"startedAtUtc":"2099-01-01T00:00:00.000Z"}\n',
        );
      final filesystemTime = DateTime.utc(2025, 4, 5);
      corrupt.setLastModifiedSync(filesystemTime);
      final store = TelemetrySessionStore(documentsDirectory: () async => root);

      final index = await store.listSessions();

      expect(index.sessions.map((entry) => entry.id), <String>[newId, oldId]);
      expect(index.damaged.single.id, corruptId);
      expect(index.damaged.single.filesystemModifiedAtUtc, filesystemTime);
    },
  );

  test(
    'finalized file whose header sessionId mismatches filename is damaged',
    () async {
      final telemetry = Directory('${root.path}/telltale-telemetry')
        ..createSync();
      final fileId = '4' * 32;
      final headerId = '5' * 32;
      File('${telemetry.path}/$fileId.ndjson').writeAsBytesSync(
        _completeSession(headerId, DateTime.utc(2026, 1, 3)),
      );
      final store = TelemetrySessionStore(documentsDirectory: () async => root);

      final index = await store.listSessions();

      expect(index.sessions, isEmpty);
      expect(index.damaged.single.id, fileId);
      expect(
        index.damaged.single.kind,
        DamagedTelemetryArtifactKind.corrupt,
      );
    },
  );

  test(
    'exact-name non-regular artifacts consume groups and are damaged',
    () async {
      final telemetry = Directory('${root.path}/telltale-telemetry')
        ..createSync();
      final directoryId = 'a' * 32;
      final linkId = 'b' * 32;
      Directory('${telemetry.path}/$directoryId.ndjson').createSync();
      final target = File('${root.path}/outside-target')
        ..writeAsStringSync('outside');
      await Link('${telemetry.path}/$linkId.ndjson.part').create(target.path);
      final store = TelemetrySessionStore(documentsDirectory: () async => root);

      final quota = await store.scanQuota();
      final index = await store.listSessions();
      final recovery = await store.inspectRecovery();
      final create = await store.createStaging(
        headerLineForId: _headerLine,
        minimalValueLineBytes: 3,
      );

      expect(quota.groupCount, 2);
      expect(
        quota.recognizedBytes,
        greaterThanOrEqualTo(TelemetryQuota.libraryByteLimit),
      );
      expect(quota.remainingLibraryBytes, 0);
      expect(create.outcome, TelemetryCreateOutcome.libraryByteLimit);
      expect(index.sessions, isEmpty);
      expect(index.damaged.map((entry) => entry.id), {directoryId, linkId});
      expect(recovery.items.single.id, linkId);
      expect(
        recovery.items.single.classification,
        TelemetryRecoveryClassification.corruptDeleteOnly,
      );
      expect(await target.readAsString(), 'outside');
    },
  );

  test('twenty exact-name directories cannot bypass the group quota', () async {
    final telemetry = Directory('${root.path}/telltale-telemetry')
      ..createSync();
    for (var index = 0; index < TelemetryQuota.groupLimit; index++) {
      final id = index.toRadixString(16).padLeft(32, '0');
      Directory('${telemetry.path}/$id.ndjson').createSync();
    }
    final store = TelemetrySessionStore(
      documentsDirectory: () async => root,
      idSource: () => 'f' * 32,
    );

    final created = await store.createStaging(
      headerLineForId: _headerLine,
      minimalValueLineBytes: 3,
    );

    expect(created.outcome, TelemetryCreateOutcome.libraryGroupLimit);
    expect(telemetry.listSync(followLinks: false), hasLength(20));
  });

  test(
    'group deletion unlinks exact symlink without touching its target',
    () async {
      final id = 'c' * 32;
      final telemetry = Directory('${root.path}/telltale-telemetry')
        ..createSync();
      final target = File('${root.path}/outside-target')
        ..writeAsStringSync('keep');
      final link = Link('${telemetry.path}/$id.ndjson')
        ..createSync(target.path);
      final store = TelemetrySessionStore(documentsDirectory: () async => root);

      expect(await store.deleteGroup(id), TelemetryDeleteOutcome.deleted);
      expect(await link.exists(), isFalse);
      expect(await target.readAsString(), 'keep');
    },
  );

  test(
    'deleteGroup removes staging before the installed session',
    () async {
      final id = 'a' * 32;
      final telemetry = Directory('${root.path}/telltale-telemetry')
        ..createSync();
      File('${telemetry.path}/$id.ndjson').writeAsStringSync('installed');
      File('${telemetry.path}/$id.ndjson.part').writeAsStringSync('staging');
      final store = TelemetrySessionStore(documentsDirectory: () async => root);
      final order = <String>[];

      expect(
        await store.deleteGroup(
          id,
          checkpoint: (checkpoint) {
            if (checkpoint.startsWith('delete.beforeDelete.')) {
              order.add(checkpoint);
            }
          },
        ),
        TelemetryDeleteOutcome.deleted,
      );
      expect(order, [
        'delete.beforeDelete..ndjson.part',
        'delete.beforeDelete..ndjson',
      ]);
      expect(telemetry.listSync(followLinks: false), isEmpty);
    },
  );

  test(
    'partial collision delete after staging leaves installed session intact',
    () async {
      final id = 'b' * 32;
      final telemetry = Directory('${root.path}/telltale-telemetry')
        ..createSync();
      final installed = File('${telemetry.path}/$id.ndjson')
        ..writeAsStringSync('installed');
      File('${telemetry.path}/$id.ndjson.part').writeAsStringSync('staging');
      final store = TelemetrySessionStore(documentsDirectory: () async => root);

      expect(
        await store.deleteGroup(
          id,
          checkpoint: (checkpoint) {
            if (checkpoint == 'delete.beforeDelete..ndjson') {
              throw StateError('cut after staging');
            }
          },
        ),
        TelemetryDeleteOutcome.uncontainedFailure,
      );
      expect(File('${telemetry.path}/$id.ndjson.part').existsSync(), isFalse);
      expect(await installed.readAsString(), 'installed');
    },
  );

  test('group deletion removes only an empty exact-name directory', () async {
    final emptyId = 'd' * 32;
    final nonemptyId = 'e' * 32;
    final telemetry = Directory('${root.path}/telltale-telemetry')
      ..createSync();
    final empty = Directory('${telemetry.path}/$emptyId.ndjson')..createSync();
    final nonempty = Directory('${telemetry.path}/$nonemptyId.ndjson')
      ..createSync();
    File('${nonempty.path}/untrusted').writeAsStringSync('keep');
    final store = TelemetrySessionStore(documentsDirectory: () async => root);

    expect(await store.deleteGroup(emptyId), TelemetryDeleteOutcome.deleted);
    expect(await empty.exists(), isFalse);
    expect(
      await store.deleteGroup(nonemptyId),
      TelemetryDeleteOutcome.uncontainedFailure,
    );
    expect(await File('${nonempty.path}/untrusted').readAsString(), 'keep');
  });
}

Future<bool> _completesSoon(Future<Object?> future) async {
  final marker = Object();
  return !identical(
    await Future.any<Object?>(<Future<Object?>>[
      future,
      Future<Object?>.delayed(const Duration(milliseconds: 20), () => marker),
    ]),
    marker,
  );
}

final class _FailingExclusiveCreateIo implements TelemetryExclusiveCreateIo {
  _FailingExclusiveCreateIo({
    required this.failureAt,
    this.neverDelete = false,
  });

  final String failureAt;
  final bool neverDelete;
  FileSystemEntityType type = FileSystemEntityType.notFound;
  bool deleted = false;
  int closeCalls = 0;

  @override
  Future<bool> exists(File file) async => false;

  @override
  Future<void> create(File file) async {
    if (failureAt == 'neverCreate') return Completer<void>().future;
    type = FileSystemEntityType.file;
    if (failureAt == 'create') {
      throw const FileSystemException('create after allocation');
    }
  }

  @override
  Future<TelemetryExclusiveCreateHandle> openWrite(File file) async {
    if (failureAt == 'open') throw const FileSystemException('open');
    return _FailingExclusiveCreateHandle(this);
  }

  @override
  Future<FileSystemEntityType> typeNoFollow(File file) async => type;

  @override
  Future<void> delete(File file) {
    if (neverDelete) return Completer<void>().future;
    deleted = true;
    type = FileSystemEntityType.notFound;
    return Future<void>.value();
  }
}

final class _FailingExclusiveCreateHandle
    implements TelemetryExclusiveCreateHandle {
  _FailingExclusiveCreateHandle(this.owner);

  final _FailingExclusiveCreateIo owner;

  @override
  Future<void> write(List<int> bytes) async {
    if (owner.failureAt == 'write') throw const FileSystemException('write');
  }

  @override
  Future<void> flush() async {
    if (owner.failureAt == 'flush') throw const FileSystemException('flush');
  }

  @override
  Future<void> close() async {
    owner.closeCalls++;
    if (owner.failureAt == 'close') throw const FileSystemException('close');
  }
}

List<int> _headerLine(String id) => TelemetrySessionCodec.encodeHeaderLine(
  TelemetrySessionHeader(
    sessionId: id,
    startedAtUtc: DateTime.utc(2026),
    source: TelemetrySource.demo,
    transport: TransportKind.demo,
    protocol: 'AUTO',
    signals: <FrozenPidDefinition>[
      FrozenPidDefinition.freeze(
        const TelemetrySignalDefinition(
          id: '010C',
          name: 'RPM',
          shortName: 'RPM',
          request: '010C',
          header: '',
          unit: 'rpm',
          unitProvenance: UnitProvenance.standardDirectCanonical,
          minimum: 0,
          maximum: 8000,
          isCustom: false,
          variant: '',
          priority: 0,
          equation: '((A*256)+B)/4',
        ),
      ),
    ],
  ),
);

List<int> _completeSession(String id, DateTime startedAtUtc) {
  final headerResult = TelemetrySessionCodec.decodeHeaderLine(_headerLine(id));
  final header = TelemetrySessionHeader(
    sessionId: id,
    startedAtUtc: startedAtUtc,
    source: headerResult.value!.source,
    transport: headerResult.value!.transport,
    protocol: headerResult.value!.protocol,
    signals: headerResult.value!.signals,
  );
  final event = TelemetryEvent.value(
    observedAtUtc: startedAtUtc.add(const Duration(seconds: 1)),
    sourceTimestampUtc: startedAtUtc.add(const Duration(seconds: 1)),
    elapsedUs: 1000000,
    pidId: '010C',
    value: 1000,
  );
  final prefix = <int>[
    ...TelemetrySessionCodec.encodeHeaderLine(header),
    ...TelemetrySessionCodec.encodeEventLine(event),
  ];
  return <int>[
    ...prefix,
    ...TelemetrySessionCodec.encodeFooterLine(
      TelemetrySessionFooter(
        endedAtUtc: startedAtUtc.add(const Duration(seconds: 2)),
        terminalReason: TelemetryTerminalReason.user,
        valueCount: 1,
        statusCount: 0,
        gapCount: 0,
        bytesBeforeFooter: prefix.length,
      ),
    ),
  ];
}
