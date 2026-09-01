import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Gives host-side tests the foreground lifecycle edge that a real Flutter
/// engine sends before a user can interact with the app.
///
/// [TestWidgetsFlutterBinding] otherwise starts with a null lifecycle state.
/// Production deliberately treats that absence as unknown/background, but the
/// existing notifier and transport tests model an already interactive app.
/// Resetting before every test preserves that model without weakening the
/// production fail-closed lifecycle gate or allowing one lifecycle test to
/// leak a paused state into the next test.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  void resume() {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }

  resume();
  setUp(resume);
  await testMain();
}
