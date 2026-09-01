library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../state/obd_session.dart';
import '../../../state/pid_registry.dart';
import '../../../state/telemetry_recorder.dart';
import '../../../state/telemetry_runtime.dart';
import '../../../state/telemetry_sessions.dart';
import '../../../telemetry/session/telemetry_recorder.dart';
import '../../widgets/panel.dart';
import 'telemetry_status_copy.dart';

class TelemetryRecorderPanel extends ConsumerStatefulWidget {
  const TelemetryRecorderPanel({super.key});

  @override
  ConsumerState<TelemetryRecorderPanel> createState() =>
      _TelemetryRecorderPanelState();
}

class _TelemetryRecorderPanelState
    extends ConsumerState<TelemetryRecorderPanel> {
  bool _starting = false;
  bool _startNeedsRestart = false;

  @override
  Widget build(BuildContext context) {
    // These watches intentionally drive safety-copy refreshes. The environment
    // itself is a stable authority and reads these values synchronously.
    ref.watch(obdSessionProvider);
    ref.watch(telemetryProvider);
    final activePids = ref.watch(activePidsProvider);
    final evidence = ref.watch(currentTelemetryConnectionEvidenceProvider);
    final progress = ref.watch(telemetryRecorderProgressProvider);
    final environment = ref.read(liveTelemetryStartEnvironmentProvider);
    final safety = environment.snapshot('recorderPanel');
    final state = progress.state;
    final phase = state.phase;
    final recoveryCopy = telemetryRecorderRecoveryLabel(
      state,
      startNeedsRestart: _startNeedsRestart,
    );
    final historyAccess = ref.watch(telemetryHistoryAccessProvider);
    final isTransition =
        phase == TelemetryRecorderPhase.preparing ||
        phase == TelemetryRecorderPhase.recording ||
        phase == TelemetryRecorderPhase.finalizing;
    final canOfferStart =
        !isTransition && !state.requiresRestart && !_startNeedsRestart;
    final blockReason = _startBlockReason(
      evidencePresent: evidence != null,
      foreground: safety.foreground,
      speedKnown: safety.speedKnown,
      speedKmh: safety.speedKmh,
      activeCount: activePids.length,
    );
    final canStart = canOfferStart && blockReason == null && !_starting;
    final accent = switch (phase) {
      TelemetryRecorderPhase.recording => context.palette.danger,
      TelemetryRecorderPhase.preparing ||
      TelemetryRecorderPhase.finalizing => context.palette.warning,
      TelemetryRecorderPhase.completed => context.palette.success,
      TelemetryRecorderPhase.failed => context.palette.danger,
      TelemetryRecorderPhase.idle => context.palette.accent,
    };

    return Panel(
      accent: accent,
      isActive: isTransition,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            liveRegion:
                phase == TelemetryRecorderPhase.completed ||
                phase == TelemetryRecorderPhase.failed,
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: Spacing.md,
              runSpacing: Spacing.sm,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_phaseIcon(phase), size: 20, color: accent),
                    const SizedBox(width: Spacing.sm),
                    Flexible(
                      child: Text(
                        _phaseTitle(progress),
                        style: context.texts.titleMedium,
                      ),
                    ),
                  ],
                ),
                if (phase == TelemetryRecorderPhase.recording ||
                    phase == TelemetryRecorderPhase.finalizing)
                  Text(
                    formatTelemetryDuration(progress.elapsedUs),
                    style: AppTypography.readout(context.palette, 22),
                  ),
              ],
            ),
          ),
          if (phase == TelemetryRecorderPhase.recording ||
              phase == TelemetryRecorderPhase.finalizing ||
              phase == TelemetryRecorderPhase.completed ||
              phase == TelemetryRecorderPhase.failed) ...[
            const SizedBox(height: Spacing.md),
            _RecorderMetrics(
              valueCount: state.valueCount,
              statusCount: state.statusCount,
              gapCount: state.gapCount,
              bytesLabel: _bytesLabel(progress),
            ),
          ],
          if (state.terminalReason case final reason?) ...[
            const SizedBox(height: Spacing.md),
            Text(
              telemetryTerminalReasonLabel(reason),
              style: context.texts.bodyMedium,
            ),
          ],
          if (recoveryCopy != null) ...[
            const SizedBox(height: Spacing.md),
            Text(
              recoveryCopy,
              style: context.texts.bodyMedium?.copyWith(
                color: context.palette.danger,
              ),
            ),
          ],
          if ((phase == TelemetryRecorderPhase.completed ||
                  phase == TelemetryRecorderPhase.failed) &&
              !state.requiresRestart) ...[
            const SizedBox(height: Spacing.md),
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.sm,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('telemetry-open-history'),
                  onPressed: historyAccess == TelemetryHistoryAccess.permitted
                      ? () => context.push('/sessions')
                      : null,
                  icon: const Icon(Icons.history, size: 18),
                  label: const Text('查看本機紀錄'),
                ),
                TextButton(
                  key: const ValueKey('telemetry-dismiss-outcome'),
                  onPressed: () => ref
                      .read(telemetryRecorderControllerProvider)
                      .dismissTerminalOutcome(),
                  child: const Text('關閉提示'),
                ),
              ],
            ),
            if (historyAccess != TelemetryHistoryAccess.permitted) ...[
              const SizedBox(height: Spacing.xs),
              Text(
                historyAccess.message!,
                style: context.texts.bodySmall?.copyWith(
                  color: context.palette.warning,
                ),
              ),
            ],
          ],
          const SizedBox(height: Spacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.lock_outline,
                size: 18,
                color: context.palette.textTertiary,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  '只紀錄已啟用的 OBD 訊號，不含位置、VIN 或帳號資料。'
                  '趨勢圖最多顯示 4 項，錄製會保留全部 ${activePids.length} 項已啟用訊號。',
                  style: context.texts.bodySmall,
                ),
              ),
            ],
          ),
          if (phase == TelemetryRecorderPhase.idle || canOfferStart) ...[
            if (blockReason != null) ...[
              const SizedBox(height: Spacing.sm),
              Text(
                blockReason,
                style: context.texts.bodySmall?.copyWith(
                  color: context.palette.warning,
                ),
              ),
            ],
            const SizedBox(height: Spacing.md),
            FilledButton.icon(
              key: const ValueKey('telemetry-start'),
              onPressed: canStart ? _start : null,
              icon: _starting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.fiber_manual_record, size: 18),
              label: Text(_starting ? '正在開始' : '開始紀錄'),
            ),
          ] else if (phase == TelemetryRecorderPhase.recording) ...[
            const SizedBox(height: Spacing.md),
            FilledButton.icon(
              key: const ValueKey('telemetry-stop'),
              onPressed: () =>
                  ref.read(telemetryRecorderControllerProvider).stop(),
              style: FilledButton.styleFrom(
                backgroundColor: context.palette.danger,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.stop, size: 18),
              label: const Text('停止並儲存'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _start() async {
    final evidence = ref.read(currentTelemetryConnectionEvidenceProvider);
    if (evidence == null) return;
    setState(() {
      _starting = true;
      _startNeedsRestart = false;
    });
    final result = await ref
        .read(telemetryRecorderControllerProvider)
        .start(
          TelemetryStartRequest(
            source: evidence.source,
            transport: evidence.transport,
            protocol: evidence.protocol,
            activePids: ref.read(activePidsProvider),
          ),
        );
    if (!mounted) return;
    setState(() {
      _starting = false;
      _startNeedsRestart =
          result.outcome == TelemetryStartOutcome.restartRequired;
    });
    if (result.outcome != TelemetryStartOutcome.recording) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(telemetryStartOutcomeLabel(result.outcome))),
      );
    }
  }

  static String? _startBlockReason({
    required bool evidencePresent,
    required bool foreground,
    required bool speedKnown,
    required double speedKmh,
    required int activeCount,
  }) {
    if (!evidencePresent) return '請先連線再開始紀錄';
    if (!foreground) return '請回到 App 前景再開始紀錄';
    if (!speedKnown || !speedKmh.isFinite) {
      return '無法確認車輛已停止；請先中斷連線';
    }
    if (speedKmh > 5) return '請停車後操作';
    if (activeCount == 0) return '請先啟用至少一項 PID';
    if (activeCount > 32) return '錄製最多包含 32 項訊號，請先減少 PID';
    return null;
  }

  static String _phaseTitle(TelemetryRecorderProgress progress) {
    final state = progress.state;
    return switch (state.phase) {
      TelemetryRecorderPhase.idle => '前景本機紀錄',
      TelemetryRecorderPhase.preparing => '正在準備錄製',
      TelemetryRecorderPhase.recording =>
        state.valueCount == 0 ? '準備錄製' : '紀錄中',
      TelemetryRecorderPhase.finalizing => '正在儲存紀錄',
      TelemetryRecorderPhase.completed => '紀錄已儲存',
      TelemetryRecorderPhase.failed => '紀錄儲存失敗',
    };
  }

  static IconData _phaseIcon(TelemetryRecorderPhase phase) => switch (phase) {
    TelemetryRecorderPhase.idle => Icons.fiber_manual_record_outlined,
    TelemetryRecorderPhase.preparing => Icons.hourglass_top,
    TelemetryRecorderPhase.recording => Icons.fiber_manual_record,
    TelemetryRecorderPhase.finalizing => Icons.save_outlined,
    TelemetryRecorderPhase.completed => Icons.check_circle_outline,
    TelemetryRecorderPhase.failed => Icons.error_outline,
  };

  static String _bytesLabel(TelemetryRecorderProgress progress) {
    final used = formatTelemetryBytes(progress.bytesBeforeFooter);
    final limit = progress.effectiveSessionLimit;
    return limit == null ? used : '$used / ${formatTelemetryBytes(limit)}';
  }
}

