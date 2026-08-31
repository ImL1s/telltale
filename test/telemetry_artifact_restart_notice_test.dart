import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/core/theme/app_theme.dart';
import 'package:torque_obd/state/telemetry_sessions.dart';
import 'package:torque_obd/ui/widgets/telemetry/telemetry_artifact_restart_notice.dart';

void main() {
  testWidgets('restart-owned artifact warning is exact and not dismissible', (
    tester,
  ) async {
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        child: Builder(
          builder: (context) {
            container = ProviderScope.containerOf(context, listen: false);
            return MaterialApp(
              theme: AppTheme.dark(),
              home: const Scaffold(body: TelemetryArtifactRestartNotice()),
            );
          },
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('telemetry-artifact-restart-notice')),
      findsNothing,
    );
    container.read(telemetryArtifactNoticeProvider.notifier).requireRestart();
    await tester.pump();

    expect(
      find.byKey(const ValueKey('telemetry-artifact-restart-notice')),
      findsOneWidget,
    );
    expect(find.text(telemetryArtifactRestartRequiredCopy), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(IconButton), findsNothing);
  });
}
