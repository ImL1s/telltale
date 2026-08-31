/// A scan that finds nothing has to say so, and say what to do next.
///
/// Found on an emulator, 2026-08-20: tapping 搜尋 BLE 裝置 ran a real scan —
/// Android's stack logged `le_scanning_manager` start and stop — found nothing,
/// and the screen returned to exactly the state it was in before. No message,
/// no result, no next step. The Bluetooth Classic branch has had an
/// `emptyHint` for this since it was written; the BLE branch never got one.
///
/// This is the connect screen's worst moment to be silent. Somebody is
/// standing at a car with an adapter plugged in, and the three things that
/// actually cause it — the adapter has no power because the ignition is off,
/// they are out of range, or the adapter is a Classic one and this is the
/// wrong list — are all invisible from a blank panel. Silence reads as "the
/// app is broken", which is the one conclusion that helps nobody.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/ui/screens/connect/connect_screen.dart';

void main() {
  test('the empty-scan guidance names the causes rather than the symptom', () {
    final text = bleEmptyScanGuidance(classicAvailable: true);

    expect(text, isNotEmpty);

    // Power. The commonest cause by a distance: an ELM327 on a switched socket
    // is dead until the ignition is on, and it advertises nothing at all.
    expect(text.contains('電門') || text.contains('通電'), isTrue,
        reason: 'an unpowered adapter is the commonest reason for an empty '
            'scan, and it is invisible from the app: $text');

    // The wrong list. A Classic-only adapter can never appear here, and the
    // user has no way to know that from a blank panel.
    expect(text.contains('Classic'), isTrue,
        reason: 'a Classic adapter cannot appear in a BLE scan, so the empty '
            'result has to offer that branch: $text');

    // The trap the pairing list sets. `which_transport_test.dart` covers the
    // routing question; this is the same trap reached from the other side —
    // somebody who finds nothing here will try to pair it in system settings.
    expect(text.contains('配對'), isTrue,
        reason: 'somebody who scans and finds nothing will go and pair it in '
            'system settings, which cannot work for a BLE adapter: $text');
  });

  test('hosts without Classic are not sent to the greyed-out Classic card', () {
    final text = bleEmptyScanGuidance(classicAvailable: false);
    expect(text.contains('改用上面的 Bluetooth Classic'), isFalse);
    expect(text.contains('Wi‑Fi') || text.contains('Wi-Fi'), isTrue);
    expect(text.contains('未開放 Bluetooth Classic'), isTrue);
  });

  test('it does not merely restate that the list is empty', () {
    // "找不到裝置" alone is the failure this test exists to prevent: it tells
    // the user something they can already see, and nothing they can act on.
    final text = bleEmptyScanGuidance(classicAvailable: true);
    expect(text.length, greaterThan(30),
        reason: 'a one-line restatement of the empty list is not guidance');
  });
}
