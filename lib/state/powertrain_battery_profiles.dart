/// Session-only authorization for vehicle-specific battery polling.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../obd/pid/pid.dart';
import '../obd/powertrain_battery/powertrain_battery_catalog.dart';
import '../obd/powertrain_battery/powertrain_battery_profile.dart';
import '../obd/powertrain_battery/profile_catalog_validator.dart';
import '../obd/powertrain_battery/profile_wire_contract.dart';
import 'powertrain_battery_experiments.dart';

typedef PowertrainBatteryCatalogLoader =
    Future<PowertrainBatteryCatalogSnapshot> Function();

final powertrainBatteryCatalogLoaderProvider =
    Provider<PowertrainBatteryCatalogLoader>(
      (ref) =>
          () => PowertrainBatteryCatalogAsset.load(),
    );

final class PowertrainProfileAuthorization {
  const PowertrainProfileAuthorization({
    required this.vehicleYear,
    required this.sourceRevision,
    required this.connectionGeneration,
  });

  final int vehicleYear;
  final String sourceRevision;
  final int connectionGeneration;

  @override
  bool operator ==(Object other) =>
      other is PowertrainProfileAuthorization &&
      vehicleYear == other.vehicleYear &&
      sourceRevision == other.sourceRevision &&
      connectionGeneration == other.connectionGeneration;

  @override
  int get hashCode =>
      Object.hash(vehicleYear, sourceRevision, connectionGeneration);
}

class PowertrainProfileAuthorizations
    extends Notifier<Map<String, PowertrainProfileAuthorization>> {
  @override
  Map<String, PowertrainProfileAuthorization> build() => const {};

  /// Validates a request but never grants periodic profile polling.
  ///
  /// The bundled catalog has no installable profile. Status and caller-supplied
  /// evidence therefore cannot create a production authorization, even if a
  /// future or injected entry labels itself `ready` or `community`.
  PowertrainBatteryProfileValidation authorize(
    PowertrainBatteryProfile profile, {
    required int vehicleYear,
    required int connectionGeneration,
  }) {
    final validation = const PowertrainBatteryProfileCatalogValidator()
        .validateProfile(profile, vehicleYear: vehicleYear);
    state = const {};
    return validation;
  }

  void revoke(String profileId) {
    if (!state.containsKey(profileId)) return;
    final next = {...state}..remove(profileId);
    state = Map.unmodifiable(next);
  }

  void invalidateForVehicleBoundary() {
    if (state.isEmpty) return;
    state = const {};
  }

  bool isAuthorized(String profileId) => false;
}

final powertrainProfileAuthorizationsProvider =
    NotifierProvider<
      PowertrainProfileAuthorizations,
      Map<String, PowertrainProfileAuthorization>
    >(PowertrainProfileAuthorizations.new);

final class PowertrainExperimentalProbeConsent {
  const PowertrainExperimentalProbeConsent({
    required this.profileId,
    required this.sourceRevision,
    required this.catalogSha256,
    required this.commandKey,
    required this.vehicleYear,
    required this.connectionGeneration,
    required this.issuedAt,
    required this.expiresAt,
  });

  final String profileId;
  final String sourceRevision;
  final String catalogSha256;
  final String commandKey;
  final int vehicleYear;
  final int connectionGeneration;
  final DateTime issuedAt;
  final DateTime expiresAt;

  String get key => '$profileId\u0000$commandKey';
}

final class PowertrainExperimentalConsentDecision {
  const PowertrainExperimentalConsentDecision._({
    required this.accepted,
    required this.reason,
  });

  const PowertrainExperimentalConsentDecision.accepted()
    : this._(accepted: true, reason: '');

  const PowertrainExperimentalConsentDecision.refused(String reason)
    : this._(accepted: false, reason: reason);

  final bool accepted;
  final String reason;
}

final class PowertrainExperimentalProbeLease {
  const PowertrainExperimentalProbeLease._(this.consent);

  final PowertrainExperimentalProbeConsent consent;
}

