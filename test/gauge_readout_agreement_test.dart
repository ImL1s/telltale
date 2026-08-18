/// What a dial prints, and what it says out loud.
///
/// `_semanticValue`'s doc comment claimed it announced "at the same precision
/// the readout shows" and it carried its own copy of a different rule. A
/// lambda of 0.85 was printed as 0.8 and read aloud as 0.85 — two of this
/// app's users getting different numbers off one dial, which is the same
/// defect as two parts of a screen disagreeing, arriving in the place nobody
/// looks.
///
/// Asserted through a pumped widget rather than by comparing the formatter
/// with itself. A first version of this file did the latter, which is a
/// tautology: both sides now call one function, so of course they agree, and
/// the thing worth holding is that the *widget* uses it on both paths.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/core/theme/app_theme.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/telemetry.dart';
import 'package:torque_obd/ui/widgets/gauges/dial_gauge.dart';

Future<String> _spoken(WidgetTester tester, double value) async {
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.dark(),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 300,
          height: 300,
          child: DialGauge(
            value: value,
            minValue: 0,
            maxValue: 10,
            label: 'LAMBDA',
            units: '',
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  // Read off the `Semantics` widget the gauge builds, rather than the merged
  // node: the dial marks its children `excludeSemantics` and announces itself,
  // so the value lives on that widget's own properties.
  final semantics = tester.widgetList<Semantics>(find.byType(Semantics))
      .firstWhere((s) => (s.properties.value ?? '').isNotEmpty);
  return semantics.properties.value!;
}

void main() {
  testWidgets('the dial announces exactly what it prints', (tester) async {
    // 0.85 is the value that gave it away. It prints 0.8 rather than 0.9
    // because the nearest double to 0.85 is a hair below it — ordinary IEEE
    // rounding, and not the point. The point is that both halves say the same
    // thing, whatever that is.
    for (final value in [0.85, 1.0, 9.99, 5.5]) {
      final spoken = await _spoken(tester, value);
      final printed = find.byWidgetPredicate(
        (w) => w is Text && w.data == formatGaugeReadout(value),
      );
      expect(printed, findsOneWidget,
          reason: 'the readout for $value should be '
              '"${formatGaugeReadout(value)}"');
      expect(spoken, contains(formatGaugeReadout(value)),
          reason: 'and it should be announced the same way');
    }
  });

  test('a non-finite value is not printed as a number', () {
    expect(formatGaugeReadout(double.nan), '--');
    expect(formatGaugeReadout(double.infinity), '--');
  });

  test('the list may be finer than the dial, and that is a decision', () {
    // `Reading.formatted` keeps two decimals below ten. Not drift: a list read
    // at rest can afford them, a dial glanced at from a driving seat is easier
    // with one. Pinned so that unifying them later has to be deliberate.
    final reading = Reading(
      pid: PidLibrary.engineRpm,
      value: 0.85,
      rawBytes: const [0, 0],
      timestamp: DateTime(2026, 8, 17),
    );
    expect(reading.formatted, '0.85');
    expect(formatGaugeReadout(0.85), '0.8');
  });
}
