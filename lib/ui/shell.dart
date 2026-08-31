/// Navigation shell.
///
/// Compact widths get a bottom navigation bar; anything wider gets a rail, so
/// a tablet or a phone in landscape — mounted on a windscreen, which is how
/// this app actually gets used — keeps the full screen height for gauges.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/app_wakelock.dart';
import '../core/theme/app_theme.dart';
import '../state/obd_session.dart';
import 'screens/dashboard/dashboard_screen.dart';
import 'screens/dtc/dtc_screen.dart';
import 'screens/performance/performance_screen.dart';
import 'screens/pids/pid_manager_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'widgets/telemetry/telemetry_recorder_strip.dart';

class _Destination {
  const _Destination(this.path, this.label, this.icon, this.selectedIcon);

  final String path;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

const _destinations = [
  _Destination(DashboardScreen.path, '儀表板', Icons.speed_outlined, Icons.speed),
  _Destination(PidManagerScreen.path, 'PID', Icons.tune_outlined, Icons.tune),
  _Destination(
    DtcScreen.path,
    '故障碼',
    Icons.warning_amber_outlined,
    Icons.warning_amber,
  ),
  _Destination(PerformanceScreen.path, '性能', Icons.timer_outlined, Icons.timer),
  _Destination(
    SettingsScreen.path,
    '設定',
    Icons.settings_outlined,
    Icons.settings,
  ),
];

class AppShell extends ConsumerStatefulWidget {
  const AppShell({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  bool _wakelockOn = false;

  @override
  void dispose() {
    if (_wakelockOn) unawaited(setAppWakelock(false));
    super.dispose();
  }

  /// Holds the screen awake while a session is live.
  ///
  /// Android blanks the display after the system timeout regardless of what is
  /// on it, and a dashboard that goes dark thirty seconds into a drive is worse
  /// than no dashboard — the driver has to reach over and wake it, which is the
  /// exact interaction this app exists to avoid.
  void _syncWakelock(bool shouldHold) {
    if (shouldHold == _wakelockOn) return;
    _wakelockOn = shouldHold;
    unawaited(setAppWakelock(shouldHold));
  }

  int _indexFor(BuildContext context) {
    final location = GoRouterState.of(context).uri.path;
    final index = _destinations.indexWhere((d) => location.startsWith(d.path));
    return index < 0 ? 0 : index;
  }

  @override
  Widget build(BuildContext context) {
    final index = _indexFor(context);
    final useRail = MediaQuery.sizeOf(context).width >= 720;
    final child = widget.child;

    _syncWakelock(ref.watch(obdSessionProvider).isConnected);

    // Losing the link mid-session drops back to the connection wizard rather
    // than leaving frozen gauges on screen looking like live data.
    ref.listen(obdSessionProvider, (previous, next) {
      if (previous?.isConnected == true &&
          next.phase == ConnectionPhase.failed) {
        context.go('/');
      }
    });

    if (useRail) {
      return Scaffold(
        body: Row(
          children: [
            _Rail(index: index),
            const VerticalDivider(width: 1),
            Expanded(
              child: Column(
                children: [
                  const SafeArea(
                    bottom: false,
                    child: TelemetryRecorderStrip(),
                  ),
                  Expanded(child: child),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: child,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const TelemetryRecorderStrip(),
          NavigationBar(
            selectedIndex: index,
            onDestinationSelected: (i) => context.go(_destinations[i].path),
            destinations: [
              for (final destination in _destinations)
                NavigationDestination(
                  icon: Icon(destination.icon),
                  selectedIcon: Icon(destination.selectedIcon),
                  label: destination.label,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    // The native rail scrolls only its destination group, retaining its own
    // layout, SafeArea and semantics at short landscape heights. Wrapping the
    // whole rail in an intrinsic-height scroll view duplicates this framework
    // behavior and makes the accessibility layout needlessly expensive.
    return NavigationRail(
      selectedIndex: index,
      onDestinationSelected: (i) => context.go(_destinations[i].path),
      scrollable: true,
      backgroundColor: palette.surface,
      labelType: NavigationRailLabelType.all,
      indicatorColor: palette.accent.withValues(alpha: 0.16),
      selectedIconTheme: IconThemeData(color: palette.accent, size: 22),
      unselectedIconTheme: IconThemeData(color: palette.textTertiary, size: 22),
      selectedLabelTextStyle: context.texts.labelMedium?.copyWith(
        color: palette.accent,
      ),
      unselectedLabelTextStyle: context.texts.labelMedium?.copyWith(
        color: palette.textTertiary,
      ),
      destinations: [
        for (final destination in _destinations)
          NavigationRailDestination(
            icon: Icon(destination.icon),
            selectedIcon: Icon(destination.selectedIcon),
            label: Text(destination.label),
          ),
      ],
    );
  }
}
