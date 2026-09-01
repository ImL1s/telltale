/// The shell decision rides the platform's watch answer, nothing else.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/app.dart';
import 'package:torque_obd/core/form_factor.dart';
import 'package:torque_obd/state/pid_registry.dart';
import 'package:torque_obd/ui/wear/wear_shell.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpApp(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: const TorqueApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
  }

  // The platform override must be back to null before the test body ends —
  // the binding verifies foundation debug variables itself, ahead of any
  // tearDown/addTearDown — hence the try/finally shape.
  Future<void> route(
    WidgetTester tester, {
    required TargetPlatform platform,
    required bool watchAnswer,
    required Matcher wearShell,
  }) async {
    debugDefaultTargetPlatformOverride = platform;
    FormFactor.debugIsWatch = watchAnswer;
    try {
      await pumpApp(tester);
      expect(find.byType(WearShell), wearShell);
    } finally {
      FormFactor.debugIsWatch = false;
      debugDefaultTargetPlatformOverride = null;
    }
  }

  testWidgets('a watch answer routes Android to the wear shell', (
    tester,
  ) async {
    await route(
      tester,
      platform: TargetPlatform.android,
      watchAnswer: true,
      wearShell: findsOneWidget,
    );
  });

  testWidgets('a phone answer keeps the full phone shell', (tester) async {
    await route(
      tester,
      platform: TargetPlatform.android,
      watchAnswer: false,
      wearShell: findsNothing,
    );
  });

  testWidgets('a watch claim off Android is still a phone', (tester) async {
    await route(
      tester,
      platform: TargetPlatform.iOS,
      watchAnswer: true,
      wearShell: findsNothing,
    );
  });
}
