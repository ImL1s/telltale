/// CAN Mode 03 carries a DTC count byte that legacy buses do not, and the count
/// is a claim the payload has to honour.
///
/// Datasheet p.35: "the ISO 15765-4 (CAN) protocol is very similar, but it adds
/// an extra data byte (in the second position), showing how many data items
/// (DTCs) are to follow." So `2 + 2*count` is the meaningful payload length and
/// everything past it is padding.
///
/// Reading the count without reconciling it against what actually arrived lets
/// a truncated reply pass as a complete scan and a contradictory one pass as a
/// clean bill of health — on the screen a driver consults before deciding the
/// car is fine.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/dtc/dtc.dart';
import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/polling_engine.dart';

import 'support/fake_elm327.dart';

FakeEcu _canEcm() => FakeEcu(
      name: 'ECM',
      requestId: '7E0',
      responseId: '7E8',
      responses: {
        '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
      },
    );

/// Wraps a raw payload in the header and ISO-TP PCI a real adapter prints.
///
/// `forcedReplies` bypasses the fake's framing, so these fixtures used to
/// arrive anonymous — and a global scan now refuses a reply it cannot
/// attribute, because a lying clone that answers `OK` to `ATH1` and prints no
/// header could otherwise turn one nameless `43 00` into a whole-vehicle
/// all-clear. These tests are about the count byte, not about attribution, so
/// they get a well-formed envelope rather than an exemption.
/// [meaningful] is the ISO-TP length the PCI declares, which is not always the
/// number of bytes on the line: a CAN frame is eight bytes whatever the payload
/// occupies, and the remainder is frame padding.
String _headered(String payload, {int? meaningful}) {
  final bytes = payload.trim().split(RegExp(r'\s+'));
  final length = meaningful ?? bytes.length;
  expect(length, lessThanOrEqualTo(7), reason: 'single-frame fixtures only');
  final pci = length.toRadixString(16).toUpperCase().padLeft(2, '0');
  return '7E8 $pci $payload';
}

Future<PollingEngine> _engineWith(String mode03Reply, {int? meaningful}) async {
  final transport = FakeElm327(
    protocol: BusProtocol.can11,
    ecus: [_canEcm()],
    faults: AdapterFaults(
      forcedReplies: {'03': _headered(mode03Reply, meaningful: meaningful)},
    ),
  );
  final client = Elm327Client(transport);
  expect(await client.connect(), isTrue);
  return PollingEngine(client);
}

void main() {
  group('the CAN count byte is a contract', () {
    test('a reply short of its declared count is rejected', () async {
      // Declares three codes and carries one. Reporting that single code as a
      // finished scan tells the driver the car has one fault when two more were
      // announced and never arrived.
      final engine = await _engineWith('43 03 03 01 00 00 00');
      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()),
      );
    });

    test('a reply carrying codes it declared none of is rejected', () async {
      // Declares zero and carries P0301. Reporting "no codes" here is the
      // single worst output this app can produce: a false all-clear that a
      // person could drive away on.
      final engine = await _engineWith('43 00 03 01');
      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()),
      );
    });

    test('a genuine zero-code reply is an empty list, not an error', () async {
      // `7E8 02 43 00` with headers off. Verified against ELM327-emulator
      // (elm/obd_message.py:2086). This is the only reply that justifies
      // telling the user the car is clean.
      final engine = await _engineWith('43 00');
      expect(await engine.readDtcs(DtcKind.stored), isEmpty);
    });

    test('padding past the declared count is not decoded as P0000', () async {
      // Two codes declared, two present, the rest CAN frame padding to eight
      // bytes. `00 00` is not a fault code.
      // Six meaningful bytes — `43 02` plus two codes — then CAN frame
      // padding, which is what the PCI length distinguishes.
      //
      // Seven payload bytes, not eight. The PCI is the frame's first byte, so
      // eight here made a nine-byte CAN frame — a shape no bus can carry, and
      // one the parser now refuses outright. The fixture was modelling the
      // padding it was written to test wrongly.
      final engine = await _engineWith('43 02 01 33 03 00 00', meaningful: 6);
      final codes = await engine.readDtcs(DtcKind.stored);
      expect(codes.map((d) => d.code).toList(), equals(['P0133', 'P0300']));
    });

    test('a dangling odd byte is corruption, not something to discard',
        () async {
      // This test used to assert the opposite — that `07` is dropped and
      // P0133 returned. Codex named it as an unsafe expectation, and it is:
      // the byte says the frame was cut mid-code, so the declared count of one
      // was satisfied by luck. Returning the half that decoded presents a
      // truncated read as a finished scan, which is the one thing a fault-code
      // screen must never do. Discarding data because it is inconvenient to
      // parse is how a diagnostic tool invents a clean bill of health.
      final engine = await _engineWith('43 01 01 33 07');
      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()),
      );
    });
  });
}
