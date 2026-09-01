library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../state/telemetry_sessions.dart';

/// Process-lifetime warning for an indeterminate artifact mutation.
///
/// There is intentionally no dismiss action: the retained ownership gate can
/// only be reconstructed by a fresh process, so hiding this copy would imply a
/// recovery that did not occur.
class TelemetryArtifactRestartNotice extends ConsumerWidget {
  const TelemetryArtifactRestartNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final message = ref.watch(telemetryArtifactNoticeProvider);
    if (message == null) return const SizedBox.shrink();
    return SafeArea(
      bottom: false,
      child: Material(
        key: const ValueKey('telemetry-artifact-restart-notice'),
        color: context.palette.danger,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.lg,
            vertical: Spacing.md,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.restart_alt, color: Colors.white),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  message,
                  style: context.texts.bodyMedium?.copyWith(
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
