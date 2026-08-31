/// Closed production boundary for battery-profile PID installation.
library;

import '../pid/pid.dart';
import 'powertrain_battery_profile.dart';

final class PowertrainProfileInstallException implements Exception {
  const PowertrainProfileInstallException(this.message);

  final String message;

  @override
  String toString() => 'PowertrainProfileInstallException: $message';
}

abstract final class PowertrainProfilePidInstaller {
  static List<Pid> build(PowertrainBatteryProfile profile) {
    throw PowertrainProfileInstallException(
      'battery profile installation is unavailable; '
      '${profile.id} remains catalog/one-shot research data only',
    );
  }
}
