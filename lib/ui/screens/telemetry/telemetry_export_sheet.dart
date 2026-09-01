library;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../state/telemetry_sessions.dart';

Future<TelemetryExportFormat?> showTelemetryExportSheet(BuildContext context) =>
    showModalBottomSheet<TelemetryExportFormat>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const TelemetryExportSheet(),
    );

class TelemetryExportSheet extends StatelessWidget {
  const TelemetryExportSheet({super.key});

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      primary: false,
      padding: const EdgeInsets.all(Spacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('匯出本機紀錄', style: context.texts.titleLarge),
          const SizedBox(height: Spacing.md),
          const Text(telemetryExportDisclosure),
          const SizedBox(height: Spacing.lg),
          Wrap(
            spacing: Spacing.md,
            runSpacing: Spacing.sm,
            children: [
              OutlinedButton.icon(
                onPressed: () =>
                    Navigator.pop(context, TelemetryExportFormat.csv),
                icon: const Icon(Icons.table_chart_outlined),
                label: const Text('匯出 CSV'),
              ),
              FilledButton.icon(
                onPressed: () =>
                    Navigator.pop(context, TelemetryExportFormat.json),
                icon: const Icon(Icons.data_object),
                label: const Text('匯出 JSON'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
