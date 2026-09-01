import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torque_obd/obd/pid/pid.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/polling_engine.dart';
import 'package:torque_obd/state/pid_mutation_lock.dart';
import 'package:torque_obd/state/pid_registry.dart';

const _custom =
    '{"name":"Custom first","shortName":"CUS",'
    '"modeAndPid":"221234","equation":"A","minValue":0,'
    '"maxValue":255,"units":"","header":"7E0","isCustom":true}';

Future<ProviderContainer> _container() async {
  SharedPreferences.setMockInitialValues({
    'custom_pids_v1': <String>[_custom],
    'active_pid_ids_v1': <String>[
      'custom:7E0:221234',
      PidLibrary.vehicleSpeed.id,
    ],
  });
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
}

ObdCapabilitySummary _summary() => ObdCapabilitySummary(
  phase: ObdCapabilityDiscoveryPhase.attemptFinished,
  verifiedBlockIds: const <String>{'0100'},
  supportedMode01Requests: const <String>{'0105', '010C', '010D'},
  directlyAnsweredDefinitionIds: const <String>{},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'bulk selection appends once in library order and writes once',
    () async {
      final container = await _container();
      addTearDown(container.dispose);
      final active = container.read(activePidsProvider.notifier);
      final before = List<Pid>.of(container.read(activePidsProvider));

      final outcome = await active.appendPositivelyConfirmed(_summary());

      expect(outcome.result, SupportedPidSelectionResult.applied);
      expect(outcome.addedCount, 2);
      expect(active.persistWriteCount, 1);
      final after = container.read(activePidsProvider);
      expect(
        after.take(before.length).map((pid) => pid.id),
        before.map((p) => p.id),
      );
      expect(after.skip(before.length).map((pid) => pid.id), [
        PidLibrary.engineRpm.id,
        PidLibrary.coolantTemp.id,
      ], reason: 'new entries follow PidLibrary.all, not mask or set order');

      final repeat = await active.appendPositivelyConfirmed(_summary());
      expect(repeat.result, SupportedPidSelectionResult.noChange);
      expect(
        active.persistWriteCount,
        1,
        reason: 'repeat is a zero-write no-op',
      );
    },
  );

  test(
    'bulk selection excludes variants, custom, non-Mode01 and other headers',
    () async {
      final container = await _container();
      addTearDown(container.dispose);
      final active = container.read(activePidsProvider.notifier);
      final summary = ObdCapabilitySummary(
        phase: ObdCapabilityDiscoveryPhase.attemptFinished,
        verifiedBlockIds: const <String>{},
        supportedMode01Requests: const <String>{},
        directlyAnsweredDefinitionIds: <String>{
          PidLibrary.boostPressure.id,
          PidLibrary.speedMph.id,
          ...PidLibrary.all
              .where((pid) => !pid.isMode01 || pid.header != kDefaultHeader)
              .map((pid) => pid.id),
        },
      );

      final outcome = await active.appendPositivelyConfirmed(summary);

      expect(outcome.result, SupportedPidSelectionResult.noChange);
      expect(active.persistWriteCount, 0);
    },
  );

  test(
    'root mutation lock refuses the whole bulk mutation atomically',
    () async {
      final container = await _container();
      addTearDown(container.dispose);
      final lock = container.read(pidMutationLockProvider);
      final token = lock.tryAcquire('recording')!;
      final before = List<Pid>.of(container.read(activePidsProvider));
      final active = container.read(activePidsProvider.notifier);

      final outcome = await active.appendPositivelyConfirmed(_summary());

      expect(outcome.result, SupportedPidSelectionResult.locked);
      expect(container.read(activePidsProvider), before);
      expect(active.persistWriteCount, 0);
      lock.release(token);
    },
  );
}
