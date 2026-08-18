import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/pid/formula_engine.dart';
import 'package:torque_obd/obd/pid/pid.dart';

void main() {
  late FormulaEngine engine;

  setUp(() => engine = FormulaEngine());

  group('payload byte extraction', () {
    test('strips the Mode 01 positive-response prefix', () {
      expect(FormulaEngine.parseUserTypedSampleBytes('41 0C 1A F0'), [0x1A, 0xF0]);
    });

    test('strips the wider Mode 22 prefix', () {
      expect(FormulaEngine.parseUserTypedSampleBytes('62 1E 1C 02 80'), [0x02, 0x80]);
    });

    test('passes through a payload that carries no prefix', () {
      expect(FormulaEngine.parseUserTypedSampleBytes('1AF0'), [0x1A, 0xF0]);
    });

    test(
        'turns the error line DATA ERROR into the plausible bytes DA AE — which '
        'is why no adapter-sourced string may ever reach this function', () {
      // Not a defect being tolerated: it is the documented cost of accepting
      // whatever punctuation a person pastes into 測試用回應位元組. The strip is
      // a blacklist (delete non-hex, concatenate the rest), and this project's
      // hard rule against blacklists exists because of exactly this result —
      // two bytes of ordinary magnitude, indistinguishable downstream from a
      // sensor reading, produced from a line that says the read failed.
      //
      // Pinned so the constraint is recorded in something that runs. It held
      // only by the accident of where the two call sites got their text from,
      // and nothing anywhere said so.
      expect(FormulaEngine.parseUserTypedSampleBytes('DATA ERROR'),
          [0xDA, 0xAE]);
      // The other lines an ELM327 emits in place of data survive as bytes too,
      // just fewer of them — still a number where the wire said there is none.
      expect(FormulaEngine.parseUserTypedSampleBytes('CAN ERROR'), [0xCA]);
      expect(FormulaEngine.parseUserTypedSampleBytes('BUS INIT: ERROR'), [0xBE]);
    });

    test('nothing under lib/obd/ calls the string-taking evaluator', () {
      // The only route from a response line into the blacklist strip above.
      // Live polling calls `evaluateBytes` with bytes the whitelist in
      // `Elm327Client._hexLine` already accepted; the string overload exists
      // for the editor's authoring preview and must stay there.
      //
      // A source-level check rather than a behavioural one, because the defect
      // being guarded against is a future call site, not a wrong answer from an
      // existing one — and by the time it returns a wrong answer it looks like
      // a reading.
      final root = Directory('lib/obd');
      expect(root.existsSync(), isTrue,
          reason: 'run from the app/ directory, where lib/obd/ is');
      final offenders = <String>[];
      for (final entity in root.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].contains('.evaluate(')) {
            offenders.add('${entity.path}:${i + 1}: ${lines[i].trim()}');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'a string reaching FormulaEngine.evaluate from the OBD layer '
              'is adapter output, and it would be stripped by blacklist');
    });
  });

  group('reference cases ported from examples/dart', () {
    test('coolant temperature: A-40', () {
      expect(engine.evaluate('A-40', '41 05 50'), closeTo(40.0, 1e-6));
    });

    test('engine RPM: ((A*256)+B)/4', () {
      expect(engine.evaluate('((A*256)+B)/4', '41 0C 1A F0'), closeTo(1724.0, 1e-6));
    });

    test('signed byte conversion', () {
      expect(engine.evaluate('SIGNED(A)*1.5', '41 00 FE'), closeTo(-3.0, 1e-6));
    });

    test('ABS()', () {
      expect(engine.evaluate('ABS(A-100)', '41 00 20'), closeTo(68.0, 1e-6));
    });

    test('LOG10()', () {
      expect(engine.evaluate('LOG10(A)', '41 00 64'), closeTo(2.0, 1e-6));
    });

    test('VAL{} external PID reference', () {
      // A VAL{} reference now resolves against the *asking* controller, so the
      // seed and the requester have to be on the same one. Keying by bare hex
      // let a formula on the ECM consume a value the TCM measured.
      final now = DateTime(2026, 8, 15);
      final requester = FormulaEngine.probePid('0000');
      engine.cachePidValue(FormulaEngine.probePid('010D'), 100.0, now);
      expect(
        engine.evaluate(
          'VAL{010D}*0.621371',
          '41 00',
          requester: requester,
          now: now,
        ),
        closeTo(62.1371, 1e-4),
      );
    });
  });

  group('operator handling', () {
    test('respects precedence without parentheses', () {
      // 2 + 3 * 4 must be 14, not 20.
      expect(engine.evaluateBytes('2+3*4', const []), closeTo(14.0, 1e-9));
    });

    test('subtraction associates left to right', () {
      // A regression guard: splitting on the first '-' instead of the last
      // would yield 10 - (5 - 2) = 7.
      expect(engine.evaluateBytes('10-5-2', const []), closeTo(3.0, 1e-9));
    });

    test('division associates left to right', () {
      expect(engine.evaluateBytes('100/5/2', const []), closeTo(10.0, 1e-9));
    });

    test('handles a leading unary minus', () {
      expect(engine.evaluateBytes('-5+8', const []), closeTo(3.0, 1e-9));
    });

    test('does not mistake a unary minus for subtraction', () {
      expect(engine.evaluateBytes('3*-2', const []), closeTo(-6.0, 1e-9));
    });

    test('exponentiation', () {
      expect(engine.evaluateBytes('2^10', const []), closeTo(1024.0, 1e-9));
    });

    test('bitwise and / or', () {
      expect(engine.evaluateBytes('12&10', const []), closeTo(8.0, 1e-9));
      expect(engine.evaluateBytes('12|3', const []), closeTo(15.0, 1e-9));
    });

    test('relational operators yield 1 or 0', () {
      expect(engine.evaluateBytes('5>3', const []), closeTo(1.0, 1e-9));
      expect(engine.evaluateBytes('5<3', const []), closeTo(0.0, 1e-9));
      expect(engine.evaluateBytes('5==5', const []), closeTo(1.0, 1e-9));
    });

    test('division by zero is an error, not zero', () {
      // Returning 0 would put a plausible number on a gauge for a calculation
      // that could not be performed.
      expect(
        () => engine.evaluateBytes('10/0', const []),
        throwsA(isA<FormulaException>()),
      );
      expect(
        () => engine.evaluateBytes('10%0', const []),
        throwsA(isA<FormulaException>()),
      );
    });

    test('exponentiation is right-associative', () {
      // 2^3^2 is 2^(3^2) = 512, not (2^3)^2 = 64.
      expect(engine.evaluateBytes('2^3^2', const []), closeTo(512.0, 1e-9));
    });

    test('modulo shares precedence with multiply and divide', () {
      // Treating % as its own tighter level makes this A/(B%C) = 100/2 = 50.
      expect(engine.evaluateBytes('A/B%C', const [100, 7, 5]), closeTo(4.285714, 1e-5));
    });

    test('multiply and modulo associate left to right', () {
      expect(engine.evaluateBytes('20%7*3', const []), closeTo(18.0, 1e-9));
    });

    test('a unary minus binds looser than exponentiation', () {
      // -A^2 is -(A^2). Splitting on ^ first would take -3 as the base and
      // give +9.
      expect(engine.evaluateBytes('-A^2', const [3]), closeTo(-9.0, 1e-9));
    });

    test('a negated power still combines correctly with addition', () {
      expect(engine.evaluateBytes('-A^2+1', const [3]), closeTo(-8.0, 1e-9));
    });

    test('exponentiation of an explicitly bracketed negative', () {
      expect(engine.evaluateBytes('(-A)^2', const [3]), closeTo(9.0, 1e-9));
    });

    test('two-character relational operators', () {
      expect(engine.evaluateBytes('5>=5', const []), 1.0);
      expect(engine.evaluateBytes('5<=4', const []), 0.0);
      expect(engine.evaluateBytes('5!=4', const []), 1.0);
      expect(engine.evaluateBytes('5!=5', const []), 0.0);
    });

    test('>= is not mis-split as > followed by =', () {
      expect(engine.evaluateBytes('A>=B', const [3, 9]), 0.0);
      expect(engine.evaluateBytes('A>=B', const [9, 3]), 1.0);
    });
  });

  group('variable binding', () {
    test('binds A..N positionally', () {
      expect(engine.evaluateBytes('A+B+C+D', const [1, 2, 3, 4]), closeTo(10.0, 1e-9));
    });

    test('a formula referencing a byte the ECU did not send is an error', () {
      // Substituting zero here would turn a truncated reply into a confident
      // wrong reading rather than a visible fault.
      expect(
        () => engine.evaluateBytes('A+B+C', const [5]),
        throwsA(isA<FormulaException>()),
      );
    });

    test('a truncated RPM reply fails instead of reading low', () {
      // ((A*256)+B)/4 with B missing would silently report 1664 rpm when the
      // real value was 1724.
      expect(
        () => engine.evaluateBytes('((A*256)+B)/4', const [0x1A]),
        throwsA(isA<FormulaException>()),
      );
    });

    test('function names survive variable substitution', () {
      // The 'A' in ABS and the letters in LOG10 must not be replaced by byte
      // values — the sentinel shielding exists for exactly this.
      expect(engine.evaluateBytes('ABS(A-10)', const [3]), closeTo(7.0, 1e-9));
      expect(engine.evaluateBytes('LOG10(A)', const [100]), closeTo(2.0, 1e-9));
    });

    test('nested functions reduce innermost first', () {
      expect(engine.evaluateBytes('ABS(ABS(A)-20)', const [5]), closeTo(15.0, 1e-9));
    });

    test('BARO injects the ambient pressure', () {
      // Scoped to a controller now, like every other dependency — the seeder
      // and the requester have to agree on which one.
      engine.baroPressure = 99.5;
      expect(
        engine.evaluateBytes(
          'A-BARO',
          const [120],
          requester: FormulaEngine.probePid('0000'),
        ),
        closeTo(20.5, 1e-6),
      );
    });

    test('BARO measured on one controller does not feed another', () {
      // A single shared value meant `7E0`'s reading fed a formula evaluated on
      // `7E1`, whichever wrote last — the collision the VAL{} work removed,
      // still open on the one input with no byte of its own.
      final now = DateTime(2026, 8, 15);
      const ecm = Pid(
        name: 'baro', shortName: 'baro', modeAndPid: '0133', equation: 'A',
        minValue: 0, maxValue: 255, units: 'kPa', header: '7E0',
      );
      const onTcm = Pid(
        name: 'boost', shortName: 'boost', modeAndPid: '010B',
        equation: 'A-BARO', minValue: -100, maxValue: 300, units: 'kPa',
        header: '7E1',
      );

      engine.setBaroPressure(ecm, 99.5, now);
      expect(
        () => engine.evaluateBytes('A-BARO', const [120],
            requester: onTcm, now: now),
        throwsA(isA<FormulaException>()),
        reason: 'the TCM has no barometric measurement of its own',
      );
    });

    test('BARO does not survive a break in continuity', () {
      // `clearCache()` runs on pause. Leaving the pressure behind let a value
      // measured before the pause feed a formula after one.
      final now = DateTime(2026, 8, 15);
      final probe = FormulaEngine.probePid('0000');
      engine.setBaroPressure(probe, 99.5, now);
      engine.clearCache();
      expect(
        () => engine.evaluateBytes('A-BARO', const [120],
            requester: probe, now: now),
        throwsA(isA<FormulaException>()),
      );
    });

    test('a nested divide-by-zero is a formula error, not a raw throw', () {
      // `ABS(A/B)` with B = 0 raised `_ArithmeticFailure` during
      // preprocessing, outside the boundary that converts it — so the poller,
      // which handles only `FormulaException`, lost the whole cycle through
      // its outer catch and left the previous reading on the gauge as current.
      expect(
        () => engine.evaluateBytes('ABS(A/B)', const [10, 0]),
        throwsA(isA<FormulaException>()),
      );
      expect(
        () => engine.evaluateBytes('LOG10(A/B)', const [10, 0]),
        throwsA(isA<FormulaException>()),
      );
      // And the same equation with a usable divisor still works.
      expect(engine.evaluateBytes('ABS(A/B)', const [10, 2]), closeTo(5, 1e-9));
    });

    test('an unresolved VAL{} reference is an error, not zero', () {
      // `A-VAL{0133}` (boost) would otherwise degrade into `A-0` and display
      // raw manifold pressure as though it were boost.
      expect(
        () => engine.evaluateBytes('VAL{9999}+7', const []),
        throwsA(isA<FormulaException>()),
      );
    });

    test('a resolved VAL{} reference still works', () {
      final now = DateTime(2026, 8, 15);
      engine.cachePidValue(FormulaEngine.probePid('0133'), 101.0, now);
      expect(
        engine.evaluateBytes(
          'A-VAL{0133}',
          const [150],
          requester: FormulaEngine.probePid('0000'),
          now: now,
        ),
        closeTo(49.0, 1e-9),
      );
    });

    test('an ambiguous VAL{} reference is refused, not guessed', () {
      // Two gauges can define the same hex on the same controller with
      // different maths — a raw manifold pressure beside a converted boost
      // figure. They share a cache key, because `VAL{010B}` names hex and
      // nothing else, so whichever polled last used to win and the number that
      // came out looked exactly as reasonable as the right one.
      final now = DateTime(2026, 8, 15);
      const raw = Pid(
        name: 'map', shortName: 'map', modeAndPid: '010B', equation: 'A',
        minValue: 0, maxValue: 255, units: 'kPa',
      );
      const converted = Pid(
        name: 'boost', shortName: 'boost', modeAndPid: '010B',
        equation: 'A*0.145', minValue: 0, maxValue: 255, units: 'psi',
        variant: 'psi',
      );

      engine.cachePidValue(raw, 100, now);
      expect(
        engine.cachedPidValue(FormulaEngine.probePid('0000'), '010B', now: now),
        equals(100),
        reason: 'one definition resolves normally',
      );

      engine.cachePidValue(converted, 14.5, now);
      expect(
        engine.cachedPidValue(FormulaEngine.probePid('0000'), '010B', now: now),
        isNull,
        reason: 'two definitions computing different things cannot be told '
            'apart by a reference that names only the hex',
      );
    });

    test('a VAL{} reference goes stale rather than standing forever', () {
      final measured = DateTime(2026, 8, 15);
      engine.cachePidValue(FormulaEngine.probePid('0133'), 101.0, measured);
      expect(
        () => engine.evaluateBytes(
          'A-VAL{0133}',
          const [150],
          requester: FormulaEngine.probePid('0000'),
          now: measured.add(
            FormulaEngine.maxCacheAge + const Duration(seconds: 1),
          ),
        ),
        throwsA(isA<FormulaException>()),
        reason: 'the poller drops a reading whose source stopped answering, '
            'but the formula cache kept quoting the number indefinitely',
      );
    });

    test('SIGNED() past the payload is an error', () {
      expect(
        () => engine.evaluateBytes('SIGNED(C)', const [1, 2]),
        throwsA(isA<FormulaException>()),
      );
    });

    test('a non-finite result is rejected', () {
      expect(
        () => engine.evaluateBytes('LOG10(A)/0', const [100]),
        throwsA(isA<FormulaException>()),
      );
    });
  });

  group('failure handling', () {
    test('rejects an empty formula', () {
      expect(() => engine.evaluateBytes('', const [1]), throwsA(isA<FormulaException>()));
    });

    test('rejects unbalanced parentheses', () {
      expect(
        () => engine.evaluateBytes('(A+1', const [1]),
        throwsA(isA<FormulaException>()),
      );
    });

    test('rejects a stray identifier', () {
      expect(
        () => engine.evaluateBytes('A+ZZZ', const [1]),
        throwsA(isA<FormulaException>()),
      );
    });

    test('validate() accepts a sound formula', () {
      expect(FormulaEngine.validate('((A*256)+B)/4'), isNull);
    });

    test('validate() reports the problem with a broken formula', () {
      expect(FormulaEngine.validate('((A*256)+B'), isNotNull);
    });
  });

  group('numeric formatting round-trip', () {
    test('small magnitudes do not degrade into scientific notation', () {
      // toString() would render this as 1e-7 and the reducer would then split
      // on the '-', producing nonsense.
      final result = engine.evaluateBytes('A/10000000', const [1]);
      expect(result, closeTo(1e-7, 1e-12));
    });

    test('a tiny intermediate survives a following operation', () {
      final result = engine.evaluateBytes('(A/10000000)*10000000', const [3]);
      expect(result, closeTo(3.0, 1e-6));
    });
  });

  _editorValidation();
}

