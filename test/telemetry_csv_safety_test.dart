import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/telemetry/session/telemetry_export_codec.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_codec.dart';

TelemetrySession maliciousSession() {
  final definition = FrozenPidDefinition.freeze(
    const TelemetrySignalDefinition(
      id: '=cmd',
      name: '+name,"車"',
      shortName: '-short',
      request: '01 0C',
      header: '',
      unit: '@rpm',
      unitProvenance: UnitProvenance.userDefined,
      minimum: 0,
      maximum: 9,
      isCustom: true,
      variant: '\tvariant',
      priority: 0,
      equation: '\rformula',
    ),
  );
  final header = TelemetrySessionHeader(
    sessionId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    startedAtUtc: DateTime.utc(2026),
    source: TelemetrySource.fieldAppConnection,
    transport: TransportKind.wifi,
    protocol: 'AUTO',
    signals: [definition],
  );
  final events = [
    TelemetryEvent.value(
      observedAtUtc: DateTime.utc(2026, 1, 1, 0, 0, 1),
      sourceTimestampUtc: DateTime.utc(2026, 1, 1, 0, 0, 0),
      elapsedUs: 1500,
      pidId: '=cmd',
      value: 1.5,
    ),
    TelemetryEvent.status(
      observedAtUtc: DateTime.utc(2026, 1, 1, 0, 0, 2),
      elapsedUs: 2000,
      pidId: '=cmd',
      status: TelemetryStatus.stale,
    ),
  ];
  final prefix = TelemetrySessionCodec.encodePrefix(header, events);
  return TelemetrySession(
    header: header,
    events: events,
    footer: TelemetrySessionFooter(
      endedAtUtc: DateTime.utc(2026, 1, 1, 0, 0, 3),
      terminalReason: TelemetryTerminalReason.user,
      valueCount: 1,
      statusCount: 1,
      gapCount: 1,
      bytesBeforeFooter: prefix.length,
    ),
  );
}

TelemetrySession sessionWithInvalidPrefixBytes(int bytesBeforeFooter) {
  final session = maliciousSession();
  return TelemetrySession(
    header: session.header,
    events: session.events,
    footer: TelemetrySessionFooter(
      endedAtUtc: session.footer.endedAtUtc,
      terminalReason: session.footer.terminalReason,
      valueCount: session.footer.valueCount,
      statusCount: session.footer.statusCount,
      gapCount: session.footer.gapCount,
      bytesBeforeFooter: bytesBeforeFooter,
    ),
  );
}

void main() {
  test(
    'CSV is long-form RFC4180 and neutralizes every user-controlled formula',
    () {
      final session = maliciousSession();
      final chunks = TelemetryExportCodec.encodeCsvChunks(session).toList();
      expect(chunks.every((chunk) => chunk.length <= 64 * 1024), isTrue);
      final csv = utf8.decode(<int>[for (final chunk in chunks) ...chunk]);
      expect(csv, TelemetryExportCodec.encodeCsv(session));
      expect(
        csv,
        contains(
          'observed_at_utc,source_timestamp_utc,elapsed_ms,pid_id,signal_name,event_type,value,unit,status',
        ),
      );
      expect(csv, contains("'=cmd"));
      expect(csv, contains("'+name"));
      expect(csv, contains("'@rpm"));
      expect(csv, contains('fieldAppConnection'));
      expect(csv, contains('VIN'));
      expect(csv, contains('GPS'));
      final rows = csv
          .split('\r\n')
          .where((line) => !line.startsWith('#'))
          .toList();
      expect(rows[2], contains('status'));
      expect(rows[2], isNot(contains(',1.5,')));
    },
  );

  test(
    'JSON preserves original user text and discloses frozen definitions',
    () {
      final session = maliciousSession();
      final chunks = TelemetryExportCodec.encodeJsonChunks(session).toList();
      expect(chunks.every((chunk) => chunk.length <= 64 * 1024), isTrue);
      final joined = <int>[for (final chunk in chunks) ...chunk];
      final json = utf8.decode(joined);
      expect(json, utf8.decode(TelemetryExportCodec.encodeJson(session)));
      expect(json, contains('"id":"=cmd"'));
      expect(json, contains('"unit":"@rpm"'));
      expect(json, contains('fullFrozenDefinitions'));
    },
  );

  test('exports reject zero and mismatched bytesBeforeFooter', () {
    for (final invalid in [
      sessionWithInvalidPrefixBytes(0),
      sessionWithInvalidPrefixBytes(7),
    ]) {
      expect(
        () => TelemetryExportCodec.encodeCsv(invalid),
        throwsA(isA<TelemetryValidationException>()),
      );
      expect(
        () => TelemetryExportCodec.encodeJson(invalid),
        throwsA(isA<TelemetryValidationException>()),
      );
    }
  });
}
