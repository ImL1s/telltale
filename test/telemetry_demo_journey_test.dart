import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/core/share/app_share_platform_bridge.dart';
import 'package:torque_obd/obd/physics/vehicle_profile.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/telemetry.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/app_share_coordinator.dart';
import 'package:torque_obd/state/artifact_operation_gate.dart';
import 'package:torque_obd/state/pid_mutation_lock.dart';
import 'package:torque_obd/state/telemetry_recorder.dart';
import 'package:torque_obd/state/telemetry_runtime.dart';
import 'package:torque_obd/state/telemetry_sessions.dart';
import 'package:torque_obd/telemetry/session/telemetry_recorder.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_store.dart';

void main() {
  test('Demo records finalizes replays exports privately then deletes and frees quota', () async {
    final documents = await Directory.systemTemp.createTemp('demo-journey-');
    final shareRoot = await Directory.systemTemp.createTemp('demo-share-');
    addTearDown(() => documents.delete(recursive: true));
    addTearDown(() => shareRoot.delete(recursive: true));
    const sessionId = '00000000000000000000000000000021';
    var now = DateTime.utc(2026, 8, 30, 1);
    var elapsedUs = 1000000;
    final store = TelemetrySessionStore(
      documentsDirectory: () async => documents,
      idSource: () => sessionId,
      nowUtc: () => now,
    );
    final environment = LiveTelemetryStartEnvironment(
      readConnection: () => const TelemetryConnectionSnapshot(
        connected: true,
        foreground: true,
        connectionGeneration: 1,
        foregroundEpoch: 1,
      ),
      utcNow: () => now,
      elapsedUs: () => elapsedUs,
    )..observeTelemetry(_snapshot(now, speed: 0, rpm: 900));
    final recorder = RootTelemetryRecorder(
      environment: environment,
      storage: FileTelemetryRecorderStorage(store),
      startCommandMutex: StartCommandMutex(),
      artifactGate: ArtifactOperationGate(),
      pidMutationLock: PidMutationLock(),
      utcNow: () => now,
      elapsedUs: () => elapsedUs,
    );

    const profile = VehicleProfile(massKg: 1280, isConfirmed: false);
    final started = await recorder.start(
      TelemetryStartRequest(
        source: TelemetrySource.demo,
        transport: TransportKind.demo,
        protocol: 'Demo',
        activePids: [PidLibrary.vehicleSpeed, PidLibrary.engineRpm],
        vehicleProfile: profile,
      ),
    );
    expect(started.outcome, TelemetryStartOutcome.recording);
    now = now.add(const Duration(milliseconds: 100));
    elapsedUs += 100000;
    recorder.onTelemetry(
      _snapshot(now, speed: 0, rpm: 1726, accel: 0),
      profile: profile,
    );
    now = now.add(const Duration(milliseconds: 100));
    elapsedUs += 100000;
    recorder.onTelemetry(
      _snapshot(now, speed: 8, rpm: 2100, accel: 0.8),
      profile: profile,
    );
    recorder.stop();
    await recorder.drainFinalization();
    expect(recorder.progress.state.phase, TelemetryRecorderPhase.completed);

    final service = TelemetrySessionLibraryService(
      documentsDirectory: () async => documents,
    );
    final library = await service.load();
    expect(library.groupCount, 1);
    expect(library.sessions.single.id, sessionId);
    expect(library.sessions.single.source, TelemetrySource.demo);
    expect(library.sessions.single.transport, TransportKind.demo.name);
    expect(library.sessions.single.valueCount, 6);
    expect(library.sessions.single.statusCount, 0);
    expect(library.sessions.single.gapCount, 0);

    final replay = await service.replay(sessionId);
    expect(replay.failure, isNull);
    expect(replay.replay?.source, TelemetrySource.demo);
    expect(replay.replay?.lanes, hasLength(4));
    expect(
      replay.replay!.lanes.map((lane) => lane.name),
      containsAll(['Engine RPM', 'Vehicle Speed', '估算馬力', '估算油耗']),
    );
    expect(replay.replay?.valueCount, 6);

    final platform = _CapturingPlatform();
    final policy = _PermittingPolicy();
    final artifactGate = ArtifactOperationGate();
    var shareId = 0;
    final coordinator = AppShareCoordinator(
      rootDirectory: () async => shareRoot,
      policy: policy,
      artifactGate: artifactGate,
      platform: platform,
      idSource: () => (++shareId).toRadixString(16).padLeft(32, '0'),
      nowUtc: () => now,
      availableBytes: (_) async => 64 * 1024 * 1024,
    );
    expect(await coordinator.initialize(), AppShareInitializationOutcome.ready);
    final actions = TelemetrySessionActions(
      documentsDirectory: () async => documents,
      store: store,
      shareCoordinator: coordinator,
      artifactGate: artifactGate,
      sharePolicy: policy,
      readRecorderPhase: () => recorder.progress.state.phase,
    );

    expect(
      (await actions.export(sessionId, TelemetryExportFormat.csv)).isSuccess,
      isTrue,
    );
    expect(
      (await actions.export(sessionId, TelemetryExportFormat.json)).isSuccess,
      isTrue,
    );
    final csv = utf8.decode(platform.byExtension['csv']!);
    final jsonText = utf8.decode(platform.byExtension['json']!);
    final json = jsonDecode(jsonText) as Map<String, Object?>;
    expect(csv, contains('Engine RPM'));
    expect(csv, contains('Vehicle Speed'));
    expect(csv, contains('估算馬力'));
    expect(csv, contains('calculated'));
    expect(json['events'], hasLength(6));
    expect(jsonText, contains('"origin":"calculated"'));
    expect(jsonText, contains('"source":"demo"'));
    expect(csv, contains('# privacy_exclusions=VIN;GPS;account;'));
    expect(
      json['privacyExclusions'],
      containsAll(const [
        'VIN',
        'GPS',
        'account',
        'vehicleProfile',
        'adapterAddress',
        'rawDiagnosticTraffic',
      ]),
    );
    final csvPayload = csv
        .split(RegExp(r'\r?\n'))
        .where((line) => !line.startsWith('#'))
        .join('\n');
    final jsonPayload = jsonEncode({
      'header': json['header'],
      'events': json['events'],
      'footer': json['footer'],
    });
    for (final forbidden in const [
      'VIN',
      'GPS',
      'account',
      'adapterAddress',
      'vehicleProfile',
      'rawTranscript',
    ]) {
      expect(csvPayload, isNot(contains(forbidden)));
      expect(jsonPayload, isNot(contains(forbidden)));
    }

    expect(
      (await actions.delete(sessionId, confirmed: true)).isSuccess,
      isTrue,
    );
    final emptyLibrary = await service.load();
    final quota = await store.scanQuota();
    expect(emptyLibrary.sessions, isEmpty);
    expect(emptyLibrary.damaged, isEmpty);
    expect(quota.groupCount, 0);
    expect(quota.recognizedBytes, 0);
  });

  test('editing vehicle settings during a recording stops the session', () async {
    final documents = await Directory.systemTemp.createTemp('profile-freeze-');
    addTearDown(() => documents.delete(recursive: true));
    const sessionId = '00000000000000000000000000000022';
    var now = DateTime.utc(2026, 8, 30, 1);
    var elapsedUs = 1000000;
    final store = TelemetrySessionStore(
      documentsDirectory: () async => documents,
      idSource: () => sessionId,
      nowUtc: () => now,
    );
    final environment = LiveTelemetryStartEnvironment(
      readConnection: () => const TelemetryConnectionSnapshot(
        connected: true,
        foreground: true,
        connectionGeneration: 1,
        foregroundEpoch: 1,
      ),
      utcNow: () => now,
      elapsedUs: () => elapsedUs,
    )..observeTelemetry(_snapshot(now, speed: 0, rpm: 900, accel: 0));
    final recorder = RootTelemetryRecorder(
      environment: environment,
      storage: FileTelemetryRecorderStorage(store),
      startCommandMutex: StartCommandMutex(),
      artifactGate: ArtifactOperationGate(),
      pidMutationLock: PidMutationLock(),
      utcNow: () => now,
      elapsedUs: () => elapsedUs,
    );
    const profile = VehicleProfile(massKg: 1280);
    expect(
      (await recorder.start(
        TelemetryStartRequest(
          source: TelemetrySource.demo,
          transport: TransportKind.demo,
          protocol: 'Demo',
          activePids: [PidLibrary.vehicleSpeed, PidLibrary.engineRpm],
          vehicleProfile: profile,
        ),
      )).outcome,
      TelemetryStartOutcome.recording,
    );
    recorder.onTelemetry(
      _snapshot(now, speed: 8, rpm: 2100, accel: 0.8),
      profile: profile,
    );
    recorder.onVehicleProfileChanged(const VehicleProfile(massKg: 1800));
    await recorder.drainFinalization();
    expect(recorder.progress.state.phase, TelemetryRecorderPhase.completed);
    expect(
      recorder.progress.state.terminalReason,
      TelemetryTerminalReason.configurationChanged,
    );
  });
}

