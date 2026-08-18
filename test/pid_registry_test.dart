/// An empty dashboard the user chose is not the same as one that broke.
///
/// `ActivePids.build()` fell back to the shipped layout whenever nothing
/// resolved, which covers two situations that need opposite handling: every
/// stored PID has since been deleted (a broken layout, and a blank screen with
/// no way back), versus the user having deliberately removed every gauge. The
/// second was silently overridden — clear the dashboard, relaunch, and every
/// default gauge is back.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/obd/pid/pid.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/state/pid_registry.dart';

Future<ProviderContainer> _container(Map<String, Object> initial) async {
  SharedPreferences.setMockInitialValues(initial);
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('R14-codex 02: an import says what it actually did', () async {
    // Codex round 14. The editor refuses a duplicate identity; import went
    // round it. Two CSV rows for `010C` both canonicalise to one id,
    // `upsertAllCustom` replaced by id and last-row-wins, and the snackbar
    // counted parsed rows — so the app said "imported 2", kept one, and swapped
    // a working `((A*256)+B)/4` for `A`. The same reply then reads 26 rpm
    // instead of 1726, with nothing on screen to say why.
    final container = await _container({});
    addTearDown(container.dispose);
    final registry = container.read(pidRegistryProvider.notifier);

    const correct = Pid(
      name: 'RPM correct', shortName: 'RPM', modeAndPid: '010C',
      equation: '((A*256)+B)/4', minValue: 0, maxValue: 8000, units: 'rpm',
      header: kDefaultHeader, isCustom: true,
    );
    const raw = Pid(
      name: 'RPM raw', shortName: 'RPM', modeAndPid: '010C',
      equation: 'A', minValue: 0, maxValue: 8000, units: 'rpm',
      header: kDefaultHeader, isCustom: true,
    );

    final outcome = await registry.upsertAllCustom([correct, raw]);
    expect(outcome.inserted, 1);
    expect(outcome.duplicatesInFile, ['RPM raw'],
        reason: 'the second row is reported, not silently preferred');

    final stored = container
        .read(pidRegistryProvider)
        .where((p) => p.isCustom)
        .toList();
    expect(stored, hasLength(1));
    expect(stored.single.equation, '((A*256)+B)/4',
        reason: 'the first row is kept — deterministically, and reported, '
            'rather than the last one silently winning');
  });

  test('R15-codex 01: two spellings of one identity collapse on load',
      () async {
    // Codex round 15. Stored entries are normalised one at a time and were not
    // coalesced, so `01 0C` and `010C` loaded as two objects with the same
    // `Pid.id`. `ActivePids` built a map literal — last wins — while
    // `upsertAllCustom` used `indexWhere` — first wins. An import could report
    // that it had overwritten the definition while the stale twin went on
    // driving the gauge: 26 rpm for bytes that mean 1726.
    // Stored in the order a real upgrade would have them: a stale definition
    // first, then the correction the user saved afterwards.
    const stale = '{"name":"RPM stale","shortName":"RPM",'
        '"modeAndPid":"01 0C","equation":"A","minValue":0,'
        '"maxValue":8000,"units":"rpm","header":"7E0","isCustom":true}';
    const corrected = '{"name":"RPM corrected","shortName":"RPM",'
        '"modeAndPid":"010C","equation":"((A*256)+B)/4","minValue":0,'
        '"maxValue":8000,"units":"rpm","header":"7E0","isCustom":true}';

    final container = await _container({
      'custom_pids_v1': <String>[stale, corrected],
      'active_pid_ids_v1': <String>['custom:7E0:01 0C'],
    });
    addTearDown(container.dispose);

    final custom =
        container.read(pidRegistryProvider).where((p) => p.isCustom).toList();
    expect(custom, hasLength(1),
        reason: 'one identity is one definition, whatever it was spelled as');
    // The last, because that is the one the previous release was already
    // showing: `ActivePids` built a canonical map literal and a map literal
    // keeps the last. Collapsing to the first would have silently migrated a
    // working gauge from 1726 rpm to 26.
    expect(container.read(activePidsProvider).single.equation,
        '((A*256)+B)/4',
        reason: 'upgrading does not change what the gauge reads');
  });

  test('R15-codex 05: the import message counts what landed', () {
    // Codex round 15's coverage note. The registry's counting was tested; what
    // the user is *told* was not, and the two are the same claim. "已匯入 2"
    // for a file whose second row replaced the first is how someone comes away
    // believing they have two gauges, one of which is now wrong.
    const clean = PidImportOutcome(
        inserted: 3, replaced: 0, duplicatesInFile: []);
    expect(clean.describe(), '已匯入 3 項自訂 PID。');

    const replacing = PidImportOutcome(
        inserted: 1, replaced: 2, duplicatesInFile: []);
    expect(replacing.describe(), contains('匯入 3 項'));
    expect(replacing.describe(), contains('2 項覆蓋了現有定義'),
        reason: 'replacing an existing definition is not the same as adding '
            'one, and the person who chose the file has to hear so');

    const duped = PidImportOutcome(
        inserted: 1, replaced: 0, duplicatesInFile: ['RPM raw']);
    expect(duped.landed, 1, reason: 'one landed, not two');
    expect(duped.describe(), contains('1 行與檔案內其他行重複已略過'));

    const messy = PidImportOutcome(
        inserted: 1, replaced: 1, duplicatesInFile: ['a', 'b']);
    final text = messy.describe(skippedRows: 4, defaultedRanges: 2);
    expect(text, contains('匯入 2 項'));
    expect(text, contains('4 行有問題已略過'));
    expect(text, contains('2 行套用了預設量程'));
    expect(text, contains('1 項覆蓋了現有定義'));
    expect(text, contains('2 行與檔案內其他行重複已略過'));
  });

  group('a definition leaving the registry leaves the dashboard', () {
    const only = '{"name":"Only","shortName":"ONE","modeAndPid":"010B",'
        '"equation":"A","minValue":0,"maxValue":300,"units":"kPa",'
        '"header":"7E0","isCustom":true,"variant":"only"}';

    test('R10-codex: deleting the last active gauge does not restore the '
        'shipped defaults', () async {
      // Found by Codex while reviewing the fix that caused it, hours old.
      //
      // `removeCustom` used to take the definition off the dashboard by
      // hand; that read `activePidsProvider` from inside the provider it
      // watches, which Riverpod refuses, so the call was removed and the
      // dashboard left to derive itself. Deriving works — the gauge does
      // leave — but the stored id stays behind and never resolves again, and
      // "stored, non-empty, nothing resolved" is the *broken layout* branch.
      // So deleting your only gauge repopulates the screen with six you did
      // not ask for.
      final container = await _container({
        'custom_pids_v1': <String>[only],
        'active_pid_ids_v1': <String>['custom:7E0:010B#only'],
      });
      addTearDown(container.dispose);

      final gauge = container.read(activePidsProvider).single;
      expect(gauge.name, 'Only', reason: 'sanity: it starts on the dashboard');

      await container.read(pidRegistryProvider.notifier).removeCustom(gauge);

      expect(container.read(activePidsProvider), isEmpty,
          reason: 'the user deleted their only gauge; that is a choice, not a '
              'broken layout');

      // And it has to survive a relaunch. Checking only the in-memory
      // provider left `unawaited(_persist())` removable without a failure:
      // the stale non-empty id list then resolves to nothing on the next
      // start, which is the *broken layout* branch, and the shipped gauges
      // come back.
      final relaunched = ProviderContainer(overrides: [
        sharedPreferencesProvider
            .overrideWithValue(await SharedPreferences.getInstance()),
      ]);
      addTearDown(relaunched.dispose);
      expect(relaunched.read(activePidsProvider), isEmpty,
          reason: 'the choice outlives the session that made it');
    });

    test('R10-codex: an edited definition reaches the dashboard', () async {
      // The other half of the same mechanism, and the reason the dashboard
      // cannot simply keep the objects it was built with: an edit replaces the
      // definition, and a gauge still painting the old formula is a wrong
      // number with nothing on screen to say so.
      final container = await _container({
        'custom_pids_v1': <String>[only],
        'active_pid_ids_v1': <String>['custom:7E0:010B#only'],
      });
      addTearDown(container.dispose);

      final gauge = container.read(activePidsProvider).single;
      await container
          .read(pidRegistryProvider.notifier)
          .upsertCustom(gauge.copyWith(equation: 'A*10'));

      expect(container.read(activePidsProvider).single.equation, 'A*10');
    });
  });

  test('R10-codex 04: two variants that differ only by a space stay two PIDs',
      () async {
    // Codex, round 10. `Pid.id` deliberately carries the raw `#variant`, and
    // the CSV importer takes that field verbatim — it is a user's label, not
    // a field this app owns. Canonicalising the *whole* id stripped spaces out
    // of it too, so `#raw value` and `#rawvalue` became one lookup key.
    //
    // Two definitions of `0105` with different equations then resolved to
    // whichever the registry kept last. Both gauges paint the same number,
    // one of them is wrong, and nothing on screen says which — the failure
    // this project ranks above crashes.
    String pid(String variant, String equation) =>
        '{"name":"V $variant","shortName":"V","modeAndPid":"0105",'
        '"equation":"$equation","minValue":0,"maxValue":900,"units":"",'
        '"header":"7E0","isCustom":true,"variant":"$variant"}';

    final container = await _container({
      'custom_pids_v1': <String>[pid('raw value', 'A-40'), pid('rawvalue', 'A*10')],
      'active_pid_ids_v1': <String>[
        'custom:7E0:0105#raw value',
        'custom:7E0:0105#rawvalue',
      ],
    });
    addTearDown(container.dispose);

    final active = container.read(activePidsProvider);
    expect(active, hasLength(2),
        reason: 'they are two definitions and the user put both on the '
            'dashboard');
    expect(active.map((p) => p.equation), ['A-40', 'A*10'],
        reason: 'and each keeps its own formula, or one gauge is showing the '
            "other's number");
  });

  group('an upgrade may not lose a gauge', () {
    // Codex's M-02, also reported by cursor and qwen. Canonicalising `header`
    // on load was right; it changes `Pid.id`, and nothing was taught that
    // `active_pid_ids_v1` holds the old spelling.
    const oldSpelling = '{"name":"Coolant","shortName":"CLT",'
        '"modeAndPid":"01 05","equation":"A-40","minValue":-40,'
        '"maxValue":215,"units":"°C","header":"7 E 0","isCustom":true}';

    test('R9-codex M-02: a custom gauge stored by an older build survives',
        () async {
      final container = await _container({
        'custom_pids_v1': <String>[oldSpelling],
        // The old id, beside a built-in that still resolves — which is what
        // suppressed the "nothing resolved" fallback and made the loss silent.
        'active_pid_ids_v1': <String>[
          'custom:7 E 0:01 05',
          PidLibrary.defaultDashboard.first.id,
        ],
      });
      addTearDown(container.dispose);

      final active = container.read(activePidsProvider);
      expect(active, hasLength(2),
          reason: 'the gauge was on the dashboard before the upgrade and the '
              'upgrade is not a reason to remove it');
      expect(active.any((p) => p.isCustom && p.name == 'Coolant'), isTrue);
    });

    test('R9-codex M-02: both identity fields are canonicalised, not just one',
        () async {
      final container = await _container({
        'custom_pids_v1': <String>[oldSpelling],
      });
      addTearDown(container.dispose);

      final stored = container
          .read(pidRegistryProvider)
          .firstWhere((p) => p.isCustom && p.name == 'Coolant');
      expect(stored.header, '7E0');
      expect(stored.modeAndPid, '0105');
      // The half that was left behind. `substring(2, 4)` of `01 05` is `' 0'`,
      // which parses to null — so the response splitter cannot associate a
      // valid `41 05 …` with this gauge and the reading never appears, while
      // the adapter ignores the space and answers perfectly.
      expect(stored.pidByte, 0x05,
          reason: 'the vehicle answered; the app has to be able to tell whose '
              'answer it is');
    });
  });

  group('the active dashboard layout', () {
    test('starts from the shipped defaults when nothing has been stored',
        () async {
      final container = await _container({});
      addTearDown(container.dispose);

      expect(
        container.read(activePidsProvider),
        equals(PidLibrary.defaultDashboard),
      );
    });

    test('stays empty when the user has cleared it', () async {
      final container = await _container({'active_pid_ids_v1': <String>[]});
      addTearDown(container.dispose);

      expect(
        container.read(activePidsProvider),
        isEmpty,
        reason: 'restoring the defaults here overrides a deliberate choice — '
            'every gauge came back on the next launch with no way to make the '
            'removal stick',
      );
    });

    test('falls back when every stored id has since been deleted', () async {
      // Distinct from the case above: the user chose these gauges, and the
      // definitions behind them are gone. A blank dashboard with no way to
      // recover is worse than the shipped layout.
      final container = await _container({
        'active_pid_ids_v1': <String>['custom:7E0:229999#gone'],
      });
      addTearDown(container.dispose);

      expect(
        container.read(activePidsProvider),
        equals(PidLibrary.defaultDashboard),
      );
    });
  });
}
