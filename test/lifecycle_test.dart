/// Time passing with the app suspended is not evidence the adapter went quiet.
///
/// Dart's timers stop when the OS freezes the process. On resume the watchdog
/// wakes, compares `lastRxAt` against a wall clock that moved on by however
/// long the user spent in another app, and tears down a link that never went
/// anywhere. The existing guard for an idle link — `_pending == null` — does
/// not help, because the polling loop almost always has a command outstanding.
///
/// This could not be reproduced on the test device: Samsung's Freecess logged
/// `skipping freeze com.prowl.torque_obd` throughout both a 50-second and a
/// 200-second background window, so an adb-connected app appears to be exempt.
/// The mechanism is therefore covered here rather than on hardware.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/polling_engine.dart';

import 'support/fake_elm327.dart';

/// [wedge] makes the adapter answer a command with data but no `>` prompt, so
/// the request stays outstanding — which is the state the watchdog exists for,
/// and the one a suspended process resumes into.
FakeElm327 _adapter({Set<String> wedge = const {}}) => FakeElm327(
  faults: AdapterFaults(swallowPromptFor: wedge),
  protocol: BusProtocol.can11,
  ecus: [
    FakeEcu(
      name: 'ECM',
      requestId: '7E0',
      responseId: '7E8',
      responses: {
        '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
        '010C': [0x41, 0x0C, 0x1A, 0xF8],
      },
    ),
  ],
);

