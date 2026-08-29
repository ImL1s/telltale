/// Vehicle identity is evidence from the currently connected vehicle only.
///
/// A VIN is not a preference: persisting it would let the next connection
/// inherit the previous car's identity. These tests therefore drive an
/// in-memory Riverpod notifier and require every uncertain outcome to discard
/// any candidate it may have seen.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/state/vehicle_identity.dart';

void main() {
  group('session vehicle identity', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer();
    });

    tearDown(() {
      container.dispose();
    });

    test('starts unread and contains no candidate', () {
      expect(
        container.read(vehicleIdentityProvider),
        const VehicleIdentity.notRead(),
      );
    });

    test('accepts one complete ISO VIN reported by the vehicle', () {
      container
          .read(vehicleIdentityProvider.notifier)
          .reportVin('1D4GP00R55B123456');

      final identity = container.read(vehicleIdentityProvider);
      expect(identity.status, VehicleIdentityStatus.vehicleReported);
      expect(identity.vin, '1D4GP00R55B123456');
    });

    test('rejects shortened, forbidden-letter, and lower-case candidates', () {
      final notifier = container.read(vehicleIdentityProvider.notifier);

      for (final invalid in [
        '1D4GP00R55B12345',
        '1D4GP00R55B12345I',
        '1D4GP00R55B12345O',
        '1D4GP00R55B12345Q',
        '1d4gp00r55b123456',
      ]) {
        notifier.reportVin(invalid);
        expect(
          container.read(vehicleIdentityProvider),
          const VehicleIdentity.unavailable(),
          reason: '$invalid is not a complete ISO VIN',
        );
      }
    });

    test('a missing reply is unavailable rather than an empty identity', () {
      container.read(vehicleIdentityProvider.notifier).reportVin(null);

      expect(
        container.read(vehicleIdentityProvider),
        const VehicleIdentity.unavailable(),
      );
    });

    test(
      'a conflict discards an earlier candidate instead of selecting it',
      () {
        final notifier = container.read(vehicleIdentityProvider.notifier);
        notifier.reportVin('1D4GP00R55B123456');

        notifier.reportConflict();

        final identity = container.read(vehicleIdentityProvider);
        expect(identity.status, VehicleIdentityStatus.conflict);
        expect(identity.vin, isNull);
      },
    );

    test('reset starts a new connection with no identity evidence', () {
      final notifier = container.read(vehicleIdentityProvider.notifier);
      notifier.reportVin('1D4GP00R55B123456');

      notifier.reset();

      expect(
        container.read(vehicleIdentityProvider),
        const VehicleIdentity.notRead(),
      );
    });

    test('disposing the session cannot persist its VIN', () {
      container
          .read(vehicleIdentityProvider.notifier)
          .reportVin('1D4GP00R55B123456');
      container.dispose();

      container = ProviderContainer();

      expect(
        container.read(vehicleIdentityProvider),
        const VehicleIdentity.notRead(),
      );
    });
  });
}
