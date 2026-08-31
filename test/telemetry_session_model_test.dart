import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';

TelemetrySignalDefinition signal({
  String id = 'rpm',
  String name = '引擎轉速',
  String shortName = 'RPM',
  String request = '01 0C',
  String header = '',
  String unit = 'rpm',
  UnitProvenance provenance = UnitProvenance.standardDirectCanonical,
  double? min = 0,
  double? max = 8000,
  bool isCustom = false,
  String variant = '',
  int priority = 0,
  String equation = '(A*256+B)/4',
}) => TelemetrySignalDefinition(
  id: id,
  name: name,
  shortName: shortName,
  request: request,
  header: header,
  unit: unit,
  unitProvenance: provenance,
  minimum: min,
  maximum: max,
  isCustom: isCustom,
  variant: variant,
  priority: priority,
  equation: equation,
);

void main() {
  test('canonical definition and ordered configuration use exact FNV-1a64', () {
    final frozen = FrozenPidDefinition.freeze(signal());
    expect(
      utf8.decode(frozen.canonicalBytes),
      '{"id":"rpm","name":"引擎轉速","shortName":"RPM","request":"01 0C","header":"","unit":"rpm","unitProvenance":"standardDirectCanonical","minimum":0.0,"maximum":8000.0,"isCustom":false,"variant":"","priority":0,"equation":"(A*256+B)/4"}',
    );
    expect(frozen.fingerprint, matches(RegExp(r'^fnv1a64:[0-9a-f]{16}$')));
    expect(frozen.matchesExact(FrozenPidDefinition.freeze(signal())), isTrue);
    expect(
      frozen.matchesExact(FrozenPidDefinition.freeze(signal(name: 'other'))),
      isFalse,
    );
    expect(
      frozen.matchesFingerprintAndCanonicalBytes(
        claimedFingerprint: frozen.fingerprint,
        claimedCanonicalBytes: FrozenPidDefinition.freeze(
          signal(name: 'collision fixture'),
        ).canonicalBytes,
      ),
      isFalse,
      reason: 'a synthetic matching hash claim cannot bypass exact bytes',
    );

    final a = FrozenPidDefinition.freeze(signal());
    final b = FrozenPidDefinition.freeze(signal(id: 'speed', request: '01 0D'));
    expect(
      configurationFingerprint([a, b]),
      isNot(configurationFingerprint([b, a])),
    );
    expect(fnv1a64(const []), 'fnv1a64:cbf29ce484222325');
    expect(fnv1a64(utf8.encode('hello')), 'fnv1a64:a430d84680aabd0b');

    final changed = <TelemetrySignalDefinition>[
      signal(name: 'other'),
      signal(shortName: 'R'),
      signal(request: '01 0D'),
      signal(header: '7E0'),
      signal(unit: 'r/min'),
      signal(provenance: UnitProvenance.userDefined, isCustom: true),
      signal(min: -1),
      signal(max: 9000),
      signal(isCustom: true, provenance: UnitProvenance.userDefined),
      signal(variant: 'v2', provenance: UnitProvenance.shippedDerivedOrVariant),
      signal(priority: 1),
      signal(equation: 'A'),
    ];
    for (final candidate in changed) {
      expect(
        FrozenPidDefinition.freeze(candidate).fingerprint,
        isNot(frozen.fingerprint),
      );
    }
  });

  test('header enforces 1..32 unique ordered signals and safe provenance', () {
    final frozen = FrozenPidDefinition.freeze(signal());
    final header = TelemetrySessionHeader(
      sessionId: '0123456789abcdef0123456789abcdef',
      startedAtUtc: DateTime.utc(2026),
      source: TelemetrySource.fieldAppConnection,
      transport: TransportKind.wifi,
      protocol: 'ISO 15765-4 CAN',
      signals: [frozen],
    );
    expect(header.configurationFingerprint, configurationFingerprint([frozen]));
    expect(header.source.wireName, 'fieldAppConnection');
    expect(header.source.wireName, isNot(contains('realVehicle')));
    expect(
      deriveTelemetrySource(
        transport: TransportKind.demo,
        requiresSimulatedEvidence: false,
      ),
      TelemetrySource.demo,
    );
    expect(
      deriveTelemetrySource(
        transport: TransportKind.bluetoothLe,
        requiresSimulatedEvidence: true,
      ),
      TelemetrySource.simulatedRig,
    );
    expect(
      UnitProvenance.standardDirectCanonical.allowsFutureAutomaticConversion,
      isTrue,
    );
    expect(
      UnitProvenance.shippedDerivedOrVariant.allowsFutureAutomaticConversion,
      isFalse,
    );
    expect(
      () => TelemetrySessionHeader(
        sessionId: header.sessionId,
        startedAtUtc: header.startedAtUtc,
        source: header.source,
        transport: header.transport,
        protocol: header.protocol,
        signals: const [],
      ),
      throwsA(isA<TelemetryValidationException>()),
    );
    expect(
      () => TelemetrySessionHeader(
        sessionId: header.sessionId,
        startedAtUtc: header.startedAtUtc,
        source: header.source,
        transport: header.transport,
        protocol: header.protocol,
        signals: [frozen, frozen],
      ),
      throwsA(isA<TelemetryValidationException>()),
    );
  });

  test('source and transport provenance is fail-closed', () {
    final frozen = FrozenPidDefinition.freeze(signal());
    TelemetrySessionHeader build(
      TelemetrySource source,
      TransportKind transport,
    ) => TelemetrySessionHeader(
      sessionId: '0123456789abcdef0123456789abcdef',
      startedAtUtc: DateTime.utc(2026),
      source: source,
      transport: transport,
      protocol: 'AUTO',
      signals: [frozen],
    );

    expect(
      () => build(TelemetrySource.demo, TransportKind.wifi),
      throwsA(isA<TelemetryValidationException>()),
    );
    expect(
      () => build(TelemetrySource.fieldAppConnection, TransportKind.demo),
      throwsA(isA<TelemetryValidationException>()),
    );
    expect(build(TelemetrySource.demo, TransportKind.demo), isNotNull);
  });

  test('definition provenance and priority invariants are fail-closed', () {
    expect(
      () => FrozenPidDefinition.freeze(signal(isCustom: true)),
      throwsA(isA<TelemetryValidationException>()),
    );
    expect(
      () => FrozenPidDefinition.freeze(
        signal(provenance: UnitProvenance.userDefined),
      ),
      throwsA(isA<TelemetryValidationException>()),
    );
    expect(
      () => FrozenPidDefinition.freeze(signal(variant: 'derived')),
      throwsA(isA<TelemetryValidationException>()),
    );
    expect(
      () => FrozenPidDefinition.freeze(signal(request: 'garbage')),
      throwsA(isA<TelemetryValidationException>()),
    );
    expect(
      () => FrozenPidDefinition.freeze(signal(header: 'not-hex')),
      throwsA(isA<TelemetryValidationException>()),
    );
    expect(
      () => FrozenPidDefinition.freeze(signal(unit: '')),
      throwsA(isA<TelemetryValidationException>()),
    );
    expect(
      () => FrozenPidDefinition.freeze(
        signal(provenance: UnitProvenance.shippedDerivedOrVariant),
      ),
      throwsA(isA<TelemetryValidationException>()),
    );
    expect(
      () => FrozenPidDefinition.freeze(signal(header: '7E1')),
      throwsA(isA<TelemetryValidationException>()),
    );
    expect(
      () => FrozenPidDefinition.freeze(signal(priority: 4)),
      throwsA(isA<TelemetryValidationException>()),
    );
    expect(
      FrozenPidDefinition.freeze(
        signal(
          isCustom: true,
          provenance: UnitProvenance.userDefined,
          variant: 'owner-defined',
        ),
      ),
      isNotNull,
    );
  });

  test(
    'events and footer validate time, finite values, and independent counts',
    () {
      final observed = DateTime.utc(2026, 1, 1);
      expect(
        TelemetryEvent.value(
          observedAtUtc: observed,
          sourceTimestampUtc: observed.subtract(
            const Duration(milliseconds: 3),
          ),
          elapsedUs: 1,
          pidId: 'rpm',
          value: 1234.5,
        ).value,
        1234.5,
      );
      expect(
        () => TelemetryEvent.value(
          observedAtUtc: observed,
          sourceTimestampUtc: observed,
          elapsedUs: 1,
          pidId: 'rpm',
          value: double.nan,
        ),
        throwsA(isA<TelemetryValidationException>()),
      );
      expect(
        TelemetryEvent.status(
          observedAtUtc: observed,
          elapsedUs: 2,
          pidId: 'rpm',
          status: TelemetryStatus.noAnswer,
        ).value,
        isNull,
      );
      final footer = TelemetrySessionFooter(
        endedAtUtc: observed,
        terminalReason: TelemetryTerminalReason.user,
        valueCount: 1,
        statusCount: 2,
        gapCount: 1,
        bytesBeforeFooter: 99,
      );
      expect(footer.statusCount, 2);
    },
  );
}
