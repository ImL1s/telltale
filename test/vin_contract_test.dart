/// Mode 09 PID 02 is framed differently on legacy buses and on CAN, and the
/// difference is structural rather than cosmetic.
///
/// Datasheet p.43 gives both, deliberately using the same vehicle so the two
/// can be compared:
///
///   legacy — the envelope `49 02 <seq>` repeats on **every** line and the
///            third byte is a sequence number;
///   CAN    — the envelope `49 02 01` appears **once** at the start of the
///            reassembled message and the `01` is a data-item count.
///
/// Applying the CAN rule to legacy bytes strips three bytes once and keeps
/// every later `49 02 <seq>` inside the payload. `0x49` is ASCII `I`, which
/// passes a printable-character filter, so the result is a longer string that
/// still looks like a VIN. Filtering corruption out rather than rejecting it
/// manufactures an identity.
///
/// Fixtures below are the datasheet's own printed lines, pasted rather than
/// generated, so the parser is tested against what an adapter prints.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/dtc/dtc.dart';
import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/polling_engine.dart';

import 'support/fake_elm327.dart';

/// Datasheet p.43, "one example of a response that might be obtained from a
/// J1850 vehicle". Five lines, sequence 01–05, four data bytes each; the three
/// leading `00`s are J1979 filler.
const _legacyVinLines = [
  '49 02 01 00 00 00 31',
  '49 02 02 44 34 47 50',
  '49 02 03 30 30 52 35',
  '49 02 04 35 42 31 32',
  '49 02 05 33 34 35 36',
];

/// Datasheet p.43, the same vehicle over 11-bit CAN with `ATH0` and `CAF1`.
/// `014` is the ISO-TP total length: 0x14 = 20 = 6 + 7 + 7.
const _canVinLines = [
  '014',
  '0: 49 02 01 31 44 34',
  '1: 47 50 30 30 52 35 35',
  '2: 42 31 32 33 34 35 36',
];

/// The VIN both examples decode to, stated by the datasheet.
const _datasheetVin = '1D4GP00R55B123456';

FakeEcu _ecuPrinting(Map<String, List<String>> lines, {required String id}) =>
    FakeEcu(
      name: 'ECM',
      requestId: id,
      responseId: id,
      responses: {
        '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
      },
      literalResponses: lines,
    );

/// The datasheet prints its worked examples with `ATH0`. The app asks for
/// headers before any global request — a reply it cannot attribute cannot
/// support a whole-vehicle statement — so the fixtures are given the header a
/// real adapter would print under `ATH1`, with the payload bytes untouched.
///
/// The ISO-TP PCI bytes replace the `014` length line and the `N:` prefixes,
/// which is what the datasheet shows on p.44 for the headers-on case.
List<String> _withHeader(String id, List<String> lines) => [
      for (final line in lines)
        if (!RegExp(r'^[0-9A-F]{3}$').hasMatch(line.trim()))
          '$id ${line.replaceFirst(RegExp(r'^[0-9A-F]:\s*'), _pciFor(line))}',
    ];

/// Derives the ISO-TP PCI for a line that carried an `N:` segment prefix.
String _pciFor(String line) {
  final match = RegExp(r'^([0-9A-F]):').firstMatch(line.trim());
  if (match == null) return '';
  final seq = int.parse(match.group(1)!, radix: 16);
  // 0x10 | high nibble of the total length, then its low byte; then 0x2N.
  return seq == 0 ? '10 14 ' : '2${seq.toRadixString(16).toUpperCase()} ';
}

