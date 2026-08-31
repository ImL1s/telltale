/// The manual command box asks questions. It does not change anything.
///
/// Serialising it onto the ordinary command chain stopped it interleaving with
/// the poll loop. It did not stop it changing the adapter underneath the app's
/// model of it, and that is the part that produces a wrong number: a poll
/// selects `7E0` and the client caches it, the user types `ATSH 7E1`, and the
/// next built-in `010C` trusts the cache, sends no `ATSH`, and publishes the
/// transmission's 1000 rpm as the engine's.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/state/obd_session.dart';

void main() {
  String? refuse(String c) => ObdSession.manualCommandRefusal(c);

  group('queries go through', () {
    test('adapter questions', () {
      for (final c in [
        'ATI',
        'AT@1',
        'ATRV',
        'ATDP',
        'ATDPN',
        'ATPPS',
        'ATIGN',
      ]) {
        expect(refuse(c), isNull, reason: '$c only asks');
      }
    });

    test('read-only OBD services', () {
      for (final c in [
        '0100',
        '010C',
        '03',
        '07',
        '0A',
        '0902',
        '221E1C',
        '02',
      ]) {
        expect(refuse(c), isNull, reason: '$c only reads');
      }
    });

    test('Mode 21 is reserved for consent-bound experimental probes', () {
      expect(refuse('2101'), isNotNull);
      expect(refuse('21 95'), isNotNull);
    });

    test('spacing and case do not matter', () {
      expect(refuse('at i'), isNull);
      expect(refuse('01 0C'), isNull);
    });
  });

  group('anything that changes the adapter is refused', () {
    test('the header, which is how a wrong ECU answers', () {
      // The concrete trigger. `ATSH 7E1` is answered `OK`, the adapter now
      // transmits on 7E1, and nothing updates the client's cached header — so
      // the next built-in request goes to the transmission and its reply is
      // rendered as the engine's, with nothing on screen to say so.
      final why = refuse('ATSH 7E1');
      expect(why, isNotNull);
      expect(why, contains('另一個控制器'));
    });

    test('resets and protocol selection', () {
      for (final c in [
        'ATZ',
        'ATD',
        'ATSP0',
        'ATSP6',
        'ATE1',
        'ATH1',
        'ATS1',
      ]) {
        expect(refuse(c), isNotNull, reason: '$c invalidates the model');
      }
    });

    test('Mode 08 is a control service wearing a read service number', () {
      // J1979 names it "request control of on-board system, test or
      // component": it actuates things — evaporative-system leak tests,
      // solenoids, pumps. It was on a whitelist whose contract is read-only
      // because its number looks like its neighbours'.
      expect(refuse('08'), isNotNull);
      expect(refuse('0801'), isNotNull);
    });

    test('filters, flow control and monitoring', () {
      // The two commands this project has a written record of breaking real
      // vehicles are in here, and so are the monitor modes that never return.
      for (final c in ['ATCRA 7B0', 'ATCFC0', 'ATMA', 'ATMR7E8', 'ATMT7E8']) {
        expect(refuse(c), isNotNull);
      }
    });
  });

  group('clearing has a button, and the button is where the safeguards are', () {
    test('Mode 04 typed here is refused, and says where to go', () {
      final why = refuse('04');
      expect(why, isNotNull);
      expect(why, contains('清除'));
      // Typed here it would skip the confirmation, the coverage check, the
      // acknowledgement check and the lifecycle guard, clear whichever
      // controller happened to be selected, and reset the readiness monitors
      // while the app's own model of the scan knew nothing had happened.
      expect(why, contains('確認'));
    });

    test('and so is a Mode 04 with anything after it', () {
      expect(refuse('04 00'), isNotNull);
    });

    test('R29-codex 08: the help text lists what is actually allowed', () {
      // Codex round 29. The sentence that tells somebody what they *can* send
      // was written out by hand beside the set it describes, and the two had
      // already drifted: Mode 05 was admitted this round and the help text
      // still omitted it. A refusal that misdescribes the whitelist misdirects
      // exactly the person who most needs it — the one whose command just
      // failed, at a car.
      // Hex, so it passes the charset gate and reaches the sentence that
      // lists the services. `ZZ` does not — it is refused a step earlier for
      // its characters.
      final why = refuse('FF');
      expect(why, isNotNull);
      for (final service in [
        '01',
        '02',
        '03',
        '05',
        '06',
        '07',
        '09',
        '0A',
        '22',
      ]) {
        expect(why, contains(service), reason: service);
        expect(
          refuse(service),
          isNull,
          reason: 'listed as allowed, so it has to be allowed',
        );
      }
      expect(
        why,
        isNot(contains('04')),
        reason: 'and the clear must not appear in a list of read queries',
      );
      expect(why, isNot(contains('08')), reason: 'nor a control service');
    });

    test('R28-N6: Mode 05 is a read service and was refused', () {
      // J1979 service 05, "request oxygen sensor monitoring test results" —
      // stored results from completed tests, addressed by a sensor byte rather
      // than a PID. It is defined for pre-CAN implementations only, which is
      // exactly where it matters: on ISO 9141-2 and the J1850 pair there is no
      // Mode 06 to ask instead, so refusing it left no way to ask at all.
      expect(refuse('05'), isNull);
      expect(refuse('0501'), isNull);
    });

    test('R28-N5: a line break smuggles a clear past every check', () {
      // Cursor round 28. `\r` is the ELM327's command terminator, so this is
      // not one odd Mode 03 request — it is two requests, and the second
      // erases the vehicle's fault memory. Every rule in the refusal read the
      // first two characters, found `03`, and passed the whole string through.
      //
      // What that costs: the clear happens with no confirmation dialog, no
      // check that every controller was reached, no validation of what came
      // back — and the app's own model of the scan still believes nothing has
      // happened, so the screen goes on showing codes that are already gone.
      // The readiness monitors are reset either way, which is a drive cycle.
      for (final smuggled in [
        '03\r04',
        '03\n04',
        '0100\r\n04',
        'ATI\r04',
        '03\t04',
      ]) {
        expect(
          refuse(smuggled),
          isNotNull,
          reason: 'a command carrying a terminator is more than one command',
        );
      }
    });

    test('R29-cursor F5: a separator that is not CR is still a second command', () {
      // Cursor round 29. The control-character gate closed `03\r04`, and the
      // service check underneath it still matched a *prefix* — so `03;04` was
      // a Mode 03 request as far as it was concerned. `;` is named as a
      // command separator on STN-based adapters, and an OBDLink paste is how
      // it arrives.
      //
      // Fixed by whitelisting rather than by adding `;` to a list: no legal
      // OBD request contains a character outside `0-9A-F`, so anything else is
      // refused whether or not this app knows what it means. A blacklist of
      // separators is a list somebody has to keep complete, and the cost of
      // an incomplete one here is a clear.
      for (final smuggled in ['03;04', '03,04', '03|04', '03&04', '03/04']) {
        expect(refuse(smuggled), isNotNull, reason: smuggled);
      }
    });

    test('R29-cursor F5: ordinary hex commands still go through', () {
      // The over-strict sibling. Every shape a person legitimately types.
      for (final ok in [
        '03',
        '0100',
        '010C',
        '0902',
        '2211A6',
        '01 0C',
        '0a',
      ]) {
        expect(refuse(ok), isNull, reason: ok);
      }
    });

    test('R28-N5: the refusal explains the mechanism, not just "no"', () {
      final why = refuse('03\r04');
      expect(why, contains('換行'));
      expect(why, contains('一次只輸入一個指令'));
    });

    test('R28-N5: an ordinary command with surrounding whitespace still works', () {
      // The over-strict sibling. A pasted command arrives with its trailing
      // newline, and `trim` has already dealt with that — refusing it would
      // break the commonest legitimate paste there is.
      //
      // Safe because `sendManualCommand` puts the *trimmed* string on the
      // wire, so the terminator that was stripped for checking is the same one
      // that never reaches the adapter. The two have to agree on that, and
      // this is the test that says so.
      expect(refuse('03\r\n'), isNull);
      expect(refuse('  0100  '), isNull);
      expect(refuse('\nATI\n'), isNull);
    });
  });

  test('nonsense is refused rather than sent', () {
    expect(refuse('ZZ'), isNotNull);
    expect(refuse(''), isNotNull);
    expect(refuse('   '), isNotNull);
  });
}
