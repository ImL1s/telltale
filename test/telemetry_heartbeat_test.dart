/// Staleness is a statement about now, so something has to ask again.
///
/// The model layer was taught to measure against a wall clock, which fixed the
/// *answer*. Nothing fixed the *question*: the screens re-evaluated staleness
/// only when a new snapshot arrived, and snapshots stop arriving in exactly the
/// situations staleness exists for — the polling loop's exception path returns
/// without publishing, a protocol re-search runs silent for 25 seconds, a
/// wedged adapter answers nothing at all.
///
/// Fable found this on a device: after freezing the adapter the gauges held
/// pre-freeze values at full brightness for three minutes, and the only thing
/// that dimmed them was switching tabs, because that forced a rebuild. Pixel
/// sampling confirmed the dimming logic itself was fine.
///
/// The same clock covers two other frozen readouts, which is why they are
/// asserted together: the throughput pill already decays *when read*, and
/// adapter voltage already expires *in its getter*. Both were correct and both
/// were invisible, because the snapshot the UI held was a set of scalars copied
/// at publish time and nobody was asking for a new one.
///
/// **This file's first version asserted the wrong contract**, and Codex caught
/// it in round 7. It called `engine.stop()` to model a frozen adapter, then
/// required emissions to continue afterwards — so it pinned "a stopped engine
/// keeps publishing" as desired behaviour, and the heartbeat duly republished a
/// paused session's retained readings one second after the screen was cleared.
///
/// A deliberately stopped engine and a running one whose link has gone silent
/// are opposite states. Only the second is what the heartbeat is for.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/obd/telemetry.dart';
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

  test('a running session is re-asked, so figures age on screen', () async {
    final container = await _container();
    addTearDown(container.dispose);

    final session = container.read(obdSessionProvider.notifier);
    expect(await session.connectDemo(), isTrue);

    final seen = <TelemetrySnapshot>[];
    final sub = container.listen(
      telemetryProvider,
      (_, next) {
        final value = next.value;
        if (value != null) seen.add(value);
      },
      fireImmediately: true,
    );
    addTearDown(sub.close);
    seen.clear();

    await Future<void>.delayed(
      kTelemetryHeartbeat * 3 + const Duration(milliseconds: 300),
    );

    expect(
      seen.length,
      greaterThanOrEqualTo(2),
      reason: 'with the loop alive the UI must keep re-asking, or a frozen '
          'link looks identical to a healthy one',
    );
    // And what it re-asks for is the engine's *current* view rather than a
    // replay, so `capturedAt` moves even when no new reading has arrived.
    expect(
      seen.last.capturedAt!.isAfter(seen.first.capturedAt!),
      isTrue,
      reason: 'a replayed snapshot would carry its original timestamp and '
          'never age',
    );
  });

  test('a stopped engine is not re-asked, because it has stopped', () async {
    // The contract this file used to have backwards. `stop()` deliberately
    // retains the last readings so a resume has something to show while it
    // re-establishes — which makes `engine.current` after a stop a record of
    // the past, not a view of the present. Publishing it on a timer put a
    // paused session's 6000 rpm back on screen one second after the pause had
    // cleared it, and a user returning during the three-second voltage probe
    // saw that number looking entirely live.
    final container = await _container();
    addTearDown(container.dispose);

    final session = container.read(obdSessionProvider.notifier);
    expect(await session.connectDemo(), isTrue);

    final seen = <TelemetrySnapshot>[];
    final sub = container.listen(
      telemetryProvider,
      (_, next) {
        final value = next.value;
        if (value != null) seen.add(value);
      },
      fireImmediately: true,
    );
    addTearDown(sub.close);

    // Let it actually read something first: retained readings are the whole
    // hazard, and a stop before the first poll would prove nothing.
    for (var i = 0; i < 40 && session.engine!.current.readings.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await session.engine!.stop();
    expect(session.engine!.current.readings, isNotEmpty,
        reason: 'sanity: the readings really are retained, which is what made '
            'republishing them dangerous');
    seen.clear();

    await Future<void>.delayed(
      kTelemetryHeartbeat * 3 + const Duration(milliseconds: 300),
    );

    expect(
      seen,
      isEmpty,
      reason: 'nothing is polling, so nothing on screen may be refreshed as '
          'though it were current',
    );
  });

  test('a backgrounded session is not re-asked either', () async {
    // The same rule reached through the other door, and the one Codex's
    // trigger used: pause publishes an empty snapshot, and the heartbeat put
    // the old readings straight back.
    final container = await _container();
    addTearDown(container.dispose);

    final session = container.read(obdSessionProvider.notifier);
    expect(await session.connectDemo(), isTrue);

    final seen = <TelemetrySnapshot>[];
    final sub = container.listen(
      telemetryProvider,
      (_, next) {
        final value = next.value;
        if (value != null) seen.add(value);
      },
      fireImmediately: true,
    );
    addTearDown(sub.close);

    // Driven through the binding, because the session listens to the real
    // `AppLifecycleListener` rather than exposing a hook — and a test that
    // called a private method would not prove the wiring works.
    final binding = TestWidgetsFlutterBinding.instance;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(session.isForeground, isFalse,
        reason: 'sanity: the pause actually reached the session');
    seen.clear();

    await Future<void>.delayed(
      kTelemetryHeartbeat * 2 + const Duration(milliseconds: 300),
    );

    expect(
      seen.where((s) => s.readings.isNotEmpty),
      isEmpty,
      reason: 'the app is not in front of anyone; nothing it shows may claim '
          'to be a live reading',
    );
  });
}
