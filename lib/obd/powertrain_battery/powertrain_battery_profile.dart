/// Evidence-carrying, read-only powertrain battery profile schema.
library;

import 'dart:convert';

enum PowertrainProfileStatus {
  ready,
  community,
  experimental,
  researchOnly;

  static PowertrainProfileStatus parse(Object? value) {
    final text = _requiredString(value, 'status');
    for (final status in values) {
      if (status.name == text) return status;
    }
    throw PowertrainBatteryProfileFormatException(
      'unsupported profile status "$text"',
    );
  }
}

/// Evidence for this catalog entry, not evidence produced by this app.
///
/// A third-party project reporting a real vehicle remains [sourceBacked]. Only
/// a physical-vehicle run performed and retained by this project may use
/// [physicalVehicle].
enum PowertrainProfileEvidence {
  sourceBacked,
  syntheticRig,
  physicalVehicle;

  static PowertrainProfileEvidence parse(Object? value) {
    final text = _requiredString(value, 'evidence');
    for (final evidence in values) {
      if (evidence.name == text) return evidence;
    }
    throw PowertrainBatteryProfileFormatException(
      'unsupported profile evidence "$text"',
    );
  }
}

final class PowertrainBatterySource {
  const PowertrainBatterySource({
    required this.name,
    required this.url,
    required this.revision,
    required this.license,
    required this.path,
    required this.locator,
    this.artifactSha256 = '',
  });

  final String name;
  final String url;
  final String revision;
  final String license;
  final String path;
  final String locator;

  /// Digest of the exact source artifact from which executable data came.
  ///
  /// Required by the validator for experimental profiles. Metadata-only
  /// entries can continue to pin a repository/official dataset revision.
  final String artifactSha256;

  factory PowertrainBatterySource.fromJson(Map<String, Object?> json) =>
      PowertrainBatterySource(
        name: _requiredString(json['name'], 'source.name'),
        url: _requiredString(json['url'], 'source.url'),
        revision: _string(json['revision'], 'source.revision'),
        license: _string(json['license'], 'source.license'),
        path: _requiredString(json['path'], 'source.path'),
        locator: _requiredString(json['locator'], 'source.locator'),
        artifactSha256: _string(
          json['artifact_sha256'] ?? '',
          'source.artifact_sha256',
        ),
      );
}

enum PowertrainIdentityEvidenceLevel {
  exact,
  sourcePartial,
  unknown;

  static PowertrainIdentityEvidenceLevel parse(Object? value, String path) {
    final text = _requiredString(value, path);
    for (final level in values) {
      if (level.name == text) return level;
    }
    throw PowertrainBatteryProfileFormatException(
      'unsupported identity evidence "$text" at $path',
    );
  }
}

final class PowertrainBatteryIdentityEvidence {
  const PowertrainBatteryIdentityEvidence({
    required this.market,
    required this.year,
    required this.model,
    required this.variant,
  });

  final PowertrainIdentityEvidenceLevel market;
  final PowertrainIdentityEvidenceLevel year;
  final PowertrainIdentityEvidenceLevel model;
  final PowertrainIdentityEvidenceLevel variant;

  factory PowertrainBatteryIdentityEvidence.fromJson(
    Map<String, Object?> json,
  ) => PowertrainBatteryIdentityEvidence(
    market: PowertrainIdentityEvidenceLevel.parse(
      json['market'],
      'identity_evidence.market',
    ),
    year: PowertrainIdentityEvidenceLevel.parse(
      json['year'],
      'identity_evidence.year',
    ),
    model: PowertrainIdentityEvidenceLevel.parse(
      json['model'],
      'identity_evidence.model',
    ),
    variant: PowertrainIdentityEvidenceLevel.parse(
      json['variant'],
      'identity_evidence.variant',
    ),
  );
}

final class PowertrainBatterySignal {
  const PowertrainBatterySignal({
    required this.id,
    required this.name,
    required this.offset,
    required this.width,
    required this.equation,
    required this.unit,
    required this.minValue,
    required this.maxValue,
    required this.semanticKind,
    required this.recommended,
  });

  final String id;
  final String name;

  /// Zero-based byte offset within the declared response payload.
  final int offset;

