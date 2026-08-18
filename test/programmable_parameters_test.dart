/// `AT PPS`, and the one letter that decides what it means.
///
/// Codex's round-10 test-oracle audit: nothing in the suite would have failed
/// if `effective()` were changed back to "use the stored byte". Every fixture
/// printed each disabled parameter with its own factory value, so the two
/// readings agreed on every case that existed.
///
/// The cases below are the ones where they disagree, and one of them —
/// `2A:38 F` — is what the ELM327 emulator used for the hardware walkthrough
/// actually prints.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/obd/programmable_parameters.dart';

/// One line of a summary, in the documented `hh:vv S` shape.
String _pps(Map<int, String> entries) =>
    entries.entries.map((e) => '${e.key.toRadixString(16).toUpperCase().padLeft(2, '0')}:${e.value}').join('   ');

void main() {
  group('a disabled parameter is not in effect', () {
    test('R10-codex: a stored value that is switched off does not govern', () {
      // `N` is on and `F` is off — the datasheet's worked example, p.67: "You
      // can see that PP 01 now shows a value of 00, and it is enabled (oN),
      // while the others are all off."
      //
      // So `2C:81 F` means somebody once configured protocol B as 11-bit
      // ISO 15765-4 and then disabled the parameter. What governs is the
      // factory `E0`, whose format bits are `000` — no formatting at all.
      // Reading the stored byte instead turns unframed CAN into an OBD-II bus
      // and the J1979 decoder runs over it.
      final off = ProgrammableParameters.parse(_pps({0x2C: '81 F'}));
      expect(off.userCanOptions('B'), 0xE0,
          reason: 'disabled, so the factory default is what the adapter is '
              'actually doing');
      expect(UserCanFormat.of(off.userCanOptions('B')!), UserCanFormat.none);

      // The same byte, switched on, is a different vehicle.
      final on = ProgrammableParameters.parse(_pps({0x2C: '81 N'}));
      expect(on.userCanOptions('B'), 0x81);
      expect(UserCanFormat.of(on.userCanOptions('B')!), UserCanFormat.iso15765);
      expect(userCanIs11Bit(on.userCanOptions('B')!), isTrue);
    });

    test('R10-codex: `2A:38 F` is response pending *handled*', () {
      // The line a real adapter prints. Bit 2 is cleared in storage and the
      // parameter is off, so the factory `3C` — bit 2 set — is in effect and
      // the adapter does extend its own timeout.
      //
      // Reading the stored byte says the opposite. That direction is the safe
      // one (the app would re-ask a controller unnecessarily), which is
      // exactly why nothing would have caught it.
      final stock = ProgrammableParameters.parse(_pps({0x2A: '38 F'}));
      expect(stock.responsePendingHandled, isTrue);

      // Switched on, the cleared bit is real and the adapter does not wait.
      final configured = ProgrammableParameters.parse(_pps({0x2A: '38 N'}));
      expect(configured.responsePendingHandled, isFalse);
    });

    test('R10-codex 03: a truncated page does not complete itself', () {
      // Codex, round 10. `wasRead` meant "at least one entry parsed", and from
      // then on every *other* parameter reported its factory default. A
      // summary cut short before PP 2A therefore said response pending was
      // handled on an adapter whose 2A said the opposite — and the app then
      // declined the second Mode 03 that would have returned the fault.
      //
      // Absence is unknown. Only a parameter actually printed with `F` gets
      // its default.
      final partial = ProgrammableParameters.parse(_pps({0x00: 'FF F', 0x2C: '81 N'}));
      expect(partial.wasRead, isTrue, reason: 'sanity: something did parse');
      expect(partial.userCanOptions('B'), 0x81,
          reason: 'this one was present, and enabled');
      expect(partial.sawParameter(0x2A), isFalse);
      expect(partial.responsePendingHandled, isNull,
          reason: 'PP 2A was never printed, so nothing is known about it — and '
              'unknown must not become the factory default');
      expect(partial.userCanOptions('C'), isNull,
          reason: 'nor may PP 2E');
    });

    test('unread is unknown, and unknown is not a default', () {
      const unread = ProgrammableParameters.unread();
      expect(unread.wasRead, isFalse);
      expect(unread.responsePendingHandled, isNull,
          reason: 'an adapter that will not answer `AT PPS` has told us '
              'nothing about how it is configured');
      expect(unread.userCanOptions('B'), isNull);
      expect(unread.userCanOptions('C'), isNull);

      // A reply that is not a summary is not a summary.
      expect(ProgrammableParameters.parse('?').wasRead, isFalse);
      expect(ProgrammableParameters.parse('NO DATA').wasRead, isFalse);
    });

    test('protocol C reads its own parameter', () {
      final pps = ProgrammableParameters.parse(_pps({0x2C: '81 N', 0x2E: '01 N'}));
      expect(UserCanFormat.of(pps.userCanOptions('C')!), UserCanFormat.iso15765);
      expect(userCanIs11Bit(pps.userCanOptions('C')!), isFalse,
          reason: 'b7 clear is 29-bit, and B and C are configured separately');
      expect(pps.userCanOptions('6'), isNull,
          reason: 'only B and C have an options byte');
    });

    test('J1939 selected through a user slot is still J1939', () {
      final pps = ProgrammableParameters.parse(_pps({0x2C: '42 N'}));
      expect(UserCanFormat.of(pps.userCanOptions('B')!), UserCanFormat.j1939);
    });
  });
}
