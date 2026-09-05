library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show Rect;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../telemetry/session/derived_estimates.dart';
import '../telemetry/session/telemetry_recorder.dart';
import '../telemetry/session/telemetry_session.dart';
import '../telemetry/session/telemetry_session_codec.dart';
import '../telemetry/session/telemetry_session_reader.dart';
import '../telemetry/session/telemetry_session_store.dart';
import '../telemetry/session/timeline_downsampler.dart';
import 'app_share_coordinator.dart';
import 'app_share_entry_controller.dart';
import 'artifact_operation_gate.dart';
import 'driving_interaction_safety.dart';
import 'obd_session.dart';
import 'telemetry_recorder.dart';
import 'telemetry_runtime.dart';

const telemetryReplayDisclaimer = '預覽已抽樣；匯出保留完整已記錄事件';
const telemetryExportDisclosure =
    '匯出內容包含訊號名稱、數值、觀測與來源時間、傳輸類型、通訊協定，以及凍結的 PID 標籤、單位與公式。JSON 可能包含使用者自訂標籤、單位、公式與完整凍結定義。匯出內容不含 VIN、GPS、帳號、轉接器位址、車輛設定檔或原始診斷流量。';

enum TelemetryHistoryAccess {
  permitted,
  recorderActive,
  moving,
  speedUnknown,
  background,
}

extension TelemetryHistoryAccessMessage on TelemetryHistoryAccess {
  String? get message => switch (this) {
    TelemetryHistoryAccess.permitted => null,
    TelemetryHistoryAccess.recorderActive => '請先停止並儲存',
    TelemetryHistoryAccess.moving => '請停車後操作',
    TelemetryHistoryAccess.speedUnknown => '無法確認車輛已停止；請先中斷連線',
    TelemetryHistoryAccess.background => '請回到 App 後再操作',
  };
}

TelemetryHistoryAccess telemetryHistoryAccess({
  required TelemetryRecorderPhase recorderPhase,
  required DrivingInteractionSafetySnapshot? safety,
}) {
  if (recorderPhase == TelemetryRecorderPhase.preparing ||
      recorderPhase == TelemetryRecorderPhase.recording ||
      recorderPhase == TelemetryRecorderPhase.finalizing) {
    return TelemetryHistoryAccess.recorderActive;
  }
  if (safety == null) return TelemetryHistoryAccess.speedUnknown;
  if (!safety.foreground) return TelemetryHistoryAccess.background;
  return switch (safety.classification) {
    DrivingSafetyClassification.disconnected ||
    DrivingSafetyClassification.stopped => TelemetryHistoryAccess.permitted,
    DrivingSafetyClassification.moving => TelemetryHistoryAccess.moving,
    DrivingSafetyClassification.unknown => TelemetryHistoryAccess.speedUnknown,
  };
}

String telemetrySourceLabel(TelemetrySource source) => switch (source) {
  TelemetrySource.demo => '內建模擬',
  TelemetrySource.simulatedRig => '測試馬具',
  TelemetrySource.fieldAppConnection => '一般 field App 連線',
};

final class TelemetrySessionProjection {
  const TelemetrySessionProjection({
    required this.id,
    required this.startedAtUtc,
    required this.endedAtUtc,
    required this.source,
    required this.transport,
    required this.protocol,
    required this.signalCount,
    required this.valueCount,
    required this.statusCount,
    required this.gapCount,
    required this.terminalReason,
    required this.bytes,
    required this.elapsedDurationUs,
  });

  final String id;
  final DateTime startedAtUtc;
  final DateTime endedAtUtc;
  final TelemetrySource source;
  final String transport;
  final String protocol;
  final int signalCount;
  final int valueCount;
  final int statusCount;
  final int gapCount;
  final TelemetryTerminalReason terminalReason;
  final int bytes;

  /// Monotonic event span (last elapsed − first elapsed), matching replay.
  /// Prefer this over wall-clock header/footer diffs: recovery footers use
  /// recovery time and can inflate overnight gaps into the history label.
  final int elapsedDurationUs;

  Duration get duration =>
      Duration(microseconds: elapsedDurationUs < 0 ? 0 : elapsedDurationUs);
  String get sourceLabel => telemetrySourceLabel(source);
}

enum DamagedTelemetryKind { corrupt, collision }

final class DamagedTelemetryProjection {
  const DamagedTelemetryProjection({
    required this.id,
    required this.filesystemModifiedAtUtc,
    required this.kind,
  });

  final String id;
  final DateTime filesystemModifiedAtUtc;
  final DamagedTelemetryKind kind;
}

final class TelemetrySessionLibrary {
  const TelemetrySessionLibrary({
    required this.sessions,
    required this.damaged,
    required this.groupCount,
    required this.recognizedBytes,
    required this.omittedCount,
    required this.encodedProjectionBytes,
    required this.workerDebugName,
  });

  final List<TelemetrySessionProjection> sessions;
  final List<DamagedTelemetryProjection> damaged;
  final int groupCount;
  final int recognizedBytes;
  final int omittedCount;
  final int encodedProjectionBytes;
  final String workerDebugName;