// Editor-facing validation. Runtime evaluation is strict about unresolved
// dependencies; authoring is not, because at authoring time there is no live
// data at all and blocking on that would make VAL{} unusable despite the
// editor advertising it.
void _editorValidation() {
  group('editor validation vs runtime evaluation', () {
    test('a formula with VAL{} validates even though nothing is polled yet', () {
      expect(FormulaEngine.validate('A-VAL{0133}'), isNull);
    });

    test('valReferences finds every dependency', () {
      expect(
        FormulaEngine.valReferences('VAL{010D}*0.6+VAL{0133}'),
        containsAll(['010D', '0133']),
      );
    });

    test('a malformed formula still fails validation', () {
      expect(FormulaEngine.validate('A-VAL{0133}*'), isNotNull);
      expect(FormulaEngine.validate('((A+1)'), isNotNull);
    });

    test('runtime evaluation stays strict about the same formula', () {
      expect(
        () => FormulaEngine().evaluateBytes('A-VAL{0133}', const [150]),
        throwsA(isA<FormulaException>()),
      );
    });

    test('R23-kimi F7: modulo takes the sign of the dividend, as Torque does',
        () {
      // These formulas are written for Torque, which is a Java app, and Java's
      // `%` is a truncated remainder — it takes the dividend's sign. Dart's is
      // Euclidean and never negative. `(A-128)%16` with `A = 0x64` is -12 in
      // Torque and was 12 here: two numbers, both plausible, both passing
      // every structural check, and the gauge showed the wrong one with no
      // fault raised.
      expect(FormulaEngine().evaluateBytes('(A-128)%16', const [0x64]), -12);
      // The ordinary direction is unchanged.
      expect(FormulaEngine().evaluateBytes('A%16', const [0x64]), 4);
    });

    test('R23-kimi F8: ABS and LOG10 nest in either order', () {
      // Both patterns exclude parentheses so each pass collapses an innermost
      // call, and the passes ran once each in a fixed order — so exactly one
      // nesting order worked. `LOG10(ABS(A))` reduced; `ABS(LOG10(A))` was
      // refused at authoring time with nothing wrong in it.
      expect(FormulaEngine().evaluateBytes('LOG10(ABS(A))', const [100]), 2);
      expect(FormulaEngine().evaluateBytes('ABS(LOG10(A))', const [100]), 2);
      // And an argument parenthesised for its own sake, which is how people
      // write.
      expect(FormulaEngine().evaluateBytes('ABS((A-200))', const [100]), 100);
      expect(FormulaEngine.validate('ABS(LOG10(A))'), isNull);
    });

    test('R23-kimi F9: a sample too short to hold a header keeps its bytes',
        () {
      // `62 1E` is two bytes and the Mode 22 header is three, so stripping it
      // threw a raw `RangeError` — outside this file's exception contract, and
      // the editor showed the user a Dart error object.
      expect(FormulaEngine.parseUserTypedSampleBytes('62 1E'), [0x62, 0x1E]);
      expect(FormulaEngine.parseUserTypedSampleBytes('41 0C 1A F8'), [0x1A, 0xF8]);
      expect(FormulaEngine.parseUserTypedSampleBytes('62 F1 90 41'), [0x41]);
      // Two bytes beginning 0x4X are kept: there is no header to remove.
      expect(FormulaEngine.parseUserTypedSampleBytes('4A 20'), [0x4A, 0x20]);
    });
  });
}