/// Builds an engine over a fixture, choosing the adapter to match the fixture.
///
/// A fixture whose lines carry no header is only coherent on an adapter that
/// will not print them, so the legacy protocols get [refuseHeaders]. That is
/// not a convenience: an adapter which answers `OK` to `ATH1` and then prints
/// nothing is the lying clone, and the app refuses its replies outright. The
/// two used to be indistinguishable, so these fixtures quietly modelled the
/// clone while their comments described the refusing adapter.
Future<PollingEngine> _engine(BusProtocol protocol, Map<String, List<String>> lines) async {
  final headerless = !protocol.isCan;
  final transport = FakeElm327(
    protocol: protocol,
    faults: AdapterFaults(refuseHeaders: headerless),
    ecus: [_ecuPrinting(lines, id: protocol.engineHeader)],
  );
  final client = Elm327Client(transport);
  expect(await client.connect(), isTrue);
  return PollingEngine(client);
}

void main() {
  group('VIN framing follows the bus', () {
    test('the datasheet J1850 five-line response decodes correctly', () async {
      final engine = await _engine(
        BusProtocol.j1850vpw,
        // Not headered, because this adapter refuses `ATH1` — `sendGlobal`
        // does ask on legacy buses, and tolerates a refusal there. The lines
        // are exactly as the datasheet prints them.
        {'0902': _legacyVinLines},
      );
      expect(await engine.readVin(), _datasheetVin);
    });

    test('the datasheet CAN multi-frame response decodes correctly', () async {
      final engine = await _engine(
        BusProtocol.can11,
        {'0902': _withHeader('7E8', _canVinLines)},
      );
      expect(await engine.readVin(), _datasheetVin);
    });

    test('legacy lines are never read with the CAN rule', () async {
      // The specific corruption: keeping the later `49 02 <seq>` envelopes and
      // filtering to printable characters yields something like
      // `1D4GPI 00R5I 5B12I 3456` — longer than 17, with `I` where an envelope
      // byte was. Whatever comes out, it must not be that.
      final engine = await _engine(
        BusProtocol.j1850vpw,
        // Not headered, because this adapter refuses `ATH1` — `sendGlobal`
        // does ask on legacy buses, and tolerates a refusal there. The lines
        // are exactly as the datasheet prints them.
        {'0902': _legacyVinLines},
      );
      final vin = await engine.readVin();
      expect(vin, isNot(anyOf(isNull, hasLength(isNot(17)))));
      expect(vin, isNot(contains('I')));
    });
  });

  group('an unattributed VIN needs something else to bound it', () {
    test('R8-12: two controllers splitting the sequence cannot be spliced',
        () async {
      // GPT-5.6 Pro, and a hole left by round 7's own fix. Grouping by
      // `sourceId ?? ''` restores the identity when headers are on; when
      // `ATH1` is refused every frame carries the same empty source, they all
      // land in one group, and complementary fragments are spliced.
      //
      // A supplies segments 1-2, B supplies 3-5, the completeness check sees a
      // contiguous 1..5, and out comes a syntactically perfect VIN that
      // neither module gave. The duplicate rule catches the easy version of
      // this — two controllers both answering 1-5 — and cannot catch a
      // disjoint split.
      //
      // What bounds it instead is the handshake: `0100` is functional too, and
      // on a legacy bus each reply is one complete line, so the number of
      // lines it drew counts responders without needing headers at all.
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        faults: const AdapterFaults(refuseHeaders: true),
        ecus: [
          FakeEcu(
            name: 'A',
            requestId: '686AF1',
            responseId: '486B10',
            responses: {'0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13]},
            literalResponses: {
              '0902': [
                '49 02 01 00 00 00 31',
                '49 02 02 48 47 42 48',
                '49 02 03 34 31 4A 58',
                '49 02 04 4D 4E 31 30',
                '49 02 05 39 31 38 36',
              ],
            },
          ),
          FakeEcu(
            name: 'B',
            requestId: '686AF1',
            responseId: '486B18',
            // Answers the census, so the app knows two modules are out there.
            responses: {'0100': [0x41, 0x00, 0x80, 0x00, 0x00, 0x00]},
          ),
        ],
      );
      final client = Elm327Client(transport);
      expect(await client.connect(), isTrue);
      expect(client.responderCount, 2,
          reason: 'sanity: the handshake saw two lines, so two modules answer');

      expect(await PollingEngine(client).readVin(), isNull,
          reason: 'nothing here says these five lines came from one module, '
              'and 1HGBH41JXMN109186 belonging to neither is worse than no '
              'VIN at all');
      await client.dispose();
    });
  });

  group('a VIN is 17 legal characters or it is nothing', () {
    test('a truncated reply is rejected, not padded out', () async {
      // Codex C-12's trigger: `49 02 01 31 48 47 43 4D` currently renders as
      // the five-character "VIN" 1HGCM.
      final engine = await _engine(
        BusProtocol.can11,
        // Headered, so this is refused for being eight bytes rather than for
        // being unattributable — a rejection for the wrong reason proves
        // nothing about the rule under test.
        {'0902': ['7E8 08 49 02 01 31 48 47 43 4D']},
      );
      expect(await engine.readVin(), isNull);
    });

    test('a reply to the wrong service is rejected', () async {
      final engine = await _engine(
        BusProtocol.can11,
        {'0902': _withHeader('7E8', ['014', '0: 49 04 01 31 44 34',
                 '1: 47 50 30 30 52 35 35', '2: 42 31 32 33 34 35 36'])},
      );
      expect(await engine.readVin(), isNull);
    });

    test('letters a VIN may not contain are rejected, not filtered out',
        () async {
      // I, O and Q are excluded from the VIN alphabet precisely because they
      // are confusable with 1 and 0. A corrupt byte landing on one of them
      // must fail the read rather than be quietly deleted to leave a shorter,
      // clean-looking string.
      final engine = await _engine(
        BusProtocol.can11,
        // 49 02 01 then 'IOQ' + 14 more characters.
        {'0902': _withHeader('7E8', ['014',
          '0: 49 02 01 49 4F 51', '1: 34 47 50 30 30 52 35',
          '2: 35 42 31 32 33 34 00'])},
      );
      expect(await engine.readVin(), isNull);
    });

    test('a missing legacy line is rejected rather than silently shortened',
        () async {
      final lines = [..._legacyVinLines]..removeAt(2); // drop sequence 03
      final engine = await _engine(BusProtocol.j1850vpw, {'0902': lines});
      expect(await engine.readVin(), isNull);
    });
  });

  group('two controllers, two identities', () {
    test('a conflict makes the vehicle unknown, not first-responder-wins',
        () async {
      // A replaced or misconfigured module carrying a different VIN is exactly
      // when identity must become unknown. `readVin` read `response.bytes`,
      // which is the first frame, so bus ordering chose which car the user was
      // told they were sitting in.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {'0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13]},
            literalResponses: {
              '0902': [
                ..._withHeader('7E8', _canVinLines),
                // A second controller, one character different.
                '7E9 10 14 49 02 01 31 44 34',
                '7E9 21 47 50 30 30 52 35 35',
                '7E9 22 42 31 32 33 34 35 37',
              ],
            },
          ),
        ],
      );
      final client = Elm327Client(transport);
      expect(await client.connect(), isTrue);
      final engine = PollingEngine(client);

      await expectLater(
        engine.readVin(),
        throwsA(isA<VinIdentityConflictException>()),
        reason: 'two valid but different VINs is a conflict to report, not a '
            'race to resolve',
      );
    });

    test('the same VIN from two controllers is not a conflict', () async {
      // Agreement is ordinary — several modules store the VIN. Only
      // disagreement is a problem.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {'0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13]},
            literalResponses: {
              '0902': [
                ..._withHeader('7E8', _canVinLines),
                '7E9 10 14 49 02 01 31 44 34',
                '7E9 21 47 50 30 30 52 35 35',
                '7E9 22 42 31 32 33 34 35 36',
              ],
            },
          ),
        ],
      );
      final client = Elm327Client(transport);
      expect(await client.connect(), isTrue);
      expect(await PollingEngine(client).readVin(), _datasheetVin);
    });
  });
}