class _RecorderMetrics extends StatelessWidget {
  const _RecorderMetrics({
    required this.valueCount,
    required this.statusCount,
    required this.gapCount,
    required this.bytesLabel,
  });

  final int valueCount;
  final int statusCount;
  final int gapCount;
  final String bytesLabel;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final singleColumn = constraints.maxWidth < 520 || scale > 1.3;
        final width = singleColumn
            ? constraints.maxWidth
            : (constraints.maxWidth - Spacing.sm) / 2;
        return Wrap(
          spacing: Spacing.sm,
          runSpacing: Spacing.sm,
          children: [
            SizedBox(
              width: width,
              child: _RecorderMetric(
                label: '$valueCount 筆有效值',
                icon: Icons.data_usage,
                color: context.palette.accent,
              ),
            ),
            SizedBox(
              width: width,
              child: _RecorderMetric(
                label: '$statusCount 個狀態',
                icon: Icons.info_outline,
                color: context.palette.textSecondary,
              ),
            ),
            SizedBox(
              width: width,
              child: _RecorderMetric(
                label: '$gapCount 個缺口',
                icon: Icons.link_off,
                color: gapCount == 0
                    ? context.palette.textSecondary
                    : context.palette.warning,
              ),
            ),
            SizedBox(
              width: width,
              child: _RecorderMetric(
                label: bytesLabel,
                icon: Icons.storage_outlined,
                color: context.palette.textSecondary,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _RecorderMetric extends StatelessWidget {
  const _RecorderMetric({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      decoration: BoxDecoration(
        color: context.palette.surfaceAlt,
        border: Border.all(color: context.palette.hairline),
        borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: Spacing.sm),
          Expanded(child: Text(label, style: context.texts.labelMedium)),
        ],
      ),
    );
  }
}
