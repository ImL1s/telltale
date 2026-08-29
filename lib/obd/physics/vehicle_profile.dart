/// Vehicle parameters the physics engine needs.
///
/// None of these can be read off the OBD bus, so the user supplies them in
/// settings. Every derived figure — fuel consumption, horsepower, torque — is
/// only as good as these numbers, which the settings screen says out loud.
library;

enum FuelType {
  gasoline('汽油', 14.7, 740),
  diesel('柴油', 14.5, 835),
  lpg('液化石油氣 (LPG)', 15.6, 540),
  ethanolE85('E85 酒精汽油', 9.8, 782);

  const FuelType(this.label, this.stoichAfr, this.densityGPerL);

  final String label;

  /// Stoichiometric air-fuel ratio by mass.
  final double stoichAfr;

  /// Fuel mass density in g/L.
  final double densityGPerL;
}

enum Drivetrain {
  fwd('前輪驅動', 0.85),
  rwd('後輪驅動', 0.85),
  awd('四輪驅動', 0.80);

  const Drivetrain(this.label, this.efficiency);

  final String label;

  /// Fraction of crank power that reaches the road.
  final double efficiency;
}

class VehicleProfile {
  static const int schemaVersion = 1;

  static const double minDisplacementL = 0.6;
  static const double maxDisplacementL = 8.0;
  static const double minMassKg = 600;
  static const double maxMassKg = 3500;
  static const double minVolumetricEfficiency = 50;
  static const double maxVolumetricEfficiency = 130;
  static const double minDragCoefficient = 0.15;
  static const double maxDragCoefficient = 0.60;
  static const double minFrontalAreaM2 = 1.4;
  static const double maxFrontalAreaM2 = 4.0;
  static const double minRollingResistance = 0.006;
  static const double maxRollingResistance = 0.030;

  /// Engine swept volume, litres.
  final double displacementL;

  /// Kerb mass plus occupants, kg.
  final double massKg;

  /// Volumetric efficiency, percent. ~85 for a healthy naturally-aspirated
  /// engine; forced induction can exceed 100.
  final double volumetricEfficiency;

  final FuelType fuelType;
  final Drivetrain drivetrain;

  /// Aerodynamic drag coefficient.
  final double dragCoefficient;

  /// Frontal area, m².
  final double frontalAreaM2;

  /// Tyre rolling resistance coefficient.
  final double rollingResistance;

  /// Whether the driver has reviewed this complete set of assumptions.
  ///
  /// This is deliberately not inferred from plausible-looking values. The
  /// defaults are only an editable starting point and cannot identify any
  /// particular vehicle. Profile-dependent figures stay hidden until the
  /// driver confirms them, and editing any field invalidates that confirmation.
  final bool _confirmationRequested;

  /// True only when confirmation was requested for a valid complete profile.
  ///
  /// The private backing field keeps even direct constructor calls fail
  /// closed: a caller cannot make an out-of-range profile trustworthy merely
  /// by passing `isConfirmed: true`.
  bool get isConfirmed => _confirmationRequested && hasValidAssumptions;

  const VehicleProfile({
    this.displacementL = 2.0,
    this.massKg = 1500,
    this.volumetricEfficiency = 85,
    this.fuelType = FuelType.gasoline,
    this.drivetrain = Drivetrain.fwd,
    this.dragCoefficient = 0.30,
    this.frontalAreaM2 = 2.2,
    this.rollingResistance = 0.015,
    bool isConfirmed = false,
  }) : _confirmationRequested = isConfirmed;

  double get drivetrainEfficiency => drivetrain.efficiency;
  double get stoichAfr => fuelType.stoichAfr;
  double get fuelDensityGPerL => fuelType.densityGPerL;

  bool get hasValidAssumptions =>
      _inRange(displacementL, minDisplacementL, maxDisplacementL) &&
      _inRange(massKg, minMassKg, maxMassKg) &&
      _inRange(
        volumetricEfficiency,
        minVolumetricEfficiency,
        maxVolumetricEfficiency,
      ) &&
      _inRange(dragCoefficient, minDragCoefficient, maxDragCoefficient) &&
      _inRange(frontalAreaM2, minFrontalAreaM2, maxFrontalAreaM2) &&
      _inRange(rollingResistance, minRollingResistance, maxRollingResistance);

  VehicleProfile copyWith({
    double? displacementL,
    double? massKg,
    double? volumetricEfficiency,
    FuelType? fuelType,
    Drivetrain? drivetrain,
    double? dragCoefficient,
    double? frontalAreaM2,
    double? rollingResistance,
    bool? isConfirmed,
  }) {
    final assumptionsChanged =
        displacementL != null ||
        massKg != null ||
        volumetricEfficiency != null ||
        fuelType != null ||
        drivetrain != null ||
        dragCoefficient != null ||
        frontalAreaM2 != null ||
        rollingResistance != null;
    return VehicleProfile(
      displacementL: displacementL ?? this.displacementL,
      massKg: massKg ?? this.massKg,
      volumetricEfficiency: volumetricEfficiency ?? this.volumetricEfficiency,
      fuelType: fuelType ?? this.fuelType,
      drivetrain: drivetrain ?? this.drivetrain,
      dragCoefficient: dragCoefficient ?? this.dragCoefficient,
      frontalAreaM2: frontalAreaM2 ?? this.frontalAreaM2,
      rollingResistance: rollingResistance ?? this.rollingResistance,
      // Changing any assumption always invalidates the whole review, even if
      // a caller also tries to pass `isConfirmed: true` in the same call.
      isConfirmed: assumptionsChanged
          ? false
          : (isConfirmed ?? this.isConfirmed),
    );
  }

