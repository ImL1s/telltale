/// Fault-code scan results outlive a tab switch, and only a tab switch.
///
/// Fable found this on a device: scan the car, tap 性能, tap back, and the
/// screen says 尚未掃描. The results lived in `_DtcScreenState`, and the shell
/// is an ordinary `ShellRoute` driven by `context.go`, so changing tabs
/// disposes the screen. Ten seconds of scanning on a real car did not survive
/// a glance at the dashboard.
///
/// The obvious fix — hoist it into a provider — would have traded that for a
/// far worse bug, because the widget-local state was buying something real:
/// results could never outlive the connection that produced them. A verdict
/// about the car in front of you is not a verdict about the next one, and a
/// stale green "no fault codes" panel is the most dangerous thing this screen
/// can show. Both properties are asserted here.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/obd/dtc/dtc.dart';
import 'package:torque_obd/state/dtc_scan.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_registry.dart';

Future<ProviderContainer> _container() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DTC scan results', () {
    test('R9-codex H-03: an interruption during the census retires the scan',
        () async {
      // Codex, on a regression I shipped this morning. The census await was
      // inserted *above* the block that captures the scan's deadline,
      // connection generation and pause epoch — so the one step that can take
      // an unbounded amount of time on a slow adapter was outside every token
      // the rest of the scan is held to.
      //
      //   tap 掃描      → census begins, four commands on a slow adapter
      //   press Home   → pause epoch advances
      //   return       → census finishes
      //   ← the tokens are captured *here*, already stale, and the scan
      //     proceeds as though nothing had happened
      //
      // 20 seconds of census plus a 45-second budget is a 65-second scan that
      // advertises 45, and the interruption leaves no mark at all. The fix for
      // one hole opened another one line above itself.
      final binding = TestWidgetsFlutterBinding.instance;
      final container = await _container();
      addTearDown(container.dispose);
      expect(await container.read(obdSessionProvider.notifier).connectDemo(),
          isTrue);

      final notifier = container.read(dtcScanProvider.notifier);
      // Not awaited: the tokens are captured synchronously and the first
      // suspension point is the census, which is the window this is about.
      final running = notifier.scan();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await running;

      final after = container.read(dtcScanProvider);
      expect(after.hasScanned, isFalse,
          reason: 'a scan that spanned an interval nobody owned is not a '
              'result about this car');
      expect(after.error, contains('中斷'),
          reason: 'and it says so, rather than going quietly blank');
    });

    test('survive the screen being disposed and rebuilt', () async {
      final container = await _container();
      addTearDown(container.dispose);

      expect(await container.read(obdSessionProvider.notifier).connectDemo(),
          isTrue);
      await container.read(dtcScanProvider.notifier).scan();

      final afterScan = container.read(dtcScanProvider);
      expect(afterScan.hasScanned, isTrue,
          reason: 'the demo vehicle answers, so this scan should complete');

      // A tab switch disposes the widget, not the provider. Reading again is
      // what the rebuilt screen does on its first frame.
      final afterRebuild = container.read(dtcScanProvider);
      expect(afterRebuild.hasScanned, isTrue);
      expect(afterRebuild.scannedAt, equals(afterScan.scannedAt),
          reason: 'the same scan, not a silently repeated one');
      expect(
        afterRebuild.results.keys.toSet(),
        equals(afterScan.results.keys.toSet()),
      );
    });

    test('do not outlive the connection that produced them', () async {
      final container = await _container();
      addTearDown(container.dispose);

      final session = container.read(obdSessionProvider.notifier);
      expect(await session.connectDemo(), isTrue);
      await container.read(dtcScanProvider.notifier).scan();
      expect(container.read(dtcScanProvider).hasScanned, isTrue);

      await session.disconnect();
      // The listener fires on the session's state change; give it the
      // microtask it needs rather than assuming ordering.
      await Future<void>.delayed(Duration.zero);

      final after = container.read(dtcScanProvider);
      expect(after.hasScanned, isFalse,
          reason: 'a verdict about the car that was connected is not a verdict '
              'about the next one');
      expect(after.results, isEmpty);
      expect(after.vin, isNull);
      expect(
        after.verdict,
        ScanVerdict.notScanned,
        reason: 'and nothing on screen may claim a result',
      );
    });
  });

  group('the scan waits for the evidence it reasons from', () {
    test('R9-cursor: a scan started immediately still takes the census',
        () async {
      // Every test for the silence check called `discoverResponders()` by
      // hand first. In the app nobody does: it is fired unawaited at connect,
      // and a scan started promptly — which is exactly what someone does
      // after plugging in — found `_responders` null and skipped the check
      // entirely. One controller's clean `43 00` closed the class while
      // another sat silent with a real fault, which is the whole thing the
      // census exists to prevent.
      //
      // The hole was invisible because the tests took the evidence the app
      // never waited for.
      final container = await _container();
      addTearDown(container.dispose);
      final session = container.read(obdSessionProvider.notifier);
      expect(await session.connectDemo(), isTrue);

      // No manual census, and no delay: straight to a scan, as the UI does.
      await container.read(dtcScanProvider.notifier).scan();

      // This asserts the postcondition, not the race. The demo answers fast
      // enough that the unawaited census usually lands before a scan finishes
      // anyway, so removing the await leaves this green — the race needs a
      // transport slow enough to lose it, and `ObdSession` takes no injected
      // transport. Recorded in `TEST_EVIDENCE.md` rather than dressed up as
      // coverage it does not give.
      expect(session.engine!.responders, isNotNull,
          reason: 'the scan reasons from the census, so it has to have one '
              'before it starts — not whenever the unawaited call lands');
      expect(container.read(dtcScanProvider).hasScanned, isTrue,
          reason: 'and taking it must not break an ordinary scan');
    });
  });

  group('a refresh does not leave the old verdict on screen', () {
    test('R8-14: scanning again clears the previous result first', () async {
      // GPT-5.6 Pro. `copyWith(loading: true)` kept `results`, `scannedAt` and
      // `vin`, so `hasScanned` stayed true and the screen went on rendering
      // the old green 未偵測到故障碼 for the whole scan — a verified all-clear
      // about a car the app was at that moment re-interrogating, and which may
      // be a different car entirely.
      //
      // The failed-refresh case was already handled this way: a scan that
      // could not run must not leave the old panel standing. The *running*
      // case was not.
      final container = await _container();
      addTearDown(container.dispose);

      final session = container.read(obdSessionProvider.notifier);
      expect(await session.connectDemo(), isTrue);
      final notifier = container.read(dtcScanProvider.notifier);
      await notifier.scan();
      expect(container.read(dtcScanProvider).hasScanned, isTrue,
          reason: 'sanity: there is a verdict to be stale');

      final second = notifier.scan();
      final during = container.read(dtcScanProvider);
      expect(during.loading, isTrue);
      expect(during.hasScanned, isFalse,
          reason: 'nothing may claim a result while the question is being '
              'asked again');
      expect(during.results, isEmpty);
      expect(during.verdict, ScanVerdict.notScanned);
      await second;
    });
  });

  group('a category that stopped part-way', () {
    test('still counts and reports what it read', () {
      // Codes read before a scan had to be abandoned were retained on the
      // exception and exposed on the result, and then counted by nobody: a
      // real P0300 from a named controller could sit in memory while the
      // screen said 已回應的項目沒有故障碼. Incomplete coverage is a reason to
      // qualify a finding, never to hide it.
      final found = DtcDecoder.decodePair(0x03, 0x00, DtcKind.pending)!;
      expect(found.code, 'P0300', reason: 'sanity: the fixture is the code '
          'this test is about');
      final state = DtcScanState(
        scannedAt: DateTime(2026, 8, 15),
        results: {
          DtcKind.stored: const DtcCategoryResult.codes([]),
          DtcKind.pending: DtcCategoryResult.failed(
            DtcReadException('有 1 個控制器拒絕回答', partial: [found]),
          ),
          DtcKind.permanent: const DtcCategoryResult.codes([]),
        },
      );

      expect(state.totalCodes, 1,
          reason: 'the fault was observed, whatever the coverage');
      expect(
        state.verdict,
        ScanVerdict.faultsFound,
        reason: 'a scan that saw a fault cannot report an absence of faults, '
            'even a qualified one',
      );
      expect(state.results[DtcKind.pending]!.partial, equals([found]));
    });
  });

  test('a scan is bounded, and says which categories it did not reach', () {
    // Nothing bounded a scan: each command had its own timeout, and a category
    // meeting a controller that answers "still working" retries. A
    // pathological adapter could hold the spinner for minutes with no way out
    // but killing the app.
    expect(
      DtcScanNotifier.budget.inSeconds,
      lessThanOrEqualTo(60),
      reason: 'a spinner nobody can escape is its own failure mode',
    );

    // What it did reach is kept, and what it did not is named — the two look
    // identical on screen otherwise.
    final ranOut = DtcScanState(
      scannedAt: DateTime(2026, 8, 15),
      results: {
        DtcKind.stored: const DtcCategoryResult.codes([]),
        DtcKind.pending: const DtcCategoryResult.failed(
          DtcReadException('掃描已達時間上限，這個類別沒有讀取到。請重新掃描。',
              kind: DtcReadFailure.noAnswer),
        ),
        DtcKind.permanent: const DtcCategoryResult.codes([]),
      },
    );
    expect(
      ranOut.verdict,
      ScanVerdict.partialClean,
      reason: 'a category that ran out of time is unanswered, not clean',
    );
  });
}
