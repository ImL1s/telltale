/// Vehicle physics derivations.
///
/// Every constant here was re-derived from first principles rather than copied,
/// because the source spec is reverse-engineering notes rather than a standard.
/// The derivations are recorded in `SPEC_DEVIATIONS.md`; they agreed with the
/// spec in each case.
///
/// These are estimates. Wheel horsepower from OBD speed deltas is a genuinely
/// noisy measurement, and the results are only as good as the [VehicleProfile]
/// the user entered — the UI presents them as estimates, not dyno figures.
library;

import 'dart:math' as math;

import 'vehicle_profile.dart';

/// Everything the physics engine derives from one sample of live data.
/// Where an air-mass figure came from.
enum AirflowSource {
  /// The vehicle's own MAF sensor.
  measured,

  /// Computed from engine speed, manifold pressure and intake temperature.
  speedDensity,

  /// Neither was available. Not the same as zero air flow, which would mean a
  /// stopped engine.
  unavailable;

  String get label => switch (this) {
        AirflowSource.measured => 'MAF 感測器',
        AirflowSource.speedDensity => 'Speed-Density 推算',
        AirflowSource.unavailable => '無法取得',
      };
}

/// Where a fuel figure came from.
enum FuelSource {
  /// PID 015E — the ECU's own fuel rate, which accounts for the mixture the
  /// engine is actually running.
  measured,

  /// Derived from air mass assuming a stoichiometric mixture. Wrong by roughly
  /// the lambda the engine is running: a diesel at lambda 2 gets an estimate
  /// about twice the real consumption.
  stoichiometricEstimate,

  unavailable;

  String get label => switch (this) {
        FuelSource.measured => 'ECU 回報',
        FuelSource.stoichiometricEstimate => '化學計量比推算',
        FuelSource.unavailable => '無法取得',
      };
}

class DerivedMetrics {
  /// Air mass flow, g/s, or null when neither a sensor reading nor the full
  /// speed-density input set was available.
  ///
  /// Nullable rather than zero: substituting `MAP = 0` and `IAT = 20 °C` for
  /// missing inputs produced a confident `0.0 g/s` on the tile, which is what
  /// a stopped engine looks like, from a car at 3000 rpm.
  final double? mafGramsPerSecond;

  final AirflowSource airflowSource;

  /// Volumetric fuel flow, L/h, or null when it could not be established.
  final double? fuelRateLPerHour;

  final FuelSource fuelSource;

  /// Instantaneous consumption, or null while stationary or unavailable.
  final double? litresPer100Km;
  final double? milesPerGallonUs;

  final double wheelHorsepower;
  final double engineHorsepower;
  final double torqueNm;
  final double torqueFtLb;

  const DerivedMetrics({
    this.mafGramsPerSecond,
    this.airflowSource = AirflowSource.unavailable,
    this.fuelRateLPerHour,
    this.fuelSource = FuelSource.unavailable,
    this.litresPer100Km,
    this.milesPerGallonUs,
    this.wheelHorsepower = 0,
    this.engineHorsepower = 0,
    this.torqueNm = 0,
    this.torqueFtLb = 0,
  });

  /// True when consumption can be expressed per distance rather than per hour.
  bool get isMoving => litresPer100Km != null;

  bool get mafIsEstimated => airflowSource == AirflowSource.speedDensity;
}

abstract final class PhysicsEngine {
  /// Mean molar mass of dry air, g/mol.
  static const double molarMassAir = 28.97;

  /// Universal gas constant, J/(mol·K).
  static const double gasConstant = 8.314;

  /// Air density at sea level, 15 °C, kg/m³.
  static const double airDensity = 1.225;

  static const double gravity = 9.80665;

  /// Watts per mechanical horsepower.
  static const double wattsPerHp = 745.699871582;

  /// 100 km = 62.13712 mi and 1 US gal = 3.785411784 L, so
  /// mpg × (L/100km) = 62.13712 × 3.785411784.
  static const double mpgLper100kmProduct = 235.2145833;

  static const double kmhToMs = 1 / 3.6;
  static const double ftLbPerNm = 0.737562149;

  /// Below this speed, distance-based consumption is meaningless.
  static const double minSpeedForConsumption = 2.0;

