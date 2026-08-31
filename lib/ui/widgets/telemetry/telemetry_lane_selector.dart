library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../obd/pid/pid.dart';
import '../../../state/telemetry_trends.dart';

class TelemetryLaneSelector extends ConsumerWidget {
  const TelemetryLaneSelector({
    required this.activePids,
    required this.selectedIds,
    required this.enabled,
    required this.disabledReason,
    super.key,
  });

  final List<Pid> activePids;
  final List<String> selectedIds;
  final bool enabled;
  final String? disabledReason;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final byId = {for (final pid in activePids) pid.id: pid};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: Spacing.sm,
          runSpacing: Spacing.sm,
          children: [
            for (final id in selectedIds)
              if (byId[id] case final pid?)
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: InputChip(
                    label: Text(_name(pid)),
                    avatar: Icon(
                      Icons.show_chart,
                      size: 18,
                      color: context
                          .gaugeColors(GaugeHue.forKey(pid.id))
                          .bright,
                    ),
                    onDeleted: enabled
                        ? () => unawaited(_remove(context, ref, id))
                        : null,
                    deleteButtonTooltipMessage: '移除 ${_name(pid)}',
                  ),
                ),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: ActionChip(
                key: const ValueKey('telemetry-lane-selector'),
                avatar: const Icon(Icons.tune, size: 18),
                label: const Text('選擇訊號'),
                onPressed: enabled && activePids.isNotEmpty
                    ? () => _showSelector(context, ref)
                    : null,
              ),
            ),
          ],
        ),
        if (!enabled && disabledReason != null) ...[
          const SizedBox(height: Spacing.sm),
          Text(
            disabledReason!,
            style: context.texts.bodySmall?.copyWith(
              color: context.palette.warning,
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _remove(BuildContext context, WidgetRef ref, String id) async {
    final next = selectedIds.where((candidate) => candidate != id).toList();
    final outcome = await ref
        .read(telemetryTrendsProvider.notifier)
        .setSelectedIds(next);
    if (!context.mounted) return;
    _showOutcome(context, outcome);
  }

  Future<void> _showSelector(BuildContext context, WidgetRef ref) async {
    final initial = selectedIds.toSet();
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _TelemetryLaneSheet(
        activePids: activePids,
        initialSelection: initial,
      ),
    );
    if (result == null || !context.mounted) return;
    final outcome = await ref
        .read(telemetryTrendsProvider.notifier)
        .setSelectedIds(result);
    if (!context.mounted) return;
    _showOutcome(context, outcome);
  }

  static void _showOutcome(
    BuildContext context,
    TelemetryTrendSelectionOutcome outcome,
  ) {
    final message = switch (outcome) {
      TelemetryTrendSelectionOutcome.tooMany => '最多選擇 4 項',
      TelemetryTrendSelectionOutcome.unavailable => '其中一項訊號已不在 PID 監看清單',
      TelemetryTrendSelectionOutcome.storageFailure => '無法儲存趨勢顯示選擇',
      _ => null,
    };
    if (message != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  static String _name(Pid pid) =>
      pid.shortName.isEmpty ? pid.name : pid.shortName;
}

class _TelemetryLaneSheet extends StatefulWidget {
  const _TelemetryLaneSheet({
    required this.activePids,
    required this.initialSelection,
  });

  final List<Pid> activePids;
  final Set<String> initialSelection;

  @override
  State<_TelemetryLaneSheet> createState() => _TelemetryLaneSheetState();
}

class _TelemetryLaneSheetState extends State<_TelemetryLaneSheet> {
  late final Set<String> _selected = {...widget.initialSelection};

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        maxChildSize: 0.94,
        builder: (context, controller) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
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
                  Text('趨勢訊號', style: context.texts.headlineSmall),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    '最多選擇 4 項。這只會改變圖表，不會改變 PID 輪詢或正在進行的紀錄。',
                    style: context.texts.bodySmall,
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: controller,
                itemCount: widget.activePids.length,
                itemBuilder: (context, index) {
                  final pid = widget.activePids[index];
                  final selected = _selected.contains(pid.id);
                  return CheckboxListTile(
                    value: selected,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(
                      pid.shortName.isEmpty ? pid.name : pid.shortName,
                    ),
                    subtitle: Text(
                      pid.units.isEmpty
                          ? pid.modeAndPid
                          : '${pid.modeAndPid} · ${pid.units}',
                    ),
                    onChanged: (value) {
                      if (value == true && _selected.length >= 4) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('最多選擇 4 項')),
                        );
                        return;
                      }
                      setState(() {
                        if (value == true) {
                          _selected.add(pid.id);
                        } else {
                          _selected.remove(pid.id);
                        }
                      });
                    },
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(Spacing.lg),
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(
                  widget.activePids
                      .where((pid) => _selected.contains(pid.id))
                      .map((pid) => pid.id)
                      .toList(),
                ),
                child: Text('完成 · ${_selected.length}/4'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
