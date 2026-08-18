/// Asking the silent controllers by name, once, before giving up on them.
///
/// A functional broadcast is one request and one window. A module can miss it
/// for reasons that say nothing about whether it would answer — another
/// controller's long reply filling the adapter's buffer, a lost flow-control
/// frame, a module still waking — and the scan then refuses, correctly,
/// because silence is not an answer. The user is told the vehicle could not be
/// read when one more question would have read it.
///
/// The rules that matter here are the ones about what this must *not* become.
/// It runs only after the broadcast has already failed coverage; it may only
/// add controllers to the answered set; and nothing it does may turn silence
/// into a clean bill of health.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/obd/dtc/dtc.dart';
import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/polling_engine.dart';

import 'support/fake_elm327.dart';

Future<PollingEngine> _connect(FakeElm327 transport) async {
  await transport.connect();
  final client = Elm327Client(transport);
  expect(await client.connect(), isTrue);
  return PollingEngine(client);
}

const _physics = {
  '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
  '0101': [0x41, 0x01, 0x00, 0x07, 0x65, 0x04],
};

/// Two controllers. The transmission misses the broadcast and answers by name.
FakeElm327 _tcmMissesBroadcast({required List<int> tcmStored}) => FakeElm327(
      protocol: BusProtocol.can11,
      ecus: [
        FakeEcu(
          name: 'ECM',
          requestId: '7E0',
          responseId: '7E8',
          responses: {..._physics, '03': [0x43, 0x00], '07': [0x47, 0x00]},
        ),
        FakeEcu(
          name: 'TCM',
          requestId: '7E1',
          responseId: '7E9',
          responses: {
            '0100': [0x41, 0x00, 0x80, 0x00, 0x00, 0x00],
            '03': tcmStored,
            '07': [0x47, 0x00],
          },
          missesFunctionalFor: const {'03'},
        ),
      ],
    );

void main() {
  test('a controller that misses the broadcast is asked by name', () async {
    // Without this the scan refuses: `7E9` answered `0100`, so it is owed, and
    // it said nothing to the broadcast. Refusing is right — but it is a
    // wasted trip when one directly addressed request gets the answer.
    final engine = await _connect(
        _tcmMissesBroadcast(tcmStored: const [0x43, 0x01, 0x07, 0x15]));
    await engine.discoverResponders();

    final codes = await engine.readDtcs(DtcKind.stored);
    expect(codes.map((d) => d.code), contains('P0715'),
        reason: "the transmission's fault is the whole reason to ask");
    expect(codes.single.sourceId, '7E9',
        reason: 'and it is attributed to the controller that sent it, not to '
            'whoever happened to be addressed');
    await engine.dispose();
  });

  test('and the scan completes rather than reporting the vehicle unreadable',
      () async {
    // The `7E8`-answered-and-`7E9`-did-not case, where the transmission turns
    // out to have nothing wrong. Before, this was a refusal; the car is
    // readable and now reads as clean, honestly, because both controllers
    // answered.
    final engine =
        await _connect(_tcmMissesBroadcast(tcmStored: const [0x43, 0x00]));
    await engine.discoverResponders();

    expect(await engine.readDtcs(DtcKind.stored), isEmpty);
    await engine.dispose();
  });

  test('a controller silent to its own request stays owed', () async {
    // The rule this must never break. Asking by name is a way to *rule out* a
    // broadcast that went astray; a module that will not answer its own
    // physically addressed request has not been heard from, and the scan must
    // still refuse rather than report the vehicle clean.
    final engine = await _connect(FakeElm327(
      protocol: BusProtocol.can11,
      ecus: [
        FakeEcu(
          name: 'ECM',
          requestId: '7E0',
          responseId: '7E8',
          responses: {..._physics, '03': [0x43, 0x00]},
        ),
        FakeEcu(
          name: 'TCM',
          requestId: '7E1',
          responseId: '7E9',
          // Answers the census and nothing else, on any address.
          responses: {'0100': [0x41, 0x00, 0x80, 0x00, 0x00, 0x00]},
        ),
      ],
    ));
    await engine.discoverResponders();

    await expectLater(
      engine.readDtcs(DtcKind.stored),
      throwsA(isA<DtcReadException>()
          .having((e) => e.message, 'message', contains('7E9'))),
      reason: 'silence is not an answer, however it is asked for',
    );
    await engine.dispose();
  });

  test('a reply from the wrong controller does not discharge the debt',
      () async {
    // The failure mode that would make this whole thing dangerous. A
    // physically addressed request should only ever be answered by its target,
    // and "should" is not a thing to build an all-clear on: if some other
    // module's `43 00` were accepted here, the silent controller's debt would
    // be settled by a reply it never sent.
    final engine = await _connect(FakeElm327(
      protocol: BusProtocol.can11,
      faults: const AdapterFaults(
        // Whatever is asked, `7E8` answers — including the request addressed
        // to `7E1`.
        forcedReplies: {'03': '7E8 02 43 00'},
      ),
      ecus: [
        FakeEcu(
          name: 'ECM',
          requestId: '7E0',
          responseId: '7E8',
          responses: {..._physics},
        ),
        FakeEcu(
          name: 'TCM',
          requestId: '7E1',
          responseId: '7E9',
          responses: {'0100': [0x41, 0x00, 0x80, 0x00, 0x00, 0x00]},
        ),
      ],
    ));
    await engine.discoverResponders();

    await expectLater(
      engine.readDtcs(DtcKind.stored),
      throwsA(isA<DtcReadException>()
          .having((e) => e.message, 'message', contains('7E9'))),
      reason: "7E8 cannot answer for 7E9, whatever address the question went "
          'to',
    );
    await engine.dispose();
  });

  test('nothing is asked by name on a bus where the address is a guess',
      () async {
    // ISO 15765-4 pairs 7E0–7E7 with 7E8–7EF and nothing else. On a legacy bus
    // there is no derivation — there is a guess, and a request sent to a
    // guessed address is answered by whoever owns it. The scan refuses, as it
    // did before this existed.
    final engine = await _connect(FakeElm327(
      protocol: BusProtocol.iso9141,
      ecus: [
        FakeEcu(
          name: 'ECM',
          requestId: '686AF1',
          responseId: '486B10',
          responses: {..._physics, '03': [0x43, 0x00]},
        ),
        FakeEcu(
          name: 'TCM',
          requestId: '686BF1',
          responseId: '486B18',
          responses: {'0100': [0x41, 0x00, 0x80, 0x00, 0x00, 0x00]},
        ),
      ],
    ));
    await engine.discoverResponders();

    await expectLater(
      engine.readDtcs(DtcKind.stored),
      throwsA(isA<DtcReadException>()),
      reason: 'inventing an address is worse than admitting the gap',
    );
    await engine.dispose();
  });
}
