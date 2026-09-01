library;

import '../../../state/telemetry_recorder.dart';
import '../../../telemetry/session/telemetry_recorder.dart';
import '../../../telemetry/session/telemetry_session.dart';

String telemetryStatusLabel(TelemetryStatus status) => switch (status) {
  TelemetryStatus.stale => '資料已過期',
  TelemetryStatus.unsupported => '目前引擎控制器已確認不支援',
  TelemetryStatus.noAnswer => '無回應，稍後重試',
  TelemetryStatus.formulaError => '公式錯誤',
  TelemetryStatus.busError => '匯流排錯誤',
  TelemetryStatus.headerMismatch => '標頭不符目前匯流排',
  TelemetryStatus.unsafeServiceRefusal => '此服務不是唯讀查詢，已停止發送',
};

String telemetryTerminalReasonLabel(TelemetryTerminalReason reason) =>
    switch (reason) {
      TelemetryTerminalReason.user => '已手動停止',
      TelemetryTerminalReason.disconnect => '連線中斷後已停止',
      TelemetryTerminalReason.sessionReplacement => '連線工作階段已更換',
      TelemetryTerminalReason.background => 'App 進入背景後已停止',
      TelemetryTerminalReason.durationLimit => '已達 60 分鐘上限',
      TelemetryTerminalReason.sessionSizeLimit => '已達單筆紀錄容量上限',
      TelemetryTerminalReason.librarySizeLimit => '本機紀錄空間已滿',
      TelemetryTerminalReason.storageBackpressure => '儲存速度不足',
      TelemetryTerminalReason.configurationChanged => 'PID 設定已變更',
      TelemetryTerminalReason.storageFailure => '儲存失敗',
      TelemetryTerminalReason.recoveredAfterInterruption => '上次中斷後已復原',
    };

String telemetryStartOutcomeLabel(TelemetryStartOutcome outcome) =>
    switch (outcome) {
      TelemetryStartOutcome.recording => '已開始紀錄',
      TelemetryStartOutcome.disconnected => '請先連線再開始紀錄',
      TelemetryStartOutcome.background => '請回到 App 前景再開始紀錄',
      TelemetryStartOutcome.speedUnknown ||
      TelemetryStartOutcome.startInvalidatedSpeedUnknown => '無法確認車輛已停止；請先中斷連線',
      TelemetryStartOutcome.moving ||
      TelemetryStartOutcome.startInvalidatedMoving => '請停車後操作',
      TelemetryStartOutcome.startInvalidatedBackground => 'App 已進入背景，未開始紀錄',
      TelemetryStartOutcome.startInvalidatedDisconnect => '連線已中斷，未開始紀錄',
      TelemetryStartOutcome.startInvalidatedSessionReplacement =>
        '連線工作階段已更換，未開始紀錄',
      TelemetryStartOutcome.libraryGroupLimit => '本機紀錄已達 20 組上限，請先匯出或刪除',
      TelemetryStartOutcome.libraryByteLimit ||
      TelemetryStartOutcome.noRoomForValue => '本機紀錄空間不足，請先匯出或刪除',
      TelemetryStartOutcome.invalidConfiguration => 'PID 設定無法安全紀錄，請檢查定義',
      TelemetryStartOutcome.idCollision ||
      TelemetryStartOutcome.storageFailure => '無法建立紀錄檔',
      TelemetryStartOutcome.restartRequired => '啟動清理未完成；請重新啟動 App 以修復紀錄',
      TelemetryStartOutcome.startBusy ||
      TelemetryStartOutcome.artifactBusy ||
      TelemetryStartOutcome.pidLocked => '另一個紀錄或檔案作業尚未完成',
    };

const telemetryPendingOwnerRecoveryCopy = '作業仍由目前程序持有；若持續停在此狀態，請完全關閉並重新啟動 App';

/// Persistent recovery guidance for recorder work that cannot safely be
/// cancelled or released by a UI timeout.
String? telemetryRecorderRecoveryLabel(
  TelemetryRecorderState state, {
  bool startNeedsRestart = false,
}) {
  if (state.phase == TelemetryRecorderPhase.preparing ||
      state.phase == TelemetryRecorderPhase.finalizing) {
    return telemetryPendingOwnerRecoveryCopy;
  }
  if (!state.requiresRestart && !startNeedsRestart) return null;
  return state.phase == TelemetryRecorderPhase.preparing
      ? '啟動清理未完成；請重新啟動 App 以修復紀錄'
      : '儲存作業未完成；請重新啟動 App 以修復紀錄';
}

String formatTelemetryDuration(int elapsedUs) {
  final seconds = elapsedUs < 0
      ? 0
      : elapsedUs ~/ Duration.microsecondsPerSecond;
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remainder = seconds % 60;
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${remainder.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:'
      '${remainder.toString().padLeft(2, '0')}';
}

String formatTelemetryBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
}
