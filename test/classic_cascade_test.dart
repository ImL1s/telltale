/// The Bluetooth Classic fallback cascade, and when it stops.
///
/// This file exists because of how its subject went missing. The cascade's
/// abort was written, reviewed, described in a commit message and in two code
/// comments and one user-facing hint — and then reverted by a stray
/// `git checkout` of a not-yet-committed file during an unrelated mutation
/// check. Everything downstream stayed green, because nothing anywhere pinned
/// what the cascade does next. The commit landed describing behaviour it had
/// just deleted, and a reviewer found it by reading the code against the
/// message.
///
/// So the rules that matter here are the ones about what does *not* happen:
/// a tier that must not start, a note that must not be dropped.
library;

import 'dart:async';

import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_classic_bluetooth/flutter_classic_bluetooth.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/obd/transport/classic_transport.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';

/// A cascade wired to a scripted socket opener rather than the platform.
({ClassicTransport transport, List<String> tiers}) _wire(
  Future<BtcConnection> Function(int tierIndex) open,
) {
  final tiers = <String>[];
  var index = 0;
  final transport = ClassicTransport(
    address: '00:11:22:33:44:55',
    name: 'ELM327 v2.1',
    onAttempt: tiers.add,
  );
  transport.openTierForTest = ({
    required String address,
    String uuid = BtcUuid.spp,
    bool secure = true,
    Duration? timeout,
    int? channel,
  }) =>
      open(index++);
  return (transport: transport, tiers: tiers);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every tier is tried when each one fails on its own', () async {
    // The baseline the rules below are departures from. Three tiers, in order,
    // and the third is the whole reason this app runs a forked plugin.
    final wired = _wire((_) async => throw const BtcConnectionException('refused'));
    await expectLater(
      wired.transport.connect(),
      throwsA(isA<TransportException>()),
    );
    expect(wired.tiers, hasLength(3));
    expect(wired.tiers.first, contains('加密'));
    expect(wired.tiers.last, contains('通道 1'),
        reason: 'the direct-channel tier is the one upstream does not have, '
            'and the one a clone that publishes no SDP record needs');
  });

  test('a cancelled cascade does not start its next tier', () async {
    // The rule that went missing. `BluetoothSocket.connect()` has no
    // interrupt, so the tier already running cannot be cut short — but
    // continuing past it is a choice, and it is the difference between an
    // abandoned attempt costing twelve seconds and costing thirty-six.
    //
    // Thirty-six seconds during which the correct adapter did nothing at all
    // when tapped. On the app's first screen, that reads as a broken app.
    final blocked = Completer<BtcConnection>();
    final wired = _wire((_) => blocked.future);

    final attempt = wired.transport.connect();
    await Future<void>.delayed(Duration.zero);
    expect(wired.tiers, hasLength(1), reason: 'tier 1 is in flight');

    // What 取消 does: the session disposes the client, and
    // `Elm327Client.dispose()` disconnects its transport.
    await wired.transport.disconnect();
    blocked.completeError(const BtcConnectionException('socket closed'));

    await expectLater(attempt, throwsA(isA<TransportException>()));
    expect(wired.tiers, hasLength(1),
        reason: 'tiers 2 and 3 belong to a connection the user walked away '
            'from; starting them holds the adapter for another 24 seconds');
  });

  test('an abandoned cascade says it was cancelled, not that the device failed',
      () async {
    final blocked = Completer<BtcConnection>();
    final wired = _wire((_) => blocked.future);
    final attempt = wired.transport.connect();
    await Future<void>.delayed(Duration.zero);
    await wired.transport.disconnect();
    blocked.completeError(const BtcConnectionException('socket closed'));

    await expectLater(
      attempt,
      throwsA(isA<TransportException>()
          .having((e) => e.message, 'message', contains('取消'))),
      reason: 'blaming the adapter for a cancellation sends somebody looking '
          'for a hardware fault that is not there',
    );
  });

  test('a tier that succeeds into a cancellation is closed, not installed',
      () async {
    // Codex round 30. The abort check only stopped the *next* tier from
    // starting. Cancelling during a connect that then completes — the
    // commonest way an SDP lookup ends, milliseconds after the user gave up —
    // handed back a live socket, which was installed, marked connected, and
    // handshaken against a device the user had walked away from. It also holds
    // the adapter, which is the one resource the next attempt needs.
    final blocked = Completer<BtcConnection>();
    final wired = _wire((_) => blocked.future);

    final attempt = wired.transport.connect();
    await Future<void>.delayed(Duration.zero);
    await wired.transport.disconnect();

    // The race the check above cannot win: success, arriving after the cancel.
    blocked.complete(BtcConnection(
      id: 1,
      address: '00:11:22:33:44:55',
      methodChannel: const MethodChannel('flutter_classic_bluetooth'),
    ));

    await expectLater(
      attempt,
      throwsA(isA<TransportException>()
          .having((e) => e.message, 'message', contains('取消'))),
    );
    expect(wired.transport.isConnected, isFalse,
        reason: 'a link the user cancelled must not be reported as live, or '
            'the handshake runs against a device they walked away from');
  });

  test('and the socket it hands back is actually closed', () async {
    // Codex and cursor, round 31, and the reason the test above is not enough
    // on its own: delete the `await opened.close()` and keep the throw, and
    // every assertion in it still holds. `_connection` is assigned only after
    // `_connectWithRetry()` returns, so a leaked socket is invisible through
    // `isConnected` either way.
    //
    // The close is the half that matters in the field. An RFCOMM socket left
    // open holds the adapter — most ELM327 clones accept exactly one link —
    // so the next tap fails against hardware the app itself is still holding,
    // and the user reads that as a broken adapter.
    //
    // Observed at the method channel because that is where the release
    // actually happens: `BtcConnection.close()` is
    // `invokeMethod('disconnect', {'id': id})`.
    final disconnected = <int>[];
    const channel = MethodChannel('flutter_classic_bluetooth');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'disconnect') {
        disconnected.add((call.arguments as Map)['id'] as int);
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    final blocked = Completer<BtcConnection>();
    final wired = _wire((_) => blocked.future);
    final attempt = wired.transport.connect();
    await Future<void>.delayed(Duration.zero);
    await wired.transport.disconnect();

    blocked.complete(BtcConnection(
      id: 7,
      address: '00:11:22:33:44:55',
      methodChannel: channel,
    ));

    await expectLater(attempt, throwsA(isA<TransportException>()));
    expect(disconnected, contains(7),
        reason: 'the adapter is the one resource the next attempt needs, and '
            'nothing else in this file would notice it being kept');
  });

  test('a tier that timed out still describes itself', () async {
    // The appendix was written for the case where the adapter never answers,
    // and was empty in exactly that case: only the plain-exception branch
    // recorded a note, so a stack where all three tiers hang to their deadline
    // produced "timed out" with no sign that three different things had been
    // tried.
    final wired = _wire((_) async => throw const BtcTimeoutException(message: 'no answer'));
    await expectLater(
      wired.transport.connect(),
      throwsA(isA<TransportException>()
          .having((e) => e.message, 'message', contains('其他嘗試'))
          .having((e) => e.message, 'message', contains('加密 SPP'))
          .having((e) => e.message, 'message', contains('未加密 SPP'))
          .having((e) => e.message, 'message', contains('直接連通道 1'))),
    );
  });

  test('a mixed cascade names every tier it tried', () async {
    // Timeout and refusal in one cascade — the precedence stays "never
    // answered", because that is the case where waiting helps, and the other
    // tiers' diagnoses are still worth carrying.
    final wired = _wire((i) async => i == 0
        ? throw const BtcTimeoutException(message: 'no answer')
        : throw const BtcConnectionException('createRfcommSocket unavailable'));
    await expectLater(
      wired.transport.connect(),
      throwsA(isA<TransportException>()
          .having((e) => e.message, 'message', contains('逾時'))
          .having((e) => e.message, 'message', contains('加密 SPP'))
          .having((e) => e.message, 'message',
              contains('createRfcommSocket unavailable'))),
    );
  });
}
