library;

import 'dart:convert';
import 'dart:typed_data';

import '../../obd/transport/obd_transport.dart';
import 'telemetry_session.dart';

enum TelemetryLineKind { header, event, footer }

final class TelemetryCorruption {
  const TelemetryCorruption(this.code, [this.detail]);

  final String code;
  final String? detail;

  @override
  String toString() => detail == null ? code : '$code: $detail';
}

final class TelemetryDecodeResult {
  const TelemetryDecodeResult.success(this.session) : error = null;
  const TelemetryDecodeResult.failure(this.error) : session = null;

  final TelemetrySession? session;
  final TelemetryCorruption? error;
  bool get isSuccess => session != null;
}

final class TelemetryLineDecodeResult<T> {
  const TelemetryLineDecodeResult.success(this.value) : error = null;
  const TelemetryLineDecodeResult.failure(this.error) : value = null;

  final T? value;
  final TelemetryCorruption? error;
  bool get isSuccess => value != null;
}

abstract final class TelemetrySessionCodec {
  static const maximumHeaderLineBytes = 64 * 1024;
  static const maximumEventOrFooterLineBytes = 2048;

  static Uint8List encode(TelemetrySession session) {
    final prefix = encodePrefix(session.header, session.events);
    if (session.footer.bytesBeforeFooter != prefix.length) {
      throw const TelemetryValidationException('bytesBeforeFooterMismatch');
    }
    final footer = encodeFooterLine(session.footer);
    return Uint8List.fromList(<int>[...prefix, ...footer]);
  }

  static Uint8List encodeHeaderLine(TelemetrySessionHeader header) =>
      _line(_headerJson(header), TelemetryLineKind.header);

  static Uint8List encodeEventLine(TelemetryEvent event) =>
      _line(_eventJson(event), TelemetryLineKind.event);

  static Uint8List encodeFooterLine(TelemetrySessionFooter footer) =>
      _line(_footerJson(footer), TelemetryLineKind.footer);

  /// Decodes one complete header line, including its terminating LF.
  ///
  /// This is the bounded validation seam used by incremental readers. It
  /// never throws for untrusted input.
  static TelemetryLineDecodeResult<TelemetrySessionHeader> decodeHeaderLine(
    List<int> encodedLineIncludingLf,
  ) => _decodeCompleteLine(
    encodedLineIncludingLf,
    TelemetryLineKind.header,
    _decodeHeader,
  );

  /// Validates a header object that was already decoded from one bounded line.
  static TelemetryLineDecodeResult<TelemetrySessionHeader> decodeHeaderObject(
    Map<String, Object?> object,
  ) => _decodeObject(object, TelemetryLineKind.header, _decodeHeader);

  /// Decodes one complete event line and validates frozen PID membership and
  /// the nondecreasing elapsed axis.
  static TelemetryLineDecodeResult<TelemetryEvent> decodeEventLine(
    List<int> encodedLineIncludingLf,
    TelemetrySessionHeader header,
    int previousElapsedUs,
  ) {
    final result = _decodeCompleteLine(
      encodedLineIncludingLf,
      TelemetryLineKind.event,
      _decodeEvent,
    );
    final event = result.value;
    if (event == null) return result;
    if (!header.signals.any((signal) => signal.definition.id == event.pidId)) {
      return const TelemetryLineDecodeResult.failure(
        TelemetryCorruption('unknownPid'),
      );
    }
    if (event.elapsedUs < previousElapsedUs) {
      return const TelemetryLineDecodeResult.failure(
        TelemetryCorruption('backwardElapsed'),
      );
    }
    return result;
  }

  /// Validates an event object that was already decoded from one bounded line.
  static TelemetryLineDecodeResult<TelemetryEvent> decodeEventObject(
    Map<String, Object?> object,
    TelemetrySessionHeader header,
    int previousElapsedUs,
  ) {
    final result = _decodeObject(object, TelemetryLineKind.event, _decodeEvent);
    return _validateEvent(result, header, previousElapsedUs);
  }

  /// Decodes one complete footer line and verifies all accumulated counters
  /// and the exact prefix byte length supplied by the incremental reader.
  static TelemetryLineDecodeResult<TelemetrySessionFooter> decodeFooterLine(
    List<int> encodedLineIncludingLf,
    int expectedValueCount,
    int expectedStatusCount,
    int expectedGapCount,
    int expectedBytesBeforeFooter,
  ) {
    final result = _decodeCompleteLine(
      encodedLineIncludingLf,
      TelemetryLineKind.footer,
      _decodeFooter,
    );
    return _validateFooter(
      result,
      expectedValueCount,
      expectedStatusCount,
      expectedGapCount,
      expectedBytesBeforeFooter,
    );
  }

