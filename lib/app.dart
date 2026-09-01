import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/form_factor.dart';
import 'core/theme/app_theme.dart';
import 'state/powertrain_battery_profiles.dart';
import 'state/settings.dart';
import 'ui/wear/wear_shell.dart';
import 'ui/screens/connect/connect_screen.dart';
import 'ui/screens/dashboard/dashboard_screen.dart';
import 'ui/screens/dtc/dtc_screen.dart';
import 'ui/screens/performance/performance_screen.dart';
import 'ui/screens/pids/powertrain_battery_catalog_screen.dart';
import 'ui/screens/pids/pid_editor_screen.dart';
import 'ui/screens/pids/pid_manager_screen.dart';
import 'ui/screens/settings/settings_screen.dart';
import 'ui/shell.dart';

class TorqueApp extends ConsumerWidget {
  const TorqueApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Rehydrates installed battery-profile PIDs from the verified catalog.
    // Watched at the root so it runs once per app start regardless of which
    // screen the user lands on; failure means those PIDs simply stay absent.
    ref.watch(installedPowertrainProfilesRestoreProvider);
    // A watch gets the wear shell instead of the phone router. Decided by
    // the platform's FEATURE_WATCH answer rather than build flavor or
    // geometry, so the same binary behaves correctly in the Wear emulator
    // regardless of how it was built while a narrow split-screen phone
    // keeps its full shell; the `wear` flavor exists for the Play track's
    // manifest, not for the UI decision.
    if (isWatchFormFactor()) {
      return MaterialApp(
        title: 'Telltale',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(skin: ref.watch(gaugeSkinProvider)),
        home: const WearShell(),
      );
    }
    final themeMode = ref.watch(themeModeProvider);
    // Both themes get the same skin. A skin is what kind of instrument this
    // is; light and dark are the light you are reading it in, and a skin that
    // only existed in one of them would strand anybody who drives at night.
    final skin = ref.watch(gaugeSkinProvider);
    return MaterialApp.router(
      title: 'Telltale',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(skin: skin),
      darkTheme: AppTheme.dark(skin: skin),
      themeMode: themeMode,
      routerConfig: _router,
    );
  }
}

/// Whether this app is running on a watch.
///
/// Backed by `PackageManager.FEATURE_WATCH` prefetched at startup — the
/// platform's own claim, not window geometry, because a phone in a narrow
/// split screen is still a phone and must keep its full shell.
/// `defaultTargetPlatform` rather than `dart:io` so a widget test can steer
/// the route; on a device the two agree.
bool isWatchFormFactor() =>
    defaultTargetPlatform == TargetPlatform.android && FormFactor.isWatch;

final _rootKey = GlobalKey<NavigatorState>();
final _shellKey = GlobalKey<NavigatorState>();

final _router = GoRouter(
  navigatorKey: _rootKey,
  initialLocation: ConnectScreen.path,
  routes: [
    GoRoute(
      path: ConnectScreen.path,
      builder: (context, state) => const ConnectScreen(),
    ),
    ShellRoute(
      navigatorKey: _shellKey,
      builder: (context, state, child) => AppShell(child: child),
      routes: [
        GoRoute(
          path: DashboardScreen.path,
          builder: (context, state) => const DashboardScreen(),
        ),
        GoRoute(
          path: PidManagerScreen.path,
          builder: (context, state) => const PidManagerScreen(),
        ),
        GoRoute(
          path: DtcScreen.path,
          builder: (context, state) => const DtcScreen(),
        ),
        GoRoute(
          path: PerformanceScreen.path,
          builder: (context, state) => const PerformanceScreen(),
        ),
        GoRoute(
          path: SettingsScreen.path,
          builder: (context, state) => const SettingsScreen(),
        ),
      ],
    ),
    GoRoute(
      path: PidEditorScreen.path,
      parentNavigatorKey: _rootKey,
      builder: (context, state) =>
          PidEditorScreen(pidId: state.uri.queryParameters['id']),
    ),
    GoRoute(
      path: PowertrainBatteryCatalogScreen.path,
      parentNavigatorKey: _rootKey,
      builder: (context, state) => const PowertrainBatteryCatalogScreen(),
    ),
  ],
);
