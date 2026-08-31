library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:csv/csv.dart';

import '../../core/hash/fnv1a64.dart';
import 'telemetry_export_codec.dart';
import 'telemetry_session.dart';
import 'telemetry_session_codec.dart';
import 'telemetry_session_reader.dart';

final class TelemetryExportException implements Exception {
  const TelemetryExportException(this.code, {this.detail, this.remoteStack});

  final String code;
  final String? detail;
  final String? remoteStack;

  @override
  String toString() => 'TelemetryExportException($code)';
}

final class TelemetryExportBufferUsage {
  const TelemetryExportBufferUsage({
    required this.inputBytes,
    required this.transformBytes,
    required this.outputBytes,
  });

  final int inputBytes;
  final int transformBytes;
  final int outputBytes;

  int get totalBytes => inputBytes + transformBytes + outputBytes;
}

typedef TelemetryExportBufferObserver = void Function(
  TelemetryExportBufferUsage usage,
);

/// Validates and transforms a canonical telemetry session without retaining
/// its event list or the complete exported artifact.
///
/// Every export performs a full validation pass before emitting bytes, then a
/// second validated pass. A semantic source hash prevents a changed second
/// pass from being reported as successful. The returned stream is a
/// one-output-chunk rendezvous, so a slow consumer cannot create an unbounded
/// queue. Its methods can be passed directly as an `AppShareRequest`
/// `streamFactory` without importing the share layer here.
final class TelemetrySessionExporter {
  TelemetrySessionExporter({this.onBufferUsage, TelemetrySessionReader? reader})
    : _reader = reader ?? const TelemetrySessionReader();

  static const maximumInputBytes = TelemetrySessionReader.chunkBytes;
  static const maximumTransformBytes = 64 * 1024;
  static const maximumOutputChunkBytes = 64 * 1024;

  final TelemetrySessionReader _reader;
  final TelemetryExportBufferObserver? onBufferUsage;

  Stream<List<int>> Function() csvStreamFactory(TelemetryChunkSource source) =>
      () => csvStream(source);

  Stream<List<int>> Function() jsonStreamFactory(TelemetryChunkSource source) =>
      () => jsonStream(source);

  Stream<List<int>> csvStream(TelemetryChunkSource source) =>
      _export(source, _ExportFormat.csv);

  Stream<List<int>> jsonStream(TelemetryChunkSource source) =>
      _export(source, _ExportFormat.json);

  Stream<List<int>> _export(
    TelemetryChunkSource source,
    _ExportFormat format,
  ) async* {
    final trusted = await _scan(source);
    final channel = _RendezvousChannel<List<int>>();
    final producer = _produce(source, trusted, format, channel).then<void>(
      (_) => channel.close(),
      onError: (Object error, StackTrace stackTrace) {
        channel.closeError(error, stackTrace);
      },
    );
    _RendezvousMessage<List<int>>? previous;
    try {
      while (true) {
        previous?.accepted.complete();
        previous = null;
        final message = await channel.take();
        if (message.error case final error?) {
          Error.throwWithStackTrace(error, message.stackTrace!);
        }
        if (message.isDone) break;
        previous = message;
        yield message.value!;
      }
      await producer;
    } finally {
      previous?.accepted.complete();
      channel.cancel();
      try {
        await producer;
      } on Object {
        // The stream already delivered the producer error, or cancellation
        // intentionally interrupted a pending rendezvous.
      }
    }
  }

  Future<_TrustedScan> _scan(TelemetryChunkSource source) async {
    final hash = Fnv1a64();
    final result = await _reader.read(source, onEncodedLine: hash.add);
    final header = result.sessionHeader;
    final footer = result.sessionFooter;
    if (!result.isValid ||
        !result.footerSeen ||
        header == null ||
        footer == null) {
      throw TelemetryExportException(result.failure?.name ?? 'missingFooter');
    }
    return _TrustedScan(
      header: header,
      footer: footer,
      hash: hash.hex,
      completePrefixBytes: result.completePrefixBytes,
      valueCount: result.valueCount,
      statusCount: result.statusCount,
      gapCount: result.gapCount,
    );
  }

