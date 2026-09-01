/// PID registry: which signals exist, which are being polled, and the user's
/// own definitions — persisted so a dashboard survives a restart.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../obd/pid/pid.dart';
import '../obd/pid/pid_library.dart';
import '../obd/polling_engine.dart';
import '../obd/powertrain_battery/powertrain_battery_catalog.dart';
import '../obd/powertrain_battery/powertrain_battery_profile.dart';
import '../obd/powertrain_battery/profile_pid_installer.dart';
import '../obd/powertrain_battery/profile_wire_contract.dart';
import 'pid_mutation_lock.dart';

const _kCustomPidsKey = 'custom_pids_v1';
const _kActivePidIdsKey = 'active_pid_ids_v1';
const _kPowertrainProfilePidsKey = 'powertrain_profile_pids_v1';
const _kPowertrainProfileInstallsKey = 'powertrain_profile_installs_v1';

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
    // Storage is not a trusted source for profile PIDs. The former key held
    // full Pid JSON, which would let a tampered preference carry a modified
    // formula past the SHA-256-verified catalog — so it is still ignored and
    // erased. Installations persist as `{profile_id, vehicle_year}` references
    // under [_kPowertrainProfileInstallsKey] and are rebuilt from the verified
    // catalog by [restoreInstalledProfiles] once it has loaded.
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

  /// Installs or replaces every signal owned by a catalog profile in one
  /// persisted operation. Installation only makes definitions available; it
  /// does not add them to the dashboard, and polling still requires a
  /// per-connection authorization for the exact vehicle.
  ///
  /// The profile is named by id and resolved from the verified [snapshot],
  /// never accepted as a caller-built object: whatever installs is exactly
  /// what passed the catalog's SHA-256 manifest check and full validation,
  /// and a self-declared profile has no way in.
  ///
  /// [vehicleYear] is the model year the user confirmed at install time. It
  /// is stored with the reference so the connection-time authorization prompt
  /// can name the exact vehicle rather than a range.
  Future<PidMutationOutcome> installPowertrainProfile(
    PowertrainBatteryCatalogSnapshot snapshot,
    String profileId, {
    required int vehicleYear,
  }) async {
    final lock = ref.read(pidMutationLockProvider);
    final token = lock.tryAcquire('catalog-install');
    if (token == null) return const PidMutationOutcome.locked();
    try {
      if (!isPowertrainCatalogSha256(snapshot.catalogSha256)) {
        throw const PowertrainProfileInstallException(
          'catalog snapshot carries no verified SHA-256',
        );
      }
      final profile = snapshot.catalog.profiles
          .where((candidate) => candidate.id == profileId)
          .firstOrNull;
      if (profile == null) {
        throw PowertrainProfileInstallException(
          '$profileId is not in the verified catalog',
        );
      }
      if (!profile.appliesToYear(vehicleYear)) {
        throw PowertrainProfileInstallException(
          '$vehicleYear is outside ${profile.id}\'s documented year range',
        );
      }
      final pids = PowertrainProfilePidInstaller.build(profile);
      // Persist a snapshot first, commit second. Nothing observable — not the
      // provider state, not the [installedVehicleYear] getter — changes until
      // the storage write has succeeded, so a failure leaves every reader
      // consistent and there is nothing to roll back. Publishing last matters
      // separately: the state assignment notifies the dashboard's
      // reconciliation synchronously, and a failure after that point could
      // not reach across providers to undo what the notification caused.
      final nextYears = Map.of(_installedYears)..[profile.id] = vehicleYear;
      await _persistProfileInstalls(nextYears);
      _installedYears
        ..clear()
        ..addAll(nextYears);
      state = [
        for (final pid in state)
          if (pid.ownerProfileId != profile.id) pid,
        ...pids,
      ];
      _powertrainRestoreSettled = true;
      return const PidMutationOutcome.applied();
    } finally {
      lock.release(token);
    }
  }

  Future<PidMutationOutcome> uninstallPowertrainProfile(
    String profileId,
  ) async {
    final lock = ref.read(pidMutationLockProvider);
    final token = lock.tryAcquire('catalog-uninstall');
    if (token == null) return const PidMutationOutcome.locked();
    try {
      final nextYears = Map.of(_installedYears)..remove(profileId);
      await _persistProfileInstalls(nextYears);
      _installedYears
        ..clear()
        ..addAll(nextYears);
      state = [
        for (final pid in state)
          if (pid.ownerProfileId != profileId) pid,
      ];
      _powertrainRestoreSettled = true;
      return const PidMutationOutcome.applied();
    } finally {
      lock.release(token);
    }
  }

  /// The model year confirmed when [profileId] was installed, if it is.
  int? installedVehicleYear(String profileId) => _installedYears[profileId];

  final Map<String, int> _installedYears = {};

  /// Whether the startup restore has produced an authoritative answer.
  ///
  /// Until then, a `profile:` layout id that does not resolve is *pending* —
  /// its definition may still arrive from the verified catalog. Afterwards,
  /// an unresolved profile id means withdrawn or uninstalled, and the
  /// dashboard may treat it like any other deletion.
  bool get powertrainRestoreSettled => _powertrainRestoreSettled;
  bool _powertrainRestoreSettled = false;

  /// Recording may freeze the visible PID set once restore has finished, or
  /// once storage proves there is nothing to restore. A non-empty install
  /// list that has not been rebuilt yet still blocks Start — those gauges
  /// are pending, not absent.
  bool get pidDefinitionsReadyForRecording {
    if (_powertrainRestoreSettled) return true;
    final stored = ref
        .read(sharedPreferencesProvider)
        .getStringList(_kPowertrainProfileInstallsKey);
    return stored == null || stored.isEmpty;
  }

  /// Rebuilds installed profile PIDs from the verified [catalog].
  ///
  /// Only `{profile_id, vehicle_year}` references are persisted, so the
  /// formulas and byte windows always come from the catalog that just passed
  /// its manifest SHA-256 check — never from mutable preferences. A reference
  /// whose profile has left the catalog, lost its installable status, or no
  /// longer covers the stored year is dropped and the storage rewritten, so a
  /// catalog downgrade uninstalls cleanly instead of resurrecting stale PIDs.
  Future<void> restoreInstalledProfiles(
    PowertrainBatteryCatalog catalog,
  ) async {
    final lock = ref.read(pidMutationLockProvider);
    final token = lock.tryAcquire('catalog-restore');
    if (token == null) return;
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      final stored = prefs.getStringList(_kPowertrainProfileInstallsKey);
      if (stored == null || stored.isEmpty) {
        _powertrainRestoreSettled = true;
        // Nothing to rebuild, but the answer is now authoritative — notify so
        // the dashboard can reconcile layout ids that will never resolve.
        state = [...state];
        return;
      }

      final byId = {
        for (final profile in catalog.profiles) profile.id: profile,
      };
      final restored = <Pid>[];
      final nextYears = <String, int>{};
      for (final entry in stored) {
        Object? decoded;
        try {
          decoded = jsonDecode(entry);
        } on FormatException {
          continue;
        }
        if (decoded is! Map<String, dynamic>) continue;
        final profileId = decoded['profile_id'];
        final vehicleYear = decoded['vehicle_year'];
        if (profileId is! String || vehicleYear is! int) continue;
        final profile = byId[profileId];
        if (profile == null || !profile.appliesToYear(vehicleYear)) continue;
        try {
          restored.addAll(PowertrainProfilePidInstaller.build(profile));
        } on PowertrainProfileInstallException {
          continue;
        }
        nextYears[profileId] = vehicleYear;
      }

      // The stored references are the sole authority: every profile PID in the
      // current state is replaced by what the verified catalog rebuilds, and a
      // profile whose reference did not survive is gone rather than lingering.
      //
      // Persist the snapshot first, then commit, mark settled, and assign —
      // nothing observable changes on a failed write, and the state
      // assignment notifies listeners synchronously, so the dashboard's
      // reconciliation must observe the settled flag on that very
      // notification.
      await _persistProfileInstalls(nextYears);
      _installedYears
        ..clear()
        ..addAll(nextYears);
      _powertrainRestoreSettled = true;
      state = [
        for (final pid in state)
          if (pid.ownerProfileId == null) pid,
        ...restored,
      ];
    } finally {
      lock.release(token);
    }
  }

  Future<void> _persistProfileInstalls(Map<String, int> years) async {
    final prefs = ref.read(sharedPreferencesProvider);
    // `SharedPreferences` reports failure as `false`, not as an exception,
    // and swallowing it here is how an install could survive until the next
    // restart and then silently vanish.
    final saved = years.isEmpty
        ? await prefs.remove(_kPowertrainProfileInstallsKey)
        : await prefs.setStringList(_kPowertrainProfileInstallsKey, [
            for (final entry in years.entries)
              jsonEncode({
                'profile_id': entry.key,
                'vehicle_year': entry.value,
              }),
          ]);
    if (!saved) {
      throw const PowertrainProfileInstallException(
        'installed-profile references could not be persisted',
      );
    }
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

  /// The user's chosen layout by canonical id — including ids that do not
  /// currently resolve.
  ///
  /// The state below is the *visible* subset. Keeping the full list matters
  /// because installed battery-profile PIDs are rebuilt from the verified
  /// catalog asynchronously after start: their ids arrive here from storage
  /// before the registry holds their definitions, and dropping them at that
  /// moment — as resolving straight into state used to — silently erased
  /// the user's battery gauges from the persisted layout on every restart.
  /// An id that stays unresolved is invisible, nothing more; it is written
  /// back only by explicit user edits, so a deletion is still a deletion.
  List<String> _layoutIds = const [];

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
    if (storedIds == null) {
      _layoutIds = [
        for (final pid in PidLibrary.defaultDashboard) Pid.canonicalId(pid.id),
      ];
      return PidLibrary.defaultDashboard;
    }

    // Stored *and empty*: the user cleared the dashboard. Restoring the
    // defaults there overrode a deliberate choice — every gauge came back on
    // the next launch, with no way to make it stick.
    if (storedIds.isEmpty) {
      _layoutIds = const [];
      return const [];
    }

    // Compared canonically. Canonicalising `header` and `modeAndPid` on load
    // changes `Pid.id`, and these stored ids hold the spelling an older build
    // wrote — so an active custom gauge stopped resolving and disappeared
    // without a word, while the other ids kept resolving and suppressed the
    // "nothing resolved" fallback that would have made it visible.
    _layoutIds = [for (final id in storedIds) Pid.canonicalId(id)];
    // The restore can settle before this provider is first read — there is
    // no later registry notification to reconcile on, so the settled ghost
    // pruning has to happen here too, with the same all-profile fallback.
    // Unresolved built-in/custom ids keep their historical build behavior:
    // invisible until the next explicit edit rewrites storage.
    if (ref.read(pidRegistryProvider.notifier).powertrainRestoreSettled) {
      final byId = {for (final pid in registry) Pid.canonicalId(pid.id): pid};
      final pruned = [
        for (final id in _layoutIds)
          if (byId.containsKey(id) || !id.startsWith('profile:')) id,
      ];
      if (pruned.length != _layoutIds.length) {
        if (pruned.isEmpty &&
            _layoutIds.every((id) => id.startsWith('profile:'))) {
          _layoutIds = [
            for (final pid in PidLibrary.defaultDashboard)
              Pid.canonicalId(pid.id),
          ];
        } else {
          _layoutIds = pruned;
        }
        unawaited(_persist());
      }
    }
    final resolved = _resolve(registry);
    // Stored, non-empty, and nothing resolved: every id has since been
    // deleted. That is a broken layout rather than a chosen one, so fall back
    // rather than showing a blank dashboard with no way to recover. A layout
    // that still names profile ids is *pending*, not broken — their
    // definitions arrive when the catalog restore finishes — so it keeps
    // waiting instead of overwriting the user's choice.
    if (resolved.isEmpty &&
        !_layoutIds.any((id) => id.startsWith('profile:'))) {
      _layoutIds = [
        for (final pid in PidLibrary.defaultDashboard) Pid.canonicalId(pid.id),
      ];
      return PidLibrary.defaultDashboard;
    }
    return resolved;
  }

  List<Pid> _resolve(List<Pid> registry) {
    final byId = {for (final pid in registry) Pid.canonicalId(pid.id): pid};
    return _layoutIds.map((id) => byId[id]).nonNulls.toList();
  }

  /// Folds a registry change into the dashboard without consulting storage.
  ///
  /// Three jobs:
  ///
  ///  * a definition that left the registry leaves the grid, or the tile
  ///    points at something that no longer exists;
  ///  * a definition that was *edited* is replaced, or the gauge goes on
  ///    painting the old formula — a wrong number with nothing on screen to
  ///    say so;
  ///  * a layout id that could not resolve before — an installed profile
  ///    PID whose catalog restore had not finished — comes back the moment
  ///    its definition arrives.
  ///
  /// Order is preserved because the user chose it. A built-in or custom id
  /// that stops resolving means its definition was deleted, so its slot is
  /// pruned and the pruned layout persisted — a deletion is a deletion, and
  /// it outlives the session. A `profile:` id is different only while the
  /// startup restore has not yet answered: its definition is rebuilt
  /// asynchronously from the verified catalog, so until then an absence is
  /// *pending*, and pruning it silently erased the user's battery gauges
  /// from the layout on every restart. Once the restore settles, an
  /// unresolved profile id means withdrawn or uninstalled, and it is pruned
  /// and persisted like any other deletion — reinstalling later must not
  /// resurrect gauges the user did not put back.
  void _onRegistryChanged(List<Pid>? previous, List<Pid> next) {
    final byId = {for (final pid in next) Pid.canonicalId(pid.id): pid};
    final replacements = <String, String>{};
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
          replacements[beforeId] = afterId;
        }
      }
    }
    var persistLayout = false;
    if (replacements.isNotEmpty) {
      final remapped = [for (final id in _layoutIds) replacements[id] ?? id];
      for (var i = 0; i < remapped.length; i++) {
        if (remapped[i] != _layoutIds[i]) {
          persistLayout = true;
          break;
        }
      }
      _layoutIds = remapped;
    }
    final restoreSettled = ref
        .read(pidRegistryProvider.notifier)
        .powertrainRestoreSettled;
    final pruned = [
      for (final id in _layoutIds)
        if (byId.containsKey(id) ||
            (!restoreSettled && id.startsWith('profile:')))
          id,
    ];
    if (pruned.length != _layoutIds.length) {
      if (pruned.isEmpty &&
          _layoutIds.every((id) => id.startsWith('profile:'))) {
        // A dashboard that held only battery gauges just lost every one of
        // them to a catalog withdrawal or uninstall. That is a broken
        // layout, not a chosen one — fall back like the startup path does,
        // instead of leaving a permanently blank screen.
        _layoutIds = [
          for (final pid in PidLibrary.defaultDashboard)
            Pid.canonicalId(pid.id),
        ];
      } else {
        _layoutIds = pruned;
      }
      persistLayout = true;
    }
    // Identity remaps keep the same slot count, so pruning alone would leave
    // the old id in storage. The next launch then drops the gauge.
    if (persistLayout) unawaited(_persist());
    final resolved = _resolve(next);

    var changed = resolved.length != state.length;
    if (!changed) {
      for (var i = 0; i < resolved.length; i++) {
        if (!identical(resolved[i], state[i])) {
          changed = true;
          break;
        }
      }
    }
    // Assigning an equal-looking list would still notify, and the poll loop
    // resyncs its active set on every notification.
    if (!changed) return;

    state = resolved;
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
    _layoutIds = [..._layoutIds, Pid.canonicalId(pid.id)];
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
    _layoutIds = [
      ..._layoutIds,
      for (final pid in additions) Pid.canonicalId(pid.id),
    ];
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
    final visibleIndex = index.clamp(0, next.length);
    final layout = [..._layoutIds];
    // The index is into the *visible* list; the layout may hold invisible
    // pending ids, so the insertion lands before the visible anchor's slot.
    final layoutIndex = visibleIndex >= next.length
        ? layout.length
        : layout.indexOf(Pid.canonicalId(next[visibleIndex].id));
    layout.insert(
      layoutIndex < 0 ? layout.length : layoutIndex,
      Pid.canonicalId(pid.id),
    );
    next.insert(visibleIndex, pid);
    _layoutIds = layout;
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
    final layoutIndex = _layoutIds.indexOf(Pid.canonicalId(previous.id));
    if (layoutIndex >= 0) {
      final layout = [..._layoutIds];
      layout[layoutIndex] = Pid.canonicalId(replacement.id);
      _layoutIds = layout;
    }
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
    final canonical = Pid.canonicalId(pid.id);
    _layoutIds = [
      for (final id in _layoutIds)
        if (id != canonical) id,
    ];
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
    final previousVisible = {for (final pid in state) Pid.canonicalId(pid.id)};
    final next = [...state];
    final item = next.removeAt(oldIndex);
    next.insert(newIndex.clamp(0, next.length), item);
    state = next;
    // Re-thread the new visible order through the layout, leaving any
    // invisible pending ids in their original slots.
    final visibleOrder = [for (final pid in next) Pid.canonicalId(pid.id)];
    var cursor = 0;
    _layoutIds = [
      for (final id in _layoutIds)
        if (previousVisible.contains(id)) visibleOrder[cursor++] else id,
    ];
    await _persist();
    return const PidMutationOutcome.applied();
  }

  Future<void> _persist() async {
    _persistWriteCount++;
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setStringList(_kActivePidIdsKey, [..._layoutIds]);
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
