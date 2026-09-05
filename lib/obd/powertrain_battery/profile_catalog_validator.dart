/// Fail-closed validation for installable powertrain battery profiles.
library;

import '../pid/formula_engine.dart';
import '../pid/pid.dart';
import 'powertrain_battery_profile.dart';
import 'profile_wire_contract.dart';

final class PowertrainBatteryProfileCatalogValidator {
  const PowertrainBatteryProfileCatalogValidator();

  /// Services for which the profile polling path enforces an exact responder.
  ///
  /// Generic Mode 01/02/09 parsing intentionally lives on another path and
  /// does not attribute every value to a profile's expected ECU. Keeping those
  /// services out of installable profiles prevents a valid response from a
  /// different controller from being accepted under a vehicle-specific map.
  static const Set<String> readOnlyServices = {'21', '22'};
  static const Set<String> deniedServices = {
    '10',
    '11',
    '14',
    '27',
    '28',
    '2E',
    '2F',
    '31',
  };

  PowertrainBatteryProfileValidation validateProfile(
    PowertrainBatteryProfile profile, {
    int? vehicleYear,
  }) {
    final issues = <PowertrainBatteryProfileIssue>[];
    void issue(String code, String path, String message) {
      issues.add(
        PowertrainBatteryProfileIssue(code: code, path: path, message: message),
      );
    }

    if (profile.id.trim().isEmpty) {
      issue('missing_profile_id', 'id', 'profile id is required');
    }
    final reviewedStatus =
        profile.status == PowertrainProfileStatus.ready ||
        profile.status == PowertrainProfileStatus.community;
    final exactVehicleFields = <String, String>{
      'market': profile.market,
      'make': profile.make,
      'model': profile.model,
      'variant': profile.variant,
      'powertrain': profile.powertrain,
    };
    for (final entry in exactVehicleFields.entries) {
      if (entry.value.trim().isEmpty) {
        issue(
          'missing_vehicle_identity',
          entry.key,
          '${entry.key} is required for exact vehicle gating',
        );
      } else if (reviewedStatus && _isInexactIdentity(entry.value)) {
        issue(
          'inexact_vehicle_identity',
          entry.key,
          '${entry.key} must be exact for ready/community source metadata',
        );
      }
    }
    // The string check above rejects "unspecified"-shaped spellings; for a
    // community variant that is still the floor. A generation-scoped variant
    // label such as "Mk1 (2019–2022)" passes it, and the evidence-level gate
    // below decides whether that scoping is honest.
    if (reviewedStatus) {
      _validateReviewedIdentityEvidence(
        profile.identityEvidence,
        profile.status,
        issue,
      );
      // Both reviewed tiers require independent corroboration and a pinned
      // primary artifact. `ready` is a superset of `community` — physical
      // vehicle evidence on top of everything below — so it must never have
      // a *lower* bar than the tier beneath it. A single hobbyist CSV that
      // nobody else agrees with stays experimental no matter how plausible
      // it looks.
      if (!isPowertrainCatalogSha256(profile.source.artifactSha256)) {
        issue(
          'missing_source_artifact_hash',
          'source.artifact_sha256',
          'a ${profile.status.name} profile must pin the exact source '
              'artifact SHA-256',
        );
      }
      if (profile.secondarySources.isEmpty) {
        issue(
          'missing_secondary_source',
          'secondary_sources',
          'a ${profile.status.name} profile requires at least one '
              'independent corroborating source',
        );
      }
      // Structural distinctness is what a validator can enforce; whether two
      // repositories are *editorially* independent (not the same author, not
      // a derivation) is a review-time judgement the docs own. But a
      // secondary that points at the primary's own bytes — same artifact
      // hash, or the same repository revision and path under a new name — is
      // provably not a second source, and renaming it must not open the
      // install gate.
      final seenArtifacts = {profile.source.artifactSha256.trim()};
      final seenLocations = {_sourceLocation(profile.source)};
      for (
        var sourceIndex = 0;
        sourceIndex < profile.secondarySources.length;
        sourceIndex++
      ) {
        final secondary = profile.secondarySources[sourceIndex];
        final prefix = 'secondary_sources[$sourceIndex].';
        _validateSource(secondary, issue, pathPrefix: prefix);
        if (!isPowertrainCatalogSha256(secondary.artifactSha256)) {
          issue(
            'missing_source_artifact_hash',
            '${prefix}source.artifact_sha256',
            'a corroborating source must pin its exact artifact SHA-256',
          );
        } else if (!seenArtifacts.add(secondary.artifactSha256.trim())) {
          issue(
            'duplicate_corroborating_source',
            '${prefix}source.artifact_sha256',
            'a corroborating source must not share an artifact with the '
                'primary or another secondary',
          );
        }
        if (!seenLocations.add(_sourceLocation(secondary))) {
          issue(
            'duplicate_corroborating_source',
            '${prefix}source',
            'a corroborating source must not point at the same repository '
                'revision and path as the primary or another secondary',
          );
        }
      }
    }
    if (profile.yearFrom < 1886 ||
        profile.yearTo > 2100 ||
        profile.yearFrom > profile.yearTo) {
      issue(
        'invalid_vehicle_year_range',
        'year_from/year_to',
        'inclusive year range must be ordered and within 1886..2100',
      );
    }
    if (vehicleYear != null && !profile.appliesToYear(vehicleYear)) {
      issue(
        'vehicle_year_out_of_range',
        'year_from/year_to',
        'selected vehicle year $vehicleYear is outside this profile range',
      );
    }

    _validateSource(profile.source, issue);

    if (profile.status == PowertrainProfileStatus.experimental) {
      if (!isPowertrainCatalogSha256(profile.source.artifactSha256)) {
        issue(
          'missing_source_artifact_hash',
          'source.artifact_sha256',
          'an experimental profile must pin the exact source artifact SHA-256',
        );
      }
      final identity = profile.identityEvidence;
      if (identity == null) {
        issue(
          'missing_identity_evidence',
          'identity_evidence',
          'an experimental profile must label identity evidence field by field',
        );
      } else if (identity.year == PowertrainIdentityEvidenceLevel.unknown ||
          identity.model == PowertrainIdentityEvidenceLevel.unknown) {
        issue(
          'insufficient_identity_evidence',
          'identity_evidence',
          'experimental model and year evidence cannot be unknown',
        );
      }
    }

    final executableStatus =
        reviewedStatus ||
        profile.status == PowertrainProfileStatus.experimental;
    if (executableStatus && profile.commands.isEmpty) {
      issue(
        'missing_commands',
        'commands',
        'an executable profile must declare at least one command',
      );
    }
    if (profile.status == PowertrainProfileStatus.researchOnly &&
        profile.commands.isNotEmpty) {
      issue(
        'research_profile_has_commands',
        'commands',
        'a research-only profile is metadata-only and must not carry commands',
      );
    }

    final signalIds = <String>{};
    final commandIds = <String>{};
    for (
      var commandIndex = 0;
      commandIndex < profile.commands.length;
      commandIndex++
    ) {
      final command = profile.commands[commandIndex];
      final path = 'commands[$commandIndex]';
      _validateCommand(command, path, issue);
      // The polling allowlist ([PollableServices]) deliberately reserves
      // Mode 21 for the one-shot probe, so an installable tier must not
      // carry it: the profile would install and authorize, then every poll
      // would be refused at the wire sink — a dark gauge blamed on an
      // "unsafe service" the catalog itself shipped.
      if (reviewedStatus && command.mode != '22') {
        issue(
          'unpollable_service',
          '$path.mode',
          'installable profiles may only carry Mode 22 commands; '
              'Mode ${command.mode} is probe-only',
        );
      }

      final commandId = [
        command.requestHeader,
        command.expectedResponder,
        command.mode,
        command.identifier,
      ].join(':');
      if (!commandIds.add(commandId)) {
        issue(
          'duplicate_command',
          path,
          'duplicate request/responder/mode/identifier tuple',
        );
      }

      for (
        var signalIndex = 0;
        signalIndex < command.signals.length;
        signalIndex++
      ) {
        final signal = command.signals[signalIndex];
        final signalPath = '$path.signals[$signalIndex]';
        if (!signalIds.add(signal.id)) {
          issue(
            'duplicate_signal_id',
            '$signalPath.id',
            'signal ids must be unique within a profile',
          );
        }
        if (signal.id.trim().isEmpty || signal.name.trim().isEmpty) {
          issue(
            'missing_signal_identity',
            signalPath,
            'signal id and name are required',
          );
        }
        if (signal.equation.trim().isEmpty) {
          issue(
            'missing_equation',
            '$signalPath.equation',
            'signal equation is required',
          );
        } else if (signal.width > 14) {
          issue(
            'signal_too_wide',
            '$signalPath.width',
            'signal width exceeds the A..N formula byte window',
          );
        } else {
          final formulaIssue = FormulaEngine.validate(
            signal.equation,
            sampleBytes: List<int>.filled(signal.width, 1),
          );
          if (formulaIssue != null) {
            issue('invalid_equation', '$signalPath.equation', formulaIssue);
          }
        }
        if (!signal.minValue.isFinite ||
            !signal.maxValue.isFinite ||
            signal.minValue >= signal.maxValue) {
          issue(
            'invalid_signal_range',
            signalPath,
            'signal min_value and max_value must be finite and increasing',
          );
        }
        if (signal.offset < 0 ||
            signal.width <= 0 ||
            signal.offset + signal.width > command.payloadLength) {
          issue(
            'signal_out_of_bounds',
            signalPath,
            'signal byte slice must fit within payload_length',
          );
        }
      }
    }

    return PowertrainBatteryProfileValidation(profile: profile, issues: issues);
  }

