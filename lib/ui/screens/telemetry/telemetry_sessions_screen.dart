library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../state/telemetry_sessions.dart';
import '../../widgets/panel.dart';
import '../../widgets/telemetry/telemetry_status_copy.dart';

class TelemetrySessionsScreen extends ConsumerWidget {
  const TelemetrySessionsScreen({super.key});

  static const path = '/sessions';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(telemetryHistoryAccessProvider);
    if (access != TelemetryHistoryAccess.permitted) {
      return Scaffold(
        appBar: AppBar(title: const Text('本機紀錄')),
        body: Center(child: Text(access.message!)),
      );
    }
    final library = ref.watch(telemetrySessionLibraryProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('本機紀錄'),
        actions: [
          IconButton(
            tooltip: '重新載入',
            onPressed: () => ref.invalidate(telemetrySessionLibraryProvider),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: library.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => Center(
          child: FilledButton(
            onPressed: () => ref.invalidate(telemetrySessionLibraryProvider),
            child: const Text('無法載入，請重試'),
          ),
        ),
        data: (data) => _LibraryBody(data: data),
      ),
    );
  }
}

class _LibraryBody extends StatelessWidget {
  const _LibraryBody({required this.data});

  final TelemetrySessionLibrary data;

  @override
  Widget build(BuildContext context) {
    final usedMiB = data.recognizedBytes / (1024 * 1024);
    if (data.sessions.isEmpty && data.damaged.isEmpty) {
      return const Center(child: Text('還沒有本機紀錄\n連線後開始錄製'));
    }
    return ListView(
      padding: const EdgeInsets.all(Spacing.lg),
      children: [
        Semantics(
          label:
              '本機儲存 ${data.groupCount} / 20 組，${usedMiB.toStringAsFixed(1)} / 100 MiB',
          child: Panel(
            child: Wrap(
              spacing: Spacing.lg,
              runSpacing: Spacing.sm,
              children: [
                Text('${data.groupCount}/20 組'),
                Text('${usedMiB.toStringAsFixed(1)}/100 MiB'),
                if (data.omittedCount > 0) Text('另有 ${data.omittedCount} 組未顯示'),
              ],
            ),
          ),
        ),
        if (data.sessions.isNotEmpty) ...[
          const SizedBox(height: Spacing.lg),
          const SectionHeading('可回放的紀錄'),
          for (final session in data.sessions) ...[
            _SessionTile(session: session),
            const SizedBox(height: Spacing.sm),
          ],
        ],
        if (data.damaged.isNotEmpty) ...[
          const SizedBox(height: Spacing.lg),
          const SectionHeading('損壞的紀錄檔'),
          for (final artifact in data.damaged) ...[
            _DamagedTile(artifact: artifact),
            const SizedBox(height: Spacing.sm),
          ],
        ],
      ],
    );
  }
}

class _DamagedTile extends ConsumerWidget {
  const _DamagedTile({required this.artifact});

  final DamagedTelemetryProjection artifact;

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('刪除損壞紀錄？'),
        content: Text(
          '將刪除 ${artifact.id}（檔案時間 '
          '${_localTime(artifact.filesystemModifiedAtUtc)}）。刪除後無法復原。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('刪除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final result = await ref
        .read(telemetrySessionActionsProvider)
        .delete(artifact.id, confirmed: true);
    if (!context.mounted) return;
    if (result.isSuccess) {
      ref.invalidate(telemetrySessionLibraryProvider);
    } else {
      if (result.failure != TelemetrySessionActionFailure.restartRequired) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('刪除未完成：${result.message}')));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => Panel(
    child: ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.warning_amber_rounded),
      title: Text(artifact.id),
      subtitle: Text(
        '${artifact.kind == DamagedTelemetryKind.collision ? '同一識別碼同時存在完成與未完成檔，未選擇任何一份' : '紀錄損壞，無法安全讀取'}\n'
        '檔案時間 ${_localTime(artifact.filesystemModifiedAtUtc)}',
      ),
      trailing: IconButton(
        tooltip: '刪除損壞紀錄',
        onPressed: () => _delete(context, ref),
        icon: const Icon(Icons.delete_outline),
      ),
    ),
  );
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session});

  final TelemetrySessionProjection session;

  @override
  Widget build(BuildContext context) => Panel(
    onTap: () => context.push('${TelemetrySessionsScreen.path}/${session.id}'),
    child: ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(_localTime(session.startedAtUtc)),
      subtitle: Text(
        '${session.sourceLabel} · ${session.transport} · ${session.protocol}\n'
        '${_durationLabel(session.duration)} · ${session.signalCount} 項訊號\n'
        '${session.valueCount} 筆有效值 · ${session.statusCount} 個狀態 · '
        '${session.gapCount} 個缺口\n'
        '${telemetryTerminalReasonLabel(session.terminalReason)}',
      ),
      trailing: const Icon(Icons.chevron_right),
    ),
  );
}

String _localTime(DateTime utc) => utc.toLocal().toString().substring(0, 16);

String _durationLabel(Duration duration) {
  final seconds = duration.inSeconds.clamp(0, 24 * 60 * 60 - 1);
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
