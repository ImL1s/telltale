/// Desktop host assumptions for Demo → record → export/share.
///
/// CI runners exercise this after `flutter build {macos,windows,linux}`. The
/// share sheet itself may soft-fail on headless Linux/Windows agents; what
/// must not fail is staging a real export file and keeping the UX non-throwing.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/core/share/app_share_platform_bridge.dart';
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
  test('Demo record → CSV/JSON export stages files before soft-fail share',
      () async {
    final documents = await Directory.systemTemp.createTemp('desktop-tel-docs-');
    final shareRoot =
        await Directory.systemTemp.createTemp('desktop-tel-share-');
    addTearDown(() => documents.delete(recursive: true));
    addTearDown(() => shareRoot.delete(recursive: true));

    const sessionId = '00000000000000000000000000000042';
    var now = DateTime.utc(2026, 9, 1, 2);
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

    final started = await recorder.start(
      TelemetryStartRequest(
        source: TelemetrySource.demo,
        transport: TransportKind.demo,
        protocol: 'Demo',
        activePids: [PidLibrary.vehicleSpeed, PidLibrary.engineRpm],
      ),
    );
    expect(started.outcome, TelemetryStartOutcome.recording);
    now = now.add(const Duration(milliseconds: 120));
    elapsedUs += 120000;
    recorder.onTelemetry(_snapshot(now, speed: 0, rpm: 1726));
    now = now.add(const Duration(milliseconds: 120));
    elapsedUs += 120000;
    recorder.onTelemetry(_snapshot(now, speed: 28, rpm: 2400));
    recorder.stop();
    await recorder.drainFinalization();
    expect(recorder.progress.state.phase, TelemetryRecorderPhase.completed);

    final platform = _SoftFailCapturingPlatform();
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

    // Soft-fail share is allowed on desktop hosts without a sheet target.
    expect(platform.calls, 2);
    expect(platform.paths, hasLength(2));
    for (final path in platform.paths) {
      expect(File(path).existsSync(), isTrue);
      expect(File(path).lengthSync(), greaterThan(0));
    }
    expect(platform.mimes, containsAll(['text/csv', 'application/json']));

    final csvText = utf8.decode(platform.payloads['csv']!);
    final jsonText = utf8.decode(platform.payloads['json']!);
    expect(csvText, contains('Engine RPM'));
    expect(csvText, contains('Vehicle Speed'));
    expect(jsonDecode(jsonText), isA<Map<String, Object?>>());
    expect(jsonText, contains('"source":"demo"'));

    // Host-assumption marker for the desktop smoke matrix.
    expect(
      Platform.isMacOS ||
          Platform.isWindows ||
          Platform.isLinux ||
          Platform.isAndroid ||
          Platform.isIOS,
      isTrue,
      reason: 'flutter test host must identify an OS the product ships on',
    );
  });

  test('bridge swallows platform exceptions as failed without throwing',
      () async {
    final bridge = AppSharePlatformBridge(useNativeMacOsShare: false);
    // No share_plus binding in unit tests → soft-fail, never throw.
    final result = await bridge.share(
      AppSharePlatformRequest(
        path: Directory.systemTemp.path,
        mimeType: 'text/plain',
        fileName: 'probe.txt',
        subject: 'probe',
      ),
    );
    expect(result, AppShareResult.failed);
  });
}

TelemetrySnapshot _snapshot(
  DateTime at, {
  required double speed,
  required double rpm,
}) =>
    TelemetrySnapshot(
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
      capturedAt: at,
    );

final class _SoftFailCapturingPlatform implements AppSharePlatform {
  final List<String> paths = [];
  final List<String> mimes = [];
  final Map<String, List<int>> payloads = {};
  int calls = 0;

  @override
  Future<AppShareResult> share(AppSharePlatformRequest request) async {
    calls += 1;
    paths.add(request.path);
    mimes.add(request.mimeType);
    expect(File(request.path).existsSync(), isTrue);
    final bytes = await File(request.path).readAsBytes();
    payloads[request.fileName.split('.').last] = bytes;
    return AppShareResult.failed;
  }
}

final class _PermittingPolicy implements AppSharePolicy {
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
