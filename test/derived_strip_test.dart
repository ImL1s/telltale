/// The one place that decides whether a horsepower figure may be shown.
///
/// `_DerivedStrip` gates every derived number behind engine speed, road speed
/// **and** acceleration being present. That gate is a single boolean in a
/// widget, and the model behind it enforces nothing: `PhysicsEngine.derive`
/// takes non-nullable doubles, and `DerivedMetrics` exposes its four power and
/// torque fields as non-nullable doubles defaulting to 0. So `accelMs2: accel
/// ?? 0` compiles, the physics happily produces a steady-cruise answer from a
/// measurement nobody took, and the tile presents it in the same type as a
/// sensor reading.
///
/// Until this file existed nothing loaded `DashboardScreen` — `grep -rn
/// 'DashboardScreen' test/` returned nothing — so that weakening was a green
/// suite away. Verified by making it: dropping the null check and substituting
/// zero turns the four tests below red and leaves the other 800-odd untouched.
///
/// The mirror cases matter as much as the refusals. A gate that never opens
/// also passes "no acceleration, no horsepower", and would hide the figure on
/// every car forever.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/telemetry.dart';

import 'support/dashboard_harness.dart';

/// 2000 rpm at 60 km/h, with acceleration supplied or withheld.
TelemetrySnapshot _snapshot({
  double? accel,
  bool withRpm = true,
  bool withSpeed = true,
}) =>
    TelemetrySnapshot(
      readings: {
        if (withRpm)
          PidLibrary.engineRpm.id: liveReading(PidLibrary.engineRpm, 2000),
        if (withSpeed)
          PidLibrary.vehicleSpeed.id: liveReading(PidLibrary.vehicleSpeed, 60),
        PidLibrary.mafRate.id: liveReading(PidLibrary.mafRate, 12.5),
      },
      accelerationMs2: accel,
      capturedAt: DateTime.now(),
    );

/// One gauge on the wall.
///
/// Not decoration: with no active PIDs the empty state is a
/// `SliverFillRemaining`, which occupies the whole viewport, and the derived
/// strip below it is then never built — so every assertion here would pass
/// against a screen that renders nothing at all.
final _activePids = [PidLibrary.engineRpm];

const _waiting = '等待引擎轉速與車速資料';

void main() {
  group('the derived strip refuses to compute from an input it does not have',
      () {
    testWidgets('no acceleration means no horsepower and no torque',
        (tester) async {
      // The inertial term is the whole reason acceleration is an input. Absent,
      // the estimate accounts only for drag and rolling resistance — which is
      // not a conservative figure, it is a confident wrong one, and it is
      // indistinguishable on the tile from a measured value.
      await pumpDashboard(tester,
          snapshot: _snapshot(accel: null), activePids: _activePids);

      expect(find.textContaining(_waiting), findsOneWidget);
      expect(find.text('引擎馬力'), findsNothing);
      expect(find.text('hp'), findsNothing);
      expect(find.text('扭力'), findsNothing);
      expect(find.text('N·m'), findsNothing);
    });

    testWidgets('no engine speed means no derived figures', (tester) async {
      await pumpDashboard(tester,
          snapshot: _snapshot(accel: 0.4, withRpm: false),
          activePids: _activePids);

      expect(find.textContaining(_waiting), findsOneWidget);
      expect(find.text('hp'), findsNothing);
    });

    testWidgets('no road speed means no derived figures', (tester) async {
      await pumpDashboard(tester,
          snapshot: _snapshot(accel: 0.4, withSpeed: false),
          activePids: _activePids);

      expect(find.textContaining(_waiting), findsOneWidget);
      expect(find.text('hp'), findsNothing);
    });
  });

  group('and shows them once every input is actually present', () {
    testWidgets('all three inputs produce a horsepower and a torque cell',
        (tester) async {
      // Without this the suppression tests above would pass just as well
      // against a strip that never renders anything.
      await pumpDashboard(tester,
          snapshot: _snapshot(accel: 0.8), activePids: _activePids);

      expect(find.textContaining(_waiting), findsNothing);
      expect(find.text('推算數值'), findsOneWidget);
      expect(find.text('引擎馬力'), findsOneWidget);
      expect(find.text('hp'), findsOneWidget);
      expect(find.text('扭力'), findsOneWidget);
      expect(find.text('N·m'), findsOneWidget);
    });

    testWidgets('a measured zero acceleration is a measurement, not a gap',
        (tester) async {
      // Steady cruise. The number that `accel ?? 0` fabricates is the same
      // number this case legitimately reports, which is exactly why the two
      // cannot be told apart downstream and the distinction has to be kept
      // here.
      await pumpDashboard(tester,
          snapshot: _snapshot(accel: 0), activePids: _activePids);

      expect(find.textContaining(_waiting), findsNothing);
      expect(find.text('hp'), findsOneWidget);
    });
  });
}
