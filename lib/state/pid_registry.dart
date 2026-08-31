/// PID registry: which signals exist, which are being polled, and the user's
/// own definitions — persisted so a dashboard survives a restart.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import '../obd/pid/pid.dart';
import '../obd/pid/pid_library.dart';
import '../obd/powertrain_battery/powertrain_battery_profile.dart';
import '../obd/powertrain_battery/profile_pid_installer.dart';
import '../obd/polling_engine.dart';
import 'pid_mutation_lock.dart';

const _kCustomPidsKey = 'custom_pids_v1';
const _kActivePidIdsKey = 'active_pid_ids_v1';
const _kPowertrainProfilePidsKey = 'powertrain_profile_pids_v1';

/// Injected at startup in `main()` so the rest of the app can read preferences
/// synchronously instead of every screen awaiting the same future.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) =>
      throw UnimplementedError('sharedPreferencesProvider must be overridden'),
);

class PidRegistry extends Notifier<List<Pid>> {
  @override
  List<Pid> build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final stored = prefs.getStringList(_kCustomPidsKey) ?? const [];
    final custom = <Pid>[];
    for (final entry in stored) {
      try {
        final decoded = jsonDecode(entry);
        // `FormatException` alone was not enough. Valid JSON of the wrong
        // shape — a stored `[]`, or a field holding a string where a number
        // belongs — parses cleanly and then throws `TypeError` on the cast,
        // which was unhandled: a single corrupt entry, or a schema that
        // changed between builds, took the whole PID list and the screens
        // built on it down with it.
        if (decoded is! Map<String, dynamic>) continue;
        custom.add(Pid.fromJson(decoded));
      } on Object {
        // A corrupt entry should not cost the user their whole PID list.
        continue;
      }
    }
    // Collapsed by canonical identity before anything downstream sees them.
    //
    // Two stored entries can carry different spellings — `01 0C` and `010C` —
    // and canonicalise to the same `Pid.id`. Left as two objects they reach
    // `ActivePids`, whose map literal keeps the *last*, while `upsertAllCustom`
    // replaces the *first*. An import could then correctly report that it had
    // overwritten a definition while the stale twin went on driving the gauge,
    // showing 26 rpm for bytes that mean 1726.
    //
    // The *last* wins, because that is the one that was already driving the
    // gauge.
    //
    // Both duplicates used to reach `ActivePids`, whose canonical map literal
    // keeps the last — so on the release before this one, the second stored
    // definition is what the user was looking at. Collapsing to the first
    // would have been a silent migration of live data: a corrected
    // `((A*256)+B)/4` saved after a stale `A` would have been thrown away on
    // upgrade and the gauge would have gone from 1726 rpm to 26.
    //
    // This is order-dependent, and saying otherwise would be false. What it is
    // not is *arbitrary*: it preserves the definition that was in effect.
    final byCanonicalId = <String, Pid>{};
    for (final pid in custom) {
      byCanonicalId[Pid.canonicalId(pid.id)] = pid;
    }
    // No catalog profile is installable in this release. Ignore and erase any
    // value injected under the former experimental persistence key rather
    // than rehydrating it into the production PID registry.
    if (prefs.containsKey(_kPowertrainProfilePidsKey)) {
      unawaited(prefs.remove(_kPowertrainProfilePidsKey));
    }
    return [...PidLibrary.all, ...byCanonicalId.values];
  }

  List<Pid> get customPids => state.where((p) => p.isCustom).toList();

  List<Pid> get profilePids => state
      .where((pid) => !pid.isCustom && pid.ownerProfileId != null)
      .toList(growable: false);

  Set<String> get installedPowertrainProfileIds => {
    for (final pid in profilePids) pid.ownerProfileId!,
  };

  Pid? byId(String id) {
    for (final pid in state) {
      if (pid.id == id) return pid;
    }
    return null;
  }

  Future<PidImportOutcome> upsertCustom(Pid pid) => upsertAllCustom([pid]);

  /// Replaces one custom definition as a single in-memory commit.
  ///
  /// The lock is checked exactly once before [state] changes, and the old
  /// definition is never removed in a separate awaitable operation. This is
  /// the compound edit path used when a header or request changes identity.
  Future<PidMutationOutcome> replaceCustom(
    Pid previous,
    Pid replacement,
  ) async {
    if (ref.read(pidMutationLockProvider).isLocked) {
      return const PidMutationOutcome.locked();
    }
    final previousId = Pid.canonicalId(previous.id);
    final index = state.indexWhere(
      (pid) => pid.isCustom && Pid.canonicalId(pid.id) == previousId,
    );
    if (index < 0) return const PidMutationOutcome.noChange();

    final custom = replacement.copyWith(isCustom: true);
    final replacementId = Pid.canonicalId(custom.id);
    final collision = state.indexWhere(
      (pid) =>
          pid.isCustom &&
          Pid.canonicalId(pid.id) == replacementId &&
          Pid.canonicalId(pid.id) != previousId,
    );
    if (collision >= 0) return const PidMutationOutcome.noChange();

    final next = [...state];
    next[index] = custom;
    state = next;
    await _persist();
    return const PidMutationOutcome.applied();
  }

  /// Adds or replaces several definitions with a single write.
  ///
  /// A CSV import calls this once rather than per row: persisting inside the
  /// loop rewrites the whole list for every entry, which is O(n²) writes to
  /// SharedPreferences for a file the user expects to import instantly.
  /// What an import actually did, so the screen can say so.
  ///
  /// The count of parsed rows is not the count of definitions that survived,
  /// and reporting the first as the second is how a file with two rows for
  /// `010C` reported "imported 2" while keeping one — whichever came last —
  /// and silently swapped a working formula for it. A gauge then reads 26 rpm
  /// where the vehicle said 1726, with nothing on screen to say why.
  Future<PidImportOutcome> upsertAllCustom(Iterable<Pid> pids) async {
    if (ref.read(pidMutationLockProvider).isLocked) {
      return const PidImportOutcome(
        inserted: 0,
        replaced: 0,
        duplicatesInFile: [],
        failure: PidMutationFailure.locked,
      );
    }
    final next = [...state];
    var inserted = 0;
    var replaced = 0;
    final duplicates = <String>[];
    final withinThisImport = <String>{};

    for (final pid in pids) {
      final custom = pid.copyWith(isCustom: true);
      // Two rows in one file claiming the same identity is a mistake in the
      // file, not an instruction. The first is taken and the rest are
      // reported, because silently keeping the last one makes which formula
      // you get depend on row order.
      if (!withinThisImport.add(Pid.canonicalId(custom.id))) {
        duplicates.add(custom.name);
        continue;
      }
      // Canonically, for the reason `build` collapses: matching on the raw id
      // finds the first of a pair that a map literal downstream resolves to
      // the second.
      final index = next.indexWhere(
        (p) =>
            p.isCustom && Pid.canonicalId(p.id) == Pid.canonicalId(custom.id),
      );
      if (index >= 0) {
        next[index] = custom;
        replaced++;
      } else {
        next.add(custom);
        inserted++;
      }
    }
    state = next;
    await _persist();
    return PidImportOutcome(
      inserted: inserted,
      replaced: replaced,
      duplicatesInFile: List.unmodifiable(duplicates),
    );
  }

  Future<PidMutationOutcome> removeCustom(Pid pid) async {
    if (ref.read(pidMutationLockProvider).isLocked) {
      return const PidMutationOutcome.locked();
    }
    if (!state.any((p) => p.id == pid.id && p.isCustom)) {
      return const PidMutationOutcome.noChange();
    }
    state = state.where((p) => !(p.id == pid.id && p.isCustom)).toList();
    await _persist();
    // A deleted PID must also leave the dashboard, and it does — by being
    // gone from here.
    //
    // This used to say so by calling `activePidsProvider.notifier.remove`,
    // which Riverpod refuses: `ActivePids.build` watches this provider, so
    // reading it back from here is a circular dependency. It threw
    // `CircularDependencyError` out of `_save`, the editor stayed open with no
    // message, and the edit was lost — but only on the branch that renames a
    // PID's *identity*, because that is the only one that calls this. Changing
    // a name or a formula saves fine, so both the editor's own regression test
    // and the reviewer's covered the branch that could not fail.
    //
    // Found on a device, by editing a custom PID's mode from `012F` to `0105`.
    //
    // Nothing replaces the call because nothing needs to. The dashboard is a
    // view of this list: `ActivePids.build` resolves stored ids against the
    // registry and drops what no longer resolves, so a definition that leaves
    // here leaves the grid on the rebuild this assignment already triggers. A
    // stale id left in storage never resolves again and is rewritten by the
    // next toggle.
    return const PidMutationOutcome.applied();
  }

  /// Installs or replaces every signal owned by [profile] in one persisted
  /// operation. Installation only makes definitions available; it does not
  /// add them to the dashboard or authorize vehicle traffic.
  Future<void> installPowertrainProfile(
    PowertrainBatteryProfile profile,
  ) async {
    PowertrainProfilePidInstaller.build(profile);
  }

  Future<void> uninstallPowertrainProfile(String profileId) async {
    final next = [
      for (final pid in state)
        if (pid.ownerProfileId != profileId) pid,
    ];
    state = next;
    await ref
        .read(sharedPreferencesProvider)
        .remove(_kPowertrainProfilePidsKey);
  }

  Future<void> _persist() async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setStringList(
      _kCustomPidsKey,
      customPids.map((p) => jsonEncode(p.toJson())).toList(),
    );
  }
}

