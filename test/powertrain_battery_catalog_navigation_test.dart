import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/state/pid_registry.dart';
import 'package:torque_obd/ui/screens/pids/pid_manager_screen.dart';
import 'package:torque_obd/ui/screens/pids/powertrain_battery_catalog_screen.dart';

void main() {
  testWidgets('PID manager opens the powertrain battery catalog', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
    );
    final router = GoRouter(
      initialLocation: PidManagerScreen.path,
      routes: [
        GoRoute(
          path: PidManagerScreen.path,
          builder: (_, _) => const PidManagerScreen(),
        ),
        GoRoute(
          path: PowertrainBatteryCatalogScreen.path,
          builder: (_, _) => const PowertrainBatteryCatalogScreen(),
        ),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byKey(const Key('open_powertrain_battery_catalog')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(router.state.uri.path, PowertrainBatteryCatalogScreen.path);
    expect(find.text('大電池車型目錄'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    router.dispose();
    await tester.pump();
  });
}
