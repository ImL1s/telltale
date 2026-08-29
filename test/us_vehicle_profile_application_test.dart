import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/obd/physics/vehicle_evidence.dart';
import 'package:torque_obd/obd/physics/vehicle_profile.dart';
import 'package:torque_obd/obd/vehicle_catalog/us_vehicle_catalog.dart';
import 'package:torque_obd/obd/vehicle_catalog/us_vehicle_profile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late UsVehicleCatalog catalog;
  setUpAll(() async {
    catalog = await UsVehicleCatalog.load(rootBundle);
  });

  group('U.S. EPA profile application', () {
    test('applies only exact fields the EPA row actually establishes', () {
      final applied = applyUsEpaConfiguration(catalog, epaId: 24752);

      expect(applied.configuration.make, 'Dodge');
      expect(applied.configuration.model, 'Viper Convertible');
      expect(applied.verifiedFieldKeys, {'displacementL', 'fuelType'});
      expect(applied.profile.displacementL, 8.4);
      expect(applied.profile.fuelType, FuelType.gasoline);
      expect(applied.profile.displacementField.isVerifiedExact, isTrue);
      expect(applied.profile.fuelTypeField.isVerifiedExact, isTrue);
      expect(
        applied.profile.displacementField.evidence?.locator,
        'epa_id=24752',
      );
      expect(
        applied.profile.displacementField.evidence?.sha256,
        catalog.snapshotSha256,
      );
      expect(
        applied.profile.drivetrainField.origin,
        VehicleFieldOrigin.genericDefault,
        reason: 'EPA drive layout does not prove a fixed efficiency',
      );
      expect(applied.profile.massField.isVerifiedExact, isFalse);
      expect(applied.profile.isConfirmed, isFalse);
    });

    test('dual-fuel identity does not guess what is currently in the tank', () {
      final applied = applyUsEpaConfiguration(catalog, epaId: 16409);

      expect(applied.configuration.fuelTypeSecondary, 'E85');
      expect(applied.verifiedFieldKeys, {'displacementL'});
      expect(applied.profile.fuelTypeField.isVerifiedExact, isFalse);
    });

    test(
      'a conventional hybrid does not claim combustion-only fuel evidence',
      () {
        final applied = applyUsEpaConfiguration(catalog, epaId: 16705);

        expect(applied.configuration.alternativeVehicleType, 'Hybrid');
        expect(applied.profile.displacementField.isVerifiedExact, isTrue);
        expect(applied.profile.fuelTypeField.isVerifiedExact, isFalse);
        expect(applied.verifiedFieldKeys, {'displacementL'});
      },
    );

    test(
      'unsupported fields keep the current user values and lose session trust',
      () {
        final current = const VehicleProfile()
            .copyWith(massKg: 1280, dragCoefficient: 0.27)
            .confirmAssumptions();

        final applied = applyUsEpaConfiguration(
          catalog,
          epaId: 24752,
          baseProfile: current,
        );

        expect(applied.profile.massKg, 1280);
        expect(applied.profile.dragCoefficient, 0.27);
        expect(
          applied.profile.massField.origin,
          VehicleFieldOrigin.userEntered,
        );
        expect(
          applied.profile.massField.resolution,
          EvidenceResolution.unknown,
        );
        expect(applied.profile.displacementField.isVerifiedExact, isTrue);
        expect(applied.profile.isConfirmed, isFalse);
      },
    );

    test(
      'a new exact configuration cannot inherit another configuration evidence',
      () {
        final viper = applyUsEpaConfiguration(catalog, epaId: 24752).profile;

        final taurus = applyUsEpaConfiguration(
          catalog,
          epaId: 16409,
          baseProfile: viper,
        );

        expect(
          taurus.profile.displacementField.evidence?.locator,
          'epa_id=16409',
        );
        expect(taurus.profile.fuelTypeField.isVerifiedExact, isFalse);
        expect(taurus.profile.fuelTypeField.evidence, isNull);
        expect(
          taurus.profile.inputFields
              .where((field) => field.isVerifiedExact)
              .map((field) => field.evidence!.locator),
          everyElement('epa_id=16409'),
        );
      },
    );

    test('an electric row remains selectable without invented engine data', () {
      final applied = applyUsEpaConfiguration(catalog, epaId: 16423);

      expect(applied.configuration.model, 'Altra EV');
      expect(applied.verifiedFieldKeys, isEmpty);
      expect(
        applied.profile.inputFields.map((field) => field.origin),
        everyElement(VehicleFieldOrigin.genericDefault),
      );
    });

    test('unknown ids fail closed', () {
      expect(
        () => applyUsEpaConfiguration(catalog, epaId: -1),
        throwsA(isA<UsVehicleCatalogException>()),
      );
    });

    test('the entire bundled snapshot obeys the compatible-field boundary', () {
      final appliedFieldCounts = <int, int>{};
      final incompatibleFuelClaims = <int>[];

      for (final year in catalog.years) {
        for (final make in catalog.makes(year: year)) {
          for (final model in catalog.models(year: year, make: make)) {
            for (final configuration in catalog.configurations(
              year: year,
              make: make,
              model: model,
            )) {
              final applied = applyUsEpaConfiguration(
                catalog,
                epaId: configuration.epaId,
              );
              appliedFieldCounts.update(
                applied.verifiedFieldKeys.length,
                (count) => count + 1,
                ifAbsent: () => 1,
              );
              if (configuration.alternativeVehicleType != '' &&
                  configuration.alternativeVehicleType != 'Diesel' &&
                  applied.profile.fuelTypeField.isVerifiedExact) {
                incompatibleFuelClaims.add(configuration.epaId);
              }
            }
          }
        }
      }

      expect(appliedFieldCounts, {0: 1616, 1: 3948, 2: 44678});
      expect(incompatibleFuelClaims, isEmpty);
    });
  });
}
