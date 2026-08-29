/// Applies only semantically compatible fields from one exact U.S. EPA row.
///
/// EPA publishes drive layout, but [VehicleProfile.drivetrain] also embeds a
/// fixed transmission-efficiency assumption. Those are different facts, so
/// drive is deliberately not copied here. The catalog also has no curb mass,
/// torque, drag, frontal-area, rolling-resistance, or VE field.
library;

import '../physics/vehicle_evidence.dart';
import '../physics/vehicle_profile.dart';
import 'us_vehicle_catalog.dart';

final class UsEpaProfileApplication {
  const UsEpaProfileApplication({
    required this.configuration,
    required this.profile,
    required this.verifiedFieldKeys,
  });

  final UsEpaVehicleConfiguration configuration;
  final VehicleProfile profile;
  final Set<String> verifiedFieldKeys;
}

UsEpaProfileApplication applyUsEpaConfiguration(
  UsVehicleCatalog catalog, {
  required int epaId,
  VehicleProfile? baseProfile,
}) {
  final configuration = catalog.byEpaId(epaId);
  if (configuration == null) {
    throw UsVehicleCatalogException('unknown EPA vehicle id $epaId');
  }

  final evidence = _evidenceFor(catalog, configuration);
  final displacement = configuration.displacementL;
  final exactDisplacement =
      displacement != null &&
          displacement >= VehicleProfile.minDisplacementL &&
          displacement <= VehicleProfile.maxDisplacementL
      ? SourcedField<double>(
          value: displacement,
          origin: VehicleFieldOrigin.officialRegistry,
          resolution: EvidenceResolution.verifiedExact,
          evidence: evidence,
        )
      : null;
  final mappedFuel = _exactFuelType(configuration);
  final exactFuel = mappedFuel == null
      ? null
      : SourcedField<FuelType>(
          value: mappedFuel,
          origin: VehicleFieldOrigin.officialRegistry,
          resolution: EvidenceResolution.verifiedExact,
          evidence: evidence,
        );
  final keys = <String>{
    if (exactDisplacement != null) 'displacementL',
    if (exactFuel != null) 'fuelType',
  };
  const defaults = VehicleProfile();
  final previous = (baseProfile ?? defaults).unconfirmed();
  final base = VehicleProfile.sourced(
    displacementL: _reusableAssumption(
      previous.displacementField,
      defaults.displacementField,
    ),
    massKg: _reusableAssumption(previous.massField, defaults.massField),
    volumetricEfficiency: _reusableAssumption(
      previous.volumetricEfficiencyField,
      defaults.volumetricEfficiencyField,
    ),
    fuelType: _reusableAssumption(
      previous.fuelTypeField,
      defaults.fuelTypeField,
    ),
    drivetrain: _reusableAssumption(
      previous.drivetrainField,
      defaults.drivetrainField,
    ),
    dragCoefficient: _reusableAssumption(
      previous.dragCoefficientField,
      defaults.dragCoefficientField,
    ),
    frontalAreaM2: _reusableAssumption(
      previous.frontalAreaField,
      defaults.frontalAreaField,
    ),
    rollingResistance: _reusableAssumption(
      previous.rollingResistanceField,
      defaults.rollingResistanceField,
    ),
  );

  return UsEpaProfileApplication(
    configuration: configuration,
    profile: VehicleProfile.sourced(
      displacementL: exactDisplacement ?? base.displacementField,
      massKg: base.massField,
      volumetricEfficiency: base.volumetricEfficiencyField,
      fuelType: exactFuel ?? base.fuelTypeField,
      drivetrain: base.drivetrainField,
      dragCoefficient: base.dragCoefficientField,
      frontalAreaM2: base.frontalAreaField,
      rollingResistance: base.rollingResistanceField,
    ),
    verifiedFieldKeys: Set.unmodifiable(keys),
  );
}

SourcedField<T> _reusableAssumption<T>(
  SourcedField<T> current,
  SourcedField<T> fallback,
) {
  final isEditableAssumption =
      current.origin == VehicleFieldOrigin.genericDefault ||
      current.origin == VehicleFieldOrigin.userEntered;
  return isEditableAssumption &&
          current.resolution == EvidenceResolution.unknown &&
          current.evidence == null
      ? current
      : fallback;
}

EvidenceRef _evidenceFor(
  UsVehicleCatalog catalog,
  UsEpaVehicleConfiguration configuration,
) {
  final revision = configuration.modifiedOn.trim().isNotEmpty
      ? configuration.modifiedOn.trim()
      : catalog.retrievedAtUtc.toIso8601String();
  final trim = [
    configuration.model,
    configuration.transmission,
    configuration.drive,
    configuration.fuelType,
  ].where((value) => value.trim().isNotEmpty).join(' · ');
  return EvidenceRef(
    sourceId: 'us-epa-fueleconomy-vehicles',
    publisher: 'U.S. EPA / U.S. Department of Energy',
    sourceUrl: 'https://www.fueleconomy.gov/feg/download.shtml',
    revision: revision,
    retrievedAt: catalog.retrievedAtUtc.toIso8601String(),
    sha256: catalog.snapshotSha256,
    market: 'United States',
    locator: 'epa_id=${configuration.epaId}',
    year: configuration.year,
    make: configuration.make,
    model: configuration.model,
    trim: trim,
  );
}

FuelType? _exactFuelType(UsEpaVehicleConfiguration configuration) {
  // A second fuel means the row does not establish what is in the tank now.
  // Hybrid rows also remain unknown: the current physics model cannot express
  // the electric contribution alongside the combustion fuel.
  if (configuration.fuelTypeSecondary.trim().isNotEmpty) return null;
  // FuelEconomy.gov marks conventional hybrids via atvType even when fuelType2
  // is empty. The current physics model cannot express electric assistance, so
  // only conventional gasoline rows and explicitly diesel rows are compatible.
  if (configuration.alternativeVehicleType != '' &&
      configuration.alternativeVehicleType != 'Diesel') {
    return null;
  }
  return switch (configuration.fuelTypePrimary) {
    'Regular Gasoline' ||
    'Midgrade Gasoline' ||
    'Premium Gasoline' => FuelType.gasoline,
    'Diesel' => FuelType.diesel,
    _ => null,
  };
}
