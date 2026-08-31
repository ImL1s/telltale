import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/telemetry/session/telemetry_export_codec.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_codec.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_exporter.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_reader.dart';

final class _MemorySource implements TelemetryChunkSource {
  _MemorySource(this.bytes);

  Uint8List bytes;
  int maximumRequest = 0;
  int reads = 0;

  @override
  Future<Uint8List> read(int offset, int maximumBytes) async {
    reads++;
    if (maximumBytes > maximumRequest) maximumRequest = maximumBytes;
    if (offset >= bytes.length) return Uint8List(0);
    final end = (offset + maximumBytes).clamp(0, bytes.length);
    return Uint8List.sublistView(bytes, offset, end);
  }
}

final class _ChangingSource implements TelemetryChunkSource {
  _ChangingSource(this.first, this.second);

  final Uint8List first;
  final Uint8List second;
  var _pass = 0;

  @override
  Future<Uint8List> read(int offset, int maximumBytes) async {
    if (offset == 0) _pass++;
    final bytes = _pass <= 1 ? first : second;
    if (offset >= bytes.length) return Uint8List(0);
    return Uint8List.sublistView(
      bytes,
      offset,
      (offset + maximumBytes).clamp(0, bytes.length),
    );
  }
}

TelemetrySession _fixture({int eventCount = 3}) {
  final definition = FrozenPidDefinition.freeze(
    const TelemetrySignalDefinition(
      id: '=rpm',
      name: '+原始\n名稱',
      shortName: '轉速',
      request: '01 0C',
      header: '',
      unit: '@rpm',
      unitProvenance: UnitProvenance.standardDirectCanonical,
      minimum: 0,
      maximum: 9000,
      isCustom: false,
      variant: '',
      priority: 0,
      equation: '(A*256+B)/4',
    ),
  );
  final header = TelemetrySessionHeader(
    sessionId: '0123456789abcdef0123456789abcdef',
    startedAtUtc: DateTime.utc(2026),
    source: TelemetrySource.demo,
    transport: TransportKind.demo,
    protocol: 'AUTO',
    signals: [definition],
  );
  final events = <TelemetryEvent>[
    for (var index = 0; index < eventCount; index++)
      TelemetryEvent.value(
        observedAtUtc: DateTime.utc(2026).add(Duration(milliseconds: index)),
        sourceTimestampUtc: DateTime.utc(2026)
            .add(Duration(milliseconds: index)),
        elapsedUs: index * 1000,
        pidId: '=rpm',
        value: index / 10,
      ),
  ];
  final prefix = TelemetrySessionCodec.encodePrefix(header, events);
  return TelemetrySession(
    header: header,
    events: events,
    footer: TelemetrySessionFooter(
      endedAtUtc: DateTime.utc(2026, 1, 1, 0, 1),
      terminalReason: TelemetryTerminalReason.user,
      valueCount: eventCount,
      statusCount: 0,
      gapCount: 0,
      bytesBeforeFooter: prefix.length,
    ),
  );
}

Future<Uint8List> _collect(Stream<List<int>> stream) async {
  final output = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    output.add(chunk);
  }
  return output.takeBytes();
}

void main() {
  test(
    'CSV and JSON stream bytes match the trusted small-session codec',
    () async {
      final session = _fixture(eventCount: 80);
      final source = _MemorySource(TelemetrySessionCodec.encode(session));
      final exporter = TelemetrySessionExporter();

      final csv = await _collect(exporter.csvStream(source));
      final trustedCsv = utf8.encode(TelemetryExportCodec.encodeCsv(session));
      expect(csv, trustedCsv);
      expect(fnv1a64(csv), fnv1a64(trustedCsv));
      expect(utf8.decode(csv), contains("'=rpm"));
      expect(utf8.decode(csv), contains("'+原始"));

      final json = await _collect(exporter.jsonStream(source));
      final trustedJson = TelemetryExportCodec.encodeJson(session);
      expect(json, trustedJson);
      expect(fnv1a64(json), fnv1a64(trustedJson));
      expect(utf8.decode(json), contains('+原始\\n名稱'));
      expect(
        source.reads,
        greaterThan(4),
        reason: 'each export validates first',
      );
    },
  );

  test(
    'all events beyond the reader diagnostic preview are exported',
    () async {
      final session = _fixture(eventCount: 130);
      final source = _MemorySource(TelemetrySessionCodec.encode(session));

      final decoded = jsonDecode(
        utf8.decode(
          await _collect(TelemetrySessionExporter().jsonStream(source)),
        ),
      ) as Map<String, Object?>;
      expect(decoded['events'], hasLength(130));
    },
  );

  test(
    'corrupt, truncated, and mismatched inputs fail before any output',
    () async {
      final valid = TelemetrySessionCodec.encode(_fixture());
      final cases = <Uint8List>[
        Uint8List.sublistView(valid, 0, valid.length - 1),
        Uint8List.fromList([...valid]..[10] = 0xff),
        Uint8List.fromList(
          utf8.encode(
            utf8.decode(valid).replaceFirst('"valueCount":3', '"valueCount":9'),
          ),
        ),
      ];
      for (final bytes in cases) {
        final emitted = <List<int>>[];
        Object? failure;
        try {
          await TelemetrySessionExporter()
              .csvStream(_MemorySource(bytes))
              .forEach(emitted.add);
        } on Object catch (error) {
          failure = error;
        }
        expect(failure, isA<TelemetryExportException>());
        expect(emitted, isEmpty);
      }
    },
  );

  test(
    'bounded pipeline scales beyond preview without whole-session buffers',
    () async {
      final session = _fixture(eventCount: 2500);
      final source = _MemorySource(TelemetrySessionCodec.encode(session));
      var maximumObserved = 0;
      var outputBytes = 0;
      final exporter = TelemetrySessionExporter(
        onBufferUsage: (usage) {
          if (usage.totalBytes > maximumObserved) {
            maximumObserved = usage.totalBytes;
          }
        },
      );

      await for (final chunk in exporter.csvStream(source)) {
        expect(chunk.length, lessThanOrEqualTo(64 * 1024));
        outputBytes += chunk.length;
      }

      expect(outputBytes, greaterThan(2500 * 40));
      expect(source.maximumRequest, lessThanOrEqualTo(64 * 1024));
      expect(maximumObserved, lessThanOrEqualTo(192 * 1024));
      final factory = exporter.csvStreamFactory(source);
      expect(await _collect(factory()), isNotEmpty);
    },
  );

  test(
    'a valid source changed between passes never completes successfully',
    () async {
      final source = _ChangingSource(
        TelemetrySessionCodec.encode(_fixture()),
        TelemetrySessionCodec.encode(_fixture(eventCount: 4)),
      );
      Object? failure;
      try {
        await _collect(TelemetrySessionExporter().jsonStream(source));
      } on Object catch (error) {
        failure = error;
      }
      expect(failure, isA<TelemetryExportException>());
      expect((failure! as TelemetryExportException).code, 'sourceChanged');
    },
  );
}
