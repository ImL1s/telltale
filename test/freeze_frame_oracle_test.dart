/// The freeze frame, against an ELM327 this project did not write.
///
/// Every other freeze-frame test in this suite is ultimately my parser checked
/// against my simulator — the same reading of J1979 on both sides of the wire,
/// so a misreading agrees with itself. This one runs against the virtual server
/// on the `research/obd2-apps-analysis` branch, whose Mode 02 was written by a
/// different agent from a different reading of the standard.
///
/// It disagreed usefully on the first contact. It implements the Mode 02 data
/// PIDs and **no support mask at all** — `020000` answers `NO DATA` — which is
/// a shape a conforming ECU should not have and a real bus produces anyway,
/// through a gateway that filters it or a clone adapter that drops it. Against
/// a mask-first reader that vehicle has a perfectly readable freeze frame and
/// shows nothing. This is the test that would have caught it.
///
/// Skipped unless the server is running:
///
///     git show research/obd2-apps-analysis:harnesses/elm327_virtual_server.py > /tmp/vsrv.py
///     python3 /tmp/vsrv.py --port 35000 &
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/dtc/dtc.dart';
import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/polling_engine.dart';
import 'package:torque_obd/obd/readiness.dart';
import 'package:torque_obd/obd/transport/wifi_transport.dart';

const _host = '127.0.0.1';
const _port = 35000;

