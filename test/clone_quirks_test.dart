/// Behaviours cheap clone adapters have and the datasheet's ELM327 does not.
///
/// These matter more than they look: the clones are the hardware most people
/// actually plug in, and their quirks fail in the app's worst direction —
/// plausible numbers rather than errors.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/elm327_client.dart';

import 'support/fake_elm327.dart';

FakeEcu _canEcm() => FakeEcu(
      name: 'ECM',
      requestId: '7E0',
      responseId: '7E8',
      responses: {
        '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
        '010C': [0x41, 0x0C, 0x1A, 0xF8],
      },
    );

void main() {
  _isoTpIntegrityTests();
  group('an adapter that keeps echoing numeric commands after ATE0', () {
    test('still connects', () async {
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [_canEcm()],
        faults: const AdapterFaults(echoNumericCommands: true),
      );
      expect(await Elm327Client(transport).connect(), isTrue);
    });

    test('does not prepend its echo to the payload', () async {
      // `ATZ`'s echo was harmless and is the only case the old test covered —
      // `ATZ` is not hex, so the payload whitelist dropped it by accident. The
      // echo of `010C` *is* valid hex, so it passed the same whitelist and put
      // two extra bytes in front of the reading.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [_canEcm()],
        faults: const AdapterFaults(echoNumericCommands: true),
      );
      final client = Elm327Client(transport);
      expect(await client.connect(), isTrue);

      final response = await client.send('010C');
      expect(response.bytes, [0x41, 0x0C, 0x1A, 0xF8]);
      expect(response.hexPayload, '410C1AF8');
    });

    test('a line that merely looks like the command is kept', () async {
      // The echo is dropped only on an exact match with the command actually
      // outstanding. A blanket "looks like a command" rule would eat data.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [_canEcm()],
        faults: const AdapterFaults(
          // Single-line reply whose bytes happen to spell the request.
          forcedReplies: {'010C': '01 0C'},
        ),
      );
      final client = Elm327Client(transport);
      expect(await client.connect(), isTrue);

      final response = await client.send('010C');
      expect(response.bytes, [0x01, 0x0C]);
    });
  });

  group('NUL bytes in the stream', () {
    test('are stripped rather than breaking the payload whitelist', () async {
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [_canEcm()],
        faults: const AdapterFaults(injectNulls: true),
      );
      final client = Elm327Client(transport);
      expect(await client.connect(), isTrue);
      final response = await client.send('010C');
      expect(response.bytes, [0x41, 0x0C, 0x1A, 0xF8]);
    });
  });

  group('replies split across arbitrary chunk boundaries', () {
    test('reassemble, including a prompt alone in its own chunk', () async {
      // BLE notifications split wherever they like. A `>` arriving by itself
      // is the shape that breaks naive framing.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [_canEcm()],
        faults: const AdapterFaults(maxChunkBytes: 1),
      );
      final client = Elm327Client(transport);
      expect(await client.connect(), isTrue);
      final response = await client.send('010C');
      expect(response.bytes, [0x41, 0x0C, 0x1A, 0xF8]);
    });
  });
}

/// ISO-TP reassembly must reject what it cannot prove intact.
void _isoTpIntegrityTests() {
  FakeEcu vinEcu() => FakeEcu(
        name: 'ECM',
        requestId: '7E0',
        responseId: '7E8',
        responses: {
          '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
          // 49 02 01 + the datasheet's 17-character VIN.
          '0902': [
            0x49, 0x02, 0x01,
            ...'1D4GP00R55B123456'.codeUnits,
          ],
        },
      );

  group('a multi-frame reply that is not intact is rejected', () {
    test('the intact reply reassembles', () async {
      final transport =
          FakeElm327(protocol: BusProtocol.can11, ecus: [vinEcu()]);
      final client = Elm327Client(transport);
      expect(await client.connect(), isTrue);
      final response = await client.send('0902');
      expect(response.isSuccess, isTrue);
      expect(response.bytes.length, 20); // 49 02 01 + 17
    });

    test('a lost continuation line does not become a shorter payload',
        () async {
      // A BLE notification carrying `1:` is simply lost while `0:`, `2:` and
      // the prompt all arrive. Accepting what is left fabricates an identity.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [vinEcu()],
        faults: const AdapterFaults(dropSequenceIndex: 1),
      );
      final client = Elm327Client(transport);
      expect(await client.connect(), isTrue);
      final response = await client.send('0902');
      expect(response.isSuccess, isFalse);
    });

    test('segments arriving out of order are rejected', () async {
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [vinEcu()],
        faults: const AdapterFaults(reorderSequenceLines: true),
      );
      final client = Elm327Client(transport);
      expect(await client.connect(), isTrue);
      final response = await client.send('0902');
      expect(response.isSuccess, isFalse);
    });

    test('the declared length bounds the payload, so padding is not data',
        () async {
      final transport =
          FakeElm327(protocol: BusProtocol.can11, ecus: [vinEcu()]);
      final client = Elm327Client(transport);
      expect(await client.connect(), isTrue);
      final response = await client.send('0902');
      // Three frames carry 6 + 7 + 7 = 20 bytes, and the reply is exactly 20;
      // any zero padding the adapter added must not extend the payload.
      expect(response.bytes.length, 20);
      expect(response.bytes.last, isNot(0));
    });
  });
}
