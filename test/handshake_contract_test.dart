/// The handshake must prove a *vehicle* answered, not merely that something
/// on the other end of the serial link was polite.
///
/// `ObdResponse.isSuccess` means only "no recognised adapter error string". A
/// broken clone, a wrong paired device, or a half-initialised adapter that
/// answers `OK` to everything therefore walks the entire init sequence and the
/// app reports a live connection with zero ECU payload behind it. Every gauge
/// then shows `--` while the UI insists it is connected, and the user has no
/// way to tell that apart from a car with the ignition off.
///
/// The existing scripted transport in `elm327_resync_test.dart` defaults every
/// unscripted command — including the critical `0100` probe — to `OK`, which is
/// why this class of failure has never shown up in a test.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';

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

Elm327Client _clientFor(FakeElm327 transport) => Elm327Client(
      transport,
      commandTimeout: const Duration(milliseconds: 200),
    );

void main() {
  group('the 0100 probe is a contract, not a formality', () {
    test('a device that answers OK to everything does not connect', () async {
      // The classic wrong-peer case: a BLE speaker, a serial bridge, or a clone
      // whose firmware acknowledges anything it does not understand.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [_canEcm()],
        faults: const AdapterFaults(forcedReplies: {'0100': 'OK'}),
      );
      expect(await _clientFor(transport).connect(), isFalse);
    });

    test('a bare prompt for 0100 does not connect', () async {
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [_canEcm()],
        faults: const AdapterFaults(forcedReplies: {'0100': ''}),
      );
      expect(await _clientFor(transport).connect(), isFalse);
    });

    test('a truncated support mask does not connect', () async {
      // `41 00` with fewer than four mask bytes is not a usable answer; reading
      // it as one produces a support set built from bytes that were never sent.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [_canEcm()],
        faults: const AdapterFaults(forcedReplies: {'0100': '41 00 BE'}),
      );
      expect(await _clientFor(transport).connect(), isFalse);
    });

    test('a reply to the wrong service does not connect', () async {
      // `41 0C` is a perfectly valid response — to a different question.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [_canEcm()],
        faults: const AdapterFaults(
          forcedReplies: {'0100': '41 0C 1A F8 00 00'},
        ),
      );
      expect(await _clientFor(transport).connect(), isFalse);
    });

    test('a negative response to 0100 does not connect', () async {
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [_canEcm()],
        faults: const AdapterFaults(forcedReplies: {'0100': '7F 01 12'}),
      );
      expect(await _clientFor(transport).connect(), isFalse);
    });

    test('a real ECU answer connects', () async {
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [_canEcm()],
      );
      final client = _clientFor(transport);
      expect(await client.connect(), isTrue);
      expect(client.protocolNumber, contains('6'));
    });
  });

  group('state-changing AT commands must be acknowledged', () {
    test('an adapter that will not turn echo off does not connect', () async {
      // Echo left on means every reply is prefixed by the command, and the
      // echo of a numeric command is itself valid hex — it lands in the
      // payload. Proceeding on an unacknowledged ATE0 is how that starts.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [_canEcm()],
        faults: const AdapterFaults(forcedReplies: {'ATE0': '?'}),
      );
      expect(await _clientFor(transport).connect(), isFalse);
    });

    test('an adapter that rejects ATSP0 does not connect', () async {
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [_canEcm()],
        faults: const AdapterFaults(forcedReplies: {'ATSP0': '?'}),
      );
      expect(await _clientFor(transport).connect(), isFalse);
    });
  });

  group('cached state must follow the adapter, not the intent', () {
    test('a refused ATSH does not update the cached header', () async {
      // An ELM327 refuses `ATSH 7E0` outright on any bus that is not 11-bit
      // CAN. Recording the header anyway meant the client believed `7E0` was
      // selected, so the next `sendOnHeader('7E0', …)` skipped the switch as
      // redundant and the query went out on whatever the adapter really had.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [_canEcm()],
        faults: const AdapterFaults(forcedReplies: {'ATSH7E0': '?'}),
      );
      final client = _clientFor(transport);
      // ATSH is not a critical step, so the handshake still completes — which
      // is why the cache being wrong is invisible without this test.
      expect(await client.connect(), isTrue);

      await expectLater(
        client.sendOnHeader('7E0', '010C'),
        throwsA(isA<TransportException>()),
        reason: 'the switch was refused, so the query must not be sent at all',
      );
    });
  });

  group('battery voltage is a measurement, not a string', () {
    test('an implausible voltage is not reported as a reading', () async {
      // A corrupt or clone reply of `99.9V` currently renders as a healthy
      // green 99.9 V, because validation is purely syntactic and the UI treats
      // anything at or above 11.8 as good.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [_canEcm()],
        faults: const AdapterFaults(voltageText: '99.9V'),
      );
      final client = _clientFor(transport);
      expect(await client.connect(), isTrue);
      expect(client.batteryVoltage, isNull);
    });

    test('a plausible voltage is kept', () async {
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [_canEcm()],
        faults: const AdapterFaults(voltageText: '13.8V'),
      );
      final client = _clientFor(transport);
      expect(await client.connect(), isTrue);
      expect(client.batteryVoltage, closeTo(13.8, 0.001));
    });

    test('a 24 V commercial vehicle is still plausible', () async {
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [_canEcm()],
        faults: const AdapterFaults(voltageText: '27.4V'),
      );
      final client = _clientFor(transport);
      expect(await client.connect(), isTrue);
      expect(client.batteryVoltage, closeTo(27.4, 0.001));
    });
  });
}
