/// What a PID definition may not be, whichever door it came in by.
///
/// Both findings were verified against Dart 3.13 directly rather than reasoned
/// about. `double.tryParse('NaN')` returns NaN; every comparison against NaN is
/// false, so `max <= min` waved it past. The dial's
/// `((value - min) / (max - min)).clamp(0, 1)` then evaluates to 1.0 — a needle
/// pinned at full scale and an arc fully lit, for an engine at idle. And
/// `jsonEncode` throws on a non-finite double, so saving wedges *and* leaves
/// the definition in memory, after which every later save of any custom PID
/// throws too.
///
/// The second is quieter. The validator's two callers each normalised the
/// identifier their own way before storing it, and `pidByte` reads
/// `substring(2, 4)` — which for a stored `01 0C` is `' 0'` and parses to null.
/// Type that into the editor and the gauge never reads anything, with nothing
/// on screen to say why, while the identical text imported from a spreadsheet
/// works.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/core/theme/app_theme.dart';
import 'package:torque_obd/ui/widgets/gauges/dial_gauge.dart';
import 'package:torque_obd/obd/addressing.dart';
import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/pid/formula_engine.dart';
import 'package:torque_obd/obd/transport/demo_transport.dart';
import 'package:torque_obd/obd/pid/pid.dart';
void main() {
  test('non-finite bounds are refused', () {
    for (final bad in ['NaN', 'Infinity', '-Infinity']) {
      expect(
        PidDefinition.rejectionReason(
            name: 'x', modeAndPid: '010C', header: '7E0',
            minText: '0', maxText: bad),
        isNotNull,
        reason: '$bad passes every `max <= min` comparison and pins the '
            'needle at full scale, then wedges jsonEncode',
      );
    }
    expect(
      PidDefinition.rejectionReason(
          name: 'x', modeAndPid: '010C', header: '7E0',
          minText: '0', maxText: '8000'),
      isNull,
    );
  });
  test('one spelling of an identifier', () {
    expect(PollableServices.normalise(' 01 0c '), '010C');
  });

  test('an ambiguous reference says so, rather than saying it is missing', () {
    // Fable F-9's second half. `pidValue` returns null for three different
    // reasons and the caller reported all three as "no value obtained yet".
    // For ambiguity that is a lie about the cause: the value exists, twice,
    // and the app is declining to choose. The user is sent to look for a fault
    // in a vehicle that is answering perfectly.
    //
    // It needs nothing unusual to reach. The shipped library defines `010B`
    // twice — manifold pressure and turbo boost — so putting the boost gauge
    // on the dashboard makes that hex ambiguous for as long as it is there.
    final engine = FormulaEngine();
    Pid def(String eq, String variant) => Pid(
          name: variant, shortName: variant, modeAndPid: '010B',
          equation: eq, minValue: 0, maxValue: 300, units: '',
          header: kDefaultHeader, variant: variant, isCustom: true);

    final now = DateTime(2026, 8, 15);
    engine.cachePidValue(def('A', 'plain'), 100, now);
    engine.cachePidValue(def('A*2', 'doubled'), 200, now);
    expect(engine.isAmbiguous(kDefaultHeader, '010B'), isTrue,
        reason: 'sanity: two definitions of one hex is the premise');

    const consumer = Pid(
      name: 'derived', shortName: 'd', modeAndPid: '0111',
      equation: 'VAL{010B}', minValue: 0, maxValue: 300, units: '',
      header: kDefaultHeader, isCustom: true,
    );
    expect(
      () => engine.evaluateBytes('VAL{010B}', const [0x40],
          requester: consumer, now: now),
      throwsA(isA<FormulaException>().having(
        (e) => e.toString(), 'message', contains('兩個定義'))),
      reason: 'the remedy is to remove a gauge, not to wait for a reading '
          'that has already arrived twice',
    );
  });

  test('BARO applies the same conflict rule VAL{} does', () {
    // Fable F-13. `setBaroPressure` recorded which definition wrote each
    // value and no reader consulted it, so a custom `0133` polled beside the
    // built-in one had `BARO` silently alternating between two values at the
    // polling cadence — one controller, one measurement, two answers — while
    // `VAL{0133}` refused that identical collision. Two opposite policies for
    // the same ambiguity, chosen by which spelling the formula happened to
    // use.
    final engine = FormulaEngine();
    Pid baroSource(String eq, String variant) => Pid(
          name: variant, shortName: variant, modeAndPid: '0133',
          equation: eq, minValue: 0, maxValue: 300, units: '',
          header: kDefaultHeader, variant: variant, isCustom: true);

    final now = DateTime(2026, 8, 15);
    engine.setBaroPressure(baroSource('A', 'plain'), 101.0, now);
    // One author: usable.
    expect(
      engine.evaluateBytes('BARO', const [0x00],
          requester: baroSource('A', 'plain'), now: now),
      closeTo(101.0, 0.01),
    );

    engine.setBaroPressure(baroSource('A*10', 'tenfold'), 1010.0, now);
    expect(
      () => engine.evaluateBytes('BARO', const [0x00],
          requester: baroSource('A', 'plain'), now: now),
      throwsA(isA<FormulaException>().having(
          (e) => e.toString(), 'message', contains('兩個定義'))),
      reason: 'picking either would be picking at random, which is what the '
          'sibling rule already refuses to do',
    );
  });

  testWidgets('a gauge speaks why it has no value, not only that it has none',
      (tester) async {
    // Fable F-27. The footnote distinguishes three states on screen — a
    // formula the user can fix, a bus fault they cannot, and a sensor that
    // will be retried — and `excludeSemantics: true` meant a screen reader
    // heard "無資料" for all of them.
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark(),
      home: const Scaffold(
        body: SizedBox.square(
          dimension: 300,
          child: DialGauge(
            value: null,
            minValue: 0,
            maxValue: 8000,
            label: 'RPM',
            units: 'rpm',
            footnote: '公式錯誤',
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final node = tester.getSemantics(find.bySemanticsLabel('RPM'));
    expect(node.value, contains('公式錯誤'),
        reason: 'a bus fault and a formula error need different actions from '
            'the user, and sounded identical');
    handle.dispose();
  });

  test('R7 F-25: a headered single frame carries its padding', () async {
    // Fable flagged its own premise here as a guess from datasheet memory, so
    // it was checked rather than adopted — and the datasheet settles it. Its
    // worked example is
    //
    //     7E8 06 41 00 BE 3F B8 13 00
    //
    // six data bytes declared, six delivered, one `00` filling the frame out
    // to eight. A CAN frame is eight bytes on the wire whatever the payload
    // occupies, and with headers on the adapter prints all of it.
    //
    // The demo's multi-frame branch padded and its single-frame branch did
    // not, so the shipped simulator never produced the shape real hardware
    // prints most often. The parser has always handled it; nothing exercised
    // it.
    final transport = DemoTransport();
    final client = Elm327Client(transport);
    expect(await client.connect(), isTrue);

    // **Mode 07, not Mode 03.** The first version of this used `03`, whose
    // demo payload is eight bytes — an ISO-TP *multi*-frame, whose first line
    // is long whether or not single frames are padded. It therefore passed
    // with the padding deleted, testing the branch next to the one it names.
    //
    // `47 00` is two bytes, so it takes the single-frame path this is about.
    final reply = await client.sendGlobal('07');
    expect(reply.isSuccess, isTrue);
    final line = reply.rawLines.firstWhere((l) => l.trim().isNotEmpty).trim();
    // Header + PCI + seven payload bytes, unspaced under `ATS0`: `7E8` plus
    // eight byte pairs is 19 characters. Two data bytes alone would be 9.
    expect(line.length, greaterThanOrEqualTo(19),
        reason: 'a CAN frame is eight bytes on the wire whatever the payload '
            'occupies, and with headers on the adapter prints all of it. '
            'Got: $line');
    expect(reply.frames.first.sourceId, isNotNull,
        reason: 'and it is still attributed, which is what the padding sits '
            'inside');
    await client.dispose();
  });

  test('R8-10: a header is spelled one way too', () {
    // The same defect as the mode+PID identifier, in the field beside it. The
    // shared validator canonicalised and the editor stored `trim()
    // .toUpperCase()`, keeping internal spaces — so `7 E 0` passed validation,
    // enabled Save, and was stored in a spelling `isAppDefault` and
    // `acceptsHeader` both reject. The PID then polled with no `ATSH` at all,
    // on the adapter's functional default, and whichever controller answered
    // first filled the gauge.
    expect(BusAddressing.normaliseHeader(' 7 e 0 '), '7E0');
    expect(BusAddressing.isAppDefault(BusAddressing.normaliseHeader('7 E 0')),
        isTrue,
        reason: 'the stored spelling has to be the one the runtime matches');
    // This used to assert `acceptsHeader('7 E 1') == false` as a "sanity"
    // control — pinning the defective half of the mismatch as though it were
    // the contract. A reviewer named it, and it is the sixth time this project
    // has fixed one side of a normalisation and left a test guarding the
    // other.
    //
    // Every reader goes through the one normaliser now, so they agree whatever
    // spelling reaches them — which is the actual property, and the only one
    // worth pinning.
    final can11 = BusAddressing.forProtocolNumber('6');
    for (final spelling in ['7E1', '7 E 1', ' 7e1 ', '7 e 1']) {
      expect(can11.acceptsHeader(spelling), isTrue, reason: spelling);
    }
    expect(BusAddressing.isAppDefault('7 e 0'), isTrue);

    // And a definition stored by an older build is normalised on the way in,
    // rather than reproducing the defect one launch later.
    const spaced = Pid(
      name: 'x', shortName: 'x', modeAndPid: '010C', equation: 'A',
      minValue: 0, maxValue: 8000, units: '', header: '7 E 0',
    );
    expect(Pid.fromJson(spaced.toJson()).header, '7E0');
  });

  test('R8-18: a difference in spelling is not a disagreement', () {
    // GPT-5.6 Pro. Ambiguity was inferred from equation *text*, so `A` and
    // `(A)` — the same number from the same bytes — marked the key
    // permanently ambiguous and a boost gauge went unavailable for it.
    //
    // The honest test is whether the values disagree at the moment a reader
    // would use them.
    final engine = FormulaEngine();
    Pid baro(String eq, String variant) => Pid(
          name: variant, shortName: variant, modeAndPid: '0133',
          equation: eq, minValue: 0, maxValue: 300, units: '',
          header: kDefaultHeader, variant: variant, isCustom: true);

    final now = DateTime(2026, 8, 16);
    engine.setBaroPressure(baro('A', 'plain'), 101.0, now);
    engine.setBaroPressure(baro('(A)', 'parenthesised'), 101.0, now);
    expect(
      engine.evaluateBytes('BARO', const [0x00],
          requester: baro('A', 'plain'), now: now),
      closeTo(101.0, 0.001),
      reason: 'both definitions produced the same measurement; there is '
          'nothing for a reader to be ambiguous about',
    );

    // And two that genuinely disagree still are. `A` and `A*2` agree only
    // while A is zero, so the flag is set when they diverge rather than
    // pre-emptively.
    engine.setBaroPressure(baro('A*2', 'doubled'), 202.0, now);
    expect(
      () => engine.evaluateBytes('BARO', const [0x00],
          requester: baro('A', 'plain'), now: now),
      throwsA(isA<FormulaException>()),
      reason: 'now they really do disagree, and picking one is picking at '
          'random',
    );
  });

  test('R8-19: editing a PID does not delete what the editor cannot show', () {
    // **The first version of this test was a tautology**, and a reviewer
    // caught it: it built both `Pid` objects by hand, passed
    // `redlineFrom: original.redlineFrom` to the second, and asserted the
    // value had survived. Deleting the production line changed nothing,
    // because the production line was never involved. Fifth instance of a
    // pattern this project has documented four times.
    //
    // `copyWith` is what the editor's reconstruction has to behave like, and
    // it is real code with a real chance of dropping a field — which is
    // exactly what `explicitDataBytes` did before it was deleted.
    const original = Pid(
      name: 'Boost', shortName: 'BST', modeAndPid: '010B', equation: 'A',
      minValue: 0, maxValue: 300, units: 'kPa', header: kDefaultHeader,
      isCustom: true, variant: 'boost', redlineFrom: 250,
    );

    // Every field the editor can change, changed — and the one it cannot show
    // must survive all of them.
    final renamed = original.copyWith(name: 'Boost pressure');
    expect(renamed.redlineFrom, 250,
        reason: 'an editor may not destroy what it cannot show');
    expect(renamed.id, original.id,
        reason: 'and it is still the same gauge, so the loss would have been '
            'invisible');

    // The round trip through storage, which is the other way a field
    // disappears silently.
    final restored = Pid.fromJson(original.toJson());
    expect(restored.redlineFrom, 250,
        reason: 'persisted definitions keep it too, or the deletion just '
            'happens one launch later');
  });
}
