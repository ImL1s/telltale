import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/field_evidence/platform_metadata.dart';
import 'core/form_factor.dart';
import 'core/licenses/powertrain_battery_licenses.dart';
import 'core/share/rig_app_share_platform.dart';
import 'obd/session_evidence.dart';
import 'state/app_runtime.dart';
import 'state/app_share_coordinator.dart';
import 'state/pid_registry.dart';
import 'state/telemetry_recorder.dart';
import 'state/telemetry_runtime.dart';

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
  final platformMetadata = platformMetadataCache.value;
  final rigShareCaptureEnabled = isRigShareCaptureEligible(
    metadata: platformMetadata,
    buildFlag: isObdTestRigBuild,
    debugMode: kDebugMode,
  );

  // The shell decision (phone router vs wear shell) is made before the first
  // frame from the platform's own watch-feature answer; geometry never
  // decides it, because a narrow window is not a wrist.
  await FormFactor.prefetch();

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
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        telemetryRecorderRuntimeProvider.overrideWith(
          (ref) => ref.watch(productionTelemetryRecorderRuntimeProvider),
        ),
        appSharePolicyProvider.overrideWith(
          (ref) => ref.watch(productionAppSharePolicyProvider),
        ),
        appShareAvailableBytesProvider.overrideWith(
          (ref) => ref.watch(productionAppShareAvailableBytesProvider),
        ),
        if (rigShareCaptureEnabled)
          appSharePlatformProvider.overrideWith(
            (ref) => RigAppSharePlatform(metadata: platformMetadata),
          ),
      ],
      child: const TorqueApp(),
    ),
  );
}
