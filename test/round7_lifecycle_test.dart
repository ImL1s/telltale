/// What an interruption is allowed to leave on screen.
///
/// Three round-7 findings meet here, and all three are about a check that
/// samples rather than counts, or a wipe that says nothing.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

void _background(TestWidgetsFlutterBinding binding) {
  binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
}

void _foreground(TestWidgetsFlutterBinding binding) {
  binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  tearDown(() {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  test('hidden is a foreground boundary and hidden then paused counts once',
      () async {
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);
    final before = session.pauseEpoch;

    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(session.isForeground, isFalse);
    expect(session.pauseEpoch, before + 1);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(
      session.pauseEpoch,
      before + 1,
      reason: 'mobile hidden -> paused is one suspension, not two',
    );
  });

  test('R7 F-10: backgrounding clears the gauges and says the session paused',
      () async {
    // The guard here was inverted, which reversed both halves: the empty
    // snapshot was withheld on an ordinary pause — so returning to the app
    // showed pre-pause values at full brightness until the first new reading —
    // and published on the one occasion it should not have been. Neither
    // direction had a test, which is why it survived a round.
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);
    expect(await session.connectDemo(), isTrue);

    for (var i = 0; i < 40 && session.engine!.current.readings.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(session.engine!.current.readings, isNotEmpty,
        reason: 'sanity: there are live values to clear');

    final seen = <int>[];
    final sub = session.telemetryStream.listen((s) => seen.add(s.readings.length));
    addTearDown(sub.cancel);

    _background(binding);
    await Future<void>.delayed(const Duration(milliseconds: 600));

    expect(session.isForeground, isFalse);
    expect(seen.last, 0,
        reason: 'the last thing published before the app went away must say '
            'that nothing on screen is current');
  });

  test('R7 F-15: a suspension between two checkpoints is still counted',
      () async {
    // `isForeground` is a sample. A suspension that begins and ends between
    // two checkpoints passes every check, and the verdict is assembled across
    // a gap nobody owned — which is the exact case the check's own comment
    // describes. A counter cannot be stepped over.
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);
    expect(await session.connectDemo(), isTrue);

    final before = session.pauseEpoch;
    _background(binding);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    _foreground(binding);
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(session.isForeground, isTrue,
        reason: 'sampling `isForeground` now would see nothing wrong — which '
            'is the whole point');
    expect(session.pauseEpoch, greaterThan(before),
        reason: 'the interruption left a mark whether or not anyone was '
            'looking');
  });

  test('R9-codex C-04: the session hands the client a lease, not a snapshot',
      () async {
    // The companion to the engine-level test in `round5_triggers_test.dart`.
    // That one proves `clearDtcs` carries its lease to the write; this one
    // proves the predicate on the other end actually reads it — otherwise the
    // threading is inert and the engine test passes on its own fixture.
    //
    // Codex's finding was that `mayTransmit` sampled "foreground now". The
    // refusal was real while the app was away and evaporated on resume, so a
    // Mode 04 queued for an abandoned screen went out and erased the vehicle's
    // fault memory. Below: a real background/resume through the binding, and
    // then the question asked with a lease taken before it.
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);
    expect(await session.connectDemo(), isTrue);

    final lease = session.pauseEpoch;
    final mayTransmit = session.engine!.client.mayTransmit;
    expect(mayTransmit, isNotNull, reason: 'sanity: the session installed one');
    expect(mayTransmit!(lease), isTrue,
        reason: 'sanity: a current lease is allowed, or the rest proves '
            'nothing but that everything is refused');

    _background(binding);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    _foreground(binding);
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(session.isForeground, isTrue,
        reason: 'sanity: the old question now answers yes again');
    expect(mayTransmit(lease), isFalse,
        reason: 'the work that lease belongs to was abandoned before the '
            'interruption and coming back does not re-authorise it');
    expect(mayTransmit(session.pauseEpoch), isTrue,
        reason: 'and work started after the resume is not punished for it');
    expect(mayTransmit(null), isTrue,
        reason: 'the polling loop holds no lease; its writes are repeatable '
            'reads and refusing them would stop the gauges');
  });

  test(
    'resume keeps safety closed until ATRV; pre-pause telemetry is cleared',
    () async {
      // Codex P1: opening isForeground while `_pauseNow` still awaited
      // engine.stop() left a pre-pause stopped-speed reading authoritative
      // for seconds, so record/share could mint permits on stale authority.
      final container = await _container();
      addTearDown(container.dispose);
      final session = container.read(obdSessionProvider.notifier);
      expect(await session.connectDemo(), isTrue);

      for (var i = 0; i < 40 && session.engine!.current.readings.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(session.engine!.current.readings, isNotEmpty);

      final seen = <int>[];
      final sub =
          session.telemetryStream.listen((s) => seen.add(s.readings.length));
      addTearDown(sub.cancel);

      _background(binding);
      // Resume immediately — before pause's stop is guaranteed to finish —
      // and assert the safety gate is still closed with empty telemetry.
      _foreground(binding);
      expect(
        session.isForeground,
        isFalse,
        reason: 'foreground must stay closed until resume validation finishes',
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        seen.isNotEmpty && seen.last == 0,
        isTrue,
        reason: 'pre-pause readings must be revoked on the resume edge',
      );

      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(
        session.isForeground,
        isTrue,
        reason: 'after ATRV the safety gate opens for a live session',
      );
      expect(
        container.read(obdSessionProvider).phase,
        ConnectionPhase.connected,
      );
    },
  );

  test('R7 F-15: an interrupted scan says so instead of going blank', () async {
    // The wipe set a bare empty state, so the screen returned to 尚未掃描 with
    // nothing said — contradicting the same function's rule that an unnamed
    // absence and a timeout are indistinguishable on screen. A user who
    // backgrounded the app mid-scan and came back to a blank panel has no way
    // to know whether the scan ran.
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);
    expect(await session.connectDemo(), isTrue);

    final notifier = container.read(dtcScanProvider.notifier);
    final scan = notifier.scan();
    _background(binding);
    await scan;

    final state = container.read(dtcScanProvider);
    // Unconditional. This used to read `if (!state.hasScanned) { ... }`, a
    // hedge written because I was not sure the interruption would be detected
    // — and a hedge in a test is a false green with extra steps. With the
    // supersession check disabled the scan completes, `hasScanned` is true,
    // neither assertion runs, and the suite reports success.
    //
    // That is the fourth time this project has produced a test that asserts
    // nothing, and the second in a file whose two other tests both carry an
    // explicit `sanity:` control for exactly this reason.
    expect(state.hasScanned, isFalse,
        reason: 'sanity: the interruption has to be detected at all, or '
            'everything below is about a scan that quietly finished');
    expect(state.error, isNotNull,
        reason: 'a scan that was abandoned must name itself; a blank panel '
            'is indistinguishable from never having scanned');
    expect(state.error, contains('中斷'));
  });
}
