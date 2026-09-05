/// Short per-value USABILITY-R2 badge. Status follows the datum.
library;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../diagnostics/availability.dart';
import '../panel.dart';

class DatumStatusBadge extends StatelessWidget {
  const DatumStatusBadge({required this.status, this.dense = true, super.key});

  final DatumStatus status;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final text = status.badgeText;
    if (text.isEmpty) return const SizedBox.shrink();
    final tone = switch (status.quality) {
      DatumQuality.invalid => StatusTone.bad,
      DatumQuality.outOfReferenceRange => StatusTone.warn,
      DatumQuality.stale || DatumQuality.partial => StatusTone.warn,
      DatumQuality.tentativeDecode => StatusTone.neutral,
      DatumQuality.valid =>
        status.isEstimate
            ? StatusTone.accent
            : status.isFieldVerified
            ? StatusTone.good
            : StatusTone.neutral,
    };
    return StatusPill(label: text, tone: tone, dense: dense);
  }
}

Future<void> showDatumStatusDetails(
  BuildContext context, {
  required String title,
  required DatumStatus status,
  List<DatumStatus> extra = const [],
}) {
  final items = [status, ...extra];
  return showDialog<void>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < items.length; index++) ...[
                if (index > 0) const SizedBox(height: Spacing.lg),
                Text(
                  items[index].badgeText.isEmpty
                      ? '狀態隨資料'
                      : items[index].badgeText,
                ),
                if (items[index].reason != null) ...[
                  const SizedBox(height: Spacing.sm),
                  Text(items[index].reason!),
                ],
                if (items[index].formula != null) ...[
                  const SizedBox(height: Spacing.md),
                  Text('公式', style: Theme.of(context).textTheme.labelMedium),
                  Text(items[index].formula!),
                ],
                if (items[index].assumptions != null) ...[
                  const SizedBox(height: Spacing.md),
                  Text('假設', style: Theme.of(context).textTheme.labelMedium),
                  Text(items[index].assumptions!),
                ],
                if (items[index].nextStep != null) ...[
                  const SizedBox(height: Spacing.md),
                  Text(items[index].nextStep!),
                ],
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('關閉'),
          ),
        ],
      );
    },
  );
}
