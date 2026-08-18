/// Addressing follows the protocol the adapter actually settled on.
///
/// The app used to send `ATSH 7E0` unconditionally after detection. Three hex
/// digits is the 11-bit CAN form; J1850, ISO 9141-2 and ISO 14230-4 take three
/// bytes and 29-bit CAN takes four. On those buses the command either fails or
/// installs nonsense, and either way it discards the addressing `ATSP0` had
/// just worked out — so the vehicle paired and then answered nothing.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/addressing.dart';
import 'package:torque_obd/obd/dtc/dtc.dart';
import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/pid/pid.dart';
import 'package:torque_obd/obd/polling_engine.dart';
import 'package:torque_obd/obd/telemetry.dart';

import 'support/fake_elm327.dart';

const _coolant = Pid(
  name: 'Coolant',
  shortName: 'COOLANT',
  modeAndPid: '0105',
  equation: 'A-40',
  minValue: -40,
  maxValue: 215,
  units: '°C',
);

/// A PID the user pointed at a transmission controller using an 11-bit address.
const _transOnCan11Header = Pid(
  name: 'Trans',
  shortName: 'TRANS',
  modeAndPid: '221E1C',
  equation: 'A',
  minValue: 0,
  maxValue: 255,
  units: '°C',
  header: '7E1',
  isCustom: true,
);

Map<String, List<int>> _standardReplies() => {
      '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
      '010C': [0x41, 0x0C, 0x1A, 0xF8],
      '010D': [0x41, 0x0D, 0x3C],
      '010B': [0x41, 0x0B, 0x63],
      '010F': [0x41, 0x0F, 0x46],
      '0110': [0x41, 0x10, 0x07, 0xD0],
      '015E': [0x41, 0x5E, 0x00, 0x64], // ECU fuel rate, 5.0 L/h
      '0105': [0x41, 0x05, 0x82],
    };