  /// Validates a footer object that was already decoded from one bounded line.
  static TelemetryLineDecodeResult<TelemetrySessionFooter> decodeFooterObject(
    Map<String, Object?> object,
    int expectedValueCount,
    int expectedStatusCount,
    int expectedGapCount,
    int expectedBytesBeforeFooter,
  ) {
    final result = _decodeObject(
      object,
      TelemetryLineKind.footer,
      _decodeFooter,
    );
    return _validateFooter(
      result,
      expectedValueCount,
      expectedStatusCount,
      expectedGapCount,
      expectedBytesBeforeFooter,
    );
  }

  static TelemetryLineDecodeResult<TelemetryEvent> _validateEvent(
    TelemetryLineDecodeResult<TelemetryEvent> result,
    TelemetrySessionHeader header,
    int previousElapsedUs,
  ) {
    final event = result.value;
    if (event == null) return result;
    if (!header.signals.any((signal) => signal.definition.id == event.pidId)) {
      return const TelemetryLineDecodeResult.failure(
        TelemetryCorruption('unknownPid'),
      );
    }
    if (event.elapsedUs < previousElapsedUs) {
      return const TelemetryLineDecodeResult.failure(
        TelemetryCorruption('backwardElapsed'),
      );
    }
    return result;
  }

  static TelemetryLineDecodeResult<TelemetrySessionFooter> _validateFooter(
    TelemetryLineDecodeResult<TelemetrySessionFooter> result,
    int expectedValueCount,
    int expectedStatusCount,
    int expectedGapCount,
    int expectedBytesBeforeFooter,
  ) {
    final footer = result.value;
    if (footer == null) return result;
    if (footer.valueCount != expectedValueCount ||
        footer.statusCount != expectedStatusCount ||
        footer.gapCount != expectedGapCount) {
      return const TelemetryLineDecodeResult.failure(
        TelemetryCorruption('countMismatch'),
      );
    }
    if (footer.bytesBeforeFooter != expectedBytesBeforeFooter) {
      return const TelemetryLineDecodeResult.failure(
        TelemetryCorruption('bytesBeforeFooterMismatch'),
      );
    }
    return result;
  }

  static Uint8List encodePrefix(
    TelemetrySessionHeader header,
    Iterable<TelemetryEvent> events,
  ) {
    final bytes = <int>[...encodeHeaderLine(header)];
    var previousElapsed = -1;
    final knownIds = header.signals.map((value) => value.definition.id).toSet();
    for (final event in events) {
      if (!knownIds.contains(event.pidId)) {
        throw const TelemetryValidationException('unknownPid');
      }
      if (event.elapsedUs < previousElapsed) {
        throw const TelemetryValidationException('backwardElapsed');
      }
      previousElapsed = event.elapsedUs;
      bytes.addAll(encodeEventLine(event));
    }
    return Uint8List.fromList(bytes);
  }

