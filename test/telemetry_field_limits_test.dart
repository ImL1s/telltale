import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_codec.dart';

TelemetrySignalDefinition makeSignal({
  String id = 'x',
  String name = 'n',
  String shortName = 's',
  String request = '01 0C',
  String header = '',
  String unit = 'rpm',
  String variant = '',
  String equation = 'A',
}) => TelemetrySignalDefinition(
  id: id,
  name: name,
  shortName: shortName,
  request: request,
  header: header,
  unit: unit,
  unitProvenance: request == '01 0C' && header.isEmpty && variant.isEmpty
      ? UnitProvenance.standardDirectCanonical
      : UnitProvenance.shippedDerivedOrVariant,
  minimum: 0,
  maximum: 1,
  isCustom: false,
  variant: variant,
  priority: 0,
  equation: equation,
);

String utf8Sized(int bytes) {
  final multibyteCount = bytes ~/ 3;
  return '${'車' * multibyteCount}${'a' * (bytes - multibyteCount * 3)}';
}

void main() {
  test('field limits count UTF-8 bytes and identify the field', () {
    expect(utf8.encode('車' * 170).length, 510);
    expect(FrozenPidDefinition.freeze(makeSignal(name: '車' * 170)), isNotNull);
    expect(
      () => FrozenPidDefinition.freeze(makeSignal(name: '車' * 171)),
      throwsA(
        isA<TelemetryValidationException>().having(
          (error) => error.field,
          'field',
          'name',
        ),
      ),
    );
    expect(FrozenPidDefinition.freeze(makeSignal(id: 'a' * 256)), isNotNull);
    expect(
      () => FrozenPidDefinition.freeze(makeSignal(id: 'a' * 257)),
      throwsA(isA<TelemetryValidationException>()),
    );
  });

  test(
    'every frozen text field accepts its UTF-8 limit and rejects limit+1',
    () {
      final cases = <(String, int, TelemetrySignalDefinition Function(String))>[
        ('id', 256, (value) => makeSignal(id: value)),
        ('name', 512, (value) => makeSignal(name: value)),
        ('shortName', 128, (value) => makeSignal(shortName: value)),
        ('request', 64, (value) => makeSignal(request: value)),
        ('header', 64, (value) => makeSignal(header: value)),
        ('unit', 64, (value) => makeSignal(unit: value)),
        ('variant', 128, (value) => makeSignal(variant: value)),
        ('equation', 4096, (value) => makeSignal(equation: value)),
      ];
      for (final (field, limit, build) in cases) {
        final atLimit = switch (field) {
          'request' => 'AA' * (limit ~/ 2),
          'header' => 'A' * limit,
          _ => utf8Sized(limit),
        };
        expect(utf8.encode(atLimit), hasLength(limit), reason: field);
        expect(FrozenPidDefinition.freeze(build(atLimit)), isNotNull);
        expect(
          () => FrozenPidDefinition.freeze(build('${atLimit}a')),
          throwsA(
            isA<TelemetryValidationException>().having(
              (error) => error.field,
              'field',
              field,
            ),
          ),
        );
      }
    },
  );

  test('wire line limits include LF', () {
    expect(TelemetrySessionCodec.maximumHeaderLineBytes, 64 * 1024);
    expect(TelemetrySessionCodec.maximumEventOrFooterLineBytes, 2048);
    expect(
      () => TelemetrySessionCodec.checkLineLimit(
        List<int>.filled(2048, 0x61),
        kind: TelemetryLineKind.event,
      ),
      throwsA(isA<TelemetryValidationException>()),
    );
    TelemetrySessionCodec.checkLineLimit(
      List<int>.filled(2047, 0x61),
      kind: TelemetryLineKind.event,
    );
  });

  test('protocol limit is also UTF-8 bytes', () {
    TelemetrySessionHeader build(String protocol) => TelemetrySessionHeader(
      sessionId: '0123456789abcdef0123456789abcdef',
      startedAtUtc: DateTime.utc(2026),
      source: TelemetrySource.demo,
      transport: TransportKind.demo,
      protocol: protocol,
      signals: [FrozenPidDefinition.freeze(makeSignal())],
    );
    expect(build(utf8Sized(512)), isNotNull);
    expect(
      () => build('${utf8Sized(512)}a'),
      throwsA(
        isA<TelemetryValidationException>().having(
          (error) => error.field,
          'field',
          'protocol',
        ),
      ),
    );
  });
}
