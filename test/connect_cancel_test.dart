/// Cancelling a connection attempt, and connecting again straight afterwards.
///
/// The wizard is the app's first screen and the bonded-device list it reads is
/// the phone's, so it lists headphones, a car stereo and a laptop beside the
/// adapter. Tapping the wrong row is the ordinary mistake, not the unusual
/// one — and until this round the app's answer to it was to look broken:
/// 取消 invalidated the attempt but could not stop it, so for up to three
/// twelve-second tiers afterwards the *correct* adapter did nothing when
/// tapped. Silently. No banner, no message, nothing on screen changing at all.
///
/// Somebody standing next to a car with a phone that ignores them force-quits
/// the app. These tests are the ones that say they should not have to.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_registry.dart';

import 'package:torque_obd/obd/transport/demo_transport.dart';

Future<ProviderContainer> _container() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
}

/// A transport whose `connect()` never finishes on its own.
///
/// Models the case the fix is about rather than any one link: a Bluetooth
/// Classic tier blocked inside `BluetoothSocket.connect()`, a Wi-Fi socket
/// waiting on a host that will not answer. What matters is that it ends only
/// when somebody outside it says so, and that it then reports a failure —
/// late, after the user has moved on.
class _HangingTransport extends BaseObdTransport {
  _HangingTransport({this.unwind = Duration.zero, this.teardown = Duration.zero});

  /// How long `disconnect()` takes, which is what a teardown awaits.
  final Duration teardown;

  /// How long the transport takes to notice it was abandoned.
  ///
  /// Zero models an abort that lands immediately; a long one models a native
  /// call with no interrupt, which is what Bluetooth Classic actually is.
  final Duration unwind;

  final _abandoned = Completer<void>();

  /// Whether anything ever asked this transport to stop.
  bool aborted = false;

  @override
  TransportKind get kind => TransportKind.wifi;

  @override
  String get displayName => '掛住的轉接器';

  @override
  Future<void> connect() async {
    await _abandoned.future;
    if (unwind > Duration.zero) await Future<void>.delayed(unwind);
    // The late failure. Before this round it repainted a screen the user had
    // already left.
    throw const TransportException('連線到 掛住的轉接器 逾時。');
  }

  @override
  Future<void> disconnect() async {
    aborted = true;
    // Slow once. The abandoned attempt disposes its own client on the way
    // out, so a delay on every call adds a second teardown to the very wait
    // being measured and makes both budget placements look identical — which
    // is how the first version of the budget test passed under its own
    // mutation.
    if (teardown > Duration.zero && !_toreDown) {
      _toreDown = true;
      await Future<void>.delayed(teardown);
    }
    if (!_abandoned.isCompleted) _abandoned.complete();
  }

  bool _toreDown = false;

  @override
  Future<void> write(List<int> data) async {}
}

