/// PID manager: pick what the dashboard shows, and author custom definitions.
library;

import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../obd/pid/pid.dart';
import '../../../obd/pid/pid_csv.dart';
import '../../../obd/polling_engine.dart';
import '../../../obd/telemetry.dart';
import '../../../state/obd_session.dart';
import '../../../state/pid_mutation_lock.dart';
import '../../../state/pid_registry.dart';
import '../../../state/app_share_entry_controller.dart';
import '../../../state/app_share_coordinator.dart';
import '../../widgets/panel.dart';
import 'pid_editor_screen.dart';
import 'powertrain_battery_catalog_screen.dart';

class PidManagerScreen extends ConsumerStatefulWidget {
  const PidManagerScreen({super.key});

  static const String path = '/pids';

  @override
  ConsumerState<PidManagerScreen> createState() => _PidManagerScreenState();
}

enum _PidMenuAction { arrange, importCsv, exportCsv }

enum SupportedPidBulkUiState {
  pending,
  incomplete,
  zero,
  ready,
  allActive,
  locked,
}

final class SupportedPidBulkPresentation {
  const SupportedPidBulkPresentation({
    required this.state,
    required this.confirmedCount,
    required this.addCount,
  });

  final SupportedPidBulkUiState state;
  final int confirmedCount;
  final int addCount;

  bool get canAdd =>
      (state == SupportedPidBulkUiState.ready ||
          state == SupportedPidBulkUiState.incomplete) &&
      addCount > 0;
}

String supportedPidConfirmationMessage({
  required ObdCapabilitySummary summary,
  required int addCount,
}) =>
    '${summary.unknownOrUnverifiedBlockCount > 0 ? '仍有 ${summary.unknownOrUnverifiedBlockCount} 個支援區塊未確認，這次只加入已有正面證據的項目。\n\n' : ''}'
    '將加入 $addCount 項。啟用越多 PID，單項資料的更新頻率可能降低。';

SupportedPidBulkPresentation supportedPidBulkPresentation({
  required ObdCapabilitySummary summary,
  required Iterable<Pid> active,
  required bool mutationLocked,
}) {
  final confirmed = summary.positivelyConfirmedShippedDirectPids;
  final activeIds = active.map((pid) => Pid.canonicalId(pid.id)).toSet();
  final addCount = confirmed
      .where((pid) => !activeIds.contains(Pid.canonicalId(pid.id)))
      .length;
  if (mutationLocked) {
    return SupportedPidBulkPresentation(
      state: SupportedPidBulkUiState.locked,
      confirmedCount: confirmed.length,
      addCount: addCount,
    );
  }
  if (summary.phase == ObdCapabilityDiscoveryPhase.notStarted ||
      summary.phase == ObdCapabilityDiscoveryPhase.running) {
    return SupportedPidBulkPresentation(
      state: SupportedPidBulkUiState.pending,
      confirmedCount: confirmed.length,
      addCount: addCount,
    );
  }
  if (confirmed.isEmpty && summary.unknownOrUnverifiedBlockCount == 0) {
    return const SupportedPidBulkPresentation(
      state: SupportedPidBulkUiState.zero,
      confirmedCount: 0,
      addCount: 0,
    );
  }
  if (addCount == 0 && confirmed.isNotEmpty) {
    return SupportedPidBulkPresentation(
      state: SupportedPidBulkUiState.allActive,
      confirmedCount: confirmed.length,
      addCount: 0,
    );
  }
  final incomplete =
      summary.phase == ObdCapabilityDiscoveryPhase.interrupted ||
      summary.unknownOrUnverifiedBlockCount > 0;
  return SupportedPidBulkPresentation(
    state: incomplete
        ? SupportedPidBulkUiState.incomplete
        : SupportedPidBulkUiState.ready,
    confirmedCount: confirmed.length,
    addCount: addCount,
  );
}

class _PidManagerScreenState extends ConsumerState<PidManagerScreen> {
  String _query = '';
  bool _activeOnly = false;

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _togglePid(Pid pid) async {
    final outcome = await ref.read(activePidsProvider.notifier).toggle(pid);
    if (outcome.isLocked) _snack(kPidMutationLockedMessage);
  }

