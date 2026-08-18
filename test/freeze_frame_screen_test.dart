/// The freeze-frame card, and the two things it must never do.
///
/// It must not appear when there is no frame — an empty list is also what a
/// timeout and an unsupported service produce, and a card headed 故障發生當下的
/// 車況 with nothing under it reads as "we looked and the car was fine".
///
/// And it must name the code the snapshot belongs to. A car with three stored
/// codes has a frame belonging to exactly one of them; a snapshot read against
/// the wrong fault sends somebody after the wrong part, which is worse than
/// having no snapshot at all.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/core/theme/app_theme.dart';
import 'package:torque_obd/obd/dtc/dtc.dart';
import 'package:torque_obd/obd/freeze_frame.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
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

const _misfire = Dtc(
  code: 'P0301',
  category: DtcCategory.powertrain,
  kind: DtcKind.stored,
  sourceId: '7E8',
  isManufacturerSpecific: false,
);

FreezeFrame _frame({
  int undecodable = 0,
  int unread = 0,
  List<FreezeReading>? readings,
}) =>
    FreezeFrame(
      source: '7E8',
      frameNumber: 0,
      cause: _misfire,
      readings: readings ??
          [
            const FreezeReading(
                pid: PidLibrary.engineRpm, value: 2856, raw: [0x2C, 0xA0]),
            const FreezeReading(
                pid: PidLibrary.coolantTemp, value: 91, raw: [131]),
            const FreezeReading(
                pid: PidLibrary.mafRate, value: 18.4, raw: [0x07, 0x30]),
          ],
      undecodable: undecodable,
      unread: unread,
    );

Future<void> _pump(WidgetTester tester, List<FreezeFrame> frames) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        dtcScanProvider.overrideWith(() => _FixedScan(DtcScanState(
              scannedAt: DateTime(2026, 8, 17),
              results: {
                DtcKind.stored: const DtcCategoryResult.codes([_misfire]),
              },
              freezeFrames: frames,
            ))),
        obdSessionProvider.overrideWith(_FixedSession.new),
      ],
      child: MaterialApp(theme: AppTheme.dark(), home: const DtcScreen()),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('no frame means no card, not an empty one', (tester) async {
    await _pump(tester, const []);
    expect(find.textContaining('故障發生當下'), findsNothing,
        reason: 'an empty list is also a timeout and an unsupported service; '
            'a heading over nothing reads as a clean bill of health');
  });

  testWidgets('the snapshot says which fault it belongs to', (tester) async {
    await _pump(tester, [_frame()]);
    expect(find.textContaining('故障發生當下'), findsOneWidget);
    expect(find.textContaining('P0301'), findsWidgets);
    expect(find.text('控制器 7E8'), findsWidgets);
  });

  testWidgets('the frozen values are shown with their units', (tester) async {
    await _pump(tester, [_frame()]);
    expect(find.text('2856 rpm'), findsOneWidget);
    expect(find.text('91 °C'), findsOneWidget);
    // A tenth for a measurement, none for a count. Both on screen at once, so
    // a formatter that rounded everything to integers would lose the 18.4.
    expect(find.text('18.4 g/s'), findsOneWidget);
  });

  testWidgets('it warns that clearing destroys it', (tester) async {
    // The clear button is on this same screen, two hundred lines up, and this
    // is the only panel whose contents that button makes unrecoverable.
    await _pump(tester, [_frame()]);
    expect(find.textContaining('清除故障碼會一併銷毀'), findsOneWidget);
  });

  testWidgets('what it could not decode is said, not hidden', (tester) async {
    await _pump(tester, [_frame(undecodable: 2)]);
    expect(find.textContaining('另有 2 個項目'), findsOneWidget);
  });

  testWidgets('and nothing is said when there was nothing to say',
      (tester) async {
    await _pump(tester, [_frame()]);
    expect(find.textContaining('另有'), findsNothing,
        reason: 'a permanent caveat is noise that trains people to skip it');
  });

  testWidgets('a frame with no readable values says so rather than showing '
      'an empty table', (tester) async {
    await _pump(tester, [_frame(readings: const [], undecodable: 4)]);
    expect(find.textContaining('沒有本 App 能解讀的項目'), findsOneWidget);
  });

  group('the clear dialog', () {
    // The card's warning is somewhere up the page and may be scrolled off. The
    // dialog is where the decision happens, and the frame is the only thing on
    // this screen a clear makes unreadable until the fault happens again.
    Future<void> openDialog(WidgetTester tester) async {
      await tester.tap(find.text('清除'));
      await tester.pumpAndSettle();
    }

    testWidgets('names the frames it is about to destroy', (tester) async {
      await _pump(tester, [_frame()]);
      await openDialog(tester);
      expect(find.textContaining('P0301 的凍結幀'), findsOneWidget);
      expect(find.textContaining('讀不回來'), findsOneWidget);
    });

    testWidgets('says nothing about frames when there are none',
        (tester) async {
      // A warning that appears every time is one people learn to tap past,
      // which is the failure mode of warning about everything.
      await _pump(tester, const []);
      await openDialog(tester);
      expect(find.textContaining('凍結幀'), findsNothing);
      // …and the dialog is still the dialog.
      expect(find.text('確定清除'), findsOneWidget);
    });
  });
}
