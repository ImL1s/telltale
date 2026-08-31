library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

abstract interface class TelemetryAppendSink {
  Future<void> append(List<int> chunk);
  Future<void> flush();
  Future<void> close();
}

final class FileTelemetryAppendSink implements TelemetryAppendSink {
  FileTelemetryAppendSink(this._handle);

  final RandomAccessFile _handle;

  @override
  Future<void> append(List<int> chunk) => _handle.writeFrom(chunk);

  @override
  Future<void> flush() => _handle.flush();

  @override
  Future<void> close() => _handle.close();
}

enum TelemetryAppendResult {
  accepted,
  lineTooLarge,
  storageBackpressure,
  sessionSizeLimit,
  librarySizeLimit,
  closed,
}

final class TelemetryWriterException implements Exception {
  const TelemetryWriterException(this.operation, this.cause);

  final String operation;
  final Object cause;

  @override
  String toString() => 'TelemetryWriterException($operation, $cause)';
}

/// Non-blocking two-buffer session writer.
///
/// The writer owns two fixed 64 KiB byte arrays. One is active and one may be
/// held by the single append Future. No queue exists: if both are occupied and
/// the next complete line cannot fit, acceptance closes synchronously.
final class TelemetrySessionWriter {
  TelemetrySessionWriter({
    required this.sink,
    int bytesAlreadyWritten = 0,
    this.effectiveSessionLimit = 25 * 1024 * 1024,
    this.sessionLimitIsLibraryBound = false,
  }) : _bytesBeforeFooter = bytesAlreadyWritten,
       assert(effectiveSessionLimit > 0);

  static const bufferBytes = 64 * 1024;

  final TelemetryAppendSink sink;
  final int effectiveSessionLimit;
  final bool sessionLimitIsLibraryBound;
  Uint8List _active = Uint8List(bufferBytes);
  Uint8List _spare = Uint8List(bufferBytes);
  int _activeLength = 0;
  int _inFlightLength = 0;
  Future<void>? _inFlight;
  Object? _inFlightError;
  void Function()? _appendFailureHandler;
  bool _accepting = true;
  bool _closeSucceeded = false;
  int _bytesBeforeFooter;

  bool get isAccepting => _accepting;
  int get activeBytes => _activeLength;
  int get inFlightBytes => _inFlightLength;
  int get pendingBytes => activeBytes + inFlightBytes;
  int get bytesBeforeFooter => _bytesBeforeFooter;
  bool get closeSucceeded => _closeSucceeded;

  void setAppendFailureHandler(void Function()? handler) {
    _appendFailureHandler = handler;
  }

  TelemetryAppendResult tryAppendLine(List<int> encodedLine) {
    if (!_accepting) return TelemetryAppendResult.closed;
    if (encodedLine.isEmpty ||
        encodedLine.last != 0x0A ||
        encodedLine.length > bufferBytes) {
      return TelemetryAppendResult.lineTooLarge;
    }
    if (_bytesBeforeFooter + encodedLine.length + 2048 >
        effectiveSessionLimit) {
      _accepting = false;
      return sessionLimitIsLibraryBound
          ? TelemetryAppendResult.librarySizeLimit
          : TelemetryAppendResult.sessionSizeLimit;
    }
    if (_activeLength + encodedLine.length > bufferBytes) {
      if (_inFlight != null) {
        _accepting = false;
        return TelemetryAppendResult.storageBackpressure;
      }
      flushActive();
      if (!_accepting) return TelemetryAppendResult.closed;
    }
    _active.setRange(
      _activeLength,
      _activeLength + encodedLine.length,
      encodedLine,
    );
    _activeLength += encodedLine.length;
    _bytesBeforeFooter += encodedLine.length;
    if (_activeLength == bufferBytes && _inFlight == null) {
      flushActive();
      if (!_accepting) {
        _bytesBeforeFooter -= encodedLine.length;
        return TelemetryAppendResult.closed;
      }
    }
    return TelemetryAppendResult.accepted;
  }

  /// Starts the one permitted append without awaiting it.
  void flushActive() {
    if (_activeLength == 0 || _inFlight != null) return;
    final outgoing = _active;
    final outgoingLength = _activeLength;
    _active = _spare;
    _spare = outgoing;
    _activeLength = 0;
    _inFlightLength = outgoingLength;
    late final Future<void> operation;
    try {
      operation = sink.append(
        Uint8List.sublistView(outgoing, 0, outgoingLength),
      );
    } on Object catch (error) {
      _inFlightLength = 0;
      _recordAppendFailure(error);
      return;
    }
    _inFlight = operation.then<void>(
      (_) {
        _inFlight = null;
        _inFlightLength = 0;
      },
      onError: (Object error, StackTrace _) {
        _inFlight = null;
        _inFlightLength = 0;
        _recordAppendFailure(error);
      },
    );
  }

  Future<void> finalize({required List<int> footerLine}) async {
    _accepting = false;
    if (footerLine.isEmpty ||
        footerLine.last != 0x0A ||
        footerLine.length > 2048 ||
        _bytesBeforeFooter + footerLine.length > effectiveSessionLimit) {
      throw TelemetryWriterException(
        'footer',
        StateError('footer exceeds its reserved bytes'),
      );
    }
    Object? failure;
    StackTrace? failureStack;
    try {
      final pending = _inFlight;
      if (pending != null) await pending;
      _throwPriorAppendFailure();
      if (_activeLength != 0) {
        await sink.append(Uint8List.sublistView(_active, 0, _activeLength));
        _activeLength = 0;
      }
      await sink.append(footerLine);
      await sink.flush();
    } on Object catch (error, stackTrace) {
      failure = error;
      failureStack = stackTrace;
    }
    try {
      await sink.close();
      _closeSucceeded = true;
    } on Object catch (error) {
      throw TelemetryWriterException('close', error);
    }
    if (failure != null) {
      Error.throwWithStackTrace(
        failure is TelemetryWriterException
            ? failure
            : TelemetryWriterException('finalize', failure),
        failureStack!,
      );
    }
  }

  /// Closes a staging session without writing buffered event bytes or a footer.
  ///
  /// Start-abort and zero-value cleanup delete the staging file immediately
  /// afterwards. Dropping the active buffer is intentional: an aborted
  /// artifact must never be made parseable or installed.
  Future<void> closeForAbort() async {
    _accepting = false;
    try {
      final pending = _inFlight;
      if (pending != null) await pending;
      _throwPriorAppendFailure();
      _activeLength = 0;
      await sink.close();
      _closeSucceeded = true;
    } on TelemetryWriterException {
      rethrow;
    } on Object catch (error) {
      throw TelemetryWriterException('abort', error);
    }
  }

  void _throwPriorAppendFailure() {
    final error = _inFlightError;
    if (error != null) throw TelemetryWriterException('append', error);
  }

  void _recordAppendFailure(Object error) {
    if (_inFlightError != null) return;
    _inFlightError = error;
    _accepting = false;
    _appendFailureHandler?.call();
  }
}
