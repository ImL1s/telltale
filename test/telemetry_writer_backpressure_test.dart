import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_writer.dart';

void main() {
  test(
    'checkpointPartial appends a short active buffer before 64 KiB overflow',
    () async {
      final sink = _ControlledSink()..holdAppends = false;
      final writer = TelemetrySessionWriter(sink: sink);
      expect(
        writer.tryAppendLine(utf8.encode('event\n')),
        TelemetryAppendResult.accepted,
      );
      expect(sink.bytes, isEmpty);
      expect(writer.activeBytes, utf8.encode('event\n').length);

      await writer.checkpointPartial();

      expect(utf8.decode(sink.bytes), 'event\n');
      expect(writer.activeBytes, 0);
      expect(sink.calls, <String>['append', 'flush']);
    },
  );

  test(
    'checkpointPartial is a no-op when the active buffer is empty',
    () async {
      final sink = _ControlledSink()..holdAppends = false;
      final writer = TelemetrySessionWriter(sink: sink);
      await writer.checkpointPartial();
      expect(sink.calls, isEmpty);
      expect(sink.bytes, isEmpty);
    },
  );

  test('uses one active and one in-flight 64 KiB buffer only', () async {
    final sink = _ControlledSink();
    final writer = TelemetrySessionWriter(sink: sink);
    final line = utf8.encode('${'x' * 2047}\n');

    for (var i = 0; i < 32; i++) {
      expect(writer.tryAppendLine(line), TelemetryAppendResult.accepted);
    }
    expect(writer.inFlightBytes, 64 * 1024);
    for (var i = 0; i < 32; i++) {
      expect(writer.tryAppendLine(line), TelemetryAppendResult.accepted);
    }

    expect(writer.pendingBytes, 128 * 1024);
    expect(
      writer.tryAppendLine(utf8.encode('{}\n')),
      TelemetryAppendResult.storageBackpressure,
    );
    expect(writer.isAccepting, isFalse);
    expect(sink.maximumConcurrentAppends, 1);
  });

  test(
    'delayed sink preserves order without duplicate or lost bytes',
    () async {
      final sink = _ControlledSink();
      final writer = TelemetrySessionWriter(sink: sink);
      expect(
        writer.tryAppendLine(utf8.encode('one\n')),
        TelemetryAppendResult.accepted,
      );
      writer.flushActive();
      expect(
        writer.tryAppendLine(utf8.encode('two\n')),
        TelemetryAppendResult.accepted,
      );
      sink.completeNext();
      await writer.finalize(footerLine: utf8.encode('footer\n'));

      expect(utf8.decode(sink.bytes), 'one\ntwo\nfooter\n');
      expect(sink.calls, <String>[
        'append',
        'append',
        'append',
        'flush',
        'close',
      ]);
      expect(sink.maximumConcurrentAppends, 1);
    },
  );

  test(
    'sink failure preserves staging responsibility and does not close',
    () async {
      final sink = _ControlledSink()..failNext = true;
      final writer = TelemetrySessionWriter(sink: sink);
      writer.tryAppendLine(utf8.encode('header\n'));
      writer.flushActive();

      await expectLater(
        writer.finalize(footerLine: utf8.encode('footer\n')),
        throwsA(isA<TelemetryWriterException>()),
      );
      expect(sink.calls, <String>['append', 'close']);
      expect(writer.closeSucceeded, isTrue);
    },
  );

  test('async append failure notifies exactly once without escaping', () async {
    final sink = _ControlledSink()..failNext = true;
    final writer = TelemetrySessionWriter(sink: sink);
    var notifications = 0;
    writer.setAppendFailureHandler(() => notifications++);

    expect(
      writer.tryAppendLine(utf8.encode('event\n')),
      TelemetryAppendResult.accepted,
    );
    writer.flushActive();
    await Future<void>.delayed(Duration.zero);

    expect(notifications, 1);
    expect(writer.isAccepting, isFalse);
    await expectLater(
      writer.finalize(footerLine: utf8.encode('footer\n')),
      throwsA(isA<TelemetryWriterException>()),
    );
    expect(notifications, 1);
  });

  test('synchronous append throw does not copy the triggering line', () {
    final writer = TelemetrySessionWriter(sink: _SynchronousThrowSink());
    final nearlyFull = utf8.encode(
      '${'x' * (TelemetrySessionWriter.bufferBytes - 2)}\n',
    );
    expect(writer.tryAppendLine(nearlyFull), TelemetryAppendResult.accepted);
    final bytesBeforeFailure = writer.bytesBeforeFooter;

    expect(
      writer.tryAppendLine(utf8.encode('next\n')),
      TelemetryAppendResult.closed,
    );
    expect(writer.bytesBeforeFooter, bytesBeforeFailure);
    expect(writer.activeBytes, 0);
    expect(writer.inFlightBytes, 0);
    expect(writer.isAccepting, isFalse);
  });

  test('exact-fill synchronous append throw rejects the filled line', () {
    final writer = TelemetrySessionWriter(sink: _SynchronousThrowSink());
    var notifications = 0;
    writer.setAppendFailureHandler(() => notifications++);
    final exactBuffer = utf8.encode(
      '${'x' * (TelemetrySessionWriter.bufferBytes - 1)}\n',
    );

    expect(writer.tryAppendLine(exactBuffer), TelemetryAppendResult.closed);
    expect(notifications, 1);
    expect(writer.bytesBeforeFooter, 0);
    expect(writer.activeBytes, 0);
    expect(writer.inFlightBytes, 0);
    expect(writer.isAccepting, isFalse);
  });

  for (final failureAt in const <String>[
    'activeAppend',
    'footerAppend',
    'flush',
  ]) {
    test('$failureAt failure still proves sink close', () async {
      final sink = _PointFailureSink(failureAt);
      final writer = TelemetrySessionWriter(sink: sink);
      expect(
        writer.tryAppendLine(utf8.encode('event\n')),
        TelemetryAppendResult.accepted,
      );

      await expectLater(
        writer.finalize(footerLine: utf8.encode('footer\n')),
        throwsA(isA<TelemetryWriterException>()),
      );

      expect(sink.calls.last, 'close');
      expect(writer.closeSucceeded, isTrue);
    });
  }

  test('close failure is not reported as contained', () async {
    final sink = _PointFailureSink('close');
    final writer = TelemetrySessionWriter(sink: sink);
    writer.tryAppendLine(utf8.encode('event\n'));

    await expectLater(
      writer.finalize(footerLine: utf8.encode('footer\n')),
      throwsA(
        isA<TelemetryWriterException>().having(
          (error) => error.operation,
          'operation',
          'close',
        ),
      ),
    );
    expect(writer.closeSucceeded, isFalse);
  });

  test('never-completing close never produces a contained result', () async {
    final sink = _PointFailureSink('neverClose');
    final writer = TelemetrySessionWriter(sink: sink);
    writer.tryAppendLine(utf8.encode('event\n'));

    final future = writer.finalize(footerLine: utf8.encode('footer\n'));

    expect(await _completesSoon(future), isFalse);
    expect(writer.closeSucceeded, isFalse);
  });

  test('reserves footer bytes before accepting each complete line', () {
    final sessionBound = TelemetrySessionWriter(
      sink: _ControlledSink(),
      bytesAlreadyWritten: 100,
      effectiveSessionLimit: 2151,
    );
    expect(
      sessionBound.tryAppendLine(utf8.encode('abc\n')),
      TelemetryAppendResult.sessionSizeLimit,
    );
    expect(sessionBound.bytesBeforeFooter, 100);

    final libraryBound = TelemetrySessionWriter(
      sink: _ControlledSink(),
      bytesAlreadyWritten: 100,
      effectiveSessionLimit: 2151,
      sessionLimitIsLibraryBound: true,
    );
    expect(
      libraryBound.tryAppendLine(utf8.encode('abc\n')),
      TelemetryAppendResult.librarySizeLimit,
    );
  });
}