/// Lets microtasks and zero-duration timers run.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('cancelling leaves the screen disconnected, not showing a stale failure',
      () async {
    final container = await _container();
    final session = container.read(obdSessionProvider.notifier);
    // Deliberately slow to give up. The failure has to arrive *after* the
    // cancel has already repainted the screen — with a transport that fails
    // the instant it is aborted, the two land in an order that happens to be
    // harmless, and the test would pass without the guard that makes it so.
    final transport =
        _HangingTransport(unwind: const Duration(milliseconds: 120));

    final attempt = session.connectForTest(transport, TransportKind.wifi);
    await _settle();
    expect(container.read(obdSessionProvider).isBusy, isTrue,
        reason: 'the fixture must actually be mid-connect');

    await session.disconnect();
    expect(container.read(obdSessionProvider).phase,
        ConnectionPhase.disconnected,
        reason: 'cancel returns the screen to idle immediately');

    // Only now does the abandoned attempt notice and report its own failure.
    expect(await attempt, isFalse);
    await _settle();

    final state = container.read(obdSessionProvider);
    expect(state.phase, ConnectionPhase.disconnected,
        reason: 'the user cancelled; an error about the connection they '
            'walked away from is indistinguishable from a failure of '
            'whatever they did next');
    expect(state.error, anyOf(isNull, isEmpty));
    expect(transport.aborted, isTrue,
        reason: 'cancel has to reach the transport, or the adapter stays held');
    container.dispose();
  });

  test('connecting again right after cancel works, and is never silent',
      () async {
    // The whole point. Tap headphones, cancel, tap the adapter.
    final container = await _container();
    final session = container.read(obdSessionProvider.notifier);
    final wrongDevice = _HangingTransport();

    final abandoned = session.connectForTest(wrongDevice, TransportKind.wifi);
    await _settle();
    await session.disconnect();
    expect(await abandoned, isFalse);

    final adapter = DemoTransport();
    expect(await session.connectForTest(adapter, TransportKind.demo), isTrue,
        reason: 'the second tap is the whole reason the first was cancelled');
    expect(container.read(obdSessionProvider).phase, ConnectionPhase.connected);
    await session.disconnect();
    container.dispose();
  });

  test('a second tap during an attempt cancels it and connects, not returns '
      'false', () async {
    // Without cancelling first — the user simply taps the right row while the
    // wrong one is still spinning. This used to `return false` with nothing on
    // screen changing, which is the version of the bug that looks most like a
    // dead app.
    final container = await _container();
    final session = container.read(obdSessionProvider.notifier);
    final wrongDevice = _HangingTransport();

    final abandoned = session.connectForTest(wrongDevice, TransportKind.wifi);
    await _settle();

    final adapter = DemoTransport();
    final second = session.connectForTest(adapter, TransportKind.demo);

    expect(await second, isTrue,
        reason: 'the tap that supersedes an attempt has to be able to connect');
    expect(await abandoned, isFalse);
    expect(wrongDevice.aborted, isTrue);
    expect(container.read(obdSessionProvider).phase, ConnectionPhase.connected);
    await session.disconnect();
    container.dispose();
  });

  test('R29-kimi: the handover wait is visible, and names the device', () async {
    // kimi, round 29. 取消 returns the screen to idle, so a tap during the
    // abandoned tier's remaining seconds produced nothing on screen at all
    // until it ended — the same silence the cancel was meant to end, moved a
    // few seconds later. Somebody standing at a car reads a second dead tap as
    // confirmation the app is broken.
    final container = await _container();
    final session = container.read(obdSessionProvider.notifier);

    // Slow to give up, so the second tap genuinely lands during the handover
    // rather than after it.
    final wrongDevice =
        _HangingTransport(unwind: const Duration(milliseconds: 200));
    final abandoned = session.connectForTest(wrongDevice, TransportKind.wifi);
    await _settle();
    await session.disconnect();
    expect(container.read(obdSessionProvider).phase,
        ConnectionPhase.disconnected);

    // The second tap, while the first is still unwinding.
    final adapter = DemoTransport();
    final second = session.connectForTest(adapter, TransportKind.demo);
    await _settle();

    final waiting = container.read(obdSessionProvider);
    expect(waiting.isBusy, isTrue, reason: 'the tap registered');
    expect(waiting.deviceName, adapter.displayName,
        reason: 'and it registered for the device they actually chose');
    expect(waiting.detail, contains('中止'),
        reason: 'and it says what it is waiting on, rather than nothing');

    expect(await second, isTrue);
    expect(await abandoned, isFalse);
    await session.disconnect();
    container.dispose();
  });

  test('R30-codex 07B: a slow teardown is spent from the handover budget',
      () async {
    // Codex round 30, an unpinned rule. `f228a67` says one budget covers the
    // whole handover — the teardown *and* the wait — because a teardown has no
    // deadline of its own: stream cancellations, `engine.dispose`, and a
    // transport disconnect that on Bluetooth Classic reaches the platform. The
    // cancellation tests all unwind in milliseconds, so moving the stopwatch
    // back below the teardown left every one of them green.
    //
    // The timings are chosen so the two placements disagree, which is the
    // whole difficulty: the teardown alone outlasts the budget, and the
    // attempt then unwinds quickly. Start the clock *after* the teardown and
    // the successor has budget left, waits out the short unwind, and connects.
    // Start it before, and the budget is already gone when the wait begins, so
    // it refuses. A first version of this test used a slow unwind, where both
    // placements refuse and the mutation survived.
    final container = await _container();
    final session = container.read(obdSessionProvider.notifier);
    final previous = ObdSession.abandonTimeout;
    ObdSession.abandonTimeout = const Duration(milliseconds: 150);
    addTearDown(() => ObdSession.abandonTimeout = previous);

    final wrongDevice = _HangingTransport(
      unwind: const Duration(milliseconds: 50),
      teardown: const Duration(milliseconds: 400),
    );
    final abandoned = session.connectForTest(wrongDevice, TransportKind.wifi);
    await _settle();

    expect(await session.connectForTest(DemoTransport(), TransportKind.demo),
        isFalse,
        reason: 'the teardown alone spent the whole budget; the refusal is '
            'the honest answer and it is what the user is told');
    expect(container.read(obdSessionProvider).error, contains('中止中'),
        reason: 'and never silently');

    await abandoned;
    await session.disconnect();
    container.dispose();
  });

  test('R29-agy 02: three quick taps connect the last one, not the middle one',
      () async {
    // agy, round 29. The wizard's cards are disabled while an attempt runs, so
    // this is not reachable by tapping today — but the rule it breaks is the
    // one the whole cancel-and-wait design rests on, and a device list that
    // stays live during an attempt is an obvious next step.
    //
    // A wrong, B wrong, C the adapter. B and C both queued behind A; A
    // finished, B woke first and took the link, and C woke to find somebody
    // connecting and was refused. The app connected to a device the user had
    // already changed their mind about, and told them their actual choice had
    // failed.
    final container = await _container();
    final session = container.read(obdSessionProvider.notifier);

    final wrongFirst = _HangingTransport();
    final wrongSecond = DemoTransport();
    final adapter = DemoTransport();

    final a = session.connectForTest(wrongFirst, TransportKind.wifi);
    final b = session.connectForTest(wrongSecond, TransportKind.demo);
    final c = session.connectForTest(adapter, TransportKind.demo);

    expect(await a, isFalse);
    expect(await b, isFalse,
        reason: 'the user changed their mind about this one before it started');
    expect(await c, isTrue, reason: 'the last tap is the one they meant');

    expect(session.client?.transport, same(adapter),
        reason: 'and it is the last-tapped device that is actually connected — '
            'connecting to a rejected one is worse than connecting to none');
    await session.disconnect();
    container.dispose();
  });

  test('a superseded attempt cannot repaint the connection that replaced it',
      () async {
    // The ordering that makes the guard necessary: the abandoned transport
    // takes a moment to fail, so its `TransportException` arrives *after* the
    // new session is live. Publishing it would turn a working connection into
    // 連線失敗 on screen while the engine underneath keeps polling.
    final container = await _container();
    final session = container.read(obdSessionProvider.notifier);
    final wrongDevice =
        _HangingTransport(unwind: const Duration(milliseconds: 120));

    final abandoned = session.connectForTest(wrongDevice, TransportKind.wifi);
    await _settle();
    await session.disconnect();

    final adapter = DemoTransport();
    expect(await session.connectForTest(adapter, TransportKind.demo), isTrue);
    expect(container.read(obdSessionProvider).phase, ConnectionPhase.connected);

    // Now let the abandoned attempt finish failing.
    expect(await abandoned, isFalse);
    await _settle();

    expect(container.read(obdSessionProvider).phase, ConnectionPhase.connected,
        reason: 'the live session belongs to the adapter the user chose; the '
            'other attempt lost the right to speak when it was superseded');
    await session.disconnect();
    container.dispose();
  });
}
