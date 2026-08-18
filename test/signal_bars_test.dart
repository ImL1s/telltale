/// Signal strength, and what it must not claim.
///
/// `signalBars` shipped with full dBm thresholds and no caller anywhere — dead
/// code found by a competitor review looking for features we already had the
/// data for. Wiring it up meant first fixing what it did with an absent
/// reading: it returned **four bars**, the best possible answer, for a device
/// that had reported no signal at all.
///
/// That is not cosmetic. This is the row somebody reads to pick the adapter out
/// of five similarly-named devices — the one in the car two feet away should be
/// the loud one — and a bonded Classic device has no RSSI until something
/// scans, which is most of the list most of the time. Unknown drawn as
/// excellent is the same failure this codebase is arranged against, arriving
/// somewhere it would be dismissed as decoration.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';

DiscoveredDevice _device({int? rssi}) => DiscoveredDevice(
      id: '00:11:22:33:44:55',
      name: 'V-LINK',
      kind: TransportKind.bluetoothLe,
      rssi: rssi,
    );

void main() {
  test('no reading is no bars, not full bars', () {
    expect(_device().signalBars, isNull,
        reason: 'the caller draws nothing for null; drawing four would tell '
            'somebody the device across the car park is the strong one');
  });

  group('the thresholds', () {
    test('very close is four', () {
      expect(_device(rssi: -30).signalBars, 4);
      expect(_device(rssi: -55).signalBars, 4);
    });

    test('good is three', () {
      expect(_device(rssi: -56).signalBars, 3);
      expect(_device(rssi: -67).signalBars, 3);
    });

    test('fair is two', () {
      expect(_device(rssi: -68).signalBars, 2);
      expect(_device(rssi: -78).signalBars, 2);
    });

    test('weak is one', () {
      expect(_device(rssi: -79).signalBars, 1);
      expect(_device(rssi: -90).signalBars, 1);
    });

    test('beyond usable is zero, and zero is not null', () {
      // Distinct states: "measured, and it is terrible" is actionable — move
      // the phone, or that is not the adapter in this car. "Not measured" is
      // not. Collapsing them loses the only one worth acting on.
      expect(_device(rssi: -91).signalBars, 0);
      expect(_device(rssi: -120).signalBars, 0);
      expect(_device(rssi: -91).signalBars, isNotNull);
    });
  });

  test('the scale is monotonic', () {
    // A stronger signal can never show fewer bars. Cheap to state, and the
    // kind of thing an edited threshold breaks silently.
    int? previous;
    for (var dbm = -120; dbm <= -20; dbm++) {
      final bars = _device(rssi: dbm).signalBars!;
      if (previous != null) {
        expect(bars, greaterThanOrEqualTo(previous),
            reason: '$dbm dBm gave $bars after $previous');
      }
      previous = bars;
    }
    expect(previous, 4);
  });
}