  PowertrainBatteryCatalogValidation validateCatalog(
    PowertrainBatteryCatalog catalog,
  ) {
    final issues = <PowertrainBatteryProfileIssue>[];
    final ids = <String>{};
    for (var index = 0; index < catalog.profiles.length; index++) {
      final profile = catalog.profiles[index];
      if (!ids.add(profile.id)) {
        issues.add(
          PowertrainBatteryProfileIssue(
            code: 'duplicate_profile_id',
            path: 'profiles[$index].id',
            message: 'profile ids must be unique within a catalog',
          ),
        );
      }
      for (final profileIssue in validateProfile(profile).issues) {
        issues.add(
          PowertrainBatteryProfileIssue(
            code: profileIssue.code,
            path: 'profiles[$index].${profileIssue.path}',
            message: profileIssue.message,
          ),
        );
      }
    }
    return PowertrainBatteryCatalogValidation(issues: issues);
  }

  void _validateSource(
    PowertrainBatterySource source,
    void Function(String code, String path, String message) issue, {
    String pathPrefix = '',
  }) {
    if (source.name.trim().isEmpty) {
      issue(
        'missing_source',
        '${pathPrefix}source.name',
        'source name is required',
      );
    }
    final uri = Uri.tryParse(source.url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      issue(
        'invalid_source_url',
        '${pathPrefix}source.url',
        'source URL must be an absolute HTTPS URL',
      );
    }
    final revision = source.revision.trim();
    if (!isImmutablePowertrainRevision(revision)) {
      issue(
        'mutable_source',
        '${pathPrefix}source.revision',
        'source revision must be a full commit or content hash',
      );
    }
    if (source.license.trim().isEmpty) {
      issue(
        'missing_license',
        '${pathPrefix}source.license',
        'an explicit source license is required',
      );
    }
    if (source.path.trim().isEmpty || source.locator.trim().isEmpty) {
      issue(
        'missing_source_locator',
        '${pathPrefix}source.path/source.locator',
        'source path and locator are required',
      );
    }
  }

