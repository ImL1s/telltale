/// The recording has to survive the app dying without warning.
///
/// `transcript_store_test.dart` covers the orderly deaths: the app is paused
/// and then killed, or the session ends. Both run a handler, and the handler
/// writes the snapshot. This file covers the death that runs no handler at all
/// — the process is gone between one line and the next.
///
/// Measured on a Pixel 9 emulator, 2026-08-20, before this existed:
///
///   * home, then `am force-stop` -> the recording was on disk and offered on
///     the next launch. `onPause` had run.
///   * `am crash` from the foreground -> `FATAL EXCEPTION`, the process died,
///     and the next launch offered nothing. The whole session was gone.
///
/// The second is not an exotic case. It is the app crashing in a car, which is
/// the exact session somebody would need to send back, and it was the one with
/// no record at all. So a live session now writes as it goes, and the most a
/// crash can cost is the interval.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/core/field_evidence/platform_metadata.dart';
import 'package:torque_obd/obd/transcript.dart';
import 'package:torque_obd/obd/transcript_store.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_registry.dart';

import 'support/fake_elm327.dart';

late Directory _dir;

TranscriptStore _store() => TranscriptStore(directory: () async => _dir);

/// Counts writes so the throttle can be checked, not just the first write.
class _CountingStore extends TranscriptStore {
  _CountingStore() : super(directory: () async => _dir);

  int saves = 0;

  @override
  Future<bool> save(
    ObdTranscript transcript,
    String header, {
    required bool fromRealHardware,
  }) {
    saves++;
    return super.save(transcript, header, fromRealHardware: fromRealHardware);
  }
}

class _GateStore extends TranscriptStore {
  _GateStore() : super(directory: () async => _dir);

  final firstStarted = Completer<void>();
  final releaseFirst = Completer<void>();
  final bodies = <String>[];
  final recordedMarks = <int>[];

  @override
  Future<bool> save(
    ObdTranscript transcript,
    String header, {
    required bool fromRealHardware,
  }) async {
    bodies.add(transcript.renderHex(header: header));
    recordedMarks.add(transcript.recorded);
    if (bodies.length == 1) {
      firstStarted.complete();
      await releaseFirst.future;
    }
    return true;
  }
}

class _FailingStore extends TranscriptStore {
  _FailingStore() : super(directory: () async => _dir);

  @override
  Future<bool> save(
    ObdTranscript transcript,
    String header, {
    required bool fromRealHardware,
  }) async => false;
}

FakeElm327 _adapter() => FakeElm327(
  protocol: BusProtocol.can11,
  ecus: [
    FakeEcu(
      name: 'ECM',
      requestId: '7E0',
      responseId: '7E8',
      responses: {
        '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
        '010C': [0x41, 0x0C, 0x1A, 0xF8],
        '010D': [0x41, 0x0D, 0x40],
      },
    ),
  ],
);

Future<ProviderContainer> _container() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
}

ObdSession _sessionWithDeterministicCleanup(ProviderContainer container) {
  final session = container.read(obdSessionProvider.notifier);
  addTearDown(() async {
    container.dispose();
    await session.drainTranscriptSnapshotsForTest();
  });
  return session;
}