  Future<void> _produce(
    TelemetryChunkSource source,
    _TrustedScan trusted,
    _ExportFormat format,
    _RendezvousChannel<List<int>> channel,
  ) async {
    final hash = Fnv1a64();
    var firstJsonEvent = true;
    final definitions = <String, TelemetrySignalDefinition>{
      for (final signal in trusted.header.signals)
        signal.definition.id: signal.definition,
    };

    if (format == _ExportFormat.csv) {
      for (final chunk in _csvPreamble(trusted.header, trusted.footer)) {
        await _emit(channel, chunk);
      }
    } else {
      await _emit(channel, _jsonPreambleStart());
      await _emit(
        channel,
        _withoutLf(TelemetrySessionCodec.encodeHeaderLine(trusted.header)),
      );
      await _emit(channel, Uint8List.fromList(utf8.encode(',"events":[')));
    }

    final result = await _reader.read(
      source,
      onEncodedLine: hash.add,
      onLine: (line) async {
        if (line.kind != TelemetryRecordLineKind.value &&
            line.kind != TelemetryRecordLineKind.status) {
          return;
        }
        final event = line.canonicalEvent;
        if (event == null) {
          throw const TelemetryExportException('invalidEvent');
        }
        if (format == _ExportFormat.csv) {
          final definition = definitions[event.pidId];
          if (definition == null) {
            throw const TelemetryExportException('unknownPid');
          }
          await _emit(channel, _csvEvent(event, definition));
        } else {
          if (!firstJsonEvent) {
            await _emit(channel, Uint8List.fromList(const [0x2c]));
          }
          firstJsonEvent = false;
          await _emit(
            channel,
            _withoutLf(TelemetrySessionCodec.encodeEventLine(event)),
          );
        }
      },
    );
    if (!result.isValid || !result.footerSeen) {
      throw TelemetryExportException(result.failure?.name ?? 'missingFooter');
    }
    if (hash.hex != trusted.hash ||
        result.completePrefixBytes != trusted.completePrefixBytes ||
        result.valueCount != trusted.valueCount ||
        result.statusCount != trusted.statusCount ||
        result.gapCount != trusted.gapCount ||
        result.sessionHeader?.configurationFingerprint !=
            trusted.header.configurationFingerprint ||
        !_sameFooter(result.sessionFooter, trusted.footer)) {
      throw const TelemetryExportException('sourceChanged');
    }
    if (format == _ExportFormat.json) {
      await _emit(channel, _jsonFooter(trusted.footer));
    }
  }

  Future<void> _emit(
    _RendezvousChannel<List<int>> channel,
    Uint8List bytes,
  ) async {
    if (bytes.length > maximumOutputChunkBytes) {
      throw const TelemetryExportException('outputChunkTooLarge');
    }
    onBufferUsage?.call(
      TelemetryExportBufferUsage(
        inputBytes: maximumInputBytes,
        transformBytes: bytes.length.clamp(0, maximumTransformBytes),
        outputBytes: bytes.length,
      ),
    );
    await channel.add(bytes);
  }
}

enum _ExportFormat { csv, json }

final class _TrustedScan {
  const _TrustedScan({
    required this.header,
    required this.footer,
    required this.hash,
    required this.completePrefixBytes,
    required this.valueCount,
    required this.statusCount,
    required this.gapCount,
  });

  final TelemetrySessionHeader header;
  final TelemetrySessionFooter footer;
  final String hash;
  final int completePrefixBytes;
  final int valueCount;
  final int statusCount;
  final int gapCount;
}

final Csv _csv = Csv(lineDelimiter: '\r\n');

Iterable<Uint8List> _csvPreamble(
  TelemetrySessionHeader header,
  TelemetrySessionFooter footer,
) sync* {
  final metadata = <String>[
    '# telltale_telemetry_csv_version=1',
    '# source=${header.source.wireName}',
    '# transport=${header.transport.name}',
    '# protocol=${_safeMetadata(header.protocol)}',
    '# started_at_utc=${header.startedAtUtc.toIso8601String()}',
    '# ended_at_utc=${footer.endedAtUtc.toIso8601String()}',
    '# terminal_reason=${footer.terminalReason.wireName}',
    '# value_count=${footer.valueCount}',
    '# status_count=${footer.statusCount}',
    '# gap_count=${footer.gapCount}',
    '# preview=預覽已抽樣；匯出保留完整已記錄事件',
    '# privacy_exclusions=VIN;GPS;account;vehicle_profile;adapter_address;raw_diagnostic_traffic',
    '# json_disclosure=JSON may include user-authored PID labels, units, equations, and full frozen definitions',
    for (final signal in header.signals)
      '# frozen_definition=${_safeMetadata(signal.definition.id)}:${signal.fingerprint}',
  ];
  for (final line in metadata) {
    yield Uint8List.fromList(utf8.encode('$line\r\n'));
  }
  yield Uint8List.fromList(
    utf8.encode('${_csv.encode([TelemetryExportCodec.csvColumns])}\r\n'),
  );
}