  /// Number of response payload bytes consumed by this signal.
  final int width;
  final String equation;
  final String unit;
  final double minValue;
  final double maxValue;
  final String semanticKind;
  final bool recommended;

  factory PowertrainBatterySignal.fromJson(Map<String, Object?> json) =>
      PowertrainBatterySignal(
        id: _requiredString(json['id'], 'signal.id'),
        name: _requiredString(json['name'], 'signal.name'),
        offset: _integer(json['offset'], 'signal.offset'),
        width: _integer(json['width'], 'signal.width'),
        equation: _requiredString(json['equation'], 'signal.equation'),
        unit: _string(json['unit'], 'signal.unit'),
        minValue: _number(json['min_value'], 'signal.min_value'),
        maxValue: _number(json['max_value'], 'signal.max_value'),
        semanticKind: _requiredString(
          json['semantic_kind'],
          'signal.semantic_kind',
        ),
        recommended: _boolean(json['recommended'], 'signal.recommended'),
      );
}

final class PowertrainBatteryCommand {
  PowertrainBatteryCommand({
    required this.requestHeader,
    required this.expectedResponder,
    required this.mode,
    required this.identifier,
    required this.payloadLength,
    required List<PowertrainBatterySignal> signals,
  }) : signals = List.unmodifiable(signals);

  /// Exact CAN identifier used for the diagnostic request.
  final String requestHeader;

  /// Exact CAN identifier from which a matching response is accepted.
  final String expectedResponder;
  final String mode;
  final String identifier;

  /// Number of data bytes after the positive-response service and identifier.
  final int payloadLength;
  final List<PowertrainBatterySignal> signals;

  String get modeAndIdentifier => '$mode$identifier';

  String get wireKey => '$requestHeader:$expectedResponder:$mode:$identifier';

  factory PowertrainBatteryCommand.fromJson(Map<String, Object?> json) =>
      PowertrainBatteryCommand(
        requestHeader: _hexString(json['request_header'], 'request_header'),
        expectedResponder: _hexString(
          json['expected_responder'],
          'expected_responder',
        ),
        mode: _hexString(json['mode'], 'mode'),
        identifier: _hexString(json['identifier'], 'identifier'),
        payloadLength: _integer(json['payload_length'], 'payload_length'),
        signals: _objectList(
          json['signals'],
          'signals',
        ).map(PowertrainBatterySignal.fromJson).toList(growable: false),
      );
}

final class PowertrainBatteryProfile {
  PowertrainBatteryProfile({
    required this.id,
    required this.displayName,
    required this.description,
    required List<String> limitations,
    required this.status,
    required this.evidence,
    required this.market,
    required this.make,
    required this.model,
    required this.yearFrom,
    required this.yearTo,
    required this.variant,
    required this.powertrain,
    required this.source,
    required List<PowertrainBatteryCommand> commands,
    this.identityEvidence,
  }) : limitations = List.unmodifiable(limitations),
       commands = List.unmodifiable(commands);

  final String id;
  final String displayName;
  final String description;
  final List<String> limitations;
  final PowertrainProfileStatus status;
  final PowertrainProfileEvidence evidence;
  final String market;
  final String make;
  final String model;
  final int yearFrom;
  final int yearTo;
  final String variant;
  final String powertrain;
  final PowertrainBatterySource source;
  final List<PowertrainBatteryCommand> commands;
  final PowertrainBatteryIdentityEvidence? identityEvidence;

  bool appliesToYear(int year) => year >= yearFrom && year <= yearTo;

