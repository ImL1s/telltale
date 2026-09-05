/// Frozen derived horsepower / fuel-rate signals for recording and export.
library;

import '../../diagnostics/availability.dart';
import '../../obd/physics/physics_engine.dart';
import '../../obd/physics/vehicle_profile.dart';
import '../../obd/pid/pid.dart';
import '../../obd/pid/pid_library.dart';
import '../../obd/telemetry.dart';
import 'telemetry_recorder.dart';
import 'telemetry_session.dart';

abstract final class DerivedEstimates {
  static const horsepowerVariant = 'derived-horsepower';
  static const fuelVariant = 'derived-fuel-rate';

  static const Pid horsepower = Pid(
    name: '估算馬力',
    shortName: 'hp',
    modeAndPid: '00FF',
    header: '000',
    variant: horsepowerVariant,
    equation: AvailabilityPolicy.horsepowerFormula,
    minValue: 0,
    maxValue: 2000,
    units: 'hp',
  );

  static const Pid fuelRate = Pid(
    name: '估算油耗',
    shortName: 'L/h',
    modeAndPid: '00FE',
    header: '000',
    variant: fuelVariant,
    equation: AvailabilityPolicy.fuelEstimateFormula,
    minValue: 0,
    maxValue: 100,
    units: 'L/h',
  );

  static bool isDerived(TelemetrySignalDefinition definition) =>
      definition.variant.startsWith('derived-');

  static bool isDerivedId(String id) =>
      id == horsepower.id || id == fuelRate.id;

  static List<FrozenPidDefinition> appendTo(
    List<FrozenPidDefinition> signals,
  ) {
    final extra = <FrozenPidDefinition>[
      freezePidDefinition(horsepower),
      freezePidDefinition(fuelRate),
    ];
    final room = maximumTelemetrySignals - signals.length;
    if (room <= 0) return signals;
    return [...signals, ...extra.take(room)];
  }

  static Map<String, double> valuesFor({
    required TelemetrySnapshot snapshot,
    required VehicleProfile profile,
  }) {
    final clock = snapshot.capturedAt;
    final rpm = snapshot.valueOf(PidLibrary.engineRpm, now: clock);
    final speed = snapshot.valueOf(PidLibrary.vehicleSpeed, now: clock);
    final accel = snapshot.accelerationMs2;
    if (rpm == null || speed == null || accel == null) return const {};
    final metrics = PhysicsEngine.derive(
      profile: profile,
      rpm: rpm,
      speedKmh: speed,
      accelMs2: accel,
      mafSensorGps: snapshot.valueOf(PidLibrary.mafRate, now: clock),
      mapKpa: snapshot.valueOf(PidLibrary.manifoldPressure, now: clock),
      intakeTempC: snapshot.valueOf(PidLibrary.intakeAirTemp, now: clock),
      fuelRateSensorLPerHour: snapshot.valueOf(
        PidLibrary.engineFuelRate,
        now: clock,
      ),
    );
    final values = <String, double>{};
    if (metrics.engineHorsepower.isFinite) {
      values[horsepower.id] = metrics.engineHorsepower;
    }
    if (metrics.fuelSource == FuelSource.stoichiometricEstimate &&
        metrics.fuelRateLPerHour != null &&
        metrics.fuelRateLPerHour!.isFinite) {
      values[fuelRate.id] = metrics.fuelRateLPerHour!;
    }
    return values;
  }
}
