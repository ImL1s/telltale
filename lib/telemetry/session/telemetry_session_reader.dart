library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'telemetry_session.dart';
import 'telemetry_session_codec.dart' as canonical;

/// A random-access source used by the incremental session parser.
abstract interface class TelemetryChunkSource {
  Future<Uint8List> read(int offset, int maximumBytes);
}

final class FileTelemetryChunkSource implements TelemetryChunkSource {
  FileTelemetryChunkSource(this.file);

  final File file;

  @override
  Future<Uint8List> read(int offset, int maximumBytes) async {
    final handle = await file.open();
    try {
      await handle.setPosition(offset);
      return await handle.read(maximumBytes);
    } finally {
      await handle.close();
    }
  }
}

enum TelemetryRecordLineKind { header, value, status, footer }

enum TelemetryReadFailure {
  invalidUtf8,
  invalidJson,
  invalidShape,
  invalidOrder,
  lineTooLong,
  incompleteTail,
  schemaViolation,
}

final class TelemetryDecodedLine {
  const TelemetryDecodedLine({
    required this.kind,
    required this.object,
    required this.encodedBytesIncludingLf,
    required this.byteOffset,
    this.canonicalHeader,
    this.canonicalEvent,
    this.canonicalFooter,
  });

  final TelemetryRecordLineKind kind;
  final Map<String, Object?> object;
  final int encodedBytesIncludingLf;
  final int byteOffset;
  final TelemetrySessionHeader? canonicalHeader;
  final TelemetryEvent? canonicalEvent;
  final TelemetrySessionFooter? canonicalFooter;
}

final class TelemetryReadResult {
  const TelemetryReadResult({
    required this.lines,
    required this.failure,
    required this.droppedIncompleteTail,
    required this.completePrefixBytes,
    required this.valueCount,
    required this.statusCount,
    required this.gapCount,
    required this.footerSeen,
    required this.header,
    required this.footer,
    required this.sessionHeader,
    required this.sessionFooter,
  });

  /// A bounded diagnostic projection. Canonical consumers must use [onLine].
  final List<TelemetryDecodedLine> lines;
  final TelemetryReadFailure? failure;
  final bool droppedIncompleteTail;
  final int completePrefixBytes;
  final int valueCount;
  final int statusCount;
  final int gapCount;
  final bool footerSeen;
  final TelemetryDecodedLine? header;
  final TelemetryDecodedLine? footer;
  final TelemetrySessionHeader? sessionHeader;
  final TelemetrySessionFooter? sessionFooter;

  bool get isValid => failure == null;
}

typedef TelemetryLineVisitor = FutureOr<void> Function(
  TelemetryDecodedLine line,
);

/// Receives one validated encoded line. The view is valid only until the
/// returned future completes and must not be retained by the visitor.
typedef TelemetryEncodedLineVisitor = FutureOr<void> Function(
  Uint8List encodedLineIncludingLf,
);

/// Strict, bounded NDJSON reader.
///
/// It never asks the source for more than 64 KiB and retains at most one
/// schema-bounded line. [lines] is deliberately capped; callers needing every
/// event must consume [onLine] rather than materializing a session.
final class TelemetrySessionReader {
  const TelemetrySessionReader();

  static const chunkBytes = 64 * 1024;
  static const headerLineBytes = 64 * 1024;
  static const eventLineBytes = 2 * 1024;
  static const _diagnosticLineLimit = 64;

