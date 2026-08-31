/// Persistent visibility opt-in for the one-shot battery evidence laboratory.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pid_registry.dart';

const _kPowertrainBatteryExperimentsKey =
    'powertrain_battery_experiments_enabled_v1';

typedef PowertrainBatteryExperimentalPersistence = Future<bool> Function(
  bool enabled,
);

/// Kept injectable so the fail-closed ordering can be regression tested
/// without replacing the app-wide preferences instance.
final powertrainBatteryExperimentalPersistenceProvider =
    Provider<PowertrainBatteryExperimentalPersistence>((ref) {
      final preferences = ref.watch(sharedPreferencesProvider);
      return (enabled) =>
          preferences.setBool(_kPowertrainBatteryExperimentsKey, enabled);
    });

class PowertrainBatteryExperimentalAccess extends Notifier<bool> {
  int _persistenceGeneration = 0;
  Future<void> _persistenceChain = Future<void>.value();

  @override
  bool build() {
    try {
      return ref
              .watch(sharedPreferencesProvider)
              .getBool(_kPowertrainBatteryExperimentsKey) ??
          false;
    } on Object {
      return false;
    }
  }

  /// This persists willingness to see the lab UI, never vehicle trust.
  Future<void> setEnabled(bool enabled) async {
    final generation = ++_persistenceGeneration;

    // Closing the laboratory is a safety boundary, not a preference-writing
    // success callback. Publish it synchronously so listeners revoke every
    // in-memory consent before storage or an in-flight wire response can win
    // a race. A failed write must remain closed for this process.
    if (!enabled) state = false;

    // Preferences writes are not specified to complete in call order. Queue
    // them so an old, slow enable can never land after a newer disable and
    // silently reopen the laboratory on the next process start.
    final persistence = ref.read(
      powertrainBatteryExperimentalPersistenceProvider,
    );
    final write = _persistenceChain.then((_) async {
      final saved = await persistence(enabled);
      if (!saved) {
        throw StateError('experimental powertrain access was not persisted');
      }
    });
    _persistenceChain = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );

    try {
      await write;
    } on Object {
      if (!enabled) state = false;
      rethrow;
    }

    // An older enable cannot reopen the lab after a newer disable request.
    if (generation != _persistenceGeneration) return;

    // Opening is the inverse safety order: no visible opt-in until the durable
    // preference has acknowledged success.
    if (enabled) state = true;
  }
}

final powertrainBatteryExperimentalAccessProvider =
    NotifierProvider<PowertrainBatteryExperimentalAccess, bool>(
      PowertrainBatteryExperimentalAccess.new,
    );