  /// Identity evidence gates by review tier.
  ///
  /// `ready` keeps the original bar: every field exact. `community` requires
  /// exact market, year and model, but accepts [sourcePartial] variant
  /// evidence — a BMS wire contract is a property of the battery system, and
  /// battery systems are shared across trims within a generation. What makes
  /// that scoping honest is the independent-corroboration requirement checked
  /// alongside this gate, not a relabelled evidence level.
  void _validateReviewedIdentityEvidence(
    PowertrainBatteryIdentityEvidence? identity,
    PowertrainProfileStatus status,
    void Function(String code, String path, String message) issue,
  ) {
    if (identity == null) {
      issue(
        'missing_identity_evidence',
        'identity_evidence',
        'ready/community source metadata must carry structured exact vehicle identity evidence',
      );
      return;
    }

    final fields = <String, PowertrainIdentityEvidenceLevel>{
      'market': identity.market,
      'year': identity.year,
      'model': identity.model,
      'variant': identity.variant,
    };
    for (final entry in fields.entries) {
      if (entry.value == PowertrainIdentityEvidenceLevel.exact) continue;
      final variantMayBePartial =
          status == PowertrainProfileStatus.community &&
          entry.key == 'variant' &&
          entry.value == PowertrainIdentityEvidenceLevel.sourcePartial;
      if (variantMayBePartial) continue;
      issue(
        'insufficient_identity_evidence',
        'identity_evidence.${entry.key}',
        status == PowertrainProfileStatus.community
            ? 'community source metadata requires exact ${entry.key} evidence '
                  '(variant may be sourcePartial when generation-scoped)'
            : 'ready source metadata requires exact ${entry.key} evidence',
      );
    }
  }

