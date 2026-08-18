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

  const VehicleProfile({
    this.displacementL = 2.0,
    this.massKg = 1500,
    this.volumetricEfficiency = 85,
    this.fuelType = FuelType.gasoline,
    this.drivetrain = Drivetrain.fwd,
    this.dragCoefficient = 0.30,
    this.frontalAreaM2 = 2.2,
    this.rollingResistance = 0.015,
  });

  double get drivetrainEfficiency => drivetrain.efficiency;
  double get stoichAfr => fuelType.stoichAfr;
  double get fuelDensityGPerL => fuelType.densityGPerL;

  VehicleProfile copyWith({
    double? displacementL,
    double? massKg,
    double? volumetricEfficiency,
    FuelType? fuelType,
    Drivetrain? drivetrain,
    double? dragCoefficient,
    double? frontalAreaM2,
    double? rollingResistance,
  }) {
    return VehicleProfile(
      displacementL: displacementL ?? this.displacementL,
      massKg: massKg ?? this.massKg,
      volumetricEfficiency: volumetricEfficiency ?? this.volumetricEfficiency,
      fuelType: fuelType ?? this.fuelType,
      drivetrain: drivetrain ?? this.drivetrain,
      dragCoefficient: dragCoefficient ?? this.dragCoefficient,
      frontalAreaM2: frontalAreaM2 ?? this.frontalAreaM2,
      rollingResistance: rollingResistance ?? this.rollingResistance,
    );
  }

  Map<String, dynamic> toJson() => {
        'displacementL': displacementL,
        'massKg': massKg,
        'volumetricEfficiency': volumetricEfficiency,
        'fuelType': fuelType.name,
        'drivetrain': drivetrain.name,
        'dragCoefficient': dragCoefficient,
        'frontalAreaM2': frontalAreaM2,
        'rollingResistance': rollingResistance,
      };

  factory VehicleProfile.fromJson(Map<String, dynamic> json) => VehicleProfile(
        displacementL: (json['displacementL'] as num?)?.toDouble() ?? 2.0,
        massKg: (json['massKg'] as num?)?.toDouble() ?? 1500,
        volumetricEfficiency: (json['volumetricEfficiency'] as num?)?.toDouble() ?? 85,
        fuelType: FuelType.values.firstWhere(
          (f) => f.name == json['fuelType'],
          orElse: () => FuelType.gasoline,
        ),
        drivetrain: Drivetrain.values.firstWhere(
          (d) => d.name == json['drivetrain'],
          orElse: () => Drivetrain.fwd,
        ),
        dragCoefficient: (json['dragCoefficient'] as num?)?.toDouble() ?? 0.30,
        frontalAreaM2: (json['frontalAreaM2'] as num?)?.toDouble() ?? 2.2,
        rollingResistance: (json['rollingResistance'] as num?)?.toDouble() ?? 0.015,
      );
}
