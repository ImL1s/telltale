import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/diagnostics/availability.dart';
import 'package:torque_obd/obd/physics/vehicle_profile.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
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
