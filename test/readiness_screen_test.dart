/// What the readiness card says, against what the decoder knows.
///
/// `readiness_test.dart` holds the decoder. This holds the screen — and the
/// gap between them is where round 36 found a false all-clear. `Readiness`
/// grew `unnamedSupported` / `unnamedOutstanding` so a monitor this table
/// cannot name could still block "ready", and `allSupportedComplete` was
/// written to honour that. The card never used it: it asked
/// `incomplete.isEmpty` — named monitors only — and told a driver with an
/// outstanding unnamed monitor that everything was finished.
///
/// The same shape as the gauge face two rounds ago. A rule moved somewhere
/// testable, and the call site kept its own older copy.
///
/// Every case here is built by `Readiness.decode` from bytes an ECU could
/// actually send, not by naming fields on the model. That matters more than
/// it looks: **only compression ignition has unnamed bits at all** — the petrol
/// map covers all eight of C's bits, so a `spark` readiness with
/// `unnamedSupported > 0` is a state the decoder cannot produce and a test
/// pinning it would be pinning fiction.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/core/theme/app_theme.dart';
import 'package:torque_obd/obd/polling_engine.dart';
import 'package:torque_obd/obd/readiness.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/dtc_scan.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/ui/screens/dtc/dtc_screen.dart';

class _FixedScan extends DtcScanNotifier {
  _FixedScan(this.initial);
  final DtcScanState initial;
  @override
  DtcScanState build() => initial;
}

class _FixedSession extends ObdSession {
  @override
  ObdConnectionState build() => const ObdConnectionState(
        phase: ConnectionPhase.connected,
        kind: TransportKind.demo,
        deviceName: 'Demo ECU',
      );
}

/// Byte B with the compression-ignition bit set and no continuous monitor
/// supported, so C and D carry the whole answer.
const _diesel = 0x08;

Future<void> _pumpReadiness(WidgetTester tester, Readiness readiness) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        dtcScanProvider.overrideWith(() => _FixedScan(DtcScanState(
              scannedAt: DateTime(2026, 8, 17),
              results: const {},
              mil: MilStatus({
                '7E8': MilSummary(
                  milOn: false,
                  confirmedCount: 0,
                  readiness: readiness,
                ),
              }),
            ))),
        obdSessionProvider.overrideWith(_FixedSession.new),
      ],
      child: MaterialApp(theme: AppTheme.dark(), home: const DtcScreen()),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

/// How many chips on screen are marked unfinished, by the mark the chip draws.
int _chipsSayingUnfinished(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .where((t) => (t.data ?? '').startsWith('… '))
    .length;

void main() {
  testWidgets('an outstanding monitor it cannot name is not an all-clear',
      (tester) async {
    // C bit 2 supported, D bit 2 unfinished. Bit 2 is unnamed in the
    // compression set, so `incomplete` is empty while the vehicle has plainly
    // said something is not done. The card used to read that as finished.
    final readiness = Readiness.decode(_diesel, 0x04, 0x04);
    expect(readiness.incomplete, isEmpty, reason: 'the trap: nothing named');
    expect(readiness.unnamedOutstanding, 1);

    await _pumpReadiness(tester, readiness);

    expect(find.textContaining('都已完成'), findsNothing,
        reason: 'this is somebody about to drive to an inspection');
    expect(find.textContaining('還有 1 項沒有完成'), findsOneWidget);
  });

  testWidgets('and the chips agree with the sentence', (tester) async {
    // The other half, and the one the sentence alone would hide. The chip row
    // is built from `readiness.states`, which by construction holds only the
    // monitors this table has names for — so a fixed sentence saying "2 left"
    // sat above a row where every chip read ✓ or —, and the screen
    // contradicted itself in the same glance.
    //
    // Bit 0 is NMHC catalyst, bit 2 is unnamed; both supported, both unfinished.
    final readiness = Readiness.decode(_diesel, 0x05, 0x05);
    expect(readiness.incomplete, [ReadinessMonitor.nmhcCatalyst]);
    expect(readiness.unnamedOutstanding, 1);

    await _pumpReadiness(tester, readiness);

    expect(find.textContaining('還有 2 項沒有完成'), findsOneWidget);
    expect(_chipsSayingUnfinished(tester), 2,
        reason: 'the count in the sentence has to be countable on screen — '
            'a driver reconciling it against an inspection report is the '
            'entire audience for this card');
  });

  testWidgets('an unnamed monitor that is finished is still a completion',
      (tester) async {
    // The over-strict twin, in the UI. C bit 2 supported, D clear: the vehicle
    // monitors one thing this code cannot name, and has finished it. That is a
    // controller reporting completion, not a controller reporting nothing, and
    // it must not fall into the 沒有回報任何監控項目 branch.
    final readiness = Readiness.decode(_diesel, 0x04, 0x00);
    expect(readiness.complete, isEmpty, reason: 'nothing named finished either');
    expect(readiness.saysNothing, isFalse);

    await _pumpReadiness(tester, readiness);

    expect(find.textContaining('都已完成'), findsOneWidget);
    expect(find.textContaining('沒有回報任何監控項目'), findsNothing);
  });

  testWidgets('all zeroes is still silence, not a pass', (tester) async {
    // Unchanged by any of the above, and pinned here because the fix touches
    // the branch immediately next to it.
    final readiness = Readiness.decode(_diesel, 0x00, 0x00);
    await _pumpReadiness(tester, readiness);

    expect(find.textContaining('沒有回報任何監控項目'), findsOneWidget);
    expect(find.textContaining('都已完成'), findsNothing);
  });
}