/// Whether the thing on the port is *this* oracle.
///
/// Asked the same way `emulator_integration_test.dart` asks its own question,
/// and for the reason recorded there: port 35000 is `WifiTransport.defaultPort`
/// and therefore where anybody's ELM327 simulator ends up. Both servers answer
/// `ATI` with an `ELM327 v1.x` banner; `AT@1` is the device description and is
/// the only thing that tells them apart. Ircama's says `OBDII to RS232
/// Interpreter`; this one says `Virtual OBD Diagnostic Server`.
Future<bool> _oracleIsVirtualServer() async {
  Socket? socket;
  try {
    socket = await Socket.connect(_host, _port,
        timeout: const Duration(seconds: 2));
    final replies = StringBuffer();
    socket.listen(
      (bytes) => replies.write(String.fromCharCodes(bytes)),
      onError: (_) {},
    );
    socket.write('ATZ\r');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    // Polled rather than waited on a completer that the *reset* reply would
    // already have finished. The first version armed the completer before
    // `ATZ`, so it fired on the banner, and the await after the buffer was
    // cleared returned instantly against nothing — the check then reported
    // "no oracle" while the server was answering perfectly two lines above in
    // a shell. A skipped test that should have run is a test that cannot fail.
    replies.clear();
    socket.write('AT@1\r');
    for (var i = 0; i < 30; i++) {
      if (replies.toString().contains('>')) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return replies.toString().contains('Virtual OBD Diagnostic Server');
  } on Object {
    return false;
  } finally {
    socket?.destroy();
  }
}

void main() {
  late bool available;

  setUpAll(() async {
    available = await _oracleIsVirtualServer();
    // The bus is put back before anything runs, not only after.
    //
    // Fault injection lives on the server and outlives the test that set it,
    // so a degraded test that dies before its `finally` leaves an 85% drop
    // rate behind — and the next run then fails every test in this file at
    // `connect`, nowhere near the cause. Half an hour went into that once.
    if (available) await _restoreBus();
  });

  /// A connected engine against the oracle, or null when it is not running.
  Future<(Elm327Client, PollingEngine)?> connect() async {
    if (!available) {
      markTestSkipped('virtual server not on $_host:$_port');
      return null;
    }
    final client = Elm327Client(WifiTransport(host: _host, port: _port));
    expect(await client.connect(), isTrue);
    return (client, PollingEngine(client));
  }

  test('a frame with no support mask is read anyway', () async {
    final pair = await connect();
    if (pair == null) return;
    final (client, engine) = pair;

    final frames = (await engine.readFreezeFrames()).frames;
    expect(frames, hasLength(1),
        reason: 'the ECM names a causing code, so it has a frame');
    final frame = frames.single;

    // Its own choice of code, not one this project picked: the server stores
    // P0133 as what caused the frame.
    expect(frame.cause.code, 'P0133');
    expect(frame.source, '7E8');

    // The point of the whole test. `020000` answers NO DATA here, so a
    // mask-first reader gets an empty frame; the direct probe of the
    // conventional freeze-frame PIDs is what turns that into readings.
    expect(frame.readings, isNotEmpty,
        reason: 'this server publishes Mode 02 data PIDs and no mask at all — '
            'exactly the vehicle a mask-first reader shows nothing for');
    expect(frame.contentsUnknown, isFalse);

    // Values decoded by this app's formulas from bytes another implementation
    // chose. Wrong scaling on either side shows up here and nowhere else.
    double valueOf(String id) =>
        frame.readings.firstWhere((r) => r.pid.modeAndPid == id).value;
    expect(valueOf('010C'), closeTo(2450, 1), reason: 'rpm from 26 48');
    expect(valueOf('0105'), closeTo(88, 0.5), reason: '°C from 80');
    expect(valueOf('010D'), closeTo(72, 0.5), reason: 'km/h from 48');
    expect(valueOf('0104'), closeTo(65.5, 0.5), reason: '% load from A7');

    // No settling delay. Disposing straight after the read is the case that
    // found the unhandled-error path in `_failPending`, and leaving the sleep
    // in would have hidden it again.
    await client.dispose();
  }, timeout: const Timeout(Duration(seconds: 90)));

  group('the rest of the scan, against the same stranger', () {
    // The freeze frame is not the only thing worth checking against an
    // implementation this project did not write. Everything below decodes
    // bytes another agent chose, through this app's parsers.

    test('all three fault-code classes are read on their own terms', () async {
      final pair = await connect();
      if (pair == null) return;
      final (client, engine) = pair;

      final stored = await engine.readDtcs(DtcKind.stored);

      // `7E8`'s own answer, a multi-frame Mode 03: eight declared bytes across
      // two ISO-TP lines, with the count byte CAN puts after the service.
      expect(stored.map((d) => d.code),
          containsAll(['P0133', 'P0300', 'P0420']));

      // And three more that a functional broadcast alone does not see.
      //
      // Sending `03` to `7DF` by hand on this server returns exactly the three
      // above. The app finds six, because `7E9` and `7EA` answered the census
      // and then went quiet for Mode 03, so it asked each of them by name. The
      // transmission and chassis codes exist and are reachable; a reader that
      // stopped at the broadcast would have called this vehicle three-fifths
      // diagnosed and shown a shorter list with nothing saying so.
      //
      // Set up by a fixture written for something else, which is what makes it
      // worth having: this is the app's central safety property demonstrated
      // against somebody else's idea of how a bus behaves.
      expect(stored.map((d) => d.code),
          containsAll(['P0700', 'P0730', 'C0200']));
      expect(stored.map((d) => d.sourceId).toSet().length, greaterThan(1),
          reason: 'and each code says which controller reported it');

      final pending = await engine.readDtcs(DtcKind.pending);
      expect(pending.map((d) => d.code), ['P0171', 'P0174']);

      // Mode 0A answers NO DATA here — this server does not implement
      // permanent codes, which is also true of most vehicles built before
      // about 2012. The property worth holding is that its absence says
      // nothing about the other two, which have already been read above:
      // the old all-or-nothing loop discarded two good answers for this.
      await expectLater(
        engine.readDtcs(DtcKind.permanent),
        throwsA(isA<DtcReadException>()),
      );
      final again = await engine.readDtcs(DtcKind.stored);
      expect(again.map((d) => d.code), stored.map((d) => d.code),
          reason: 'and the unsupported class did not poison the link');

      await client.dispose();
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('the lamp and the readiness monitors decode', () async {
      final pair = await connect();
      if (pair == null) return;
      final (client, engine) = pair;

      final mil = await engine.readMilStatus();
      expect(mil, isNotNull);
      final summary = mil!.bySource['7E8'];
      expect(summary, isNotNull);
      // `41 01 83 07 E5 00`: bit 7 of A is the lamp, bits 0-6 the count.
      expect(summary!.milOn, isTrue);
      expect(summary.confirmedCount, 3,
          reason: 'and it agrees with the three codes Mode 03 returned — a '
              'controller claiming a different number from its own fault list '
              'is the contradiction the scan verdict exists to catch');
      final readiness = summary.readiness;
      expect(readiness, isNotNull);
      expect(readiness!.ignition, IgnitionType.spark,
          reason: 'bit 3 of B is clear');
      expect(readiness.saysNothing, isFalse);
      expect(readiness.incomplete, isEmpty,
          reason: 'D is 00 — nothing outstanding');

      await client.dispose();
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('the VIN survives reassembly and validation', () async {
      // Mode 09 is the multi-frame path: seventeen characters cannot fit one
      // CAN frame, so this exercises the length header and the sequence
      // prefixes against somebody else's framing.
      final pair = await connect();
      if (pair == null) return;
      final (client, engine) = pair;

      final vin = await engine.readVin();
      expect(vin, isNotNull);
      expect(vin!.length, 17);
      expect(RegExp(r'^[A-HJ-NPR-Z0-9]{17}$').hasMatch(vin), isTrue,
          reason: 'ISO 3779 excludes I, O and Q; a VIN carrying one is a '
              'corrupt read wearing the right length');

      await client.dispose();
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('two controllers answer the census and only one answers Mode 03',
        () async {
      // The safety property this whole app is arranged around, and here it is
      // set up by a fixture nobody wrote for it: `7E9` and `7EA` answer `0100`
      // and neither answers Mode 03. A scan that reported only what `7E8` said
      // would be describing part of a vehicle as though it were all of it.
      final pair = await connect();
      if (pair == null) return;
      final (client, engine) = pair;

      final responders = await engine.discoverResponders();
      await engine.readMilStatus();
      await engine.readDtcs(DtcKind.stored);

      expect(responders, containsAll(['7E8', '7E9', '7EA']),
          reason: 'all three answered the census');
      expect(engine.optionalNotCovered[DtcKind.pending] ?? const <String>{},
          isNot(contains('7E8')),
          reason: '7E8 did answer Mode 07');

      await client.dispose();
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  group('and on a bus that is barely working', () {
    // The server's `AT#` namespace configures fault injection at runtime, so
    // this can degrade the link part way through and restore it afterwards.
    // Kept in this file rather than its own because `flutter test` runs files
    // concurrently and there is one server: a sibling file degrading the bus
    // under another file's scan would produce a failure that belongs to
    // neither.

    test('a deadline is honoured rather than retried past', () async {
      final pair = await connect();
      if (pair == null) return;
      final (client, engine) = pair;
      try {
        // Eighty-five per cent of replies never arrive. That is worse than any
        // real adapter, and the point is not that the read succeeds — it is
        // that asking for eight seconds costs about eight seconds. Without a
        // bound the retries run for minutes with a spinner on screen and no
        // way out but killing the app, which is the state `DtcScanNotifier`'s
        // budget exists to prevent.
        await _control('AT#DROP RATE 0.85');
        final startedAt = DateTime.now();
        try {
          await engine.readDtcs(
            DtcKind.stored,
            deadline: startedAt.add(const Duration(seconds: 8)),
          );
        } on Object {
          // Either outcome is fine here; the assertion is about the clock.
        }
        final elapsed = DateTime.now().difference(startedAt);
        expect(elapsed, lessThan(const Duration(seconds: 30)),
            reason: 'asked for 8s, took ${elapsed.inSeconds}s');
      } finally {
        await _restoreBus();
        await client.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('a link this bad is never reported as a clean vehicle', () async {
      // The failure that matters. This car has six stored codes. A scan that
      // cannot hear them must say so — silence read as an absence of faults is
      // the thing this whole codebase is arranged against, and a degraded link
      // is the most likely way to produce it on a real car.
      final pair = await connect();
      if (pair == null) return;
      final (client, engine) = pair;
      try {
        await _control('AT#DROP RATE 0.85');
        List<Dtc>? codes;
        Object? failure;
        try {
          codes = await engine.readDtcs(
            DtcKind.stored,
            deadline: DateTime.now().add(const Duration(seconds: 10)),
          );
        } on Object catch (e) {
          failure = e;
        }
        // The empty list is the whole assertion. Which exception arrives is
        // deliberately not asserted: a census of twelve runs at this drop rate
        // returned `DtcReadException` eight times and `TimeoutException` four,
        // depending on where in an exchange the losses fell, and pinning one
        // of them made this test fail intermittently for a reason that had
        // nothing to do with the property. `DtcScanNotifier` catches
        // `DtcReadException`, `TimeoutException` and `Object` alike and turns
        // each into a failed category, so the distinction does not reach the
        // screen.
        //
        // Zero of those twelve returned an empty list, which is the outcome
        // this exists to forbid: the app telling somebody their car is clean
        // because it could not hear it.
        if (failure == null) {
          expect(codes, isNotNull);
          expect(codes, isNotEmpty,
              reason: 'an empty list on a link this bad is a false all-clear');
        }
      } finally {
        await _restoreBus();
        await client.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}

/// Sends one harness control command on a socket of its own.
///
/// Not through `Elm327Client`, and that is forced rather than stylistic: the
/// client normalises every command by stripping spaces, because a real ELM327
/// ignores them — so `AT#DROP RATE 0.85` leaves as `AT#DROPRATE0.85`, the
/// server answers `?`, and the bus is never degraded at all. Both tests below
/// passed that way, proving nothing, which is how this was found.
///
/// A separate socket is also the honest shape: `AT#` is the harness's control
/// plane, not something the app under test should be able to reach.
Future<void> _control(String command) async {
  final socket = await Socket.connect(_host, _port,
      timeout: const Duration(seconds: 3));
  final seen = StringBuffer();
  socket.listen((b) => seen.write(String.fromCharCodes(b)), onError: (_) {});
  socket.write('$command\r');
  for (var i = 0; i < 30; i++) {
    if (seen.toString().contains('>')) break;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  expect(seen.toString(), isNot(contains('?')),
      reason: 'the harness refused "$command"');
  socket.destroy();
}

/// Puts the link back, without touching anything else.
///
/// Deliberately not `AT#RESET`, which also clears the vehicle's fault codes —
/// its name says RESET_ALL and it means it. Using it to undo a drop rate wiped
/// the six stored codes the rest of this file asserts on, and the failures then
/// landed on tests that had nothing to do with the one that broke it.
Future<void> _restoreBus() async {
  await _control('AT#DROP NONE');
  await _control('AT#DELAY 0');
}
