/// Mixed evidence must survive the shipped CSV/JSON exporter.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/diagnostics/availability.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/telemetry/session/derived_estimates.dart';
import 'package:torque_obd/telemetry/session/telemetry_export_codec.dart';
import 'package:torque_obd/telemetry/session/telemetry_recorder.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_codec.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_exporter.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_reader.dart';

FrozenPidDefinition _signal({
  required String id,
  required String name,
  required String request,
  required bool isCustom,
  double minimum = 0,
  double maximum = 100,
  String? evidenceKind,
}) => FrozenPidDefinition.freeze(
  TelemetrySignalDefinition(
    id: id,
    name: name,
    shortName: name,
    request: request,
    header: isCustom ? '7E0' : '',
    unit: '%',
    unitProvenance: isCustom
        ? UnitProvenance.userDefined
        : UnitProvenance.standardDirectCanonical,
    minimum: minimum,
    maximum: maximum,
    isCustom: isCustom,
    variant: '',
    priority: 1,
    equation: 'A',
    evidenceKind: evidenceKind,
  ),
);

Future<Uint8List> _collect(Stream<List<int>> stream) async {
  final output = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    output.add(chunk);
  }
  return output.takeBytes();
}

void main() {
  test(
    'mixed unverified / 估算 / 異常 / partial marks survive CSV and JSON',
    () async {
      final community = _signal(
        id: 'soc',
        name: 'SOC',
        request: '01 5B',
        isCustom: false,
        maximum: 100,
        evidenceKind: 'community',
      );
      final user = _signal(
        id: 'custom:7E0:0105',
        name: 'User coolant',
        request: '01 05',
        isCustom: true,
        minimum: -40,
        maximum: 215,
      );
      final header = TelemetrySessionHeader(
        sessionId: '0123456789abcdef0123456789abcdef',
        startedAtUtc: DateTime.utc(2026),
        source: TelemetrySource.demo,
        transport: TransportKind.demo,
        protocol: 'AUTO',
        signals: [community, user],
      );
      final events = <TelemetryEvent>[
        TelemetryEvent.value(
          observedAtUtc: DateTime.utc(2026),
          sourceTimestampUtc: DateTime.utc(2026),
          elapsedUs: 0,
          pidId: community.definition.id,
          value: 140,
          quality: TelemetryQuality.outOfReferenceRange,
        ),
        TelemetryEvent.value(
          observedAtUtc: DateTime.utc(2026),
          sourceTimestampUtc: DateTime.utc(2026),
          elapsedUs: 1000,
          pidId: user.definition.id,
          value: 90,
        ),
        TelemetryEvent.status(
          observedAtUtc: DateTime.utc(2026),
          elapsedUs: 2000,
          pidId: community.definition.id,
          status: TelemetryStatus.noAnswer,
        ),
      ];
      final prefix = TelemetrySessionCodec.encodePrefix(header, events);
      final session = TelemetrySession(
        header: header,
        events: events,
        footer: TelemetrySessionFooter(
          endedAtUtc: DateTime.utc(2026, 1, 1, 0, 1),
          terminalReason: TelemetryTerminalReason.user,
          valueCount: 2,
          statusCount: 1,
          gapCount: 1,
          bytesBeforeFooter: prefix.length,
        ),
      );

      final csv = TelemetryExportCodec.encodeCsv(session);
      final dump = Platform.environment['USABILITY_R2_EXPORT'];
      if (dump != null && dump.isNotEmpty) {
        File(dump).writeAsStringSync(csv);
      }
      expect(csv, contains('telltale_telemetry_csv_version=2'));
      expect(csv, contains('mixed_evidence_upgrade=never'));
      expect(csv, contains('outOfReferenceRange'));
      expect(csv, contains('userSupplied'));
      expect(csv, contains('usableWithNotice,demo,userSupplied'));
      expect(csv, contains('usableWithNotice,demo,community'));
      expect(csv, contains('noAnswer'));
      expect(csv, isNot(contains('fieldVerified')));
      expect(csv, contains('140'));
      expect(csv, contains('90'));
      final json = utf8.decode(TelemetryExportCodec.encodeJson(session));
      expect(json, contains('"origin":"demo"'));
      expect(json, contains('"evidence":"community"'));
      expect(json, contains('"evidence":"userSupplied"'));
      expect(json, contains('"compatibility":"userSelected"'));
      expect(json, contains('"compatibility":"candidate"'));
      expect(json, contains('"quality":"outOfReferenceRange"'));
      expect(json, contains('"operation_risk":"boundedRead"'));
      final streamedJson = utf8.decode(
        await _collect(
          TelemetrySessionExporter().jsonStream(
            _MemorySource(TelemetrySessionCodec.encode(session)),
          ),
        ),
      );
      expect(streamedJson, json);

      final outlier = AvailabilityPolicy.forRecordedEvent(
        definition: community.definition,
        event: events.first,
        source: TelemetrySource.demo,
      );
      expect(outlier.origin, DatumOrigin.demo);
      expect(outlier.quality, DatumQuality.outOfReferenceRange);
      expect(outlier.compatibility, Compatibility.candidate);
      expect(outlier.isNumericSuccess, isTrue);
      expect(outlier.badgeLabels, contains('異常'));

      final userStatus = AvailabilityPolicy.forRecordedEvent(
        definition: user.definition,
        event: events[1],
      );
      expect(userStatus.evidence, EvidenceKind.userSupplied);
      expect(userStatus.compatibility, Compatibility.userSelected);

      final clearStatus = AvailabilityPolicy.forRecordedEvent(
        definition: const TelemetrySignalDefinition(
          id: 'clear',
          name: 'Clear',
          shortName: 'Clear',
          request: '04',
          header: '',
          unit: '',
          unitProvenance: UnitProvenance.standardDirectCanonical,
          minimum: 0,
          maximum: 0,
          isCustom: false,
          variant: '',
          priority: 1,
          equation: '',
        ),
        event: TelemetryEvent.status(
          observedAtUtc: DateTime.utc(2026),
          elapsedUs: 0,
          pidId: 'clear',
          status: TelemetryStatus.noAnswer,
        ),
      );
      expect(clearStatus.operationRisk, OperationRisk.clear);

      final demoCustom = AvailabilityPolicy.forRecordedEvent(
        definition: user.definition,
        event: events[1],
        source: TelemetrySource.demo,
      );
      expect(demoCustom.origin, DatumOrigin.demo);
      expect(demoCustom.evidence, EvidenceKind.userSupplied);

      final streamed = utf8.decode(
        await _collect(
          TelemetrySessionExporter().csvStream(
            _MemorySource(TelemetrySessionCodec.encode(session)),
          ),
        ),
      );
      expect(streamed, csv);
    },
  );

  test('derived estimates export as 估算 with formula', () {
    final hp = freezePidDefinition(DerivedEstimates.horsepower);
    final header = TelemetrySessionHeader(
      sessionId: '0123456789abcdef0123456789abcdef',
      startedAtUtc: DateTime.utc(2026),
      source: TelemetrySource.demo,
      transport: TransportKind.demo,
      protocol: 'AUTO',
      signals: [hp],
    );
    final events = [
      TelemetryEvent.value(
        observedAtUtc: DateTime.utc(2026),
        sourceTimestampUtc: DateTime.utc(2026),
        elapsedUs: 0,
        pidId: hp.definition.id,
        value: 145,
      ),
    ];
    final prefix = TelemetrySessionCodec.encodePrefix(header, events);
    final session = TelemetrySession(
      header: header,
      events: events,
      footer: TelemetrySessionFooter(
        endedAtUtc: DateTime.utc(2026, 1, 1, 0, 1),
        terminalReason: TelemetryTerminalReason.user,
        valueCount: 1,
        statusCount: 0,
        gapCount: 0,
        bytesBeforeFooter: prefix.length,
      ),
    );
    final csv = TelemetryExportCodec.encodeCsv(session);
    expect(csv, contains('calculated'));
    expect(csv, contains('display'));
    final json = utf8.decode(TelemetryExportCodec.encodeJson(session));
    expect(json, contains('"origin":"calculated"'));
    expect(json, contains('wheelWatts'));
    final status = AvailabilityPolicy.forRecordedEvent(
      definition: hp.definition,
      event: events.single,
      source: TelemetrySource.demo,
    );
    expect(status.origin, DatumOrigin.calculated);
    expect(status.badgeLabels, contains('估算'));
    expect(status.formula, AvailabilityPolicy.horsepowerFormula);
  });
}

final class _MemorySource implements TelemetryChunkSource {
  _MemorySource(this.bytes);

  final Uint8List bytes;

  @override
  Future<Uint8List> read(int offset, int maximumBytes) async {
    if (offset >= bytes.length) return Uint8List(0);
    final end = (offset + maximumBytes).clamp(0, bytes.length);
    return Uint8List.sublistView(bytes, offset, end);
  }
}
