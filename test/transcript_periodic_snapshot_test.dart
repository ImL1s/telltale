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

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  Future<void> save(
    ObdTranscript transcript,
    String header, {
    required bool fromRealHardware,
  }) {
    saves++;
    return super.save(transcript, header, fromRealHardware: fromRealHardware);
  }
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _dir = Directory.systemTemp.createTempSync('transcript-periodic-test');
  });
  tearDown(() {
    if (_dir.existsSync()) _dir.deleteSync(recursive: true);
  });

  test('a session still running has already written its recording', () async {
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);
    session.transcriptStore = _store();
    session.snapshotInterval = const Duration(milliseconds: 40);

    expect(await session.connectForTest(_adapter(), TransportKind.wifi), isTrue,
        reason: 'the fixture must connect');

    // Nothing has been paused. Nothing has been torn down. The session is
    // exactly as it would be while somebody is driving, and this is the state
    // in which the app used to have nothing on disk at all.
    await Future<void>.delayed(const Duration(milliseconds: 250));

    final stored = await _store().load();
    expect(stored, isNotNull,
        reason: 'a live session must not be one crash away from leaving '
            'nothing behind');
    expect(stored!.body, isNotEmpty);
    expect(stored.fromRealHardware, isTrue,
        reason: 'a wifi adapter is hardware, so this recording may not be '
            'overwritten by a later simulator session');
  });

  test('a session with nothing new to say stops rewriting the file', () async {
    final store = _CountingStore();
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);
    session.transcriptStore = store;
    session.snapshotInterval = const Duration(milliseconds: 30);

    expect(await session.connectForTest(_adapter(), TransportKind.wifi), isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 150));
    await session.disconnect();
    final afterTraffic = store.saves;
    expect(afterTraffic, greaterThan(0));

    // The session is over, so nothing can be added to the recording. Every
    // further tick has the same bytes to write as the last one, and writing
    // a few hundred kilobytes on a timer for no reason is a real cost on a
    // phone that is also driving a gauge at 20 Hz.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(store.saves, afterTraffic,
        reason: 'the throttle must be on new bytes, not on the clock');
  });

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
    expect(transcript.recorded, 3,
        reason: 'three were recorded even though one was dropped');
  });
}
