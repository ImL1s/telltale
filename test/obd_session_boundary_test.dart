import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torque_obd/obd/session_boundary.dart';
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

  test(
    'connection replacement boundary is synchronous before first await',
    () async {
      final container = await _container();
      addTearDown(container.dispose);
      final session = container.read(obdSessionProvider.notifier);
      final boundaries = <ObdSessionBoundary>[];
      final sub = session.sessionBoundaries.listen(boundaries.add);
      addTearDown(sub.cancel);

      final connecting = session.connectDemo();
      expect(
        boundaries,
        hasLength(1),
        reason: 'the boundary must publish in the command call stack',
      );
      expect(
        boundaries.single.reason,
        ObdSessionBoundaryReason.sessionReplacement,
      );
      expect(boundaries.single.generation, 0);
      expect(await connecting, isTrue);
    },
  );

  test('user disconnect closes the old generation synchronously', () async {
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);
    expect(await session.connectDemo(), isTrue);
    final generation = session.generation;
    final boundaries = <ObdSessionBoundary>[];
    final sub = session.sessionBoundaries.listen(boundaries.add);
    addTearDown(sub.cancel);

    final disconnecting = session.disconnect();
    expect(
      boundaries,
      hasLength(1),
      reason: 'recording acceptance closes before teardown awaits',
    );
    expect(boundaries.single.reason, ObdSessionBoundaryReason.userDisconnect);
    expect(boundaries.single.generation, generation);
    expect(boundaries.single.observedAtUtc.isUtc, isTrue);
    await disconnecting;
  });

  test('boundary stream is synchronous broadcast', () async {
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);
    var first = 0;
    var second = 0;
    final a = session.sessionBoundaries.listen((_) => first++);
    final b = session.sessionBoundaries.listen((_) => second++);
    addTearDown(a.cancel);
    addTearDown(b.cancel);

    final future = session.connectDemo();
    expect((first, second), (1, 1));
    await future;
  });
}
