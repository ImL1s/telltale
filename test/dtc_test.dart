import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/addressing.dart';
import 'package:torque_obd/obd/dtc/dtc.dart';

void main() {
  group('single code decoding', () {
    test('P0301 — cylinder 1 misfire', () {
      final dtc = DtcDecoder.decodePair(0x03, 0x01, DtcKind.stored)!;
      expect(dtc.code, 'P0301');
      expect(dtc.category, DtcCategory.powertrain);
      expect(dtc.isManufacturerSpecific, isFalse);
      expect(dtc.description, contains('失火'));
    });

    test('P0420 — catalyst efficiency', () {
      expect(DtcDecoder.decodePair(0x04, 0x20, DtcKind.stored)!.code, 'P0420');
    });

    test('U0123 — network category', () {
      final dtc = DtcDecoder.decodePair(0xC1, 0x23, DtcKind.stored)!;
      expect(dtc.code, 'U0123');
      expect(dtc.category, DtcCategory.network);
    });

    test('C0035 — chassis category', () {
      final dtc = DtcDecoder.decodePair(0x40, 0x35, DtcKind.stored)!;
      expect(dtc.code, 'C0035');
      expect(dtc.category, DtcCategory.chassis);
    });

    test('B0001 — body category', () {
      final dtc = DtcDecoder.decodePair(0x80, 0x01, DtcKind.stored)!;
      expect(dtc.code, 'B0001');
      expect(dtc.category, DtcCategory.body);
    });

    test('hex digits above 9 render as A-F', () {
      expect(DtcDecoder.decodePair(0x01, 0xAF, DtcKind.stored)!.code, 'P01AF');
    });

    test('first digit 1 marks a manufacturer-specific code', () {
      final dtc = DtcDecoder.decodePair(0x13, 0x01, DtcKind.stored)!;
      expect(dtc.code, 'P1301');
      expect(dtc.isManufacturerSpecific, isTrue);
      // Generic descriptions must not be claimed for OEM ranges.
      expect(dtc.description, isNull);
    });

    test('first digit 3 is also manufacturer-specific', () {
      expect(DtcDecoder.decodePair(0x33, 0x01, DtcKind.stored)!.isManufacturerSpecific, isTrue);
    });

    test('0x0000 is padding, not a code', () {
      expect(DtcDecoder.decodePair(0x00, 0x00, DtcKind.stored), isNull);
    });
  });

  group('full response decoding', () {
    test('ISO 15765 reply with a count byte', () {
      // 43 02 <P0301> <P0420>
      final bytes = [0x43, 0x02, 0x03, 0x01, 0x04, 0x20];
      final codes = DtcDecoder.decodeResponse(bytes, DtcKind.stored);
      expect(codes.map((c) => c.code), ['P0301', 'P0420']);
    });

    test('legacy reply without a count byte', () {
      // ISO 9141 / KWP / J1850 go straight from the mode byte to the codes.
      final bytes = [0x43, 0x03, 0x01, 0x04, 0x20];
      final codes =
          DtcDecoder.decodeResponse(bytes, DtcKind.stored, hasCountByte: false);
      expect(codes.map((c) => c.code), contains('P0301'));
    });

    test('a legacy reply is not mangled by guessing at a count byte', () {
      // 43 01 43 01 96 is two real codes on a legacy bus. Treating the leading
      // 01 as "one code" starts two bytes late and reports a single C0301 the
      // car never set, losing both real faults.
      final bytes = [0x43, 0x01, 0x43, 0x01, 0x96];
      final codes =
          DtcDecoder.decodeResponse(bytes, DtcKind.stored, hasCountByte: false);
      expect(codes.map((c) => c.code), ['P0143', 'P0196']);
    });

    test('a CAN reply stops at the declared count and ignores frame padding', () {
      final bytes = [0x43, 0x02, 0x03, 0x01, 0x04, 0x20, 0x00, 0x00, 0x00, 0x00];
      final codes = DtcDecoder.decodeResponse(bytes, DtcKind.stored);
      expect(codes.map((c) => c.code), ['P0301', 'P0420']);
    });

    test('R9-cursor: an undetermined protocol fails closed', () {
      // The assertion guarding this is stripped from a release build, so the
      // default underneath it is what ships. It used to answer "yes, CAN" —
      // and the comment a few lines from it is about exactly what that costs:
      // an ISO 9141 reply read with CAN framing turns a real P0133 into a
      // P3300 the car never set.
      //
      // Production callers are refused earlier now; this is for the next
      // caller who is not.
      for (final undetermined in ['', '0', 'A0', 'zz']) {
        expect(DtcDecoder.protocolIsKnown(undetermined), isFalse,
            reason: undetermined);
        expect(DtcDecoder.protocolIsCan(undetermined), isFalse,
            reason: undetermined);
      }
    });

    test('protocol number decides whether a count byte is present', () {
      // The CAN set is `6`-`9`, and the membership test is a named set rather
      // than a range: narrowing to `6..9` to exclude J1939 once excluded the
      // user protocols too, and a Mode 03 reply `43 02 01 03 07 00` decoded
      // without its count byte pairs `(02,01)` and `(03,07)` into P0201 and
      // P0307 — two faults the vehicle never set, drawn with the same
      // confident red chip as a real one.
      //
      // `B` and `C` were then put *in* the set, which was the same error
      // pointing the other way and is Codex's H-01. They are configurable
      // slots: PP 2C and PP 2E choose the identifier width and the data
      // format, and both ship selecting *no* format. This decoder sees only
      // the letter, so it cannot answer — and answering anyway is what ran
      // J1979 over unframed CAN.
      //
      // `BusAddressing` does see the options byte and the production callers
      // ask it, so a genuinely configured ISO 15765-4 user protocol still
      // decodes. This API just stops claiming to know.
      //
      // `A` is J1939 and is not asked at all: `protocolIsKnown` refuses it
      // first, which the assertion inside `protocolHasCountByte` enforces.
      for (final can in ['6', 'A6', '7', '8', '9']) {
        expect(DtcDecoder.protocolHasCountByte(can), isTrue, reason: can);
      }
      for (final userCan in ['B', 'C', 'AB', 'AC']) {
        expect(DtcDecoder.protocolIsKnown(userCan), isFalse,
            reason: '$userCan needs its options byte, which is not in the '
                'letter');
        expect(DtcDecoder.protocolIsCan(userCan), isFalse, reason: userCan);
      }
      for (final legacy in ['1', '2', 'A3', '4', '5']) {
        expect(DtcDecoder.protocolHasCountByte(legacy), isFalse, reason: legacy);
      }
      // An unknown protocol is not answered at all — callers check
      // `protocolIsKnown` and refuse to decode. Assuming CAN here invented
      // fault codes on legacy cars whose ATDPN failed.
      expect(DtcDecoder.protocolIsKnown(''), isFalse);
      expect(DtcDecoder.protocolIsKnown('A0'), isFalse);

      // Protocol `A` is J1939, and this used to assert it was ordinary CAN —
      // a wrong contract, pinned by a test, which is how it survived.
      //
      // The normaliser must still recognise it: a naive `replaceFirst('A','')`
      // ate the protocol itself and left an empty string, which read as
      // undetermined, and `AA` is auto-detected J1939 and must reduce to `A`.
      // That part was right and stays.
      //
      // What was wrong is what came next. J1939 is 29-bit CAN electrically and
      // shares nothing else with ISO 15765-4: PGN addressing, its own
      // application layer, no J1979 mode bytes, no `43` DTC shape. Bus
      // identifier width is not an application protocol. A heavy-duty vehicle
      // normally fails the `0100` probe by itself, but a permissive bridge
      // lets the app carry on and frame every reply by rules that do not
      // apply.
      //
      // "Determined, and not a bus we can read" is a different state from
      // "not determined yet", and both were being answered with the same
      // silence.
      expect(BusAddressing.normaliseProtocolNumber('AA'), 'A',
          reason: 'the automatic-search prefix still comes off, and only it');
      expect(DtcDecoder.protocolIsKnown('A'), isFalse,
          reason: 'nothing here can decode a J1939 fault code');
      expect(DtcDecoder.protocolIsKnown('AA'), isFalse);
      expect(DtcDecoder.protocolIsCan('A'), isFalse,
          reason: 'and batching J1979 PIDs on it would mean nothing');
      // Asserted from the other side above: the letter alone is not a
      // protocol identity, and this API has no way to see PP 2C / PP 2E.
    });

    test('trailing zero padding is discarded', () {
      final bytes = [0x43, 0x01, 0x03, 0x01, 0x00, 0x00, 0x00, 0x00];
      final codes = DtcDecoder.decodeResponse(bytes, DtcKind.stored);
      expect(codes.map((c) => c.code), ['P0301']);
    });

    test('an empty stored-codes reply yields nothing', () {
      expect(DtcDecoder.decodeResponse([0x43, 0x00], DtcKind.stored), isEmpty);
    });

    test('pending codes use mode 07 and are tagged as such', () {
      final codes = DtcDecoder.decodeResponse([0x47, 0x01, 0x01, 0x71], DtcKind.pending);
      expect(codes.single.code, 'P0171');
      expect(codes.single.kind, DtcKind.pending);
    });

    test('permanent codes use mode 0A', () {
      final codes = DtcDecoder.decodeResponse([0x4A, 0x01, 0x04, 0x20], DtcKind.permanent);
      expect(codes.single.kind, DtcKind.permanent);
    });

    test('an empty payload yields nothing', () {
      expect(DtcDecoder.decodeResponse(const [], DtcKind.stored), isEmpty);
    });
  });

  group('encode round-trip', () {
    test('every category survives a round trip', () {
      for (final code in ['P0301', 'C0035', 'B0001', 'U0123', 'P01AF', 'P3FFF']) {
        final encoded = DtcDecoder.encode(code)!;
        final decoded = DtcDecoder.decodePair(encoded.$1, encoded.$2, DtcKind.stored)!;
        expect(decoded.code, code, reason: '$code should survive encode/decode');
      }
    });

    test('rejects malformed input', () {
      expect(DtcDecoder.encode('P030'), isNull);
      expect(DtcDecoder.encode('X0301'), isNull);
      expect(DtcDecoder.encode('P4301'), isNull); // first digit must be 0-3
    });
  });

  group('the descriptions say what the code actually means', () {
    test('P0411 is secondary air, P0441 is EVAP', () {
      // The most-reposted "commonest fault codes" table on the web has this
      // pair the wrong way round, and a subagent researching whether to import
      // a public dataset found it there while checking the datasets against
      // each other. Copying it sends somebody to check a fuel cap while an air
      // pump fails.
      //
      // Pinned because these two are one digit apart, both emissions, both
      // common — and because a wrong description is the one kind of error this
      // table can make that looks exactly like a right one.
      expect(DtcDecoder.genericDescriptions['P0411'], contains('二次空氣'));
      expect(DtcDecoder.genericDescriptions['P0411'], isNot(contains('蒸發')));
      expect(DtcDecoder.genericDescriptions['P0441'], contains('蒸發'));
      expect(DtcDecoder.genericDescriptions['P0441'], isNot(contains('二次空氣')));
    });

    test('a manufacturer-specific code is never given a generic description',
        () {
      // The table has no standing over the manufacturer ranges: they mean
      // whatever the manufacturer says. Kept as a rule rather than an accident
      // of which keys happen to be present.
      //
      // Both ranges, because `_decode` is `d1 == 1 || d1 == 3` and the first
      // version of this test only excluded `1`. A `P3xxx` entry would have
      // been accepted here and then been unreachable at runtime — the exact
      // dead-key failure the test below was written to catch, walking in
      // through the door this test left open. Found by a reviewer mutating the
      // table and watching the suite stay green.
      for (final code in DtcDecoder.genericDescriptions.keys) {
        expect(code[1], isNot(anyOf('1', '3')),
            reason: '$code is in a manufacturer-defined range, where a '
                'generic description is both wrong and unreachable');
      }
    });

    test('and every description is actually reachable through Dtc', () {
      // The rule the one above protects, asserted end to end rather than by
      // proxy. A key can be well-formed, non-manufacturer, and still never
      // surface if `description` disagrees about what counts as generic.
      for (final code in DtcDecoder.genericDescriptions.keys) {
        final decoded = Dtc(
          code: code,
          category: DtcCategory.powertrain,
          kind: DtcKind.stored,
          isManufacturerSpecific: code[1] == '1' || code[1] == '3',
        );
        expect(decoded.description, isNotNull,
            reason: '$code has a description that nothing can ever show');
      }
    });

    test('every description belongs to a decodable code', () {
      // A typo in a key is invisible: the entry simply never matches, and the
      // code falls back to its category label as though nothing were written
      // for it.
      for (final code in DtcDecoder.genericDescriptions.keys) {
        expect(DtcDecoder.encode(code), isNotNull,
            reason: '$code is not a well-formed DTC');
      }
    });
  });
}
