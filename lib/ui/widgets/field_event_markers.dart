import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../state/obd_session.dart';
import 'panel.dart';

typedef FieldEventRecorder = Future<FieldEventRecordResult> Function(
  FieldEventMarker marker,
);

/// Four large, low-ambiguity markers for a passenger during a field session.
class FieldEventMarkerPanel extends StatefulWidget {
  const FieldEventMarkerPanel({
    super.key,
    required this.enabled,
    required this.onRecord,
  });

  final bool enabled;
  final FieldEventRecorder onRecord;

  @override
  State<FieldEventMarkerPanel> createState() => _FieldEventMarkerPanelState();
}

class _FieldEventMarkerPanelState extends State<FieldEventMarkerPanel> {
  bool _saving = false;

  Future<void> _record(FieldEventMarker marker) async {
    if (!widget.enabled || _saving) return;
    setState(() => _saving = true);
    final result = await widget.onRecord(marker);
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(switch (result) {
          FieldEventRecordResult.persisted => '已記錄並保存：${marker.label}',
          FieldEventRecordResult.memoryOnly =>
            '已記在目前工作階段，但自動保存失敗；請立刻匯出紀錄。',
          FieldEventRecordResult.unavailable => '目前沒有可記錄的實車連線。',
        }),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled && !_saving;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('實車事件標記', style: context.texts.titleSmall),
          const SizedBox(height: Spacing.xs),
          Text(
            '只在車輛完全停妥時，由乘客或停車中的操作人員按下。'
            '事件會與 OBD 原始資料使用同一條時間軸並嘗試立即保存。',
            style: context.texts.bodySmall,
          ),
          const SizedBox(height: Spacing.sm),
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: [
              for (final marker in FieldEventMarker.values)
                FilledButton.tonal(
                  onPressed: enabled ? () => _record(marker) : null,
                  child: Text(marker.label),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