/// One-use, in-memory consent and quarantine for experimental probes.
class PowertrainExperimentalProbeConsents
    extends Notifier<Map<String, PowertrainExperimentalProbeConsent>> {
  static const Duration consentLifetime = Duration(minutes: 2);
  static const Duration commandCooldown = Duration(seconds: 5);
  static const int maxAttemptsPerCommand = 3;

  final Map<String, String> _quarantineReasons = {};
  final Map<String, int> _attempts = {};
  final Map<String, DateTime> _lastAttemptAt = {};
  PowertrainExperimentalProbeLease? _inFlightLease;

  @override
  Map<String, PowertrainExperimentalProbeConsent> build() => const {};

  PowertrainExperimentalConsentDecision authorize({
    required PowertrainBatteryCatalogSnapshot snapshot,
    required String profileId,
    required String commandKey,
    required int vehicleYear,
    required int connectionGeneration,
    DateTime? now,
  }) {
    if (!ref.read(powertrainBatteryExperimentalAccessProvider)) {
      return const PowertrainExperimentalConsentDecision.refused(
        '大電池證據實驗室尚未開啟',
      );
    }
    if (!isPowertrainCatalogSha256(snapshot.catalogSha256)) {
      return const PowertrainExperimentalConsentDecision.refused('目錄完整性雜湊無效');
    }
    final profile = snapshot.catalog.profiles
        .where((candidate) => candidate.id == profileId)
        .firstOrNull;
    if (profile == null) {
      return const PowertrainExperimentalConsentDecision.refused('設定檔不在已驗證目錄中');
    }
    final validation = const PowertrainBatteryProfileCatalogValidator()
        .validateProfile(profile, vehicleYear: vehicleYear);
    if (!validation.canProbe) {
      return PowertrainExperimentalConsentDecision.refused(
        validation.issues.isEmpty
            ? '這不是可單次探測的實驗設定檔'
            : validation.issues.first.message,
      );
    }
    if (!profile.commands.any((command) => command.wireKey == commandKey)) {
      return const PowertrainExperimentalConsentDecision.refused('指令不在已驗證設定檔中');
    }
    if (_quarantineReasons.containsKey(profileId)) {
      return PowertrainExperimentalConsentDecision.refused(
        '本次連線已隔離：${_quarantineReasons[profileId]}',
      );
    }

    final issuedAt = (now ?? DateTime.now()).toUtc();
    final consent = PowertrainExperimentalProbeConsent(
      profileId: profile.id,
      sourceRevision: profile.source.revision,
      catalogSha256: snapshot.catalogSha256,
      commandKey: commandKey,
      vehicleYear: vehicleYear,
      connectionGeneration: connectionGeneration,
      issuedAt: issuedAt,
      expiresAt: issuedAt.add(consentLifetime),
    );
    state = Map.unmodifiable({...state, consent.key: consent});
    return const PowertrainExperimentalConsentDecision.accepted();
  }

  PowertrainExperimentalProbeLease? take({
    required PowertrainBatteryCatalogSnapshot snapshot,
    required String profileId,
    required String commandKey,
    required int vehicleYear,
    required int connectionGeneration,
    DateTime? now,
  }) {
    if (!ref.read(powertrainBatteryExperimentalAccessProvider) ||
        _inFlightLease != null ||
        _quarantineReasons.containsKey(profileId)) {
      return null;
    }
    final key = '$profileId\u0000$commandKey';
    final consent = state[key];
    if (consent == null) return null;
    final takenAt = (now ?? DateTime.now()).toUtc();
    final canonical = snapshot.catalog.profiles
        .where((profile) => profile.id == profileId)
        .firstOrNull;
    final canonicalCommand = canonical?.commands
        .where((command) => command.wireKey == commandKey)
        .firstOrNull;
    if (consent.vehicleYear != vehicleYear) {
      _remove(key);
      return null;
    }
    if (canonical == null ||
        canonicalCommand == null ||
        consent.catalogSha256 != snapshot.catalogSha256 ||
        consent.sourceRevision != canonical.source.revision ||
        consent.connectionGeneration != connectionGeneration ||
        takenAt.isBefore(consent.issuedAt) ||
        !takenAt.isBefore(consent.expiresAt)) {
      _remove(key);
      return null;
    }
    final attempts = _attempts[key] ?? 0;
    if (attempts >= maxAttemptsPerCommand) {
      quarantine(profileId, '同一指令本次連線已達 $maxAttemptsPerCommand 次上限');
      return null;
    }
    final last = _lastAttemptAt[key];
    if (last != null && takenAt.difference(last) < commandCooldown) return null;

    _remove(key);
    _attempts[key] = attempts + 1;
    _lastAttemptAt[key] = takenAt;
    final lease = PowertrainExperimentalProbeLease._(consent);
    _inFlightLease = lease;
    return lease;
  }

  void complete(
    PowertrainExperimentalProbeLease lease, {
    String? quarantineReason,
  }) {
    if (!identical(_inFlightLease, lease)) return;
    _inFlightLease = null;
    if (quarantineReason != null && quarantineReason.trim().isNotEmpty) {
      quarantine(lease.consent.profileId, quarantineReason);
    }
  }

  void quarantine(String profileId, String reason) {
    _quarantineReasons[profileId] = reason;
    final next = {...state}
      ..removeWhere((_, consent) => consent.profileId == profileId);
    state = Map.unmodifiable(next);
  }

  String? quarantineReason(String profileId) => _quarantineReasons[profileId];

  void invalidateForVehicleBoundary() {
    state = const {};
    _quarantineReasons.clear();
    _attempts.clear();
    _lastAttemptAt.clear();
    _inFlightLease = null;
  }

  /// Revokes unused consent without resetting connection-scoped safeguards.
  ///
  /// A consumed lease stays marked in flight until its caller unwinds. This
  /// prevents a pause/resume or off/on cycle from overlapping a second probe
  /// with an older command that may already be on the adapter wire.
  void revokeAll() {
    state = const {};
  }

  void _remove(String key) {
    if (!state.containsKey(key)) return;
    final next = {...state}..remove(key);
    state = Map.unmodifiable(next);
  }
}

final powertrainExperimentalProbeConsentsProvider =
    NotifierProvider<
      PowertrainExperimentalProbeConsents,
      Map<String, PowertrainExperimentalProbeConsent>
    >(PowertrainExperimentalProbeConsents.new);

/// Removes every catalog-derived PID from the production polling set.
///
/// The authorization map remains an input for API compatibility, but cannot
/// reopen this boundary. Research browsing and consent-bound one-shot probes
/// use a separate path and do not create [Pid] definitions.
List<Pid> filterAuthorizedPowertrainPids(
  Iterable<Pid> pids,
  Map<String, PowertrainProfileAuthorization> authorizations, {
  required int connectionGeneration,
}) => List.unmodifiable([
  for (final pid in pids)
    if (pid.ownerProfileId == null) pid,
]);