/// What [PidRegistry.upsertAllCustom] did with the rows it was given.
class PidImportOutcome {
  const PidImportOutcome({
    required this.inserted,
    required this.replaced,
    required this.duplicatesInFile,
    this.failure,
  });

  final int inserted;
  final int replaced;
  final PidMutationFailure? failure;

  /// Names of rows skipped because an earlier row in the same file already
  /// claimed their identity.
  final List<String> duplicatesInFile;

  /// How many definitions the registry actually ended up with.
  int get landed => inserted + replaced;

  /// The sentence shown after an import.
  ///
  /// A pure function because the counts are the part worth testing, and a
  /// snackbar built inline could only be checked by driving a file picker.
  /// Saying "已匯入 2" while one row silently replaced another is how a gauge
  /// comes to read 26 where the vehicle said 1726, so what is displayed is
  /// held to the same standard as what is stored.
  String describe({int skippedRows = 0, int defaultedRanges = 0}) {
    if (failure == PidMutationFailure.locked) {
      return '錄製準備、錄製或儲存完成前不能變更 PID。';
    }
    final notes = [
      if (skippedRows > 0) '$skippedRows 行有問題已略過',
      if (defaultedRanges > 0) '$defaultedRanges 行套用了預設量程',
      if (replaced > 0) '$replaced 項覆蓋了現有定義',
      if (duplicatesInFile.isNotEmpty)
        '${duplicatesInFile.length} 行與檔案內其他行重複已略過',
    ];
    return notes.isEmpty
        ? '已匯入 $landed 項自訂 PID。'
        : '匯入 $landed 項，${notes.join('、')}。';
  }
}

