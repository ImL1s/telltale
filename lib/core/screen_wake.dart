/// Keeps the screen awake while a session is live.
library;

import 'package:flutter/services.dart';

/// Wraps the platform's keep-screen-on window flag.
///
/// A driving dashboard that dozes off mid-corner is worse than the battery
/// it saves — the watch shell holds this while connected. Failure is
/// swallowed on purpose: a platform without the channel (tests, desktop)
/// simply keeps its normal screen policy, which is never wrong data.
abstract final class ScreenWake {
  static const MethodChannel _channel = MethodChannel(
    'com.cbstudio.telltale/screen_wake',
  );

  static Future<void> keepOn(bool on) async {
    try {
      await _channel.invokeMethod<void>('keepOn', {'on': on});
    } on Object {
      // No channel on this platform; the screen keeps its normal policy.
    }
  }
}
