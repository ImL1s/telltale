/// The clear's safety state belongs to the vehicle, not to the screen.
///
/// `state/dtc_scan.dart` opens by recording this lesson being learned once:
/// the shell is an ordinary `ShellRoute` driven by `context.go`, so switching
/// tabs disposes the screen, and a scan that takes ten seconds on a real car
/// did not survive a glance at the dashboard. The results were moved into a
/// notifier for exactly that reason.
///
/// The clear's two safety flags were left behind. So — codex, round 30 — tap
/// 清除, switch to the dashboard, come back, and a fresh widget state arrived
/// with the repeat-lock cleared and the warning gone, over codes that were
/// still on screen. The next tap sent a second global `04`, which reaches the
/// controller the first one just finished and resets its readiness monitors
/// again: another full drive cycle before the vehicle can pass an emissions
/// test.
///
/// These tests do not build a widget. They exercise the state a widget would
/// have destroyed, which is the point.
library;

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/obd/dtc/dtc.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/dtc_scan.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_registry.dart';

import 'support/fake_elm327.dart';

Future<ProviderContainer> _container() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
}

/// A vehicle whose clear half-works: the engine finishes, the transmission
/// refuses because it is running.
FakeElm327 _mixedClear() => FakeElm327(
      protocol: BusProtocol.can11,
      ecus: [
        FakeEcu(
          name: 'ECM',
          requestId: '7E0',
          responseId: '7E8',
          responses: {
            '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
            '03': [0x43, 0x01, 0x03, 0x01],
            '07': [0x47, 0x00],
            '0A': [0x4A, 0x00],
            '04': [0x44],
          },
        ),
        FakeEcu(
          name: 'TCM',
          requestId: '7E1',
          responseId: '7E9',
          responses: {
            '0100': [0x41, 0x00, 0x80, 0x00, 0x00, 0x00],
            '03': [0x43, 0x00],
            '07': [0x47, 0x00],
            '0A': [0x4A, 0x00],
            '04': [0x7F, 0x04, 0x22],
          },
        ),
      ],
    );

/// The same half-clear, but the controller that refused still has its code —
/// so after the rescan there is something to clear and the button is drawn.
///
/// `_mixedClear`'s TCM answers Mode 03 empty, which makes `totalCodes` fall to
/// zero after the rescan and the clear button disappear. That is why the
/// contradiction below survived every test in this file.
FakeElm327 _mixedClearWithCodesLeft() => FakeElm327(
      protocol: BusProtocol.can11,
      ecus: [
        FakeEcu(
          name: 'ECM',
          requestId: '7E0',
          responseId: '7E8',
          responses: {
            '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
            '03': [0x43, 0x01, 0x03, 0x01],
            '07': [0x47, 0x00],
            '0A': [0x4A, 0x00],
            '04': [0x44],
          },
        ),
        FakeEcu(
          name: 'TCM',
          requestId: '7E1',
          responseId: '7E9',
          responses: {
            '0100': [0x41, 0x00, 0x80, 0x00, 0x00, 0x00],
            // Still there, because this is the controller that refused.
            '03': [0x43, 0x01, 0x07, 0x00],
            '07': [0x47, 0x00],
            '0A': [0x4A, 0x00],
            '04': [0x7F, 0x04, 0x22],
          },
        ),
      ],
    );

/// What pressing Home actually delivers, in order.
void _background(TestWidgetsFlutterBinding binding) {
  binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
}