  static TelemetryDecodeResult decode(List<int> bytes) {
    try {
      if (bytes.isEmpty || bytes.last != 0x0a) {
        return const TelemetryDecodeResult.failure(
          TelemetryCorruption('incompleteTail'),
        );
      }
      final text = utf8.decode(bytes, allowMalformed: false);
      final lines = text.substring(0, text.length - 1).split('\n');
      if (lines.length < 2) {
        return const TelemetryDecodeResult.failure(
          TelemetryCorruption('missingEnvelope'),
        );
      }
      final headerBytes = utf8.encode('${lines.first}\n');
      checkLineLimit(
        headerBytes.sublist(0, headerBytes.length - 1),
        kind: TelemetryLineKind.header,
      );
      final headerMap = _object(lines.first);
      if (headerMap['type'] != 'header') {
        return const TelemetryDecodeResult.failure(
          TelemetryCorruption('headerFirst'),
        );
      }
      final header = _decodeHeader(headerMap);
      final events = <TelemetryEvent>[];
      var elapsed = -1;
      var valueCount = 0;
      var statusCount = 0;
      var gapCount = 0;
      final available = <String, bool>{};
      var prefixBytes = headerBytes.length;
      TelemetrySessionFooter? footer;
      for (var index = 1; index < lines.length; index++) {
        final lineBytes = utf8.encode('${lines[index]}\n');
        final object = _object(lines[index]);
        final type = object['type'];
        if (type == 'footer') {
          checkLineLimit(
            lineBytes.sublist(0, lineBytes.length - 1),
            kind: TelemetryLineKind.footer,
          );
          if (index != lines.length - 1 || footer != null) {
            throw const TelemetryValidationException('footerLast');
          }
          footer = _decodeFooter(object);
          continue;
        }
        checkLineLimit(
          lineBytes.sublist(0, lineBytes.length - 1),
          kind: TelemetryLineKind.event,
        );
        if (type == 'header') {
          throw const TelemetryValidationException('duplicateHeader');
        }
        final event = _decodeEvent(object);
        if (!header.signals.any(
          (signal) => signal.definition.id == event.pidId,
        )) {
          throw const TelemetryValidationException('unknownPid');
        }
        if (event.elapsedUs < elapsed) {
          throw const TelemetryValidationException('backwardElapsed');
        }
        elapsed = event.elapsedUs;
        events.add(event);
        prefixBytes += lineBytes.length;
        if (event.kind == TelemetryEventKind.value) {
          valueCount++;
          available[event.pidId] = true;
        } else {
          statusCount++;
          if (available[event.pidId] ?? false) gapCount++;
          available[event.pidId] = false;
        }
      }
      if (footer == null) {
        throw const TelemetryValidationException('missingFooter');
      }
      if (footer.valueCount != valueCount ||
          footer.statusCount != statusCount ||
          footer.gapCount != gapCount) {
        return const TelemetryDecodeResult.failure(
          TelemetryCorruption('countMismatch'),
        );
      }
      if (footer.bytesBeforeFooter != prefixBytes) {
        return const TelemetryDecodeResult.failure(
          TelemetryCorruption('bytesBeforeFooterMismatch'),
        );
      }
      return TelemetryDecodeResult.success(
        TelemetrySession(header: header, events: events, footer: footer),
      );
    } on FormatException catch (error) {
      return TelemetryDecodeResult.failure(
        TelemetryCorruption('invalidEncoding', '$error'),
      );
    } on TelemetryValidationException catch (error) {
      return TelemetryDecodeResult.failure(
        TelemetryCorruption(error.code, error.field),
      );
    } on Object catch (error) {
      return TelemetryDecodeResult.failure(
        TelemetryCorruption('malformed', '$error'),
      );
    }
  }

  static void checkLineLimit(
    List<int> contentWithoutLf, {
    required TelemetryLineKind kind,
  }) {
    final maximum = kind == TelemetryLineKind.header
        ? maximumHeaderLineBytes
        : maximumEventOrFooterLineBytes;
    if (contentWithoutLf.length + 1 > maximum) {
      throw TelemetryValidationException('lineLimit', field: kind.name);
    }
  }

  static Uint8List _line(Map<String, Object?> value, TelemetryLineKind kind) {
    final content = utf8.encode(jsonEncode(value));
    checkLineLimit(content, kind: kind);
    return Uint8List.fromList(<int>[...content, 0x0a]);
  }

  static TelemetryLineDecodeResult<T> _decodeCompleteLine<T>(
    List<int> encodedLineIncludingLf,
    TelemetryLineKind kind,
    T Function(Map<String, Object?> object) decode,
  ) {
    try {
      if (encodedLineIncludingLf.isEmpty ||
          encodedLineIncludingLf.last != 0x0a) {
        return const TelemetryLineDecodeResult.failure(
          TelemetryCorruption('incompleteTail'),
        );
      }
      final content = encodedLineIncludingLf is Uint8List
          ? Uint8List.sublistView(
              encodedLineIncludingLf,
              0,
              encodedLineIncludingLf.length - 1,
            )
          : encodedLineIncludingLf.sublist(
              0,
              encodedLineIncludingLf.length - 1,
            );
      checkLineLimit(content, kind: kind);
      final object = _object(utf8.decode(content, allowMalformed: false));
      return _decodeObject(object, kind, decode);
    } on FormatException catch (error) {
      return TelemetryLineDecodeResult.failure(
        TelemetryCorruption('invalidEncoding', '$error'),
      );
    } on TelemetryValidationException catch (error) {
      return TelemetryLineDecodeResult.failure(
        TelemetryCorruption(error.code, error.field),
      );
    } on Object catch (error) {
      return TelemetryLineDecodeResult.failure(
        TelemetryCorruption('malformed', '$error'),
      );
    }
  }