  int get remainingGroups => (TelemetryQuota.groupLimit - groupCount).clamp(
    0,
    TelemetryQuota.groupLimit,
  );
  int get remainingBytes => (TelemetryQuota.libraryByteLimit - recognizedBytes)
      .clamp(0, TelemetryQuota.libraryByteLimit);
}

enum TelemetryReplayPrimitiveKind { value, status, gap }

final class TelemetryReplayPrimitive {
  const TelemetryReplayPrimitive({
    required this.kind,
    required this.elapsedUs,
    this.value,
    this.status,
    this.breakBefore = false,
    this.omittedGapCountBefore = 0,
    this.quality,
  });

  final TelemetryReplayPrimitiveKind kind;
  final int elapsedUs;
  final double? value;
  final String? status;
  final bool breakBefore;
  final int omittedGapCountBefore;
  final String? quality;
}

final class TelemetryReplayLane {
  const TelemetryReplayLane({
    required this.pidId,
    required this.name,
    required this.unit,
    required this.primitives,
  });

  final String pidId;
  final String name;
  final String unit;
  final List<TelemetryReplayPrimitive> primitives;
}

final class TelemetrySessionReplay {
  const TelemetrySessionReplay({
    required this.sessionId,
    required this.startedAtUtc,
    required this.endedAtUtc,
    required this.source,
    required this.transport,
    required this.protocol,
    required this.signalCount,
    required this.valueCount,
    required this.statusCount,
    required this.gapCount,
    required this.terminalReason,
    required this.elapsedDurationUs,
    required this.lanes,
    required this.workerDebugName,
  });

  final String sessionId;
  final DateTime startedAtUtc;
  final DateTime endedAtUtc;
  final TelemetrySource source;
  final String transport;
  final String protocol;
  final int signalCount;
  final int valueCount;
  final int statusCount;
  final int gapCount;
  final TelemetryTerminalReason terminalReason;
  final int elapsedDurationUs;
  final List<TelemetryReplayLane> lanes;
  final String workerDebugName;
}

enum TelemetryReplayFailure { invalidId, notFound, damaged, invalidSelection }

final class TelemetryReplayResult {
  const TelemetryReplayResult.success(this.replay) : failure = null;
  const TelemetryReplayResult.failure(this.failure) : replay = null;

  final TelemetrySessionReplay? replay;
  final TelemetryReplayFailure? failure;
}

final class TelemetrySessionLibraryService {
  TelemetrySessionLibraryService({
    Future<Directory> Function()? documentsDirectory,
    this._loader,
  }) : _documentsDirectory =
           documentsDirectory ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _documentsDirectory;
  final Future<TelemetrySessionLibrary> Function()? _loader;

  Future<TelemetrySessionLibrary> load() async {
    final override = _loader;
    if (override != null) return override();
    final documents = await _documentsDirectory();
    final raw = await Isolate.run(() => _scanLibraryWorker(documents.path));
    return _decodeLibrary(raw);
  }

  Future<TelemetryReplayResult> replay(
    String sessionId, {
    Iterable<String> selectedPidIds = const <String>[],
  }) async {
    if (!TelemetrySessionReader.isOpaqueId(sessionId)) {
      return const TelemetryReplayResult.failure(
        TelemetryReplayFailure.invalidId,
      );
    }
    final selected = selectedPidIds.toSet().toList(growable: false);
    if (selected.length > 4) {
      return const TelemetryReplayResult.failure(
        TelemetryReplayFailure.invalidSelection,
      );
    }
    final documents = await _documentsDirectory();
    final raw = await Isolate.run(
      () => _replayWorker(<String, Object?>{
        'documentsPath': documents.path,
        'sessionId': sessionId,
        'selectedPidIds': selected,
      }),
    );
    return _decodeReplay(raw);
  }
}

enum TelemetryExportFormat { csv, json }

enum TelemetrySessionActionFailure {
  confirmationRequired,
  recorderActive,
  moving,
  speedUnknown,
  background,
  artifactBusy,
  policyChanged,
  invalidId,
  notFound,
  storage,
  share,
  restartRequired,
}

final class TelemetrySessionActionResult {
  const TelemetrySessionActionResult.success()
    : failure = null,
      userFacingMessage = null;
  const TelemetrySessionActionResult.failure(
    this.failure, {
    this.userFacingMessage,
  });

  final TelemetrySessionActionFailure? failure;
  final String? userFacingMessage;
  bool get isSuccess => failure == null;

  String get message =>
      userFacingMessage ?? telemetrySessionActionFailureLabel(failure!);
}

const telemetryArtifactRestartRequiredCopy = '本機檔案作業狀態無法確認；請完全關閉並重新啟動 App 後再操作';

