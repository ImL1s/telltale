/// Display wake-lock helper for live OBD sessions.
///
/// `wakelock_plus` has no Linux plugin. Calling enable/disable there throws
/// [MissingPluginException], and an unawaited failure can surface as an
/// unhandled async error. Skip the plugin on Linux and swallow
/// [MissingPluginException] on every host so a missing native implementation
/// never reaches UI.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:wakelock_plus/wakelock_plus.dart';

/// Holds or releases the screen-awake lock.
///
/// No-ops on Linux. Elsewhere delegates to `wakelock_plus`, treating a missing
/// plugin as a soft no-op rather than a crash.
Future<void> setAppWakelock(
  bool enabled, {
  @visibleForTesting bool? isLinux,
  @visibleForTesting Future<void> Function()? enable,
  @visibleForTesting Future<void> Function()? disable,
}) async {
  if (isLinux ?? Platform.isLinux) return;
  try {
    if (enabled) {
      await (enable ?? WakelockPlus.enable)();
    } else {
      await (disable ?? WakelockPlus.disable)();
    }
  } on MissingPluginException {
    // Host build without a wakelock plugin (or a stub that answers
    // notImplemented). Leaving the display free to sleep is correct; crashing
    // the shell is not.
  }
}
