/// A derived figure has to say where it came from, and refuse to exist when it
/// cannot be computed.
///
/// The old code substituted `MAP = 0` and `IAT = 20 °C` for missing inputs.
/// Zero manifold pressure zeroes the whole product, so a car at 3000 rpm
/// reported `0.0 g/s` — which is what a stopped engine looks like. And an
/// assumed ambient temperature is not a conservative fallback; it is an
/// invented measurement that flows straight into the consumption figure.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/physics/physics_engine.dart';
import 'package:torque_obd/obd/physics/vehicle_profile.dart';
import 'package:torque_obd/obd/pid/formula_engine.dart';

const _profile = VehicleProfile();

DerivedMetrics _derive({
  double? maf,
  double? map,
  double? iat,
  double? fuelRateSensor,
  double rpm = 3000,
  double speed = 60,
}) =>
    PhysicsEngine.derive(
      profile: _profile,
      rpm: rpm,
      speedKmh: speed,
      accelMs2: 0,
      mafSensorGps: maf,
      mapKpa: map,
      intakeTempC: iat,
      fuelRateSensorLPerHour: fuelRateSensor,
    );

void main() {
  group('air mass', () {
    test('a sensor reading is used and labelled as measured', () {
      final m = _derive(maf: 12.5);
      expect(m.mafGramsPerSecond, closeTo(12.5, 0.001));
      expect(m.airflowSource, AirflowSource.measured);
    });

    test('speed-density is used when the full input set is present', () {
      final m = _derive(map: 100, iat: 30);
      expect(m.mafGramsPerSecond, greaterThan(0));
      expect(m.airflowSource, AirflowSource.speedDensity);
    });

    test('a missing MAP yields no figure rather than zero', () {
      // Codex's trigger: RPM 3000, speed 60, MAF and MAP both NO DATA. The old
      // code displayed 0.0 g/s as though it had been measured.
      final m = _derive(iat: 30);
      expect(m.mafGramsPerSecond, isNull);
      expect(m.airflowSource, AirflowSource.unavailable);
    });

    test('a missing intake temperature is not assumed to be 20 °C', () {
      // Assuming 20 °C where the intake is at 80 °C overstates air mass by
      // roughly a fifth, and nothing on the tile says so.
      final m = _derive(map: 100);
      expect(m.mafGramsPerSecond, isNull);
      expect(m.airflowSource, AirflowSource.unavailable);
    });
  });

  group('fuel', () {
    test("the ECU's own rate wins over the stoichiometric estimate", () {
      // PID 015E accounts for the mixture actually being run; the estimate
      // assumes lambda 1 and is wrong by roughly lambda on anything that is
      // not — a diesel at lambda 2 comes out about twice its real consumption.
      final m = _derive(maf: 12.5, fuelRateSensor: 4.2);
      expect(m.fuelRateLPerHour, closeTo(4.2, 0.001));
      expect(m.fuelSource, FuelSource.measured);
    });

    test('the estimate is used as a fallback and labelled as one', () {
      final m = _derive(maf: 12.5);
      expect(m.fuelRateLPerHour, greaterThan(0));
      expect(m.fuelSource, FuelSource.stoichiometricEstimate);
    });

    test('no air mass means no fuel figure at all', () {
      final m = _derive();
      expect(m.fuelRateLPerHour, isNull);
      expect(m.fuelSource, FuelSource.unavailable);
      expect(m.litresPer100Km, isNull);
    });

    test('consumption per distance needs the car to be moving', () {
      final m = _derive(maf: 12.5, speed: 0);
      expect(m.isMoving, isFalse);
      expect(m.litresPer100Km, isNull);
      // The per-hour figure still stands still.
      expect(m.fuelRateLPerHour, greaterThan(0));
    });
  });

  group('formula domain errors are errors', () {
    final engine = FormulaEngine();

    test('LOG10 of a non-positive number fails rather than answering zero', () {
      // `LOG10(A-128)` with A = 0 used to display a confident 0.
      expect(
        () => engine.evaluateBytes('LOG10(A-128)', const [0x00]),
        throwsA(isA<FormulaException>()),
      );
    });

    test('a non-finite intermediate does not collapse the expression', () {
      // `((-1)^0.5)+90` quietly became 90 — an invalid expression producing a
      // plausible temperature.
      expect(
        () => engine.evaluateBytes('((0-1)^0.5)+90', const [0x00]),
        throwsA(isA<FormulaException>()),
      );
    });

    test('ordinary arithmetic still works', () {
      expect(engine.evaluateBytes('A-40', const [0x82]), closeTo(90, 0.001));
      expect(engine.evaluateBytes('LOG10(A)', const [100]), closeTo(2, 0.001));
    });
  });

  group('a manifold pressure of zero is a broken sensor, not thin air', () {
    test('it produces no airflow rather than a confident zero', () {
      // `41 0B 00` — 0 kPa — is what a failed MAP sensor or a disconnected
      // line answers. A running engine cannot produce it: 0 kPa absolute is
      // vacuum, and the manifold of a 3000 rpm engine is nowhere near it.
      //
      // Speed-density returned 0 for that input and `derive` only checked that
      // MAP was *present*, so the row showed 空氣流量 0.0 g/s under the label
      // 「Speed-Density 推算」 — which is what a stopped engine looks like, from
      // a car at 3000 rpm. `mafGramsPerSecond`'s own doc comment records that
      // exact sentence as a bug already fixed; it came back through a door the
      // type left open, because a function returning `double` gave the caller
      // nothing to check.
      final broken = _derive(map: 0, iat: 30);
      expect(broken.mafGramsPerSecond, isNull);
      expect(broken.airflowSource, AirflowSource.unavailable,
          reason: 'and it must not be labelled as an estimate that succeeded');
    });

    test('the row does not contradict itself about the same engine', () {
      // The tell that made this findable by eye: airflow said 0.0 with
      // confidence while fuel rate — whose own guard is `maf > 0` — said it
      // could not be determined. One row, one engine, two answers.
      final broken = _derive(map: 0, iat: 30);
      expect(broken.mafGramsPerSecond, isNull);
      expect(broken.fuelRateLPerHour, isNull);
    });

    test('a volumetric efficiency of zero is refused too', () {
      // The slider is bounded 50–130, but `VehicleProfile.fromJson` does not
      // clamp — a corrupted preference or a schema from another version
      // reaches the formula unchecked, and zero produces the same confident
      // 0.0 g/s the nullable return exists to prevent.
      expect(
        PhysicsEngine.speedDensityMaf(
          rpm: 3000,
          mapKpa: 60,
          intakeTempC: 30,
          displacementL: 2.0,
          volumetricEfficiencyPct: 0,
        ),
        isNull,
      );
      expect(
        PhysicsEngine.speedDensityMaf(
          rpm: 3000,
          mapKpa: 60,
          intakeTempC: 30,
          displacementL: 2.0,
          volumetricEfficiencyPct: -85,
        ),
        isNull,
        reason: 'and a negative one does not produce negative air',
      );
    });

    test('a plausible manifold pressure still estimates', () {
      // The other direction, so the guard above cannot be satisfied by
      // refusing speed-density altogether.
      final ok = _derive(map: 60, iat: 30);
      expect(ok.mafGramsPerSecond, isNotNull);
      expect(ok.mafGramsPerSecond, greaterThan(0));
      expect(ok.airflowSource, AirflowSource.speedDensity);
    });

    test('an impossible intake temperature is refused the same way', () {
      // Below absolute zero. Same class: an input no engine can produce,
      // arriving from a sensor that has failed.
      final frozen = _derive(map: 60, iat: -300);
      expect(frozen.mafGramsPerSecond, isNull);
      expect(frozen.airflowSource, AirflowSource.unavailable);
    });
  });

  group('a measured zero is a measurement', () {
    test('deceleration fuel cut is not replaced with an estimate', () {
      // During fuel cut the ECU reports exactly 0.0 L/h on `015E` while RPM,
      // speed and MAF stay positive. The sensor was accepted only when
      // `> 0`, so zero read as "no sensor" and a stoichiometric estimate took
      // its place — a positive fuel rate substituted for a figure the vehicle
      // had supplied. Labelling it "derived" is honest about provenance and
      // still the wrong number.
      final cut = _derive(fuelRateSensor: 0, maf: 12.5);
      expect(cut.fuelRateLPerHour, equals(0));

      // The estimate is what it would otherwise have shown, and it is not zero.
      final estimated = _derive(maf: 12.5);
      expect(estimated.fuelRateLPerHour, greaterThan(0));
    });

    test('a negative or non-finite sensor value still falls back', () {
      // Those are not measurements. Only zero was being misread as one.
      expect(_derive(fuelRateSensor: -1, maf: 12.5).fuelRateLPerHour,
          greaterThan(0));
      expect(_derive(fuelRateSensor: double.nan, maf: 12.5).fuelRateLPerHour,
          greaterThan(0));
    });
  });
}