  /// Requests confirmation without changing any assumption.
  ///
  /// [isConfirmed] still remains false when the assumptions are invalid.
  VehicleProfile confirmAssumptions() => copyWith(isConfirmed: true);

  VehicleProfile unconfirmed() => copyWith(isConfirmed: false);

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'displacementL': displacementL,
    'massKg': massKg,
    'volumetricEfficiency': volumetricEfficiency,
    'fuelType': fuelType.name,
    'drivetrain': drivetrain.name,
    'dragCoefficient': dragCoefficient,
    'frontalAreaM2': frontalAreaM2,
    'rollingResistance': rollingResistance,
    'isConfirmed': isConfirmed,
  };

  factory VehicleProfile.fromJson(Map<String, dynamic> json) {
    final displacementL = _boundedNumber(
      json['displacementL'],
      fallback: 2.0,
      min: minDisplacementL,
      max: maxDisplacementL,
    );
    final massKg = _boundedNumber(
      json['massKg'],
      fallback: 1500,
      min: minMassKg,
      max: maxMassKg,
    );
    final volumetricEfficiency = _boundedNumber(
      json['volumetricEfficiency'],
      fallback: 85,
      min: minVolumetricEfficiency,
      max: maxVolumetricEfficiency,
    );
    final dragCoefficient = _boundedNumber(
      json['dragCoefficient'],
      fallback: 0.30,
      min: minDragCoefficient,
      max: maxDragCoefficient,
    );
    final frontalAreaM2 = _boundedNumber(
      json['frontalAreaM2'],
      fallback: 2.2,
      min: minFrontalAreaM2,
      max: maxFrontalAreaM2,
    );
    final rollingResistance = _boundedNumber(
      json['rollingResistance'],
      fallback: 0.015,
      min: minRollingResistance,
      max: maxRollingResistance,
    );
    final fuelType = FuelType.values.firstWhere(
      (fuel) => fuel.name == json['fuelType'],
      orElse: () => FuelType.gasoline,
    );
    final drivetrain = Drivetrain.values.firstWhere(
      (drive) => drive.name == json['drivetrain'],
      orElse: () => Drivetrain.fwd,
    );

    // Confirmation is meaningful only for the exact, complete schema the
    // driver reviewed. A partial/corrupt object must not fill its missing
    // fields from generic defaults and carry `isConfirmed: true` with it.
    final confirmationIsValid =
        json['isConfirmed'] == true &&
        json['schemaVersion'] is int &&
        json['schemaVersion'] == schemaVersion &&
        _isValidRawNumber(
          json['displacementL'],
          minDisplacementL,
          maxDisplacementL,
        ) &&
        _isValidRawNumber(json['massKg'], minMassKg, maxMassKg) &&
        _isValidRawNumber(
          json['volumetricEfficiency'],
          minVolumetricEfficiency,
          maxVolumetricEfficiency,
        ) &&
        _isValidRawNumber(
          json['dragCoefficient'],
          minDragCoefficient,
          maxDragCoefficient,
        ) &&
        _isValidRawNumber(
          json['frontalAreaM2'],
          minFrontalAreaM2,
          maxFrontalAreaM2,
        ) &&
        _isValidRawNumber(
          json['rollingResistance'],
          minRollingResistance,
          maxRollingResistance,
        ) &&
        json['fuelType'] == fuelType.name &&
        json['drivetrain'] == drivetrain.name;

    return VehicleProfile(
      displacementL: displacementL,
      massKg: massKg,
      volumetricEfficiency: volumetricEfficiency,
      fuelType: fuelType,
      drivetrain: drivetrain,
      dragCoefficient: dragCoefficient,
      frontalAreaM2: frontalAreaM2,
      rollingResistance: rollingResistance,
      isConfirmed: confirmationIsValid,
    );
  }

  static bool _inRange(double value, double min, double max) =>
      value.isFinite && value >= min && value <= max;

  static bool _isValidRawNumber(Object? raw, double min, double max) =>
      raw is num && _inRange(raw.toDouble(), min, max);

  static double _boundedNumber(
    Object? raw, {
    required double fallback,
    required double min,
    required double max,
  }) {
    if (raw is! num) return fallback;
    final value = raw.toDouble();
    if (!value.isFinite) return fallback;
    return value.clamp(min, max).toDouble();
  }
}
