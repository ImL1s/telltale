/// Parsing replies captured with `ATH1`.
///
/// This has to work before addressing can be fixed, and the order is not
/// optional. Grouping replies by controller — which is what stops a
/// transmission fault being reported as an engine fault — requires headers on.
/// But with headers on every CAN line begins `7E8 …`, and `7E8` is three hex
/// digits, so the payload whitelist (which demands whole byte pairs) rejected
/// the entire line. Turning headers on before teaching the parser to read them
/// would have emptied every response in the app.
///
/// Fixtures are the datasheet's printed lines.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/elm327_client.dart';

import 'support/fake_elm327.dart';

/// Datasheet p.44: two controllers answering `09 04`, frames interleaved.
///
/// Note Elm's own caveat on this example — the First Frame claims 0x013 = 19
/// bytes while the three frames carry 20, and the datasheet flags the
/// discrepancy itself. It is quoted here for the *shape*, which is what it
/// exists to demonstrate.
const _datasheetTwoEcuLines = [
  '7E8 10 13 49 04 01 35 36 30',
  '7E8 21 32 38 39 34 39 41 43',
  '7E9 10 13 49 04 01 35 36 30',
  '7E8 22 00 00 00 00 00 00 31',
  '7E9 21 32 38 39 35 34 41 43',
  '7E9 22 00 00 00 00 00 00 00',
];

FakeEcu _ecuPrinting(Map<String, List<String>> lines) => FakeEcu(
      name: 'ECM',
      requestId: '7E0',
      responseId: '7E8',
      responses: {
        '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
      },
      literalResponses: lines,
    );

Future<Elm327Client> _connected(Map<String, List<String>> lines) async {
  final transport = FakeElm327(
    protocol: BusProtocol.can11,
    ecus: [_ecuPrinting(lines)],
  );
  final client = Elm327Client(transport);
  expect(await client.connect(), isTrue);

  // Headers on, explicitly.
  //
  // The parser keys off the client's own `ATH` state rather than the shape of
  // the line, because with `ATS0` — which the handshake enables — spaces are
  // gone and `4100BE3FA813` splits just as well into a 29-bit ID and a
  // two-byte payload as it does into a support mask. So a fixture of headered
  // lines is only meaningful if the client was told to expect them, which is
  // also what a real adapter requires.
  final ack = await client.send('ATH1');
  expect(ack.isSuccess, isTrue);
  return client;
}

void main() {
  group('two ECUs answering one request', () {
    test('are kept apart instead of being flattened into one payload',
        () async {
      final client = await _connected({'0904': _datasheetTwoEcuLines});
      final response = await client.send('0904');

      expect(response.isSuccess, isTrue);
      expect(response.frames, hasLength(2));
      expect(
        response.frames.map((f) => f.sourceId).toList(),
        equals(['7E8', '7E9']),
      );
    });

    test('each is reassembled from its own interleaved frames', () async {
      // 7E9's frames arrive between 7E8's. Reassembling in arrival order
      // rather than per address builds one message out of two vehicles' worth
      // of data.
      final client = await _connected({'0904': _datasheetTwoEcuLines});
      final response = await client.send('0904');

      final ecm = response.frames.firstWhere((f) => f.sourceId == '7E8');
      final tcm = response.frames.firstWhere((f) => f.sourceId == '7E9');

      // Both start with the positive response to 09 04.
      expect(ecm.bytes.take(3).toList(), [0x49, 0x04, 0x01]);
      expect(tcm.bytes.take(3).toList(), [0x49, 0x04, 0x01]);

      // The declared length bounds each one at 0x13 = 19 bytes.
      expect(ecm.bytes, hasLength(0x13));
      expect(tcm.bytes, hasLength(0x13));

      // The two calibration IDs differ in the bytes the datasheet shows
      // differing — proof they were not mixed.
      expect(ecm.bytes, isNot(equals(tcm.bytes)));
    });

    test('bytes exposes the first responder, not a merger of both', () async {
      final client = await _connected({'0904': _datasheetTwoEcuLines});
      final response = await client.send('0904');
      expect(response.bytes, equals(response.frames.first.bytes));
    });
  });

  group('ISO-TP PCI validation on headered lines', () {
    test('a single frame declares its own length', () async {
      // python-OBD's single-frame fixture; PCI 06 = six data bytes.
      //
      // Deliberately not keyed on `0100`: that is the handshake's own probe,
      // which runs before `ATH1`, and a headered line offered there is
      // correctly rejected — so the fixture would break the connection it
      // needs rather than testing anything.
      final client = await _connected({
        '0120': ['7E8 06 41 20 00 01 02 03'],
      });
      final response = await client.send('0120');
      expect(response.bytes, [0x41, 0x20, 0x00, 0x01, 0x02, 0x03]);
    });

    test('a single frame claiming more than seven bytes is rejected', () async {
      final client = await _connected({
        '0902': ['7E8 08 41 00 00 01 02 03 04 05'],
      });
      final response = await client.send('0902');
      expect(response.isSuccess, isFalse);
    });

    test('a zero-length single frame is rejected', () async {
      final client = await _connected({
        '0902': ['7E8 00'],
      });
      final response = await client.send('0902');
      expect(response.isSuccess, isFalse);
    });

    test('a first frame missing a continuation is rejected', () async {
      final client = await _connected({
        '0902': ['7E8 10 14 49 02 01 31 44 34'],
      });
      final response = await client.send('0902');
      expect(response.isSuccess, isFalse);
    });

    test('a continuation out of sequence is rejected', () async {
      final client = await _connected({
        '0902': [
          '7E8 10 14 49 02 01 31 44 34',
          '7E8 22 47 50 30 30 52 35 35', // should be 21
          '7E8 23 42 31 32 33 34 35 36',
        ],
      });
      final response = await client.send('0902');
      expect(response.isSuccess, isFalse);
    });

    test('a correctly sequenced multi-frame reply reassembles', () async {
      final client = await _connected({
        '0902': [
          '7E8 10 14 49 02 01 31 44 34',
          '7E8 21 47 50 30 30 52 35 35',
          '7E8 22 42 31 32 33 34 35 36',
        ],
      });
      final response = await client.send('0902');
      expect(response.isSuccess, isTrue);
      expect(response.bytes, hasLength(0x14));
      expect(
        String.fromCharCodes(response.bytes.skip(3)),
        '1D4GP00R55B123456',
      );
    });
  });

  group('the fake renders ATH1 the way the datasheet describes', () {
    test('its own output round-trips through the parser', () async {
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
              '0902': [0x49, 0x02, 0x01, ...'1D4GP00R55B123456'.codeUnits],
            },
          ),
        ],
      );
      final client = Elm327Client(transport);
      expect(await client.connect(), isTrue);

      // Turn headers on the way the addressing work will.
      final ack = await client.send('ATH1');
      expect(ack.isSuccess, isTrue);

      final response = await client.send('0902');
      expect(response.isSuccess, isTrue);
      expect(response.frames.single.sourceId, '7E8');
      expect(
        String.fromCharCodes(response.bytes.skip(3)),
        '1D4GP00R55B123456',
      );
    });
  });
}
