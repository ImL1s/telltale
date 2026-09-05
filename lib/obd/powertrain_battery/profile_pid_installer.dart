/// Converts a reviewed catalog profile into runtime PID definitions.
library;

import '../pid/pid.dart';
import '../pid/priority_tier.dart';
import 'powertrain_battery_profile.dart';
import 'profile_catalog_validator.dart';

final class PowertrainProfileInstallException implements Exception {
  const PowertrainProfileInstallException(this.message);

  final String message;

  @override
  String toString() => 'PowertrainProfileInstallException: $message';
}

abstract final class PowertrainProfilePidInstaller {
  /// Gauge-face labels by signal semantic, mirroring the built-in library's
  /// English abbreviations. A semantic this map does not know falls back to
  /// the signal name, which the gauge truncates rather than this code
  /// guessing an abbreviation.
  static const Map<String, String> _shortNames = {
    'stateOfCharge': 'SOC',
    'stateOfHealth': 'SOH',
    'packVoltage': 'Pack V',
    'packCurrent': 'Pack A',
    'packResistance': 'Pack Ω',
    'batteryTemperature': 'Batt °C',
    'coolantTemperature': 'Coolant',
    'cellVoltageMin': 'Cell min',
    'cellVoltageMax': 'Cell max',
    'motorTorque': 'Torque',
    'auxBatteryVoltage': 'Aux V',
    'chargeEnergy': 'Chg kWh',
    'dischargeEnergy': 'Dis kWh',
  };

  /// Builds one [Pid] per catalog signal, re-validating the profile first.
  ///
  /// Validation here rather than trusting the caller: the profile object may
  /// have been persisted, injected or built in a test, and the byte windows
  /// and formulas it carries become live wire traffic and gauge numbers. The
  /// equation letters stay window-relative (`A` is the first byte of the
  /// signal's slice) because the polling engine slices
  /// `dataOffsetBytes..+dataLengthBytes` out of the attributed payload before
  /// evaluating.
  static List<Pid> build(PowertrainBatteryProfile profile) {
    final validation = const PowertrainBatteryProfileCatalogValidator()
        .validateProfile(profile);
    if (!validation.canInstall) {
      final reason = validation.issues.isNotEmpty
          ? validation.issues.first.toString()
          : 'status ${profile.status.name} is not installable';
      throw PowertrainProfileInstallException(
        '${profile.id} cannot be installed: $reason',
      );
    }

    final pids = <Pid>[];
    for (final command in profile.commands) {
      for (final signal in command.signals) {
        pids.add(
          Pid(
            name: '${profile.displayName} ${signal.name}',
            shortName: _shortNames[signal.semanticKind] ?? signal.name,
            modeAndPid: command.modeAndIdentifier,
            equation: signal.equation,
            minValue: signal.minValue,
            maxValue: signal.maxValue,
            units: signal.unit,
            header: command.requestHeader,
            priority: signal.recommended
                ? PriorityTier.medium
                : PriorityTier.low,
            ownerProfileId: profile.id,
            sourceSignalId: signal.id,
            sourceRevision: profile.source.revision,
            expectedResponseId: command.expectedResponder,
            dataOffsetBytes: signal.offset,
            dataLengthBytes: signal.width,
            responseDataLengthBytes: command.payloadLength,
            evidenceKind: profile.status.name,
          ),
        );
      }
    }
    return List.unmodifiable(pids);
  }
}
