/// The clear button, as rendered.
///
/// Cursor round 30, F8: `ClearOutcome.repeatWouldHarm` and
/// `DtcReadException.repeatWouldHarm` were both well tested, and the screen's
/// use of them was not. Deleting the conjunct from `onPressed` left the entire
/// suite green — the round-29 failure mode, on the exact control the commit
/// was about.
///
/// Buildable without a session because the screen now renders the clear
/// entirely from `DtcScanState`. That was not true a few commits ago, and the
/// fact that it is now is what makes this test possible: a connected session
/// cannot be driven from `testWidgets` at all, since the fake-async clock
/// never advances for the poller's real delays.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/core/theme/app_theme.dart';
import 'package:torque_obd/obd/dtc/dtc.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/dtc_scan.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/ui/screens/dtc/dtc_screen.dart';

/// A scan state held still, so the screen can be asked what it renders.
class _FixedScan extends DtcScanNotifier {
  _FixedScan(this.initial);
  final DtcScanState initial;
  @override
  DtcScanState build() => initial;
}

/// A session that reports itself connected without owning anything.
class _FixedSession extends ObdSession {
  @override
  ObdConnectionState build() => const ObdConnectionState(
        phase: ConnectionPhase.connected,
        kind: TransportKind.demo,
        deviceName: 'Demo ECU',
      );
}

DtcScanState _scanWith({
  required bool clearing,
  required bool repeatWouldHarm,
  String? message,
}) =>
    DtcScanState(
      scannedAt: DateTime(2026, 8, 17),
      results: {
        DtcKind.stored: const DtcCategoryResult.codes([
          Dtc(
            code: 'P0301',
            category: DtcCategory.powertrain,
            kind: DtcKind.stored,
            sourceId: '7E8',
            isManufacturerSpecific: false,
          ),
        ]),
      },
      clearing: clearing,
      clearRepeatWouldHarm: repeatWouldHarm,
      clearMessage: message,
    );

Future<void> _pump(WidgetTester tester, DtcScanState scan) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        dtcScanProvider.overrideWith(() => _FixedScan(scan)),
        obdSessionProvider.overrideWith(_FixedSession.new),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: const DtcScreen(),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _pumpCompressedLandscape(
  WidgetTester tester,
  DtcScanState scan,
) async {
  tester.view.physicalSize = const Size(832, 384);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        dtcScanProvider.overrideWith(() => _FixedScan(scan)),
        obdSessionProvider.overrideWith(_FixedSession.new),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: const MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: Row(
              children: [
                SizedBox(width: 112, child: Text('導覽列')),
                Expanded(
                  child: Column(
                    children: [
                      SizedBox(height: 88, child: Text('錄製中 00:09')),
                      Expanded(child: DtcScreen()),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

/// The clear control, whatever its label currently is.
Finder _clearButton() => find.byType(OutlinedButton);

void main() {
  testWidgets('with codes and nothing owed, the button clears', (tester) async {
    await _pump(tester, _scanWith(clearing: false, repeatWouldHarm: false));
    expect(find.text('清除'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(_clearButton()).onPressed, isNotNull,
        reason: 'the ordinary case — there are codes and nothing was cleared');
  });

  testWidgets('while a clear is on the wire, it says so and cannot be pressed',
      (tester) async {
    await _pump(tester, _scanWith(clearing: true, repeatWouldHarm: false));
    expect(find.text('清除中…'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(_clearButton()).onPressed, isNull,
        reason: 'a second tap queues a second global 04 behind the first');
  });

  testWidgets('when a repeat would harm, it says what to do instead',
      (tester) async {
    // The rule this file exists for. A dead control with no explanation reads
    // as an app that has stopped working; this one names the action that
    // brings it back.
    await _pump(
      tester,
      _scanWith(
        clearing: false,
        repeatWouldHarm: true,
        message: '已有控制器回報清除完成，但其餘控制器無法確認。',
      ),
    );
    expect(find.text('請先重新掃描'), findsOneWidget);
    expect(find.text('清除'), findsNothing);
    expect(tester.widget<OutlinedButton>(_clearButton()).onPressed, isNull,
        reason: 'this is the tap that costs a drive cycle');
  });

  testWidgets('an outcome that says to retry keeps the button pressable',
      (tester) async {
    // Cursor round 31. Every case in this file paired a live button with *no*
    // message and a dead button with one, so the screen could have been wired
    // `onPressed: clearMessage != null ? null : _clear` and stayed green —
    // disabling the one refusal the field guide tells people to retry.
    //
    // `04 -> ?` is the adapter saying, in its own voice, that nothing went to
    // the bus. Nothing was erased, a retry is free, and the message says so.
    await _pump(
      tester,
      _scanWith(
        clearing: false,
        repeatWouldHarm: false,
        message: '清除失敗，沒有控制器接受指令。可以再試一次。',
      ),
    );
    expect(find.text('清除'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(_clearButton()).onPressed, isNotNull,
        reason: 'the sentence and the control have to agree in this direction '
            'too — a dead button under 可以再試一次 reads as a broken app');
  });

  testWidgets('the outcome stays on screen, and is selectable', (tester) async {
    // These messages name controllers that appear nowhere else in the app, so
    // the text has to be copyable and must not be a four-second SnackBar.
    const said = '已有控制器回報清除完成，但其餘控制器無法確認。';
    await _pump(
      tester,
      _scanWith(clearing: false, repeatWouldHarm: true, message: said),
    );
    expect(find.text(said), findsOneWidget);
    expect(
      find.byWidgetPredicate((w) => w is SelectableText && w.data == said),
      findsOneWidget,
    );
  });

  testWidgets('200 percent short landscape keeps the DTC header scrollable',
      (tester) async {
    await _pumpCompressedLandscape(
      tester,
      _scanWith(
        clearing: false,
        repeatWouldHarm: true,
        message: '已有控制器回報清除完成，但其餘控制器無法確認。'
            '請先重新掃描，確認已儲存、待確認與永久故障碼的最新狀態。',
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('故障碼'), findsOneWidget);
    expect(find.text('請先重新掃描'), findsOneWidget);
    expect(find.byTooltip('關閉'), findsOneWidget);

    final pageScroll = find.byKey(const ValueKey('dtc-page-scroll'));
    expect(pageScroll, findsOneWidget);
    await tester.drag(pageScroll, const Offset(0, -220));
    await tester.pump();
    expect(tester.takeException(), isNull);

    final dismiss = find.widgetWithIcon(IconButton, Icons.close);
    await Scrollable.ensureVisible(
      tester.element(dismiss),
      alignment: 0.5,
    );
    await tester.pump();
    expect(dismiss.hitTestable(), findsOneWidget);
    await tester.tap(dismiss);
    await tester.pump();
    expect(find.byTooltip('關閉'), findsNothing,
        reason: 'the compressed layout must retain the clear-result action');
    expect(
      tester.widget<OutlinedButton>(_clearButton()).onPressed,
      isNull,
      reason: 'dismissing the result must not remove the repeat-clear lock',
    );
  });
}