  /// Speed-density air mass flow, g/s.
  ///
  /// A four-stroke engine draws one full swept volume every two revolutions,
  /// so volumetric flow is `RPM × Vd / 120` L/s. Feeding that through the ideal
  /// gas law and multiplying by air's molar mass gives mass flow:
  ///
  ///     MAF = RPM × MAP × Vd × 28.97 / (120 × R × T) × VE/100
  /// Null rather than zero when the inputs cannot produce a flow.
  ///
  /// It returned 0 for a non-positive MAP, and `derive` only checked that MAP
  /// was *present*. So a failed sensor answering `41 0B 00` — 0 kPa, which a
  /// running engine cannot produce — came out as a confident **0.0 g/s**
  /// labelled 「Speed-Density 推算」, beside a fuel rate that showed `--`
  /// because its own guard is `maf > 0`. One row contradicting itself, and the
  /// airflow half saying the engine is not breathing while the rev counter says
  /// 3000 rpm.
  ///
  /// [mafGramsPerSecond]'s own doc comment records this exact failure as
  /// already fixed — "substituting MAP = 0 produced a confident 0.0 g/s on the
  /// tile, which is what a stopped engine looks like, from a car at 3000 rpm".
  /// It came back through a different door: the type said the answer always
  /// exists, so the caller had nothing to check.
  static double? speedDensityMaf({
    required double rpm,
    required double mapKpa,
    required double intakeTempC,
    required double displacementL,
    required double volumetricEfficiencyPct,
  }) {
    // Volumetric efficiency is in the guard too. It comes from the vehicle
    // profile, whose slider is bounded 50–130 — but `VehicleProfile.fromJson`
    // does not clamp, so a corrupted preference or a schema from another
    // version reaches here unchecked. Zero produces the same confident 0.0 g/s
    // this function was made nullable to prevent; negative produces a negative
    // air mass.
    if (rpm <= 0 ||
        mapKpa <= 0 ||
        displacementL <= 0 ||
        volumetricEfficiencyPct <= 0) {
      return null;
    }
    final tempK = intakeTempC + 273.15;
    if (tempK <= 0) return null;

    final numerator = rpm * mapKpa * displacementL * molarMassAir;
    final denominator = 120 * gasConstant * tempK;
    return numerator / denominator * (volumetricEfficiencyPct / 100);
  }

  /// Volumetric fuel flow, L/h.
  ///
  /// Fuel mass rate is air mass rate divided by the air-fuel ratio; dividing by
  /// density and scaling to the hour gives volume.
  static double fuelRateLPerHour({
    required double mafGramsPerSecond,
    required double stoichAfr,
    required double fuelDensityGPerL,
    double lambda = 1.0,
  }) {
    if (mafGramsPerSecond <= 0 || stoichAfr <= 0 || fuelDensityGPerL <= 0 || lambda <= 0) {
      return 0;
    }
    final fuelMassGPerSecond = mafGramsPerSecond / (stoichAfr * lambda);
    return fuelMassGPerSecond * 3600 / fuelDensityGPerL;
  }

  /// Total power at the wheels, watts.
  ///
  ///     P = m·a·v  +  ½·ρ·Cd·A·v³  +  Crr·m·g·v
  ///
  /// The three terms are inertia, aerodynamic drag and rolling resistance.
  /// Negative under braking, which is physically correct and why the UI clamps
  /// the horsepower gauge at zero rather than the maths doing it.
  static double wheelPowerWatts({
    required double massKg,
    required double accelMs2,
    required double speedKmh,
    required double dragCoefficient,
    required double frontalAreaM2,
    required double rollingResistance,
  }) {
    if (speedKmh <= 0) return 0;
    final v = speedKmh * kmhToMs;
    final inertial = massKg * accelMs2 * v;
    final aero = 0.5 * airDensity * dragCoefficient * frontalAreaM2 * v * v * v;
    final rolling = rollingResistance * massKg * gravity * v;
    return inertial + aero + rolling;
  }

  /// Crank torque from power and engine speed.
  ///
  /// `P = τ·ω` with ω in rad/s, so `τ = P / (2π·RPM/60)`.
  static double torqueNmFromPower({required double powerWatts, required double rpm}) {
    if (rpm <= 0 || powerWatts <= 0) return 0;
    final omega = 2 * math.pi * rpm / 60;
    return powerWatts / omega;
  }

