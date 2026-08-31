/// Root production authorities shared by recording, file operations, and UI.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/share/app_storage_capacity.dart';
import '../obd/telemetry.dart';
import 'app_share_coordinator.dart';
import 'artifact_operation_gate.dart';
import 'driving_interaction_safety.dart';
import 'obd_session.dart';
import 'telemetry_recorder.dart';

/// The live, root-stable driving-safety policy used by every file action.
///
/// This provider deliberately reads changing inputs inside the policy callback
/// instead of watching and replacing the policy object. A permit must retain
/// one authority identity for its complete asynchronous preparation window.
final productionDrivingSafetyInputProvider =
    Provider<DrivingSafetyInput Function()>((ref) {
      final stopwatch = Stopwatch()..start();
      return () {
        final connection = ref.read(obdSessionProvider);
        final session = ref.read(obdSessionProvider.notifier);
        final recorder = ref.read(telemetryRecorderControllerProvider);
        final artifact = ref.read(artifactOperationGateProvider).snapshot;
        final telemetry = authoritativeTelemetryValue(
          ref.read(telemetryProvider),
        );
        final recorderOwnsArtifacts =
            artifact.operation == ArtifactOperation.record ||
            artifact.operation == ArtifactOperation.finalize;
        return DrivingSafetyInput(
          connectionPhase: connection.phase,
          connectionEpoch: session.generation,
          foreground: session.isForeground,
          foregroundEpoch: session.pauseEpoch,
          recorderBlocksArtifacts: recorderOwnsArtifacts,
          recorderEpoch: recorder.lifecycleEpoch,
          telemetry: telemetry ?? const TelemetrySnapshot(),
          nowUtc: DateTime.now().toUtc(),
          monotonicUs: stopwatch.elapsedMicroseconds,
        );
      };
    });

final productionAppSharePolicyProvider = Provider<AppSharePolicy>((ref) {
  final policy = DrivingInteractionSafetyPolicy(
    ref.read(productionDrivingSafetyInputProvider),
  );
  ref.listen(telemetryProvider, (_, _) => policy.synchronize());
  return policy;
});

final productionAppShareAvailableBytesProvider =
    Provider<Future<int?> Function(Directory)>((ref) {
      const capacity = AppStorageCapacity();
      return capacity.availableBytes;
    });
