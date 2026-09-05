import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/physics/vehicle_profile.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/telemetry_sessions.dart';
import 'package:torque_obd/telemetry/session/derived_estimates.dart';
import 'package:torque_obd/telemetry/session/telemetry_recorder.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_codec.dart';

Future<String> _writeReplay(
  Directory documents, {
  int valuePairs = 800,
  Duration wallClockDuration = const Duration(microseconds: 1600000),
  int elapsedOriginUs = 0,
  String sessionId = '10000000000000000000000000000001',
}) async {
  final id = sessionId;
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
    final elapsed = elapsedOriginUs + index * 2000;
    events.add(
      TelemetryEvent.value(
        observedAtUtc: started.add(
          Duration(microseconds: elapsed - elapsedOriginUs),
        ),
        sourceTimestampUtc: started.add(
          Duration(microseconds: elapsed - elapsedOriginUs),
        ),
        elapsedUs: elapsed,
        pidId: definitions.first.definition.id,
        value: 1000 + index.toDouble(),
      ),
    );
    if (index == valuePairs ~/ 2) {
      events.add(
        TelemetryEvent.status(
          observedAtUtc: started.add(
            Duration(microseconds: elapsed - elapsedOriginUs + 1),
          ),
          elapsedUs: elapsed + 1,
          pidId: definitions.first.definition.id,
          status: TelemetryStatus.noAnswer,
        ),
      );
    }
    events.add(
      TelemetryEvent.value(
        observedAtUtc: started.add(
          Duration(microseconds: elapsed - elapsedOriginUs + 2),
        ),
        sourceTimestampUtc: started.add(
          Duration(microseconds: elapsed - elapsedOriginUs + 2),
        ),
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

  test(
    'replay normalizes a non-zero app-clock origin to session-relative time',
    () async {
      final documents = await Directory.systemTemp.createTemp('replay-origin');
      addTearDown(() => documents.delete(recursive: true));
      // A one-minute recording that begins ten minutes after app launch must
      // replay for ~60s from chart origin 0, not stretch across ~11 minutes.
      const originUs = 10 * 60 * 1000000;
      final id = await _writeReplay(
        documents,
        valuePairs: 4,
        elapsedOriginUs: originUs,
        sessionId: '10000000000000000000000000000003',
      );

      final result = await TelemetrySessionLibraryService(
        documentsDirectory: () async => documents,
      ).replay(id);

      final replay = result.replay!;
      expect(replay.elapsedDurationUs, 6002);
      expect(
        replay.elapsedDurationUs,
        lessThan(originUs),
        reason: 'duration must be session length, not absolute last elapsedUs',
      );
      final earliest = replay.lanes
          .expand((lane) => lane.primitives)
          .map((primitive) => primitive.elapsedUs)
          .reduce((a, b) => a < b ? a : b);
      expect(earliest, 0, reason: 'session origin must be normalized to zero');
      expect(
        replay.lanes.every(
          (lane) => lane.primitives.every(
            (primitive) =>
                primitive.elapsedUs >= 0 && primitive.elapsedUs <= 6002,
          ),
        ),
        isTrue,
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

  test('replay keeps out-of-range quality on the selected datum', () async {
    final documents = await Directory.systemTemp.createTemp('replay-quality');
    addTearDown(() => documents.delete(recursive: true));
    const id = '10000000000000000000000000000004';
    final started = DateTime.utc(2026, 8, 30, 3);
    final definition = freezePidDefinition(PidLibrary.coolantTemp);
    final header = TelemetrySessionHeader(
      sessionId: id,
      startedAtUtc: started,
      source: TelemetrySource.demo,
      transport: TransportKind.demo,
      protocol: 'AUTO',
      signals: [definition],
    );
    final events = [
      TelemetryEvent.value(
        observedAtUtc: started,
        sourceTimestampUtc: started,
        elapsedUs: 0,
        pidId: definition.definition.id,
        value: 999,
        quality: TelemetryQuality.outOfReferenceRange,
      ),
    ];
    final prefix = TelemetrySessionCodec.encodePrefix(header, events);
    final root = Directory('${documents.path}/telltale-telemetry');
    await root.create(recursive: true);
    await File('${root.path}/$id.ndjson').writeAsBytes(
      TelemetrySessionCodec.encode(
        TelemetrySession(
          header: header,
          events: events,
          footer: TelemetrySessionFooter(
            endedAtUtc: started.add(const Duration(seconds: 1)),
            terminalReason: TelemetryTerminalReason.user,
            valueCount: 1,
            statusCount: 0,
            gapCount: 0,
            bytesBeforeFooter: prefix.length,
          ),
        ),
      ),
    );

    final result = await TelemetrySessionLibraryService(
      documentsDirectory: () async => documents,
    ).replay(id);

    final primitive = result.replay!.lanes.single.primitives.single;
    expect(primitive.kind, TelemetryReplayPrimitiveKind.value);
    expect(primitive.value, 999);
    expect(primitive.quality, 'outOfReferenceRange');
  });

  test(
    'default History replay keeps derived lanes when more than four PIDs',
    () async {
      final documents = await Directory.systemTemp.createTemp('replay-derived');
      addTearDown(() => documents.delete(recursive: true));
      const id = '10000000000000000000000000000005';
      final started = DateTime.utc(2026, 8, 30, 4);
      const profile = VehicleProfile(massKg: 1280);
      final signals = DerivedEstimates.appendTo(
        [
          PidLibrary.engineRpm,
          PidLibrary.vehicleSpeed,
          PidLibrary.coolantTemp,
          PidLibrary.throttlePosition,
        ].map(freezePidDefinition).toList(),
        profile: profile,
      );
      expect(signals, hasLength(6));
      final header = TelemetrySessionHeader(
        sessionId: id,
        startedAtUtc: started,
        source: TelemetrySource.demo,
        transport: TransportKind.demo,
        protocol: 'AUTO',
        signals: signals,
      );
      final events = [
        for (var index = 0; index < signals.length; index++)
          TelemetryEvent.value(
            observedAtUtc: started,
            sourceTimestampUtc: started,
            elapsedUs: index,
            pidId: signals[index].definition.id,
            value: index.toDouble(),
          ),
      ];
      final prefix = TelemetrySessionCodec.encodePrefix(header, events);
      final root = Directory('${documents.path}/telltale-telemetry');
      await root.create(recursive: true);
      await File('${root.path}/$id.ndjson').writeAsBytes(
        TelemetrySessionCodec.encode(
          TelemetrySession(
            header: header,
            events: events,
            footer: TelemetrySessionFooter(
              endedAtUtc: started.add(const Duration(seconds: 1)),
              terminalReason: TelemetryTerminalReason.user,
              valueCount: events.length,
              statusCount: 0,
              gapCount: 0,
              bytesBeforeFooter: prefix.length,
            ),
          ),
        ),
      );

      final result = await TelemetrySessionLibraryService(
        documentsDirectory: () async => documents,
      ).replay(id);

      expect(result.failure, isNull);
      expect(result.replay!.signalCount, 6);
      expect(result.replay!.lanes, hasLength(4));
      expect(
        result.replay!.lanes.map((lane) => lane.name),
        containsAll(['估算馬力', '估算油耗']),
      );
    },
  );

  test(
    'default replay skips a derived lane that never recorded a value',
    () async {
      final documents = await Directory.systemTemp.createTemp(
        'replay-empty-fuel',
      );
      addTearDown(() => documents.delete(recursive: true));
      const id = '10000000000000000000000000000006';
      final started = DateTime.utc(2026, 8, 30, 5);
      final signals = DerivedEstimates.appendTo(
        [
          PidLibrary.engineRpm,
          PidLibrary.vehicleSpeed,
          PidLibrary.coolantTemp,
          PidLibrary.throttlePosition,
        ].map(freezePidDefinition).toList(),
      );
      final header = TelemetrySessionHeader(
        sessionId: id,
        startedAtUtc: started,
        source: TelemetrySource.demo,
        transport: TransportKind.demo,
        protocol: 'AUTO',
        signals: signals,
      );
      final events = [
        for (final signal in signals)
          if (signal.definition.id != DerivedEstimates.fuelRate.id)
            TelemetryEvent.value(
              observedAtUtc: started,
              sourceTimestampUtc: started,
              elapsedUs: 0,
              pidId: signal.definition.id,
              value: 1,
            ),
      ];
      final prefix = TelemetrySessionCodec.encodePrefix(header, events);
      final root = Directory('${documents.path}/telltale-telemetry');
      await root.create(recursive: true);
      await File('${root.path}/$id.ndjson').writeAsBytes(
        TelemetrySessionCodec.encode(
          TelemetrySession(
            header: header,
            events: events,
            footer: TelemetrySessionFooter(
              endedAtUtc: started.add(const Duration(seconds: 1)),
              terminalReason: TelemetryTerminalReason.user,
              valueCount: events.length,
              statusCount: 0,
              gapCount: 0,
              bytesBeforeFooter: prefix.length,
            ),
          ),
        ),
      );

      final result = await TelemetrySessionLibraryService(
        documentsDirectory: () async => documents,
      ).replay(id);

      expect(result.failure, isNull);
      expect(result.replay!.lanes.map((lane) => lane.name), contains('估算馬力'));
      expect(
        result.replay!.lanes.map((lane) => lane.name),
        isNot(contains('估算油耗')),
      );
    },
  );
}
