library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../obd/transcript_store.dart';
import 'app_share_coordinator.dart';
import 'artifact_operation_gate.dart';

/// Serializes the one canonical transcript snapshot without contending with
/// telemetry recording. Explicit Share and destructive clear operations still
/// use the app-wide artifact gate.
final transcriptMutationGateProvider = Provider<ArtifactOperationGate>((ref) {
  return ArtifactOperationGate();
});

/// The store used by automatic ObdSession snapshots. It shares the root
/// path and mutation lane but does not need destructive-action authority.
final obdTranscriptStoreProvider = Provider<TranscriptStore>((ref) {
  return TranscriptStore(
    artifactGate: ref.watch(artifactOperationGateProvider),
    saveGate: ref.watch(transcriptMutationGateProvider),
  );
});

/// The same storage path and root gate with the live policy required for
/// explicit destructive actions such as deleting a recovered transcript.
final managedTranscriptStoreProvider = Provider<TranscriptStore>((ref) {
  return TranscriptStore(
    artifactGate: ref.watch(artifactOperationGateProvider),
    saveGate: ref.watch(transcriptMutationGateProvider),
    destructivePolicy: ref.watch(appSharePolicyProvider),
  );
});