Future<(FakeElm327, TelemetrySnapshot)> _poll(
  BusProtocol protocol,
  List<Pid> pids,
) async {
  final transport = FakeElm327(
    protocol: protocol,
    ecus: [
      FakeEcu(
        name: 'ECM',
        requestId: protocol.engineHeader,
        responseId: protocol.engineHeader,
        responses: _standardReplies(),
      ),
    ],
  );
  final client = Elm327Client(
    transport,
    commandTimeout: const Duration(milliseconds: 120),
  );
  expect(await client.connect(), isTrue);
  final engine = PollingEngine(client)..setActivePids(pids);
  engine.start();
  // Waited on the outcome, not on the clock.
  //
  // A fixed 300 ms passed alone and failed inside a full run whenever the
  // machine was busy — the same flake this project has already fixed once, in
  // `round5_triggers_test.dart`, and for the same reason. Every PID here ends
  // with either a reading or a fault; that is the condition to wait for.
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  bool decided() => pids.every((pid) =>
      engine.current.readings.containsKey(pid.id) ||
      engine.current.faults.containsKey(pid.id));
  while (!decided() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  await engine.stop();
  final snapshot = engine.current;
  await engine.dispose();
  return (transport, snapshot);
}

void main() {
  _descriptionFallback();
  _functionalAddressingTests();
  group('protocol number to addressing', () {
    test('R8-8: the two J1850 sub-protocols are told apart', () {
      // `ATDPN` answers 1 for PWM and 2 for VPW. The app used to collapse both
      // into one family and then refuse to restore a displaced header because
      // "the family covers both and cannot choose" — refusing on the strength
      // of information it had been given and discarded one function earlier.
      //
      // The addresses are still absent, and for a reason about evidence: the
      // datasheet gives J1850 no default request header, and a plausible
      // secondary claim is what round 7's F-2 was about. But each is now
      // answerable on its own.
      expect(BusAddressing.forProtocolNumber('1').family,
          ObdBusFamily.j1850Pwm);
      expect(BusAddressing.forProtocolNumber('2').family,
          ObdBusFamily.j1850Vpw);
      expect(BusAddressing.forProtocolNumber('A1').family,
          ObdBusFamily.j1850Pwm,
          reason: 'and the automatic-search prefix does not hide it');
      expect(BusAddressing.forProtocolNumber('1').headerHexDigits, 6);
    });

    test('maps every documented protocol to its header width', () {
      // Datasheet p.11 lists exactly three ATSH forms.
      //
      // Protocol `A` is J1939. Stripping the automatic-search prefix without a
      // lookahead ate the protocol itself, so it came out as `unknown` — no
      // functional header, no header width, every "global" request silently
      // physical. That was the bug; recognising `A` is the fix and stays.
      //
      // Calling it `can29` was the *next* defect, asserted here for a round.
      // 29-bit CAN is the physical layer they share and the only thing they
      // share: J1939 is PGN-addressed with its own application layer, so
      // ISO 15765-4 addressing, ISO-TP reassembly and the J1979 DTC shape all
      // apply to it wrongly.
      expect(BusAddressing.forProtocolNumber('A').family, ObdBusFamily.j1939);
      expect(BusAddressing.forProtocolNumber('A').headerHexDigits, 8,
          reason: 'it really is 29-bit; that was never the mistake');
      expect(BusAddressing.forProtocolNumber('AA').family, ObdBusFamily.j1939);
      expect(BusAddressing.forProtocolNumber('A').supportsObd2, isFalse,
          reason: 'determined, and not a bus this app reads — which is a '
              'different answer from "not determined yet"');
      expect(BusAddressing.forProtocolNumber('A0').supportsObd2, isFalse,
          reason: 'undetermined is also not usable, for its own reason');
      expect(BusAddressing.forProtocolNumber('6').supportsObd2, isTrue);
      // The user CAN protocols, which this file used to resolve to 11-bit
      // ISO 15765-4 and assert as such — Codex's H-01, and the assertion was
      // the reason nobody looked again.
      //
      // `B` and `C` are two configurable slots, not protocol identities. PP 2C
      // and PP 2E choose the transmit identifier width (b7) *and* the data
      // format (b2 b1 b0: none / ISO 15765-4 / SAE J1939), and both ship with
      // the format bits clear. A factory-default protocol B is CAN traffic
      // with no application layer at all, and the app was running the J1979
      // decoder over it.
      for (final userCan in ['B', 'C']) {
        expect(BusAddressing.forProtocolNumber(userCan).family,
            ObdBusFamily.unknown,
            reason: '$userCan without its options byte says nothing about '
                'framing, and a guess here becomes a fault code');
        expect(BusAddressing.forProtocolNumber(userCan).supportsObd2, isFalse,
            reason: 'and unknown must not be read as usable');
        // The factory defaults, which are the case that matters: E0 and 80
        // both select data format `000`.
        expect(
            BusAddressing.forProtocolNumber(userCan, userCanOptions: 0xE0)
                .family,
            ObdBusFamily.unknown,
            reason: 'no formatting is not an OBD-II bus');
        // Configured for ISO 15765-4, which is when it becomes one. b7 picks
        // the width, and it is the whole reason the width cannot be assumed.
        expect(
            BusAddressing.forProtocolNumber(userCan, userCanOptions: 0x81)
                .family,
            ObdBusFamily.can11,
            reason: 'b7 set is 11-bit');
        expect(
            BusAddressing.forProtocolNumber(userCan, userCanOptions: 0x81)
                .headerHexDigits,
            3);
        expect(
            BusAddressing.forProtocolNumber(userCan, userCanOptions: 0x01)
                .family,
            ObdBusFamily.can29,
            reason: 'b7 clear is 29-bit — the case the old contract could not '
                'express, and the one that transmits on the wrong identifier');
        expect(
            BusAddressing.forProtocolNumber(userCan, userCanOptions: 0x01)
                .headerHexDigits,
            8);
        expect(
            BusAddressing.forProtocolNumber(userCan, userCanOptions: 0x82)
                .family,
            ObdBusFamily.j1939,
            reason: 'option byte 42/82 makes it J1939, which this app refuses '
                '— and used to decode with the J1979 count byte');
      }
      expect(BusAddressing.forProtocolNumber('A0').family, ObdBusFamily.unknown);

      expect(BusAddressing.forProtocolNumber('A1').headerHexDigits, 6); // J1850 PWM
      expect(BusAddressing.forProtocolNumber('A2').headerHexDigits, 6); // J1850 VPW
      expect(BusAddressing.forProtocolNumber('A3').headerHexDigits, 6); // ISO 9141-2
      expect(BusAddressing.forProtocolNumber('A5').headerHexDigits, 6); // KWP fast
      expect(BusAddressing.forProtocolNumber('A6').headerHexDigits, 3); // CAN 11/500
      expect(BusAddressing.forProtocolNumber('A7').headerHexDigits, 8); // CAN 29/500
      expect(BusAddressing.forProtocolNumber('A8').headerHexDigits, 3); // CAN 11/250
      expect(BusAddressing.forProtocolNumber('A9').headerHexDigits, 8); // CAN 29/250
    });

    test('R19-codex 05: an identifier is checked at its own width', () {
      // Codex round 19. The integration test for this accepted any exception,
      // and the no-census branch threw first — so removing the range check
      // changed nothing it could see. The bounds are the contract, so they are
      // asserted directly.
      expect(BusAddressing.isLegalCanId('7E8'), isTrue);
      expect(BusAddressing.isLegalCanId('7FF'), isTrue,
          reason: 'the largest 11-bit identifier there is');
      expect(BusAddressing.isLegalCanId('800'), isFalse,
          reason: 'three digits, and one past the end');
      expect(BusAddressing.isLegalCanId('18DAF110'), isTrue);
      expect(BusAddressing.isLegalCanId('1FFFFFFF'), isTrue,
          reason: 'the largest 29-bit identifier there is');
      expect(BusAddressing.isLegalCanId('20000000'), isFalse);
      expect(BusAddressing.isLegalCanId('43020715'), isFalse,
          reason: 'the payload that used to be read as a controller');
      expect(BusAddressing.isLegalCanId('7E80'), isFalse,
          reason: 'no CAN identifier has four hex digits');
    });

    test('R19-codex 06: a slot told to accept both widths accepts both', () {
      // `A1` is 11-bit transmit, both widths on receive, ISO 15765-4. The only
      // test for it asserted that an *illegal* eight-digit line was rejected,
      // which stays true if either consumer regresses to the transmit width.
      final both = BusAddressing.forProtocolNumber('B', userCanOptions: 0xA1);
      expect(both.family, ObdBusFamily.can11,
          reason: 'b7 set is 11-bit transmit');
      expect(both.acceptedReceiveWidths, {3, 8},
          reason: 'and b5 set means replies may come on either');

      // The reciprocal: 29-bit transmit, both widths on receive.
      final reciprocal =
          BusAddressing.forProtocolNumber('C', userCanOptions: 0x21);
      expect(reciprocal.family, ObdBusFamily.can29);
      expect(reciprocal.acceptedReceiveWidths, {3, 8});

      // Bit 5 clear: one width, its own.
      final single = BusAddressing.forProtocolNumber('B', userCanOptions: 0x81);
      expect(single.acceptedReceiveWidths, {3});
      expect(BusAddressing.forProtocolNumber('6').acceptedReceiveWidths, {3});
      expect(BusAddressing.forProtocolNumber('7').acceptedReceiveWidths, {8});
      expect(BusAddressing.forProtocolNumber('3').acceptedReceiveWidths, isEmpty,
          reason: 'a legacy bus has no CAN identifier width at all');
    });

    test('an undecided protocol is unknown rather than guessed', () {
      // `ATSP0` only arms the search; until the first OBD request the adapter
      // reports `A0`, and reading that as protocol 0 is how a CAN car got its
      // fault codes decoded with legacy framing.
      expect(BusAddressing.forProtocolNumber('A0').isKnown, isFalse);
      expect(BusAddressing.forProtocolNumber('').isKnown, isFalse);
    });

    test('the stored default is only an instruction on 11-bit CAN', () {
      expect(BusAddressing.forProtocolNumber('A6').shouldTransmit('7E0'), isTrue);
      expect(BusAddressing.forProtocolNumber('A3').shouldTransmit('7E0'), isFalse);
      expect(BusAddressing.forProtocolNumber('A7').shouldTransmit('7E0'), isFalse);
    });
  });

  group('a legacy vehicle', () {
    test('never receives ATSH 7E0 during the handshake', () async {
      final (transport, _) = await _poll(BusProtocol.iso9141, [_coolant]);
      expect(
        transport.commandLog.where((c) => c.startsWith('ATSH')),
        isEmpty,
        reason: 'three hex digits is not a header on ISO 9141-2',
      );
    });

    test('reads a PID, which it could not do before', () async {
      // The whole point. Previously `ATSH 7E0` was refused, `sendOnHeader`
      // threw, and the poll loop yielded forever: a car that paired and then
      // showed nothing.
      final (_, snapshot) = await _poll(BusProtocol.iso9141, [_coolant]);
      expect(snapshot.readings[_coolant.id]?.value, closeTo(90, 0.001));
    });

    test('so does a KWP2000 vehicle', () async {
      final (_, snapshot) = await _poll(BusProtocol.kwp2000Fast, [_coolant]);
      expect(snapshot.readings[_coolant.id]?.value, closeTo(90, 0.001));
    });

    test('and a 29-bit CAN vehicle', () async {
      final (transport, snapshot) = await _poll(BusProtocol.can29, [_coolant]);
      expect(transport.commandLog.where((c) => c == 'ATSH7E0'), isEmpty);
      expect(snapshot.readings[_coolant.id]?.value, closeTo(90, 0.001));
    });
  });

  group('an 11-bit CAN vehicle', () {
    test('still selects the engine address, where it means something', () async {
      final (transport, snapshot) = await _poll(BusProtocol.can11, [_coolant]);
      expect(transport.commandLog, contains('ATSH7E0'));
      expect(snapshot.readings[_coolant.id]?.value, closeTo(90, 0.001));
    });
  });

  group('a custom header that cannot exist on the detected bus', () {
    test('faults the PID instead of being transmitted', () async {
      // A user's 11-bit transmission PID on a legacy car. Polling it anyway
      // would answer from whichever controller the adapter was addressing, and
      // that reply is indistinguishable from the right one.
      final (transport, snapshot) =
          await _poll(BusProtocol.iso9141, [_transOnCan11Header]);
      expect(transport.commandLog.where((c) => c.startsWith('ATSH')), isEmpty);
      expect(snapshot.readings[_transOnCan11Header.id], isNull);
      // Its own fault kind, not `unsupported`.
      //
      // `unsupported` is a statement about the *car* — the vehicle's own
      // support mask says the sensor is not there. This is a statement about
      // the *definition*: a three-digit CAN header on a six-digit legacy bus.
      // Wearing the same label sent people looking at their vehicle for a
      // problem sitting in a field they can edit, and the edit takes ten
      // seconds once they know that is what it is.
      expect(snapshot.faults[_transOnCan11Header.id],
          PidFault.headerNotOnThisBus);
    });
  });
}

/// Global requests must reach every emissions controller, not just the engine.
void _functionalAddressingTests() {
  FakeElm327 twoEcuCar({Map<String, List<int>> ecmExtra = const {}}) =>
      FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              ..._standardReplies(),
              '03': [0x43, 0x00], // engine is clean
              '04': [0x44],
              ...ecmExtra,
            },
          ),
          FakeEcu(
            name: 'TCM',
            requestId: '7E1',
            responseId: '7E9',
            responses: {
              '03': [0x43, 0x01, 0x07, 0x15], // P0715, input speed sensor
              '04': [0x44],
              '221E1C': [0x62, 0x1E, 0x1C, 0x5A],
            },
          ),
        ],
      );

  Future<PollingEngine> connect(FakeElm327 transport) async {
    final client = Elm327Client(
      transport,
      commandTimeout: const Duration(milliseconds: 200),
    );
    expect(await client.connect(), isTrue);
    return PollingEngine(client);
  }

  group('a fault in a controller that is not the engine', () {
    test('is found, where a physical request to 7E0 would miss it', () async {
      // The engine reports `43 00` — no codes. Asking only the engine, which
      // is what a physical `7E0` request does, produced a green "no faults"
      // screen on a car with a transmission fault.
      final engine = await connect(twoEcuCar());
      final codes = await engine.readDtcs(DtcKind.stored);
      expect(codes.map((d) => d.code).toList(), equals(['P0715']));
    });

    test('the request goes out functionally addressed', () async {
      final transport = twoEcuCar();
      final engine = await connect(transport);
      await engine.readDtcs(DtcKind.stored);
      expect(transport.commandLog, contains('ATSH7DF'));
      expect(transport.commandLog, contains('ATH1'));
    });

    test('a custom PID polled just before does not capture the scan', () async {
      // The header a custom transmission PID selected used to stay active, so
      // the following Mode 03 went to that controller alone.
      final transport = twoEcuCar();
      final engine = await connect(transport);
      // Simulate the poll loop having just addressed 7E1. Reusing the engine's
      // own client matters: a second client on the same transport would
      // subscribe to the byte stream twice.
      await engine.client.sendOnHeader('7E1', '221E1C');
      transport.commandLog.clear();

      final codes = await engine.readDtcs(DtcKind.stored);
      expect(transport.commandLog, contains('ATSH7DF'));
      expect(codes.map((d) => d.code).toList(), equals(['P0715']));
    });
  });

  group('clearing faults', () {
    test('succeeds only when every controller that answered acknowledged',
        () async {
      final engine = await connect(twoEcuCar());
      expect((await engine.clearDtcs()).isSuccess, isTrue);
    });

    test('fails when one controller refuses', () async {
      // Reporting a partial clear as success leaves faults in a module the
      // driver now believes is clean.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._standardReplies(), '04': [0x44]},
          ),
          FakeEcu(
            name: 'TCM',
            requestId: '7E1',
            responseId: '7E9',
            responses: {
              '04': [0x7F, 0x04, 0x22], // conditions not correct
            },
          ),
        ],
      );
      final engine = await connect(transport);
      // Still not a success — and now it says why.
      //
      // `7F 04 22` is conditionsNotCorrect, and for a clear that almost always
      // means the engine is running: most controllers will not erase fault
      // memory while it turns. Reporting 清除失敗，ECU 未接受指令 told somebody
      // standing at a car nothing they could act on, when the remedy is a
      // ten-second one they cannot guess.
      await expectLater(
        engine.clearDtcs(),
        throwsA(isA<DtcReadException>()
            .having((e) => e.message, 'message', contains('7E9'))
            .having((e) => e.message, 'message', contains('引擎'))),
      );
    });
  });
}

