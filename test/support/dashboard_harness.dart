/// Puts `DashboardScreen` on screen in a test.
///
/// It exists because nothing did. `grep -rn 'DashboardScreen' test/` was empty
/// before this file, and the dashboard is where two rules live that exist
/// nowhere else in the tree: the derived strip's refusal to compute without
/// acceleration (`_DerivedStrip`, one boolean) and the tile's decision to
/// replace a dial with 此車輛不支援 (`_GaugeTile`, one comparison). Both are
/// single expressions in a widget that no test loaded by any path, so either
/// could be weakened without turning the suite red.
///
/// Every provider the screen reads is overridden, so no `SharedPreferences`
/// and no transport are involved and the frame is deterministic.
/// [telemetryProvider] in particular is replaced rather than driven, because
/// its real body arms a one-second heartbeat `Timer` that outlives the test.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/core/theme/app_theme.dart';
import 'package:torque_obd/obd/physics/vehicle_profile.dart';
import 'package:torque_obd/obd/pid/pid.dart';
import 'package:torque_obd/obd/telemetry.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_registry.dart';
import 'package:torque_obd/state/settings.dart';
import 'package:torque_obd/ui/screens/dashboard/dashboard_screen.dart';

class _ConnectedSession extends ObdSession {
  @override
  ObdConnectionState build() => const ObdConnectionState(
        phase: ConnectionPhase.connected,
        kind: TransportKind.demo,
        deviceName: 'Demo ECU',
      );
}

class _FixedActivePids extends ActivePids {
  _FixedActivePids(this._pids);
  final List<Pid> _pids;

  @override
  List<Pid> build() => _pids;
}

class _FixedProfile extends VehicleProfileController {
  _FixedProfile(this._profile);
  final VehicleProfile _profile;

  @override
  VehicleProfile build() => _profile;
}

/// A reading timestamped now, so [TelemetrySnapshot.valueOf] treats it as live.
///
/// Staleness is measured against the wall clock, not against the snapshot, so a
/// fixture dated anything but "now" comes back null — and a test asserting that
/// a figure is absent would then pass for the wrong reason.
Reading liveReading(Pid pid, double value) => Reading(
      pid: pid,
      value: value,
      rawBytes: const [],
      timestamp: DateTime.now(),
    );

Future<void> pumpDashboard(
  WidgetTester tester, {
  required TelemetrySnapshot snapshot,
  List<Pid> activePids = const [],
  VehicleProfile profile = const VehicleProfile(),
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        obdSessionProvider.overrideWith(_ConnectedSession.new),
        activePidsProvider.overrideWith(() => _FixedActivePids(activePids)),
        vehicleProfileProvider.overrideWith(() => _FixedProfile(profile)),
        telemetryProvider.overrideWith((ref) => Stream.value(snapshot)),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: const DashboardScreen(),
      ),
    ),
  );
  // Long enough for the tiles' staggered entrance to finish; the fade is 28 ms
  // per tile and an unsettled animation hides text from the finders.
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 600));
}
