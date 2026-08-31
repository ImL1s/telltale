/// Fail-closed validation for installable powertrain battery profiles.
library;

import '../pid/formula_engine.dart';
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
    if (reviewedStatus) {
      _validateReviewedIdentityEvidence(profile.identityEvidence, issue);
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
    void Function(String code, String path, String message) issue,
  ) {
    if (source.name.trim().isEmpty) {
      issue('missing_source', 'source.name', 'source name is required');
    }
    final uri = Uri.tryParse(source.url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      issue(
        'invalid_source_url',
        'source.url',
        'source URL must be an absolute HTTPS URL',
      );
    }
    final revision = source.revision.trim();
    if (!isImmutablePowertrainRevision(revision)) {
      issue(
        'mutable_source',
        'source.revision',
        'source revision must be a full commit or content hash',
      );
    }
    if (source.license.trim().isEmpty) {
      issue(
        'missing_license',
        'source.license',
        'an explicit source license is required',
      );
    }
    if (source.path.trim().isEmpty || source.locator.trim().isEmpty) {
      issue(
        'missing_source_locator',
        'source.path/source.locator',
        'source path and locator are required',
      );
    }
  }

  void _validateReviewedIdentityEvidence(
    PowertrainBatteryIdentityEvidence? identity,
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
      if (entry.value != PowertrainIdentityEvidenceLevel.exact) {
        issue(
          'insufficient_identity_evidence',
          'identity_evidence.${entry.key}',
          'ready/community source metadata requires exact ${entry.key} evidence',
        );
      }
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

  /// Profile installation is intentionally unavailable in this release.
  ///
  /// `ready` and `community` describe source-review maturity only. They are
  /// not a runtime trust grant, and the bundled catalog currently has no
  /// installable profile. Keeping this closed here means an injected catalog
  /// entry cannot turn status text into persistent or periodic vehicle I/O.
  bool get canInstall => false;

  /// Experimental entries may only be used by the one-shot probe flow.
  ///
  /// This deliberately does not make them installable dashboard PIDs.
  bool get canProbe =>
      issues.isEmpty &&
      profile.status == PowertrainProfileStatus.experimental &&
      profile.commands.isNotEmpty;
}

final class PowertrainBatteryCatalogValidation {
  PowertrainBatteryCatalogValidation({
    required List<PowertrainBatteryProfileIssue> issues,
  }) : issues = List.unmodifiable(issues);

  final List<PowertrainBatteryProfileIssue> issues;
  bool get isValid => issues.isEmpty;
}
