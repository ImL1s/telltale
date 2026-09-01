import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torque_obd/obd/pid/pid.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/state/pid_mutation_lock.dart';
import 'package:torque_obd/state/pid_registry.dart';

Future<ProviderContainer> _container([
  Map<String, Object> initial = const {},
]) async {
  SharedPreferences.setMockInitialValues(initial);
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('active membership/order mutations fail closed while locked', () async {
    final container = await _container();
    addTearDown(container.dispose);
    final lock = container.read(pidMutationLockProvider);
    final token = lock.tryAcquire('recorder')!;
    final active = container.read(activePidsProvider.notifier);
    final before = List<Pid>.of(container.read(activePidsProvider));
    final candidate = PidLibrary.all.firstWhere(
      (pid) => !before.any((current) => current.id == pid.id),
    );

    final outcomes = <PidMutationOutcome>[
      await active.add(candidate),
      await active.toggle(before.first),
      await active.remove(before.first),
      await active.insert(0, candidate),
      await active.replace(before.first, candidate),
      await active.reorder(0, before.length),
    ];

    expect(outcomes, everyElement(const PidMutationOutcome.locked()));
    expect(container.read(activePidsProvider), before);
    lock.release(token);
  });

  test(
    'definition import/edit/delete fail closed without persistence writes',
    () async {
      final container = await _container();
      addTearDown(container.dispose);
      final lock = container.read(pidMutationLockProvider);
      final token = lock.tryAcquire('recorder')!;
      final registry = container.read(pidRegistryProvider.notifier);
      const custom = Pid(
        name: 'Custom',
        shortName: 'C',
        modeAndPid: '0122',
        equation: 'A',
        minValue: 0,
        maxValue: 255,
        units: '',
        header: kDefaultHeader,
        isCustom: true,
      );

      final imported = await registry.upsertAllCustom([custom]);
      expect(imported.failure, PidMutationFailure.locked);
      expect(imported.landed, 0);
      expect(
        container.read(pidRegistryProvider).where((p) => p.isCustom),
        isEmpty,
      );

      final removed = await registry.removeCustom(custom);
      expect(removed, const PidMutationOutcome.locked());
      expect(
        (await SharedPreferences.getInstance()).getStringList('custom_pids_v1'),
        isNull,
        reason: 'a rejected mutation performs no persistence write',
      );
      lock.release(token);
    },
  );

  test('the matching token releases and mutations work again', () async {
    final container = await _container();
    addTearDown(container.dispose);
    final lock = container.read(pidMutationLockProvider);
    final token = lock.tryAcquire('recorder')!;
    lock.release(token);

    final active = container.read(activePidsProvider.notifier);
    final before = List<Pid>.of(container.read(activePidsProvider));
    final removed = await active.remove(before.first);
    expect(removed.applied, isTrue);
    expect(container.read(activePidsProvider), hasLength(before.length - 1));
  });

  test(
    'identity replacement commits atomically before Start can lock',
    () async {
      const stored =
          '{"name":"Boost","shortName":"BST",'
          '"modeAndPid":"010B","equation":"A","minValue":0,'
          '"maxValue":300,"units":"kPa","header":"7E0",'
          '"isCustom":true,"variant":"boost"}';
      final container = await _container({
        'custom_pids_v1': <String>[stored],
        'active_pid_ids_v1': <String>['custom:7E0:010B#boost'],
      });
      addTearDown(container.dispose);
      final previous = container
          .read(pidRegistryProvider)
          .singleWhere((pid) => pid.isCustom);
      final replacement = previous.copyWith(modeAndPid: '0105');
      expect(container.read(activePidsProvider), [previous]);

      final mutation = container
          .read(pidRegistryProvider.notifier)
          .replaceCustom(previous, replacement);
      final lock = container.read(pidMutationLockProvider);
      final startToken = lock.tryAcquire('start-after-commit');

      expect(
        startToken,
        isNotNull,
        reason: 'the mutation yielded at persistence',
      );
      expect(container.read(pidRegistryProvider).where((pid) => pid.isCustom), [
        replacement,
      ], reason: 'there is never a delete-only intermediate registry state');
      expect(container.read(activePidsProvider), [
        replacement,
      ], reason: 'the dashboard replacement is synchronous and keeps its slot');
      expect(await mutation, const PidMutationOutcome.applied());
      lock.release(startToken!);
    },
  );
}