  Future<TelemetryReadResult> read(
    TelemetryChunkSource source, {
    bool allowIncompleteTail = false,
    TelemetryLineVisitor? onLine,
    TelemetryEncodedLineVisitor? onEncodedLine,
  }) async {
    var offset = 0;
    var lineOffset = 0;
    var firstLine = true;
    var footerSeen = false;
    var valueCount = 0;
    var statusCount = 0;
    var gapCount = 0;
    var droppedTail = false;
    TelemetryDecodedLine? header;
    TelemetryDecodedLine? footer;
    final availableByPid = <String, bool>{};
    TelemetrySessionHeader? canonicalHeader;
    TelemetrySessionFooter? canonicalFooter;
    var previousElapsedUs = -1;
    final carry = Uint8List(headerLineBytes);
    var carryLength = 0;
    final diagnostic = <TelemetryDecodedLine>[];

    TelemetryReadResult failure(TelemetryReadFailure reason) =>
        TelemetryReadResult(
          lines: List.unmodifiable(diagnostic),
          failure: reason,
          droppedIncompleteTail: false,
          completePrefixBytes: lineOffset,
          valueCount: valueCount,
          statusCount: statusCount,
          gapCount: gapCount,
          footerSeen: footerSeen,
          header: header,
          footer: footer,
          sessionHeader: canonicalHeader,
          sessionFooter: canonicalFooter,
        );

    while (true) {
      final chunk = await source.read(offset, chunkBytes);
      if (chunk.length > chunkBytes) {
        return failure(TelemetryReadFailure.invalidShape);
      }
      if (chunk.isEmpty) break;
      offset += chunk.length;
      for (final byte in chunk) {
        final maximum = firstLine ? headerLineBytes : eventLineBytes;
        if (carryLength >= maximum) {
          return failure(TelemetryReadFailure.lineTooLong);
        }
        carry[carryLength++] = byte;
        if (byte != 0x0A) continue;

        final encodedLine = Uint8List.sublistView(carry, 0, carryLength);

        final parsed = _decodeLine(
          encodedLine,
          firstLine: firstLine,
          footerSeen: footerSeen,
          byteOffset: lineOffset,
          header: canonicalHeader,
          previousElapsedUs: previousElapsedUs,
          valueCount: valueCount,
          statusCount: statusCount,
          gapCount: gapCount,
        );
        if (parsed.failure != null) return failure(parsed.failure!);
        final line = parsed.line!;
        canonicalHeader = line.canonicalHeader ?? canonicalHeader;
        final event = line.canonicalEvent;
        if (event != null) previousElapsedUs = event.elapsedUs;
        canonicalFooter = line.canonicalFooter ?? canonicalFooter;
        await onEncodedLine?.call(encodedLine);
        if (diagnostic.length < _diagnosticLineLimit) diagnostic.add(line);
        await onLine?.call(line);
        switch (line.kind) {
          case TelemetryRecordLineKind.header:
            header = line;
            break;
          case TelemetryRecordLineKind.value:
            valueCount++;
            final pidId = line.object['pidId'];
            if (pidId is String) availableByPid[pidId] = true;
          case TelemetryRecordLineKind.status:
            statusCount++;
            final pidId = line.object['pidId'];
            if (pidId is String) {
              if (availableByPid[pidId] ?? false) gapCount++;
              availableByPid[pidId] = false;
            }
          case TelemetryRecordLineKind.footer:
            footerSeen = true;
            footer = line;
        }
        lineOffset += carryLength;
        carryLength = 0;
        firstLine = false;
      }
    }

    if (carryLength != 0) {
      if (footerSeen) return failure(TelemetryReadFailure.invalidOrder);
      if (!allowIncompleteTail) {
        return failure(TelemetryReadFailure.incompleteTail);
      }
      try {
        utf8.decode(
          Uint8List.sublistView(carry, 0, carryLength),
          allowMalformed: false,
        );
      } on FormatException {
        if (!_hasOnlyTruncatedFinalUtf8Scalar(carry, carryLength)) {
          return failure(TelemetryReadFailure.invalidUtf8);
        }
      }
      droppedTail = true;
    }
    if (firstLine) return failure(TelemetryReadFailure.invalidShape);
    return TelemetryReadResult(
      lines: List.unmodifiable(diagnostic),
      failure: null,
      droppedIncompleteTail: droppedTail,
      completePrefixBytes: lineOffset,
      valueCount: valueCount,
      statusCount: statusCount,
      gapCount: gapCount,
      footerSeen: footerSeen,
      header: header,
      footer: footer,
      sessionHeader: canonicalHeader,
      sessionFooter: canonicalFooter,
    );
  }