  factory PowertrainBatteryProfile.fromJson(
    Map<String, Object?> json,
  ) => PowertrainBatteryProfile(
    id: _requiredString(json['id'], 'profile.id'),
    displayName: _requiredString(json['display_name'], 'profile.display_name'),
    description: _requiredString(json['description'], 'profile.description'),
    limitations: _stringList(json['limitations'], 'profile.limitations'),
    status: PowertrainProfileStatus.parse(json['status']),
    evidence: PowertrainProfileEvidence.parse(json['evidence']),
    market: _requiredString(json['market'], 'profile.market'),
    make: _requiredString(json['make'], 'profile.make'),
    model: _requiredString(json['model'], 'profile.model'),
    yearFrom: _integer(json['year_from'], 'profile.year_from'),
    yearTo: _integer(json['year_to'], 'profile.year_to'),
    variant: _requiredString(json['variant'], 'profile.variant'),
    powertrain: _requiredString(json['powertrain'], 'profile.powertrain'),
    source: PowertrainBatterySource.fromJson(
      _object(json['source'], 'profile.source'),
    ),
    identityEvidence: json['identity_evidence'] == null
        ? null
        : PowertrainBatteryIdentityEvidence.fromJson(
            _object(json['identity_evidence'], 'profile.identity_evidence'),
          ),
    commands: _objectList(
      json['commands'],
      'profile.commands',
    ).map(PowertrainBatteryCommand.fromJson).toList(growable: false),
  );
}

final class PowertrainBatteryCatalog {
  static const int supportedSchemaVersion = 2;

  PowertrainBatteryCatalog({
    required this.schemaVersion,
    required List<PowertrainBatteryProfile> profiles,
  }) : profiles = List.unmodifiable(profiles);

  final int schemaVersion;
  final List<PowertrainBatteryProfile> profiles;

  factory PowertrainBatteryCatalog.fromJsonString(String source) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw PowertrainBatteryProfileFormatException(
        'catalog is not valid JSON: ${error.message}',
      );
    }
    return PowertrainBatteryCatalog.fromJson(_object(decoded, 'catalog'));
  }

  factory PowertrainBatteryCatalog.fromJson(Map<String, Object?> json) {
    final schemaVersion = _integer(json['schema_version'], 'schema_version');
    if (schemaVersion != supportedSchemaVersion) {
      throw PowertrainBatteryProfileFormatException(
        'unsupported schema_version $schemaVersion',
      );
    }
    return PowertrainBatteryCatalog(
      schemaVersion: schemaVersion,
      profiles: _objectList(
        json['profiles'],
        'profiles',
      ).map(PowertrainBatteryProfile.fromJson).toList(growable: false),
    );
  }
}

final class PowertrainBatteryProfileFormatException implements Exception {
  const PowertrainBatteryProfileFormatException(this.message);

  final String message;

  @override
  String toString() => 'PowertrainBatteryProfileFormatException: $message';
}

String _requiredString(Object? value, String path) {
  final result = _string(value, path).trim();
  if (result.isEmpty) {
    throw PowertrainBatteryProfileFormatException('$path must not be empty');
  }
  return result;
}

String _string(Object? value, String path) {
  if (value is! String) {
    throw PowertrainBatteryProfileFormatException('$path must be a string');
  }
  return value;
}

String _hexString(Object? value, String path) =>
    _string(value, path).replaceAll(RegExp(r'\s'), '').toUpperCase();

int _integer(Object? value, String path) {
  if (value is! int) {
    throw PowertrainBatteryProfileFormatException('$path must be an integer');
  }
  return value;
}

double _number(Object? value, String path) {
  if (value is! num) {
    throw PowertrainBatteryProfileFormatException('$path must be a number');
  }
  return value.toDouble();
}

bool _boolean(Object? value, String path) {
  if (value is! bool) {
    throw PowertrainBatteryProfileFormatException('$path must be a boolean');
  }
  return value;
}

List<String> _stringList(Object? value, String path) {
  if (value is! List) {
    throw PowertrainBatteryProfileFormatException('$path must be a list');
  }
  return List.unmodifiable([
    for (var index = 0; index < value.length; index++)
      _requiredString(value[index], '$path[$index]'),
  ]);
}

Map<String, Object?> _object(Object? value, String path) {
  if (value is! Map) {
    throw PowertrainBatteryProfileFormatException('$path must be an object');
  }
  try {
    return value.cast<String, Object?>();
  } on TypeError {
    throw PowertrainBatteryProfileFormatException('$path must use string keys');
  }
}

List<Map<String, Object?>> _objectList(Object? value, String path) {
  if (value is! List) {
    throw PowertrainBatteryProfileFormatException('$path must be a list');
  }
  return [
    for (var index = 0; index < value.length; index++)
      _object(value[index], '$path[$index]'),
  ];
}
