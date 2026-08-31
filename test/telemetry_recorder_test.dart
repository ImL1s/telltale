import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/telemetry.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/telemetry/session/telemetry_recorder.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';

TelemetrySessionHeader _header(DateTime now) => TelemetrySessionHeader(
  sessionId: '0123456789abcdef0123456789abcdef',
  startedAtUtc: now,
  source: TelemetrySource.demo,
  transport: TransportKind.demo,
  protocol: 'AUTO, CAN 11/500',
  signals: [freezePidDefinition(PidLibrary.engineRpm)],
);

Reading _rpm(double value, DateTime timestamp, {String? equation}) => Reading(
  pid: equation == null
      ? PidLibrary.engineRpm
      : PidLibrary.engineRpm.copyWith(equation: equation),
  value: value,
  rawBytes: const [0x1a, 0xf8],
  timestamp: timestamp,
);

void main() {
  late DateTime wall;
  late int elapsed;
  late TelemetryRecorder recorder;
  late List<TelemetryEvent> emitted;

  setUp(() {
    wall = DateTime.utc(2026, 8, 30, 1);
    elapsed = 0;
    emitted = <TelemetryEvent>[];
    recorder = TelemetryRecorder(
      utcNow: () => wall,
      elapsedUs: () => elapsed,
      onEvent: emitted.add,
    );
  });

  test('normal state sequence is explicit and retains truthful counts', () {
    final phases = <TelemetryRecorderPhase>[];
    phases.add(recorder.state.phase);
    expect(recorder.prepare(_header(wall)), isTrue);
    phases.add(recorder.state.phase);
    expect(recorder.openAcceptance(), isTrue);
    phases.add(recorder.state.phase);

    recorder.ingest(
      TelemetrySnapshot(
        readings: {PidLibrary.engineRpm.id: _rpm(1726, wall)},
        capturedAt: wall,
      ),
    );
    recorder.stop();
    phases.add(recorder.state.phase);
    final footer = recorder.complete(bytesBeforeFooter: 321);
    phases.add(recorder.state.phase);

    expect(phases, [
      TelemetryRecorderPhase.idle,
      TelemetryRecorderPhase.preparing,
      TelemetryRecorderPhase.recording,
      TelemetryRecorderPhase.finalizing,
      TelemetryRecorderPhase.completed,
    ]);
    expect(footer.terminalReason, TelemetryTerminalReason.user);
    expect(footer.valueCount, 1);
    expect(footer.statusCount, 0);
    expect(footer.gapCount, 0);
  });

  test('pre-start values are ignored and heartbeat duplicates deduplicate', () {
    final readingAt = wall;
    recorder.ingest(
      TelemetrySnapshot(
        readings: {PidLibrary.engineRpm.id: _rpm(1000, readingAt)},
        capturedAt: wall,
      ),
    );
    recorder.prepare(_header(wall));
    recorder.openAcceptance();

    recorder.ingest(
      TelemetrySnapshot(
        readings: {PidLibrary.engineRpm.id: _rpm(1000, readingAt)},
        capturedAt: wall,
      ),
    );
    wall = wall.add(const Duration(milliseconds: 10));
    elapsed += 10000;
    recorder.ingest(
      TelemetrySnapshot(
        readings: {PidLibrary.engineRpm.id: _rpm(1000, readingAt)},
        capturedAt: wall,
      ),
    );
    final nextSource = readingAt.add(const Duration(milliseconds: 20));
    recorder.ingest(
      TelemetrySnapshot(
        readings: {PidLibrary.engineRpm.id: _rpm(1000, nextSource)},
        capturedAt: wall,
      ),
    );

    expect(emitted, hasLength(2));
    expect(recorder.state.valueCount, 2);
    expect(emitted.first.observedAtUtc, DateTime.utc(2026, 8, 30, 1));
    expect(emitted.last.sourceTimestampUtc, nextSource);
  });

  test(
    'fresh to unavailable is one gap while status changes remain explicit',
    () {
      recorder.prepare(_header(wall));
      recorder.openAcceptance();
      recorder.ingest(
        TelemetrySnapshot(
          readings: {PidLibrary.engineRpm.id: _rpm(900, wall)},
          capturedAt: wall,
        ),
      );

      wall = wall.add(const Duration(seconds: 3));
      elapsed += const Duration(seconds: 3).inMicroseconds;
      recorder.ingest(TelemetrySnapshot(capturedAt: wall));
      recorder.ingest(
        TelemetrySnapshot(
          faults: {PidLibrary.engineRpm.id: PidFault.noAnswer},
          capturedAt: wall,
        ),
      );
      recorder.ingest(
        TelemetrySnapshot(
          faults: {PidLibrary.engineRpm.id: PidFault.busError},
          capturedAt: wall,
        ),
      );
      recorder.ingest(
        TelemetrySnapshot(
          faults: {PidLibrary.engineRpm.id: PidFault.busError},
          capturedAt: wall,
        ),
      );

      expect(recorder.state.valueCount, 1);
      expect(
        recorder.state.statusCount,
        3,
        reason: 'stale, no-answer, and bus-error are distinct transitions',
      );
      expect(
        recorder.state.gapCount,
        1,
        reason: 'status changes inside one unavailable interval are one gap',
      );
    },
  );

  test(
    'clock skew does not reopen an unavailable lane without a new value',
    () {
      final source = wall;
      recorder.prepare(_header(wall));
      recorder.openAcceptance();
      recorder.ingest(
        TelemetrySnapshot(
          readings: {PidLibrary.engineRpm.id: _rpm(900, source)},
          capturedAt: wall,
        ),
      );

      wall = wall.add(const Duration(seconds: 3));
      elapsed += const Duration(seconds: 3).inMicroseconds;
      recorder.ingest(TelemetrySnapshot(capturedAt: wall));
      expect(recorder.state.gapCount, 1);
      expect(recorder.state.statusCount, 1);

      // Wall clock jumps backward so the old sample looks fresh again.
      wall = source.add(const Duration(milliseconds: 100));
      elapsed += 1000;
      recorder.ingest(
        TelemetrySnapshot(
          readings: {PidLibrary.engineRpm.id: _rpm(900, source)},
          capturedAt: wall,
        ),
      );
      expect(
        recorder.state.valueCount,
        1,
        reason: 'same source timestamp must not emit a recovery value',
      );

      wall = wall.add(const Duration(seconds: 3));
      elapsed += const Duration(seconds: 3).inMicroseconds;
      recorder.ingest(TelemetrySnapshot(capturedAt: wall));
      expect(
        recorder.state.gapCount,
        1,
        reason:
            'reopening without a value would invent a second gap and '
            'damage the strict reader footer',
      );
      expect(recorder.state.statusCount, 1);
    },
  );

  test('changed exact definition closes before accepting the reading', () {
    recorder.prepare(_header(wall));
    recorder.openAcceptance();
    recorder.ingest(
      TelemetrySnapshot(
        readings: {PidLibrary.engineRpm.id: _rpm(26, wall, equation: 'A')},
        capturedAt: wall,
      ),
    );

    expect(recorder.state.phase, TelemetryRecorderPhase.finalizing);
    expect(
      recorder.state.terminalReason,
      TelemetryTerminalReason.configurationChanged,
    );
    expect(recorder.state.valueCount, 0);
    expect(emitted, isEmpty);

    recorder.stop(reason: TelemetryTerminalReason.background);
    expect(
      recorder.state.terminalReason,
      TelemetryTerminalReason.configurationChanged,
      reason: 'the first terminal reason wins permanently',
    );
  });

  test('non-finite values never become canonical value events', () {
    recorder.prepare(_header(wall));
    recorder.openAcceptance();
    recorder.ingest(
      TelemetrySnapshot(
        readings: {PidLibrary.engineRpm.id: _rpm(double.nan, wall)},
        capturedAt: wall,
      ),
    );
    expect(recorder.state.valueCount, 0);
    expect(emitted, isEmpty);
  });

  test('events stream to the bounded writer sink instead of accumulating', () {
    recorder.prepare(_header(wall));
    recorder.openAcceptance();

    for (var index = 0; index < 10000; index++) {
      wall = wall.add(const Duration(microseconds: 1));
      elapsed++;
      recorder.ingest(
        TelemetrySnapshot(
          readings: {PidLibrary.engineRpm.id: _rpm(index.toDouble(), wall)},
          capturedAt: wall,
        ),
      );
    }

    expect(emitted, hasLength(10000), reason: 'the injected sink owns output');
    expect(recorder.state.valueCount, 10000);
  });

  test('late storage failure cannot overwrite a completed terminal state', () {
    recorder.prepare(_header(wall));
    recorder.openAcceptance();
    recorder.stop(reason: TelemetryTerminalReason.user);
    final footer = recorder.complete(bytesBeforeFooter: 321);

    recorder.failStorage(restartRequired: true);
    recorder.failStorage();

    expect(recorder.state.phase, TelemetryRecorderPhase.completed);
    expect(recorder.state.terminalReason, footer.terminalReason);
    expect(recorder.state.errorCategory, isNull);
    expect(recorder.state.requiresRestart, isFalse);
  });
}
