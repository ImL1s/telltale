library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../state/telemetry_sessions.dart';
import '../../../telemetry/session/telemetry_session_store.dart';
import '../../screens/telemetry/telemetry_sessions_screen.dart';
import '../panel.dart';

/// Reports durable startup recovery without implying that damaged data was
/// repaired or that a physical vehicle was involved.
class TelemetryStartupRecoveryNotice extends ConsumerStatefulWidget {
  const TelemetryStartupRecoveryNotice({super.key});

  @override
  ConsumerState<TelemetryStartupRecoveryNotice> createState() =>
      _TelemetryStartupRecoveryNoticeState();
}

class _TelemetryStartupRecoveryNoticeState
    extends ConsumerState<TelemetryStartupRecoveryNotice> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    final recovery = ref.watch(telemetryStartupRecoveryProvider);
    if (_dismissed ||
        recovery.phase != TelemetryStartupRecoveryPhase.ready ||
        recovery.items.isEmpty) {
      return const SizedBox.shrink();
    }

    final installed = recovery.items.where((item) {
      return item.outcome == TelemetryRecoveryOutcome.recoveredAndInstalled ||
          item.outcome == TelemetryRecoveryOutcome.installedUnchanged;
    }).length;
    final cleaned = recovery.items
        .where(
          (item) => item.outcome == TelemetryRecoveryOutcome.deletedZeroValue,
        )
        .length;
    final damaged = recovery.items.where((item) {
      return item.outcome == TelemetryRecoveryOutcome.corruptDeleteOnly ||
          item.outcome == TelemetryRecoveryOutcome.collisionDeleteOnly;
    }).length;
    final hasHistory = installed + damaged > 0;
    final access = ref.watch(telemetryHistoryAccessProvider);
    final mayOpen = hasHistory && access == TelemetryHistoryAccess.permitted;
    final details = <String>[
      if (installed > 0) '$installed 組中斷紀錄已完成安全封存',
      if (cleaned > 0) '$cleaned 組沒有有效值的未完成檔已清理',
      if (damaged > 0) '$damaged 組損壞或衝突檔未自動修改',
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.lg, 0, Spacing.lg, Spacing.lg),
      child: Panel(
        accent: damaged > 0 ? context.palette.warning : context.palette.success,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  damaged > 0
                      ? Icons.warning_amber_rounded
                      : Icons.restore_outlined,
                  color: damaged > 0
                      ? context.palette.warning
                      : context.palette.success,
                ),
                const SizedBox(width: Spacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('啟動紀錄檢查已完成', style: context.texts.titleMedium),
                      const SizedBox(height: Spacing.xs),
                      Text(details.join('。'), style: context.texts.bodySmall),
                      if (damaged > 0) ...[
                        const SizedBox(height: Spacing.xs),
                        Text(
                          '損壞內容不會用於回放或匯出，只能在安全狀態下手動刪除。',
                          style: context.texts.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: Spacing.md),
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.sm,
              children: [
                if (hasHistory)
                  OutlinedButton.icon(
                    key: const ValueKey('telemetry-recovery-open-history'),
                    onPressed: mayOpen
                        ? () => context.push(TelemetrySessionsScreen.path)
                        : null,
                    icon: const Icon(Icons.history, size: 18),
                    label: const Text('查看本機紀錄'),
                  ),
                TextButton(
                  key: const ValueKey('telemetry-recovery-dismiss'),
                  onPressed: () => setState(() => _dismissed = true),
                  child: const Text('關閉提示'),
                ),
              ],
            ),
            if (hasHistory && !mayOpen) ...[
              const SizedBox(height: Spacing.xs),
              Text(
                access.message!,
                style: context.texts.bodySmall?.copyWith(
                  color: context.palette.warning,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
