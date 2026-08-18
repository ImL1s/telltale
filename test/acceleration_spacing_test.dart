/// Acceleration, and the guard that used to defeat itself.
///
/// `_trackAcceleration` skips samples closer together than 80 ms, because OBD
/// speed is whole km/h and quantisation dominates below that. It advanced the
/// baseline *before* the check, so every sample became the new reference and
/// the interval could never grow past the threshold. On a link that delivers
/// speed more often than every 80 ms the EMA was therefore never updated at
/// all — and the faster the adapter, the more certainly.
///
/// What the driver sees: `accelerationMs2` ages out after two seconds, and the
/// whole derived row — power, torque, fuel rate, airflow — goes to
/// 「等待引擎轉速與車速資料」 while the rev counter and speedometer above it are
/// plainly moving. The explanation on screen names the two inputs that are not
/// missing.
///
/// Nothing caught it because the simulator sits at roughly 78–98 ms, either
/// side of the threshold. A real adapter that is merely quick is worse off than
/// the fake one, which is why this is tested by spacing rather than by running
/// the poller.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/polling_engine.dart';
import 'package:torque_obd/obd/transport/demo_transport.dart';

PollingEngine _engine() => PollingEngine(Elm327Client(DemoTransport()));

void main() {
  test('samples closer than the threshold still accumulate into a reading',
      () {
    // 40 ms apart — a quick Wi-Fi adapter on a small active set. Every gap is
    // under the threshold, so under the old shape not one of them was ever
    // used and `accelerationMs2` stayed null forever.
    final engine = _engine();
    var at = DateTime.now();
    var speed = 40.0;
    for (var i = 0; i < 10; i++) {
      engine.trackAccelerationForTest(speed, at);
      at = at.add(const Duration(milliseconds: 40));
      speed += 0.4; // ~2.8 m/s²
    }
    expect(engine.accelerationMs2, isNotNull,
        reason: 'a car that is plainly accelerating must produce an '
            'acceleration, however often the adapter answers');
    expect(engine.accelerationMs2, greaterThan(0));
  });

  test('and the quantisation guard still holds within a single gap', () {
    // The guard's actual job: two samples 40 ms apart, one whole km/h of
    // change, is 6.9 m/s² of quantisation noise. It must not be published as
    // one measurement — only as part of a longer span.
    final engine = _engine();
    final start = DateTime.now();
    engine.trackAccelerationForTest(40, start);
    engine.trackAccelerationForTest(
        41, start.add(const Duration(milliseconds: 40)));
    expect(engine.accelerationMs2, isNull,
        reason: 'one km/h across 40 ms is quantisation, not acceleration');
  });

  test('a steady speed reads as no acceleration, not as no data', () {
    final engine = _engine();
    var at = DateTime.now();
    for (var i = 0; i < 10; i++) {
      engine.trackAccelerationForTest(60, at);
      at = at.add(const Duration(milliseconds: 40));
    }
    expect(engine.accelerationMs2, isNotNull);
    expect(engine.accelerationMs2!.abs(), lessThan(0.2));
  });

  test('a gap still resets rather than carrying a stale launch forward', () {
    // Unchanged behaviour, pinned here because the fix moves the baseline
    // assignments and this is the branch that must keep one.
    final engine = _engine();
    final start = DateTime.now();
    var at = start;
    var speed = 40.0;
    for (var i = 0; i < 10; i++) {
      engine.trackAccelerationForTest(speed, at);
      at = at.add(const Duration(milliseconds: 100));
      speed += 1.0;
    }
    expect(engine.accelerationMs2, isNotNull);

    final afterGap = at.add(const Duration(seconds: 5));
    engine.trackAccelerationForTest(60, afterGap);
    expect(engine.accelerationMs2, isNull,
        reason: 'a hard launch that ended five seconds ago is not current');

    // And it recovers. The assertion above alone does not hold the branch:
    // delete the two baseline assignments inside the `dt > 3` reset and it
    // still passes, because the reset itself still happens. What that mutation
    // actually breaks is everything after — the stale baseline stays, so every
    // later sample is also more than three seconds from it, and the tracker
    // sits in a permanent reset loop with the derived row dead for the rest of
    // the session. Two more samples is the whole difference between pinning
    // the reset and pinning the recovery.
    engine.trackAccelerationForTest(
        61, afterGap.add(const Duration(milliseconds: 100)));
    engine.trackAccelerationForTest(
        62, afterGap.add(const Duration(milliseconds: 200)));
    expect(engine.accelerationMs2, isNotNull,
        reason: 'the gap ended; the car is measurable again');
  });
}
