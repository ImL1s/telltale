import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torque_obd/state/pid_mutation_lock.dart';
import 'package:torque_obd/state/pid_registry.dart';
import 'package:torque_obd/ui/screens/pids/pid_manager_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('PID manager scrolls without overflow in 200% landscape', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(832, 384);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2)),
            child: PidManagerScreen(),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(find.byType(CustomScrollView), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(Switch), findsWidgets);

    await tester.enterText(find.byType(TextField), 'definitely-no-such-pid');
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('沒有符合的 PID'));
    await tester.pump();
    expect(find.text('換個關鍵字，或建立一個自訂 PID。'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pump();
  });

  testWidgets('recording lock refuses dashboard toggle with visible feedback', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    final before = List.of(container.read(activePidsProvider));
    final token = container
        .read(pidMutationLockProvider)
        .tryAcquire('recording')!;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: PidManagerScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byType(Switch).first);
    await tester.pump();

    expect(container.read(activePidsProvider), before);
    expect(find.text('請先停止並儲存'), findsOneWidget);

    container.read(pidMutationLockProvider).release(token);
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pump();
  });
}
