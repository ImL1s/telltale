import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_codec.dart';

TelemetrySession fixture() {
  final definition = FrozenPidDefinition.freeze(
    const TelemetrySignalDefinition(
      id: 'rpm',
      name: '引擎轉速',
      shortName: 'RPM',
      request: '01 0C',
      header: '',
      unit: 'rpm',
      unitProvenance: UnitProvenance.standardDirectCanonical,
      minimum: 0,
      maximum: 8000,
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
  final events = [
    TelemetryEvent.value(
      observedAtUtc: DateTime.utc(2026, 1, 1, 0, 0, 1),
      sourceTimestampUtc: DateTime.utc(2026, 1, 1, 0, 0, 0, 900),
      elapsedUs: 1000000,
      pidId: 'rpm',
      value: 1000,
    ),
    TelemetryEvent.status(
      observedAtUtc: DateTime.utc(2026, 1, 1, 0, 0, 2),
      elapsedUs: 2000000,
      pidId: 'rpm',
      status: TelemetryStatus.stale,
    ),
  ];
  final prefix = TelemetrySessionCodec.encodePrefix(header, events);
  final footer = TelemetrySessionFooter(
    endedAtUtc: DateTime.utc(2026, 1, 1, 0, 0, 3),
    terminalReason: TelemetryTerminalReason.user,
    valueCount: 1,
    statusCount: 1,
    gapCount: 1,
    bytesBeforeFooter: prefix.length,
  );
  return TelemetrySession(header: header, events: events, footer: footer);
}

void main() {
  test('canonical NDJSON round-trips byte-for-byte', () {
    final bytes = TelemetrySessionCodec.encode(fixture());
    final decoded = TelemetrySessionCodec.decode(bytes);
    expect(decoded.isSuccess, isTrue, reason: decoded.error?.toString());
    expect(TelemetrySessionCodec.encode(decoded.session!), bytes);
  });

  test(
    'decoder fails closed without throwing on ordering/count/size corruption',
    () {
      final valid = TelemetrySessionCodec.encode(fixture());
      final lines = utf8.decode(valid).trimRight().split('\n');
      final duplicateFooter = utf8.encode(
        '${lines.join('\n')}\n${lines.last}\n',
      );
      expect(TelemetrySessionCodec.decode(duplicateFooter).isSuccess, isFalse);

      final footer = jsonDecode(lines.last) as Map<String, dynamic>;
      footer['valueCount'] = 99;
      final wrongCounts = utf8.encode(
        '${[...lines.take(lines.length - 1), jsonEncode(footer)].join('\n')}\n',
      );
      expect(
        TelemetrySessionCodec.decode(wrongCounts).error!.code,
        'countMismatch',
      );

      final backwards = jsonDecode(lines[2]) as Map<String, dynamic>;
      backwards['elapsedUs'] = -1;
      final invalid = utf8.encode(
        '${[lines[0], lines[1], jsonEncode(backwards), lines[3]].join('\n')}\n',
      );
      expect(() => TelemetrySessionCodec.decode(invalid), returnsNormally);
      expect(TelemetrySessionCodec.decode(invalid).isSuccess, isFalse);
    },
  );

  test('unknown additive keys are ignored but unknown schema is rejected', () {
    final lines = utf8
        .decode(TelemetrySessionCodec.encode(fixture()))
        .split('\n');
    final header = jsonDecode(lines.first) as Map<String, dynamic>;
    header['future'] = {'anything': true};
    lines[0] = jsonEncode(header);
    // Header byte count changed, so rebuild the footer's prefix byte count.
    final prefix = utf8.encode('${lines.take(3).join('\n')}\n');
    final footer = jsonDecode(lines[3]) as Map<String, dynamic>;
    footer['bytesBeforeFooter'] = prefix.length;
    lines[3] = jsonEncode(footer);
    expect(
      TelemetrySessionCodec.decode(utf8.encode('${lines.take(4).join('\n')}\n'))
          .isSuccess,
      isTrue,
    );
    header['schemaVersion'] = 2;
    lines[0] = jsonEncode(header);
    expect(
      TelemetrySessionCodec.decode(utf8.encode('${lines.take(4).join('\n')}\n'))
          .isSuccess,
      isFalse,
    );
  });

  test(
    'bounded per-line API validates PID, elapsed, counters, and prefix bytes',
    () {
      final session = fixture();
      final headerLine = TelemetrySessionCodec.encodeHeaderLine(session.header);
      final header = TelemetrySessionCodec.decodeHeaderLine(headerLine);
      expect(header.isSuccess, isTrue);
      final headerObject = jsonDecode(
        utf8.decode(headerLine).trimRight(),
      ) as Map<String, Object?>;
      expect(
        TelemetrySessionCodec.decodeHeaderObject(headerObject).value?.sessionId,
        header.value?.sessionId,
      );

      final eventLine = TelemetrySessionCodec.encodeEventLine(
        session.events.first,
      );
      expect(
        TelemetrySessionCodec.decodeEventLine(
          eventLine,
          header.value!,
          -1,
        ).isSuccess,
        isTrue,
      );
      final eventObject = jsonDecode(
        utf8.decode(eventLine).trimRight(),
      ) as Map<String, Object?>;
      expect(
        TelemetrySessionCodec.decodeEventObject(
          eventObject,
          header.value!,
          -1,
        ).value?.value,
        session.events.first.value,
      );
      expect(
        TelemetrySessionCodec.decodeEventLine(
          eventLine,
          header.value!,
          session.events.first.elapsedUs + 1,
        ).error!.code,
        'backwardElapsed',
      );

      final footerLine = TelemetrySessionCodec.encodeFooterLine(session.footer);
      final footerObject = jsonDecode(
        utf8.decode(footerLine).trimRight(),
      ) as Map<String, Object?>;
      expect(
        TelemetrySessionCodec.decodeFooterLine(
          footerLine,
          1,
          1,
          1,
          session.footer.bytesBeforeFooter,
        ).isSuccess,
        isTrue,
      );
      expect(
        TelemetrySessionCodec.decodeFooterObject(
          footerObject,
          1,
          1,
          1,
          session.footer.bytesBeforeFooter,
        ).value?.bytesBeforeFooter,
        session.footer.bytesBeforeFooter,
      );
      expect(
        TelemetrySessionCodec.decodeFooterLine(
          footerLine,
          2,
          1,
          1,
          session.footer.bytesBeforeFooter,
        ).error!.code,
        'countMismatch',
      );
      expect(
        TelemetrySessionCodec.decodeHeaderLine(
          headerLine.sublist(0, headerLine.length - 1),
        ).error!.code,
        'incompleteTail',
      );
    },
  );

  test(
    'definition JSON must retain canonical key order and numeric encoding',
    () {
      final lines = utf8
          .decode(TelemetrySessionCodec.encode(fixture()))
          .trimRight()
          .split('\n');
      final header = jsonDecode(lines.first) as Map<String, dynamic>;
      final signals = header['signals'] as List<dynamic>;
      final signal = signals.single as Map<String, dynamic>;
      final original = signal['definition'] as Map<String, dynamic>;
      signal['definition'] = <String, dynamic>{
        'name': original['name'],
        ...original,
      };
      lines[0] = jsonEncode(header);
      final prefix = utf8.encode('${lines.take(3).join('\n')}\n');
      final footer = jsonDecode(lines.last) as Map<String, dynamic>;
      footer['bytesBeforeFooter'] = prefix.length;
      lines[3] = jsonEncode(footer);
      final result = TelemetrySessionCodec.decode(
        utf8.encode('${lines.join('\n')}\n'),
      );
      expect(result.error!.code, 'nonCanonicalDefinition');
    },
  );

  test(
    'decoder rejects source/transport and definition provenance forgery',
    () {
      List<int> mutateHeader(void Function(Map<String, dynamic>) mutate) {
        final lines = utf8
            .decode(TelemetrySessionCodec.encode(fixture()))
            .trimRight()
            .split('\n');
        final header = jsonDecode(lines.first) as Map<String, dynamic>;
        mutate(header);
        lines[0] = jsonEncode(header);
        return utf8.encode('${lines.join('\n')}\n');
      }

      final sourceMismatch = mutateHeader((header) {
        header['source'] = 'fieldAppConnection';
      });
      expect(
        TelemetrySessionCodec.decode(sourceMismatch).error!.code,
        'sourceTransportMismatch',
      );

      final invalidPriority = mutateHeader((header) {
        final signal =
            (header['signals'] as List<dynamic>).single as Map<String, dynamic>;
        final definition = signal['definition'] as Map<String, dynamic>;
        definition['priority'] = 99;
      });
      expect(
        TelemetrySessionCodec.decode(invalidPriority).error!.code,
        'invalidPriority',
      );
    },
  );

  test('decoder rejects parseable but noncanonical UTC timestamps', () {
    final lines = utf8
        .decode(TelemetrySessionCodec.encode(fixture()))
        .trimRight()
        .split('\n');
    final header = jsonDecode(lines.first) as Map<String, dynamic>;
    // DateTime.tryParse normalizes day 32; canonical encoder would never
    // emit this, so fail closed instead of rewriting History/export dates.
    header['startedAtUtc'] = '2026-01-32T00:00:00.000Z';
    lines[0] = jsonEncode(header);
    final prefix = utf8.encode('${lines.take(3).join('\n')}\n');
    final footer = jsonDecode(lines[3]) as Map<String, dynamic>;
    footer['bytesBeforeFooter'] = prefix.length;
    lines[3] = jsonEncode(footer);
    final decoded = TelemetrySessionCodec.decode(
      utf8.encode('${lines.take(4).join('\n')}\n'),
    );
    expect(decoded.isSuccess, isFalse);
    expect(decoded.error!.code, 'utcRequired');
  });
}
