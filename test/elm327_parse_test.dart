/// Regression tests for the ELM327 response parser.
///
/// Every case here is a wire format taken from the ELM327 datasheet rather than
/// from the reverse-engineering spec or from the in-app simulator. The three
/// worst defects this app has had all lived in the gap between what the
/// simulator produced and what a real adapter puts on the line, and they all
/// produced *plausible wrong numbers* rather than errors — which is the failure
/// mode a dashboard can never be allowed to have.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/transport/demo_transport.dart';

/// Builds a client purely to reach its parser; no connection is made.
Elm327Client _client() => Elm327Client(DemoTransport());

ObdResponse _parse(String wire) =>
    _client().parseFrameForTest(ascii.encode(wire.replaceAll('\n', '\r')));

void main() {
  group('single-frame replies', () {
    test('a plain Mode 01 reply parses to its data bytes', () {
      final response = _parse('41 0C 1A F0');
      expect(response.isSuccess, isTrue);
      expect(response.hexPayload, '410C1AF0');
      expect(response.bytes, [0x41, 0x0C, 0x1A, 0xF0]);
    });

    test('a reply without spaces parses identically', () {
      expect(_parse('410C1AF0').bytes, [0x41, 0x0C, 0x1A, 0xF0]);
    });

    test('SEARCHING... is dropped rather than parsed as data', () {
      // 'SEARCHING' contains A, C, E — a blacklist strip would turn it into
      // hex and prepend garbage to the real answer.
      final response = _parse('SEARCHING...\n41 0C 1A F0');
      expect(response.isSuccess, isTrue);
      expect(response.bytes, [0x41, 0x0C, 0x1A, 0xF0]);
    });

    test('the echoed command is not parsed as data', () {
      // Echo is on until ATE0 lands, so the reply to ATZ starts with ATZ.
      final response = _parse('ATZ\n\nELM327 v2.1');
      expect(response.hexPayload, isEmpty);
    });
  });

  group('multi-frame replies — datasheet §"OBD Message Formats"', () {
    // >0902
    // 014
    // 0: 49 02 01 31 44 34
    // 1: 47 50 30 30 52 35 35
    // 2: 42 31 32 33 34 35 36
    const vinWire = '014\n'
        '0: 49 02 01 31 44 34\n'
        '1: 47 50 30 30 52 35 35\n'
        '2: 42 31 32 33 34 35 36';

    test('the total-length header is not treated as payload', () {
      final response = _parse(vinWire);
      // `014` would contribute three nibbles and shift everything by half a
      // byte, which is how a VIN turns into noise.
      expect(response.hexPayload.startsWith('490201'), isTrue);
      expect(response.bytes.first, 0x49);
      expect(response.bytes[1], 0x02);
    });

    test('the decoded VIN matches the datasheet example exactly', () {
      final bytes = _parse(vinWire).bytes;
      final vin = String.fromCharCodes(bytes.skip(3));
      expect(vin, '1D4GP00R55B123456');
    });

    test('sequence prefixes are stripped from every line', () {
      expect(_parse(vinWire).bytes.length, 20);
    });

    test('a bare four-hex-digit single-frame reply stays data', () {
      // Only a multi-frame reply can carry a length header, so this must not
      // be mistaken for one.
      expect(_parse('41 42').bytes, [0x41, 0x42]);
      expect(_parse('4142').bytes, [0x41, 0x42]);
    });
  });

  group('error and alert messages are never read as data', () {
    // Each of these reduces to valid-looking hex under a "strip non-hex"
    // approach: DATA ERROR -> DAAE -> two bytes a gauge would happily show.
    const cases = <String, Elm327ErrorCode>{
      'NO DATA': Elm327ErrorCode.noData,
      'DATA ERROR': Elm327ErrorCode.dataError,
      '<DATA ERROR': Elm327ErrorCode.dataError,
      'BUS BUSY': Elm327ErrorCode.busBusy,
      'BUS ERROR': Elm327ErrorCode.busError,
      'FB ERROR': Elm327ErrorCode.feedbackError,
      'LV RESET': Elm327ErrorCode.lowVoltageReset,
      'ACT ALERT': Elm327ErrorCode.activityAlert,
      'LP ALERT': Elm327ErrorCode.lowPowerAlert,
      'CAN ERROR': Elm327ErrorCode.canError,
      'BUFFER FULL': Elm327ErrorCode.bufferFull,
      'STOPPED': Elm327ErrorCode.stopped,
      'UNABLE TO CONNECT': Elm327ErrorCode.unableToConnect,
      'BUS INIT: ERROR': Elm327ErrorCode.busInitError,
      'ERR94': Elm327ErrorCode.internalError,
    };

    cases.forEach((wire, expected) {
      test('"$wire" classifies as ${expected.name} and yields no bytes', () {
        final response = _parse(wire);
        expect(response.errorCode, expected, reason: wire);
        expect(response.isSuccess, isFalse, reason: wire);
        expect(response.bytes, isEmpty, reason: wire);
      });
    });

    test('every error code has a message written for a driver', () {
      for (final code in Elm327ErrorCode.values) {
        if (code == Elm327ErrorCode.none) continue;
        expect(code.description, isNotEmpty, reason: code.name);
      }
    });

    test('a bare ? is an unsupported command', () {
      expect(_parse('?').errorCode, Elm327ErrorCode.unknownCommand);
    });

    test('a ? inside a version banner is not an error', () {
      expect(_parse('ELM327 v1.5?').errorCode, isNot(Elm327ErrorCode.unknownCommand));
    });
  });

  group('battery voltage', () {
    test('ATRV is read out of the reply', () {
      expect(_parse('12.6V').batteryVoltage, closeTo(12.6, 1e-9));
    });

    test('a version string is not mistaken for a voltage', () {
      expect(_parse('ELM327 v2.1').batteryVoltage, isNull);
    });
  });

  group('handshake', () {
    test('ATCFC0 is not sent — ISO 15765-4 needs flow control on', () {
      // Turning flow control off stalls every reply longer than one frame:
      // the ECU sends a First Frame and waits for a Flow Control that the
      // adapter would no longer send.
      final commands = Elm327Client.initSequence.map((s) => s.command);
      expect(commands, isNot(contains('ATCFC0')));
    });

    test('ATCRA is not sent — it would filter out the ECU replies', () {
      final commands = Elm327Client.initSequence.map((s) => s.command);
      expect(commands.where((c) => c.startsWith('ATCRA')), isEmpty);
    });

    test('the critical steps are the ones without which nothing works', () {
      final critical = Elm327Client.initSequence
          .where((s) => s.isCritical)
          .map((s) => s.command)
          .toList();
      expect(critical, containsAll(['ATZ', 'ATE0', 'ATSP0']),
          reason: 'a reset the adapter did not perform, an echo that prepends '
              'valid hex to every reading, and no protocol at all — none of '
              'those leaves anything working');

      // And `ATL0` is not one of them, which is the point of the sentence in
      // the test name.
      //
      // Linefeeds are a rendering preference: the parser trims whitespace and
      // frames on the prompt, so an adapter that keeps them on is read
      // correctly either way. Gating the whole connection on a literal `OK`
      // for one cosmetic command meant a clone that will not acknowledge it
      // could not connect at all — and the handshake is the most
      // clone-sensitive surface in this app, where every extra gate is another
      // way for a working adapter to be refused.
      expect(critical, isNot(contains('ATL0')));
    });
  });
}