String telemetrySessionActionFailureLabel(
  TelemetrySessionActionFailure failure,
) => switch (failure) {
  TelemetrySessionActionFailure.confirmationRequired => '請先確認這個刪除操作',
  TelemetrySessionActionFailure.recorderActive => '請先停止並儲存',
  TelemetrySessionActionFailure.moving => '請停車後操作',
  TelemetrySessionActionFailure.speedUnknown => '無法確認車輛已停止；請先中斷連線',
  TelemetrySessionActionFailure.background => '請回到 App 後再操作',
  TelemetrySessionActionFailure.artifactBusy => '另一個檔案作業尚未完成',
  TelemetrySessionActionFailure.policyChanged => '操作期間行車或連線狀態已改變',
  TelemetrySessionActionFailure.invalidId => '紀錄識別碼無效',
  TelemetrySessionActionFailure.notFound => '找不到這筆本機紀錄',
  TelemetrySessionActionFailure.storage => '本機儲存作業失敗',
  TelemetrySessionActionFailure.share => '無法準備或開啟分享',
  TelemetrySessionActionFailure.restartRequired =>
    telemetryArtifactRestartRequiredCopy,
};

final class TelemetrySessionActions {
  TelemetrySessionActions({
    required this.documentsDirectory,
    required this.store,
    this.shareEntryController,
    this.shareCoordinator,
    required this.artifactGate,
    required this.sharePolicy,
    required this.readRecorderPhase,
    this.readRestartRequired,
    this.onRestartRequired,
  });

  final Future<Directory> Function() documentsDirectory;
  final TelemetrySessionStore store;
  final AppShareEntryController? shareEntryController;
  final AppShareCoordinator? shareCoordinator;
  final ArtifactOperationGate artifactGate;
  final AppSharePolicy sharePolicy;
  final TelemetryRecorderPhase Function() readRecorderPhase;
  final bool Function()? readRestartRequired;
  final void Function()? onRestartRequired;
  bool _restartRequired = false;

  Future<TelemetrySessionActionResult> export(
    String sessionId,
    TelemetryExportFormat format, {
    Rect? sharePositionOrigin,
  }) async {
    final guard = _guard();
    if (guard != null) return TelemetrySessionActionResult.failure(guard);
    if (!TelemetrySessionReader.isOpaqueId(sessionId)) {
      return const TelemetrySessionActionResult.failure(
        TelemetrySessionActionFailure.invalidId,
      );
    }
    final documents = await documentsDirectory();
    final controller =
        shareEntryController ??
        (shareCoordinator == null
            ? null
            : AppShareEntryController(shareCoordinator!));
    if (controller == null) {
      return const TelemetrySessionActionResult.failure(
        TelemetrySessionActionFailure.share,
      );
    }
    final outcome = format == TelemetryExportFormat.csv
        ? await controller.shareTelemetryCsv(
            documents: documents,
            sessionId: sessionId,
            sharePositionOrigin: sharePositionOrigin,
          )
        : await controller.shareTelemetryJson(
            documents: documents,
            sessionId: sessionId,
            sharePositionOrigin: sharePositionOrigin,
          );
    if (outcome.error == null) {
      return const TelemetrySessionActionResult.success();
    }
    if (outcome.error == ShareError.shareCleanupRequired) {
      _retainRestartRequirement();
      return const TelemetrySessionActionResult.failure(
        TelemetrySessionActionFailure.restartRequired,
        userFacingMessage: telemetryArtifactRestartRequiredCopy,
      );
    }
    return TelemetrySessionActionResult.failure(
      TelemetrySessionActionFailure.share,
      userFacingMessage: outcome.userFacingError,
    );
  }

  Future<TelemetrySessionActionResult> delete(
    String sessionId, {
    required bool confirmed,
  }) async {
    if (!confirmed) {
      return const TelemetrySessionActionResult.failure(
        TelemetrySessionActionFailure.confirmationRequired,
      );
    }
    final guard = _guard();
    if (guard != null) return TelemetrySessionActionResult.failure(guard);
    if (!TelemetrySessionReader.isOpaqueId(sessionId)) {
      return const TelemetrySessionActionResult.failure(
        TelemetrySessionActionFailure.invalidId,
      );
    }
    final acquired = artifactGate.tryAcquire(
      'telemetry-delete-$sessionId',
      ArtifactOperation.delete,
    );
    final token = acquired.token;
    if (token == null) {
      return const TelemetrySessionActionResult.failure(
        TelemetrySessionActionFailure.artifactBusy,
      );
    }
    final permit = sharePolicy.freeze();
    if (permit == null) {
      artifactGate.release(token);
      return TelemetrySessionActionResult.failure(
        _guard() ?? TelemetrySessionActionFailure.policyChanged,
      );
    }
    var release = true;
    try {
      if (!sharePolicy.validate(permit).isValid) {
        return const TelemetrySessionActionResult.failure(
          TelemetrySessionActionFailure.policyChanged,
        );
      }
      final outcome = await store.deleteGroup(
        sessionId,
        checkpoint: (_) {
          if (readRecorderPhase() == TelemetryRecorderPhase.preparing ||
              readRecorderPhase() == TelemetryRecorderPhase.recording ||
              readRecorderPhase() == TelemetryRecorderPhase.finalizing ||
              !sharePolicy.validate(permit).isValid) {
            throw StateError('Telemetry delete authority changed');
          }
        },
      );
      return switch (outcome) {
        TelemetryDeleteOutcome.deleted =>
          const TelemetrySessionActionResult.success(),
        TelemetryDeleteOutcome.notFound =>
          const TelemetrySessionActionResult.failure(
            TelemetrySessionActionFailure.notFound,
          ),
        TelemetryDeleteOutcome.invalidId =>
          const TelemetrySessionActionResult.failure(
            TelemetrySessionActionFailure.invalidId,
          ),
        TelemetryDeleteOutcome.storageError =>
          const TelemetrySessionActionResult.failure(
            TelemetrySessionActionFailure.storage,
          ),
        TelemetryDeleteOutcome.uncontainedFailure => () {
          release = false;
          _retainRestartRequirement();
          return const TelemetrySessionActionResult.failure(
            TelemetrySessionActionFailure.restartRequired,
            userFacingMessage: telemetryArtifactRestartRequiredCopy,
          );
        }(),
      };
    } on StateError {
      return const TelemetrySessionActionResult.failure(
        TelemetrySessionActionFailure.policyChanged,
      );
    } finally {
      if (release) artifactGate.release(token);
    }
  }

