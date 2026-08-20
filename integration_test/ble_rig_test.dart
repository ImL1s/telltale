/// The BLE path, end to end, against a peripheral that is not a fake.
///
/// Everything else in this suite stops at the platform channel: 18 unit tests
/// drive a scripted fake platform, and scanning has been exercised by hand on a
/// phone. What none of them reach is a real GATT connect, a real service
/// discovery, a real CCCD subscribe, and real notifications carrying an ELM327
/// conversation — the exact region that changed when the BLE package was
/// replaced.
///
/// **Why this is an integration test rather than an `adb shell input` script.**
/// A phone that is a useful BLE target has a secure lockscreen, and `input tap`
/// goes to the lockscreen, not to the app behind it. This driver injects widget
/// events directly, so it runs whether or not anyone is looking at the screen —
/// which turns "unlock your phone and stand here while I tap" into "plug it in".
///
/// Before running, start the peripheral on a **second machine** (a Mac cannot
/// see its own):
///
///     app/tool/ble_test_rig/run.sh
///
/// Then, with a device attached:
///
///     flutter test integration_test/ble_rig_test.dart -d <device-id>
///
/// A run that cannot find the peripheral reports it and stops rather than
/// passing quietly. Nothing here is allowed to be green without having
/// connected to something.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:torque_obd/main.dart' as app;

/// What the rig advertises as. Kept in one place so the rig and the test cannot
/// drift apart silently.
const String rigName = 'TelltaleELM';

/// Pumps for up to [timeout], returning true as soon as [predicate] holds.
///
/// `pumpAndSettle` is wrong for a scan: the screen has a spinner, so it never
/// settles, and the call times out having proved nothing about the scan.
Future<bool> pumpUntil(
  WidgetTester tester,
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 30),
  Duration step = const Duration(milliseconds: 250),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return true;
    await tester.pump(step);
  }
  return predicate();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scan, connect and talk to a real BLE peripheral', (tester) async {
    unawaited(app.main());
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // 1. Open the Bluetooth LE section.
    final bleHeader = find.text('Bluetooth LE');
    expect(bleHeader, findsOneWidget,
        reason: 'the connect screen must offer a Bluetooth LE transport');
    await tester.tap(bleHeader);
    await tester.pumpAndSettle();

    // 2. Scan. The button is the only control in that section before a result.
    final scanButton = find.text('搜尋 BLE 裝置');
    expect(scanButton, findsOneWidget);
    await tester.tap(scanButton);
    await tester.pump();

    final found = await pumpUntil(
      tester,
      () => find.text(rigName).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 40),
    );

    if (!found) {
      // Deliberately a failure, not a skip. A green run that never reached a
      // peripheral is the exact shape of evidence this repository refuses
      // everywhere else: it cannot be told apart from a run that worked.
      fail(
        'no peripheral named "$rigName" was found in 40 seconds.\n'
        'Start it with app/tool/ble_test_rig/run.sh on a SECOND machine — a '
        'Mac cannot see its own peripheral — and check that Bluetooth is on '
        'and the device is in range.',
      );
    }

    // 3. Connect. This is the part that has never run outside a fake platform:
    //    GATT connect, service discovery, the UART pair, the CCCD subscribe.
    await tester.tap(find.text(rigName));
    await tester.pump();

    // The handshake is a conversation, not a round trip: ATZ alone can take
    // several seconds on a real adapter, and the rig forwards every command to
    // a third-party emulator over TCP.
    final connected = await pumpUntil(
      tester,
      () =>
          find.textContaining('儀表板').evaluate().isNotEmpty ||
          find.textContaining('PIDs/s').evaluate().isNotEmpty,
      timeout: const Duration(seconds: 90),
    );

    expect(connected, isTrue,
        reason: 'the handshake did not complete against the rig. The rig logs '
            'every exchange to /tmp/ble_bridge.log — the last line there is '
            'the command the app stopped on.');
  });
}