  void _validateCommand(
    PowertrainBatteryCommand command,
    String path,
    void Function(String code, String path, String message) issue,
  ) {
    if (!isExactPowertrainCanId(command.requestHeader) ||
        !isExactPowertrainCanId(command.expectedResponder)) {
      issue(
        'invalid_can_id',
        path,
        'request_header and expected_responder must be exact 11-bit or 29-bit CAN ids',
      );
    }

    if (deniedServices.contains(command.mode) ||
        !readOnlyServices.contains(command.mode)) {
      issue(
        'unsafe_service',
        '$path.mode',
        'only exact-responder read-only services 21 and 22 are allowed',
      );
    }
    final expectedIdentifierLength = switch (command.mode) {
      '01' || '09' || '21' => 2,
      '02' || '22' => 4,
      _ => null,
    };
    if (expectedIdentifierLength == null ||
        !RegExp(r'^[0-9A-F]+$').hasMatch(command.identifier) ||
        command.identifier.length != expectedIdentifierLength) {
      issue(
        'invalid_identifier',
        '$path.identifier',
        'identifier width must match the diagnostic service',
      );
    }
    if (command.payloadLength <= 0) {
      issue(
        'invalid_payload_length',
        '$path.payload_length',
        'payload_length must be positive',
      );
    }
    if (command.signals.isEmpty) {
      issue(
        'missing_signals',
        '$path.signals',
        'a command must expose at least one bounded signal',
      );
    }
  }

  /// One normalized "where the bytes came from" key for distinctness checks.
  static String _sourceLocation(PowertrainBatterySource source) => [
    source.url.trim().toLowerCase().replaceAll(RegExp(r'/+$'), ''),
    source.revision.trim().toLowerCase(),
    source.path.trim().toLowerCase(),
  ].join('\u0000');

  bool _isInexactIdentity(String value) {
    final normalized = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[_-]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ');
    final words = normalized.split(' ').toSet();
    return words.contains('tbd') ||
        words.contains('unknown') ||
        words.contains('unspecified') ||
        normalized.contains('not specified') ||
        normalized.contains('not reported') ||
        normalized.contains('not available') ||
        normalized == 'unknown' ||
        normalized == 'unspecified' ||
        normalized == 'source unknown' ||
        normalized == 'source unspecified' ||
        normalized == 'not reported' ||
        normalized == 'not available' ||
        normalized == 'n/a' ||
        normalized == 'na' ||
        normalized == 'any' ||
        normalized == 'all' ||
        normalized == 'all variants' ||
        normalized == 'all trims';
  }
}

final class PowertrainBatteryProfileIssue {
  const PowertrainBatteryProfileIssue({
    required this.code,
    required this.path,
    required this.message,
  });

  final String code;
  final String path;
  final String message;

  @override
  String toString() => '$code at $path: $message';
}

final class PowertrainBatteryProfileValidation {
  PowertrainBatteryProfileValidation({
    required this.profile,
    required List<PowertrainBatteryProfileIssue> issues,
  }) : issues = List.unmodifiable(issues);

  final PowertrainBatteryProfile profile;
  final List<PowertrainBatteryProfileIssue> issues;

  /// Whether this profile may be installed as dashboard PID definitions.
  ///
  /// Evidence is not the gate. A profile that passed structural validation
  /// and carries only pollable bounded-read commands may install when it is
  /// `ready`, `community`, or `experimental`. Mode 21 stays probe-only
  /// because [PollableServices] refuses it as a gauge service — that is
  /// command risk, not a missing field log. `researchOnly` has no commands.
  bool get canInstall {
    if (issues.isNotEmpty || profile.commands.isEmpty) return false;
    switch (profile.status) {
      case PowertrainProfileStatus.ready:
      case PowertrainProfileStatus.community:
      case PowertrainProfileStatus.experimental:
        return profile.commands.every(
          (command) => PollableServices.isPollable(command.modeAndIdentifier),
        );
      case PowertrainProfileStatus.researchOnly:
        return false;
    }
  }

  /// Whether the one-shot probe flow may read this profile's commands.
  ///
  /// Experimental entries have no other read path. Community entries are
  /// also probe-eligible — a consented single read is strictly less exposure
  /// than the periodic polling they already qualify for, and it lets a
  /// driver try one value before installing. Probing never installs.
  bool get canProbe =>
      issues.isEmpty &&
      (profile.status == PowertrainProfileStatus.experimental ||
          profile.status == PowertrainProfileStatus.community) &&
      profile.commands.isNotEmpty;
}

final class PowertrainBatteryCatalogValidation {
  PowertrainBatteryCatalogValidation({
    required List<PowertrainBatteryProfileIssue> issues,
  }) : issues = List.unmodifiable(issues);

  final List<PowertrainBatteryProfileIssue> issues;
  bool get isValid => issues.isEmpty;
}
