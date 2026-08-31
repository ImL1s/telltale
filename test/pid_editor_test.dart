/// The PID editor, driven through the widget rather than around it.
///
/// Codex's L-02 and half of M-02, and qwen reported the first independently.
/// Two regressions were "covered" by tests that never rendered this screen and
/// never called `_save()`: one built both `Pid` objects by hand and asserted
/// that the field it had just passed in was still there, the other exercised
/// the header normaliser as a function. Deleting the production line under
/// either changed nothing.
///
/// Everything here goes through the real widget: real controllers, the real
/// `_canSave` gate, the real `_save`, and the real registry write.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/obd/pid/pid.dart';
import 'package:torque_obd/state/pid_mutation_lock.dart';
import 'package:torque_obd/state/pid_registry.dart';
import 'package:torque_obd/ui/screens/pids/pid_editor_screen.dart';
import 'package:torque_obd/ui/screens/pids/pid_manager_screen.dart';

/// A custom PID as an older build stored it: a redline the editor has no field
/// for, and a header spelled with the spaces the field used to accept.
const _stored = '{"name":"Boost","shortName":"BST","modeAndPid":"010B",'
    '"equation":"A","minValue":0,"maxValue":300,"units":"kPa",'
    '"header":"7E0","isCustom":true,"variant":"boost","redlineFrom":250}';

Future<ProviderContainer> _container(Map<String, Object> initial) async {
  SharedPreferences.setMockInitialValues(initial);
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
}

/// The same mode+PID and variant as `_stored`, on a different controller —
/// so a *header-only* edit is enough to collide with it.
const _otherHeader = '{"name":"Elsewhere","shortName":"ELS","modeAndPid":"010B",'
    '"equation":"A","minValue":0,"maxValue":300,"units":"kPa",'
    '"header":"7E1","isCustom":true,"variant":"boost"}';

/// A second custom PID, so a dashboard can have an order worth preserving.
const _other = '{"name":"Other","shortName":"OTH","modeAndPid":"010C",'
    '"equation":"A","minValue":0,"maxValue":8000,"units":"rpm",'
    '"header":"7E0","isCustom":true,"variant":"boost"}';

/// `_save` ends in `context.pop()`, so the screen needs a router under it —
/// and pushing it rather than making it the root means the pop has somewhere
/// to go.
Widget _host(ProviderContainer container, String pidId) {
  final router = GoRouter(
    initialLocation: '/edit',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(),
        // A child route, so go_router builds the parent beneath it and the
        // editor's closing `context.pop()` has somewhere to go — which is
        // also how the app itself reaches this screen.
        routes: [
          GoRoute(
            path: 'edit',
            builder: (_, _) => PidEditorScreen(pidId: pidId),
          ),
        ],
      ),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: router),
  );
}

/// The whole form on screen at once. The save button is below the fold on the
/// default 800x600 test viewport, and scrolling to it is incidental to what
/// these tests are about.
void _tallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, '儲存'));
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String label, String text) async {
  await tester.enterText(
    find.ancestor(
      of: find.text(label),
      matching: find.byType(TextField),
    ).first,
    text,
  );
  await tester.pump();
}

