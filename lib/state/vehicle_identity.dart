/// Vehicle identity evidence for the current connection only.
///
/// This state deliberately has no persistence dependency. A VIN identifies the
/// vehicle on the other side of the adapter now; carrying it across a provider
/// container or connection boundary would silently identify the next vehicle
/// as the previous one. This does not redact the separate raw diagnostic
/// transcript, whose VIN exposure is disclosed in the privacy policy.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

enum VehicleIdentityStatus {
  /// Mode 09 PID 02 has not been attempted during this connection.
  notRead,

  /// The vehicle returned one syntactically complete VIN.
  vehicleReported,

  /// No complete VIN could be obtained.
  unavailable,

  /// More than one distinct VIN was reported, so no candidate is trusted.
  conflict,
}

class VehicleIdentity {
  const VehicleIdentity._(this.status, this.vin);

  const VehicleIdentity.notRead() : this._(VehicleIdentityStatus.notRead, null);

  const VehicleIdentity.unavailable()
    : this._(VehicleIdentityStatus.unavailable, null);

  const VehicleIdentity.conflict()
    : this._(VehicleIdentityStatus.conflict, null);

  factory VehicleIdentity.vehicleReported(String vin) {
    if (!isCompleteVin(vin)) {
      throw ArgumentError.value(vin, 'vin', 'must be one complete ISO VIN');
    }
    return VehicleIdentity._(VehicleIdentityStatus.vehicleReported, vin);
  }

  final VehicleIdentityStatus status;

  /// Present only when exactly one complete VIN was reported by the vehicle.
  final String? vin;

  /// ISO 3779's 17-character alphabet excludes I, O and Q.
  static bool isCompleteVin(String candidate) =>
      _vinPattern.hasMatch(candidate);

  static final RegExp _vinPattern = RegExp(r'^[A-HJ-NPR-Z0-9]{17}$');

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VehicleIdentity && status == other.status && vin == other.vin;

  @override
  int get hashCode => Object.hash(status, vin);
}

class VehicleIdentityController extends Notifier<VehicleIdentity> {
  @override
  VehicleIdentity build() => const VehicleIdentity.notRead();

  /// Records the one VIN returned by [PollingEngine.readVin].
  ///
  /// Null and malformed candidates both fail closed. The parser should already
  /// enforce this boundary; enforcing it again here prevents a future caller
  /// from placing a shortened or repaired identity into shared UI state.
  void reportVin(String? vin) {
    state = vin != null && VehicleIdentity.isCompleteVin(vin)
        ? VehicleIdentity.vehicleReported(vin)
        : const VehicleIdentity.unavailable();
  }

  /// Records that the vehicle's controllers disagreed about its identity.
  ///
  /// No candidate is retained: controller order is not evidence that one VIN
  /// is more trustworthy than another.
  void reportConflict() {
    state = const VehicleIdentity.conflict();
  }

  void markUnavailable() {
    state = const VehicleIdentity.unavailable();
  }

  /// Opens a new connection boundary with no inherited identity evidence.
  void reset() {
    state = const VehicleIdentity.notRead();
  }
}

final vehicleIdentityProvider =
    NotifierProvider<VehicleIdentityController, VehicleIdentity>(
      VehicleIdentityController.new,
    );
