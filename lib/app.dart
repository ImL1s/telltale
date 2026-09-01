import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/form_factor.dart';
import 'core/theme/app_theme.dart';
import 'state/app_share_coordinator.dart';
import 'state/powertrain_battery_profiles.dart';
import 'state/settings.dart';
import 'state/telemetry_recorder.dart';
import 'state/telemetry_sessions.dart';
import 'ui/wear/wear_shell.dart';
import 'ui/screens/connect/connect_screen.dart';
import 'ui/screens/dashboard/dashboard_screen.dart';
import 'ui/screens/dtc/dtc_screen.dart';
import 'ui/screens/performance/performance_screen.dart';
import 'ui/screens/pids/powertrain_battery_catalog_screen.dart';
import 'ui/screens/pids/pid_editor_screen.dart';
import 'ui/screens/pids/pid_manager_screen.dart';
import 'ui/screens/settings/settings_screen.dart';
import 'ui/screens/telemetry/telemetry_session_detail_screen.dart';
import 'ui/screens/telemetry/telemetry_sessions_screen.dart';
import 'ui/shell.dart';
import 'ui/widgets/telemetry/telemetry_artifact_restart_notice.dart';

class TorqueApp extends ConsumerStatefulWidget {
  const TorqueApp({super.key});

  @override
  ConsumerState<TorqueApp> createState() => _TorqueAppState();
}

class _TorqueAppState extends ConsumerState<TorqueApp> {
  late Future<_AppStartupOutcome> _startupInitialization;
  late final AppLifecycleListener _lifecycleListener;
  bool _startupReady = false;
  bool _startupRequiresRestart = false;

  @override
  void initState() {
    super.initState();
    // These authorities outlive every route. Creating them before the router
    // makes lifecycle, OBD-boundary, and cross-feature file exclusion active
    // even while the user is still on Connect.
    ref.read(telemetryRecorderControllerProvider);
    ref.read(telemetryRecorderProgressProvider);
    _startupInitialization = _initializeStartup();
    _lifecycleListener = AppLifecycleListener(onResume: _retryStartup);
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  Future<_AppStartupOutcome> _initializeStartup() async {
    try {
      final share = await ref.read(appShareCoordinatorProvider).initialize();
      if (share != AppShareInitializationOutcome.ready) {
        return _rememberStartupOutcome(_AppStartupOutcome(share: share));
      }
      final recovery = await ref
          .read(telemetryStartupRecoveryProvider.notifier)
          .initialize();
      return _rememberStartupOutcome(
        _AppStartupOutcome(share: share, recovery: recovery.phase),
      );
    } on Object {
      // Startup reconstruction owns durable files. An unexpected exception is
      // indeterminate rather than retryable in-process.
      return _rememberStartupOutcome(
        const _AppStartupOutcome(unexpectedFailure: true),
      );
    }
  }

  _AppStartupOutcome _rememberStartupOutcome(_AppStartupOutcome outcome) {
    _startupReady = outcome.isReady;
    _startupRequiresRestart = outcome.requiresRestart;
    return outcome;
  }

  void _retryStartup() {
    if (!mounted || _startupReady || _startupRequiresRestart) return;
    setState(() {
      _startupInitialization = _initializeStartup();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Rehydrates installed battery-profile PIDs from the verified catalog.
    ref.watch(installedPowertrainProfilesRestoreProvider);
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
    return FutureBuilder<_AppStartupOutcome>(
      future: _startupInitialization,
      builder: (context, snapshot) {
        final outcome = snapshot.data;
        if (outcome?.isReady != true) {
          return MaterialApp(
            title: 'Telltale',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(skin: skin),
            darkTheme: AppTheme.dark(skin: skin),
            themeMode: themeMode,
            builder: _withTelemetryArtifactNotice,
            home: _AppStartupScreen(outcome: outcome, retry: _retryStartup),
          );
        }
        return MaterialApp.router(
          title: 'Telltale',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(skin: skin),
          darkTheme: AppTheme.dark(skin: skin),
          themeMode: themeMode,
          builder: _withTelemetryArtifactNotice,
          routerConfig: _router,
        );
      },
    );
  }
}

Widget _withTelemetryArtifactNotice(BuildContext context, Widget? child) {
  return Stack(
    fit: StackFit.expand,
    children: [
      child ?? const SizedBox.shrink(),
      const Align(
        alignment: Alignment.topCenter,
        child: TelemetryArtifactRestartNotice(),
      ),
    ],
  );
}

final class _AppStartupOutcome {
  const _AppStartupOutcome({
    this.share,
    this.recovery,
    this.unexpectedFailure = false,
  });

  final AppShareInitializationOutcome? share;
  final TelemetryStartupRecoveryPhase? recovery;
  final bool unexpectedFailure;

  bool get isReady =>
      share == AppShareInitializationOutcome.ready &&
      recovery == TelemetryStartupRecoveryPhase.ready &&
      !unexpectedFailure;

  bool get requiresRestart =>
      unexpectedFailure ||
      share == AppShareInitializationOutcome.blocked ||
      recovery == TelemetryStartupRecoveryPhase.restartRequired;
}

class _AppStartupScreen extends StatelessWidget {
  const _AppStartupScreen({required this.outcome, required this.retry});

  final _AppStartupOutcome? outcome;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) {
    final blocked = outcome?.requiresRestart == true;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (outcome == null) ...[
                    const CircularProgressIndicator(),
                    const SizedBox(height: 20),
                    const Text('正在檢查本機分享暫存與遙測紀錄', textAlign: TextAlign.center),
                  ] else ...[
                    Icon(
                      blocked ? Icons.restart_alt : Icons.lock_clock_outlined,
                      size: 48,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      blocked ? '需要重新啟動才能安全繼續' : '目前無法完成啟動檢查',
                      style: Theme.of(context).textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      blocked
                          ? '本機分享暫存或遙測紀錄的狀態無法確認。為避免覆寫、刪除或分享錯誤檔案，請完全關閉後重新開啟 Telltale。'
                          : '請讓 Telltale 保持在前景，並在其他檔案作業完成後重試。啟動完成前不會開放紀錄、回放、匯出或刪除。',
                      textAlign: TextAlign.center,
                    ),
                    if (!blocked) ...[
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: retry,
                        icon: const Icon(Icons.refresh),
                        label: const Text('重試'),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
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
    GoRoute(
      path: TelemetrySessionsScreen.path,
      parentNavigatorKey: _rootKey,
      builder: (context, state) => const TelemetrySessionsScreen(),
      routes: [
        GoRoute(
          path: ':sessionId',
          parentNavigatorKey: _rootKey,
          builder: (context, state) => TelemetrySessionDetailScreen(
            sessionId: state.pathParameters['sessionId'] ?? '',
          ),
        ),
      ],
    ),
  ],
);
