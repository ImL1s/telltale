/// Adversarial coverage for the buses `DemoTransport` cannot speak.
///
/// Round 4 of review found — twice, from two reviewers who never saw each
/// other's work — that a non-CAN vehicle with more than three fault codes makes
/// this app report codes the car never set. The reason no test caught it is
/// structural rather than an oversight: `DemoTransport` only ever produces
/// 11-bit CAN, so the legacy decoding path has never been executed by anything.
///
/// These tests use [FakeElm327], which frames per the selected protocol and
/// refuses anything it was not told about. They are written to the *correct*
/// answer, so they fail against the current implementation. That is the point.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/dtc/dtc.dart';
import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/polling_engine.dart';

import 'support/fake_elm327.dart';

/// A legacy ECU carrying four stored fault codes.
///
/// Four matters: a legacy message holds at most three DTCs, so four is the
/// smallest number that forces the adapter to print a second message — and the
/// second message is where the bug lives. Three or fewer decode correctly,
/// which is exactly why the defect survived manual inspection.
FakeEcu _legacyEcuWithFourCodes() => FakeEcu(
      name: 'ECM',
      requestId: '6810F1',
      responseId: '486BF1',
      responses: {
        '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
        // 43 then P0143, P0196, P0234, P0133.
        '03': [0x43, 0x01, 0x43, 0x01, 0x96, 0x02, 0x34, 0x01, 0x33],
      },
    );

/// The capture retained in `python-OBD`'s own source to document its legacy
/// parser (`obd/protocols/protocol_legacy.py:108-118`), stripped of the three
/// header bytes and checksum that `ATH0` hides:
///
///     48 6B 10 43 03 00 03 02 03 03 ck
///     48 6B 10 43 03 04 00 00 00 00 ck
///
/// A coherent real-world misfire family — random misfire plus cylinders 2, 3
/// and 4 — which is part of why it reads as a genuine capture rather than a
/// constructed one. Sourced rather than invented on purpose: writing legacy
/// fixtures from memory is the same act that produced the defect they test.
FakeEcu _pythonObdCaptureEcu() => FakeEcu(
      name: 'ECM',
      requestId: '6810F1',
      responseId: '486B10',
      responses: {
        '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
        '03': [0x43, 0x03, 0x00, 0x03, 0x02, 0x03, 0x03, 0x03, 0x04],
      },
    );

void main() {
  group('ground truth: the capture python-OBD keeps to document its parser', () {
    test('decodes to P0300 P0302 P0303 P0304 and invents nothing', () async {
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        ecus: [_pythonObdCaptureEcu()],
      );
      final client = Elm327Client(transport);
      expect(await client.connect(), isTrue);

      final codes = await PollingEngine(client).readDtcs(DtcKind.stored);

      // Flattening the two lines and stripping only the leading 43 gives
      // P0300 P0302 P0303 C0303 P0400: three real codes kept, the real P0304
      // lost, and two fabricated. Three-of-five right is why it survives
      // casual testing.
      expect(
        codes.map((d) => d.code).toList(),
        equals(['P0300', 'P0302', 'P0303', 'P0304']),
      );
      expect(codes.map((d) => d.code), isNot(contains('C0303')));
      expect(codes.map((d) => d.code), isNot(contains('P0400')));
    });

    test('the fake reproduces the captured line shape exactly', () async {
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        ecus: [_pythonObdCaptureEcu()],
      );
      final lines = <String>[];
      transport.incoming.listen((b) => lines.add(String.fromCharCodes(b)));

      await transport.connect();
      await transport.write('0100'.codeUnits);
      await Future<void>.delayed(Duration.zero);
      lines.clear();
      await transport.write('03'.codeUnits);
      await Future<void>.delayed(Duration.zero);

      final text = lines.join();
      expect(text, contains('43 03 00 03 02 03 03'));
      expect(text, contains('43 03 04 00 00 00 00'));
    });
  });

  group('legacy (non-CAN) framing', () {
    test('the fake prints one line per message, each repeating the service byte',
        () async {
      // Guard on the harness itself. If this shape is wrong every test built on
      // it is worthless, so it is asserted directly rather than assumed.
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        ecus: [_legacyEcuWithFourCodes()],
      );
      final lines = <String>[];
      transport.incoming.listen((bytes) => lines.add(String.fromCharCodes(bytes)));

      await transport.connect();
      await transport.write('0100'.codeUnits);
      await Future<void>.delayed(Duration.zero);
      lines.clear();
      await transport.write('03'.codeUnits);
      await Future<void>.delayed(Duration.zero);

      final text = lines.join();
      expect(
        text,
        contains('43 01 43 01 96 02 34'),
        reason: 'first message: service byte plus three codes',
      );
      expect(
        text,
        contains('43 01 33 00 00 00 00'),
        reason: 'second message repeats 43 and pads to the full width',
      );
    });

    test('four codes on ISO 9141 decode to exactly those four codes', () async {
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        ecus: [_legacyEcuWithFourCodes()],
      );
      final client = Elm327Client(transport);
      expect(await client.connect(), isTrue);

      final engine = PollingEngine(client);
      final codes = await engine.readDtcs(DtcKind.stored);

      // The car set these four. Anything else on this list was invented by the
      // decoder, and a driver has no way to tell the difference: every entry
      // renders with the same red code chip and the same confident description.
      expect(
        codes.map((d) => d.code).toList(),
        equals(['P0143', 'P0196', 'P0234', 'P0133']),
      );
    });

    test('a legacy bus never claims more codes than the car reported', () async {
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        ecus: [_legacyEcuWithFourCodes()],
      );
      final client = Elm327Client(transport);
      expect(await client.connect(), isTrue);

      final codes = await PollingEngine(client).readDtcs(DtcKind.stored);
      expect(codes, hasLength(4));
      expect(
        codes.map((d) => d.code),
        isNot(contains('C0301')),
        reason: 'C0301 is the artefact of pairing the second message\'s '
            'service byte with the byte after it',
      );
    });
  });

  group('the harness is stricter than the shipped demo', () {
    test('an unrecognised AT command answers ? rather than OK', () async {
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: const [],
      );
      final replies = <String>[];
      transport.incoming.listen((b) => replies.add(String.fromCharCodes(b)));

      await transport.connect();
      await transport.write('ATNOSUCHCOMMAND'.codeUnits);
      await Future<void>.delayed(Duration.zero);

      expect(replies.join(), contains('?'));
      expect(replies.join(), isNot(contains('OK')));
    });

    test('ATSH with the wrong width for the bus is rejected', () async {
      // `ATSH 7E0` is an 11-bit CAN header. On ISO 9141 it is not a valid
      // three-byte header, and a real adapter says so. The app sends it
      // unconditionally after protocol detection.
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        ecus: [_legacyEcuWithFourCodes()],
      );
      final replies = <String>[];
      transport.incoming.listen((b) => replies.add(String.fromCharCodes(b)));

      await transport.connect();
      await transport.write('ATSH7E0'.codeUnits);
      await Future<void>.delayed(Duration.zero);

      expect(replies.join(), contains('?'));
    });

    test('a request to a header no ECU owns gets NO DATA', () async {
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
            },
          ),
        ],
      );
      final replies = <String>[];
      transport.incoming.listen((b) => replies.add(String.fromCharCodes(b)));

      await transport.connect();
      await transport.write('ATSH7E1'.codeUnits); // transmission, not present
      await Future<void>.delayed(Duration.zero);
      replies.clear();
      await transport.write('0100'.codeUnits);
      await Future<void>.delayed(Duration.zero);

      expect(replies.join(), contains('NO DATA'));
    });
  });
}
