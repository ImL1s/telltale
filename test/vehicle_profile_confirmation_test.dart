import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/obd/physics/vehicle_evidence.dart';
import 'package:torque_obd/obd/physics/vehicle_profile.dart';
import 'package:torque_obd/state/pid_registry.dart';
import 'package:torque_obd/state/settings.dart';

const _storageKey = 'vehicle_profile_v1';
const _storedEvidence = EvidenceRef(
  sourceId: 'us-epa-fueleconomy-vehicles',
  publisher: 'U.S. EPA / U.S. DOE',
  sourceUrl: 'https://www.fueleconomy.gov/feg/download.shtml',
  revision: '2026-08-07',
  retrievedAt: '2026-08-29T14:28:23+00:00',
  sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  market: 'United States',
  locator: 'epa_id=12345',
  year: 2024,
  make: 'Example',
  model: 'Roadster',
  trim: '2.0',
);

Future<(ProviderContainer, SharedPreferences)> _container(
  Map<String, Object> initial,
) async {
  SharedPreferences.setMockInitialValues(initial);
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
  return (container, prefs);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('vehicle-profile confirmation is fail closed', () {
    test('a new profile and a legacy stored profile are unconfirmed', () async {
      expect(const VehicleProfile().isConfirmed, isFalse);

      final legacy = jsonEncode(
        const VehicleProfile(
          displacementL: 1.8,
          massKg: 1320,
          drivetrain: Drivetrain.rwd,
        ).toJson()..remove('isConfirmed'),
      );
      final (container, _) = await _container({_storageKey: legacy});
      addTearDown(container.dispose);

      final loaded = container.read(vehicleProfileProvider);
      expect(loaded.displacementL, 1.8);
      expect(loaded.massKg, 1320);
      expect(loaded.drivetrain, Drivetrain.rwd);
      expect(loaded.isConfirmed, isFalse);
    });

    test('confirmation round-trips through JSON only as a real boolean', () {
      const confirmed = VehicleProfile(isConfirmed: true);
      expect(VehicleProfile.fromJson(confirmed.toJson()).isConfirmed, isTrue);
      expect(
        VehicleProfile.fromJson({...confirmed.toJson(), 'isConfirmed': 'true'})
            .isConfirmed,
        isFalse,
      );
    });

    test('partial or invalid stored assumptions cannot stay confirmed', () {
      expect(
        VehicleProfile.fromJson({
          'schemaVersion': VehicleProfile.schemaVersion,
          'isConfirmed': true,
        }).isConfirmed,
        isFalse,
      );

      final corrupted = VehicleProfile.fromJson({
        ...const VehicleProfile(isConfirmed: true).toJson(),
        'massKg': -1,
      });
      expect(corrupted.isConfirmed, isFalse);
      expect(corrupted.massKg, VehicleProfile.minMassKg);
      expect(corrupted.hasValidAssumptions, isTrue);
    });

    test('copying any assumption invalidates direct model confirmation', () {
      const confirmed = VehicleProfile(isConfirmed: true);
      expect(confirmed.copyWith(displacementL: 2.4).isConfirmed, isFalse);
      expect(
        confirmed.copyWith(fuelType: FuelType.diesel).isConfirmed,
        isFalse,
      );
      expect(confirmed.copyWith().isConfirmed, isTrue);
      expect(
        confirmed.copyWith(massKg: 1400, isConfirmed: true).isConfirmed,
        isFalse,
        reason: 'an explicit flag cannot bypass modification invalidation',
      );
      expect(
        const VehicleProfile(massKg: -1, isConfirmed: true).isConfirmed,
        isFalse,
        reason: 'invalid assumptions can never be exposed as confirmed',
      );
    });

    test('confirmation is live only for the current session', () async {
      final (container, prefs) = await _container({});
      addTearDown(container.dispose);
      final controller = container.read(vehicleProfileProvider.notifier);

      await controller.confirm();
      expect(container.read(vehicleProfileProvider).isConfirmed, isTrue);
      expect(
        (jsonDecode(prefs.getString(_storageKey)!)
            as Map<String, dynamic>)['isConfirmed'],
        isFalse,
        reason: 'trust must not survive into another vehicle session',
      );

      await controller.update(
        container.read(vehicleProfileProvider).copyWith(displacementL: 2.4),
      );
      expect(container.read(vehicleProfileProvider).displacementL, 2.4);
      expect(container.read(vehicleProfileProvider).isConfirmed, isFalse);
      expect(
        (jsonDecode(prefs.getString(_storageKey)!)
            as Map<String, dynamic>)['isConfirmed'],
        isFalse,
      );
    });

    test('a formerly confirmed stored profile loads unconfirmed', () async {
      final stored = jsonEncode(
        const VehicleProfile(
          displacementL: 2.0,
          massKg: 1280,
          drivetrain: Drivetrain.rwd,
          isConfirmed: true,
        ).toJson(),
      );
      final (container, _) = await _container({_storageKey: stored});
      addTearDown(container.dispose);

      final loaded = container.read(vehicleProfileProvider);
      expect(loaded.massKg, 1280);
      expect(loaded.drivetrain, Drivetrain.rwd);
      expect(loaded.isConfirmed, isFalse);
    });

    test('persisted exact evidence is untrusted until the bundled snapshot revalidates it', () async {
      final stored = jsonEncode(
        VehicleProfile.sourced(
          displacementL: SourcedField(
            value: 2.0,
            origin: VehicleFieldOrigin.officialRegistry,
            resolution: EvidenceResolution.verifiedExact,
            evidence: _storedEvidence,
          ),
        ).toJson(),
      );
      final (container, _) = await _container({_storageKey: stored});
      addTearDown(container.dispose);

      final loaded = container.read(vehicleProfileProvider);
      expect(loaded.displacementL, 2.0);
      expect(loaded.displacementField.isVerifiedExact, isFalse);
      expect(loaded.displacementField.evidence, isNull);
      expect(loaded.isConfirmed, isFalse);
    });

    test(
      'an exact catalog match cannot cross a vehicle connection boundary',
      () async {
        final (container, _) = await _container({});
        addTearDown(container.dispose);
        final controller = container.read(vehicleProfileProvider.notifier);
        final exact = VehicleProfile.sourced(
          displacementL: SourcedField(
            value: 2.0,
            origin: VehicleFieldOrigin.officialRegistry,
            resolution: EvidenceResolution.verifiedExact,
            evidence: _storedEvidence,
          ),
        );

        await controller.update(exact);
        expect(
          container
              .read(vehicleProfileProvider)
              .displacementField
              .isVerifiedExact,
          isTrue,
        );

        await controller.invalidateForVehicleBoundary();

        final nextVehicle = container.read(vehicleProfileProvider);
        expect(nextVehicle.displacementL, 2.0);
        expect(nextVehicle.displacementField.isVerifiedExact, isFalse);
        expect(nextVehicle.displacementField.evidence, isNull);
        expect(nextVehicle.isConfirmed, isFalse);
      },
    );
  });
}
