import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/polling_engine.dart';
import 'package:torque_obd/ui/screens/pids/pid_manager_screen.dart';

ObdCapabilitySummary _summary({
  ObdCapabilityDiscoveryPhase phase =
      ObdCapabilityDiscoveryPhase.attemptFinished,
  Set<String> verified = const {'0100'},
  Set<String> supported = const {'010C'},
}) => ObdCapabilitySummary(
  phase: phase,
  verifiedBlockIds: verified,
  supportedMode01Requests: supported,
  directlyAnsweredDefinitionIds: const <String>{},
);

void main() {
  test('presentation distinguishes every safe bulk-action state', () {
    expect(
      supportedPidBulkPresentation(
        summary: _summary(phase: ObdCapabilityDiscoveryPhase.running),
        active: const [],
        mutationLocked: false,
      ).state,
      SupportedPidBulkUiState.pending,
    );
    expect(
      supportedPidBulkPresentation(
        summary: _summary(supported: const {'010C', '0120'}),
        active: const [],
        mutationLocked: false,
      ).state,
      SupportedPidBulkUiState.incomplete,
    );
    expect(
      supportedPidBulkPresentation(
        summary: _summary(supported: const <String>{}),
        active: const [],
        mutationLocked: false,
      ).state,
      SupportedPidBulkUiState.zero,
    );
    expect(
      supportedPidBulkPresentation(
        summary: _summary(),
        active: const [PidLibrary.engineRpm],
        mutationLocked: false,
      ).state,
      SupportedPidBulkUiState.allActive,
    );
    expect(
      supportedPidBulkPresentation(
        summary: _summary(),
        active: const [],
        mutationLocked: true,
      ).state,
      SupportedPidBulkUiState.locked,
    );
  });

  test('confirmation states exact count and refresh-rate warning', () {
    final message = supportedPidConfirmationMessage(
      summary: _summary(supported: const {'010C', '0120'}),
      addCount: 3,
    );

    expect(message, contains('將加入 3 項'));
    expect(message, contains('更新頻率可能降低'));
    expect(message, contains('支援區塊未確認'));
  });

  testWidgets('capability panel remains semantic and usable at 200% text', (
    tester,
  ) async {
    var added = false;
    final summary = _summary(supported: const {'010C', '0120'});
    final presentation = supportedPidBulkPresentation(
      summary: summary,
      active: const [],
      mutationLocked: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: PidCapabilityPanel(
                summary: summary,
                presentation: presentation,
                onAdd: () => added = true,
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('車輛支援 PID'), findsOneWidget);
    expect(find.textContaining('未知區塊'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('車輛支援 PID.*未知區塊')), findsOneWidget);
    await tester.tap(find.byType(FilledButton));
    expect(added, isTrue);
  });
}