Uint8List _csvEvent(
  TelemetryEvent event,
  TelemetrySignalDefinition definition,
) {
  final row = _csv.encode([
    <Object?>[
      event.observedAtUtc.toIso8601String(),
      event.kind == TelemetryEventKind.value
          ? event.sourceTimestampUtc!.toIso8601String()
          : '',
      event.elapsedUs / 1000,
      TelemetryExportCodec.protectCsvCell(definition.id),
      TelemetryExportCodec.protectCsvCell(definition.name),
      event.kind.name,
      event.kind == TelemetryEventKind.value ? event.value : '',
      event.kind == TelemetryEventKind.value
          ? TelemetryExportCodec.protectCsvCell(definition.unit)
          : '',
      event.kind == TelemetryEventKind.status ? event.status!.wireName : '',
    ],
  ]);
  return Uint8List.fromList(utf8.encode('$row\r\n'));
}

Uint8List _jsonPreambleStart() {
  final preamble = <String, Object?>{
    'exportVersion': 1,
    'privacyExclusions': const <String>[
      'VIN',
      'GPS',
      'account',
      'vehicleProfile',
      'adapterAddress',
      'rawDiagnosticTraffic',
    ],
    'disclosure': 'fullFrozenDefinitions may contain user-authored labels, units, and equations',
  };
  final encoded = jsonEncode(preamble);
  return Uint8List.fromList(
    utf8.encode('${encoded.substring(0, encoded.length - 1)},"header":'),
  );
}

Uint8List _jsonFooter(TelemetrySessionFooter footer) => Uint8List.fromList([
  ...utf8.encode('],"footer":'),
  ..._withoutLf(TelemetrySessionCodec.encodeFooterLine(footer)),
  0x7d,
]);

Uint8List _withoutLf(Uint8List line) =>
    Uint8List.sublistView(line, 0, line.length - 1);

String _safeMetadata(String value) => TelemetryExportCodec.protectCsvCell(
  value.replaceAll('\r', ' ').replaceAll('\n', ' '),
);

bool _sameFooter(
  TelemetrySessionFooter? first,
  TelemetrySessionFooter second,
) =>
    first != null &&
    first.endedAtUtc == second.endedAtUtc &&
    first.terminalReason == second.terminalReason &&
    first.valueCount == second.valueCount &&
    first.statusCount == second.statusCount &&
    first.gapCount == second.gapCount &&
    first.bytesBeforeFooter == second.bytesBeforeFooter;

final class _RendezvousMessage<T> {
  _RendezvousMessage.value(this.value)
    : error = null,
      stackTrace = null,
      isDone = false;
  _RendezvousMessage.done()
    : value = null,
      error = null,
      stackTrace = null,
      isDone = true;
  _RendezvousMessage.error(this.error, this.stackTrace)
    : value = null,
      isDone = false;

  final T? value;
  final Object? error;
  final StackTrace? stackTrace;
  final bool isDone;
  final accepted = Completer<void>();
}

final class _RendezvousChannel<T> {
  _RendezvousMessage<T>? _pending;
  Completer<_RendezvousMessage<T>>? _waiting;
  bool _cancelled = false;

  Future<void> add(T value) async {
    if (_cancelled) throw const TelemetryExportException('cancelled');
    final message = _RendezvousMessage<T>.value(value);
    _put(message);
    await message.accepted.future;
    if (_cancelled) throw const TelemetryExportException('cancelled');
  }

  void close() => _put(_RendezvousMessage<T>.done());

  void closeError(Object error, StackTrace stackTrace) =>
      _put(_RendezvousMessage<T>.error(error, stackTrace));

  Future<_RendezvousMessage<T>> take() {
    final pending = _pending;
    if (pending != null) {
      _pending = null;
      return Future.value(pending);
    }
    final waiting = Completer<_RendezvousMessage<T>>();
    _waiting = waiting;
    return waiting.future;
  }

  void cancel() {
    _cancelled = true;
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.accepted.isCompleted) {
      pending.accepted.complete();
    }
    final waiting = _waiting;
    _waiting = null;
    if (waiting != null && !waiting.isCompleted) {
      waiting.complete(_RendezvousMessage<T>.done());
    }
  }

  void _put(_RendezvousMessage<T> message) {
    if (_cancelled) {
      if (!message.accepted.isCompleted) message.accepted.complete();
      return;
    }
    final waiting = _waiting;
    if (waiting != null) {
      _waiting = null;
      waiting.complete(message);
      return;
    }
    if (_pending != null) {
      throw StateError('Only one telemetry export chunk may be in flight.');
    }
    _pending = message;
  }
}