TelemetrySnapshot _snapshot(
  DateTime at, {
  required double speed,
  required double rpm,
  double? accel,
}) => TelemetrySnapshot(
  readings: {
    PidLibrary.vehicleSpeed.id: Reading(
      pid: PidLibrary.vehicleSpeed,
      value: speed,
      rawBytes: [speed.round()],
      timestamp: at,
    ),
    PidLibrary.engineRpm.id: Reading(
      pid: PidLibrary.engineRpm,
      value: rpm,
      rawBytes: const [0x1a, 0xf8],
      timestamp: at,
    ),
  },
  accelerationMs2: accel,
  capturedAt: at,
);

class _CapturingPlatform implements AppSharePlatform {
  final Map<String, List<int>> byExtension = {};

  @override
  Future<AppShareResult> share(AppSharePlatformRequest request) async {
    byExtension[request.fileName.split('.').last] = await File(request.path)
        .readAsBytes();
    return AppShareResult.selected;
  }
}

class _PermittingPolicy implements AppSharePolicy {
  @override
  SharePreparationPermit? freeze() => const SharePreparationPermit(
    recorderEpoch: 1,
    foregroundEpoch: 1,
    connectionEpoch: 1,
    safetyEpoch: 1,
    connectionClass: ShareConnectionClass.disconnected,
  );

  @override
  SharePermitValidation validate(SharePreparationPermit permit) =>
      const SharePermitValidation.valid();
}