  _Decoded _decodeLine(
    Uint8List encoded, {
    required bool firstLine,
    required bool footerSeen,
    required int byteOffset,
    required TelemetrySessionHeader? header,
    required int previousElapsedUs,
    required int valueCount,
    required int statusCount,
    required int gapCount,
  }) {
    late final String text;
    try {
      text = utf8.decode(
        Uint8List.sublistView(encoded, 0, encoded.length - 1),
        allowMalformed: false,
      );
    } on FormatException {
      return const _Decoded.failure(TelemetryReadFailure.invalidUtf8);
    }
    late final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return const _Decoded.failure(TelemetryReadFailure.invalidJson);
    }
    if (decoded is! Map<String, Object?>) {
      return const _Decoded.failure(TelemetryReadFailure.invalidShape);
    }
    final kind = switch (decoded['type']) {
      'header' => TelemetryRecordLineKind.header,
      'value' => TelemetryRecordLineKind.value,
      'status' => TelemetryRecordLineKind.status,
      'footer' => TelemetryRecordLineKind.footer,
      _ => null,
    };
    if (kind == null) {
      return const _Decoded.failure(TelemetryReadFailure.invalidShape);
    }
    if (firstLine) {
      if (kind != TelemetryRecordLineKind.header ||
          decoded['schemaVersion'] != 1) {
        return const _Decoded.failure(TelemetryReadFailure.invalidOrder);
      }
      final id = decoded['sessionId'];
      if (id is! String || !TelemetrySessionReader.isOpaqueId(id)) {
        return const _Decoded.failure(TelemetryReadFailure.invalidShape);
      }
    } else if (kind == TelemetryRecordLineKind.header || footerSeen) {
      return const _Decoded.failure(TelemetryReadFailure.invalidOrder);
    }
    TelemetrySessionHeader? canonicalHeader;
    TelemetryEvent? canonicalEvent;
    TelemetrySessionFooter? canonicalFooter;
    switch (kind) {
      case TelemetryRecordLineKind.header:
        final result = canonical.TelemetrySessionCodec.decodeHeaderObject(
          decoded,
        );
        canonicalHeader = result.value;
        if (canonicalHeader == null) {
          return const _Decoded.failure(TelemetryReadFailure.schemaViolation);
        }
      case TelemetryRecordLineKind.value:
      case TelemetryRecordLineKind.status:
        if (header == null) {
          return const _Decoded.failure(TelemetryReadFailure.invalidOrder);
        }
        final result = canonical.TelemetrySessionCodec.decodeEventObject(
          decoded,
          header,
          previousElapsedUs,
        );
        canonicalEvent = result.value;
        if (canonicalEvent == null) {
          return const _Decoded.failure(TelemetryReadFailure.schemaViolation);
        }
      case TelemetryRecordLineKind.footer:
        final result = canonical.TelemetrySessionCodec.decodeFooterObject(
          decoded,
          valueCount,
          statusCount,
          gapCount,
          byteOffset,
        );
        canonicalFooter = result.value;
        if (canonicalFooter == null) {
          return const _Decoded.failure(TelemetryReadFailure.schemaViolation);
        }
        // Producers clamp endedAtUtc ≥ startedAtUtc; reject on-disk regressions
        // / corruption that would otherwise present a negative duration.
        if (header != null &&
            canonicalFooter.endedAtUtc.isBefore(header.startedAtUtc)) {
          return const _Decoded.failure(TelemetryReadFailure.schemaViolation);
        }
    }
    return _Decoded.line(
      TelemetryDecodedLine(
        kind: kind,
        object: Map.unmodifiable(decoded),
        encodedBytesIncludingLf: encoded.length,
        byteOffset: byteOffset,
        canonicalHeader: canonicalHeader,
        canonicalEvent: canonicalEvent,
        canonicalFooter: canonicalFooter,
      ),
    );
  }

  static bool isOpaqueId(String value) {
    return RegExp(r'^[0-9a-f]{32}$').hasMatch(value);
  }

  static bool _hasOnlyTruncatedFinalUtf8Scalar(Uint8List bytes, int length) {
    var index = 0;
    while (index < length) {
      final lead = bytes[index];
      if (lead <= 0x7F) {
        index++;
        continue;
      }
      final scalarLength = switch (lead) {
        >= 0xC2 && <= 0xDF => 2,
        >= 0xE0 && <= 0xEF => 3,
        >= 0xF0 && <= 0xF4 => 4,
        _ => 0,
      };
      if (scalarLength == 0) return false;
      final available = length - index;
      final continuationCount = available < scalarLength
          ? available - 1
          : scalarLength - 1;
      for (var offset = 1; offset <= continuationCount; offset++) {
        final continuation = bytes[index + offset];
        if (continuation < 0x80 || continuation > 0xBF) return false;
        if (offset == 1) {
          if (lead == 0xE0 && continuation < 0xA0) return false;
          if (lead == 0xED && continuation > 0x9F) return false;
          if (lead == 0xF0 && continuation < 0x90) return false;
          if (lead == 0xF4 && continuation > 0x8F) return false;
        }
      }
      if (available < scalarLength) return true;
      index += scalarLength;
    }
    return false;
  }
}

final class _Decoded {
  const _Decoded.line(this.line) : failure = null;
  const _Decoded.failure(this.failure) : line = null;

  final TelemetryDecodedLine? line;
  final TelemetryReadFailure? failure;
}
