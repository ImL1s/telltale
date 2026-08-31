/// The recording has to survive the app, not just the session.
///
/// `transcript_survives_test.dart` covers the failure this app was built
/// around: a connection that does not work, where somebody is standing at the
/// car with the app open and can press 匯出紀錄. This file covers the other
/// half — Android killing a backgrounded app, a phone dying in a car park, a
/// force-stop. Those sessions are the ones most worth reading afterwards,
/// because they went wrong in a way nobody could sit and watch, and until this
/// existed they were the ones with no record at all.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/obd/transcript.dart';
import 'package:torque_obd/obd/transcript_store.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_registry.dart';
import 'package:torque_obd/state/app_share_coordinator.dart';
import 'package:torque_obd/state/artifact_operation_gate.dart';

import 'support/fake_elm327.dart';

late Directory _dir;

TranscriptStore _store() => TranscriptStore(
  directory: () async => _dir,
  destructivePolicy: _StorePolicy(),
);

ObdTranscript _transcript(String reply) => ObdTranscript()
  ..recordWrite('0100\r'.codeUnits, DateTime(2026, 8, 17, 12))
  ..recordRead('$reply\r>'.codeUnits, DateTime(2026, 8, 17, 12));

Future<ProviderContainer> _container() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
}

void main() {
  setUp(() {
    _dir = Directory.systemTemp.createTempSync('transcript-store-test');
  });
  tearDown(() {
    if (_dir.existsSync()) _dir.deleteSync(recursive: true);
  });

  test('nothing is offered when nothing has been recorded', () async {
    expect(
      await _store().load(),
      isNull,
      reason: 'a first launch must not invent a previous session',
    );
  });

  test('a saved recording comes back with its heading attached', () async {
    final transcript = ObdTranscript()
      ..recordWrite('ATZ\r'.codeUnits, DateTime(2026, 8, 17, 12))
      ..recordRead('ELM327 v1.5\r>'.codeUnits, DateTime(2026, 8, 17, 12));

    await _store().save(
      transcript,
      '# 連線方式：Bluetooth Classic\n',
      fromRealHardware: true,
    );
    final loaded = await _store().load();

    expect(loaded, isNotNull);
    expect(
      loaded!.header,
      contains('Bluetooth Classic'),
      reason:
          'bytes with no idea what produced them are most of the way to '
          'useless — the first question anybody asks of a log is which '
          'adapter',
    );
    expect(loaded.body, contains('ATZ'));
    expect(loaded.body, contains('ELM327'));
  });

  test(
    'recovered descriptor streams the complete file without whole-file loading',
    () async {
      final transcript = ObdTranscript()
        ..recordWrite('ATZ\r'.codeUnits, DateTime(2026, 8, 17, 12));
      await _store().save(
        transcript,
        '# protocol: 6\n',
        fromRealHardware: true,
      );
      final descriptor = await _store().openStreaming();
      expect(descriptor, isNotNull);
      final chunks = await descriptor!.open(maxChunkBytes: 31).toList();
      expect(chunks.every((chunk) => chunk.length <= 31), isTrue);
      final loaded = await _store().load();
      expect(
        utf8.decode(chunks.expand((chunk) => chunk).toList()),
        '${loaded!.header}${loaded.body}',
      );
    },
  );

  test(
    'streaming descriptor stays on the validated inode after path replacement',
    () async {
      final file = File('${_dir.path}/last-session.log');
      const timestamp = '2026-08-17T12:00:00.000Z';
      const original =
          '$timestamp\n#### HARDWARE 1\n# old\n#### TRANSCRIPT ####\nOLD\n';
      const replacement =
          '$timestamp\n#### HARDWARE 1\n# new\n#### TRANSCRIPT ####\nNEW\n';
      expect(utf8.encode(original).length, utf8.encode(replacement).length);
      file.writeAsStringSync(original);
      final descriptor = await _store().openStreaming();
      expect(descriptor, isNotNull);
      final next = File('${file.path}.next')..writeAsStringSync(replacement);
      next.renameSync(file.path);

      final streamed = utf8.decode(
        (await descriptor!.open(maxChunkBytes: 7).toList())
            .expand((chunk) => chunk)
            .toList(),
      );
      expect(streamed, '# old\nOLD\n');
    },
  );

  test(
    'openStreaming and clear refuse when the displayed snapshot no longer matches',
    () async {
      final store = TranscriptStore(
        directory: () async => _dir,
        destructivePolicy: _StorePolicy(),
      );
      final first = ObdTranscript()
        ..recordWrite('ATZ\r'.codeUnits, DateTime(2026, 8, 17, 12));
      expect(
        await store.save(first, '# first\n', fromRealHardware: true),
        isTrue,
      );
      final displayed = await store.load();
      expect(displayed, isNotNull);

      final second = ObdTranscript()
        ..recordWrite('ATI\r'.codeUnits, DateTime(2026, 8, 17, 12, 1));
      // Ensure the write lands at a distinct savedAt.
      await Future<void>.delayed(const Duration(milliseconds: 2));
      expect(
        await store.save(second, '# second\n', fromRealHardware: true),
        isTrue,
      );

      expect(await store.openStreaming(expected: displayed), isNull);
      final cleared = await store.clear(expected: displayed);
      expect(cleared.error, TranscriptMutationError.identityChanged);
      expect(await store.load(), isNotNull, reason: 'replacement must remain');
    },
  );

  test(
    'canonical save survives unrelated artifact work while clear contends',
    () async {
      final gate = ArtifactOperationGate();
      final token = gate.tryAcquire('other', ArtifactOperation.export).token!;
      final store = TranscriptStore(
        directory: () async => _dir,
        artifactGate: gate,
        destructivePolicy: _StorePolicy(),
      );
      expect(
        await store.save(
          _transcript('AA'),
          '# blocked\n',
          fromRealHardware: true,
        ),
        isTrue,
      );
      expect((await store.clear()).error, TranscriptMutationError.artifactBusy);
      expect(await store.load(), isNotNull);
      gate.release(token);
    },
  );

  test(
    'concurrent canonical saves still contend on their mutation lane',
    () async {
      final saveGate = ArtifactOperationGate();
      final token = saveGate
          .tryAcquire('existing-save', ArtifactOperation.install)
          .token!;
      final store = TranscriptStore(
        directory: () async => _dir,
        saveGate: saveGate,
        destructivePolicy: _StorePolicy(),
      );

      expect(
        await store.save(
          _transcript('AA'),
          '# blocked\n',
          fromRealHardware: true,
        ),
        isFalse,
      );
      expect(_dir.listSync(), isEmpty);
      saveGate.release(token);
    },
  );

  test('clear cannot overtake an in-flight canonical save', () async {
    final directory = Completer<Directory>();
    final saveGate = ArtifactOperationGate();
    final artifactGate = ArtifactOperationGate();
    final store = TranscriptStore(
      directory: () => directory.future,
      saveGate: saveGate,
      artifactGate: artifactGate,
      destructivePolicy: _StorePolicy(),
    );

    final saving = store.save(
      _transcript('AA'),
      '# saving\n',
      fromRealHardware: true,
    );
    final clear = await store.clear();

    expect(clear.error, TranscriptMutationError.artifactBusy);
    expect(artifactGate.snapshot.isIdle, isTrue);
    directory.complete(_dir);
    expect(await saving, isTrue);
    expect(await store.load(), isNotNull);
  });

  test(
    'an in-flight clear prevents a new canonical save from recreating',
    () async {
      final directory = Completer<Directory>();
      final store = TranscriptStore(
        directory: () => directory.future,
        saveGate: ArtifactOperationGate(),
        artifactGate: ArtifactOperationGate(),
        destructivePolicy: _StorePolicy(),
      );

      final clearing = store.clear();
      expect(
        await store.save(
          _transcript('AA'),
          '# blocked\n',
          fromRealHardware: true,
        ),
        isFalse,
      );
      directory.complete(_dir);
      expect((await clearing).succeeded, isTrue);
      expect(await store.load(), isNull);
    },
  );

  test('clear revalidates live driving safety after directory await', () async {
    final directory = Completer<Directory>();
    final policy = _StorePolicy();
    final store = TranscriptStore(
      directory: () => directory.future,
      artifactGate: ArtifactOperationGate(),
      destructivePolicy: policy,
    );
    File('${_dir.path}/last-session.log').writeAsStringSync('evidence');
    final clearing = store.clear();
    policy.valid = false;
    directory.complete(_dir);
    expect((await clearing).error, TranscriptMutationError.safetyChanged);
    expect(File('${_dir.path}/last-session.log').existsSync(), isTrue);
  });

  test(
    'sentinel text inside a header value is not treated as the delimiter',
    () async {
      final transcript = ObdTranscript()
        ..recordWrite('ATI\r'.codeUnits, DateTime(2026, 8, 21, 12))
        ..recordRead('ELM327 v1.5\r>'.codeUnits, DateTime(2026, 8, 21, 12));
      const header =
          '# adapter identity: clone #### TRANSCRIPT #### rev A\n'
          '# protocol: 6\n';
      final expectedBody = transcript.renderHex();

      expect(
        await _store().save(transcript, header, fromRealHardware: true),
        isTrue,
      );
      final loaded = await _store().load();

      expect(loaded, isNotNull);
      expect(loaded!.header, header);
      expect(loaded.body, expectedBody);
    },
  );

  test('an empty session writes nothing', () async {
    await _store().save(ObdTranscript(), '# header\n', fromRealHardware: true);
    expect(
      await _store().load(),
      isNull,
      reason: 'offering an empty log implies something was recorded',
    );
  });

  test(
    'a storage error is reported without escaping into the session',
    () async {
      final store = TranscriptStore(
        directory: () async => throw const FileSystemException('disk full'),
      );
      final transcript = ObdTranscript()..recordNote('worth keeping');

      expect(
        await store.save(transcript, '# header\n', fromRealHardware: true),
        isFalse,
      );
    },
  );

  test('a later session replaces the earlier one', () async {
    // Deliberately one file. The point is "what happened last time", and a
    // growing pile of logs on a phone is a thing nobody ever prunes.
    final first = ObdTranscript()
      ..recordWrite('0100\r'.codeUnits, DateTime(2026, 8, 17, 12));
    final second = ObdTranscript()
      ..recordWrite('ATDPN\r'.codeUnits, DateTime(2026, 8, 17, 13));

    await _store().save(first, '# one\n', fromRealHardware: true);
    await _store().save(second, '# two\n', fromRealHardware: true);

    final loaded = await _store().load();
    expect(loaded!.header, contains('two'));
    expect(loaded.body, contains('ATDPN'));
    expect(loaded.body, isNot(contains('0100')));
  });

  test('save captures the transcript before its first await', () async {
    final directoryGate = Completer<Directory>();
    final store = TranscriptStore(directory: () => directoryGate.future);
    final transcript = ObdTranscript()
      ..recordNote('before save', DateTime.utc(2026, 8, 21, 3));

    final saving = store.save(transcript, '# frozen\n', fromRealHardware: true);
    transcript.recordNote(
      'after save started',
      DateTime.utc(2026, 8, 21, 3, 0, 1),
    );
    directoryGate.complete(_dir);
    await saving;

    final loaded = await store.load();
    expect(loaded, isNotNull);
    expect(loaded!.body, contains('before save'));
    expect(
      loaded.body,
      isNot(contains('after save started')),
      reason:
          'the file must describe the exact moment save was requested, '
          'not whichever entries happened to arrive while storage was awaited',
    );
  });

  test('a half-written file does not replace a complete one', () async {
    // Why the write is staged and renamed. A process killed midway would
    // otherwise swap a complete recording of the session that failed for a
    // fragment of the one that has not finished — losing the evidence at the
    // exact moment it is being collected.
    final good = ObdTranscript()
      ..recordWrite('0100\r'.codeUnits, DateTime(2026, 8, 17, 12));
    await _store().save(good, '# complete\n', fromRealHardware: true);

    File('${_dir.path}/last-session.log.part')
        .writeAsStringSync('this is a torn write');

    final loaded = await _store().load();
    expect(
      loaded!.header,
      contains('complete'),
      reason: 'the staging file is not the one that is read',
    );
  });

  test('a corrupt file reads as no recording rather than throwing', () async {
    File('${_dir.path}/last-session.log').writeAsStringSync('garbage');
    expect(await _store().load(), isNull);
  });

  test('taking it away removes it', () async {
    final transcript = ObdTranscript()
      ..recordWrite('0100\r'.codeUnits, DateTime(2026, 8, 17, 12));
    await _store().save(transcript, '# header\n', fromRealHardware: true);
    expect(await _store().load(), isNotNull);

    await _store().clear();
    expect(await _store().load(), isNull);
  });

  test('a session that ends leaves its recording on disk', () async {
    // The end-to-end rule, through the real session rather than the store.
    // Every way a connection ends goes through `_teardown`, which is why the
    // snapshot is taken there rather than at each of them.
    final container = await _container();
    var disposed = false;
    addTearDown(() {
      if (!disposed) container.dispose();
    });
    final session = container.read(obdSessionProvider.notifier);
    session.transcriptStore = _store();

    expect(
      await session.connectForTest(
        FakeElm327(
          protocol: BusProtocol.can11,
          ecus: [
            FakeEcu(
              name: 'ECM',
              requestId: '7E0',
              responseId: '7E8',
              responses: {
                '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
              },
            ),
          ],
        ),
        TransportKind.wifi,
      ),
      isTrue,
    );
    await session.disconnect();
    // Production teardown remains unawaited, but the test must drain the
    // actual snapshot chain rather than sleep and leak a late write/save-gate
    // owner into the next case.
    container.dispose();
    disposed = true;
    await session.drainTranscriptSnapshotsForTest();

    final loaded = await _store().load();
    expect(
      loaded,
      isNotNull,
      reason:
          'a session that has ended is exactly the one somebody comes '
          'back to read',
    );
    expect(
      loaded!.body,
      contains('ATZ'),
      reason: 'and the handshake is the part that says why it failed',
    );
  });

  group('a simulator session cannot destroy a real one', () {
    // The scenario is the ordinary one, not a contrived one. The connection
    // fails in the car and the phone kills the app — which is the entire
    // reason this file exists. Back at home the owner opens the app to see
    // whether it is all right, taps the Demo simulator because FIELD_GUIDE
    // tells them to, and presses Home. The pause handler saved a simulator
    // transcript over the only record of the failure, with no prompt, and
    // nothing on screen had ever mentioned that a recording existed.

    test('demo does not overwrite hardware', () async {
      final store = _store();
      expect(
        await store.save(
          _transcript('7E8 41 0C 1A F8'),
          'real adapter\n',
          fromRealHardware: true,
        ),
        isTrue,
      );
      expect(
        await store.save(
          _transcript('7E8 41 0C 00 00'),
          'Demo ECU\n',
          fromRealHardware: false,
        ),
        isTrue,
      );

      final kept = await store.load();
      expect(kept, isNotNull);
      expect(kept!.header, contains('real adapter'));
      expect(kept.fromRealHardware, isTrue);
    });

    test(
      'but hardware overwrites hardware, and demo overwrites demo',
      () async {
        // The rule is about diagnostic value, not about being precious with the
        // file. A newer real session is the one worth keeping, and a simulator
        // recording is better than nothing when nothing else is there.
        final store = _store();
        await store.save(
          _transcript('AA'),
          'first adapter\n',
          fromRealHardware: true,
        );
        await store.save(
          _transcript('BB'),
          'second adapter\n',
          fromRealHardware: true,
        );
        expect((await store.load())!.header, contains('second adapter'));

        // Cleared first: the half above left a hardware recording in the same
        // directory, which would refuse both demo saves and make this pass for
        // the wrong reason.
        await _store().clear();
        final fresh = _store();
        await fresh.save(
          _transcript('CC'),
          'Demo one\n',
          fromRealHardware: false,
        );
        await fresh.save(
          _transcript('DD'),
          'Demo two\n',
          fromRealHardware: false,
        );
        final kept = await fresh.load();
        expect(kept!.header, contains('Demo two'));
        expect(kept.fromRealHardware, isFalse);
      },
    );

    test(
      'a file written before the marker existed reads as hardware',
      () async {
        // The safe direction. Treating an unmarked recording as a simulator one
        // would let the next Demo session delete it, which is the failure this
        // whole group is about — arriving through the upgrade path instead.
        final store = _store();
        final file = File('${_dir.path}/last-session.log');
        await file.writeAsString(
          '${DateTime.now().toIso8601String()}\n'
          'old adapter\n'
          '#### TRANSCRIPT ####\n'
          '7E8 41 0C 1A F8\n',
        );

        final loaded = await store.load();
        expect(loaded, isNotNull);
        expect(loaded!.fromRealHardware, isTrue);
        expect(loaded.header, contains('old adapter'));

        await store.save(
          _transcript('ZZ'),
          'Demo ECU\n',
          fromRealHardware: false,
        );
        expect((await store.load())!.header, contains('old adapter'));
      },
    );
  });

  test('two saves that overlap do not interleave into one file', () async {
    // They genuinely overlap: the watchdog declaring the link dead at the
    // moment the app is backgrounded runs the pause handler and the teardown
    // handler together. Both opened the same staging file and wrote a few
    // hundred kilobytes across many syscalls, so the two could interleave into
    // a file that is neither — and the rename then installed the wreckage.
    //
    // Worse than losing one save. `load()` returns null on a corrupt file, and
    // the guard that stops a simulator overwriting hardware asks `load()`
    // first: a corrupted recording silently withdrew its own protection.
    var inFlight = 0;
    var overlapped = false;
    final store = _CountingStore(
      () async => _dir,
      onEnter: () {
        inFlight++;
        if (inFlight > 1) overlapped = true;
      },
      onExit: () => inFlight--,
    );

    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);
    session.transcriptStore = store;

    expect(
      await session.connectForTest(
        FakeElm327(
          protocol: BusProtocol.can11,
          ecus: [
            FakeEcu(
              name: 'ECM',
              requestId: '7E0',
              responseId: '7E8',
              responses: {
                '0100': [0x41, 0x00, 0x00, 0x08, 0x00, 0x00],
              },
            ),
          ],
        ),
        TransportKind.wifi,
      ),
      isTrue,
    );

    // Both handlers, fired together.
    await Future.wait([
      session.saveTranscriptSnapshotForTest(),
      session.saveTranscriptSnapshotForTest(),
      session.saveTranscriptSnapshotForTest(),
    ]);

    expect(
      overlapped,
      isFalse,
      reason: 'the writes are queued, not concurrent',
    );
    final loaded = await store.load();
    expect(loaded, isNotNull, reason: 'and the file is readable afterwards');
  });
}

/// A store that reports whether two saves were ever inside it at once.
class _CountingStore extends TranscriptStore {
  _CountingStore(
    Future<Directory> Function() directory, {
    required this.onEnter,
    required this.onExit,
  }) : super(directory: directory);

  final void Function() onEnter;
  final void Function() onExit;

  @override
  Future<bool> save(
    ObdTranscript transcript,
    String header, {
    required bool fromRealHardware,
  }) async {
    onEnter();
    try {
      // A turn of the loop, so an unserialised caller has somewhere to slip in.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return await super.save(
        transcript,
        header,
        fromRealHardware: fromRealHardware,
      );
    } finally {
      onExit();
    }
  }
}

class _StorePolicy implements AppSharePolicy {
  bool valid = true;

  @override
  SharePreparationPermit? freeze() => const SharePreparationPermit(
    recorderEpoch: 1,
    foregroundEpoch: 1,
    connectionEpoch: 1,
    safetyEpoch: 1,
    connectionClass: ShareConnectionClass.disconnected,
  );

  @override
  SharePermitValidation validate(SharePreparationPermit permit) => valid
      ? const SharePermitValidation.valid()
      : const SharePermitValidation.invalid(SharePermitCause.moving);
}