  static TelemetryLineDecodeResult<T> _decodeObject<T>(
    Map<String, Object?> object,
    TelemetryLineKind kind,
    T Function(Map<String, Object?> object) decode,
  ) {
    try {
      final expectedType = switch (kind) {
        TelemetryLineKind.header => 'header',
        TelemetryLineKind.event => null,
        TelemetryLineKind.footer => 'footer',
      };
      if (expectedType != null && object['type'] != expectedType) {
        throw const TelemetryValidationException('wrongLineKind');
      }
      if (kind == TelemetryLineKind.event &&
          object['type'] != 'value' &&
          object['type'] != 'status') {
        throw const TelemetryValidationException('wrongLineKind');
      }
      return TelemetryLineDecodeResult.success(decode(object));
    } on FormatException catch (error) {
      return TelemetryLineDecodeResult.failure(
        TelemetryCorruption('invalidEncoding', '$error'),
      );
    } on TelemetryValidationException catch (error) {
      return TelemetryLineDecodeResult.failure(
        TelemetryCorruption(error.code, error.field),
      );
    } on Object catch (error) {
      return TelemetryLineDecodeResult.failure(
        TelemetryCorruption('malformed', '$error'),
      );
    }
  }

  static Map<String, Object?> _headerJson(TelemetrySessionHeader header) =>
      <String, Object?>{
        'type': 'header',
        'schemaVersion': header.schemaVersion,
        'sessionId': header.sessionId,
        'startedAtUtc': header.startedAtUtc.toIso8601String(),
        'source': header.source.wireName,
        'transport': header.transport.name,
        'protocol': header.protocol,
        'signals': [
          for (final signal in header.signals)
            <String, Object?>{
              'definition': signal.definition.toCanonicalJson(),
              'fingerprint': signal.fingerprint,
            },
        ],
        'configurationFingerprint': header.configurationFingerprint,
      };

  static Map<String, Object?> _eventJson(TelemetryEvent event) =>
      switch (event.kind) {
        TelemetryEventKind.value => <String, Object?>{
          'type': 'value',
          'observedAtUtc': event.observedAtUtc.toIso8601String(),
          'sourceTimestampUtc': event.sourceTimestampUtc!.toIso8601String(),
          'elapsedUs': event.elapsedUs,
          'pidId': event.pidId,
          'value': event.value,
          if (event.quality != null && event.quality != TelemetryQuality.valid)
            'quality': event.quality!.wireName,
        },
        TelemetryEventKind.status => <String, Object?>{
          'type': 'status',
          'observedAtUtc': event.observedAtUtc.toIso8601String(),
          'elapsedUs': event.elapsedUs,
          'pidId': event.pidId,
          'status': event.status!.wireName,
        },
      };

  static Map<String, Object?> _footerJson(TelemetrySessionFooter footer) =>
      <String, Object?>{
        'type': 'footer',
        'endedAtUtc': footer.endedAtUtc.toIso8601String(),
        'terminalReason': footer.terminalReason.wireName,
        'valueCount': footer.valueCount,
        'statusCount': footer.statusCount,
        'gapCount': footer.gapCount,
        'bytesBeforeFooter': footer.bytesBeforeFooter,
      };

  static Map<String, Object?> _object(String line) {
    final decoded = jsonDecode(line);
    if (decoded is! Map<String, dynamic>) {
      throw const TelemetryValidationException('objectRequired');
    }
    return decoded;
  }

  static TelemetrySessionHeader _decodeHeader(Map<String, Object?> map) {
    final schema = _integer(map, 'schemaVersion');
    if (schema != 1) throw const TelemetryValidationException('unknownSchema');
    final rawSignals = map['signals'];
    if (rawSignals is! List<dynamic>) {
      throw const TelemetryValidationException('missingSignals');
    }
    final signals = <FrozenPidDefinition>[];
    for (final raw in rawSignals) {
      if (raw is! Map<String, dynamic>) {
        throw const TelemetryValidationException('invalidSignal');
      }
      final rawDefinition = raw['definition'];
      if (rawDefinition is! Map<String, dynamic>) {
        throw const TelemetryValidationException('invalidDefinition');
      }
      final definition = _decodeDefinition(rawDefinition);
      final frozen = FrozenPidDefinition.freeze(definition);
      if (!_bytesEqual(
        utf8.encode(jsonEncode(rawDefinition)),
        frozen.canonicalBytes,
      )) {
        throw const TelemetryValidationException('nonCanonicalDefinition');
      }
      if (_string(raw, 'fingerprint') != frozen.fingerprint) {
        throw const TelemetryValidationException('fingerprintMismatch');
      }
      signals.add(frozen);
    }
    return TelemetrySessionHeader(
      schemaVersion: schema,
      sessionId: _string(map, 'sessionId'),
      startedAtUtc: _utc(map, 'startedAtUtc'),
      source: _enumValue(TelemetrySource.values, _string(map, 'source')),
      transport: _enumValue(TransportKind.values, _string(map, 'transport')),
      protocol: _string(map, 'protocol'),
      signals: signals,
      configurationFingerprint: _string(map, 'configurationFingerprint'),
    );
  }

