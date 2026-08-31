import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/theme/app_theme.dart';
import 'state/settings.dart';
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
