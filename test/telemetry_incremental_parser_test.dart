import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_codec.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_reader.dart';

void main() {
  test('reads canonical input in chunks no larger than 64 KiB', () async {
    final header = _header('a' * 32);
    final event = _value(1);
    final prefix = <int>[
      ...TelemetrySessionCodec.encodeHeaderLine(header),
      ...TelemetrySessionCodec.encodeEventLine(event),
    ];
    final bytes = <int>[
      ...prefix,
      ...TelemetrySessionCodec.encodeFooterLine(
        TelemetrySessionFooter(
          endedAtUtc: DateTime.utc(2026, 1, 1, 0, 0, 1),
          terminalReason: TelemetryTerminalReason.user,
          valueCount: 1,
          statusCount: 0,
          gapCount: 0,
          bytesBeforeFooter: prefix.length,
        ),
      ),
    ];
    final source = _SpySource(bytes, maximumReturnedBytes: 7);

    final result = await const TelemetrySessionReader().read(source);

    expect(result.isValid, isTrue);
    expect(result.lines.map((line) => line.kind), <TelemetryRecordLineKind>[
      TelemetryRecordLineKind.header,
      TelemetryRecordLineKind.value,
      TelemetryRecordLineKind.footer,
    ]);
    expect(result.lines[0].canonicalHeader, same(result.sessionHeader));
    expect(result.lines[0].canonicalEvent, isNull);
    expect(result.lines[1].canonicalEvent?.value, event.value);
    expect(result.lines[1].canonicalHeader, isNull);
    expect(result.lines[2].canonicalFooter, same(result.sessionFooter));
    expect(source.largestRequest, TelemetrySessionReader.chunkBytes);
    expect(source.largestRequest, lessThanOrEqualTo(64 * 1024));
  });

  test(
    'accepts split UTF-8 and drops only one incomplete final fragment',
    () async {
      final complete = <int>[
        ...TelemetrySessionCodec.encodeHeaderLine(_header('b' * 32)),
        ...TelemetrySessionCodec.encodeEventLine(_value(2)),
      ];
      final source = _SpySource(<int>[
        ...complete,
        ...utf8.encode('{"type":"status","status":"壞'),
      ], maximumReturnedBytes: 1);

      final result = await const TelemetrySessionReader().read(
        source,
        allowIncompleteTail: true,
      );

      expect(result.isValid, isTrue);
      expect(result.droppedIncompleteTail, isTrue);
      expect(result.lines, hasLength(2));
    },
  );

  test('fails closed as soon as an unterminated event exceeds 2 KiB', () async {
    final bytes = <int>[
      ...TelemetrySessionCodec.encodeHeaderLine(_header('c' * 32)),
      ...utf8.encode('{"type":"value","payload":"${'x' * 5000}'),
    ];
    final source = _SpySource(bytes, maximumReturnedBytes: 512);

    final result = await const TelemetrySessionReader().read(source);

    expect(result.failure, TelemetryReadFailure.lineTooLong);
    expect(source.bytesReturned, lessThan(bytes.length));
  });

  test('invalid complete UTF-8 is corrupt, never an incomplete tail', () async {
    final header = TelemetrySessionCodec.encodeHeaderLine(_header('d' * 32));
    final result = await const TelemetrySessionReader().read(
      _SpySource(<int>[...header, 0xC3, 0x28, 0x0A]),
      allowIncompleteTail: true,
    );

    expect(result.failure, TelemetryReadFailure.invalidUtf8);
    expect(result.droppedIncompleteTail, isFalse);
  });

  test('accepts only a genuinely truncated final UTF-8 scalar', () async {
    final header = TelemetrySessionCodec.encodeHeaderLine(_header('f' * 32));
    final validPrefix = utf8.encode('{"type":"status","status":"');
    for (final truncatedScalar in const <List<int>>[
      <int>[0xC3],
      <int>[0xE5, 0xA3],
      <int>[0xF0, 0x9F, 0x9A],
    ]) {
      final result = await const TelemetrySessionReader().read(
        _SpySource(<int>[...header, ...validPrefix, ...truncatedScalar]),
        allowIncompleteTail: true,
      );
      expect(result.isValid, isTrue, reason: '$truncatedScalar');
      expect(result.droppedIncompleteTail, isTrue);
    }
  });

  test('rejects malformed UTF-8 hidden in an incomplete tail', () async {
    final header = TelemetrySessionCodec.encodeHeaderLine(_header('1' * 32));
    final prefix = utf8.encode('{"type":"status","status":"');
    final malformed = <List<int>>[
      <int>[0x80], // continuation without a lead
      <int>[0xC0], // overlong lead
      <int>[0xE0, 0x80], // overlong three-byte prefix
      <int>[0xED, 0xA0], // UTF-16 surrogate prefix
      <int>[0xF4, 0x90], // above U+10FFFF
      <int>[0xF5], // out-of-range lead
      <int>[0xE5, 0x28], // invalid continuation
      <int>[0xC3, 0x28, 0xE5], // invalid sequence before truncated scalar
    ];

    for (final suffix in malformed) {
      final result = await const TelemetrySessionReader().read(
        _SpySource(<int>[...header, ...prefix, ...suffix]),
        allowIncompleteTail: true,
      );
      expect(
        result.failure,
        TelemetryReadFailure.invalidUtf8,
        reason: '$suffix',
      );
      expect(result.droppedIncompleteTail, isFalse);
    }
  });

  test('retains footer validation without materializing every event', () async {
    final header = TelemetrySessionCodec.encodeHeaderLine(_header('e' * 32));
    final events = <int>[];
    for (var second = 1; second <= 100; second++) {
      events.addAll(TelemetrySessionCodec.encodeEventLine(_value(second)));
    }
    final prefix = <int>[...header, ...events];
    final source = _SpySource(<int>[
      ...prefix,
      ...TelemetrySessionCodec.encodeFooterLine(
        TelemetrySessionFooter(
          endedAtUtc: DateTime.utc(2026, 1, 1, 0, 2),
          terminalReason: TelemetryTerminalReason.user,
          valueCount: 100,
          statusCount: 0,
          gapCount: 0,
          bytesBeforeFooter: prefix.length,
        ),
      ),
    ]);

    final result = await const TelemetrySessionReader().read(source);

    expect(result.isValid, isTrue);
    expect(result.valueCount, 100);
    expect(result.lines, hasLength(64));
    expect(result.footer?.kind, TelemetryRecordLineKind.footer);
  });

  test('rejects footers whose endedAtUtc precedes the header start', () async {
    final header = _header('e' * 32);
    final event = _value(1);
    final prefix = <int>[
      ...TelemetrySessionCodec.encodeHeaderLine(header),
      ...TelemetrySessionCodec.encodeEventLine(event),
    ];
    // Bypass the session Footer constructor path used by encodeFooterLine by
    // hand-building a footer JSON line with an earlier wall clock.
    final badFooter = utf8.encode(
      '${jsonEncode(<String, Object?>{
        'type': 'footer',
        'endedAtUtc': DateTime.utc(2025, 12, 31).toIso8601String(),
        'terminalReason': 'user',
        'valueCount': 1,
        'statusCount': 0,
        'gapCount': 0,
        'bytesBeforeFooter': prefix.length,
      })}\n',
    );
    final result = await const TelemetrySessionReader().read(
      _SpySource(<int>[...prefix, ...badFooter]),
    );

    expect(result.failure, TelemetryReadFailure.schemaViolation);
    expect(result.isValid, isFalse);
  });
}