  static TelemetrySignalDefinition _decodeDefinition(
    Map<String, Object?> map,
  ) => TelemetrySignalDefinition(
    id: _string(map, 'id'),
    name: _string(map, 'name'),
    shortName: _string(map, 'shortName'),
    request: _string(map, 'request'),
    header: _string(map, 'header'),
    unit: _string(map, 'unit'),
    unitProvenance: _enumValue(
      UnitProvenance.values,
      _string(map, 'unitProvenance'),
    ),
    minimum: _nullableDouble(map, 'minimum'),
    maximum: _nullableDouble(map, 'maximum'),
    isCustom: _boolean(map, 'isCustom'),
    variant: _string(map, 'variant'),
    priority: _integer(map, 'priority'),
    equation: _string(map, 'equation'),
    evidenceKind: map['evidenceKind'] is String
        ? _string(map, 'evidenceKind')
        : null,
  );

  static TelemetryEvent _decodeEvent(Map<String, Object?> map) =>
      switch (map['type']) {
        'value' => TelemetryEvent.value(
          observedAtUtc: _utc(map, 'observedAtUtc'),
          sourceTimestampUtc: _utc(map, 'sourceTimestampUtc'),
          elapsedUs: _integer(map, 'elapsedUs'),
          pidId: _string(map, 'pidId'),
          value: _number(map, 'value'),
          quality: map.containsKey('quality')
              ? _enumValue(TelemetryQuality.values, _string(map, 'quality'))
              : TelemetryQuality.valid,
        ),
        'status' => TelemetryEvent.status(
          observedAtUtc: _utc(map, 'observedAtUtc'),
          elapsedUs: _integer(map, 'elapsedUs'),
          pidId: _string(map, 'pidId'),
          status: _enumValue(TelemetryStatus.values, _string(map, 'status')),
        ),
        _ => throw const TelemetryValidationException('unknownEvent'),
      };

  static TelemetrySessionFooter _decodeFooter(Map<String, Object?> map) =>
      TelemetrySessionFooter(
        endedAtUtc: _utc(map, 'endedAtUtc'),
        terminalReason: _enumValue(
          TelemetryTerminalReason.values,
          _string(map, 'terminalReason'),
        ),
        valueCount: _integer(map, 'valueCount'),
        statusCount: _integer(map, 'statusCount'),
        gapCount: _integer(map, 'gapCount'),
        bytesBeforeFooter: _integer(map, 'bytesBeforeFooter'),
      );
}

String _string(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! String) {
    throw TelemetryValidationException('missingField', field: key);
  }
  return value;
}

int _integer(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! int) {
    throw TelemetryValidationException('missingField', field: key);
  }
  return value;
}

double _number(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! num) {
    throw TelemetryValidationException('missingField', field: key);
  }
  return value.toDouble();
}

double? _nullableDouble(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is! num) {
    throw TelemetryValidationException('missingField', field: key);
  }
  return value.toDouble();
}

bool _boolean(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! bool) {
    throw TelemetryValidationException('missingField', field: key);
  }
  return value;
}

DateTime _utc(Map<String, Object?> map, String key) {
  final raw = _string(map, key);
  final value = DateTime.tryParse(raw);
  if (value == null || !value.isUtc) {
    throw TelemetryValidationException('utcRequired', field: key);
  }
  final utc = value.toUtc();
  // Reject parseable-but-noncanonical forms (overflowed components that
  // DateTime normalizes, missing millis, etc.) the same way share-lease
  // decoding does — otherwise History/replay/export would silently adopt
  // a different timestamp than the bytes on disk.
  if (utc.toIso8601String() != raw) {
    throw TelemetryValidationException('utcRequired', field: key);
  }
  return utc;
}

T _enumValue<T extends Enum>(List<T> values, String name) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw const TelemetryValidationException('unknownEnum');
}

bool _bytesEqual(List<int> first, List<int> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}
