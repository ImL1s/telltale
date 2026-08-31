library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../state/obd_session.dart';
import '../../../state/pid_registry.dart';
import '../../../state/telemetry_recorder.dart';
import '../../../state/telemetry_runtime.dart';
import '../../../state/telemetry_trends.dart';
import '../../../telemetry/session/telemetry_recorder.dart';
import '../../../telemetry/session/telemetry_session.dart';
import '../../widgets/panel.dart';
import '../../widgets/telemetry/live_trend_card.dart';
import '../../widgets/telemetry/telemetry_lane_selector.dart';

class TelemetryWorkspace extends ConsumerWidget {
  const TelemetryWorkspace({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(obdSessionProvider);
    ref.watch(telemetryProvider);
    final activePids = ref.watch(activePidsProvider);
    final trends = ref.watch(telemetryTrendsProvider);
    final evidence = ref.watch(currentTelemetryConnectionEvidenceProvider);
    final progress = ref.watch(telemetryRecorderProgressProvider);
    final safety = ref
        .read(liveTelemetryStartEnvironmentProvider)
        .snapshot('trendSelector');
    final laneSelectionBlock = _laneSelectionBlock(
      connected: evidence != null,
      speedKnown: safety.speedKnown,
      speedKmh: safety.speedKmh,
    );
    final recordingLabel = switch (progress.state.phase) {
      TelemetryRecorderPhase.preparing => '正在準備錄製',
      TelemetryRecorderPhase.recording => '正在錄製',
      TelemetryRecorderPhase.finalizing => '正在儲存紀錄',
      _ => '未錄製',
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.lg, 0, Spacing.lg, Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (evidence == null) ...[
            const StatusPill(
              label: '目前未連線',
              icon: Icons.link_off,
              tone: StatusTone.neutral,
            ),
            const SizedBox(height: Spacing.md),
          ] else if (evidence.source == TelemetrySource.demo) ...[
            const StatusPill(
              label: '內建模擬資料',
              icon: Icons.science_outlined,
              tone: StatusTone.accent,
            ),
            const SizedBox(height: Spacing.md),
          ] else if (evidence.source == TelemetrySource.simulatedRig) ...[
            const StatusPill(
              label: '測試馬具資料',
              icon: Icons.developer_board_outlined,
              tone: StatusTone.warn,
            ),
            const SizedBox(height: Spacing.md),
          ],
          const SectionHeading('趨勢訊號'),
          TelemetryLaneSelector(
            activePids: activePids,
            selectedIds: trends.selectedIds,
            enabled: laneSelectionBlock == null,
            disabledReason: laneSelectionBlock,
          ),
          const SizedBox(height: Spacing.lg),
          if (activePids.isEmpty)
            const SizedBox(
              height: 300,
              child: EmptyState(
                icon: Icons.tune,
                title: '沒有可用的趨勢訊號',
                message: '先到 PID 頁面啟用想要監看的訊號。',
              ),
            )
          else if (trends.selectedIds.isEmpty)
            const SizedBox(
              height: 300,
              child: EmptyState(
                icon: Icons.show_chart,
                title: '選擇趨勢訊號',
                message: '最多可以比較 4 項訊號，不會改變已啟用的 PID 輪詢。',
              ),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final textScale =
                    MediaQuery.textScalerOf(context).scale(14) / 14;
                final twoColumns =
                    constraints.maxWidth >= 760 && textScale <= 1.3;
                final cardWidth = twoColumns
                    ? (constraints.maxWidth - Spacing.md) / 2
                    : constraints.maxWidth;
                return Wrap(
                  spacing: Spacing.md,
                  runSpacing: Spacing.md,
                  children: [
                    for (final id in trends.selectedIds)
                      if (trends.lanes[id] case final lane?)
                        SizedBox(
                          key: ValueKey('telemetry-lane-$id'),
                          width: cardWidth,
                          child: LiveTrendCard(
                            lane: lane,
                            windowEndElapsedUs: trends.windowEndElapsedUs,
                            recordingLabel: recordingLabel,
                            isConnected: evidence != null,
                          ),
                        ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }

  static String? _laneSelectionBlock({
    required bool connected,
    required bool speedKnown,
    required double speedKmh,
  }) {
    if (!connected) return null;
    if (!speedKnown || !speedKmh.isFinite) {
      return '無法確認車輛已停止；請先中斷連線';
    }
    if (speedKmh > 5) return '請停車後操作';
    return null;
  }
}
