/// Regression tests for the second review round.
///
/// Each case here is a path that produced a *plausible wrong answer* rather
/// than an error — the failure mode a diagnostic tool can least afford.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/obd/dtc/dtc.dart';
import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/transport/demo_transport.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_registry.dart';

Elm327Client _client() => Elm327Client(DemoTransport());

ObdResponse _parse(String wire) =>
    _client().parseFrameForTest(ascii.encode(wire.replaceAll('\n', '\r')));

Future<ProviderContainer> _container() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('protocol determination', () {
    test('the handshake probes the bus before reading the protocol', () {
      final commands = Elm327Client.initSequence.map((s) => s.command).toList();
      final probe = commands.indexOf('0100');
      final dp = commands.indexOf('ATDP');
      final dpn = commands.indexOf('ATDPN');

      // ATSP0 only arms the search; it does not run until a real OBD request.
      // Reading ATDP/ATDPN first reports "undecided" forever.
      expect(probe, greaterThan(commands.indexOf('ATSP0')));
      expect(dp, greaterThan(probe));
      expect(dpn, greaterThan(probe));
    });

    test('the probe is critical — it is the only proof a vehicle answered', () {
      final probe =
          Elm327Client.initSequence.firstWhere((s) => s.command == '0100');
      expect(probe.isCritical, isTrue);
    });

    test('an undecided protocol is refused, not guessed either way', () {
      // This test used to assert the opposite — "treat A0 as CAN, because that
      // is what every modern car uses". That guess reads an ISO 9141 car's
      // single stored code with CAN framing: `43 01 33 00 00 00 00` takes the
      // `01` as a count, starts two bytes late, reports P3300 and loses the
      // real P0133 — and both the count check and the padding check pass on
      // the way through. The trigger is ordinary: a clone that answers `?` to
      // ATDPN, or times out.
      //
      // The two questions also disagreed: `protocolHasCountByte('')` said CAN
      // while `protocolIsCan('')` said not CAN. Neither guess is safe.
      expect(DtcDecoder.protocolIsKnown('A0'), isFalse);
      expect(DtcDecoder.protocolIsKnown('0'), isFalse);
      expect(DtcDecoder.protocolIsKnown(''), isFalse);
      expect(DtcDecoder.protocolIsKnown('?'), isFalse);

      expect(DtcDecoder.protocolIsKnown('A6'), isTrue);
      expect(DtcDecoder.protocolIsKnown('3'), isTrue);

      // Batching still stays off until the bus is genuinely known to be CAN.
      expect(DtcDecoder.protocolIsCan('A0'), isFalse);
      expect(DtcDecoder.protocolIsCan('A6'), isTrue);
      expect(DtcDecoder.protocolIsCan('3'), isFalse);
    });
  });

  group('stream robustness', () {
    test('a stray NULL byte does not invalidate the line', () async {
      // The datasheet notes the ELM327 may insert NULLs and tells hosts to
      // discard them. With a whitelist parser an un-stripped 0x00 would make
      // the whole line fail and the gauge keep its previous number.
      final client = Elm327Client(DemoTransport());
      final withNull = <int>[
        ...ascii.encode('41 0C 1A'),
        0x00,
        ...ascii.encode(' F8'),
      ];
      expect(client.parseFrameForTest(withNull).bytes, [0x41, 0x0C, 0x1A, 0xF8]);
    });

    test('the length header of a multi-frame reply is still dropped', () {
      final response = _parse('014\n0: 49 02 01 31 44 34\n1: 47 50 30 30 52 35 35\n'
          '2: 42 31 32 33 34 35 36');
      expect(response.bytes.first, 0x49);
      expect(response.bytes.length, 20);
    });
  });

  group('diagnostic reads refuse to guess', () {
    late ProviderContainer container;
    late ObdSession session;

    setUp(() async {
      container = await _container();
      session = container.read(obdSessionProvider.notifier);
      await session.connectDemo();
    });

    tearDown(() async {
      await session.disconnect();
      container.dispose();
    });

    test('stored codes read back correctly through realistic framing', () async {
      final codes = await session.readDtcs(DtcKind.stored);
      expect(codes.map((c) => c.code), ['P0301', 'P0420', 'U0123']);
    });

    test('clearing requires the ECU acknowledgement', () async {
      expect((await session.clearDtcs()).isSuccess, isTrue);
      expect(await session.readDtcs(DtcKind.stored), isEmpty);
    });

    test('the VIN survives the multi-frame path', () async {
      expect(await session.readVin(), '1D4GP00R55B123456');
    });

    test('the protocol is known by the time the session is connected', () {
      // If this reads A0 the DTC decoder is guessing at the frame layout.
      expect(container.read(obdSessionProvider).protocol, isNotEmpty);
      expect(container.read(obdSessionProvider).protocol, isNot(contains('A0')));
    });
  });
}