_GateStore _gateStoreWithCleanup() {
  final store = _GateStore();
  addTearDown(() {
    if (!store.releaseFirst.isCompleted) store.releaseFirst.complete();
  });
  return store;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _dir = Directory.systemTemp.createTempSync('transcript-periodic-test');
  });
  tearDown(() {
    if (_dir.existsSync()) _dir.deleteSync(recursive: true);
  });

  test('a session still running has already written its recording', () async {
    final container = await _container();
    final session = _sessionWithDeterministicCleanup(container);
    session.transcriptStore = _store();
    session.snapshotInterval = const Duration(milliseconds: 40);

    expect(
      await session.connectForTest(_adapter(), TransportKind.wifi),
      isTrue,
      reason: 'the fixture must connect',
    );

    // Nothing has been paused. Nothing has been torn down. The session is
    // exactly as it would be while somebody is driving, and this is the state
    // in which the app used to have nothing on disk at all.
    await Future<void>.delayed(const Duration(milliseconds: 250));

    final stored = await _store().load();
    expect(
      stored,
      isNotNull,
      reason:
          'a live session must not be one crash away from leaving '
          'nothing behind',
    );
    expect(stored!.body, isNotEmpty);
    expect(
      stored.fromRealHardware,
      isTrue,
      reason:
          'a wifi adapter is hardware, so this recording may not be '
          'overwritten by a later simulator session',
    );
  });

  test('a session with nothing new to say stops rewriting the file', () async {
    final store = _CountingStore();
    final container = await _container();
    final session = _sessionWithDeterministicCleanup(container);
    session.transcriptStore = store;
    session.snapshotInterval = const Duration(milliseconds: 30);

    expect(
      await session.connectForTest(_adapter(), TransportKind.wifi),
      isTrue,
    );

    await Future<void>.delayed(const Duration(milliseconds: 150));
    await session.disconnect();
    final afterTraffic = store.saves;
    expect(afterTraffic, greaterThan(0));

    // The session is over, so nothing can be added to the recording. Every
    // further tick has the same bytes to write as the last one, and writing
    // a few hundred kilobytes on a timer for no reason is a real cost on a
    // phone that is also driving a gauge at 20 Hz.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(
      store.saves,
      afterTraffic,
      reason: 'the throttle must be on new bytes, not on the clock',
    );
  });

  test(
    'provider disposal queues its final snapshot without waiting for disk',
    () async {
      final container = await _container();
      final session = _sessionWithDeterministicCleanup(container);
      final store = _gateStoreWithCleanup();
      session.transcriptStore = store;
      session.snapshotInterval = const Duration(hours: 1);

      expect(
        await session.connectForTest(_adapter(), TransportKind.wifi),
        isTrue,
      );

      var disposeReturned = false;
      var drainCompleted = false;
      Future<void>? drain;
      try {
        container.dispose();
        disposeReturned = true;
        await store.firstStarted.future;

        drain = session.drainTranscriptSnapshotsForTest();
        unawaited(drain.then((_) => drainCompleted = true));

        expect(
          disposeReturned,
          isTrue,
          reason: 'provider disposal must not wait for filesystem persistence',
        );
        expect(
          drainCompleted,
          isFalse,
          reason: 'the test drain must still represent the gate-blocked save',
        );

        store.releaseFirst.complete();
        await drain;
        expect(drainCompleted, isTrue);
      } finally {
        if (!store.releaseFirst.isCompleted) store.releaseFirst.complete();
        await (drain ?? session.drainTranscriptSnapshotsForTest());
      }
    },
  );

  test('the transcript counts everything it has ever held', () {
    // What the throttle asks. It has to keep rising while the ring buffer is
    // full and dropping, otherwise a long session stops being saved at exactly
    // the point it has the most to say.
    final transcript = ObdTranscript(maxEntries: 2);
    expect(transcript.recorded, 0);

    transcript.recordWrite('0100\r'.codeUnits, DateTime(2026, 8, 20, 12));
    expect(transcript.recorded, 1);

    transcript.recordRead('41 00\r'.codeUnits, DateTime(2026, 8, 20, 12));
    transcript.recordNote('note', DateTime(2026, 8, 20, 12));
    expect(transcript.entries.length, 2, reason: 'the buffer is full');
    expect(transcript.dropped, 1);
    expect(
      transcript.recorded,
      3,
      reason: 'three were recorded even though one was dropped',
    );
  });

  test(
    'a stationary field marker is recorded and snapshotted immediately',
    () async {
      final container = await _container();
      final session = _sessionWithDeterministicCleanup(container);
      session
        ..transcriptStore = _store()
        ..snapshotInterval = const Duration(hours: 1)
        ..platformMetadata = const PlatformMetadata(
          applicationId: androidFieldApplicationId,
          appVersion: '1.0.4',
          appBuild: '5',
          platform: 'android',
          osVersion: '16',
          manufacturer: 'Google',
          model: 'Pixel 9',
          sdkInt: '36',
        );

      expect(
        await session.connectForTest(_adapter(), TransportKind.wifi),
        isTrue,
      );
      expect(
        await session.recordFieldEvent(FieldEventMarker.engineStarted),
        FieldEventRecordResult.persisted,
      );

      final live = session.exportableTranscript!.render();
      expect(live, contains('實車事件：引擎發動'));

      final stored = await _store().load();
      expect(stored, isNotNull);
      expect(stored!.body, contains('實車事件：引擎發動'));
    },
  );

  test('a field marker without a session records and saves nothing', () async {
    final container = await _container();
    final session = _sessionWithDeterministicCleanup(container);
    final store = _CountingStore();
    session.transcriptStore = store;

    expect(
      await session.recordFieldEvent(FieldEventMarker.ignitionOn),
      FieldEventRecordResult.unavailable,
    );
    expect(store.saves, 0);
    expect(session.hasTranscript, isFalse);
  });

  test('a field marker cannot alter a session after disconnect', () async {
    final container = await _container();
    final session = _sessionWithDeterministicCleanup(container);
    session.transcriptStore = _store();

    expect(
      await session.connectForTest(_adapter(), TransportKind.wifi),
      isTrue,
    );
    await session.disconnect();
    final before = session.exportableTranscript!.recorded;
    expect(session.exportableTranscript!.render(), contains('連線事件：使用者中斷連線'));

    expect(
      await session.recordFieldEvent(FieldEventMarker.roadTestStarted),
      FieldEventRecordResult.unavailable,
    );
    expect(session.exportableTranscript!.recorded, before);
    expect(
      session.exportableTranscript!.render(),
      isNot(contains('實車事件：道路測試開始')),
    );
  });

  test(
    'a field-package demo stays simulated and cannot replace hardware evidence',
    () async {
      final store = _store();
      final hardware = ObdTranscript()..recordNote('physical adapter evidence');
      expect(
        await store.save(hardware, '# hardware\n', fromRealHardware: true),
        isTrue,
      );

      final container = await _container();
      final session = _sessionWithDeterministicCleanup(container);
      session
        ..transcriptStore = store
        ..snapshotInterval = const Duration(hours: 1)
        ..testRigBuild = false
        ..platformMetadata = const PlatformMetadata(
          applicationId: androidFieldApplicationId,
          appVersion: '1.0.4',
          appBuild: '5',
          platform: 'android',
          osVersion: '16',
          manufacturer: 'Google',
          model: 'Pixel 9',
          sdkInt: '36',
        );

      expect(await session.connectDemo(), isTrue);
      expect(session.transcriptHeader, contains('無車測試馬具證據'));
      expect(session.transcriptHeader, isNot(contains('Telltale 實車證據')));
      expect(
        await session.recordFieldEvent(FieldEventMarker.engineStarted),
        FieldEventRecordResult.unavailable,
      );
      expect(
        session.exportableTranscript!.render(),
        isNot(contains('實車事件：引擎發動')),
      );

      await session.saveTranscriptSnapshotForTest();
      final stored = await store.load();
      expect(stored, isNotNull);
      expect(stored!.fromRealHardware, isTrue);
      expect(stored.body, contains('physical adapter evidence'));
      expect(stored.body, isNot(contains('開始連線')));
    },
  );

  test(
    'the .rig app cannot create field markers or replace hardware evidence',
    () async {
      final store = _store();
      final hardware = ObdTranscript()..recordNote('physical adapter evidence');
      expect(
        await store.save(hardware, '# hardware\n', fromRealHardware: true),
        isTrue,
      );

      final container = await _container();
      final session = _sessionWithDeterministicCleanup(container);
      session
        ..transcriptStore = store
        ..snapshotInterval = const Duration(hours: 1)
        ..testRigBuild = false
        ..platformMetadata = const PlatformMetadata(
          applicationId: 'com.cbstudio.telltale.rig',
          appVersion: '1.0.4-rig',
          appBuild: '5',
          platform: 'android',
          osVersion: '16',
          manufacturer: 'Google',
          model: 'Pixel 9',
          sdkInt: '36',
        );

      expect(
        await session.connectForTest(_adapter(), TransportKind.wifi),
        isTrue,
      );
      expect(
        await session.recordFieldEvent(FieldEventMarker.engineStarted),
        FieldEventRecordResult.unavailable,
      );
      expect(
        session.exportableTranscript!.render(),
        isNot(contains('實車事件：引擎發動')),
      );
      expect(session.transcriptHeader, contains('無車測試馬具證據'));

      await session.saveTranscriptSnapshotForTest();
      final stored = await store.load();
      expect(stored, isNotNull);
      expect(stored!.fromRealHardware, isTrue);
      expect(stored.body, contains('physical adapter evidence'));
      expect(stored.body, isNot(contains('開始連線')));
    },
  );

  test(
    'unknown Android package provenance fails closed as rig evidence',
    () async {
      final store = _store();
      final hardware = ObdTranscript()..recordNote('physical adapter evidence');
      expect(
        await store.save(hardware, '# hardware\n', fromRealHardware: true),
        isTrue,
      );

      final container = await _container();
      final session = _sessionWithDeterministicCleanup(container);
      session
        ..transcriptStore = store
        ..snapshotInterval = const Duration(hours: 1)
        ..testRigBuild = false
        ..platformMetadata = const PlatformMetadata(
          appVersion: 'unknown',
          appBuild: 'unknown',
          platform: 'android',
          osVersion: 'Android 16',
          manufacturer: 'unknown',
          model: 'unknown',
          sdkInt: 'unknown',
        );

      expect(
        await session.connectForTest(_adapter(), TransportKind.wifi),
        isTrue,
      );
      expect(session.transcriptHeader, contains('無車測試馬具證據'));
      expect(session.transcriptHeader, isNot(contains('Telltale 實車證據')));
      expect(
        await session.recordFieldEvent(FieldEventMarker.engineStarted),
        FieldEventRecordResult.unavailable,
      );
      expect(
        session.exportableTranscript!.render(),
        isNot(contains('實車事件：引擎發動')),
      );

      await session.saveTranscriptSnapshotForTest();
      final stored = await store.load();
      expect(stored, isNotNull);
      expect(stored!.fromRealHardware, isTrue);
      expect(stored.body, contains('physical adapter evidence'));
      expect(stored.body, isNot(contains('開始連線')));
    },
  );

  test(
    'an unexpected Android package cannot mark or replace hardware evidence',
    () async {
      final store = _store();
      final hardware = ObdTranscript()..recordNote('physical adapter evidence');
      expect(
        await store.save(hardware, '# hardware\n', fromRealHardware: true),
        isTrue,
      );

      final container = await _container();
      final session = _sessionWithDeterministicCleanup(container);
      session
        ..transcriptStore = store
        ..snapshotInterval = const Duration(hours: 1)
        ..testRigBuild = false
        ..platformMetadata = const PlatformMetadata(
          applicationId: 'com.example.repackaged',
          appVersion: '1.0.4',
          appBuild: '5',
          platform: 'android',
          osVersion: 'Android 16',
          manufacturer: 'Google',
          model: 'Pixel 9',
          sdkInt: '36',
        );

      expect(
        await session.connectForTest(_adapter(), TransportKind.wifi),
        isTrue,
      );
      expect(session.transcriptHeader, contains('無車測試馬具證據'));
      expect(session.transcriptHeader, isNot(contains('Telltale 實車證據')));
      expect(
        await session.recordFieldEvent(FieldEventMarker.engineStarted),
        FieldEventRecordResult.unavailable,
      );
      expect(
        session.exportableTranscript!.render(),
        isNot(contains('實車事件：引擎發動')),
      );

      await session.saveTranscriptSnapshotForTest();
      final stored = await store.load();
      expect(stored, isNotNull);
      expect(stored!.fromRealHardware, isTrue);
      expect(stored.body, contains('physical adapter evidence'));
      expect(stored.body, isNot(contains('開始連線')));
    },
  );

  test('a failed marker snapshot is reported as memory-only', () async {
    final container = await _container();
    final session = _sessionWithDeterministicCleanup(container);
    session.transcriptStore = _FailingStore();
    session.snapshotInterval = const Duration(hours: 1);

    expect(
      await session.connectForTest(_adapter(), TransportKind.wifi),
      isTrue,
    );
    expect(
      await session.recordFieldEvent(FieldEventMarker.throttleBlip),
      FieldEventRecordResult.memoryOnly,
    );
    expect(
      session.exportableTranscript!.render(),
      contains('實車事件：輕踩油門'),
      reason: 'disk failure must not erase the in-memory evidence',
    );
  });

  test(
    'pause and resume events share the wire timeline and pause saves',
    () async {
      final container = await _container();
      final session = _sessionWithDeterministicCleanup(container);
      session.transcriptStore = _store();
      session.snapshotInterval = const Duration(hours: 1);
      expect(
        await session.connectForTest(_adapter(), TransportKind.wifi),
        isTrue,
      );

      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await Future<void>.delayed(const Duration(milliseconds: 250));

      final paused = await _store().load();
      expect(paused, isNotNull);
      expect(paused!.body, contains('App 進入背景'));

      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 400));

      final text = session.exportableTranscript!.render();
      final resumedAt = text.lastIndexOf('App 回到前景');
      final probeAt = text.indexOf(r'>> ATRV\r', resumedAt);
      expect(resumedAt, greaterThanOrEqualTo(0));
      expect(
        probeAt,
        greaterThan(resumedAt),
        reason:
            'the resume marker must precede the link revalidation it explains',
      );
    },
  );

  test(
    'unexpected link loss survives teardown as an automatic event',
    () async {
      final container = await _container();
      final session = _sessionWithDeterministicCleanup(container);
      final adapter = _adapter();
      expect(await session.connectForTest(adapter, TransportKind.wifi), isTrue);
      adapter.dropLinkAfterWritingFor = const {'ATRV'};

      unawaited(session.sendManualCommand('ATRV').catchError((_) => ''));
      for (
        var i = 0;
        i < 40 && container.read(obdSessionProvider).isConnected;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }

      expect(container.read(obdSessionProvider).isConnected, isFalse);
      expect(session.exportableTranscript!.render(), contains('連線事件：轉接器連線中斷'));
    },
  );

  test(
    'a queued snapshot freezes its bytes at the trigger, not later',
    () async {
      final container = await _container();
      final session = _sessionWithDeterministicCleanup(container);
      final store = _gateStoreWithCleanup();
      session.transcriptStore = store;
      session.snapshotInterval = const Duration(hours: 1);
      expect(
        await session.connectForTest(_adapter(), TransportKind.wifi),
        isTrue,
      );

      final first = session.saveTranscriptSnapshotForTest();
      await store.firstStarted.future;
      session.exportableTranscript!.recordNote('第二份之前');
      final second = session.saveTranscriptSnapshotForTest();
      session.exportableTranscript!.recordNote('第二份觸發之後');

      store.releaseFirst.complete();
      await Future.wait([first, second]);

      expect(store.bodies, hasLength(2));
      expect(store.bodies[1], contains('第二份之前'));
      expect(
        store.bodies[1],
        isNot(contains('第二份觸發之後')),
        reason:
            'a save queued behind another must still describe the exact '
            'moment its trigger fired',
      );
    },
  );

  test(
    'an old save cannot mark a new session as already snapshotted',
    () async {
      final container = await _container();
      final session = _sessionWithDeterministicCleanup(container);
      final store = _gateStoreWithCleanup();
      session.transcriptStore = store;
      session.snapshotInterval = const Duration(hours: 1);

      expect(
        await session.connectForTest(_adapter(), TransportKind.wifi),
        isTrue,
      );
      for (var i = 0; i < 1000; i++) {
        session.exportableTranscript!.recordNote('old-$i');
      }

      final blockedOldSave = session.saveTranscriptSnapshotForTest();
      await store.firstStarted.future;

      expect(
        await session.connectForTest(_adapter(), TransportKind.wifi),
        isTrue,
        reason: 'a storage write must not block reconnecting',
      );

      store.releaseFirst.complete();
      await blockedOldSave;
      for (var i = 0; i < 20 && store.recordedMarks.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(
        store.recordedMarks,
        hasLength(greaterThanOrEqualTo(2)),
        reason: 'teardown also queues the old session final snapshot',
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final oldRecordedMark = store.recordedMarks.last;
      final current = session.exportableTranscript!;
      expect(current.recorded, lessThan(oldRecordedMark));
      while (current.recorded < oldRecordedMark) {
        current.recordNote('new-padding');
      }

      expect(
        await session.savePeriodicSnapshotForTest(),
        isTrue,
        reason:
            'equal entry counts from different transcript objects are not the '
            'same saved state',
      );
      expect(store.recordedMarks, hasLength(greaterThanOrEqualTo(3)));
    },
  );
}
