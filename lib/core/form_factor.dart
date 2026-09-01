/// Which body this app woke up in.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The platform's own answer to "is this a watch", fetched once at startup.
///
/// Window geometry cannot answer this — a phone in a narrow split screen is
/// still a phone and must keep the full shell — so the decision rides on
/// `PackageManager.FEATURE_WATCH` and nothing else. Failure to answer means
/// not-a-watch: the phone shell is the safe default everywhere.
abstract final class FormFactor {
  static const MethodChannel _channel = MethodChannel(
    'com.cbstudio.telltale/form_factor',
  );

  static bool _isWatch = false;

  static bool get isWatch => _isWatch;

  static Future<void> prefetch() async {
    try {
      _isWatch =
          await _channel
              .invokeMethod<bool>('isWatch')
              .timeout(const Duration(milliseconds: 500)) ??
          false;
    } on Object {
      _isWatch = false;
    }
  }

  @visibleForTesting
  static set debugIsWatch(bool value) => _isWatch = value;
}