  /// Runs the whole chain for one sample.
  ///
  /// [mafSensorGps] is the reading from PID 0110 when the vehicle has a MAF
  /// sensor; pass null and the speed-density path fills in from MAP, IAT and
  /// RPM instead.
  static DerivedMetrics derive({
    required VehicleProfile profile,
    required double rpm,
    required double speedKmh,
    required double accelMs2,
    double? mafSensorGps,
    double? mapKpa,
    double? intakeTempC,
    double? fuelRateSensorLPerHour,
  }) {
    // Air mass: measured, computed from a *complete* input set, or unavailable.
    //
    // The middle case used to accept partial inputs, defaulting `MAP` to 0 and
    // `IAT` to 20 °C. Zero manifold pressure makes the whole product zero, so a
    // running engine reported 0.0 g/s; and assuming 20 °C when the intake is
    // actually at 80 °C overstates air mass by around a fifth, which then flows
    // straight into the consumption figure. An assumed ambient temperature is
    // not a conservative fallback, it is an invented measurement.
    final double? maf;
    final AirflowSource airflowSource;

    if (mafSensorGps != null && mafSensorGps > 0) {
      maf = mafSensorGps;
      airflowSource = AirflowSource.measured;
    } else {
      // Computed once, and the source is set from whether it produced an
      // answer rather than from whether the inputs were merely present.
      final estimated = (mapKpa != null && intakeTempC != null)
          ? speedDensityMaf(
              rpm: rpm,
              mapKpa: mapKpa,
              intakeTempC: intakeTempC,
              displacementL: profile.displacementL,
              volumetricEfficiencyPct: profile.volumetricEfficiency,
            )
          : null;
      maf = estimated;
      airflowSource = estimated == null
          ? AirflowSource.unavailable
          : AirflowSource.speedDensity;
    }

    // Fuel: the ECU's own figure where the vehicle reports it, because that
    // accounts for the mixture actually being run. The stoichiometric estimate
    // is wrong by roughly lambda — a diesel at lambda 2 comes out about twice
    // its real consumption — so it is used only as a fallback, and labelled.
    final double? fuelRate;
    final FuelSource fuelSource;

    // `>= 0`, not `> 0`. Zero is a measurement: during deceleration fuel cut
    // the ECU reports exactly 0.0 L/h while RPM, speed and MAF stay positive,
    // and treating that as "no sensor" replaced a figure the vehicle supplied
    // with a stoichiometric estimate it did not. The estimate is labelled as
    // derived, which is honest about its provenance and still the wrong
    // number.
    if (fuelRateSensorLPerHour != null &&
        fuelRateSensorLPerHour.isFinite &&
        fuelRateSensorLPerHour >= 0) {
      fuelRate = fuelRateSensorLPerHour;
      fuelSource = FuelSource.measured;
    } else if (maf != null && maf > 0) {
      fuelRate = fuelRateLPerHour(
        mafGramsPerSecond: maf,
        stoichAfr: profile.stoichAfr,
        fuelDensityGPerL: profile.fuelDensityGPerL,
      );
      fuelSource = FuelSource.stoichiometricEstimate;
    } else {
      fuelRate = null;
      fuelSource = FuelSource.unavailable;
    }

    double? lPer100;
    double? mpg;
    if (fuelRate != null &&
        fuelRate > 0 &&
        speedKmh > minSpeedForConsumption) {
      lPer100 = fuelRate / speedKmh * 100;
      mpg = lPer100 > 0 ? mpgLper100kmProduct / lPer100 : null;
    }

    final wheelWatts = wheelPowerWatts(
      massKg: profile.massKg,
      accelMs2: accelMs2,
      speedKmh: speedKmh,
      dragCoefficient: profile.dragCoefficient,
      frontalAreaM2: profile.frontalAreaM2,
      rollingResistance: profile.rollingResistance,
    );
    final wheelHp = wheelWatts / wattsPerHp;
    final engineHp = profile.drivetrainEfficiency > 0
        ? wheelHp / profile.drivetrainEfficiency
        : wheelHp;
    final engineWatts = engineHp * wattsPerHp;
    final torqueNm = torqueNmFromPower(powerWatts: engineWatts, rpm: rpm);

    return DerivedMetrics(
      mafGramsPerSecond: maf,
      airflowSource: airflowSource,
      fuelRateLPerHour: fuelRate,
      fuelSource: fuelSource,
      litresPer100Km: lPer100,
      milesPerGallonUs: mpg,
      wheelHorsepower: wheelHp,
      engineHorsepower: engineHp,
      torqueNm: torqueNm,
      torqueFtLb: torqueNm * ftLbPerNm,
    );
  }
}

/// Low-pass filter for gauge needles.
///
/// `y[t] = y[t-1] + α·(x[t] − y[t-1])`
///
/// Raw OBD samples arrive unevenly and step visibly; without this the needle
/// jitters. α trades smoothness against lag — 0.15-0.30 is the usable band, and
/// the default sits at the responsive end because a laggy tachometer reads as
/// broken.
class EmaFilter {
  EmaFilter({double initialValue = 0, double alpha = 0.25})
      : _value = initialValue,
        _alpha = alpha.clamp(0.01, 1.0);

  double _value;
  final double _alpha;
  bool _seeded = false;

  double get value => _value;

  /// True once a real sample has been folded in.
  ///
  /// The distinction matters to callers that must not publish a smoothed
  /// figure before anything has been measured: an unseeded filter reads 0,
  /// and 0 m/s² is "steady cruise", not "unknown".
  bool get isSeeded => _seeded;

  double update(double target) {
    if (target.isNaN || target.isInfinite) return _value;
    // Snap to the first real sample rather than sweeping up from zero, which
    // would make every gauge animate from empty on connect.
    if (!_seeded) {
      _seeded = true;
      _value = target;
      return _value;
    }
    _value += _alpha * (target - _value);
    return _value;
  }

  void reset([double value = 0]) {
    _value = value;
    _seeded = false;
  }
}
