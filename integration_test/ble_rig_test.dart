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
///     flutter test integration_test/ble_rig_test.dart -d <device-id> \
///       --flavor rig \
///       --dart-define=TELLTALE_TEST_RIG=true
///
/// A fresh install must first receive the version-appropriate Android Bluetooth
/// permission grants documented in `tool/ble_test_rig/README.md`; widget tests
/// cannot approve the platform permission dialog.
///
/// A run that cannot find the peripheral reports it and stops rather than
/// passing quietly. Nothing here is allowed to be green without having
/// connected to something.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'rig_support.dart';

/// What the rig advertises as. Kept in one place so the rig and the test cannot
/// drift apart silently.
const String rigName = 'TelltaleELM';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scan, connect and talk to a real BLE peripheral', (
    tester,
  ) async {
    // This runs under the `.rig` debug application ID, never the field-test
    // release package. Start from a known state so an old successful recording
    // cannot make a failed run look green.
    await startCleanRigApp(tester);

    // 1. Open the Bluetooth LE section.
    final bleHeader = await revealText(tester, 'Bluetooth LE');
    await tester.tap(bleHeader);
    await tester.pumpAndSettle();

    // 2. Scan. The button is the only control in that section before a result.
    final scanButton = await revealText(tester, '搜尋 BLE 裝置');
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
    final rigLabel = find.text(rigName);
    final rigTile = find
        .ancestor(of: rigLabel, matching: find.byType(InkWell))
        .hitTestable();
    final resultsScroll = find
        .ancestor(of: rigLabel, matching: find.byType(Scrollable))
        .first;
    try {
      await tester.scrollUntilVisible(rigTile, 300, scrollable: resultsScroll);
    } on StateError catch (error) {
      fail('the discovered rig was not visible or tappable: $error');
    }
    expect(
      rigTile,
      findsOneWidget,
      reason: 'the discovered rig was not visible or tappable',
    );
    await tester.tap(rigTile);
    await tester.pump();

    // The handshake is a conversation, not a round trip: ATZ alone can take
    // several seconds on a real adapter, and the rig forwards every command to
    // a third-party emulator over TCP.
    await requireDashboard(tester);

    // A dashboard route alone is weak evidence: it can be reached before any
    // useful telemetry has crossed the platform channel. Require at least one
    // observed polling rate from the third-party ECU emulator.
    await requireLivePolling(
      tester,
      reason:
          'the dashboard never received live PIDs. The rig logs every '
          'exchange to /tmp/ble_bridge.log — the last line there is the '
          'command the app stopped on.',
    );

    // Inject the app's Dart lifecycle callbacks and use the real
    // Documents-directory store. OS Activity/Doze delivery is a separate
    // device gate; this test deliberately does not claim it.
    // The resulting header proves which GATT service/characteristics and CCCD
    // mode the platform path actually selected; the body proves bytes crossed
    // the link rather than a fake screen transition.
    pauseApp(tester);
    final paused = await waitForStoredTranscript(
      tester,
      (value) => value.body.contains('App 進入背景'),
    );
    expect(paused, isNotNull, reason: 'pause did not persist field evidence');
    expect(paused!.fromRealHardware, isFalse);
    expect(paused.header, contains('# Telltale 無車測試馬具證據 v1'));
    expect(paused.header, contains('不得視為實體轉接器或實車驗證'));
    expect(paused.header, contains('# 連線方式：Bluetooth LE'));
    expect(paused.header, contains('# 裝置：$rigName'));
    expect(paused.header, contains('OBDII to RS232 Interpreter'));
    expect(
      paused.header.toLowerCase(),
      contains(
        '# 連線資訊.selectedserviceuuid：'
        '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
      ),
    );
    expect(
      paused.header.toLowerCase(),
      contains(
        '# 連線資訊.selectedwritecharacteristicuuid：'
        '6e400002-b5a3-f393-e0a9-e50e24dcca9e',
      ),
    );
    expect(
      paused.header.toLowerCase(),
      contains(
        '# 連線資訊.selectednotifycharacteristicuuid：'
        '6e400003-b5a3-f393-e0a9-e50e24dcca9e',
      ),
    );
    expect(paused.header, contains('# 連線資訊.subscriptionKind：notification'));
    expect(paused.body, contains(r'>> ATZ\r'));
    expect(paused.body, contains(r'>> 0100\r'));
    expect(paused.body, contains('  << '));

    resumeApp(tester);
    await requireLivePolling(
      tester,
      timeout: const Duration(seconds: 20),
      reason: 'polling did not recover after resume',
    );

    // Snapshot once more so the recovery marker and its liveness probe are on
    // disk, not merely still in RAM when the test process exits.
    pauseApp(tester);
    final recovered = await waitForStoredTranscript(
      tester,
      (value) => value.body.contains('App 回到前景'),
    );
    expect(recovered, isNotNull);
    final resumedAt = recovered!.body.lastIndexOf('App 回到前景');
    final probeAt = recovered.body.indexOf(r'>> ATRV\r', resumedAt);
    expect(
      probeAt,
      greaterThan(resumedAt),
      reason: 'resume must prove the link before telemetry becomes live',
    );
    resumeApp(tester);
  });
}
