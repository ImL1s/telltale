/// Two answers to a question that has one answer, and a controller that will
/// not say what is in its frame.
///
/// `DemoTransport` cannot produce either — it answers once, correctly, every
/// time — so these use the hostile fake. Both rules came out of the round-38
/// review, and both are the kind that only show up on a real bus.
///
/// The repeat tests run on **ISO 9141, not CAN**, and that is load-bearing
/// rather than incidental. On CAN two Single Frames from one source are an
/// ISO-TP contradiction and `Elm327Client` already rejects the whole reply as a
/// data error — measured, not assumed. A legacy bus prints one complete message
/// per line, so a controller that answers twice produces two accepted frames
/// from one source, and the engine is the only thing standing between that and
/// two engine speeds in one card. Written against CAN these tests would pass
/// with the rule deleted, because the reply never reaches the engine at all.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/freeze_frame.dart';
import 'package:torque_obd/obd/polling_engine.dart';

import 'support/fake_elm327.dart';

/// A controller with a stored misfire and a frame holding one readable value.
///
/// The mask claims PID `0C` (engine speed) and nothing else, so exactly one
/// data request follows and the tests below can be about that one reply.
/// One legacy line from `…10`, checksummed the way ISO 9141 does it.
String _line(List<int> message) => _lineFrom(0x10, message);

/// The same, from the second controller's address.
String _line18(List<int> message) => _lineFrom(0x18, message);

String _lineFrom(int source, List<int> message) {
  final full = [0x48, 0x6B, source, ...message];
  final sum = full.fold<int>(0, (a, b) => (a + b) & 0xFF);
  return [...full, sum]
      .map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0'))
      .join(' ');
}

FakeEcu _ecu({
  Map<String, List<int>> extra = const {},
  Map<String, List<String>> literal = const {},
  bool answersMask = true,
}) =>
    FakeEcu(
      name: 'ECM',
      requestId: '6810',
      responseId: '486B10',
      responses: {
        '0100': [0x41, 0x00, 0x00, 0x08, 0x00, 0x00],
        '0101': [0x41, 0x01, 0x81, 0x07, 0x65, 0x04],
        '03': [0x43, 0x01, 0x03, 0x01],
        '07': [0x47, 0x00],
        '0A': [0x4A, 0x00],
        // The causing code: P0301, the same misfire Mode 03 reports.
        '020200': [0x42, 0x02, 0x00, 0x03, 0x01],
        if (answersMask)
          // Bit for PID 0x0C only. Bit 31 is PID 01, so 0x0C is bit 20.
          '020000': [0x42, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00],
        ...extra,
      },
      literalResponses: literal,
    );

Future<(Elm327Client, PollingEngine)> _connected(FakeEcu ecu) async {
  final client = Elm327Client(
    FakeElm327(protocol: BusProtocol.iso9141, ecus: [ecu]),
  );
  expect(await client.connect(), isTrue);
  return (client, PollingEngine(client));
}

