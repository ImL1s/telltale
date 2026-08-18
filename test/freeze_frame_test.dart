/// The freeze frame, and the fiction it is one gate away from.
///
/// Service 02 is the car as it was when a fault was confirmed. What makes it
/// worth testing beyond "does it parse" is the shape of its failure: a
/// controller with no stored frame does not refuse the request. It answers
/// PID 02 — the causing code — with `00 00`, and then answers every other PID
/// with zeroes, which decode into 0 rpm, −40 °C coolant and 0% load. Well
/// formed, precise, and a moment that never happened. Under the heading
/// 故障發生當下的車況 somebody would diagnose against it.
///
/// So the causing code is read first and gates the rest. `DemoTransport`
/// produces that trap deliberately after a clear, which is what makes removing
/// the gate visible here rather than plausible.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/obd/dtc/dtc.dart';
import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/freeze_frame.dart';
import 'package:torque_obd/obd/polling_engine.dart';
import 'package:torque_obd/obd/transport/demo_transport.dart';

Future<(Elm327Client, PollingEngine)> _connected() async {
  final client = Elm327Client(DemoTransport());
  expect(await client.connect(), isTrue);
  return (client, PollingEngine(client));
}

double _valueOf(FreezeFrame frame, String modeAndPid) => frame.readings
    .firstWhere((r) => r.pid.modeAndPid == modeAndPid,
        orElse: () => throw StateError('$modeAndPid missing from the frame'))
    .value;

void main() {
  test('a stored frame comes back attributed, and names what stored it',
      () async {
    final (client, engine) = await _connected();
    final frames = (await engine.readFreezeFrames()).frames;
    expect(frames, hasLength(1));
    final frame = frames.single;

    expect(frame.source, '7E8', reason: 'a snapshot belonging to nobody '
        'cannot be checked against anybody\'s fault codes');
    expect(frame.frameNumber, 0);
    // The first confirmed code, which for this simulated car is the misfire.
    expect(frame.cause.code, 'P0301');

    await client.dispose();
  });

  test('the values are the frozen ones, not the live ones', () async {
    // The property that makes this a freeze frame at all. `DemoTransport`
    // answers service 02 with a fixed moment that differs from every live
    // Mode 01 reading, so an implementation that polled `010C` and called it a
    // freeze frame fails here instead of looking right forever.
    final (client, engine) = await _connected();
    final frame = (await engine.readFreezeFrames()).frames.single;

    expect(_valueOf(frame, '010C'), closeTo(2856, 0.5), reason: 'rpm');
    expect(_valueOf(frame, '010D'), closeTo(78, 0.5), reason: 'km/h');
    expect(_valueOf(frame, '0105'), closeTo(91, 0.5), reason: '°C coolant');
    expect(_valueOf(frame, '0104'), closeTo(74.1, 0.2), reason: '% load');
    expect(_valueOf(frame, '010F'), closeTo(34, 0.5), reason: '°C intake');
    expect(_valueOf(frame, '0110'), closeTo(18.4, 0.05), reason: 'g/s MAF');
    expect(_valueOf(frame, '011F'), closeTo(1247, 0.5), reason: 's run time');

    await client.dispose();
  });

  test('PIDs the frame carries that this app cannot decode are counted',
      () async {
    // Monitor status (`01`) and fuel system status (`03`) are in the frame and
    // have no gauge definition here. Counted rather than dropped: a list
    // silently shortened to what the app understands looks like the whole
    // frame to somebody comparing it against a scan-tool printout.
    final (client, engine) = await _connected();
    final frame = (await engine.readFreezeFrames()).frames.single;

    expect(frame.undecodable, 2);
    expect(frame.readings, hasLength(13));

    await client.dispose();
  });

  test('a PID above 0x20 is fetched, so the second mask block is really read',
      () async {
    // The rule this pins: the app loops over every published support block
    // while the continuation bit is set, instead of reading `0200` and
    // stopping. `0121` — distance driven with the lamp on — is in the second
    // block and is one of the more useful things a frame carries, and it was
    // invisible until the loop existed.
    //
    // Delete every block after the first and this reddens; nothing else in the
    // file notices, because everything else lives under 0x20.
    final (client, engine) = await _connected();
    final frame = (await engine.readFreezeFrames()).frames.single;

    expect(_valueOf(frame, '0121'), closeTo(210, 0.5),
        reason: 'km driven with the MIL on, from the second support block');

    await client.dispose();
  });

  test('after a clear there is no frame, and no numbers are invented',
      () async {
    // The whole point. The simulator still answers every data PID after a
    // clear — with zeroes, exactly as a real controller does — so this passes
    // only because the causing code is checked first.
    //
    // The gate is `decodePair` returning null for `00 00` and the frame list
    // being built from the causes that survived it — *not* the `causes.isEmpty`
    // early return, which is an optimisation: with no causes the per-source
    // checks drop every reply anyway and the result is empty either way.
    // Verified by mutation, because a guard that reads like the load-bearing
    // one and is not is exactly the sort of thing a comment gets wrong: accept
    // a zero pair as a code and this reddens with a frame reporting 0 rpm at
    // −40 °C.
    final (client, engine) = await _connected();
    expect((await engine.readFreezeFrames()).frames, isNotEmpty,
        reason: 'the before, so the after means something');

    await engine.clearDtcs();
    final after = (await engine.readFreezeFrames()).frames;

    expect(after, isEmpty);

    await client.dispose();
  });

  test('a frame number the vehicle does not have is not answered with frame 0',
      () async {
    // An adapter that substituted frame 0's contents would let the app label a
    // snapshot as a different one. Nearly every vehicle stores only frame 0,
    // so this is the ordinary case rather than an exotic one.
    //
    // It throws rather than returning empty, and that is the contract now: an
    // unanswered request means the app does not know what is stored, and an
    // empty list is reserved for a controller that answered and said there is
    // nothing. Collapsing the two is what let a Mode 02 timeout read as
    // 沒有儲存凍結幀 on a screen whose next control destroys the frame.
    final (client, engine) = await _connected();
    await expectLater(
      engine.readFreezeFrames(frameNumber: 3),
      throwsA(isA<DtcReadException>()),
    );
    await client.dispose();
  });

  test('the request carries the frame number, and the reply is checked for it',
      () async {
    // The one-byte difference from Mode 01, in both directions. A conforming
    // ECU will not answer `02 0C`; a permissive clone answers anyway with the
    // data shifted, which is a plausible wrong number rather than an error.
    final client = Elm327Client(DemoTransport());
    expect(await client.connect(), isTrue);

    final withFrame = await client.sendGlobal('020C00');
    expect(withFrame.isSuccess, isTrue);
    expect(withFrame.frames.single.bytes.sublist(0, 3), [0x42, 0x0C, 0x00],
        reason: 'service, PID and frame number, all echoed before the data');

    await client.dispose();
  });
}
