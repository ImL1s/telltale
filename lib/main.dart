import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/field_evidence/platform_metadata.dart';
import 'core/licenses/powertrain_battery_licenses.dart';
import 'state/pid_registry.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerPowertrainBatteryLicenses();

  // Preferences are loaded before the first frame so every provider that
  // depends on them can be synchronous — otherwise the dashboard flashes its
  // default layout before the user's saved one arrives.
  final prefs = await SharedPreferences.getInstance();

  // Field evidence reads this cache synchronously when the user taps an
  // adapter. The platform call happens once here, outside every OBD timing
  // path, and falls back to dart:io facts after 500 ms at most. An Android
  // fallback cannot prove field-versus-rig identity, so evidence then fails
  // closed as simulated rather than claiming physical provenance.
  await prefetchPlatformMetadata();

  // Orientation / system chrome are phone/tablet concerns. Calling them on
  // desktop is usually a soft no-op, but it is not the product contract for
  // Windows/Linux/macOS windowing — skip so a missing plugin never becomes a
  // launch-time surprise on those hosts.
  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
      ),
    );
  }

  runApp(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: const TorqueApp(),
    ),
  );
}
