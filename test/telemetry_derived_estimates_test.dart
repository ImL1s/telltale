import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/diagnostics/availability.dart';
import 'package:torque_obd/obd/physics/vehicle_profile.dart';
import 'package:torque_obd/obd/pid/pid.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/telemetry.dart';
import 'package:torque_obd/telemetry/session/derived_estimates.dart';
import 'package:torque_obd/telemetry/session/telemetry_recorder.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';

void main() {
  test('appendTo freezes the Start vehicle-profile assumptions', () {
    const profile = VehicleProfile(massKg: 1280);
    final signals = DerivedEstimates.appendTo([
      freezePidDefinition(PidLibrary.engineRpm),
    ], profile: profile);
    final hp = signals.singleWhere(
      (signal) =>
          signal.definition.variant == DerivedEstimates.horsepowerVariant,
    );
    final fuel = signals.singleWhere(
      (signal) => signal.definition.variant == DerivedEstimates.fuelVariant,
    );
    expect(hp.definition.assumptions, contains('1280'));
    expect(hp.definition.assumptions, contains('迎風面積'));
    expect(fuel.definition.assumptions, contains('AFR'));
    expect(fuel.definition.assumptions, contains('排氣量'));
    expect(fuel.definition.assumptions, contains('VE'));
    expect(fuel.definition.assumptions, isNot(contains('車重')));
    expect(hp.definition.maximum, AvailabilityPolicy.horsepowerRangeMax);
    expect(fuel.definition.maximum, AvailabilityPolicy.fuelRateRangeMax);
    expect(hp.definition.assumptionsConfirmed, isFalse);
    expect(fuel.definition.assumptionsConfirmed, isFalse);
  });

  test('appendTo freezes confirmed estimate status', () {
    const profile = VehicleProfile(massKg: 1280, isConfirmed: true);
    final signals = DerivedEstimates.appendTo([
      freezePidDefinition(PidLibrary.engineRpm),
    ], profile: profile);
    expect(
      signals
          .where((signal) => DerivedEstimates.isDerived(signal.definition))
          .every((signal) => signal.definition.assumptionsConfirmed == true),
      isTrue,
    );
  });

  test('appendTo reserves both derived slots instead of dropping fuel', () {
    final thirty = DerivedEstimates.appendTo(_liveSignals(30));
    expect(thirty, hasLength(32));
    expect(
      thirty.map((signal) => signal.definition.id),
      containsAll([
        DerivedEstimates.horsepower.id,
        DerivedEstimates.fuelRate.id,
      ]),
    );
    expect(
      () => DerivedEstimates.appendTo(_liveSignals(31)),
      throwsA(
        isA<TelemetryValidationException>().having(
          (error) => error.code,
          'code',
          'derivedEstimatesNeedRoom',
        ),
      ),
    );
    expect(
      () => DerivedEstimates.appendTo(_liveSignals(32)),
      throwsA(isA<TelemetryValidationException>()),
    );
  });

  test('fuel estimate does not require horsepower inputs', () {
    final now = DateTime.utc(2026);
    final values = DerivedEstimates.valuesFor(
      snapshot: TelemetrySnapshot(
        readings: {
          PidLibrary.mafRate.id: Reading(
            pid: PidLibrary.mafRate,
            value: 25,
            rawBytes: const [0x09, 0xc4],
            timestamp: now,
          ),
        },
        capturedAt: now,
      ),
      profile: const VehicleProfile(),
    );
    expect(values.containsKey(DerivedEstimates.horsepower.id), isFalse);
    expect(values[DerivedEstimates.fuelRate.id], isNotNull);
    expect(values[DerivedEstimates.fuelRate.id]!.isFinite, isTrue);
    expect(values[DerivedEstimates.fuelRate.id], greaterThan(0));
  });

  test('horsepower estimate does not require RPM', () {
    final now = DateTime.now();
    final values = DerivedEstimates.valuesFor(
      snapshot: TelemetrySnapshot(
        readings: {
          PidLibrary.vehicleSpeed.id: Reading(
            pid: PidLibrary.vehicleSpeed,
            value: 60,
            rawBytes: const [60],
            timestamp: now,
          ),
        },
        accelerationMs2: 0.8,
        capturedAt: now,
      ),
      profile: const VehicleProfile(),
    );
    expect(values[DerivedEstimates.horsepower.id], isNotNull);
    expect(values[DerivedEstimates.horsepower.id]!.isFinite, isTrue);
    expect(values.containsKey(PidLibrary.engineRpm.id), isFalse);
  });

  test('measured 015E does not suppress the derived fuel estimate lane', () {
    final now = DateTime.utc(2026);
    final values = DerivedEstimates.valuesFor(
      snapshot: TelemetrySnapshot(
        readings: {
          PidLibrary.mafRate.id: Reading(
            pid: PidLibrary.mafRate,
            value: 25,
            rawBytes: const [0x09, 0xc4],
            timestamp: now,
          ),
          PidLibrary.engineFuelRate.id: Reading(
            pid: PidLibrary.engineFuelRate,
            value: 6,
            rawBytes: const [0x00, 0x78],
            timestamp: now,
          ),
        },
        capturedAt: now,
      ),
      profile: const VehicleProfile(),
    );
    expect(values[DerivedEstimates.fuelRate.id], isNotNull);
    expect(values[DerivedEstimates.fuelRate.id], greaterThan(0));
  });

  test('default replay lanes prefer derived estimates over header order', () {
    final signals = DerivedEstimates.appendTo(
      [
        PidLibrary.engineRpm,
        PidLibrary.vehicleSpeed,
        PidLibrary.coolantTemp,
        PidLibrary.throttlePosition,
      ].map(freezePidDefinition).toList(),
    );
    expect(
      signals.map((signal) => signal.definition.id).take(4),
      isNot(contains(DerivedEstimates.horsepower.id)),
    );
    final lanes = DerivedEstimates.defaultReplayLaneIds(
      signals.map((signal) => signal.definition),
    );
    expect(lanes, hasLength(4));
    expect(lanes, contains(DerivedEstimates.horsepower.id));
    expect(lanes, contains(DerivedEstimates.fuelRate.id));
    final withValues = DerivedEstimates.defaultReplayLaneIds(
      signals.map((signal) => signal.definition),
      recordedIds: {
        PidLibrary.engineRpm.id,
        PidLibrary.vehicleSpeed.id,
        PidLibrary.coolantTemp.id,
        PidLibrary.throttlePosition.id,
        DerivedEstimates.horsepower.id,
      },
    );
    expect(withValues, contains(DerivedEstimates.horsepower.id));
    expect(withValues, isNot(contains(DerivedEstimates.fuelRate.id)));
    expect(withValues, contains(PidLibrary.engineRpm.id));
  });

  test(
    'imported PIDs whose variant only starts with derived- stay ECU lanes',
    () {
      final impostor = FrozenPidDefinition.freeze(
        const TelemetrySignalDefinition(
          id: 'custom:7E0:010C',
          name: 'Fake derived',
          shortName: 'fake',
          request: '01 0C',
          header: '7E0',
          unit: 'rpm',
          unitProvenance: UnitProvenance.userDefined,
          minimum: 0,
          maximum: 8000,
          isCustom: true,
          variant: 'derived-horsepower',
          priority: 1,
          equation: 'A',
        ),
      );
      expect(DerivedEstimates.isDerived(impostor.definition), isFalse);
      expect(DerivedEstimates.defaultReplayLaneIds([impostor.definition]), [
        impostor.definition.id,
      ]);
    },
  );
}

List<FrozenPidDefinition> _liveSignals(int count) => [
  for (var index = 0; index < count; index++)
    freezePidDefinition(
      Pid(
        name: 'Signal $index',
        shortName: 's$index',
        modeAndPid:
            '01${index.toRadixString(16).toUpperCase().padLeft(2, '0')}',
        equation: 'A',
        minValue: 0,
        maxValue: 1,
        units: 'x',
      ),
    ),
];