  TelemetrySessionActionFailure? _guard() {
    if (_restartRequired || (readRestartRequired?.call() ?? false)) {
      return TelemetrySessionActionFailure.restartRequired;
    }
    final phase = readRecorderPhase();
    if (phase == TelemetryRecorderPhase.preparing ||
        phase == TelemetryRecorderPhase.recording ||
        phase == TelemetryRecorderPhase.finalizing) {
      return TelemetrySessionActionFailure.recorderActive;
    }
    final policy = sharePolicy;
    if (policy is DrivingInteractionSafetyPolicy) {
      return switch (telemetryHistoryAccess(
        recorderPhase: phase,
        safety: policy.current,
      )) {
        TelemetryHistoryAccess.permitted => null,
        TelemetryHistoryAccess.recorderActive =>
          TelemetrySessionActionFailure.recorderActive,
        TelemetryHistoryAccess.moving => TelemetrySessionActionFailure.moving,
        TelemetryHistoryAccess.speedUnknown =>
          TelemetrySessionActionFailure.speedUnknown,
        TelemetryHistoryAccess.background =>
          TelemetrySessionActionFailure.background,
      };
    }
    // Alternate policy implementations are frozen authoritatively at the
    // operation boundary. Avoid consuming a checkpoint during route gating.
    return null;
  }

  void _retainRestartRequirement() {
    _restartRequired = true;
    onRestartRequired?.call();
  }
}

final class TelemetryArtifactNoticeController extends Notifier<String?> {
  @override
  String? build() => null;

  void requireRestart() {
    state = telemetryArtifactRestartRequiredCopy;
  }
}

final telemetryArtifactNoticeProvider =
    NotifierProvider<TelemetryArtifactNoticeController, String?>(
      TelemetryArtifactNoticeController.new,
    );

final telemetrySessionLibraryServiceProvider =
    Provider<TelemetrySessionLibraryService>(
      (ref) => TelemetrySessionLibraryService(),
    );

bool telemetryRecorderPhaseBlocksLibraryReload(TelemetryRecorderPhase phase) =>
    phase == TelemetryRecorderPhase.preparing ||
    phase == TelemetryRecorderPhase.recording ||
    phase == TelemetryRecorderPhase.finalizing;

final telemetrySessionLibraryProvider = FutureProvider<TelemetrySessionLibrary>(
  (ref) {
    // History must refresh after a recording settles so Connect/Dashboard do
    // not keep a stale empty projection. Do **not** key the Future on
    // preparing → recording → finalizing: that used to launch
    // `_scanLibraryWorker` (full library validate + re-read) while the writer
    // was opening/appending. Explicit invalidations (delete, recovery,
    // pull-to-refresh) still apply.
    ref.listen<TelemetryRecorderProgress>(telemetryRecorderProgressProvider, (
      previous,
      next,
    ) {
      if (previous == null) return;
      final wasActive = telemetryRecorderPhaseBlocksLibraryReload(
        previous.state.phase,
      );
      final nowSettled = !telemetryRecorderPhaseBlocksLibraryReload(
        next.state.phase,
      );
      if (wasActive && nowSettled) {
        ref.invalidateSelf();
      }
    });
    return ref.watch(telemetrySessionLibraryServiceProvider).load();
  },
);

enum TelemetryStartupRecoveryPhase {
  idle,
  running,
  ready,
  retryable,
  restartRequired,
}

final class TelemetryStartupRecoveryItemSummary {
  const TelemetryStartupRecoveryItemSummary({
    required this.id,
    required this.classification,
    required this.valueCount,
    required this.statusCount,
    required this.gapCount,
    this.outcome,
  });

  final String id;
  final TelemetryRecoveryClassification classification;
  final int valueCount;
  final int statusCount;
  final int gapCount;
  final TelemetryRecoveryOutcome? outcome;
}

final class TelemetryStartupRecoveryState {
  const TelemetryStartupRecoveryState({
    required this.phase,
    this.items = const <TelemetryStartupRecoveryItemSummary>[],
  });

