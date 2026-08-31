import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/telemetry_sessions.dart';
import 'package:torque_obd/telemetry/session/telemetry_recorder.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_codec.dart';

Future<String> _writeReplay(
  Directory documents, {
  int valuePairs = 800,
  Duration wallClockDuration = const Duration(microseconds: 1600000),
}) async {
  const id = '10000000000000000000000000000001';
  final started = DateTime.utc(2026, 8, 30, 2);
  final definitions = [
    freezePidDefinition(PidLibrary.engineRpm),
    freezePidDefinition(PidLibrary.vehicleSpeed),
  ];
  final header = TelemetrySessionHeader(
    sessionId: id,
    startedAtUtc: started,
    source: TelemetrySource.simulatedRig,
    transport: TransportKind.wifi,
    protocol: 'ISO 15765-4 CAN',
    signals: definitions,
  );
  final events = <TelemetryEvent>[];
  for (var index = 0; index < valuePairs; index++) {
    final elapsed = index * 2000;
    events.add(
      TelemetryEvent.value(
        observedAtUtc: started.add(Duration(microseconds: elapsed)),
        sourceTimestampUtc: started.add(Duration(microseconds: elapsed)),
        elapsedUs: elapsed,
        pidId: definitions.first.definition.id,
        value: 1000 + index.toDouble(),
      ),
    );
    if (index == valuePairs ~/ 2) {
      events.add(
        TelemetryEvent.status(
          observedAtUtc: started.add(Duration(microseconds: elapsed + 1)),
          elapsedUs: elapsed + 1,
          pidId: definitions.first.definition.id,
          status: TelemetryStatus.noAnswer,
        ),
      );
    }
    events.add(
      TelemetryEvent.value(
        observedAtUtc: started.add(Duration(microseconds: elapsed + 2)),
        sourceTimestampUtc: started.add(Duration(microseconds: elapsed + 2)),
        elapsedUs: elapsed + 2,
        pidId: definitions[1].definition.id,
        value: index / 10,
      ),
    );
  }
  final prefix = TelemetrySessionCodec.encodePrefix(header, events);
  final footer = TelemetrySessionFooter(
    endedAtUtc: started.add(wallClockDuration),
    terminalReason: TelemetryTerminalReason.disconnect,
    valueCount: valuePairs * 2,
    statusCount: 1,
    gapCount: 1,
    bytesBeforeFooter: prefix.length,
  );
  final root = Directory('${documents.path}/telltale-telemetry');
  await root.create(recursive: true);
  await File('${root.path}/$id.ndjson').writeAsBytes(
    TelemetrySessionCodec.encode(
      TelemetrySession(header: header, events: events, footer: footer),
    ),
  );
  return id;
}

void main() {
  test(
    'replay is off-isolate, four-lane bounded, and never bridges gaps',
    () async {
      final documents = await Directory.systemTemp.createTemp('replay');
      addTearDown(() => documents.delete(recursive: true));
      final id = await _writeReplay(documents);
      final service = TelemetrySessionLibraryService(
        documentsDirectory: () async => documents,
      );

      final result = await service.replay(id);

      final replay = result.replay!;
      expect(replay.workerDebugName, isNot(Isolate.current.debugName));
      expect(replay.source, TelemetrySource.simulatedRig);
      expect(replay.transport, TransportKind.wifi.name);
      expect(replay.protocol, 'ISO 15765-4 CAN');
      expect(replay.signalCount, 2);
      expect(replay.valueCount, 1600);
      expect(replay.statusCount, 1);
      expect(replay.gapCount, 1);
      expect(replay.terminalReason, TelemetryTerminalReason.disconnect);
      expect(replay.elapsedDurationUs, 1598002);
      expect(replay.lanes, hasLength(2));
      for (final lane in replay.lanes) {
        expect(lane.primitives.length, lessThanOrEqualTo(1200));
      }
      final rpm = replay.lanes.first;
      expect(
        rpm.primitives.any(
          (primitive) =>
              primitive.kind == TelemetryReplayPrimitiveKind.gap ||
              primitive.breakBefore ||
              primitive.omittedGapCountBefore > 0,
        ),
        isTrue,
        reason:
            'sampling must retain a discontinuity instead of drawing across it',
      );
    },
  );

  test('more than four requested lanes fails before file parsing', () async {
    final documents = await Directory.systemTemp.createTemp('replay-select');
    addTearDown(() => documents.delete(recursive: true));
    final service = TelemetrySessionLibraryService(
      documentsDirectory: () async => documents,
    );

    final result = await service.replay(
      '10000000000000000000000000000001',
      selectedPidIds: const ['a', 'b', 'c', 'd', 'e'],
    );

    expect(result.failure, TelemetryReplayFailure.invalidSelection);
  });

  test(
    'replay axis uses canonical monotonic elapsed, not wall clock',
    () async {
      final documents = await Directory.systemTemp.createTemp('replay-axis');
      addTearDown(() => documents.delete(recursive: true));
      final id = await _writeReplay(
        documents,
        valuePairs: 4,
        wallClockDuration: const Duration(hours: 12),
      );

      final result = await TelemetrySessionLibraryService(
        documentsDirectory: () async => documents,
      ).replay(id);

      expect(result.replay!.elapsedDurationUs, 6002);
      expect(
        result.replay!.endedAtUtc.difference(result.replay!.startedAtUtc),
        const Duration(hours: 12),
      );
    },
  );

  test('damaged canonical file cannot become replay data', () async {
    final documents = await Directory.systemTemp.createTemp('replay-bad');
    addTearDown(() => documents.delete(recursive: true));
    const id = '10000000000000000000000000000002';
    final root = Directory('${documents.path}/telltale-telemetry');
    await root.create(recursive: true);
    await File('${root.path}/$id.ndjson').writeAsString('{broken}\n');

    final result = await TelemetrySessionLibraryService(
      documentsDirectory: () async => documents,
    ).replay(id);

    expect(result.failure, TelemetryReplayFailure.damaged);
  });
}
