library;

import 'dart:convert';
import 'dart:typed_data';

import '../../core/hash/fnv1a64.dart';
import '../../obd/transport/obd_transport.dart';

const int maximumTelemetrySignals = 32;

final class TelemetryValidationException implements Exception {
  const TelemetryValidationException(this.code, {this.field, this.message});

  final String code;
  final String? field;
  final String? message;

  @override
  String toString() => [
    'TelemetryValidationException($code',
    if (field != null) ' field=$field',
    if (message != null) ' $message',
    ')',
  ].join();
}

enum UnitProvenance {
  standardDirectCanonical,
  shippedDerivedOrVariant,
  userDefined;

  String get wireName => name;
  bool get allowsFutureAutomaticConversion =>
      this == UnitProvenance.standardDirectCanonical;
}

enum TelemetrySource {
  demo,
  simulatedRig,
  fieldAppConnection;

  String get wireName => name;
}

TelemetrySource deriveTelemetrySource({
  required TransportKind transport,
  required bool requiresSimulatedEvidence,
}) {
  if (transport == TransportKind.demo) return TelemetrySource.demo;
  return requiresSimulatedEvidence
      ? TelemetrySource.simulatedRig
      : TelemetrySource.fieldAppConnection;
}

enum TelemetryStatus {
  stale,
  unsupported,
  noAnswer,
  formulaError,
  busError,
  headerMismatch,
  unsafeServiceRefusal;

  String get wireName => name;
}

/// Quality of a structurally valid finite value. Missing on old recordings
/// means [valid]. Out-of-range is still a value, never a numeric success
/// upgrade, and never a reason to drop the sample.
enum TelemetryQuality {
  valid,
  outOfReferenceRange,
  tentativeDecode;

  String get wireName => name;
}

enum TelemetryTerminalReason {
  user,
  disconnect,
  sessionReplacement,
  background,
  durationLimit,
  sessionSizeLimit,
  librarySizeLimit,
  storageBackpressure,
  configurationChanged,
  storageFailure,
  recoveredAfterInterruption;

  String get wireName => name;
}

final class TelemetrySignalDefinition {
  const TelemetrySignalDefinition({
    required this.id,
    required this.name,
    required this.shortName,
    required this.request,
    required this.header,
    required this.unit,
    required this.unitProvenance,
    required this.minimum,
    required this.maximum,
    required this.isCustom,
    required this.variant,
    required this.priority,
    required this.equation,
    this.evidenceKind,
    this.assumptions,
  });

  final String id;
  final String name;
  final String shortName;
  final String request;
  final String header;
  final String unit;
  final UnitProvenance unitProvenance;
  final double? minimum;
  final double? maximum;
  final bool isCustom;
  final String variant;
  final int priority;
  final String equation;

  /// USABILITY-R2 evidence tier. Omitted from canonical JSON when null so
  /// existing recordings keep their fingerprints.
  final String? evidenceKind;

  /// Frozen estimate disclosure captured at Start. Omitted when null.
  final String? assumptions;

  Map<String, Object?> toCanonicalJson() {
    final json = <String, Object?>{
      'id': id,
      'name': name,
      'shortName': shortName,
      'request': request,
      'header': header,
      'unit': unit,
      'unitProvenance': unitProvenance.wireName,
      'minimum': minimum,
      'maximum': maximum,
      'isCustom': isCustom,
      'variant': variant,
      'priority': priority,
      'equation': equation,
    };
    if (evidenceKind != null && evidenceKind!.isNotEmpty) {
      json['evidenceKind'] = evidenceKind;
    }
    if (assumptions != null && assumptions!.isNotEmpty) {
      json['assumptions'] = assumptions;
    }
    return json;
  }
}

final class FrozenPidDefinition {
  FrozenPidDefinition._({
    required this.definition,
    required this._canonicalBytes,
    required this.fingerprint,
  });

  factory FrozenPidDefinition.freeze(TelemetrySignalDefinition definition) {
    _validateDefinition(definition);
    final bytes = Uint8List.fromList(
      utf8.encode(jsonEncode(definition.toCanonicalJson())),
    );
    return FrozenPidDefinition._(
      definition: definition,
      canonicalBytes: bytes,
      fingerprint: fnv1a64(bytes),
    );
  }

  final TelemetrySignalDefinition definition;
  final Uint8List _canonicalBytes;
  final String fingerprint;

  Uint8List get canonicalBytes => Uint8List.fromList(_canonicalBytes);

  bool matchesExact(FrozenPidDefinition other) =>
      _bytesEqual(_canonicalBytes, other._canonicalBytes);

  /// Integrity hashes never authorize a definition by themselves. Callers
  /// accepting live readings must compare both the claimed fingerprint and
  /// the exact canonical bytes frozen at Start.
  bool matchesFingerprintAndCanonicalBytes({
    required String claimedFingerprint,
    required List<int> claimedCanonicalBytes,
  }) =>
      claimedFingerprint == fingerprint &&
      _bytesEqual(_canonicalBytes, claimedCanonicalBytes);