  final TelemetryStartupRecoveryPhase phase;
  final List<TelemetryStartupRecoveryItemSummary> items;

  bool get mayRetry => phase == TelemetryStartupRecoveryPhase.retryable;
}

final class TelemetryStartupRecoveryController
    extends Notifier<TelemetryStartupRecoveryState> {
  Future<TelemetryStartupRecoveryState>? _active;
  ArtifactOperationToken? _retainedToken;

  @override
  TelemetryStartupRecoveryState build() => const TelemetryStartupRecoveryState(
    phase: TelemetryStartupRecoveryPhase.idle,
  );

  Future<TelemetryStartupRecoveryState> initialize() {
    if (state.phase == TelemetryStartupRecoveryPhase.ready ||
        state.phase == TelemetryStartupRecoveryPhase.restartRequired ||
        _retainedToken != null) {
      return Future.value(state);
    }
    final active = _active;
    if (active != null) return active;
    final operation = _run();
    _active = operation;
    return operation.whenComplete(() {
      if (identical(_active, operation)) _active = null;
    });
  }

  Future<TelemetryStartupRecoveryState> retry() => initialize();

  Future<TelemetryStartupRecoveryState> _run() async {
    if (_recorderBlocks()) return _settleRetryable();
    final policy = ref.read(appSharePolicyProvider);
    final permit = policy.freeze();
    if (permit == null) return _settleRetryable();
    final gate = ref.read(artifactOperationGateProvider);
    final acquisition = gate.tryAcquire(
      'telemetry-startup-recovery',
      ArtifactOperation.recovery,
    );
    final token = acquisition.token;
    if (token == null) return _settleRetryable();
    state = const TelemetryStartupRecoveryState(
      phase: TelemetryStartupRecoveryPhase.running,
    );
    var release = true;
    try {
      _validate(policy, permit);
      final store = ref.read(telemetrySessionStoreProvider);
      final documentsPath = await store.recoveryDocumentsPath();
      _validate(policy, permit);
      final inspection = await Isolate.run(
        _telemetryRecoveryInspectionTask(documentsPath),
      );
      _validate(policy, permit);
      var summaries = <TelemetryStartupRecoveryItemSummary>[
        for (final item in inspection.items)
          TelemetryStartupRecoveryItemSummary(
            id: item.id,
            classification: item.classification,
            valueCount: item.valueCount,
            statusCount: item.statusCount,
            gapCount: item.gapCount,
          ),
      ];
      state = TelemetryStartupRecoveryState(
        phase: TelemetryStartupRecoveryPhase.running,
        items: List.unmodifiable(summaries),
      );
      final committed = await store.commitRecovery(
        inspection,
        checkpoint: (_) => _validate(policy, permit),
      );
      summaries = <TelemetryStartupRecoveryItemSummary>[
        for (final item in inspection.items)
          TelemetryStartupRecoveryItemSummary(
            id: item.id,
            classification: item.classification,
            valueCount: item.valueCount,
            statusCount: item.statusCount,
            gapCount: item.gapCount,
            outcome: committed.byId[item.id],
          ),
      ];
      if (committed.disposition ==
          TelemetryRecoveryRunDisposition.restartRequired) {
        release = false;
        _retainedToken = token;
        state = TelemetryStartupRecoveryState(
          phase: TelemetryStartupRecoveryPhase.restartRequired,
          items: List.unmodifiable(summaries),
        );
        return state;
      }
      if (committed.disposition == TelemetryRecoveryRunDisposition.retryable) {
        state = TelemetryStartupRecoveryState(
          phase: TelemetryStartupRecoveryPhase.retryable,
          items: List.unmodifiable(summaries),
        );
        return state;
      }
      ref.invalidate(telemetrySessionLibraryProvider);
      state = TelemetryStartupRecoveryState(
        phase: TelemetryStartupRecoveryPhase.ready,
        items: List.unmodifiable(summaries),
      );
      return state;
    } on Object {
      return _settleRetryable();
    } finally {
      if (release) gate.release(token);
    }
  }

  bool _recorderBlocks() {
    final phase = ref.read(telemetryRecorderProgressProvider).state.phase;
    return phase == TelemetryRecorderPhase.preparing ||
        phase == TelemetryRecorderPhase.recording ||
        phase == TelemetryRecorderPhase.finalizing;
  }

  void _validate(AppSharePolicy policy, SharePreparationPermit permit) {
    if (_recorderBlocks() || !policy.validate(permit).isValid) {
      throw StateError('Telemetry startup recovery authority changed');
    }
  }

  TelemetryStartupRecoveryState _settleRetryable() {
    state = TelemetryStartupRecoveryState(
      phase: TelemetryStartupRecoveryPhase.retryable,
      items: state.items,
    );
    return state;
  }
}

final telemetryStartupRecoveryProvider =
    NotifierProvider<
      TelemetryStartupRecoveryController,
      TelemetryStartupRecoveryState
    >(TelemetryStartupRecoveryController.new);

