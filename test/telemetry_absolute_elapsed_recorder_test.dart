import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/telemetry.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/artifact_operation_gate.dart';
import 'package:torque_obd/state/pid_mutation_lock.dart';
import 'package:torque_obd/state/telemetry_recorder.dart';
import 'package:torque_obd/state/telemetry_runtime.dart';
import 'package:torque_obd/state/telemetry_sessions.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_store.dart';

/// Regression: production and the ELM327 oracle pass absolute epoch
/// microseconds as [elapsedUs]. The session recorder must convert those to
/// session-relative elapsed before deriving observedAt, or every reading looks
/// decades-stale and the library lists an empty sessions list.
void main() {
  test('absolute epoch elapsedUs still records values the library can list', () async {
    final documents = await Directory.systemTemp.createTemp('abs-elapsed-docs-');
    addTearDown(() async {
      if (await documents.exists()) await documents.delete(recursive: true);
    });

    final now = DateTime.now().toUtc();
    final snapshot = TelemetrySnapshot(
      readings: {
        PidLibrary.vehicleSpeed.id: Reading(
          pid: PidLibrary.vehicleSpeed,
          value: 0,
          rawBytes: const [0],
          timestamp: now,
        ),
        PidLibrary.engineRpm.id: Reading(
          pid: PidLibrary.engineRpm,
          value: 1500,
          rawBytes: const [0x1a, 0xf8],
          timestamp: now,
        ),
      },
      capturedAt: now,
    );

    const sessionId = '00000000000000000000000000000031';
    final store = TelemetrySessionStore(
      documentsDirectory: () async => documents,
      idSource: () => sessionId,
    );
    final environment = LiveTelemetryStartEnvironment(
      readConnection: () => const TelemetryConnectionSnapshot(
        connected: true,
        foreground: true,
        connectionGeneration: 1,
        foregroundEpoch: 1,
      ),
      utcNow: () => DateTime.now().toUtc(),
      elapsedUs: () => DateTime.now().microsecondsSinceEpoch,
    )..observeTelemetry(snapshot);
    final recorder = RootTelemetryRecorder(
      environment: environment,
      storage: FileTelemetryRecorderStorage(store),
      startCommandMutex: StartCommandMutex(),
      artifactGate: ArtifactOperationGate(),
      pidMutationLock: PidMutationLock(),
      utcNow: () => DateTime.now().toUtc(),
      elapsedUs: () => DateTime.now().microsecondsSinceEpoch,
    );
    final started = await recorder.start(
      TelemetryStartRequest(
        source: TelemetrySource.simulatedRig,
        transport: TransportKind.wifi,
        protocol: 'ELM protocol 6',
        activePids: const [PidLibrary.vehicleSpeed, PidLibrary.engineRpm],
      ),
    );
    expect(started.outcome, TelemetryStartOutcome.recording);
    recorder.onTelemetry(snapshot);
    recorder.stop();
    await recorder.drainFinalization();

    final service = TelemetrySessionLibraryService(
      documentsDirectory: () async => documents,
    );
    final library = await service.load();
    expect(library.sessions, hasLength(1));
    expect(library.sessions.single.valueCount, 2);
    expect(library.sessions.single.statusCount, 0);
  });
}