final pidRegistryProvider = NotifierProvider<PidRegistry, List<Pid>>(
  PidRegistry.new,
);

/// The PIDs currently on the dashboard, in display order.
class ActivePids extends Notifier<List<Pid>> {
  int _persistWriteCount = 0;

  @visibleForTesting
  int get persistWriteCount => _persistWriteCount;
  @override
  List<Pid> build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    // Read once and then listened to, rather than watched.
    //
    // Watching rebuilt this whole list from storage on every registry change,
    // and storage still holds the id of a definition the user has just
    // deleted. That id no longer resolves, which lands in the "stored,
    // non-empty, nothing resolved" branch below — so deleting your only gauge
    // restored six you never asked for. Folding changes into the state instead
    // keeps a deletion a deletion, and the branch below goes back to meaning
    // what it says: a layout that arrived broken, not one being edited.
    final registry = ref.read(pidRegistryProvider);
    ref.listen<List<Pid>>(pidRegistryProvider, _onRegistryChanged);
    final storedIds = prefs.getStringList(_kActivePidIdsKey);

    // Never stored: a first run, so start from the shipped layout.
    if (storedIds == null) return PidLibrary.defaultDashboard;

    // Stored *and empty*: the user cleared the dashboard. Restoring the
    // defaults there overrode a deliberate choice — every gauge came back on
    // the next launch, with no way to make it stick.
    if (storedIds.isEmpty) return const [];

