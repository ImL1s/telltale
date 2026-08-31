/// The "which one is mine?" questions, and the two ways they were wrong.
///
/// This card exists because competitor reviews put "picked the wrong connection
/// type" among the top causes of a first session that never connects — ahead of
/// anything to do with the vehicle. A card that routes somebody to a transport
/// their adapter cannot use is therefore worse than no card, because they will
/// believe the app told them the right answer.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/ui/screens/connect/connect_screen.dart';

void main() {
  test('it does not route on whether the adapter appears in the pairing list',
      () {
    // The first version asked exactly this, and sent everybody who said yes to
    // Bluetooth Classic. Android's "pair new device" scan lists BLE
    // peripherals as well as Classic ones, so a Vgate iCar Pro BLE or a
    // Veepeak OBDCheck BLE answers yes truthfully, is routed to Classic, and
    // cannot be paired at all — no SPP service, and their own manuals say not
    // to pair them in system settings. The BLE branch was unreachable for the
    // people who needed it.
    for (final classicAvailable in [true, false]) {
      final questions =
          whichTransportGuidance(classicAvailable: classicAvailable)
              .map((q) => q.question);
      for (final q in questions) {
        expect(q.contains('配對清單') || q.contains('配對新裝置'), isFalse,
            reason: 'visibility in the pairing list does not separate Classic '
                'from LE on Android, so it cannot be the question: "$q"');
      }
    }
  });

  test('the BLE answer says not to pair it, because the list will offer to',
      () {
    // Half the fix. Not asking about the pairing list stops the misroute; the
    // adapter still shows up there, and somebody who pairs it anyway is back
    // in the same dead end by a different door.
    final ble = whichTransportGuidance(classicAvailable: true)
        .firstWhere((q) => q.transport == TransportKind.bluetoothLe);
    expect(ble.answer, contains('不要去配對'));
  });

  test('and it says what to do when the box lied about 4.0', () {
    // The cheap clones are marked "Bluetooth 4.0" for a dual-mode chip they
    // only use in SPP. Somebody who answered honestly and found nothing needs
    // the next step attached to the answer that failed them.
    final ble = whichTransportGuidance(classicAvailable: true)
        .firstWhere((q) => q.transport == TransportKind.bluetoothLe);
    expect(ble.answer, contains('掃描不到'));
    expect(ble.answer, contains('Bluetooth Classic'));
  });

  test('desktop BLE guidance never points at disabled Classic', () {
    final ble = whichTransportGuidance(classicAvailable: false)
        .firstWhere((q) => q.transport == TransportKind.bluetoothLe);
    expect(ble.answer, contains('掃描不到'));
    expect(ble.answer, isNot(contains('改用 Bluetooth Classic')));
    expect(ble.answer, contains('Wi‑Fi'));
    expect(ble.answer, contains('未開放 Bluetooth Classic'));
  });

  test('a platform without SPP is not routed to Bluetooth Classic at all', () {
    // Not reworded — absent. The transport card on the same screen is disabled
    // where SPP is unavailable, and a question above it telling somebody to
    // pair a Classic adapter made one screen give two opposite instructions
    // with the wrong one first.
    //
    // Asked of `transport`, not of the prose: the BLE answer legitimately
    // mentions Classic as a fallback, and a substring check called that a
    // second route.
    final ios = whichTransportGuidance(classicAvailable: false);
    expect(ios.map((q) => q.transport),
        isNot(contains(TransportKind.bluetoothClassic)));
    expect(ios, hasLength(2));
  });

  test('a host without BLE is not routed to Bluetooth LE at all', () {
    // Guidance API still accepts an explicit bleAvailable:false for hosts that
    // might one day lack a stack. Shipping hosts all return
    // bleTransportAvailable == true (Linux uses Dart BlueZ, not a Flutter
    // plugin registrant).
    final noBle = whichTransportGuidance(
      classicAvailable: false,
      bleAvailable: false,
    );
    expect(noBle.map((q) => q.transport),
        isNot(contains(TransportKind.bluetoothLe)));
    expect(noBle.map((q) => q.transport), [TransportKind.wifi]);
  });

  test('the guidance and the transport card read the same predicate', () {
    // They used to have their own: the card asked `Platform.isAndroid`, the
    // guidance asked `!isIOS`. On macOS — a target this app builds for — those
    // disagree, so the card was greyed out saying Classic is unavailable while
    // four lines above it a question told you to pick it. One screen, two
    // answers, in the platform nobody checked.
    expect(
      whichTransportGuidance(classicAvailable: classicTransportAvailable)
          .any((q) => q.transport == TransportKind.bluetoothClassic),
      classicTransportAvailable,
      reason: 'offering Classic and being able to use it are the same '
          'question and must not be asked twice',
    );
    expect(
      whichTransportGuidance(
        classicAvailable: classicTransportAvailable,
        bleAvailable: bleTransportAvailable,
      ).any((q) => q.transport == TransportKind.bluetoothLe),
      bleTransportAvailable,
      reason: 'offering BLE and being able to use it are the same question',
    );
  });

  test('classic unavailable copy names the host constraint, not always iOS', () {
    // The card used to hard-code an iOS sentence for every non-Android host.
    // macOS/Windows/Linux already build this app; blaming iOS there is a lie.
    expect(classicUnavailableReason, isNot(isEmpty));
    if (!classicTransportAvailable) {
      expect(
        classicUnavailableReason.contains('iOS') ||
            classicUnavailableReason.contains('Android') ||
            classicUnavailableReason.contains('macOS') ||
            classicUnavailableReason.contains('Linux') ||
            classicUnavailableReason.contains('Windows'),
        isTrue,
      );
    }
  });

  test('BLE is available on every shipping host including Linux', () {
    // Linux uses universal_ble's Dart BlueZ backend; absence from
    // generated_plugins.cmake is expected and must not grey out the card.
    expect(bleTransportAvailable, isTrue);
    expect(bleUnavailableReason, isNot(isEmpty));
  });

  test('desktop Wi-Fi guidance does not pretend the host is a phone', () {
    final desktop = whichTransportGuidance(
      classicAvailable: false,
      phoneCentricCopy: false,
    ).firstWhere((q) => q.transport == TransportKind.wifi);
    expect(desktop.question, contains('系統'));
    expect(desktop.question, isNot(contains('手機')));
    expect(desktop.answer, contains('這台裝置'));
    expect(wifiConnectInstructions(isPhone: false), contains('這台電腦'));
    expect(wifiConnectInstructions(isPhone: true), contains('手機'));
  });

  test('each transport is the destination of exactly one question', () {
    // Two questions leading to the same place means one of them is not
    // separating anything, which is how the pairing-list version went wrong.
    final android = whichTransportGuidance(classicAvailable: true);
    expect(android, hasLength(3));
    for (final kind in [
      TransportKind.wifi,
      TransportKind.bluetoothLe,
      TransportKind.bluetoothClassic,
    ]) {
      expect(android.where((q) => q.transport == kind), hasLength(1),
          reason: '$kind');
    }
  });

  test('nothing routes to the simulator', () {
    // Demo is on the same screen and is the right answer to a different
    // question — "is the app itself working". Routing hardware here would tell
    // somebody with a real adapter that their car is a simulation.
    for (final classicAvailable in [true, false]) {
      for (final bleAvailable in [true, false]) {
        for (final q in whichTransportGuidance(
          classicAvailable: classicAvailable,
          bleAvailable: bleAvailable,
        )) {
          expect(q.transport, isNot(TransportKind.demo), reason: q.question);
        }
      }
    }
  });
}
