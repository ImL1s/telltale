library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../state/telemetry_recorder.dart';
import '../../../telemetry/session/telemetry_recorder.dart';
import 'telemetry_recorder_panel.dart';

/// Keeps an interrupted/finalizing recorder visible after AppShell is gone.
class TelemetryConnectRecorderStatus extends ConsumerWidget {
  const TelemetryConnectRecorderStatus({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(telemetryRecorderProgressProvider).state.phase;
    if (phase == TelemetryRecorderPhase.idle) {
      return const SizedBox.shrink();
    }
    return const Padding(
      padding: EdgeInsets.fromLTRB(Spacing.lg, 0, Spacing.lg, Spacing.lg),
      child: TelemetryRecorderPanel(),
    );
  }
}