    // Compared canonically. Canonicalising `header` and `modeAndPid` on load
    // changes `Pid.id`, and these stored ids hold the spelling an older build
    // wrote — so an active custom gauge stopped resolving and disappeared
    // without a word, while the other ids kept resolving and suppressed the
    // "nothing resolved" fallback that would have made it visible.
    final byId = {for (final pid in registry) Pid.canonicalId(pid.id): pid};
    final resolved = storedIds
        .map((id) => byId[Pid.canonicalId(id)])
        .nonNulls
        .toList();
    // Stored, non-empty, and nothing resolved: every id has since been
    // deleted. That is a broken layout rather than a chosen one, so fall back
    // rather than showing a blank dashboard with no way to recover.
    return resolved.isEmpty ? PidLibrary.defaultDashboard : resolved;
  }

  /// Folds a registry change into the dashboard without consulting storage.
  ///
  /// Two jobs, and both used to be done by rebuilding from `prefs`:
  ///
  ///  * a definition that left the registry leaves the grid, or the tile
  ///    points at something that no longer exists;
  ///  * a definition that was *edited* is replaced, or the gauge goes on
  ///    painting the old formula — a wrong number with nothing on screen to
  ///    say so.
  ///
  /// Order is preserved because the user chose it.
  void _onRegistryChanged(List<Pid>? previous, List<Pid> next) {
    final byId = {for (final pid in next) Pid.canonicalId(pid.id): pid};
    final replacements = <String, Pid>{};
    if (previous != null && previous.length == next.length) {
      for (var index = 0; index < previous.length; index++) {
        final before = previous[index];
        final after = next[index];
        final beforeId = Pid.canonicalId(before.id);
        final afterId = Pid.canonicalId(after.id);
        if (before.isCustom &&
            after.isCustom &&
            beforeId != afterId &&
            !byId.containsKey(beforeId)) {
          replacements[beforeId] = after;
        }
      }
    }
    final kept = <Pid>[];
    var replacedIdentity = false;
    for (final pid in state) {
      final id = Pid.canonicalId(pid.id);
      final current = byId[id];
      if (current != null) {
        kept.add(current);
        continue;
      }
      final replacement = replacements[id];
      if (replacement != null) {
        kept.add(replacement);
        replacedIdentity = true;
      }
    }

    var changed = kept.length != state.length;
    if (!changed) {
      for (var i = 0; i < kept.length; i++) {
        if (!identical(kept[i], state[i])) {
          changed = true;
          break;
        }
      }
    }
    // Assigning an equal-looking list would still notify, and the poll loop
    // resyncs its active set on every notification.
    if (!changed) return;

    final droppedSome = kept.length != state.length;
    state = kept;
    // Only when the *identity* list changed. An edit leaves storage correct
    // already, and rewriting it on every formula tweak is a write per
    // keystroke's worth of saves.
    if (droppedSome || replacedIdentity) unawaited(_persist());
  }

  bool contains(Pid pid) => state.any((p) => p.id == pid.id);

  Future<PidMutationOutcome> toggle(Pid pid) async {
    if (ref.read(pidMutationLockProvider).isLocked) {
      return const PidMutationOutcome.locked();
    }
    if (contains(pid)) {
      return remove(pid);
    }
    return add(pid);
  }

  Future<PidMutationOutcome> add(Pid pid) async {
    if (ref.read(pidMutationLockProvider).isLocked) {
      return const PidMutationOutcome.locked();
    }
    if (contains(pid)) return const PidMutationOutcome.noChange();
    state = [...state, pid];
    await _persist();
    return const PidMutationOutcome.applied();
  }

  /// Appends every safely selectable shipped definition as one atomic layout
  /// mutation and one preferences write.
  Future<SupportedPidSelectionOutcome> appendPositivelyConfirmed(
    ObdCapabilitySummary summary,
  ) async {
    if (ref.read(pidMutationLockProvider).isLocked) {
      return const SupportedPidSelectionOutcome.locked();
    }
    final activeIds = state.map((pid) => Pid.canonicalId(pid.id)).toSet();
    final additions = summary.positivelyConfirmedShippedDirectPids
        .where((pid) => !activeIds.contains(Pid.canonicalId(pid.id)))
        .toList(growable: false);
    if (additions.isEmpty) {
      return const SupportedPidSelectionOutcome.noChange();
    }
    state = List<Pid>.unmodifiable(<Pid>[...state, ...additions]);
    await _persist();
    return SupportedPidSelectionOutcome.applied(additions.length);
  }

  /// Adds [pid] at [index] rather than at the end.
  Future<PidMutationOutcome> insert(int index, Pid pid) async {
    if (ref.read(pidMutationLockProvider).isLocked) {
      return const PidMutationOutcome.locked();
    }
    if (contains(pid)) return const PidMutationOutcome.noChange();
    final next = [...state];
    next.insert(index.clamp(0, next.length), pid);
    state = next;
    await _persist();
    return const PidMutationOutcome.applied();
  }

  /// Puts [replacement] where [previous] was, rather than at the end.
  ///
  /// An edit that changes a PID's identity is a removal and an insertion as
  /// far as the registry is concerned, and the dashboard was being rebuilt
  /// from those two halves: the listener dropped the old entry and the editor
  /// appended the new one. A gauge the user had placed second came back third,
  /// every time they corrected a mistyped PID.
  ///
  /// A no-op when [previous] was not on the dashboard, so the caller does not
  /// have to ask first.
  Future<PidMutationOutcome> replace(Pid previous, Pid replacement) async {
    if (ref.read(pidMutationLockProvider).isLocked) {
      return const PidMutationOutcome.locked();
    }
    final index = state.indexWhere((p) => p.id == previous.id);
    if (index < 0) return const PidMutationOutcome.noChange();
    final next = [...state];
    next[index] = replacement;
    state = next;
    await _persist();
    return const PidMutationOutcome.applied();
  }

  Future<PidMutationOutcome> remove(Pid pid) async {
    if (ref.read(pidMutationLockProvider).isLocked) {
      return const PidMutationOutcome.locked();
    }
    if (!contains(pid)) return const PidMutationOutcome.noChange();
    state = state.where((p) => p.id != pid.id).toList();
    await _persist();
    return const PidMutationOutcome.applied();
  }

  /// Moves the entry at [oldIndex] to [newIndex].
  ///
  /// [newIndex] is the destination *after* the dragged item has been removed —
  /// which is what `ReorderableListView.onReorderItem` supplies. The older
  /// `onReorder` callback reports it before removal and needs a -1 adjustment;
  /// passing that one here unadjusted would drop items one slot short.
  Future<PidMutationOutcome> reorder(int oldIndex, int newIndex) async {
    if (ref.read(pidMutationLockProvider).isLocked) {
      return const PidMutationOutcome.locked();
    }
    if (oldIndex < 0 || oldIndex >= state.length) {
      return const PidMutationOutcome.noChange();
    }
    final next = [...state];
    final item = next.removeAt(oldIndex);
    next.insert(newIndex.clamp(0, next.length), item);
    state = next;
    await _persist();
    return const PidMutationOutcome.applied();
  }

  Future<void> _persist() async {
    _persistWriteCount++;
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setStringList(
      _kActivePidIdsKey,
      state.map((p) => p.id).toList(),
    );
  }
}

enum SupportedPidSelectionResult { applied, noChange, locked }

final class SupportedPidSelectionOutcome {
  const SupportedPidSelectionOutcome._(this.result, this.addedCount);

  const SupportedPidSelectionOutcome.applied(int addedCount)
    : this._(SupportedPidSelectionResult.applied, addedCount);

  const SupportedPidSelectionOutcome.noChange()
    : this._(SupportedPidSelectionResult.noChange, 0);

  const SupportedPidSelectionOutcome.locked()
    : this._(SupportedPidSelectionResult.locked, 0);

  final SupportedPidSelectionResult result;
  final int addedCount;

  bool get isLocked => result == SupportedPidSelectionResult.locked;
}

final activePidsProvider = NotifierProvider<ActivePids, List<Pid>>(
  ActivePids.new,
);
