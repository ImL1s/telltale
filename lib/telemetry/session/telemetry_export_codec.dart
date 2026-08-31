library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:csv/csv.dart';

import 'telemetry_session.dart';
import 'telemetry_session_codec.dart';

abstract final class TelemetryExportCodec {
  static const csvColumns = <String>[
    'observed_at_utc',
    'source_timestamp_utc',
    'elapsed_ms',
    'pid_id',
    'signal_name',
    'event_type',
    'value',
    'unit',
    'status',
  ];

  static final Csv _csv = Csv(lineDelimiter: '\r\n');

  static String encodeCsv(TelemetrySession session) {
    final output = StringBuffer();
    for (final chunk in encodeCsvChunks(session)) {
      output.write(utf8.decode(chunk));
    }
    return output.toString();
  }

  static Iterable<Uint8List> encodeCsvChunks(TelemetrySession session) sync* {
    session = _validated(session);
    final definitions = {
      for (final signal in session.header.signals)
        signal.definition.id: signal.definition,
    };
    final metadata = <String>[
      '# telltale_telemetry_csv_version=1',
      '# source=${session.header.source.wireName}',
      '# transport=${session.header.transport.name}',
      '# protocol=${_safeMetadata(session.header.protocol)}',
      '# started_at_utc=${session.header.startedAtUtc.toIso8601String()}',
      '# ended_at_utc=${session.footer.endedAtUtc.toIso8601String()}',
      '# terminal_reason=${session.footer.terminalReason.wireName}',
      '# value_count=${session.footer.valueCount}',
      '# status_count=${session.footer.statusCount}',
      '# gap_count=${session.footer.gapCount}',
      '# preview=預覽已抽樣；匯出保留完整已記錄事件',
      '# privacy_exclusions=VIN;GPS;account;vehicle_profile;adapter_address;raw_diagnostic_traffic',
      '# json_disclosure=JSON may include user-authored PID labels, units, equations, and full frozen definitions',
    ];
    for (final signal in session.header.signals) {
      metadata.add(
        '# frozen_definition=${_safeMetadata(signal.definition.id)}:${signal.fingerprint}',
      );
    }
    for (final line in metadata) {
      yield Uint8List.fromList(utf8.encode('$line\r\n'));
    }
    yield Uint8List.fromList(utf8.encode('${_csv.encode([csvColumns])}\r\n'));
    for (final event in session.events) {
      final definition = definitions[event.pidId]!;
      final row = _csv.encode([
        <Object?>[
          event.observedAtUtc.toIso8601String(),
          event.kind == TelemetryEventKind.value
              ? event.sourceTimestampUtc!.toIso8601String()
              : '',
          event.elapsedUs / 1000,
          protectCsvCell(definition.id),
          protectCsvCell(definition.name),
          event.kind.name,
          event.kind == TelemetryEventKind.value ? event.value : '',
          event.kind == TelemetryEventKind.value
              ? protectCsvCell(definition.unit)
              : '',
          event.kind == TelemetryEventKind.status ? event.status!.wireName : '',
        ],
      ]);
      yield Uint8List.fromList(utf8.encode('$row\r\n'));
    }
  }

  static Uint8List encodeJson(TelemetrySession session) {
    final output = BytesBuilder(copy: false);
    for (final chunk in encodeJsonChunks(session)) {
      output.add(chunk);
    }
    return output.takeBytes();
  }

  static Iterable<Uint8List> encodeJsonChunks(TelemetrySession session) sync* {
    session = _validated(session);
    final preamble = <String, Object?>{
      'exportVersion': 1,
      'privacyExclusions': const <String>[
        'VIN',
        'GPS',
        'account',
        'vehicleProfile',
        'adapterAddress',
        'rawDiagnosticTraffic',
      ],
      'disclosure': 'fullFrozenDefinitions may contain user-authored labels, units, and equations',
    };
    final encodedPreamble = jsonEncode(preamble);
    yield Uint8List.fromList(
      utf8.encode(
        '${encodedPreamble.substring(0, encodedPreamble.length - 1)},"header":',
      ),
    );
    yield _withoutLf(TelemetrySessionCodec.encodeHeaderLine(session.header));
    yield Uint8List.fromList(utf8.encode(',"events":['));
    var first = true;
    for (final event in session.events) {
      if (!first) {
        yield Uint8List.fromList(const [0x2c]);
      }
      first = false;
      yield _withoutLf(TelemetrySessionCodec.encodeEventLine(event));
    }
    yield Uint8List.fromList(utf8.encode('],"footer":'));
    yield _withoutLf(TelemetrySessionCodec.encodeFooterLine(session.footer));
    yield Uint8List.fromList(const [0x7d]);
  }

  static Uint8List _withoutLf(Uint8List line) =>
      Uint8List.sublistView(line, 0, line.length - 1);

  static String protectCsvCell(String value) {
    if (value.isEmpty) return value;
    return switch (value.codeUnitAt(0)) {
      0x3d || 0x2b || 0x2d || 0x40 || 0x09 || 0x0d => "'$value",
      _ => value,
    };
  }

  static String _safeMetadata(String value) =>
      protectCsvCell(value.replaceAll('\r', ' ').replaceAll('\n', ' '));

  static TelemetrySession _validated(TelemetrySession session) {
    var expectedPrefixBytes = TelemetrySessionCodec.encodeHeaderLine(
      session.header,
    ).length;
    var previousElapsedUs = -1;
    var valueCount = 0;
    var statusCount = 0;
    var gapCount = 0;
    final available = <String, bool>{};
    for (final event in session.events) {
      final line = TelemetrySessionCodec.encodeEventLine(event);
      final decoded = TelemetrySessionCodec.decodeEventLine(
        line,
        session.header,
        previousElapsedUs,
      );
      if (!decoded.isSuccess) {
        throw TelemetryValidationException(decoded.error!.code);
      }
      previousElapsedUs = event.elapsedUs;
      expectedPrefixBytes += line.length;
      if (event.kind == TelemetryEventKind.value) {
        valueCount++;
        available[event.pidId] = true;
      } else {
        statusCount++;
        if (available[event.pidId] ?? false) gapCount++;
        available[event.pidId] = false;
      }
    }
    if (session.footer.valueCount != valueCount ||
        session.footer.statusCount != statusCount ||
        session.footer.gapCount != gapCount) {
      throw const TelemetryValidationException('countMismatch');
    }
    if (session.footer.bytesBeforeFooter != expectedPrefixBytes) {
      throw const TelemetryValidationException('bytesBeforeFooterMismatch');
    }
    TelemetrySessionCodec.encodeFooterLine(session.footer);
    return session;
  }
}