TelemetrySessionHeader _header(String id) => TelemetrySessionHeader(
  sessionId: id,
  startedAtUtc: DateTime.utc(2026),
  source: TelemetrySource.demo,
  transport: TransportKind.demo,
  protocol: 'AUTO',
  signals: <FrozenPidDefinition>[
    FrozenPidDefinition.freeze(
      const TelemetrySignalDefinition(
        id: '010C',
        name: 'Engine RPM',
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
);

TelemetryEvent _value(int seconds) => TelemetryEvent.value(
  observedAtUtc: DateTime.utc(2026, 1, 1, 0, 0, seconds),
  sourceTimestampUtc: DateTime.utc(2026, 1, 1, 0, 0, seconds),
  elapsedUs: seconds * 1000000,
  pidId: '010C',
  value: seconds.toDouble(),
);

final class _SpySource implements TelemetryChunkSource {
  _SpySource(this._bytes, {this.maximumReturnedBytes = 64 * 1024});

  final List<int> _bytes;
  final int maximumReturnedBytes;
  int largestRequest = 0;
  int bytesReturned = 0;

  @override
  Future<Uint8List> read(int offset, int maximumBytes) async {
    largestRequest = maximumBytes > largestRequest
        ? maximumBytes
        : largestRequest;
    if (offset >= _bytes.length) return Uint8List(0);
    final end = (offset + maximumReturnedBytes).clamp(0, _bytes.length);
    final result = Uint8List.fromList(_bytes.sublist(offset, end));
    bytesReturned += result.length;
    return result;
  }
}