Future<TelemetryRecoveryInspection> Function() _telemetryRecoveryInspectionTask(
  String documentsPath,
) =>
    () => TelemetrySessionStore(
      documentsDirectory: () async => Directory(documentsPath),
    ).inspectRecovery();

final telemetrySessionReplayProvider =
    FutureProvider.family<TelemetryReplayResult, String>(
      (ref, sessionId) =>
          ref.watch(telemetrySessionLibraryServiceProvider).replay(sessionId),
    );

final telemetryHistoryAccessProvider = Provider<TelemetryHistoryAccess>((ref) {
  ref.watch(obdSessionProvider);
  ref.watch(telemetryProvider);
  final progress = ref.watch(telemetryRecorderProgressProvider);
  final policy = ref.watch(appSharePolicyProvider);
  return telemetryHistoryAccess(
    recorderPhase: progress.state.phase,
    safety: policy is DrivingInteractionSafetyPolicy ? policy.current : null,
  );
});

final telemetrySessionActionsProvider = Provider<TelemetrySessionActions>((
  ref,
) {
  final store = ref.watch(telemetrySessionStoreProvider);
  Future<Directory> documents() async =>
      Directory(await store.recoveryDocumentsPath());
  return TelemetrySessionActions(
    documentsDirectory: documents,
    store: store,
    shareEntryController: ref.watch(appShareEntryControllerProvider),
    artifactGate: ref.watch(artifactOperationGateProvider),
    sharePolicy: ref.watch(appSharePolicyProvider),
    readRecorderPhase: () =>
        ref.read(telemetryRecorderProgressProvider).state.phase,
    readRestartRequired: () =>
        ref.read(telemetryArtifactNoticeProvider) != null,
    onRestartRequired: () =>
        ref.read(telemetryArtifactNoticeProvider.notifier).requireRestart(),
  );
});

Future<Map<String, Object?>> _scanLibraryWorker(String documentsPath) async {
  final store = TelemetrySessionStore(
    documentsDirectory: () async => Directory(documentsPath),
  );
  final quota = await store.scanQuota();
  final index = await store.listSessions();
  final candidates = <Map<String, Object?>>[];
  for (final entry in index.sessions) {
    var elapsedOriginUs = 0;
    var elapsedOriginCaptured = false;
    var elapsedDurationUs = 0;
    final result = await store.reader.read(
      FileTelemetryChunkSource(entry.file),
      onLine: (line) {
        final event = line.canonicalEvent;
        if (event == null) return;
        if (!elapsedOriginCaptured) {
          elapsedOriginUs = event.elapsedUs;
          elapsedOriginCaptured = true;
        }
        final span = event.elapsedUs - elapsedOriginUs;
        if (span > elapsedDurationUs) elapsedDurationUs = span;
      },
    );
    final header = result.sessionHeader;
    final footer = result.sessionFooter;
    if (!result.isValid || header == null || footer == null) continue;
    candidates.add(<String, Object?>{
      'kind': 'session',
      'sortAt': header.startedAtUtc.toIso8601String(),
      'id': entry.id,
      'startedAtUtc': header.startedAtUtc.toIso8601String(),
      'endedAtUtc': footer.endedAtUtc.toIso8601String(),
      'source': header.source.name,
      'transport': header.transport.name,
      'protocol': header.protocol,
      'signalCount': header.signals.length,
      'valueCount': footer.valueCount,
      'statusCount': footer.statusCount,
      'gapCount': footer.gapCount,
      'terminalReason': footer.terminalReason.name,
      'bytes': await entry.file.length(),
      'elapsedDurationUs': elapsedDurationUs,
    });
  }
  for (final entry in index.damaged) {
    candidates.add(<String, Object?>{
      'kind': 'damaged',
      'sortAt': entry.filesystemModifiedAtUtc.toIso8601String(),
      'id': entry.id,
      'damageKind': entry.kind.name,
      'filesystemModifiedAtUtc': entry.filesystemModifiedAtUtc
          .toIso8601String(),
    });
  }
  candidates.sort(
    (left, right) =>
        (right['sortAt']! as String).compareTo(left['sortAt']! as String),
  );
  final selected = candidates.take(TelemetryQuota.groupLimit).toList();
  var encoded = utf8.encode(jsonEncode(selected)).length;
  while (encoded > 80 * 1024 && selected.isNotEmpty) {
    selected.removeLast();
    encoded = utf8.encode(jsonEncode(selected)).length;
  }
  return <String, Object?>{
    'entries': selected,
    'groupCount': quota.groupCount,
    'recognizedBytes': quota.recognizedBytes,
    'omittedCount': candidates.length - selected.length,
    'encodedProjectionBytes': encoded,
    'workerDebugName': Isolate.current.debugName ?? 'telemetry-library-worker',
  };
}

