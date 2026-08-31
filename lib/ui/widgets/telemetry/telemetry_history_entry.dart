library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../state/telemetry_sessions.dart';
import '../../screens/telemetry/telemetry_sessions_screen.dart';
import '../panel.dart';

/// Offline entry to saved sessions on the connection screen.
///
/// The index is built off-isolate. Until it proves that a recognized telemetry
/// group exists, this renders nothing rather than promising data that may not
/// be readable. A recorder/safety denial remains visible but cannot mount the
/// History route.
class TelemetryHistoryEntry extends ConsumerWidget {
  const TelemetryHistoryEntry({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The access decision must dominate the filesystem-backed provider. During
    // recording/finalization (and while driving) even mounting the library is
    // forbidden: its scan is work the user is not currently allowed to start.
    final access = ref.watch(telemetryHistoryAccessProvider);
    if (access != TelemetryHistoryAccess.permitted) {
      return _HistoryPanel(access: access);
    }
    final library = ref.watch(telemetrySessionLibraryProvider);
    final data = library.value;
    if (data == null || (data.sessions.isEmpty && data.damaged.isEmpty)) {
      return const SizedBox.shrink();
    }
    return _HistoryPanel(access: access, count: data.groupCount);
  }
}

class _HistoryPanel extends StatelessWidget {
  const _HistoryPanel({required this.access, this.count});

  final TelemetryHistoryAccess access;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final permitted = access == TelemetryHistoryAccess.permitted;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.lg, 0, Spacing.lg, Spacing.lg),
      child: Panel(
        onTap: permitted
            ? () => context.push(TelemetrySessionsScreen.path)
            : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              const Icon(Icons.history),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('本機紀錄', style: context.texts.titleMedium),
                    const SizedBox(height: Spacing.xs),
                    Text(
                      permitted ? '已儲存 $count 組，可離線回放與匯出' : access.message!,
                      style: context.texts.bodySmall,
                    ),
                  ],
                ),
              ),
              if (permitted) const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}
