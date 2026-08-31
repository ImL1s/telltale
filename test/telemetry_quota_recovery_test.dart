import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_codec.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_store.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_writer.dart';

void main() {
  late Directory root;
  late Directory telemetry;
  late TelemetrySessionStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('telemetry_recovery_test_');
    telemetry = Directory('${root.path}/telltale-telemetry')..createSync();
    store = TelemetrySessionStore(
      documentsDirectory: () async => root,
      nowUtc: () => DateTime.utc(2026, 1, 1, 0, 1),
    );
  });

  tearDown(() async => root.delete(recursive: true));

  test(
    'quota groups siblings once and includes every recognized byte',
    () async {
      final id = '1' * 32;
      File('${telemetry.path}/$id.ndjson')
          .writeAsBytesSync(List<int>.filled(7, 0));
      File('${telemetry.path}/$id.ndjson.part')
          .writeAsBytesSync(List<int>.filled(11, 0));
      File('${telemetry.path}/${'2' * 32}.ndjson.part')
          .writeAsBytesSync(List<int>.filled(13, 0));

      final quota = await store.scanQuota();

      expect(quota.groupCount, 2);
      expect(quota.recognizedBytes, 31);
      expect(quota.remainingLibraryBytes, TelemetryQuota.libraryByteLimit - 31);
      expect(quota.effectiveSessionLimit, TelemetryQuota.sessionByteLimit);
    },
  );

  test(
    '20 groups and insufficient footer reservation reject creation',
    () async {
      for (var i = 0; i < 20; i++) {
        final id = i.toRadixString(16).padLeft(32, '0');
        File('${telemetry.path}/$id.ndjson').writeAsStringSync('x');
      }
      final full = await store.createStaging(
        headerLineForId: _headerLine,
        minimalValueLineBytes: 3,
      );
      expect(full.outcome, TelemetryCreateOutcome.libraryGroupLimit);

      for (final entity in telemetry.listSync()) {
        entity.deleteSync();
      }
      final quotaFiller = File('${telemetry.path}/${'f' * 32}.ndjson')
          .openSync(mode: FileMode.write);
      quotaFiller.truncateSync(
        TelemetryQuota.libraryByteLimit - TelemetryQuota.footerReserveBytes - 8,
      );
      quotaFiller.closeSync();
      final noRoom = await store.createStaging(
        headerLineForId: _headerLine,
        minimalValueLineBytes: 1,
      );
      expect(noRoom.outcome, TelemetryCreateOutcome.noRoomForValue);
      expect(telemetry.listSync(), hasLength(1));
    },
  );

  test(
    'strict recovery installs prefix, installs footer, deletes zero value',
    () async {
      final recoverId = '3' * 32;
      final completeId = '4' * 32;
      final zeroId = '5' * 32;
      File('${telemetry.path}/$recoverId.ndjson.part').writeAsBytesSync(<int>[
        ..._headerLine(recoverId),
        ..._valueLine(1),
        ...utf8.encode('{"type":"status"'),
      ]);
      final completePrefix = <int>[
        ..._headerLine(completeId),
        ..._valueLine(1),
      ];
      final completeBytes = <int>[
        ...completePrefix,
        ...TelemetrySessionCodec.encodeFooterLine(
          TelemetrySessionFooter(
            endedAtUtc: DateTime.utc(2026, 1, 1, 0, 0, 2),
            terminalReason: TelemetryTerminalReason.user,
            valueCount: 1,
            statusCount: 0,
            gapCount: 0,
            bytesBeforeFooter: completePrefix.length,
          ),
        ),
      ];
      File('${telemetry.path}/$completeId.ndjson.part')
          .writeAsBytesSync(completeBytes);
      File('${telemetry.path}/$zeroId.ndjson.part')
          .writeAsBytesSync(<int>[..._headerLine(zeroId), ..._statusLine(1)]);

      final result = await store.recover();

      expect(
        result.byId[recoverId],
        TelemetryRecoveryOutcome.recoveredAndInstalled,
      );
      expect(
        result.byId[completeId],
        TelemetryRecoveryOutcome.installedUnchanged,
      );
      expect(result.byId[zeroId], TelemetryRecoveryOutcome.deletedZeroValue);
      final recovered = File('${telemetry.path}/$recoverId.ndjson')
          .readAsStringSync();
      expect(RegExp('"type":"footer"').allMatches(recovered), hasLength(1));
      expect(
        recovered,
        contains('"terminalReason":"recoveredAfterInterruption"'),
      );
      expect(
        File('${telemetry.path}/$completeId.ndjson').readAsBytesSync(),
        completeBytes,
      );
      expect(
        File('${telemetry.path}/$zeroId.ndjson.part').existsSync(),
        isFalse,
      );
    },
  );

  test(
    'malformed complete line and final-plus-part collision stay delete-only',
    () async {
      final corruptId = '6' * 32;
      final collisionId = '7' * 32;
      File('${telemetry.path}/$corruptId.ndjson.part').writeAsBytesSync(<int>[
        ..._headerLine(corruptId),
        ...utf8.encode('{broken}\n'),
      ]);
      File('${telemetry.path}/$collisionId.ndjson')
          .writeAsBytesSync(_headerLine(collisionId));
      File('${telemetry.path}/$collisionId.ndjson.part')
          .writeAsBytesSync(_headerLine(collisionId));

      final result = await store.recover();

      expect(
        result.byId[corruptId],
        TelemetryRecoveryOutcome.corruptDeleteOnly,
      );
      expect(
        result.byId[collisionId],
        TelemetryRecoveryOutcome.collisionDeleteOnly,
      );
      expect(
        File('${telemetry.path}/$corruptId.ndjson.part').existsSync(),
        isTrue,
      );
      expect(
        File('${telemetry.path}/$collisionId.ndjson').existsSync(),
        isTrue,
      );
      expect(
        File('${telemetry.path}/$collisionId.ndjson.part').existsSync(),
        isTrue,
      );
    },
  );

  test(
    'fresh store recovers only durable prefix after never-sink backpressure',
    () async {
      final id = '8' * 32;
      final ownedStore = TelemetrySessionStore(
        documentsDirectory: () async => root,
        idSource: () => id,
        nowUtc: () => DateTime.utc(2026, 1, 1, 0, 1),
      );
      final created = await ownedStore.createStaging(
        headerLineForId: _headerLine,
        minimalValueLineBytes: _valueLine(1).length,
      );
      final headerBytes = _headerLine(id).length;
      final writer = TelemetrySessionWriter(
        sink: _FirstWriteThenNeverSink(created.file!),
        bytesAlreadyWritten: headerBytes,
      );
      expect(
        writer.tryAppendLine(_valueLine(1)),
        TelemetryAppendResult.accepted,
      );
      writer.flushActive();
      for (
        var attempt = 0;
        writer.inFlightBytes != 0 && attempt < 100;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(writer.inFlightBytes, 0);
      expect(
        writer.tryAppendLine(_valueLine(2)),
        TelemetryAppendResult.accepted,
      );
      writer.flushActive();
      expect(
        writer.tryAppendLine(List<int>.filled(64 * 1024, 0x0A)),
        TelemetryAppendResult.accepted,
      );
      expect(
        writer.tryAppendLine(<int>[0x7B, 0x7D, 0x0A]),
        TelemetryAppendResult.storageBackpressure,
      );
      expect(File('${telemetry.path}/$id.ndjson').existsSync(), isFalse);

      final freshStore = TelemetrySessionStore(
        documentsDirectory: () async => root,
        nowUtc: () => DateTime.utc(2026, 1, 1, 0, 2),
      );
      final recovery = await freshStore.recover();

      expect(recovery.byId[id], TelemetryRecoveryOutcome.recoveredAndInstalled);
      final decoded = TelemetrySessionCodec.decode(
        File('${telemetry.path}/$id.ndjson').readAsBytesSync(),
      );
      expect(decoded.isSuccess, isTrue);
      expect(decoded.session!.footer.valueCount, 1);
    },
  );

  test(
    'rechecks safety before recovery mutation and leaves part unchanged',
    () async {
      final id = '9' * 32;
      final bytes = <int>[..._headerLine(id), ..._valueLine(1)];
      final part = File('${telemetry.path}/$id.ndjson.part')
        ..writeAsBytesSync(bytes);

      final result = await store.recover(mutationAllowed: () => false);

      expect(result.byId[id], TelemetryRecoveryOutcome.mutationBlocked);
      expect(part.readAsBytesSync(), bytes);
      expect(File('${telemetry.path}/$id.ndjson').existsSync(), isFalse);
    },
  );

  test('honors asynchronous mutationAllowed Future.value(true)', () async {
    final id = 'a' * 32;
    final bytes = <int>[..._headerLine(id), ..._valueLine(1)];
    File('${telemetry.path}/$id.ndjson.part').writeAsBytesSync(bytes);

    final result = await store.recover(
      mutationAllowed: () async => true,
    );

    expect(result.byId[id], isNot(TelemetryRecoveryOutcome.mutationBlocked));
    expect(File('${telemetry.path}/$id.ndjson').existsSync(), isTrue);
  });
}

final class _FirstWriteThenNeverSink implements TelemetryAppendSink {
  _FirstWriteThenNeverSink(this.file);

  final File file;
  var calls = 0;

  @override
  Future<void> append(List<int> chunk) {
    calls++;
    if (calls == 1) {
      return file.writeAsBytes(chunk, mode: FileMode.append, flush: true);
    }
    return Completer<void>().future;
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> flush() async {}
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

List<int> _valueLine(int second) => TelemetrySessionCodec.encodeEventLine(
  TelemetryEvent.value(
    observedAtUtc: DateTime.utc(2026, 1, 1, 0, 0, second),
    sourceTimestampUtc: DateTime.utc(2026, 1, 1, 0, 0, second),
    elapsedUs: second * 1000000,
    pidId: '010C',
    value: second.toDouble(),
  ),
);

List<int> _statusLine(int second) => TelemetrySessionCodec.encodeEventLine(
  TelemetryEvent.status(
    observedAtUtc: DateTime.utc(2026, 1, 1, 0, 0, second),
    elapsedUs: second * 1000000,
    pidId: '010C',
    status: TelemetryStatus.stale,
  ),
);