void main() {
  test('a controller that repeats itself with the same value is one reading',
      () async {
    // A duplicate is a duplicate. Nothing is wrong and nothing is lost, so the
    // card shows engine speed once.
    final (client, engine) = await _connected(_ecu(literal: {
      '020C00': [
        _line([0x42, 0x0C, 0x00, 0x2C, 0xA0]),
        _line([0x42, 0x0C, 0x00, 0x2C, 0xA0]),
      ],
    }));
    final frame = (await engine.readFreezeFrames()).frames.single;

    expect(frame.readings.where((r) => r.pid.modeAndPid == '010C'),
        hasLength(1));
    expect(frame.readings.single.value, closeTo(2856, 0.5));
    expect(frame.undecodable, 0);

    await client.dispose();
  });

  test('a controller that repeats itself with a different value gets neither',
      () async {
    // The rule `_splitBatchedResponse` already applies to Mode 01: "two answers
    // to a question that has one answer means the request reached more than one
    // controller, and nothing in the definition says which was meant. Picking
    // one is picking at random."
    //
    // Before this, both went into the same card — two engine speeds, side by
    // side, differing, under a heading claiming to describe one instant. That
    // is a wrong number *and* the app contradicting itself in the same glance.
    final (client, engine) = await _connected(_ecu(literal: {
      '020C00': [
        _line([0x42, 0x0C, 0x00, 0x2C, 0xA0]), // 2856 rpm
        _line([0x42, 0x0C, 0x00, 0x2C, 0xB0]), // 2860 rpm
      ],
    }));
    final frame = (await engine.readFreezeFrames()).frames.single;

    expect(frame.readings, isEmpty,
        reason: 'neither value can be trusted, so neither is shown');
    expect(frame.unread, 1,
        reason: 'counted as "could not establish", not as "no formula here" — '
            'the app has a formula for engine speed, it could not decide '
            'which reading was the frame\'s');
    expect(frame.undecodable, 0);

    await client.dispose();
  });

  test('a controller that will not say what is in its frame says so', () async {
    // It names the causing code and then does not answer `0200`. The frame
    // exists — the code proves it — but nothing is known about the contents.
    //
    // Without the flag this is indistinguishable from a frame this app simply
    // could not decode, and the screen said 「有凍結幀，但沒有本 App 能解讀的
    // 項目」: a claim about the contents, made from a failure to fetch them.
    // One says "your app is limited" and the other says "try again", and only
    // one of them is true here.
    final (client, engine) = await _connected(_ecu(answersMask: false));
    final frame = (await engine.readFreezeFrames()).frames.single;

    expect(frame.cause.code, 'P0301', reason: 'the frame is real');
    expect(frame.readings, isEmpty);
    expect(frame.contentsUnknown, isTrue);

    await client.dispose();
  });

  test('a PID that is claimed and never answered is counted, not dropped',
      () async {
    // The freeze read runs last, under the scan's shared deadline. On a slow
    // adapter the early PIDs land and the later ones expire, and before this
    // the table simply got shorter — a partial frame presented as a whole one,
    // which is the failure `undecodable` was added to prevent arriving through
    // the other door.
    //
    // Here the mask claims engine speed and the controller then never answers
    // `020C00`.
    final (client, engine) = await _connected(_ecu());
    final frame = (await engine.readFreezeFrames()).frames.single;

    expect(frame.readings, isEmpty);
    expect(frame.unread, 1);
    expect(frame.undecodable, 0,
        reason: 'the app has a formula for engine speed; it never got a value');
    expect(frame.contentsUnknown, isFalse,
        reason: 'the mask answered — it is the value that did not');

    await client.dispose();
  });

  test('no mask is not the end of it — the standard frame PIDs are asked '
      'directly', () async {
    // J1979 requires PID 00 support in any service that uses PIDs, so a
    // conforming ECU answers `0200`. A real bus is not all conforming: a
    // gateway can filter it, a clone adapter can drop it, and the third-party
    // ELM327 simulator this project checks itself against implements the Mode
    // 02 data PIDs with no mask at all. In every one of those the frame is
    // readable and this app used to show nothing.
    final (client, engine) = await _connected(_ecu(
      answersMask: false,
      extra: {
        '020C00': [0x42, 0x0C, 0x00, 0x2C, 0xA0],
        '020500': [0x42, 0x05, 0x00, 131],
      },
    ));
    final frame = (await engine.readFreezeFrames()).frames.single;

    expect(frame.readings, hasLength(2));
    expect(frame.contentsUnknown, isFalse,
        reason: 'it stopped being unknown the moment two values came back');
    expect(frame.unread, 0,
        reason: 'the controller never said what its frame holds, so a PID that '
            'did not answer is one this car does not freeze — counting those '
            'would invent a shortfall out of the app\'s own guess');

    await client.dispose();
  });

  test('a controller that answers the mask is not marked unknown', () async {
    // The other direction, so the flag cannot be wired to something that is
    // always true.
    final (client, engine) = await _connected(_ecu(extra: {
      '020C00': [0x42, 0x0C, 0x00, 0x2C, 0xA0],
    }));
    final frame = (await engine.readFreezeFrames()).frames.single;

    expect(frame.contentsUnknown, isFalse);
    expect(frame.readings, hasLength(1));

    await client.dispose();
  });

  test('two controllers with frames do not pool their readings', () async {
    // `readFreezeFrames`' own doc comment calls this the reason the function
    // has the shape it does — "one per controller, never merged" — and round
    // 39 found that nothing tested it: every fixture in the suite had a single
    // ECU, so the per-source gate could be deleted and the suite stayed green.
    //
    // Two legacy controllers, distinct source addresses (the fake refuses a
    // fixture where two share one, because then either reply could cover for
    // the other's silence). Each has its own causing code and its own frozen
    // engine speed. Merging them, or letting one answer stand in for both,
    // shows up as a frame carrying the other's number.
    final ecm = FakeEcu(
      name: 'ECM',
      requestId: '6810',
      responseId: '486B10',
      responses: {
        '0100': [0x41, 0x00, 0x00, 0x08, 0x00, 0x00],
        '0101': [0x41, 0x01, 0x81, 0x07, 0x65, 0x04],
        '03': [0x43, 0x01, 0x03, 0x01],
        '07': [0x47, 0x00],
        '0A': [0x4A, 0x00],
        '020200': [0x42, 0x02, 0x00, 0x03, 0x01], // P0301
        '020000': [0x42, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00],
        '020C00': [0x42, 0x0C, 0x00, 0x2C, 0xA0], // 2856 rpm
      },
    );
    final tcm = FakeEcu(
      name: 'TCM',
      requestId: '6818',
      responseId: '486B18',
      responses: {
        '0100': [0x41, 0x00, 0x00, 0x08, 0x00, 0x00],
        '0101': [0x41, 0x01, 0x82, 0x07, 0x65, 0x04],
        '03': [0x43, 0x01, 0x07, 0x00],
        '07': [0x47, 0x00],
        '0A': [0x4A, 0x00],
        '020200': [0x42, 0x02, 0x00, 0x07, 0x00], // P0700
        '020000': [0x42, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00],
        '020C00': [0x42, 0x0C, 0x00, 0x0F, 0xA0], // 1000 rpm
      },
    );
    final client = Elm327Client(
      FakeElm327(protocol: BusProtocol.iso9141, ecus: [ecm, tcm]),
    );
    expect(await client.connect(), isTrue);
    final engine = PollingEngine(client);

    final frames = (await engine.readFreezeFrames()).frames;
    expect(frames, hasLength(2));

    FreezeFrame frameOf(String cause) =>
        frames.firstWhere((f) => f.cause.code == cause);
    double rpmOf(String cause) => frameOf(cause)
        .readings
        .firstWhere((r) => r.pid.modeAndPid == '010C')
        .value;

    expect(rpmOf('P0301'), closeTo(2856, 1),
        reason: 'the engine controller\'s own snapshot');
    expect(rpmOf('P0700'), closeTo(1000, 1),
        reason: 'and the transmission\'s, which is a different moment');
    expect(frameOf('P0301').source, isNot(frameOf('P0700').source));
    for (final frame in frames) {
      expect(frame.readings, hasLength(1),
          reason: 'neither frame collected the other\'s reply');
    }

    await client.dispose();
  });

  test('a value a controller never said it froze is not put in its frame',
      () async {
    // The per-source gate, isolated. The test above passes with it deleted,
    // because there both controllers claimed the same PIDs — the attribution
    // by `sourceId` alone was enough. This is the case that needs it: the
    // transmission's mask claims coolant and nothing else, and it answers
    // `020C00` anyway, which permissive clones do.
    //
    // Dropping the extra value rather than showing it is a deliberate trade.
    // The mask is the controller's own statement of what its frame holds; a
    // reply outside it is either a sloppy module or a misattributed frame, and
    // there is no way to tell from here. One missing row on a card that says
    // how many are missing is recoverable. A number from the wrong controller,
    // under a heading naming a fault it does not belong to, is what sends
    // somebody after the wrong part.
    final ecm = FakeEcu(
      name: 'ECM',
      requestId: '6810',
      responseId: '486B10',
      responses: {
        '0100': [0x41, 0x00, 0x00, 0x08, 0x00, 0x00],
        '0101': [0x41, 0x01, 0x81, 0x07, 0x65, 0x04],
        '03': [0x43, 0x01, 0x03, 0x01],
        '07': [0x47, 0x00],
        '0A': [0x4A, 0x00],
        '020200': [0x42, 0x02, 0x00, 0x03, 0x01],
        '020000': [0x42, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00], // 0x0C only
        '020C00': [0x42, 0x0C, 0x00, 0x2C, 0xA0],
      },
    );
    final tcm = FakeEcu(
      name: 'TCM',
      requestId: '6818',
      responseId: '486B18',
      responses: {
        '0100': [0x41, 0x00, 0x00, 0x08, 0x00, 0x00],
        '0101': [0x41, 0x01, 0x82, 0x07, 0x65, 0x04],
        '03': [0x43, 0x01, 0x07, 0x00],
        '07': [0x47, 0x00],
        '0A': [0x4A, 0x00],
        '020200': [0x42, 0x02, 0x00, 0x07, 0x00],
        // Bit for PID 0x05 only — coolant, and nothing else.
        '020000': [0x42, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00],
        '020500': [0x42, 0x05, 0x00, 131],
        // Answered anyway, though the mask above never claimed it.
        '020C00': [0x42, 0x0C, 0x00, 0x0F, 0xA0],
      },
    );
    final client = Elm327Client(
      FakeElm327(protocol: BusProtocol.iso9141, ecus: [ecm, tcm]),
    );
    expect(await client.connect(), isTrue);
    final engine = PollingEngine(client);

    final frames = (await engine.readFreezeFrames()).frames;
    final transmission = frames.firstWhere((f) => f.cause.code == 'P0700');
    expect(transmission.readings.map((r) => r.pid.modeAndPid), ['0105'],
        reason: 'coolant is what it said it had; the engine speed it also '
            'answered is not in its frame');

    await client.dispose();
  });

  group('damage inside a successful reply is not an absent frame', () {
    // The tail of the same finding. Throwing covers an exchange that *failed*.
    // A reply the adapter called successful can still be damaged — a causing-
    // code frame cut short by a lost CAN frame, or one with no header to
    // attribute it to — and those were dropped silently. If that was the only
    // controller the result was an empty list, which the screen renders as
    // 沒有儲存凍結幀 and the field guide tells the reader is not bad news, over
    // a button that destroys the frame.

    // Through `literalResponses`, not `responses`. The fake pads a legacy
    // message out to seven bytes, so a three-byte reply handed to `responses`
    // arrives as `42 02 00 00 00 00 00` — which is not truncation, it is a
    // controller saying `00 00`. The line has to go on the wire exactly as
    // written for the damage to exist at all.
    FakeEcu ecuWithCause(List<int> causeReply) => FakeEcu(
          name: 'ECM',
          requestId: '6810',
          responseId: '486B10',
          responses: {
            '0100': [0x41, 0x00, 0x00, 0x08, 0x00, 0x00],
            '0101': [0x41, 0x01, 0x81, 0x07, 0x65, 0x04],
            '03': [0x43, 0x01, 0x03, 0x01],
            '07': [0x47, 0x00],
            '0A': [0x4A, 0x00],
          },
          literalResponses: {'020200': [_line(causeReply)]},
        );

    test('a causing code cut short says so', () async {
      // `42 02 00` — the echo arrived and the code did not.
      final (client, engine) =
          await _connected(ecuWithCause([0x42, 0x02, 0x00]));
      final read = await engine.readFreezeFrames();
      expect(read.frames, isEmpty);
      expect(read.incomplete, isTrue,
          reason: 'the reply was damaged, not empty');
      await client.dispose();
    });

    test('half a causing code says so too', () async {
      // Past the echo check, one byte short of a code.
      final (client, engine) =
          await _connected(ecuWithCause([0x42, 0x02, 0x00, 0x51]));
      final read = await engine.readFreezeFrames();
      expect(read.frames, isEmpty);
      expect(read.incomplete, isTrue);
      await client.dispose();
    });

    test('but a controller answering 00 00 is an answer, not damage',
        () async {
      // The branch that must stay on the silent side: a controller saying it
      // holds no stored code, and therefore no frame. Marking this as damage
      // would put 「這次沒有讀到凍結幀」 on every healthy car with a code in
      // another module.
      final (client, engine) =
          await _connected(ecuWithCause([0x42, 0x02, 0x00, 0x00, 0x00]));
      final read = await engine.readFreezeFrames();
      expect(read.frames, isEmpty);
      expect(read.incomplete, isFalse);
      await client.dispose();
    });

    test('a controller that declines Mode 02 is answering, not breaking',
        () async {
      // `7F 02 11` — service not supported. Folding every negative response
      // into damage made a car whose controllers simply do not offer freeze
      // frames show 「這次沒有讀到凍結幀，請重新掃描」 on every scan, advising a
      // retry that could never work.
      for (final nrc in [0x11, 0x12, 0x31]) {
        final (client, engine) =
            await _connected(ecuWithCause([0x7F, 0x02, nrc]));
        final read = await engine.readFreezeFrames();
        expect(read.frames, isEmpty);
        expect(read.incomplete, isFalse,
            reason: 'NRC ${nrc.toRadixString(16)} is a refusal, not damage');
        await client.dispose();
      }
    });

    test('but a negative response that is not a refusal still counts',
        () async {
      // `7F 02 22` — conditions not correct. That is the controller saying it
      // cannot answer *right now*, which is exactly the case where a rescan
      // might work and the driver should not be told there is no frame.
      final (client, engine) =
          await _connected(ecuWithCause([0x7F, 0x02, 0x22]));
      final read = await engine.readFreezeFrames();
      expect(read.incomplete, isTrue);
      await client.dispose();
    });

    test('one good frame and one damaged is still incomplete', () async {
      // The quieter half. Two controllers with codes, one answering cleanly
      // and one damaged: the good card renders, nothing looks missing, and the
      // second controller reads as having stored nothing.
      final ecm = FakeEcu(
        name: 'ECM',
        requestId: '6810',
        responseId: '486B10',
        responses: {
          '0100': [0x41, 0x00, 0x00, 0x08, 0x00, 0x00],
          '0101': [0x41, 0x01, 0x81, 0x07, 0x65, 0x04],
          '03': [0x43, 0x01, 0x03, 0x01],
          '07': [0x47, 0x00],
          '0A': [0x4A, 0x00],
          '020000': [0x42, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00],
          '020C00': [0x42, 0x0C, 0x00, 0x2C, 0xA0],
        },
        // Literal here too: the fake returns *only* literal lines for a
        // command as soon as any ECU defines one, so a normal `responses`
        // entry on this controller would be dropped and the good half of the
        // case would vanish.
        literalResponses: {'020200': [_line([0x42, 0x02, 0x00, 0x03, 0x01])]},
      );
      final tcm = FakeEcu(
        name: 'TCM',
        requestId: '6818',
        responseId: '486B18',
        responses: {
          '0100': [0x41, 0x00, 0x00, 0x08, 0x00, 0x00],
          '0101': [0x41, 0x01, 0x82, 0x07, 0x65, 0x04],
          '03': [0x43, 0x01, 0x07, 0x00],
          '07': [0x47, 0x00],
          '0A': [0x4A, 0x00],
        },
        literalResponses: {
          // Cut short: the echo arrived and the code did not.
          '020200': [_line18([0x42, 0x02, 0x00])],
        },
      );
      final client = Elm327Client(
        FakeElm327(protocol: BusProtocol.iso9141, ecus: [ecm, tcm]),
      );
      expect(await client.connect(), isTrue);
      final engine = PollingEngine(client);

      final read = await engine.readFreezeFrames();
      expect(read.frames, hasLength(1));
      expect(read.frames.single.cause.code, 'P0301');
      expect(read.incomplete, isTrue,
          reason: 'the transmission answered and its answer was damaged — it '
              'must not read as a controller that stored nothing');

      await client.dispose();
    });
  });
}