void main() {
  group('transport loss during the handshake', () {
    test('fails the pending init command immediately, not as a timeout', () async {
      final transport = _adapter()..dropLinkAfterWritingFor = const {'ATE0'};
      final client = Elm327Client(transport);
      addTearDown(client.dispose);

      final progress = <InitProgress>[];
      final subscription = client.initProgress.listen(progress.add);
      addTearDown(subscription.cancel);
      var lostAfterInit = 0;
      client.onConnectionLost = () => lostAfterInit++;

      final connected = await client.connect().timeout(
        const Duration(seconds: 1),
        onTimeout: () => throw TimeoutException(
          'a reported transport close waited for the four-second command timer',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(connected, isFalse);
      expect(client.isInitialized, isFalse);
      expect(lostAfterInit, isZero);
      final failed = progress.where(
        (event) => event.status == InitStatus.failed,
      );
      expect(failed, hasLength(1));
      expect(failed.single.step.command, 'ATE0');
      expect(failed.single.detail, contains('連線已中斷'));
      expect(failed.single.detail, isNot('逾時'));
    });

    test(
      'a close immediately after the final prompt cannot commit a session',
      () async {
        final transport = _adapter()
          ..dropLinkAfterReplyingFor = const {'ATDPN'};
        final client = Elm327Client(transport);
        addTearDown(client.dispose);

        var lostAfterInit = 0;
        client.onConnectionLost = () => lostAfterInit++;

        expect(await client.connect(), isFalse);
        expect(client.isInitialized, isFalse);
        expect(transport.isConnected, isFalse);
        expect(lostAfterInit, isZero);
      },
    );

    test(
      'a close during post-handshake probes cannot return success',
      () async {
        final transport = _adapter()
          ..dropLinkAfterReplyingFor = const {'ATPPS'};
        final client = Elm327Client(transport);
        addTearDown(client.dispose);

        var lostAfterInit = 0;
        client.onConnectionLost = () => lostAfterInit++;

        expect(await client.connect(), isFalse);
        expect(client.isInitialized, isFalse);
        expect(transport.isConnected, isFalse);
        expect(lostAfterInit, 1);
      },
    );
  });

  group('the watchdog and a suspended process', () {
    test('a link is dropped when the adapter really does go quiet', () async {
      // The control: the watchdog must still do its job.
      final client = Elm327Client(
        _adapter(wedge: {'010C'}),
        watchdogTimeout: const Duration(seconds: 2),
      );
      expect(await client.connect(), isTrue);

      var lost = false;
      client.onConnectionLost = () => lost = true;

      // Nothing has arrived for far longer than the watchdog allows, and a
      // command is outstanding.
      // The wedged command is meant to be abandoned, so its eventual failure
      // is expected rather than a test error.
      unawaited(
        client
            .send('010C', timeout: const Duration(seconds: 5))
            .then((_) {}, onError: (Object _) {}),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      client.lastRxAt = DateTime.now().subtract(const Duration(seconds: 30));
      await Future<void>.delayed(const Duration(milliseconds: 1300));

      expect(lost, isTrue);
      await client.dispose();
    });

    test('markAlive stops a resume from looking like silence', () async {
      final client = Elm327Client(
        _adapter(wedge: {'010C'}),
        watchdogTimeout: const Duration(seconds: 2),
      );
      expect(await client.connect(), isTrue);

      var lost = false;
      client.onConnectionLost = () => lost = true;

      // The wedged command is meant to be abandoned, so its eventual failure
      // is expected rather than a test error.
      unawaited(
        client
            .send('010C', timeout: const Duration(seconds: 5))
            .then((_) {}, onError: (Object _) {}),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // The app was in the background for half a minute.
      client.lastRxAt = DateTime.now().subtract(const Duration(seconds: 30));
      // …and this is what resuming must do before the watchdog next ticks.
      client.markAlive();

      await Future<void>.delayed(const Duration(milliseconds: 1300));

      // 1.3 s have passed since `markAlive`, well inside the two-second
      // window. Resetting the clock buys the adapter one more window; it does
      // not make the link immune, which is the point — a genuinely dead
      // adapter still gets dropped, just not on the strength of time that
      // passed while nothing was listening.
      expect(
        lost,
        isFalse,
        reason: 'elapsed wall-clock is not evidence of adapter silence',
      );
      await client.dispose();
    });
  });

  group('one poller at a time', () {
    test('a stop released by the loop it started, never by an older one', () async {
      // Pause and resume were independent and neither awaited the other, so
      // two loops could exist at once: `start()` set `_running = true` and
      // replaced the shared completer while the previous loop was still parked
      // on a command, and that loop's `finally` then completed the *new*
      // loop's barrier. A later `stop()` returned immediately while polling
      // carried on — two loops on one half-duplex link, doubling bus load and
      // racing their publications.
      final transport = _adapter();
      final client = Elm327Client(
        transport,
        commandTimeout: const Duration(milliseconds: 200),
      );
      expect(await client.connect(), isTrue);

      final engine = PollingEngine(client)
        ..setActivePids([PidLibrary.engineRpm]);

      for (var cycle = 0; cycle < 4; cycle++) {
        engine.start();
        expect(engine.isRunning, isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await engine.stop();
        expect(
          engine.isRunning,
          isFalse,
          reason: 'stop() must not return while a loop is still polling',
        );

        // If a departing loop had released the wrong barrier, this is where it
        // would show: the command log would keep growing after the stop.
        final settled = transport.commandLog.length;
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(
          transport.commandLog.length,
          equals(settled),
          reason:
              'nothing may reach the adapter after stop() returns '
              '(cycle $cycle)',
        );
      }

      await engine.dispose();
    });

    test('a command that resolves after stop() cannot repopulate the gauges', () async {
      // `stop()`'s barrier is bounded at two seconds so a disconnect never
      // looks frozen, but a command may have up to five — twenty-five during a
      // protocol search. Pausing while the loop is parked on one therefore
      // returns *before* that command resolves, and its completion path then
      // published a full snapshot over the empty one the pause had just
      // emitted: the pre-pause values came back at full opacity, stamped with
      // the time they finished arriving, so even a wall-clock staleness check
      // could not catch them.
      //
      // This is Fable M5-5, narrowed by awaiting the stop and then surviving
      // in the window the timeout leaves open.
      // A *slow but successful* reply, not a wedged one. The first attempt at
      // this test used `swallowPromptFor` and passed with the guard removed:
      // a command that times out makes `_pollBatch` throw, so it never reaches
      // a publish at all. The defect needs the reply to arrive late and be
      // processed normally — which is also the commoner real case, since an
      // ECU busy with something else answers eventually rather than never.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              '0100': [0x41, 0x00, 0xBE, 0x3F, 0xA8, 0x13],
              '010C': [0x41, 0x0C, 0x1A, 0xF8],
            },
          ),
        ],
      );
      final client = Elm327Client(
        transport,
        // Longer than the latency, so the reply is a success and not a
        // timeout; longer than stop()'s two-second barrier, which is the
        // window the defect lives in.
        commandTimeout: const Duration(seconds: 8),
      );
      expect(await client.connect(), isTrue);

      final engine = PollingEngine(client)
        ..setActivePids([PidLibrary.engineRpm]);
      var published = 0;
      final sub = engine.snapshots.listen((_) => published++);
      addTearDown(sub.cancel);

      engine.start();
      // The first cycle has to run at full speed: it opens with `ATRV`, which
      // carries its own two-second timeout, and a slow answer there desyncs
      // the link instead of producing the late *success* this is about.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      transport.responseLatency = const Duration(seconds: 3);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      await engine.stop();
      final atStop = published;
      // Counting emissions is not enough. Suppressing an old loop's *event*
      // while letting it still write readings, faults, the formula cache and
      // the acceleration baseline leaves the stale value to ride out on the
      // next loop's snapshot with a fresh timestamp — which is the failure the
      // suppression was for. So the internal state is asserted too.
      final stateAtStop = engine.current;
      final rpmAtStop = stateAtStop.readings[PidLibrary.engineRpm.id];

      // Past the in-flight reply's arrival. Without the guard this is where a
      // snapshot lands, roughly half a second after `stop()` returned.
      await Future<void>.delayed(const Duration(seconds: 5));

      expect(
        published,
        equals(atStop),
        reason:
            'the loop that owned that command is gone; anything it '
            'publishes now describes a moment before the pause',
      );

      final rpmAfter = engine.current.readings[PidLibrary.engineRpm.id];
      expect(
        rpmAfter?.timestamp,
        equals(rpmAtStop?.timestamp),
        reason:
            'a reply that arrived after the pause must not be recorded at '
            'all — a reading stamped after `stop()` returned is exactly what '
            'the resumed loop would publish as current',
      );
      expect(
        engine.current.faults[PidLibrary.engineRpm.id],
        equals(stateAtStop.faults[PidLibrary.engineRpm.id]),
        reason: 'and neither may its error handling rewrite the fault map',
      );

      await engine.dispose();
    });
  });

  group('a silent adapter cannot leave a session that looks alive', () {
    test('the loss is reported even when the command timer wins the race', () async {
      // Fable reproduced this on a device: freeze the adapter and the
      // dashboard keeps its green dot, its throughput pill and its last values
      // for four minutes, while the fault-code screen simultaneously says
      // 連線已中斷. Nothing self-heals; only switching tabs even dims the
      // gauges.
      //
      // The existing watchdog test could not catch it, because it set
      // `watchdogTimeout` to 2s against a default 5s `commandTimeout` — a rig
      // in which the watchdog always fires first. In production both are five
      // seconds, and `_onCommandTimeout` clears `_pending` about 10ms before
      // the next command goes out, so the tick had roughly a 1% chance of
      // observing an outstanding command. The other 99% of the time the
      // command timer won, `_resync` failed, and *that* path told nobody.
      //
      // Equal timeouts here, which is the production relationship.
      final transport = _adapter();
      final client = Elm327Client(
        transport,
        commandTimeout: const Duration(milliseconds: 600),
        watchdogTimeout: const Duration(milliseconds: 600),
      );
      expect(await client.connect(), isTrue);

      var lost = 0;
      client.onConnectionLost = () => lost++;

      // Wedged, not disconnected. A transport-level drop reports itself; this
      // is the case where nothing does.
      transport.goSilent = true;

      // Keep asking, the way the polling loop does, so the recovery path is
      // actually reached. Every one of these fails; that is the point.
      Future<void> poll() async {
        try {
          await client.send('010C');
        } on Object {
          // Expected: timeout, then a resync that cannot succeed.
        }
      }

      final deadline = DateTime.now().add(const Duration(seconds: 12));
      unawaited(poll());
      while (lost == 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        unawaited(poll());
      }

      expect(
        lost,
        greaterThan(0),
        reason:
            'a wedged adapter must end the session; leaving it up is what '
            'produced a green, confidently connected, frozen dashboard',
      );

      await client.dispose();
    });
  });

  group('interleaved transitions', () {
    test('an unawaited stop followed immediately by start leaves one loop', () async {
      // This is the shape a real pause/resume pair has: `_onAppPaused` fires
      // `stop()` without awaiting it, and a resume can call `start()` while
      // that stop is still draining. The session serialises them through one
      // chain, but the engine has to survive the interleaving on its own too —
      // if it does not, the chain is the only thing standing between the app
      // and two loops on a half-duplex link.
      final transport = _adapter();
      final client = Elm327Client(
        transport,
        commandTimeout: const Duration(milliseconds: 200),
      );
      expect(await client.connect(), isTrue);

      final engine = PollingEngine(client)
        ..setActivePids([PidLibrary.engineRpm]);

      for (var i = 0; i < 5; i++) {
        engine.start();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        // Deliberately not awaited, then immediately restarted.
        unawaited(engine.stop());
        engine.start();
        expect(engine.isRunning, isTrue);
      }

      await engine.stop();
      expect(engine.isRunning, isFalse);

      // One loop, whatever the interleaving: nothing may reach the adapter
      // after the final stop returns.
      final settled = transport.commandLog.length;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        transport.commandLog.length,
        equals(settled),
        reason: 'a loop survived the interleaving and is still polling',
      );

      await engine.dispose();
    });
  });

  test(
    'a write that never completes ends the command rather than the session',
    () async {
      // `WifiTransport.write` is `socket.add` plus `await flush()`. On a
      // half-dead TCP link — the phone carried out of range of the adapter's
      // hotspot, no RST, the OS retransmitting for a quarter of an hour — that
      // flush never returns and never throws. The command chain then parks on
      // the write forever, `_pending` is cleared by its own timer, and the
      // watchdog has nothing to observe: a frozen screen that still says
      // connected.
      final transport = _adapter();
      final client = Elm327Client(
        transport,
        commandTimeout: const Duration(seconds: 5),
        writeTimeout: const Duration(milliseconds: 300),
      );
      expect(await client.connect(), isTrue);

      transport.stallWrites = true;

      final started = DateTime.now();
      await expectLater(client.send('010C'), throwsA(isA<Object>()));
      final elapsed = DateTime.now().difference(started);

      expect(
        elapsed,
        lessThan(const Duration(seconds: 2)),
        reason:
            'the write has its own deadline; waiting out the command timeout '
            'would mean the deadline is not doing anything',
      );

      await client.dispose();
    },
  );
}
