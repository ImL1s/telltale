/// A value that stopped arriving must stop looking live.
///
/// The dashboard's only test for staleness was `reading == null`, so a sensor
/// that went quiet kept its last believable number on screen styled exactly
/// like a fresh one. Nothing said it was minutes old.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/pid/pid.dart';
import 'package:torque_obd/obd/pid/priority_tier.dart';
import 'package:torque_obd/obd/telemetry.dart';

const _rpm = Pid(
  name: 'RPM',
  shortName: 'RPM',
  modeAndPid: '010C',
  equation: '((A*256)+B)/4',
  minValue: 0,
  maxValue: 8000,
  units: 'rpm',
  priority: PriorityTier.high,
);

const _ambient = Pid(
  name: 'Ambient',
  shortName: 'AMB',
  modeAndPid: '0146',
  equation: 'A-40',
  minValue: -40,
  maxValue: 215,
  units: '°C',
  priority: PriorityTier.low,
);

Reading _readingAt(Pid pid, DateTime at) =>
    Reading(pid: pid, value: 42, rawBytes: const [0x2A], timestamp: at);

void main() {
  final now = DateTime(2026, 8, 15, 12);

  group('how old is too old depends on the PID', () {
    test('a high-priority gauge tolerates seconds, not minutes', () {
      final reading = _readingAt(_rpm, now);
      expect(reading.isStaleAt(now.add(const Duration(seconds: 1))), isFalse);
      expect(reading.isStaleAt(now.add(const Duration(seconds: 3))), isTrue);
    });

    test('a low-priority signal is given more room', () {
      // A trip signal legitimately updates every few seconds; flagging it as
      // stale at two would flicker the tile for no reason.
      final fast = _readingAt(_rpm, now);
      final slow = _readingAt(_ambient, now);
      expect(slow.maxAge, greaterThan(fast.maxAge));
    });

    test('the ceiling stops any PID from looking live for a whole minute', () {
      expect(_readingAt(_ambient, now).maxAge,
          lessThanOrEqualTo(const Duration(seconds: 10)));
    });
  });

  group('the snapshot enforces it for every consumer', () {
    test('a snapshot that stopped being rebuilt still ages', () {
      // Staleness used to be measured against the snapshot's own `capturedAt`,
      // so a snapshot nobody was rebuilding could never go stale: the two
      // timestamps froze together. That is precisely the situation staleness
      // exists for — the polling loop's exception path returns without
      // publishing, and a protocol re-search keeps `SEARCHING...` arriving for
      // 25 seconds while every gauge holds pre-trouble values at full
      // brightness.
      final snapshot = TelemetrySnapshot(
        readings: {_rpm.id: _readingAt(_rpm, now)},
        capturedAt: now,
      );
      expect(snapshot.isStale(_rpm, now: now), isFalse);
      expect(
        snapshot.isStale(_rpm, now: now.add(const Duration(minutes: 5))),
        isTrue,
        reason: 'the reading has not changed, but five minutes have passed',
      );
      expect(snapshot.valueOf(_rpm, now: now.add(const Duration(minutes: 5))),
          isNull);
    });

    test('a fresh reading has a value', () {
      final snapshot = TelemetrySnapshot(
        readings: {_rpm.id: _readingAt(_rpm, now)},
        capturedAt: now,
      );
      expect(snapshot.valueOf(_rpm, now: now), 42);
      expect(snapshot.isStale(_rpm, now: now), isFalse);
    });

    test('a stale reading yields no value at all', () {
      // Enforced on the snapshot rather than at each call site: the
      // alternative is every consumer remembering to check, which is how a
      // dead sensor kept feeding the horsepower estimate.
      // The clock is what makes it stale, not the snapshot's build time: the
      // reading was taken at `now` and is being asked about 30 seconds later.
      final snapshot = TelemetrySnapshot(
        readings: {_rpm.id: _readingAt(_rpm, now)},
        capturedAt: now,
      );
      final later = now.add(const Duration(seconds: 30));
      expect(snapshot.valueOf(_rpm, now: later), isNull);
      expect(snapshot.isStale(_rpm, now: later), isTrue);
    });

    test('a missing reading is stale, not merely absent', () {
      const snapshot = TelemetrySnapshot();
      expect(snapshot.isStale(_rpm, now: now), isTrue);
    });
  });
}