void _foreground(TestWidgetsFlutterBinding binding) {
  binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  test('a rescan interrupted by backgrounding settles nothing either',
      () async {
    // Cursor round 32, F3, and the third face of one rule: a rescan settles
    // the clear when it *produces results*.
    //
    // The loading snapshot keeps the lock and the fatal-disconnect branch keeps
    // it, and both are pinned. `_interrupted()` — the branch a pause takes,
    // which is simply what phones do — replaced the whole state with an error
    // string. So: tap 清除, get 不要再送一次全車清除…請重新掃描, tap 掃描 as the
    // panel asks, press Home during the census. Come back, scan again, and 清除
    // is live with no warning over a controller that already erased its memory.
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);
    await session.connectForTest(
        _mixedClearWithCodesLeft(), TransportKind.wifi);
    final scan = container.read(dtcScanProvider.notifier);
    await scan.scan();
    await scan.clear();
    expect(container.read(dtcScanProvider).clearRepeatWouldHarm, isTrue);
    final warning = container.read(dtcScanProvider).clearMessage;

    final rescan = scan.scan();
    _background(binding);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    _foreground(binding);
    await rescan;

    final after = container.read(dtcScanProvider);
    expect(after.hasScanned, isFalse,
        reason: 'the scan really was interrupted; this is the branch under '
            'test');
    expect(after.clearRepeatWouldHarm, isTrue,
        reason: 'nothing came back from the car, so nothing was settled and '
            'the lock has not earned its release');
    expect(after.clearMessage, warning,
        reason: 'and the sentence is still the accurate one');
    await session.disconnect();
  });

  test('the rescan that unlocks the button also settles what the panel says',
      () async {
    // Cursor round 31. The clear's sentence was carried through the rescan
    // unchanged so that 已送出清除指令 would survive the rescan a *successful*
    // clear triggers. But every harmful outcome's sentence is written for the
    // moment before the rescan — it warns against a second global `04` and
    // ends by asking for exactly this rescan — and the rescan releases the
    // lock.
    //
    // So: tap 清除, read 不要再送一次全車清除…請重新掃描, tap 掃描 as both the
    // panel and the field guide instruct, and the button comes back live
    // underneath a sentence telling you not to press it. `FIELD_GUIDE.md` said
    // to trust the button.
    //
    // Deleting the sentence would be worse — a partial clear is a fact about
    // the car that the rescan does not undo — so it is replaced by the part
    // that is still true.
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);
    expect(
        await session.connectForTest(
            _mixedClearWithCodesLeft(), TransportKind.wifi),
        isTrue);

    final scan = container.read(dtcScanProvider.notifier);
    await scan.scan();
    await scan.clear();
    final afterClear = container.read(dtcScanProvider);
    expect(afterClear.clearRepeatWouldHarm, isTrue);
    expect(afterClear.clearMessage, contains('不要'));

    await scan.scan();
    final afterRescan = container.read(dtcScanProvider);
    expect(afterRescan.totalCodes, greaterThan(0),
        reason: 'the refusing controller kept its code, so the clear button '
            'is drawn — which is the only case where this can be tapped');
    expect(afterRescan.clearRepeatWouldHarm, isFalse,
        reason: 'the rescan is the informed-consent gate; locking forever '
            'strands a car that can still legitimately be cleared');
    expect(afterRescan.clearMessage, isNotNull,
        reason: 'a partial clear happened and the panel is where that is '
            'recorded');
    expect(afterRescan.clearMessage, isNot(contains('不要')),
        reason: 'the button is live now, so a sentence telling somebody not '
            'to press it is the app contradicting itself on the one screen '
            'where that guess costs a drive cycle');
    await session.disconnect();
  });

  test('a second clear does not run under the first one\'s verdict', () async {
    // Cursor round 32, F4.C. `copyWith(clearMessage: null)` cannot clear a
    // message — its `??` reads null as "leave it alone" — so a second attempt
    // began under the previous attempt's panel. Fixed by going through
    // `withoutClearMessage()`, which nothing observed.
    //
    // First clear: the adapter denies transmitting, so the panel says so and
    // the button stays live. Second: slow, so the state can be read while it
    // is on the wire.
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);
    final adapter = FakeElm327(
      protocol: BusProtocol.can11,
      faults: const AdapterFaults(forcedReplies: {'04': '?'}),
      ecus: [
        FakeEcu(
          name: 'ECM',
          requestId: '7E0',
          responseId: '7E8',
          responses: {
            '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
            '03': [0x43, 0x01, 0x03, 0x01],
            '07': [0x47, 0x00],
            '0A': [0x4A, 0x00],
          },
        ),
      ],
    );
    await session.connectForTest(adapter, TransportKind.wifi);
    final scan = container.read(dtcScanProvider.notifier);
    await scan.scan();

    await scan.clear();
    expect(container.read(dtcScanProvider).clearMessage,
        contains('沒有控制器接受指令'));
    expect(container.read(dtcScanProvider).clearRepeatWouldHarm, isFalse,
        reason: 'the adapter denied transmitting, so the retry is free — this '
            'is the one outcome from which a second clear can be tapped');

    adapter.slowCommands['04'] = const Duration(seconds: 2);
    final second = scan.clear();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final during = container.read(dtcScanProvider);
    expect(during.clearing, isTrue);
    expect(during.clearMessage, isNull,
        reason: "the panel describes an attempt that is over; leaving it up "
            'under 清除中… reads as this attempt having already failed');
    await second;
    await session.disconnect();
  });

  test('a clear retired before its first write says nothing was sent',
      () async {
    // agy round 32: the typed catch for `OperationRetiredException` in
    // `clear()` had no fixture, so deleting it was silent — and deleting it
    // does two wrong things at once. The sentence becomes the generic one with
    // a Dart class name in it, and the generic branch is conservative, so the
    // button locks over a clear that provably never left the app.
    //
    // The lease is retired by backgrounding. `ATH1` is slowed so the app can
    // go away before the exchange reaches its first write.
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);
    final adapter = _mixedClearWithCodesLeft();
    await session.connectForTest(adapter, TransportKind.wifi);
    final scan = container.read(dtcScanProvider.notifier);
    await scan.scan();

    adapter.slowCommands['ATH1'] = const Duration(seconds: 2);
    final pending = scan.clear();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _background(binding);
    await pending;
    _foreground(binding);

    final after = container.read(dtcScanProvider);
    expect(after.clearRepeatWouldHarm, isFalse,
        reason: 'nothing was transmitted, so there is nothing a repeat could '
            'reach — locking the button here strands a car that can still be '
            'cleared');
    expect(after.clearMessage, isNotNull);
    expect(after.clearMessage, isNot(contains('Exception')),
        reason: 'this sentence is read at a car, not in a stack trace');
    await session.disconnect();
  });

  test('an interrupted rescan keeps a *successful* clear looking successful',
      () async {
    // Codex round 32. `_interrupted()` retaining all three clear fields was
    // claimed to be pinned, and the test that pinned it used a mixed clear —
    // for which `clearWorked` is already false. Removing its preservation
    // therefore exercised the same default and stayed green.
    //
    // An exact `44` is the case that tells them apart: 已送出清除指令 is
    // rendered as success, and without the retained flag the same sentence
    // comes back styled as a warning.
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);
    final adapter = FakeElm327(
      protocol: BusProtocol.can11,
      ecus: [
        FakeEcu(
          name: 'ECM',
          requestId: '7E0',
          responseId: '7E8',
          responses: {
            '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
            '03': [0x43, 0x01, 0x03, 0x01],
            '07': [0x47, 0x00],
            '0A': [0x4A, 0x00],
            '04': [0x44],
          },
        ),
      ],
    );
    await session.connectForTest(adapter, TransportKind.wifi);
    final scan = container.read(dtcScanProvider.notifier);
    await scan.scan();
    await scan.clear();
    expect(container.read(dtcScanProvider).clearWorked, isTrue);

    final rescan = scan.scan();
    _background(binding);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    _foreground(binding);
    await rescan;

    final after = container.read(dtcScanProvider);
    expect(after.hasScanned, isFalse, reason: 'the scan was interrupted');
    expect(after.clearWorked, isTrue,
        reason: 'the clear succeeded; an interruption to the rescan does not '
            'turn 已送出清除指令 into a warning');
    await session.disconnect();
  });

  test('a clear whose link died still says so', () async {
    // Cursor round 32, and a regression the round-31 repair introduced.
    //
    // The guard added there refused to publish a clear outcome once the
    // session generation had moved, so an outcome could not land on the next
    // car. But `generation` is bumped by *anything* that invalidates in-flight
    // work, and `_handleConnectionLost` is the loudest of those — so the one
    // case the message exists for suppressed it.
    //
    // Yank the adapter between `04` going out and its reply coming back. The
    // engine classifies it correctly (`wroteSinceAudit('04')` is true, so:
    // 清除指令送出後連線中斷…不要直接再清除一次, `repeatWouldHarm`). The guard
    // then threw the sentence away, and the screen went to 尚未掃描 with
    // nothing said. Reconnect, scan, and 清除 is live over a controller that
    // may have erased its memory a minute ago — the exact drive cycle the
    // whole lock exists to protect.
    //
    // The guard now keys on `connectEpoch`, which moves only when somebody
    // starts connecting to something.
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);
    final adapter = _mixedClearWithCodesLeft()
      ..dropLinkAfterWritingFor = const {'04'};
    await session.connectForTest(adapter, TransportKind.wifi);

    final scan = container.read(dtcScanProvider.notifier);
    await scan.scan();
    expect(container.read(dtcScanProvider).totalCodes, greaterThan(0));

    await scan.clear();
    final after = container.read(dtcScanProvider);
    expect(after.clearMessage, isNotNull,
        reason: 'the bytes went out; a blank panel says nothing happened');
    expect(after.clearMessage, contains('不要'),
        reason: 'this is the sentence FIELD_GUIDE.md promises for this row');
    expect(after.clearRepeatWouldHarm, isTrue,
        reason: 'and the button has to enforce it after the reconnect');
    expect(after.clearing, isFalse);
  });

  test('an unsettled clear survives a reconnection, because a drop is not a '
      'different car', () async {
    // Codex round 32, BLOCK, quoting the previous commit against itself: it
    // said "a dropped link is not a different car" while the code wiped the
    // whole state on every reconnect.
    //
    // The sequence is the ordinary one. `04` goes out, the link drops, the
    // warning and the lock are preserved — and then the user does the obvious
    // thing and reconnects the same adapter to the same car. Everything was
    // wiped, the scan found the remaining fault, and 清除 was live over a
    // controller that had already erased its memory.
    //
    // The two directions are not symmetric. Carrying a warning onto a car that
    // was never cleared costs one rescan, which the sentence asks for anyway.
    // Dropping it on the car that was cleared costs a drive cycle and nothing
    // gets it back. So the tie goes to the lock, and the sentence says where
    // it came from instead of pretending to describe this connection.
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);
    final scan = container.read(dtcScanProvider.notifier);

    await session.connectForTest(
        _mixedClearWithCodesLeft(), TransportKind.wifi);
    await scan.scan();
    await scan.clear();
    expect(container.read(dtcScanProvider).clearRepeatWouldHarm, isTrue);

    await session.disconnect();
    final offline = container.read(dtcScanProvider);
    expect(offline.hasScanned, isFalse,
        reason: 'the codes belonged to that connection');
    expect(offline.clearMessage, isNotNull,
        reason: 'the clear happened, and losing the link is not a reason to '
            'stop saying so');

    // Back to the same car, which is what anybody would do next.
    await session.connectForTest(
        _mixedClearWithCodesLeft(), TransportKind.wifi);
    final reconnected = container.read(dtcScanProvider);
    expect(reconnected.clearRepeatWouldHarm, isTrue,
        reason: 'this is the tap that costs a drive cycle, and nothing has '
            'happened since the clear to make it safe');
    expect(reconnected.clearMessage, contains('上一次連線'),
        reason: 'and it says where it came from, rather than claiming to '
            'describe this connection');
    expect(reconnected.hasScanned, isFalse,
        reason: 'the results are about a connection that ended');

    // The rescan the sentence asks for is what settles it.
    await scan.scan();
    final settled = container.read(dtcScanProvider);
    expect(settled.totalCodes, greaterThan(0));
    expect(settled.clearRepeatWouldHarm, isFalse,
        reason: 'the user can now see what is actually still set, so a second '
            'clear is an informed decision rather than a blind repeat');
    await session.disconnect();
  });

  test('a settled clear does not follow the adapter to the next car', () async {
    // The other direction, and the reason the reconnect branch is conditional
    // rather than simply gone. Codex round 31: a clear that needs no warning
    // must not appear over the next vehicle at all.
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);
    final scan = container.read(dtcScanProvider.notifier);

    // A clean, fully confirmed clear: nothing to warn about.
    await session.connectForTest(
      FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
              '03': [0x43, 0x01, 0x03, 0x01],
              '07': [0x47, 0x00],
              '0A': [0x4A, 0x00],
              '04': [0x44],
            },
          ),
        ],
      ),
      TransportKind.wifi,
    );
    await scan.scan();
    await scan.clear();
    expect(container.read(dtcScanProvider).clearWorked, isTrue);
    expect(container.read(dtcScanProvider).clearRepeatWouldHarm, isFalse);

    await session.disconnect();
    await session.connectForTest(
      FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
              '03': [0x43, 0x01, 0x01, 0x71],
              '07': [0x47, 0x00],
              '0A': [0x4A, 0x00],
              '04': [0x44],
            },
          ),
        ],
      ),
      TransportKind.wifi,
    );
    expect(container.read(dtcScanProvider).clearMessage, isNull,
        reason: '已送出清除指令 over the next car\'s codes reads as a statement '
            'about this car');
    expect(container.read(dtcScanProvider).clearWorked, isFalse);

    await scan.scan();
    final vehicleB = container.read(dtcScanProvider);
    expect(vehicleB.totalCodes, greaterThan(0));
    expect(vehicleB.clearMessage, isNull);
    expect(vehicleB.clearRepeatWouldHarm, isFalse,
        reason: "B has never been cleared, so its button must work");
    await session.disconnect();
  });

  test('and not even one that was on the wire when the next car arrived',
      () async {
    // Tapping 清除 and then walking to another car without waiting: `clearDtcs`
    // is still out when the next connection begins.
    //
    // What this pins is the combination that actually does the work —
    // connecting tears down the in-flight client, so the clear resolves
    // against the car it was sent to, and the listener's wipe-on-connect
    // removes it before the new one is scanned.
    //
    // It does **not** pin the `connectEpoch` guard in `clear()`. Cursor round
    // 32 (F4.A) showed that deleting that guard leaves every case here green,
    // and this test was written to reach the window and lands on the same
    // teardown path. The guard's own comment now says so rather than claiming
    // a pin it does not have.
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);
    final slowCar = _mixedClearWithCodesLeft();
    slowCar.slowCommands['04'] = const Duration(seconds: 2);
    await session.connectForTest(slowCar, TransportKind.wifi);

    final scan = container.read(dtcScanProvider.notifier);
    await scan.scan();

    // Started, not awaited: the tap, with the reply still to come.
    final inFlight = scan.clear();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(container.read(dtcScanProvider).clearing, isTrue);

    // The user gives up and connects to something else.
    await session.connectForTest(
      FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
              '03': [0x43, 0x01, 0x01, 0x71],
              '07': [0x47, 0x00],
              '0A': [0x4A, 0x00],
              '04': [0x44],
            },
          ),
        ],
      ),
      TransportKind.wifi,
    );
    await inFlight;

    final now = container.read(dtcScanProvider);
    expect(now.clearMessage, isNull,
        reason: "the outcome describes the car that is no longer there");
    expect(now.clearRepeatWouldHarm, isFalse,
        reason: "and B's button must not be locked by A's clear");
    expect(now.clearing, isFalse,
        reason: 'the in-flight flag belongs to the notifier, not the outcome; '
            'leaving it set hands the next car a clear that is not running');
    await session.disconnect();
  });

  test('a rescan that has not finished has not settled anything', () async {
    // The half of the same rule that was being enforced by accident.
    //
    // The lock and the sentence were both released at the *start* of the
    // rescan, so a rescan that died released a lock nothing had settled. That
    // was invisible because a dead scan leaves `scannedAt` null and the screen
    // only draws the clear button when `hasScanned && totalCodes > 0` — the
    // lock was being held by the absence of a button rather than by itself. It
    // also left the reword at the end with no flag to key on, which is how the
    // test above failed on its first run.
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);
    await session.connectForTest(
        _mixedClearWithCodesLeft(), TransportKind.wifi);
    final scan = container.read(dtcScanProvider.notifier);
    await scan.scan();
    await scan.clear();
    expect(container.read(dtcScanProvider).clearRepeatWouldHarm, isTrue);
    final warning = container.read(dtcScanProvider).clearMessage;

    // Started, not awaited: this is the state the screen renders under the
    // spinner, and the tap that would go out if the lock had been dropped.
    final running = scan.scan();
    final midScan = container.read(dtcScanProvider);
    expect(midScan.loading, isTrue);
    expect(midScan.clearRepeatWouldHarm, isTrue,
        reason: 'nothing has come back from the car yet; a rescan settles the '
            'clear when it produces results, not when it begins');
    expect(midScan.clearMessage, warning,
        reason: 'and the sentence is still the accurate one until then');

    await running;
    await session.disconnect();
  });

  test('the repeat-lock outlives the screen that showed it', () async {
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);
    expect(await session.connectForTest(_mixedClear(), TransportKind.wifi),
        isTrue);

    final scan = container.read(dtcScanProvider.notifier);
    await scan.scan();
    expect(container.read(dtcScanProvider).totalCodes, greaterThan(0),
        reason: 'the clear button only exists when there is something to clear');

    await scan.clear();
    final after = container.read(dtcScanProvider);
    expect(after.clearRepeatWouldHarm, isTrue,
        reason: '7E8 finished; a second global 04 reaches it again');
    expect(after.clearMessage, contains('不要'),
        reason: 'and the message says so');

    // What tapping the tab bar does: the widget goes, the notifier stays.
    // Reading the provider again is the same state a rebuilt screen sees.
    expect(container.read(dtcScanProvider).clearRepeatWouldHarm, isTrue,
        reason: 'a glance at the dashboard is not a rescan, and this is the '
            'state the rebuilt screen renders its button from');

    await session.disconnect();
  });

  test('dismissing the message does not unlock the button', () async {
    // Closing a panel is not the same as learning what happened. The close
    // button exists because these messages name controllers that appear
    // nowhere else in the app, not because dismissing one settles anything.
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);
    await session.connectForTest(_mixedClear(), TransportKind.wifi);
    final scan = container.read(dtcScanProvider.notifier);
    await scan.scan();
    await scan.clear();
    expect(container.read(dtcScanProvider).clearRepeatWouldHarm, isTrue);

    scan.dismissClearMessage();
    final after = container.read(dtcScanProvider);
    expect(after.clearMessage, isNull);
    expect(after.clearRepeatWouldHarm, isTrue);
    await session.disconnect();
  });

  test('a rescan is what brings the button back', () async {
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);
    await session.connectForTest(_mixedClear(), TransportKind.wifi);
    final scan = container.read(dtcScanProvider.notifier);
    await scan.scan();
    await scan.clear();
    expect(container.read(dtcScanProvider).clearRepeatWouldHarm, isTrue);

    await scan.scan();
    final after = container.read(dtcScanProvider);
    expect(after.clearRepeatWouldHarm, isFalse,
        reason: 'a rescan turns "part of it, the rest unknown" back into a '
            'state somebody can act on — it is what every one of these '
            'messages asks for');
    // But the sentence stays. A successful clear rescans itself, so wiping it
    // here would erase 已送出清除指令 before anybody read it — which is what
    // moving this state out of the widget briefly did.
    expect(after.clearMessage, isNotNull,
        reason: 'the rescan settles the clear; it does not un-happen it');
    await session.disconnect();
  });

  test('each outcome gets its own copy, and the button follows the copy',
      () async {
    // Codex round 30, 7D: the screen's rendering of the three returned
    // outcomes had no contract at all. Removing their distinction — or their
    // persistence — would have stayed green, and findings 2 and 3 of that same
    // report are defects this gap let through.
    //
    // Asserted on the notifier rather than through a widget because a
    // connected session cannot be driven from `testWidgets`: its fake-async
    // clock never advances for the poller's real delays, so the test
    // deadlocks instead of failing. The screen is a direct render of these
    // three fields.
    Future<DtcScanState> outcomeOf(Map<String, List<int>> ecmResponses,
        {AdapterFaults faults = const AdapterFaults()}) async {
      final container = await _container();
      addTearDown(container.dispose);
      final session = container.read(obdSessionProvider.notifier);
      await session.connectForTest(
        FakeElm327(
          protocol: BusProtocol.can11,
          faults: faults,
          ecus: [
            FakeEcu(
              name: 'ECM',
              requestId: '7E0',
              responseId: '7E8',
              responses: {
                '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
                '03': [0x43, 0x01, 0x03, 0x01],
                '07': [0x47, 0x00],
                '0A': [0x4A, 0x00],
                ...ecmResponses,
              },
            ),
          ],
        ),
        TransportKind.wifi,
      );
      final scan = container.read(dtcScanProvider.notifier);
      await scan.scan();
      await scan.clear();
      final result = container.read(dtcScanProvider);
      await session.disconnect();
      return result;
    }

    // Confirmed: the only outcome that may be reported as success, and the
    // only one that leaves the button alone.
    final confirmed = await outcomeOf({'04': [0x44]});
    expect(confirmed.clearWorked, isTrue);
    expect(confirmed.clearRepeatWouldHarm, isFalse);
    expect(confirmed.clearMessage, '已送出清除指令');

    // Sent, unreadable answer: not a success, not a failure, and a repeat
    // could cost a drive cycle.
    final unconfirmed = await outcomeOf(
      const {},
      faults: const AdapterFaults(forcedReplies: {'04': '<RX ERROR'}),
    );
    expect(unconfirmed.clearWorked, isFalse);
    expect(unconfirmed.clearRepeatWouldHarm, isTrue);
    expect(unconfirmed.clearMessage, contains('不要直接再清除一次'));

    // Nothing transmitted: the adapter said so in its own voice, so trying
    // again is free and the button has to allow it.
    final refused = await outcomeOf(
      const {},
      faults: const AdapterFaults(forcedReplies: {'04': '?'}),
    );
    expect(refused.clearWorked, isFalse);
    expect(refused.clearRepeatWouldHarm, isFalse);
    expect(refused.clearMessage, contains('沒有控制器接受指令'));

    // And every message is distinct, which is the property that makes the
    // screen's copy worth anything.
    expect(
      {
        confirmed.clearMessage,
        unconfirmed.clearMessage,
        refused.clearMessage,
      },
      hasLength(3),
    );
  });

  test('a second clear cannot start while one is on the wire', () async {
    // The guard that has to live below the UI, because it is the one the UI
    // cannot be trusted with: the button is greyed while `clearing` is set,
    // and a disposed screen has no such flag.
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);
    await session.connectForTest(_mixedClear(), TransportKind.wifi);

    final first = session.clearDtcs();
    await expectLater(
      session.clearDtcs(),
      throwsA(isA<DtcReadException>()
          .having((e) => e.message, 'message', contains('正在執行'))),
      reason: 'a second functional 04 queued behind the first reaches the '
          'controller the first just finished',
    );
    await first.then<void>((_) {}).catchError((Object _) {});
    await session.disconnect();
  });

  test('and the guard is released, so the next clear still works', () async {
    // The over-strict twin. A latch that never opens is a car that can never
    // be cleared.
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);
    await session.connectForTest(_mixedClear(), TransportKind.wifi);

    await session.clearDtcs().then<void>((_) {}).catchError((Object _) {});
    await expectLater(
      session.clearDtcs(),
      throwsA(isA<DtcReadException>()
          .having((e) => e.message, 'message', isNot(contains('正在執行')))),
      reason: 'the second attempt fails on the vehicle, not on the guard',
    );
    await session.disconnect();
  });
}