void _descriptionFallback() {
  group('an adapter that will not name its protocol is not a dead adapter', () {
    test('the description settles the bus when the number is missing', () {
      // `ATDPN` is a non-critical handshake step, so a clone that answers it
      // with `?` connects and is then useless: undetermined refuses every
      // gauge, every fault-code read and the VIN, and reconnecting produces
      // the same answer because the adapter is consistent. That is a working
      // adapter and a working car, permanently unusable.
      expect(
        BusAddressing.forProtocolDescription('AUTO, ISO 15765-4 (CAN 11/500)')
            .family,
        ObdBusFamily.can11,
      );
      expect(
        BusAddressing.forProtocolDescription('ISO 15765-4 (CAN 29/500)').family,
        ObdBusFamily.can29,
      );
      expect(
        BusAddressing.forProtocolDescription('ISO 9141-2').family,
        ObdBusFamily.iso9141,
      );
      expect(
        BusAddressing.forProtocolDescription('ISO 14230-4 (KWP FAST)').family,
        ObdBusFamily.kwp2000,
      );
      expect(
        BusAddressing.forProtocolDescription('SAE J1850 VPW').family,
        ObdBusFamily.j1850Vpw,
      );
      expect(
        BusAddressing.forProtocolDescription('SAE J1939 (CAN 29/250)').family,
        ObdBusFamily.j1939,
      );
    });

    test('R28-N4: a known number is never second-guessed by the description',
        () async {
      // Cursor round 28, and a test about a *composition* rather than a rule.
      //
      // Both halves were already covered: `forProtocolNumber` returns unknown
      // for `B`, and `forProtocolDescription` maps the ISO 15765-4 sentence to
      // 11-bit CAN. What nothing pinned was the getter that puts them
      // together — so deleting its gate and falling back whenever the
      // addressing was unknown left the whole suite green.
      //
      // That deletion is a wrong-number defect of the worst kind. `B` is a
      // *user-defined* CAN protocol: the number arrives perfectly well, and
      // what is unknown is the framing, which lives in PP 2C / PP 2E. A
      // factory-default `B` (`PP 2C = E0`, format bits 000 — no framing at
      // all) whose `ATDP` sentence happens to read ISO 15765-4 would then be
      // handed to the J1979 decoder as ordinary 11-bit CAN, and raw unframed
      // bytes would come out as gauge readings.
      //
      // So the fixture is exactly that adapter: number `B`, an ISO 15765-4
      // description, and an `AT PPS` it will not answer.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        forceProtocolNumber: 'B',
        faults: const AdapterFaults(refusePpSummary: true),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: _standardReplies(),
          ),
        ],
      );
      final client = Elm327Client(transport);
      expect(await client.connect(), isTrue,
          reason: 'the adapter works; it is the framing that is unknown');

      expect(client.protocolNumber, contains('B'),
          reason: 'the fixture must actually report B, or this pins nothing');
      expect(client.protocolDescription, contains('ISO 15765-4'),
          reason: 'and the description must be the tempting one');

      expect(client.addressing.isKnown, isFalse,
          reason: 'PP 2C decides how a user CAN protocol is framed, and an '
              'adapter that will not print AT PPS has left that unknowable — '
              'the description answers a different question');
      await client.dispose();
    });

    test('a sentence it does not recognise stays unknown', () {
      // A closed whitelist, because guessing a bus is how a legacy reply gets
      // decoded with CAN framing and invents codes the car never set.
      for (final d in [
        '',
        '?',
        'SEARCHING...',
        'USER1 CAN (11 bit ID, 125 kbaud)',
        'ISO 15765-4',
      ]) {
        expect(BusAddressing.forProtocolDescription(d).isKnown, isFalse,
            reason: '「$d」 does not name a bus this app can decode');
      }
    });
  });
}