  static void _validateDefinition(TelemetrySignalDefinition value) {
    _checkText(value.id, 256, 'id', allowEmpty: false);
    _checkText(value.name, 512, 'name', allowEmpty: false);
    _checkText(value.shortName, 128, 'shortName', allowEmpty: false);
    _checkText(value.request, 64, 'request', allowEmpty: false);
    _checkText(value.header, 64, 'header');
    _checkText(value.unit, 64, 'unit');
    _checkText(value.variant, 128, 'variant');
    _checkText(value.equation, 4096, 'equation', allowEmpty: false);
    if (value.assumptions != null) {
      _checkText(value.assumptions!, 1024, 'assumptions');
    }
    if ((value.minimum != null && !value.minimum!.isFinite) ||
        (value.maximum != null && !value.maximum!.isFinite)) {
      throw const TelemetryValidationException(
        'nonFiniteDefinitionRange',
        field: 'minimum/maximum',
      );
    }
    if (value.minimum != null &&
        value.maximum != null &&
        value.minimum! > value.maximum!) {
      throw const TelemetryValidationException(
        'invalidDefinitionRange',
        field: 'minimum/maximum',
      );
    }
    if (value.priority < 0 || value.priority > 3) {
      throw const TelemetryValidationException(
        'invalidPriority',
        field: 'priority',
      );
    }
    if (!_canonicalRequest.hasMatch(value.request)) {
      throw const TelemetryValidationException(
        'invalidRequestProvenance',
        field: 'request',
      );
    }
    if (value.header.isNotEmpty && !_canonicalHeader.hasMatch(value.header)) {
      throw const TelemetryValidationException(
        'invalidHeaderProvenance',
        field: 'header',
      );
    }
    switch (value.unitProvenance) {
      case UnitProvenance.standardDirectCanonical:
        if (value.isCustom ||
            value.variant.isNotEmpty ||
            !_standardMode01Request.hasMatch(value.request) ||
            (value.header.isNotEmpty && value.header != '7E0') ||
            value.unit.isEmpty) {
          throw const TelemetryValidationException(
            'invalidUnitProvenance',
            field: 'unitProvenance',
          );
        }
      case UnitProvenance.shippedDerivedOrVariant:
        final identifiesVariant =
            value.variant.isNotEmpty ||
            !_standardMode01Request.hasMatch(value.request) ||
            (value.header.isNotEmpty && value.header != '7E0');
        if (value.isCustom || value.unit.isEmpty || !identifiesVariant) {
          throw const TelemetryValidationException(
            'invalidUnitProvenance',
            field: 'unitProvenance',
          );
        }
      case UnitProvenance.userDefined:
        if (!value.isCustom) {
          throw const TelemetryValidationException(
            'invalidUnitProvenance',
            field: 'unitProvenance',
          );
        }
    }
  }
}

final RegExp _canonicalRequest = RegExp(r'^[0-9A-F]{2}(?: ?[0-9A-F]{2})+$');
final RegExp _standardMode01Request = RegExp(r'^01 ?[0-9A-F]{2}$');
final RegExp _canonicalHeader = RegExp(r'^[0-9A-F]{1,64}$');

String fnv1a64(List<int> bytes) {
  return (Fnv1a64()..add(bytes)).fingerprint;
}

String configurationFingerprint(List<FrozenPidDefinition> definitions) {
  return _configurationFingerprintFor(definitions);
}

String _configurationFingerprintFor(List<FrozenPidDefinition> definitions) {
  final bytes = <int>[0x5b];
  for (var index = 0; index < definitions.length; index++) {
    if (index != 0) bytes.add(0x2c);
    bytes.addAll(definitions[index]._canonicalBytes);
  }
  bytes.add(0x5d);
  return fnv1a64(bytes);
}

final class TelemetrySessionHeader {
  TelemetrySessionHeader({
    this.schemaVersion = 1,
    required this.sessionId,
    required this.startedAtUtc,
    required this.source,
    required this.transport,
    required this.protocol,
    required List<FrozenPidDefinition> signals,
    String? configurationFingerprint,
  }) : signals = List.unmodifiable(signals),
       configurationFingerprint =
           configurationFingerprint ??
           _validatedConfigurationFingerprint(signals) {
    if (schemaVersion != 1) {
      throw const TelemetryValidationException('unknownSchema');
    }
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(sessionId)) {
      throw const TelemetryValidationException(
        'invalidSessionId',
        field: 'sessionId',
      );
    }
    _requireUtc(startedAtUtc, 'startedAtUtc');
    _checkText(protocol, 512, 'protocol', allowEmpty: false);
    final isDemoTransport = transport == TransportKind.demo;
    if ((source == TelemetrySource.demo) != isDemoTransport) {
      throw const TelemetryValidationException(
        'sourceTransportMismatch',
        field: 'source/transport',
      );
    }
    final expected = _validatedConfigurationFingerprint(signals);
    if (this.configurationFingerprint != expected) {
      throw const TelemetryValidationException('fingerprintMismatch');
    }
  }

  final int schemaVersion;
  final String sessionId;
  final DateTime startedAtUtc;
  final TelemetrySource source;
  final TransportKind transport;
  final String protocol;
  final List<FrozenPidDefinition> signals;
  final String configurationFingerprint;

  static String _validatedConfigurationFingerprint(
    List<FrozenPidDefinition> signals,
  ) {
    if (signals.isEmpty || signals.length > maximumTelemetrySignals) {
      throw const TelemetryValidationException(
        'invalidSignalCount',
        field: 'signals',
      );
    }
    final ids = <String>{};
    for (final signal in signals) {
      if (!ids.add(signal.definition.id)) {
        throw const TelemetryValidationException(
          'duplicatePid',
          field: 'signals',
        );
      }
    }
    return _configurationFingerprintFor(signals);
  }
}

