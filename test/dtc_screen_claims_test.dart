/// The sentences on the fault-code screen, held where a driver reads them.
///
/// Round 39 raised the same finding four separate times, about four different
/// rules: each was tested on the model and not at the call site, so deleting
/// the branch that renders it left the whole suite green. That is the third
/// time this exact shape has appeared in this project — the gauge face, the
/// readiness sentence, and now these — and it has a name: moving a rule
/// somewhere testable is not the same as testing it.
///
/// So this file is deliberately all call sites. Every test here goes red when
/// the widget stops saying what the model says.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/core/theme/app_theme.dart';
import 'package:torque_obd/obd/dtc/dtc.dart';
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

Dtc _code(String code) => Dtc(
      code: code,
      category: DtcCategory.powertrain,
      kind: DtcKind.stored,
      sourceId: '7E8',
      isManufacturerSpecific: code[1] == '1' || code[1] == '3',
    );

Future<void> _pump(WidgetTester tester, DtcScanState scan) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        dtcScanProvider.overrideWith(() => _FixedScan(scan)),
        obdSessionProvider.overrideWith(_FixedSession.new),
      ],
      child: MaterialApp(theme: AppTheme.dark(), home: const DtcScreen()),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

DtcScanState _withCodes(List<Dtc> codes) => DtcScanState(
      scannedAt: DateTime(2026, 8, 17),
      results: {DtcKind.stored: DtcCategoryResult.codes(codes)},
    );

void main() {
  group('an unknown code says which subsystem it is in', () {
    testWidgets('rather than the category label, which fits every code',
        (tester) async {
      // The user-visible half of the J2012 subsystem fallback. `P0492` has no
      // description here; the old sentence was 動力系統相關故障, true of every
      // code on the screen and therefore worth nothing to somebody standing in
      // front of a car. Deleting the branch left the suite green because the
      // only tests were on `Dtc.subsystem`.
      await _pump(tester, _withCodes([_code('P0492')]));
      expect(find.textContaining('輔助排放控制'), findsOneWidget);
      expect(find.textContaining('動力系統相關故障'), findsNothing);
    });

    testWidgets('and says plainly that it has no detail for it',
        (tester) async {
      // The subsystem narrows where to look; it is not a description, and the
      // sentence must not read as though it were one.
      await _pump(tester, _withCodes([_code('P0492')]));
      expect(find.textContaining('沒有這一碼的詳細說明'), findsOneWidget);
    });

    testWidgets('a described code still gets its description', (tester) async {
      await _pump(tester, _withCodes([_code('P0301')]));
      expect(find.textContaining('失火'), findsWidgets);
      expect(find.textContaining('沒有這一碼的詳細說明'), findsNothing);
    });

    testWidgets('a manufacturer code claims no subsystem', (tester) async {
      // In `P1` the third digit means whatever the manufacturer decided, so
      // there is nothing to narrow and the screen says so instead.
      await _pump(tester, _withCodes([_code('P1128')]));
      expect(find.textContaining('原廠自訂碼'), findsOneWidget);
      expect(find.textContaining('燃油與空氣計量'), findsNothing);
    });
  });

  group('the readiness card reports each controller as it answered', () {
    DtcScanState withMil(MilStatus mil) => DtcScanState(
          scannedAt: DateTime(2026, 8, 17),
          results: const {},
          mil: mil,
        );

    const readiness = Readiness(
      ignition: IgnitionType.spark,
      states: {ReadinessMonitor.misfire: ReadinessState.complete},
    );

    testWidgets('a controller that claims codes is not reported as clean',
        (tester) async {
      // Forcing this sentence to its negative branch — every controller
      // reported as 沒有已確認的故障碼 whatever PID 01 said — left the whole
      // suite green. That is a per-controller false all-clear no test could
      // see, on the card that exists to question the scan's own verdict.
      await _pump(
        tester,
        withMil(const MilStatus({
          '7E8': MilSummary(
              milOn: true, confirmedCount: 3, readiness: readiness),
        })),
      );
      expect(find.textContaining('自報有 3 個已確認的故障碼'), findsOneWidget);
      expect(find.textContaining('自報沒有已確認的故障碼'), findsNothing);
    });

    testWidgets('and one that claims none says none', (tester) async {
      // The other branch, so the assertion above cannot be satisfied by a
      // sentence that is always positive.
      await _pump(
        tester,
        withMil(const MilStatus({
          '7E8': MilSummary(
              milOn: false, confirmedCount: 0, readiness: readiness),
        })),
      );
      expect(find.textContaining('自報沒有已確認的故障碼'), findsOneWidget);
    });

    testWidgets('the GPF monitor is named GPF', (tester) async {
      // The entire user-visible payload of the bit-4 rename. Flipping the label
      // back to 空調冷媒 — the exact wrong name the change exists to remove —
      // left the full suite green.
      await _pump(
        tester,
        withMil(MilStatus({
          '7E8': MilSummary(
            milOn: false,
            confirmedCount: 0,
            // C bit 4 supported: a direct-injection petrol car with a
            // particulate filter.
            readiness: Readiness.decode(0x00, 0x10, 0x00),
          ),
        })),
      );
      expect(find.textContaining('汽油微粒濾清器'), findsOneWidget);
      expect(find.textContaining('空調冷媒'), findsNothing);
    });
  });
}
