/// Provenance for vehicle-specific inputs that cannot be measured over OBD.
library;

/// The kind of source from which a field value came.
enum VehicleFieldOrigin {
  genericDefault,
  userEntered,
  officialRegistry,
  manufacturerPublication,
  scientificModel,
}

/// How confidently the field resolves to the current vehicle.
enum EvidenceResolution {
  unknown,
  userConfirmedSession,
  verifiedExact,
  ambiguous,
  conflict,
}

/// An immutable reference to an offline, integrity-checked source snapshot.
class EvidenceRef {
  const EvidenceRef({
    required this.sourceId,
    required this.publisher,
    required this.sourceUrl,
    required this.revision,
    required this.retrievedAt,
    required this.sha256,
    required this.market,
    required this.locator,
    required this.year,
    required this.make,
    required this.model,
    required this.trim,
  });

  final String sourceId;
  final String publisher;
  final String sourceUrl;
  final String revision;
  final String retrievedAt;
  final String sha256;
  final String market;
  final String locator;
  final int year;
  final String make;
  final String model;
  final String trim;

  bool get isValidExact {
    final uri = Uri.tryParse(sourceUrl);
    return sourceId.trim().isNotEmpty &&
        publisher.trim().isNotEmpty &&
        uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        revision.trim().isNotEmpty &&
        retrievedAt.trim().isNotEmpty &&
        RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256) &&
        market.trim().isNotEmpty &&
        locator.trim().isNotEmpty &&
        year >= 1886 &&
        make.trim().isNotEmpty &&
        model.trim().isNotEmpty &&
        trim.trim().isNotEmpty;
  }

  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'publisher': publisher,
    'sourceUrl': sourceUrl,
    'revision': revision,
    'retrievedAt': retrievedAt,
    'sha256': sha256,
    'market': market,
    'locator': locator,
    'year': year,
    'make': make,
    'model': model,
    'trim': trim,
  };

  static EvidenceRef? tryFromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    String string(String key) => raw[key] is String ? raw[key] as String : '';
    final ref = EvidenceRef(
      sourceId: string('sourceId'),
      publisher: string('publisher'),
      sourceUrl: string('sourceUrl'),
      revision: string('revision'),
      retrievedAt: string('retrievedAt'),
      sha256: string('sha256'),
      market: string('market'),
      locator: string('locator'),
      year: raw['year'] is int ? raw['year'] as int : 0,
      make: string('make'),
      model: string('model'),
      trim: string('trim'),
    );
    return ref.isValidExact ? ref : null;
  }

  @override
  bool operator ==(Object other) =>
      other is EvidenceRef &&
      sourceId == other.sourceId &&
      publisher == other.publisher &&
      sourceUrl == other.sourceUrl &&
      revision == other.revision &&
      retrievedAt == other.retrievedAt &&
      sha256 == other.sha256 &&
      market == other.market &&
      locator == other.locator &&
      year == other.year &&
      make == other.make &&
      model == other.model &&
      trim == other.trim;

  @override
  int get hashCode => Object.hash(
    sourceId,
    publisher,
    sourceUrl,
    revision,
    retrievedAt,
    sha256,
    market,
    locator,
    year,
    make,
    model,
    trim,
  );
}

class SourcedField<T> {
  factory SourcedField({
    required T value,
    required VehicleFieldOrigin origin,
    EvidenceResolution resolution = EvidenceResolution.unknown,
    EvidenceRef? evidence,
  }) {
    if (resolution == EvidenceResolution.verifiedExact &&
        (evidence == null || !evidence.isValidExact)) {
      throw ArgumentError.value(
        evidence,
        'evidence',
        'verifiedExact requires valid exact-vehicle evidence',
      );
    }
    if (resolution != EvidenceResolution.verifiedExact && evidence != null) {
      throw ArgumentError.value(
        evidence,
        'evidence',
        'only verifiedExact fields may carry evidence',
      );
    }
    if (resolution == EvidenceResolution.verifiedExact &&
        origin != VehicleFieldOrigin.officialRegistry &&
        origin != VehicleFieldOrigin.manufacturerPublication) {
      throw ArgumentError.value(
        origin,
        'origin',
        'verifiedExact requires an official or manufacturer source',
      );
    }
    return SourcedField<T>._(value, origin, resolution, evidence);
  }

  const SourcedField._(this.value, this.origin, this.resolution, this.evidence);

  final T value;
  final VehicleFieldOrigin origin;
  final EvidenceResolution resolution;
  final EvidenceRef? evidence;

  bool get isVerifiedExact =>
      resolution == EvidenceResolution.verifiedExact &&
      evidence?.isValidExact == true;

  Map<String, dynamic> toJson(Object? encodedValue) => {
    'value': encodedValue,
    'origin': origin.name,
    'resolution': resolution.name,
    if (evidence != null) 'evidence': evidence!.toJson(),
  };
}