enum TelemetryEventKind { value, status }

final class TelemetryEvent {
  TelemetryEvent._({
    required this.kind,
    required this.observedAtUtc,
    required this.elapsedUs,
    required this.pidId,
    this.value,
    this.sourceTimestampUtc,
    this.status,
    this.quality,
  }) {
    _requireUtc(observedAtUtc, 'observedAtUtc');
    if (elapsedUs < 0) {
      throw const TelemetryValidationException(
        'negativeElapsed',
        field: 'elapsedUs',
      );
    }
    if (pidId.isEmpty || utf8.encode(pidId).length > 256) {
      throw const TelemetryValidationException('invalidPid', field: 'pidId');
    }
    if (kind == TelemetryEventKind.value) {
      if (value == null || !value!.isFinite || sourceTimestampUtc == null) {
        throw const TelemetryValidationException('invalidValueEvent');
      }
      _requireUtc(sourceTimestampUtc!, 'sourceTimestampUtc');
      // Same fail-closed rule as TelemetryRecorder.ingest: a source stamp
      // after observation makes sample age negative and looks "fresh".
      if (sourceTimestampUtc!.isAfter(observedAtUtc)) {
        throw const TelemetryValidationException(
          'futureDatedSource',
          field: 'sourceTimestampUtc',
        );
      }
      if (status != null) {
        throw const TelemetryValidationException('mixedEvent');
      }
    } else if (status == null ||
        value != null ||
        sourceTimestampUtc != null ||
        quality != null) {
      throw const TelemetryValidationException('invalidStatusEvent');
    }
  }

  factory TelemetryEvent.value({
    required DateTime observedAtUtc,
    required DateTime sourceTimestampUtc,
    required int elapsedUs,
    required String pidId,
    required double value,
    TelemetryQuality quality = TelemetryQuality.valid,
  }) => TelemetryEvent._(
    kind: TelemetryEventKind.value,
    observedAtUtc: observedAtUtc,
    sourceTimestampUtc: sourceTimestampUtc,
    elapsedUs: elapsedUs,
    pidId: pidId,
    value: value,
    quality: quality,
  );

  factory TelemetryEvent.status({
    required DateTime observedAtUtc,
    required int elapsedUs,
    required String pidId,
    required TelemetryStatus status,
  }) => TelemetryEvent._(
    kind: TelemetryEventKind.status,
    observedAtUtc: observedAtUtc,
    elapsedUs: elapsedUs,
    pidId: pidId,
    status: status,
  );

  final TelemetryEventKind kind;
  final DateTime observedAtUtc;
  final int elapsedUs;
  final String pidId;
  final double? value;
  final DateTime? sourceTimestampUtc;
  final TelemetryStatus? status;
  final TelemetryQuality? quality;
}

final class TelemetrySessionFooter {
  TelemetrySessionFooter({
    required this.endedAtUtc,
    required this.terminalReason,
    required this.valueCount,
    required this.statusCount,
    required this.gapCount,
    required this.bytesBeforeFooter,
  }) {
    _requireUtc(endedAtUtc, 'endedAtUtc');
    if (valueCount < 0 ||
        statusCount < 0 ||
        gapCount < 0 ||
        bytesBeforeFooter < 0) {
      throw const TelemetryValidationException('negativeFooterCount');
    }
  }

  final DateTime endedAtUtc;
  final TelemetryTerminalReason terminalReason;
  final int valueCount;
  final int statusCount;
  final int gapCount;
  final int bytesBeforeFooter;
}

final class TelemetrySession {
  TelemetrySession({
    required this.header,
    required List<TelemetryEvent> events,
    required this.footer,
  }) : events = List.unmodifiable(events);

  final TelemetrySessionHeader header;
  final List<TelemetryEvent> events;
  final TelemetrySessionFooter footer;
}

void _checkText(
  String value,
  int maximumBytes,
  String field, {
  bool allowEmpty = true,
}) {
  final length = utf8.encode(value).length;
  if ((!allowEmpty && length == 0) || length > maximumBytes) {
    throw TelemetryValidationException(
      'fieldLimit',
      field: field,
      message: 'UTF-8 bytes $length exceed $maximumBytes',
    );
  }
}

void _requireUtc(DateTime value, String field) {
  if (!value.isUtc) {
    throw TelemetryValidationException('utcRequired', field: field);
  }
}

bool _bytesEqual(List<int> first, List<int> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}