TelemetrySessionLibrary _decodeLibrary(Map<String, Object?> raw) {
  final sessions = <TelemetrySessionProjection>[];
  final damaged = <DamagedTelemetryProjection>[];
  for (final value in raw['entries']! as List<Object?>) {
    final item = value! as Map<Object?, Object?>;
    if (item['kind'] == 'session') {
      sessions.add(
        TelemetrySessionProjection(
          id: item['id']! as String,
          startedAtUtc: DateTime.parse(item['startedAtUtc']! as String),
          endedAtUtc: DateTime.parse(item['endedAtUtc']! as String),
          source: TelemetrySource.values.byName(item['source']! as String),
          transport: item['transport']! as String,
          protocol: item['protocol']! as String,
          signalCount: item['signalCount']! as int,
          valueCount: item['valueCount']! as int,
          statusCount: item['statusCount']! as int,
          gapCount: item['gapCount']! as int,
          terminalReason: TelemetryTerminalReason.values.byName(
            item['terminalReason']! as String,
          ),
          bytes: item['bytes']! as int,
          elapsedDurationUs: item['elapsedDurationUs']! as int,
        ),
      );
    } else {
      damaged.add(
        DamagedTelemetryProjection(
          id: item['id']! as String,
          kind: DamagedTelemetryKind.values.byName(
            item['damageKind']! as String,
          ),
          filesystemModifiedAtUtc: DateTime.parse(
            item['filesystemModifiedAtUtc']! as String,
          ),
        ),
      );
    }
  }
  return TelemetrySessionLibrary(
    sessions: List.unmodifiable(sessions),
    damaged: List.unmodifiable(damaged),
    groupCount: raw['groupCount']! as int,
    recognizedBytes: raw['recognizedBytes']! as int,
    omittedCount: raw['omittedCount']! as int,
    encodedProjectionBytes: raw['encodedProjectionBytes']! as int,
    workerDebugName: raw['workerDebugName']! as String,
  );
}

Future<Map<String, Object?>> _replayWorker(Map<String, Object?> request) async {
  final documentsPath = request['documentsPath']! as String;
  final sessionId = request['sessionId']! as String;
  final selected = (request['selectedPidIds']! as List<Object?>).cast<String>();
  final file = File('$documentsPath/telltale-telemetry/$sessionId.ndjson');
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    return <String, Object?>{'failure': 'notFound'};
  }
  final before = await file.stat();
  TelemetrySessionHeader? header;
  final accumulators = <String, TimelineDownsampleAccumulator>{};
  final available = <String, bool>{};
  final segment = <String, int>{};
  var invalidSelection = false;
  var elapsedOriginUs = 0;
  var elapsedOriginCaptured = false;
  var elapsedDurationUs = 0;
  const reader = TelemetrySessionReader();
  final result = await reader.read(
    FileTelemetryChunkSource(file),
    onLine: (line) {
      if (line.kind == TelemetryRecordLineKind.header) {
        header = TelemetrySessionCodec.decodeHeaderLine(
          utf8.encode('${jsonEncode(line.object)}\n'),
        ).value;
        if (header == null) return;
        final ids = header!.signals
            .map((signal) => signal.definition.id)
            .toSet();
        if (selected.any((id) => !ids.contains(id))) invalidSelection = true;
        final lanes = selected.isEmpty
            ? DerivedEstimates.defaultReplayLaneIds(
                header!.signals.map((signal) => signal.definition),
              )
            : selected;
        for (final id in lanes) {
          accumulators[id] = TimelineDownsampleAccumulator(
            maximumPrimitives: 1200,
          );
        }
        return;
      }
      if (line.kind != TelemetryRecordLineKind.value &&
          line.kind != TelemetryRecordLineKind.status) {
        return;
      }
      final canonicalEvent = line.canonicalEvent;
      if (canonicalEvent != null) {
        if (!elapsedOriginCaptured) {
          elapsedOriginUs = canonicalEvent.elapsedUs;
          elapsedOriginCaptured = true;
        }
        elapsedDurationUs = canonicalEvent.elapsedUs - elapsedOriginUs;
      }
      final id = line.object['pidId'];
      final rawElapsed = line.object['elapsedUs'];
      if (id is! String || rawElapsed is! int) return;
      if (!elapsedOriginCaptured) {
        elapsedOriginUs = rawElapsed;
        elapsedOriginCaptured = true;
      }
      final elapsed = rawElapsed - elapsedOriginUs;
      if (elapsed < 0) return;
      if (elapsed > elapsedDurationUs) elapsedDurationUs = elapsed;
      final accumulator = accumulators[id];
      if (accumulator == null) return;
      if (line.kind == TelemetryRecordLineKind.status) {
        final status = line.object['status'];
        accumulator.add(TimelineStatus(elapsedUs: elapsed, status: '$status'));
        if (available[id] ?? false) {
          accumulator.add(
            TimelineGap(elapsedUs: elapsed, gapId: '$id:${segment[id] ?? 0}'),
          );
          available[id] = false;
          segment[id] = (segment[id] ?? 0) + 1;
        }
      } else {
        final value = line.object['value'];
        if (value is! num) return;
        final quality = line.object['quality'];
        final breakBefore = !(available[id] ?? false) && (segment[id] ?? 0) > 0;
        accumulator.add(
          TimelineValue(
            elapsedUs: elapsed,
            value: value.toDouble(),
            segmentId: '$id:${segment[id] ?? 0}',
            breakBefore: breakBefore,
            quality: quality is String ? quality : null,
          ),
        );
        available[id] = true;
      }
    },
  );
  header = result.sessionHeader;
  final footer = result.sessionFooter;
  final afterType = await FileSystemEntity.type(file.path, followLinks: false);
  final after = await file.stat();
  if (!result.isValid ||
      header == null ||
      footer == null ||
      header!.sessionId != sessionId ||
      invalidSelection ||
      afterType != FileSystemEntityType.file ||
      before.size != after.size ||
      before.modified != after.modified ||
      before.changed != after.changed) {
    return <String, Object?>{
      'failure': invalidSelection ? 'invalidSelection' : 'damaged',
    };
  }
  final definitions = <String, TelemetrySignalDefinition>{
    for (final signal in header!.signals)
      signal.definition.id: signal.definition,
  };
  final lanes = <Map<String, Object?>>[];
  for (final entry in accumulators.entries) {
    final definition = definitions[entry.key]!;
    lanes.add(<String, Object?>{
      'pidId': entry.key,
      'name': definition.name,
      'unit': definition.unit,
      'primitives': entry.value.finish().map(_encodePrimitive).toList(),
    });
  }
  return <String, Object?>{
    'sessionId': sessionId,
    'startedAtUtc': header!.startedAtUtc.toIso8601String(),
    'endedAtUtc': footer.endedAtUtc.toIso8601String(),
    'source': header!.source.name,
    'transport': header!.transport.name,
    'protocol': header!.protocol,
    'signalCount': header!.signals.length,
    'valueCount': footer.valueCount,
    'statusCount': footer.statusCount,
    'gapCount': footer.gapCount,
    'terminalReason': footer.terminalReason.name,
    'elapsedDurationUs': elapsedDurationUs,
    'lanes': lanes,
    'workerDebugName': Isolate.current.debugName ?? 'telemetry-replay-worker',
  };
}

