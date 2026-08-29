import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/obd/physics/vehicle_evidence.dart';
import 'package:torque_obd/obd/physics/vehicle_profile.dart';

const _exactEvidence = EvidenceRef(
  sourceId: 'manufacturer-2024-roadster',
  publisher: 'Example Motor Company',
  sourceUrl: 'https://example.test/specification',
  revision: '2024-01',
  retrievedAt: '2026-08-29',
  sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  market: 'TW',
  locator: 'Roadster/2.0/RWD/6MT',
  year: 2024,
  make: 'Example',
  model: 'Roadster',
  trim: '2.0',
);

void main() {
  group('vehicle field provenance', () {
    test('generic constructor defaults have generic-default provenance', () {
      const profile = VehicleProfile();

      expect(
        profile.inputFields.map((field) => field.origin),
        everyElement(VehicleFieldOrigin.genericDefault),
      );
      expect(
        profile.inputFields.map((field) => field.evidence),
        everyElement(isNull),
      );
    });

    test('verified-exact fields require exact vehicle evidence', () {
      expect(
        () => SourcedField<double>(
          value: 2.0,
          origin: VehicleFieldOrigin.manufacturerPublication,
          resolution: EvidenceResolution.verifiedExact,
        ),
        throwsArgumentError,
      );
      expect(
        SourcedField<double>(
          value: 2.0,
          origin: VehicleFieldOrigin.manufacturerPublication,
          resolution: EvidenceResolution.verifiedExact,
          evidence: _exactEvidence,
        ).isVerifiedExact,
        isTrue,
      );
    });

    test('the verified EPA passenger-car range includes 8.4 litre engines', () {
      final profile = VehicleProfile.sourced(
        displacementL: SourcedField(
          value: 8.4,
          origin: VehicleFieldOrigin.officialRegistry,
          resolution: EvidenceResolution.verifiedExact,
          evidence: _exactEvidence,
        ),
      );

      expect(profile.hasValidAssumptions, isTrue);
      expect(profile.displacementL, 8.4);
    });

    test('verified-exact rejects non-HTTPS or non-SHA256 snapshots', () {
      const invalid = EvidenceRef(
        sourceId: 'bad-snapshot',
        publisher: 'Example Motor Company',
        sourceUrl: 'http://example.test/specification',
        revision: '2024-01',
        retrievedAt: '2026-08-29',
        sha256: 'ABC123',
        market: 'TW',
        locator: 'Roadster/2.0/RWD/6MT',
        year: 2024,
        make: 'Example',
        model: 'Roadster',
        trim: '2.0',
      );

      expect(
        () => SourcedField<double>(
          value: 2.0,
          origin: VehicleFieldOrigin.manufacturerPublication,
          resolution: EvidenceResolution.verifiedExact,
          evidence: invalid,
        ),
        throwsArgumentError,
      );
    });

    test('schema v2 round-trips exact evidence for every input type', () {
      final original = VehicleProfile.sourced(
        displacementL: SourcedField(
          value: 2.0,
          origin: VehicleFieldOrigin.manufacturerPublication,
          resolution: EvidenceResolution.verifiedExact,
          evidence: _exactEvidence,
        ),
        massKg: SourcedField(
          value: 1280,
          origin: VehicleFieldOrigin.manufacturerPublication,
          resolution: EvidenceResolution.verifiedExact,
          evidence: _exactEvidence,
        ),
        volumetricEfficiency: SourcedField(
          value: 85,
          origin: VehicleFieldOrigin.userEntered,
        ),
        fuelType: SourcedField(
          value: FuelType.gasoline,
          origin: VehicleFieldOrigin.manufacturerPublication,
          resolution: EvidenceResolution.verifiedExact,
          evidence: _exactEvidence,
        ),
        drivetrain: SourcedField(
          value: Drivetrain.rwd,
          origin: VehicleFieldOrigin.manufacturerPublication,
          resolution: EvidenceResolution.verifiedExact,
          evidence: _exactEvidence,
        ),
        dragCoefficient: SourcedField(
          value: 0.29,
          origin: VehicleFieldOrigin.manufacturerPublication,
          resolution: EvidenceResolution.verifiedExact,
          evidence: _exactEvidence,
        ),
        frontalAreaM2: SourcedField(
          value: 2.05,
          origin: VehicleFieldOrigin.manufacturerPublication,
          resolution: EvidenceResolution.verifiedExact,
          evidence: _exactEvidence,
        ),
        rollingResistance: SourcedField(
          value: 0.012,
          origin: VehicleFieldOrigin.userEntered,
        ),
        isConfirmed: true,
      );

      final json = original.toJson();
      final restored = VehicleProfile.fromJson(json);

      expect(json['schemaVersion'], 2);
      expect(restored.displacementL, 2.0);
      expect(restored.displacementField.evidence, _exactEvidence);
      expect(
        restored.fuelTypeField.resolution,
        EvidenceResolution.verifiedExact,
      );
      expect(
        restored.rollingResistanceField.origin,
        VehicleFieldOrigin.userEntered,
      );
      expect(restored.isConfirmed, isTrue);
    });

    test(
      'editing marks only changed fields user-entered and removes evidence',
      () {
        final confirmed = VehicleProfile.sourced(
          displacementL: SourcedField(
            value: 2.0,
            origin: VehicleFieldOrigin.manufacturerPublication,
            resolution: EvidenceResolution.verifiedExact,
            evidence: _exactEvidence,
          ),
          isConfirmed: true,
        );

        final edited = confirmed.copyWith(displacementL: 2.4);

        expect(edited.displacementField.origin, VehicleFieldOrigin.userEntered);
        expect(edited.displacementField.evidence, isNull);
        expect(edited.massField.origin, VehicleFieldOrigin.genericDefault);
        expect(edited.isConfirmed, isFalse);
      },
    );

    test('session confirmation is recorded only after explicit review', () {
      final edited = const VehicleProfile().copyWith(massKg: 1280);

      expect(edited.massField.origin, VehicleFieldOrigin.userEntered);
      expect(edited.massField.resolution, EvidenceResolution.unknown);
      expect(edited.displacementField.resolution, EvidenceResolution.unknown);

      final confirmed = edited.confirmAssumptions();
      expect(confirmed.isConfirmed, isTrue);
      expect(
        confirmed.massField.resolution,
        EvidenceResolution.userConfirmedSession,
      );
      expect(
        confirmed.displacementField.resolution,
        EvidenceResolution.userConfirmedSession,
        reason: 'the driver reviewed the complete set of assumptions',
      );

      final nextVehicle = confirmed.unconfirmed();
      expect(nextVehicle.isConfirmed, isFalse);
      expect(nextVehicle.massField.resolution, EvidenceResolution.unknown);
      expect(
        nextVehicle.displacementField.resolution,
        EvidenceResolution.unknown,
      );
    });

    test(
      'ambiguous or conflicting inputs can never confirm derived outputs',
      () {
        for (final resolution in [
          EvidenceResolution.ambiguous,
          EvidenceResolution.conflict,
        ]) {
          final profile = VehicleProfile.sourced(
            massKg: SourcedField(
              value: 1280,
              origin: VehicleFieldOrigin.officialRegistry,
              resolution: resolution,
            ),
          ).confirmAssumptions();

          expect(profile.massField.resolution, resolution);
          expect(profile.isConfirmed, isFalse);
        }
      },
    );

    test('schema v1 migration retains values but gains no trust', () {
      final migrated = VehicleProfile.fromJson({
        'schemaVersion': 1,
        'displacementL': 1.8,
        'massKg': 1320,
        'volumetricEfficiency': 88,
        'fuelType': 'gasoline',
        'drivetrain': 'rwd',
        'dragCoefficient': 0.28,
        'frontalAreaM2': 2.0,
        'rollingResistance': 0.013,
        'isConfirmed': true,
      });

      expect(migrated.displacementL, 1.8);
      expect(migrated.massKg, 1320);
      expect(
        migrated.inputFields.map((field) => field.origin),
        everyElement(VehicleFieldOrigin.genericDefault),
      );
      expect(migrated.isConfirmed, isFalse);
    });

    test('missing or corrupt v2 evidence fails closed', () {
      final json = VehicleProfile.sourced(
        displacementL: SourcedField(
          value: 2.0,
          origin: VehicleFieldOrigin.manufacturerPublication,
          resolution: EvidenceResolution.verifiedExact,
          evidence: _exactEvidence,
        ),
        isConfirmed: true,
      ).toJson();
      final fields = json['fields']! as Map<String, dynamic>;
      final displacement = fields['displacementL']! as Map<String, dynamic>;
      displacement.remove('evidence');

      final restored = VehicleProfile.fromJson(json);

      expect(restored.displacementL, 2.0);
      expect(
        restored.displacementField.origin,
        VehicleFieldOrigin.genericDefault,
      );
      expect(restored.displacementField.evidence, isNull);
      expect(restored.isConfirmed, isFalse);
    });

    test(
      'an exact claim with a corrupt origin fails closed without throwing',
      () {
        final json = VehicleProfile.sourced(
          displacementL: SourcedField(
            value: 2.0,
            origin: VehicleFieldOrigin.manufacturerPublication,
            resolution: EvidenceResolution.verifiedExact,
            evidence: _exactEvidence,
          ),
          isConfirmed: true,
        ).toJson();
        final fields = json['fields']! as Map<String, dynamic>;
        final displacement = fields['displacementL']! as Map<String, dynamic>;
        displacement['origin'] = 'inventedOrigin';

        final restored = VehicleProfile.fromJson(json);

        expect(restored.displacementL, 2.0);
        expect(restored.displacementField.isVerifiedExact, isFalse);
        expect(restored.isConfirmed, isFalse);
      },
    );
  });
}