void main() {
  testWidgets('R17-codex 05: a variant id survives the route it travels on',
      (tester) async {
    // Codex rounds 16 and 17. `Pid.id` ends in `#<variant>` for an imported
    // definition, and the manager interpolated it into a location string — so
    // the router read `#boost` as a URI *fragment*, handed the editor a
    // truncated id, and the screen opened blank as 新增自訂 PID. Saving then
    // created an unvarianted sibling instead of editing the PID that was
    // tapped.
    //
    // Every other editor test constructs `PidEditorScreen(pidId: …)` directly
    // and so cannot see the seam that was broken. This one goes through the
    // real route.
    _tallViewport(tester);
    final container = await _container({'custom_pids_v1': <String>[_stored]});
    final original = container.read(pidRegistryProvider).firstWhere(
          (p) => p.isCustom && p.name == 'Boost',
        );
    expect(original.id, contains('#'), reason: 'sanity: it has a variant');

    // The manager screen and the app's own editor path — the two ends of the
    // seam that was broken. An earlier version of this test built the `Uri`
    // itself, which is the producer under test: it would have passed with the
    // production line reverted, because the test had reimplemented it.
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const PidManagerScreen(),
        ),
        GoRoute(
          path: PidEditorScreen.path,
          builder: (_, state) =>
              PidEditorScreen(pidId: state.uri.queryParameters['id']),
        ),
      ],
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    // Pumped, not settled: the manager watches the telemetry stream, whose
    // periodic timer never lets `pumpAndSettle` finish.
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byIcon(Icons.edit_outlined).first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('編輯 PID'), findsOneWidget,
        reason: 'the editor opened on the PID that was tapped, not on a blank '
            'new one');
    expect(find.text('Boost'), findsWidgets);

    // Disposed inside the test, not in a tear-down: the manager subscribes to
    // the telemetry stream, whose periodic timer the widget tester counts as
    // pending unless the container is gone before the test body returns.
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pump();
  });

  testWidgets('R9-codex L-02: saving keeps the redline the editor cannot show',
      (tester) async {
    _tallViewport(tester);
    final container = await _container({'custom_pids_v1': <String>[_stored]});
    addTearDown(container.dispose);
    final original = container.read(pidRegistryProvider).firstWhere(
          (p) => p.isCustom && p.name == 'Boost',
        );
    expect(original.redlineFrom, 250, reason: 'sanity: it was stored');

    await tester.pumpWidget(_host(container, original.id));
    await tester.pumpAndSettle();

    // The one thing someone came here to change.
    await _enter(tester, '名稱', 'Boost pressure');
    await _save(tester);

    final saved = container.read(pidRegistryProvider).firstWhere(
          (p) => p.isCustom && p.name == 'Boost pressure',
        );
    expect(saved.redlineFrom, 250,
        reason: 'an editor may not destroy what it cannot show — and the '
            'gauge stops painting its red zone with nothing to say why');
    expect(saved.id, original.id, reason: 'still the same gauge');
  });

  testWidgets('device: an edit that changes the PID\'s identity saves',
      (tester) async {
    // Found on hardware, not here — which is the point of it existing here.
    //
    // `_save` only calls `registry.removeCustom` when the edit changes
    // `Pid.id`, and `removeCustom` reached back into `activePidsProvider`.
    // `ActivePids.build` watches the registry, so Riverpod refused it as a
    // circular dependency: the save threw, the editor stayed open with no
    // message, and the edit was gone.
    //
    // Both regression tests above change a name or a header value that
    // normalises to what was already stored, so neither changes the id and
    // neither calls the failing branch. Two tests, written for two different
    // reviewers' findings, covering the half that could not break.
    //
    // Changing the mode is what a real user does when they mistype a PID.
    _tallViewport(tester);
    final container = await _container({'custom_pids_v1': <String>[_stored]});
    addTearDown(container.dispose);
    final original = container.read(pidRegistryProvider).firstWhere(
          (p) => p.isCustom && p.name == 'Boost',
        );

    await tester.pumpWidget(_host(container, original.id));
    await tester.pumpAndSettle();

    await _enter(tester, '模式 + PID', '0105');
    await _save(tester);

    final saved = container
        .read(pidRegistryProvider)
        .where((p) => p.isCustom && p.name == 'Boost')
        .toList();
    expect(saved, hasLength(1),
        reason: 'the edit replaces the entry rather than leaving two, or '
            'failing silently and leaving one unchanged');
    expect(saved.single.modeAndPid, '0105');
    expect(saved.single.id, isNot(original.id),
        reason: 'sanity: this is the identity-changing branch, which is the '
            'only one that reaches the code that threw');
  });

  testWidgets('R11-codex 08: an identity-changing edit keeps its place',
      (tester) async {
    // Codex round 11. The registry listener correctly drops the old identity
    // from the dashboard, and the editor then put the replacement back with
    // `add` — which appends. A gauge the user had placed first came back last
    // every time they corrected a mistyped PID, and the order was persisted.
    _tallViewport(tester);
    final container = await _container({
      'custom_pids_v1': <String>[_stored, _other],
      'active_pid_ids_v1': <String>[
        'custom:7E0:010B#boost',
        'custom:7E0:010C#boost',
      ],
    });
    addTearDown(container.dispose);
    expect(container.read(activePidsProvider).map((p) => p.name),
        ['Boost', 'Other'],
        reason: 'sanity: this is the order the user chose');

    final original = container.read(pidRegistryProvider).firstWhere(
          (p) => p.isCustom && p.name == 'Boost',
        );
    await tester.pumpWidget(_host(container, original.id));
    await tester.pumpAndSettle();
    await _enter(tester, '模式 + PID', '0105');
    await _save(tester);

    expect(container.read(activePidsProvider).map((p) => p.name),
        ['Boost', 'Other'],
        reason: 'correcting a PID is not a request to rearrange the grid');

    // And it has to be written down. Checking only the live provider left
    // `await _persist()` removable from `insert`: the session looks right and
    // the next launch reads the intermediate list, with Boost missing
    // altogether.
    container.dispose();
    final relaunched = ProviderContainer(overrides: [
      sharedPreferencesProvider
          .overrideWithValue(await SharedPreferences.getInstance()),
    ]);
    addTearDown(relaunched.dispose);
    expect(relaunched.read(activePidsProvider).map((p) => p.name),
        ['Boost', 'Other'],
        reason: 'the corrected layout survives the app closing');
  });

  testWidgets('R12-codex 06: an edit onto another PID\'s identity is refused',
      (tester) async {
    // Codex round 12. `upsertCustom` replaces by id, so editing one custom
    // PID's mode onto another's destroyed the second silently — definition
    // gone, gauge gone, nothing said. The editor refuses instead, and names
    // what it would have collided with.
    _tallViewport(tester);
    final container = await _container({
      'custom_pids_v1': <String>[_stored, _other],
    });
    addTearDown(container.dispose);
    final original = container.read(pidRegistryProvider).firstWhere(
          (p) => p.isCustom && p.name == 'Boost',
        );

    await tester.pumpWidget(_host(container, original.id));
    await tester.pumpAndSettle();
    // `Other` is `010C` with the same header; this is the collision.
    await _enter(tester, '模式 + PID', '010C');
    await tester.pumpAndSettle();

    expect(find.textContaining('已經有一個自訂 PID'), findsOneWidget,
        reason: 'the author is told what it would have replaced');
    expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, '儲存'))
            .onPressed,
        isNull,
        reason: 'and cannot save over it');
    expect(container.read(pidRegistryProvider).where((p) => p.isCustom),
        hasLength(2),
        reason: 'both definitions are still there');
  });

  testWidgets('R14-codex 04: a collision made by editing only the header is '
      'caught too', (tester) async {
    // Codex round 14. Name and mode/PID already rebuilt through their
    // `onChanged`; the header did not, so the duplicate refusal it feeds never
    // re-ran for a header-only edit. The existing collision test changes the
    // mode, so it passed before the listener was added and would pass again if
    // it were removed — restoring the exact bypass round 13 closed.
    _tallViewport(tester);
    final container = await _container({
      'custom_pids_v1': <String>[_stored, _otherHeader],
    });
    addTearDown(container.dispose);
    final original = container.read(pidRegistryProvider).firstWhere(
          (p) => p.isCustom && p.name == 'Boost',
        );

    await tester.pumpWidget(_host(container, original.id));
    await tester.pumpAndSettle();
    // Only the header moves, onto the address the other PID already uses.
    await _enter(tester, 'CAN 標頭', '7E1');
    await tester.pumpAndSettle();

    expect(find.textContaining('已經有一個自訂 PID'), findsOneWidget,
        reason: 'the warning appears without touching anything else');
    expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, '儲存'))
            .onPressed,
        isNull);
  });

  testWidgets('R9-codex M-02: a cleared header field stores the default, not '
      'an empty string', (tester) async {
    _tallViewport(tester);
    // Codex's trigger A, also cursor's. The CSV importer substituted the app
    // default for a blank header column and the editor stored `''`, which
    // `shouldTransmit` reads as "address nothing" — so `_pollBatch` marks the
    // PID unsupported and the gauge reads exactly as it would on a car that
    // has no such sensor. The identical blank from a spreadsheet worked.
    final container = await _container({'custom_pids_v1': <String>[_stored]});
    addTearDown(container.dispose);
    final original = container.read(pidRegistryProvider).firstWhere(
          (p) => p.isCustom && p.name == 'Boost',
        );

    await tester.pumpWidget(_host(container, original.id));
    await tester.pumpAndSettle();

    await _enter(tester, 'CAN 標頭', '');
    await _save(tester);

    final saved = container.read(pidRegistryProvider).firstWhere(
          (p) => p.isCustom && p.name == 'Boost',
        );
    expect(saved.header, kDefaultHeader,
        reason: 'no preference is not the same as "do not address anything"');
  });

  testWidgets('deleting a definition asks first', (tester) async {
    // The screen already asked about the smaller of the two actions: abandoning
    // an unsaved edit got a dialog, while the bin icon in the app bar removed
    // the whole definition — and the gauge on the dashboard with it,
    // irreversibly — on one tap. This file's own header calls losing a formula
    // somebody wrote a betrayal people remember; the confirmation was on the
    // wrong action.
    _tallViewport(tester);
    final container = await _container({'custom_pids_v1': <String>[_stored]});
    addTearDown(container.dispose);
    final original = container.read(pidRegistryProvider).firstWhere(
          (p) => p.isCustom && p.name == 'Boost',
        );

    await tester.pumpWidget(_host(container, original.id));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('刪除這個 PID？'), findsOneWidget);
    // It names the one being destroyed, because a dialog that does not is a
    // dialog people confirm without reading.
    expect(find.textContaining('Boost'), findsWidgets);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(
      container.read(pidRegistryProvider).where((p) => p.name == 'Boost'),
      hasLength(1),
      reason: 'cancelled means still there',
    );

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '刪除'));
    await tester.pumpAndSettle();
    expect(
      container.read(pidRegistryProvider).where((p) => p.name == 'Boost'),
      isEmpty,
      reason: 'and confirming still deletes it',
    );
  });

  testWidgets('recording lock refuses save without closing the editor',
      (tester) async {
    _tallViewport(tester);
    final container = await _container({'custom_pids_v1': <String>[_stored]});
    addTearDown(container.dispose);
    final original = container.read(pidRegistryProvider).firstWhere(
          (pid) => pid.isCustom && pid.name == 'Boost',
        );
    final token = container
        .read(pidMutationLockProvider)
        .tryAcquire('recording')!;

    await tester.pumpWidget(_host(container, original.id));
    await tester.pumpAndSettle();
    await _enter(tester, '名稱', 'Must not save');
    await _save(tester);

    expect(find.text('編輯 PID'), findsOneWidget);
    expect(find.text('請先停止並儲存'), findsOneWidget);
    expect(
      container.read(pidRegistryProvider).where((pid) => pid.name == 'Boost'),
      hasLength(1),
    );
    expect(
      container
          .read(pidRegistryProvider)
          .where((pid) => pid.name == 'Must not save'),
      isEmpty,
    );
    container.read(pidMutationLockProvider).release(token);
  });

  testWidgets('recording lock refuses confirmed delete without closing editor',
      (tester) async {
    _tallViewport(tester);
    final container = await _container({'custom_pids_v1': <String>[_stored]});
    addTearDown(container.dispose);
    final original = container.read(pidRegistryProvider).firstWhere(
          (pid) => pid.isCustom && pid.name == 'Boost',
        );
    final token = container
        .read(pidMutationLockProvider)
        .tryAcquire('recording')!;

    await tester.pumpWidget(_host(container, original.id));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '刪除'));
    await tester.pumpAndSettle();

    expect(find.text('編輯 PID'), findsOneWidget);
    expect(find.text('請先停止並儲存'), findsOneWidget);
    expect(
      container.read(pidRegistryProvider).where((pid) => pid.name == 'Boost'),
      hasLength(1),
    );
    container.read(pidMutationLockProvider).release(token);
  });
}