  Future<void> _addConfirmedSupported(
    ObdCapabilitySummary summary,
    List<Pid> active,
  ) async {
    final presentation = supportedPidBulkPresentation(
      summary: summary,
      active: active,
      mutationLocked: ref.read(pidMutationLockProvider).isLocked,
    );
    if (!presentation.canAdd) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('加入 ${presentation.addCount} 項已確認支援 PID？'),
        content: Text(
          supportedPidConfirmationMessage(
            summary: summary,
            addCount: presentation.addCount,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('加入 ${presentation.addCount} 項'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final outcome = await ref
        .read(activePidsProvider.notifier)
        .appendPositivelyConfirmed(summary);
    if (outcome.isLocked) {
      _snack(kPidMutationLockedMessage);
    } else if (outcome.addedCount > 0) {
      _snack('已加入 ${outcome.addedCount} 項已確認支援 PID。');
    }
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
                inserted: 0,
                replaced: 0,
                duplicatesInFile: [],
              ))
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
      final outcome = await ref
          .read(appShareEntryControllerProvider)
          .sharePidCsv(pids: custom);
      final error = outcome.userFacingError;
      if (error != null) _snack(error);
    } on Exception catch (e) {
      _snack('匯出失敗：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final registry = ref.watch(pidRegistryProvider);
    final active = ref.watch(activePidsProvider);
    final snapshot =
        ref.watch(telemetryProvider).value ?? const TelemetrySnapshot();
    final summary =
        ref.watch(obdCapabilitySummaryProvider).value ??
        ObdCapabilitySummary.notStarted();
    final mutationLocked = ref.watch(pidMutationLockProvider).isLocked;
    final bulkPresentation = supportedPidBulkPresentation(
      summary: summary,
      active: active,
      mutationLocked: mutationLocked,
    );

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
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.lg,
                  Spacing.md,
                  Spacing.lg,
                  Spacing.md,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: Spacing.md,
                      runSpacing: Spacing.sm,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(minWidth: 180),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'PID 管理',
                                style: context.texts.headlineMedium,
                              ),
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
                                leading: Icon(
                                  Icons.file_download_outlined,
                                  size: 20,
                                ),
                                title: Text('匯入 CSV'),
                              ),
                            ),
                            PopupMenuItem(
                              value: _PidMenuAction.exportCsv,
                              child: ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(
                                  Icons.file_upload_outlined,
                                  size: 20,
                                ),
                                title: Text('匯出自訂 PID'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: Spacing.md),
                    PidCapabilityPanel(
                      summary: summary,
                      presentation: bulkPresentation,
                      onAdd: () => _addConfirmedSupported(summary, active),
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
                            color: _activeOnly
                                ? palette.accent
                                : palette.textSecondary,
                          ),
                        ),
                        const Spacer(),
                        OutlinedButton.icon(
                          key: const Key('open_powertrain_battery_catalog'),
                          onPressed: () =>
                              context.push(PowertrainBatteryCatalogScreen.path),
                          icon: const Icon(Icons.electric_car_outlined, size: 18),
                          label: const Text('大電池目錄'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (visible.isEmpty)
              const SliverFillRemaining(
                child: EmptyState(
                  icon: Icons.search_off,
                  title: '沒有符合的 PID',
                  message: '換個關鍵字，或建立一個自訂 PID。',
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.lg,
                  0,
                  Spacing.lg,
                  Spacing.xxl,
                ),
                sliver: SliverList.separated(
                  itemCount: visible.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: Spacing.sm),
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
                      isUnsupported:
                          summary.statusFor(pid) ==
                          PidCapabilityStatus.unsupported,
                      onToggle: () => _togglePid(pid),
                      // Encoded, not interpolated. `Pid.id` ends in
                      // `#<variant>` for an imported definition, and a
                      // raw `#` in a location string is a URI *fragment*:
                      // the editor received a truncated id, found nothing,
                      // opened blank as 新增自訂 PID, and saving created an
                      // unvarianted sibling instead of editing the PID the
                      // user had tapped.
                      onEdit: pid.isCustom
                          ? () => context.push(
                              Uri(
                                path: PidEditorScreen.path,
                                queryParameters: {'id': pid.id},
                              ).toString(),
                            )
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

final class PidCapabilityPanel extends StatelessWidget {
  const PidCapabilityPanel({
    super.key,
    required this.summary,
    required this.presentation,
    required this.onAdd,
  });

  final ObdCapabilitySummary summary;
  final SupportedPidBulkPresentation presentation;
  final VoidCallback onAdd;

  String get _phaseLabel => switch (summary.phase) {
    ObdCapabilityDiscoveryPhase.notStarted => '尚未開始掃描',
    ObdCapabilityDiscoveryPhase.running => '正在確認車輛支援項目',
    ObdCapabilityDiscoveryPhase.attemptFinished => '本次支援掃描已完成',
    ObdCapabilityDiscoveryPhase.interrupted => '支援掃描已中斷',
  };

  String get _actionLabel => switch (presentation.state) {
    SupportedPidBulkUiState.pending => '等待掃描結果',
    SupportedPidBulkUiState.incomplete =>
      presentation.addCount > 0
          ? '加入已確認的 ${presentation.addCount} 項'
          : '掃描資料不完整',
    SupportedPidBulkUiState.zero => '沒有確認支援項目',
    SupportedPidBulkUiState.ready => '加入 ${presentation.addCount} 項',
    SupportedPidBulkUiState.allActive => '已全部啟用',
    SupportedPidBulkUiState.locked => '錄製中無法變更',
  };

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label:
        '車輛支援 PID。$_phaseLabel。確認 ${presentation.confirmedCount} 項。'
        '未知區塊 ${summary.unknownOrUnverifiedBlockCount} 個。',
    child: Panel(
      padding: const EdgeInsets.all(Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('車輛支援 PID', style: context.texts.titleMedium),
          const SizedBox(height: Spacing.xs),
          Text(_phaseLabel, style: context.texts.bodySmall),
          const SizedBox(height: Spacing.sm),
          Wrap(
            spacing: Spacing.md,
            runSpacing: Spacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('確認 ${presentation.confirmedCount} 項'),
              Text('未知區塊 ${summary.unknownOrUnverifiedBlockCount}'),
              if (summary.contiguousCoverageThroughPid case final through?)
                Text(
                  '連續涵蓋 01–${through.toRadixString(16).toUpperCase().padLeft(2, '0')}'
                  '${summary.contiguousCoverageReachedVerifiedTerminal ? '（已到終點）' : '（後續未知）'}',
                )
              else
                const Text('連續涵蓋尚未建立'),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Semantics(
            button: true,
            label: _actionLabel,
            child: FilledButton.icon(
              onPressed: presentation.canAdd ? onAdd : null,
              icon: const Icon(Icons.playlist_add_check),
              label: Text(_actionLabel),
            ),
          ),
        ],
      ),
    ),
  );
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
  final Future<void> Function() onToggle;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = context.gaugeColors(GaugeHue.forKey(pid.id)).bright;

    return Panel(
      accent: accent,
      isActive: isActive,
      onTap: () => unawaited(onToggle()),
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
                      const StatusPill(
                        label: '自訂',
                        tone: StatusTone.accent,
                        dense: true,
                      ),
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
            child: Switch(
              value: isActive,
              onChanged: (_) => unawaited(onToggle()),
            ),
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
                      onReorderItem: (oldIndex, newIndex) {
                        unawaited(() async {
                          final outcome = await ref
                              .read(activePidsProvider.notifier)
                              .reorder(oldIndex, newIndex);
                          if (outcome.isLocked && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(kPidMutationLockedMessage),
                              ),
                            );
                          }
                        }());
                      },
                      itemBuilder: (context, index) {
                        final pid = active[index];
                        final accent = context
                            .gaugeColors(GaugeHue.forKey(pid.id))
                            .bright;
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
                                    borderRadius: BorderRadius.circular(
                                      Radii.sm - 2,
                                    ),
                                  ),
                                  child: Text(
                                    '${index + 1}',
                                    style: context.texts.labelMedium?.copyWith(
                                      color: accent,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: Spacing.md),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        pid.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: context.texts.titleSmall,
                                      ),
                                      Text(
                                        pid.modeAndPid,
                                        style: AppTypography.code(
                                          palette,
                                          size: 11.5,
                                        ),
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