Future<bool> _completesSoon(Future<Object?> future) async {
  final marker = Object();
  return !identical(
    await Future.any<Object?>(<Future<Object?>>[
      future,
      Future<Object?>.delayed(const Duration(milliseconds: 20), () => marker),
    ]),
    marker,
  );
}

final class _PointFailureSink implements TelemetryAppendSink {
  _PointFailureSink(this.failureAt);

  final String failureAt;
  final List<String> calls = <String>[];
  int appendCalls = 0;

  @override
  Future<void> append(List<int> chunk) async {
    calls.add('append');
    appendCalls++;
    if (failureAt == 'activeAppend' && appendCalls == 1) {
      throw StateError('active append');
    }
    if (failureAt == 'footerAppend' && appendCalls == 2) {
      throw StateError('footer append');
    }
  }

  @override
  Future<void> flush() async {
    calls.add('flush');
    if (failureAt == 'flush') throw StateError('flush');
  }

  @override
  Future<void> close() {
    calls.add('close');
    if (failureAt == 'close') return Future<void>.error(StateError('close'));
    if (failureAt == 'neverClose') return Completer<void>().future;
    return Future<void>.value();
  }
}

final class _SynchronousThrowSink implements TelemetryAppendSink {
  @override
  Future<void> append(List<int> chunk) => throw StateError('sync append');

  @override
  Future<void> close() async {}

  @override
  Future<void> flush() async {}
}

final class _ControlledSink implements TelemetryAppendSink {
  final List<int> bytes = <int>[];
  final List<String> calls = <String>[];
  final List<Completer<void>> _pending = <Completer<void>>[];
  var activeAppends = 0;
  var maximumConcurrentAppends = 0;
  var failNext = false;
  var holdAppends = true;

  @override
  Future<void> append(List<int> chunk) {
    calls.add('append');
    activeAppends++;
    maximumConcurrentAppends = activeAppends > maximumConcurrentAppends
        ? activeAppends
        : maximumConcurrentAppends;
    if (failNext) {
      failNext = false;
      activeAppends--;
      return Future<void>.error(StateError('append failed'));
    }
    if (!holdAppends) {
      bytes.addAll(chunk);
      activeAppends--;
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _pending.add(completer);
    return completer.future.then((_) {
      bytes.addAll(chunk);
      activeAppends--;
    });
  }

  void completeNext() {
    holdAppends = false;
    _pending.removeAt(0).complete();
  }

  @override
  Future<void> flush() async => calls.add('flush');

  @override
  Future<void> close() async => calls.add('close');
}
