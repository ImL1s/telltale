/// The emissions readiness monitors.
///
/// The rule this file exists to hold is the one a naive implementation gets
/// backwards: a monitor can be **not supported by this vehicle**, which is a
/// formal J1979 state and not a failure. Almost every car reports several that
/// way. Rendering those as "incomplete" makes a ready vehicle look unready —
/// the same class of error as reporting a vehicle clean when it is not, in the
/// other direction.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/readiness.dart';

void main() {
  group('the three continuous monitors, out of byte B', () {
    test('supported and complete', () {
      // Bits 0–2 set (supported), bits 4–6 clear (not incomplete).
      final r = Readiness.decode(0x07, 0x00, 0x00);
      expect(r.states[ReadinessMonitor.misfire], ReadinessState.complete);
      expect(r.states[ReadinessMonitor.fuelSystem], ReadinessState.complete);
      expect(r.states[ReadinessMonitor.components], ReadinessState.complete);
    });

    test('supported and incomplete', () {
      final r = Readiness.decode(0x77, 0x00, 0x00);
      expect(r.states[ReadinessMonitor.misfire], ReadinessState.incomplete);
      expect(r.states[ReadinessMonitor.fuelSystem], ReadinessState.incomplete);
      expect(r.states[ReadinessMonitor.components], ReadinessState.incomplete);
    });

    test('unsupported reads as unsupported, not as incomplete', () {
      // The one that matters. Support bits clear, incompleteness bits set —
      // which is a contradiction the vehicle should not report, and must not
      // be resolved by inventing "incomplete" out of it.
      final r = Readiness.decode(0x70, 0x00, 0x00);
      expect(r.states[ReadinessMonitor.misfire], ReadinessState.unsupported);
      expect(r.states[ReadinessMonitor.fuelSystem], ReadinessState.unsupported);
      expect(r.states[ReadinessMonitor.components], ReadinessState.unsupported);
      expect(r.incomplete, isEmpty,
          reason: 'a monitor this car does not have cannot be unfinished');
    });
  });

  group('ignition type decides what C and D mean', () {
    test('bit 3 clear is spark ignition, and names the petrol monitors', () {
      final r = Readiness.decode(0x00, 0xFF, 0x00);
      expect(r.ignition, IgnitionType.spark);
      expect(r.states.keys, contains(ReadinessMonitor.catalyst));
      expect(r.states.keys, contains(ReadinessMonitor.evaporative));
      expect(r.states.keys, isNot(contains(ReadinessMonitor.particulateFilter)),
          reason: 'a petrol car has no diesel particulate filter monitor, and '
              'showing one would be a row nobody can act on');
    });

    test('bit 3 set is compression ignition, and names the diesel monitors',
        () {
      final r = Readiness.decode(0x08, 0xFF, 0x00);
      expect(r.ignition, IgnitionType.compression);
      expect(r.states.keys, contains(ReadinessMonitor.particulateFilter));
      expect(r.states.keys, contains(ReadinessMonitor.noxAftertreatment));
      expect(r.states.keys, isNot(contains(ReadinessMonitor.evaporative)),
          reason: 'a diesel has no evaporative emissions monitor');
    });
  });

  group('bytes C and D pair up per monitor', () {
    test('supported in C, incomplete in D', () {
      // Catalyst is bit 0 of both.
      final r = Readiness.decode(0x00, 0x01, 0x01);
      expect(r.states[ReadinessMonitor.catalyst], ReadinessState.incomplete);
    });

    test('supported in C, complete because D is clear', () {
      final r = Readiness.decode(0x00, 0x01, 0x00);
      expect(r.states[ReadinessMonitor.catalyst], ReadinessState.complete);
    });

    test('a bit set only in D is unsupported, not incomplete', () {
      // The contradiction case again, on the other pair of bytes.
      final r = Readiness.decode(0x00, 0x00, 0x01);
      expect(r.states[ReadinessMonitor.catalyst], ReadinessState.unsupported);
    });
  });

  group('what the whole report says', () {
    test('a car with everything it has finished is complete', () {
      final r = Readiness.decode(0x07, 0x21, 0x00);
      expect(r.allSupportedComplete, isTrue);
      expect(r.incomplete, isEmpty);
      expect(r.unsupported, isNotEmpty,
          reason: 'unsupported monitors are ordinary and stay listed, because '
              'somebody comparing against an inspection report needs them');
    });

    test('one unfinished monitor is enough to say so', () {
      final r = Readiness.decode(0x17, 0x21, 0x00);
      expect(r.allSupportedComplete, isFalse);
      expect(r.incomplete, [ReadinessMonitor.misfire]);
    });

    test('all zeroes is not a clean bill of health', () {
      // A module that does not participate in emissions monitoring answers
      // this way. Reading it as "ready" turns silence into an answer, which is
      // the mistake this whole codebase is organised against.
      final r = Readiness.decode(0x00, 0x00, 0x00);
      expect(r.saysNothing, isTrue);
      expect(r.allSupportedComplete, isFalse,
          reason: 'nothing was reported ready, so nothing may be reported '
              'ready');
    });
  });

  test('a real reply decodes end to end', () {
    // `41 01 81 07 65 04` — a typical warmed-up petrol car with the lamp on:
    // A = 0x81 (MIL on, one confirmed code), B = 0x07 (three continuous
    // monitors supported and complete), C = 0x65, D = 0x04.
    final r = Readiness.decode(0x07, 0x65, 0x04);
    expect(r.ignition, IgnitionType.spark);
    // C = 0x65 sets bits 0, 2, 5 and 6; D = 0x04 sets bit 2. Bit 2 is the
    // evaporative system, so that is the one supported and unfinished — the
    // commonest thing to find outstanding after a battery disconnect, and the
    // usual reason a car fails an inspection with no fault codes at all.
    expect(r.incomplete, [ReadinessMonitor.evaporative]);
    expect(r.complete, contains(ReadinessMonitor.misfire));
    expect(r.complete, contains(ReadinessMonitor.catalyst));
    expect(r.unsupported, contains(ReadinessMonitor.heatedCatalyst));
  });

  group('no monitor the vehicle set may vanish', () {
    test('the petrol bit 4 monitor is decoded, not dropped', () {
      // Round 34. Bit 4 is named in the original J1979 and marked reserved in
      // later revisions, so it was left out — and leaving it out meant a car
      // that supports it and has not finished it reported *nothing*
      // outstanding, and the screen said it was ready. A false all-clear about
      // an inspection somebody is about to drive to.
      final r = Readiness.decode(0x07, 0x10, 0x10);
      expect(r.states[ReadinessMonitor.gasolineParticulateFilter],
          ReadinessState.incomplete);
      expect(r.incomplete, [ReadinessMonitor.gasolineParticulateFilter]);
      expect(r.allSupportedComplete, isFalse);
    });

    test('and a bit no table names still blocks "ready"', () {
      // The structural version, which matters more than the one bit. Fixing
      // only bit 4 would leave the same shape waiting for the next revision or
      // the next manufacturer. Diesel has no bit 2 or bit 4 in its map, so a
      // vehicle setting either is a monitor this code cannot name.
      final r = Readiness.decode(0x08 | 0x07, 0x04, 0x04);
      expect(r.unnamedOutstanding, greaterThan(0));
      expect(r.allSupportedComplete, isFalse,
          reason: 'a monitor this code cannot name is still a monitor the '
              'vehicle says is unfinished');
    });

    test('a controller whose only monitor is unnamed and finished is ready',
        () {
      // Round 35, and the over-strict twin of the counter added in round 34 —
      // introduced by the same commit that fixed the first half.
      //
      // Diesel, no continuous monitors supported, and the only thing it does
      // monitor is a bit this table cannot name. It has finished it. The app
      // said 這個控制器沒有回報任何監控項目 — that it monitors nothing — when it
      // had reported something: that it was done.
      final r = Readiness.decode(0x08, 0x04, 0x00);
      expect(r.unnamedSupported, 1);
      expect(r.unnamedOutstanding, 0);
      expect(r.saysNothing, isFalse,
          reason: 'it reported a supported monitor, which is not nothing');
      expect(r.allSupportedComplete, isTrue,
          reason: 'everything it monitors is finished, which is the question '
              'somebody about to drive to an inspection is asking');
    });

    test('and the same controller with that monitor unfinished is not', () {
      // The direction that must not move with it.
      final r = Readiness.decode(0x08, 0x04, 0x04);
      expect(r.saysNothing, isFalse);
      expect(r.allSupportedComplete, isFalse);
    });

    test('an unnamed bit that is *complete* does not block anything', () {
      // Supported and finished. There is nothing outstanding, so inventing a
      // reason to withhold "ready" would be the over-strict twin of the bug —
      // the failure this file's header is about, in the other direction.
      final r = Readiness.decode(0x08 | 0x07, 0x04, 0x00);
      expect(r.unnamedOutstanding, 0);
      expect(r.allSupportedComplete, isTrue);
    });

    test('the over-strict twin: only unnamed monitors supported and complete', () {
      final r = Readiness.decode(0x08, 0x04, 0x00);
      expect(r.unnamedOutstanding, 0);
      expect(r.allSupportedComplete, isTrue);
    });
  });
}
