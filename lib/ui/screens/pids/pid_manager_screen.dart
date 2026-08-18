/// PID manager: pick what the dashboard shows, and author custom definitions.
library;

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../obd/pid/pid.dart';
import '../../../obd/pid/pid_csv.dart';
import '../../../obd/telemetry.dart';
import '../../../state/obd_session.dart';
import '../../../state/pid_registry.dart';
import '../../widgets/panel.dart';
import 'pid_editor_screen.dart';

class PidManagerScreen extends ConsumerStatefulWidget {
  const PidManagerScreen({super.key});

  static const String path = '/pids';

  @override
  ConsumerState<PidManagerScreen> createState() => _PidManagerScreenState();
}

enum _PidMenuAction { arrange, importCsv, exportCsv }

class _PidManagerScreenState extends ConsumerState<PidManagerScreen> {
  String _query = '';
  bool _activeOnly = false;

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _handleMenu(_PidMenuAction action) async {
    switch (action) {
      case _PidMenuAction.arrange:
        await _showArrangeSheet();
      case _PidMenuAction.importCsv:
        await _importCsv();
      case _PidMenuAction.exportCsv:
        await _exportCsv();
    }
  }

  Future<void> _showArrangeSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const _ArrangeSheet(),
    );
  }

  Future<void> _importCsv() async {
    final PlatformFile? picked;
    try {
      picked = await FilePicker.pickFile(
        dialogTitle: '選擇 PID 定義 CSV',
        type: FileType.custom,
        allowedExtensions: const ['csv', 'txt'],
      );
    } on Exception catch (e) {
      _snack('無法開啟檔案選擇器：$e');
      return;
    }
    if (picked == null) return;

    String contents;
    try {
      // Decoded as UTF-8 rather than raw code units: unit labels in these
      // files are routinely °C, g/s, N·m, and a byte-wise read would mangle
      // every one of them.
      contents = utf8.decode(await picked.readAsBytes(), allowMalformed: true);
    } on Exception catch (e) {
      _snack('讀取檔案失敗：$e');
      return;
    }

    final result = PidCsv.parse(contents);
    PidImportOutcome? outcome;
    if (result.pids.isNotEmpty) {
      outcome = await ref
          .read(pidRegistryProvider.notifier)
          .upsertAllCustom(result.pids);
    }

    if (result.pids.isEmpty) {
      _snack(result.errors.isEmpty ? '沒有可匯入的定義。' : result.errors.first);
      return;
    }
    // Warnings are reported too, and separately from errors. A row that was
    // *changed* on the way in is not a row that was rejected — and a scale the
    // importer chose is the change most worth mentioning, because a needle
    // reads as authoritative against whatever bounds it is drawn on.
    // Counted as they landed, not as they were parsed — and phrased by
    // `PidImportOutcome.describe`, which is where the counting is tested.
    _snack(
      (outcome ??
              const PidImportOutcome(
                  inserted: 0, replaced: 0, duplicatesInFile: []))
          .describe(
        skippedRows: result.hasErrors ? result.errors.length : 0,
        defaultedRanges: result.hasWarnings ? result.warnings.length : 0,
      ),
    );
  }

  Future<void> _exportCsv() async {
    final custom = ref.read(pidRegistryProvider.notifier).customPids;
    if (custom.isEmpty) {
      _snack('目前沒有自訂 PID 可匯出。');
      return;
    }

    try {
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/torque_custom_pids.csv');
      await file.writeAsString(PidCsv.export(custom));
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/csv')],
          subject: 'Torque 自訂 PID 定義',
        ),
      );
    } on Exception catch (e) {
      _snack('匯出失敗：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final registry = ref.watch(pidRegistryProvider);
    final active = ref.watch(activePidsProvider);
    final snapshot = ref.watch(telemetryProvider).value ?? const TelemetrySnapshot();
    final engine = ref.watch(obdSessionProvider.notifier).engine;

    final activeIds = active.map((p) => p.id).toSet();
    final query = _query.trim().toLowerCase();
    final visible = registry.where((pid) {
      if (_activeOnly && !activeIds.contains(pid.id)) return false;
      if (query.isEmpty) return true;
      return pid.name.toLowerCase().contains(query) ||
          pid.shortName.toLowerCase().contains(query) ||
          pid.modeAndPid.toLowerCase().contains(query);
    }).toList();

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.lg,
                Spacing.md,
                Spacing.lg,
                Spacing.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('PID 管理', style: context.texts.headlineMedium),
                            Text(
                              '已啟用 ${active.length} 項 · 共 ${registry.length} 項可用',
                              style: context.texts.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: () => context.push(PidEditorScreen.path),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('新增'),
                      ),
                      PopupMenuButton<_PidMenuAction>(
                        onSelected: _handleMenu,
                        tooltip: '更多',
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                            value: _PidMenuAction.arrange,
                            child: ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.reorder, size: 20),
                              title: Text('排列儀表板'),
                            ),
                          ),
                          PopupMenuItem(
                            value: _PidMenuAction.importCsv,
                            child: ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.file_download_outlined, size: 20),
                              title: Text('匯入 CSV'),
                            ),
                          ),
                          PopupMenuItem(
                            value: _PidMenuAction.exportCsv,
                            child: ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.file_upload_outlined, size: 20),
                              title: Text('匯出自訂 PID'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: Spacing.lg),
                  TextField(
                    onChanged: (v) => setState(() => _query = v),
                    decoration: const InputDecoration(
                      hintText: '搜尋名稱或 PID 代碼…',
                      prefixIcon: Icon(Icons.search, size: 20),
                    ),
                  ),
                  const SizedBox(height: Spacing.md),
                  Row(
                    children: [
                      FilterChip(
                        selected: _activeOnly,
                        onSelected: (v) => setState(() => _activeOnly = v),
                        label: const Text('只顯示已啟用'),
                        showCheckmark: false,
                        selectedColor: palette.accent.withValues(alpha: 0.16),
                        labelStyle: context.texts.labelMedium?.copyWith(
                          color: _activeOnly ? palette.accent : palette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: visible.isEmpty
                  ? const EmptyState(
                      icon: Icons.search_off,
                      title: '沒有符合的 PID',
                      message: '換個關鍵字，或建立一個自訂 PID。',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(
                        Spacing.lg,
                        0,
                        Spacing.lg,
                        Spacing.xxl,
                      ),
                      itemCount: visible.length,
                      separatorBuilder: (_, _) => const SizedBox(height: Spacing.sm),
                      itemBuilder: (context, index) {
                        final pid = visible[index];
                        return _PidRow(
                          pid: pid,
                          isActive: activeIds.contains(pid.id),
                          reading: snapshot[pid.id],
                          isStale: snapshot.isStale(pid),
                          // Only what the vehicle positively disclaimed. This
                          // used to be "absent from the supported set", which
                          // marks every PID in a block that failed to read —
                          // and every custom PID the masks describe at all —
                          // as one this car does not have.
                          isUnsupported: engine?.isKnownUnsupported(pid) ?? false,
                          onToggle: () =>
                              ref.read(activePidsProvider.notifier).toggle(pid),
                          // Encoded, not interpolated. `Pid.id` ends in
                          // `#<variant>` for an imported definition, and a
                          // raw `#` in a location string is a URI *fragment*:
                          // the editor received a truncated id, found nothing,
                          // opened blank as 新增自訂 PID, and saving created an
                          // unvarianted sibling instead of editing the PID the
                          // user had tapped.
                          onEdit: pid.isCustom
                              ? () => context.push(Uri(
                                    path: PidEditorScreen.path,
                                    queryParameters: {'id': pid.id},
                                  ).toString())
                              : null,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PidRow extends StatelessWidget {
  const _PidRow({
    required this.pid,
    required this.isActive,
    required this.reading,
    required this.isStale,
    required this.isUnsupported,
    required this.onToggle,
    required this.onEdit,
  });

  final Pid pid;
  final bool isActive;
  final Reading? reading;

  /// Whether [reading] is too old to present as live.
  ///
  /// This screen read `snapshot[pid.id]` straight out of the map, so a sensor
  /// that had stopped answering minutes ago still showed its last number in
  /// exactly the same styling as a live one. The dashboard, the derived strip
  /// and the performance screen all honoured the staleness contract; this was
  /// the one place nobody had looked.
  final bool isStale;

  final bool isUnsupported;
  final VoidCallback onToggle;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = context.gaugeColors(GaugeHue.forKey(pid.id)).bright;

    return Panel(
      accent: accent,
      isActive: isActive,
      onTap: onToggle,
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.md,
      ),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 34,
            decoration: BoxDecoration(
              color: isActive ? accent : palette.hairline,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        pid.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.texts.titleSmall,
                      ),
                    ),
                    if (pid.isCustom) ...[
                      const SizedBox(width: Spacing.sm),
                      const StatusPill(label: '自訂', tone: StatusTone.accent, dense: true),
                    ],
                    if (isUnsupported) ...[
                      const SizedBox(width: Spacing.sm),
                      const StatusPill(
                        label: '不支援',
                        tone: StatusTone.warn,
                        dense: true,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Text(
                      pid.modeAndPid,
                      style: AppTypography.code(palette, size: 11.5),
                    ),
                    Text('  ·  ', style: context.texts.bodySmall),
                    Flexible(
                      child: Text(
                        pid.equation,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.code(
                          palette,
                          size: 11.5,
                          color: palette.textTertiary,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (reading != null) ...[
            const SizedBox(width: Spacing.sm),
            Opacity(
              // The same treatment the gauges use: a value that is no longer
              // arriving is dimmed rather than shown as though it were.
              opacity: isStale ? kStaleOpacity : 1,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    reading!.formatted,
                    style: AppTypography.readout(palette, 17),
                  ),
                  Text(
                    isStale ? '${pid.units} · 已過期' : pid.units,
                    style: context.texts.labelSmall,
                  ),
                ],
              ),
            ),
          ],
          if (onEdit != null)
            IconButton(
              onPressed: onEdit,
              icon: const Icon(Icons.edit_outlined, size: 18),
              tooltip: '編輯',
            ),
          // A bare switch announces only "on"/"off" with no subject. In a
          // list of twenty-three rows that is not enough to act on.
          Semantics(
            label: '在儀表板顯示 ${pid.name}',
            child: Switch(value: isActive, onChanged: (_) => onToggle()),
          ),
        ],
      ),
    );
  }
}

/// Drag-to-reorder sheet for the dashboard layout.
///
/// Order matters here: the grid fills row by row, so the first few entries are
/// the ones a driver sees without scrolling.
class _ArrangeSheet extends ConsumerWidget {
  const _ArrangeSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final active = ref.watch(activePidsProvider);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      builder: (context, scrollController) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.lg,
                Spacing.sm,
                Spacing.lg,
                Spacing.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('排列儀表板', style: context.texts.headlineSmall),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    '拖曳調整順序。儀表板由左至右、由上而下填滿，排在前面的最先看到。',
                    style: context.texts.bodySmall,
                  ),
                ],
              ),
            ),
            Expanded(
              child: active.isEmpty
                  ? const EmptyState(
                      icon: Icons.tune,
                      title: '還沒有啟用任何 PID',
                      message: '先在清單中啟用幾項，再回來排列順序。',
                    )
                  : ReorderableListView.builder(
                      scrollController: scrollController,
                      padding: const EdgeInsets.fromLTRB(
                        Spacing.lg,
                        0,
                        Spacing.lg,
                        Spacing.xxl,
                      ),
                      itemCount: active.length,
                      // onReorderItem rather than the deprecated onReorder:
                      // it hands back a newIndex already adjusted for the
                      // dragged item having left the list.
                      onReorderItem: (oldIndex, newIndex) => ref
                          .read(activePidsProvider.notifier)
                          .reorder(oldIndex, newIndex),
                      itemBuilder: (context, index) {
                        final pid = active[index];
                        final accent =
                            context.gaugeColors(GaugeHue.forKey(pid.id)).bright;
                        return Padding(
                          key: ValueKey(pid.id),
                          padding: const EdgeInsets.only(bottom: Spacing.sm),
                          child: Panel(
                            accent: accent,
                            padding: const EdgeInsets.symmetric(
                              horizontal: Spacing.md,
                              vertical: Spacing.sm,
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 26,
                                  height: 26,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: accent.withValues(alpha: 0.14),
                                    borderRadius: BorderRadius.circular(Radii.sm - 2),
                                  ),
                                  child: Text(
                                    '${index + 1}',
                                    style: context.texts.labelMedium
                                        ?.copyWith(color: accent),
                                  ),
                                ),
                                const SizedBox(width: Spacing.md),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        pid.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: context.texts.titleSmall,
                                      ),
                                      Text(
                                        pid.modeAndPid,
                                        style: AppTypography.code(palette, size: 11.5),
                                      ),
                                    ],
                                  ),
                                ),
                                ReorderableDragStartListener(
                                  index: index,
                                  child: Icon(
                                    Icons.drag_handle,
                                    color: palette.textTertiary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
