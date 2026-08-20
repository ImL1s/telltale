/// A raw Dart exception is not a message to a person standing at a car.
///
/// Found on a phone, 2026-08-20, connecting to a BLE peripheral that accepts a
/// GATT connection and then answers nothing. The screen said:
///
///     TimeoutException after 0:00:10.000000: Future not completed
///
/// That is `'$e'` reaching the user through `_failAttempt`. One branch away,
/// the handshake failure path says 「初始化未通過，轉接器可能不相容」 — a
/// sentence somebody can act on. The connect path had no equivalent, so every
/// exception that is not a `TransportException` arrived verbatim.
///
/// The technical string still matters — it is exactly what a maintainer wants
/// out of an exported transcript — so this is not about deleting it. It is
/// about which of the two audiences gets it.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a timeout is explained, not printed', () {
    final text = describeConnectException(
      TimeoutException('Future not completed', const Duration(seconds: 10)),
    );

    for (final leak in [
      'TimeoutException',
      'Future not completed',
      '0:00:10',
    ]) {
      expect(text.contains(leak), isFalse,
          reason: 'the exception leaked into the screen: $text');
    }

    // Actionable, and specific to the commonest cause: an adapter on a
    // switched socket has no power until the ignition is on, and it accepts a
    // connection long before it answers anything.
    expect(text.contains('電門') || text.contains('通電'), isTrue,
        reason: 'a timeout at connect is usually an unpowered adapter: $text');
  });

  test('an unknown failure does not leak its class name either', () {
    final text = describeConnectException(StateError('bad state: internal'));
    expect(text.contains('StateError'), isFalse, reason: text);
    expect(text.contains('bad state'), isFalse, reason: text);
    expect(text.length, greaterThan(10),
        reason: 'silence is not an improvement on a stack trace');
  });

  test('the raw exception is kept where a maintainer will read it', () async {
    // The other half of the fix, and the half that could silently rot: the
    // screen stops showing `TimeoutException …`, and the promise made in its
    // place — 「這次嘗試的完整往返紀錄留著了」— is only true if the transcript
    // still has it. Translating the message and dropping the evidence would be
    // a worse outcome than the raw string was.
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);

    final ok = await session.connectForTest(
      _ThrowingTransport(),
      TransportKind.bluetoothLe,
    );
    expect(ok, isFalse);

    final record = session.exportableRecord;
    expect(record, isNotNull, reason: 'a failed attempt still has a recording');
    final text = record!.transcript.render();
    expect(text, contains('TimeoutException'),
        reason: 'the transcript is where the exception belongs: $text');
    expect(container.read(obdSessionProvider).error, isNotNull);
    expect(container.read(obdSessionProvider).error!.contains('TimeoutException'),
        isFalse,
        reason: 'and it is not what the driver is shown');
  });
}

/// A transport whose connect times out the way a peripheral that accepts a
/// GATT link and then answers nothing does.
class _ThrowingTransport extends BaseObdTransport {
  @override
  TransportKind get kind => TransportKind.bluetoothLe;

  @override
  String get displayName => '未命名裝置 (68:AB:73:C3:BA:7C)';

  @override
  Future<void> connect() =>
      throw TimeoutException('Future not completed', const Duration(seconds: 10));

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> write(List<int> data) async {}
}