Map<String, Object?> _encodePrimitive(TimelinePrimitive primitive) =>
    switch (primitive) {
      TimelineValue value => <String, Object?>{
        'kind': 'value',
        'elapsedUs': value.elapsedUs,
        'value': value.value,
        'breakBefore': value.breakBefore,
        'omittedGapCountBefore': value.omittedGapCountBefore,
        if (value.quality != null && value.quality!.isNotEmpty)
          'quality': value.quality,
      },
      TimelineStatus status => <String, Object?>{
        'kind': 'status',
        'elapsedUs': status.elapsedUs,
        'status': status.status,
      },
      TimelineGap gap => <String, Object?>{
        'kind': 'gap',
        'elapsedUs': gap.elapsedUs,
        'omittedGapCountBefore': gap.omittedGapCount,
      },
    };

TelemetryReplayResult _decodeReplay(Map<String, Object?> raw) {
  final failure = raw['failure'];
  if (failure != null) {
    return TelemetryReplayResult.failure(
      TelemetryReplayFailure.values.byName(failure as String),
    );
  }
  final lanes = (raw['lanes']! as List<Object?>)
      .map((value) {
        final lane = value! as Map<Object?, Object?>;
        return TelemetryReplayLane(
          pidId: lane['pidId']! as String,
          name: lane['name']! as String,
          unit: lane['unit']! as String,
          primitives: List.unmodifiable(
            (lane['primitives']! as List<Object?>).map((rawPrimitive) {
              final primitive = rawPrimitive! as Map<Object?, Object?>;
              return TelemetryReplayPrimitive(
                kind: TelemetryReplayPrimitiveKind.values.byName(
                  primitive['kind']! as String,
                ),
                elapsedUs: primitive['elapsedUs']! as int,
                value: (primitive['value'] as num?)?.toDouble(),
                status: primitive['status'] as String?,
                breakBefore: primitive['breakBefore'] as bool? ?? false,
                omittedGapCountBefore:
                    primitive['omittedGapCountBefore'] as int? ?? 0,
                quality: primitive['quality'] as String?,
              );
            }),
          ),
        );
      })
      .toList(growable: false);
  return TelemetryReplayResult.success(
    TelemetrySessionReplay(
      sessionId: raw['sessionId']! as String,
      startedAtUtc: DateTime.parse(raw['startedAtUtc']! as String),
      endedAtUtc: DateTime.parse(raw['endedAtUtc']! as String),
      source: TelemetrySource.values.byName(raw['source']! as String),
      transport: raw['transport']! as String,
      protocol: raw['protocol']! as String,
      signalCount: raw['signalCount']! as int,
      valueCount: raw['valueCount']! as int,
      statusCount: raw['statusCount']! as int,
      gapCount: raw['gapCount']! as int,
      terminalReason: TelemetryTerminalReason.values.byName(
        raw['terminalReason']! as String,
      ),
      elapsedDurationUs: raw['elapsedDurationUs']! as int,
      lanes: List.unmodifiable(lanes),
      workerDebugName: raw['workerDebugName']! as String,
    ),
  );
}
