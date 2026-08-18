/// The wires between the engine and the screen, and what a copy must not drop.
///
/// Both of these are the same kind of gap: code that is obviously right when
/// you read it, and that nothing would notice the deletion of. Round 39 found
/// that the entire freeze-frame integration in `DtcScanNotifier` — the only
/// path between the reader and the card — could be removed with the suite
/// fully green, and separately that `withoutClearMessage()` silently dropped
/// two fields.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/obd/dtc/dtc.dart';
import 'package:torque_obd/obd/freeze_frame.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/polling_engine.dart';
import 'package:torque_obd/obd/readiness.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/dtc_scan.dart';
import 'package:torque_obd/state/obd_session.dart';

const _misfire = Dtc(
  code: 'P0301',
  category: DtcCategory.powertrain,
  kind: DtcKind.stored,
  sourceId: '7E8',
  isManufacturerSpecific: false,
);

const _frame = FreezeFrame(
  source: '7E8',
  frameNumber: 0,
  cause: _misfire,
  readings: [
    FreezeReading(pid: PidLibrary.engineRpm, value: 2856, raw: [0x2C, 0xA0]),
  ],
  undecodable: 1,
  unread: 0,
);

/// A session that answers every read from a script.
///
/// Narrower than a real one on purpose: `ObdSession` owns a transport, a
/// client and an engine, and constructing that here would be testing the
/// session rather than the wire between it and the state. What this holds is
/// exactly the wire — that `scan()` asks for the frames and keeps what comes
/// back.
class _ScriptedSession extends ObdSession {
  int freezeCalls = 0;

  @override
  ObdConnectionState build() => const ObdConnectionState(
        phase: ConnectionPhase.connected,
        kind: TransportKind.demo,
        deviceName: 'Demo ECU',
      );

  @override
  Future<List<Dtc>> readDtcs(DtcKind kind, {DateTime? deadline}) async =>
      kind == DtcKind.stored ? const [_misfire] : const [];

  @override
  Future<MilStatus?> readMilStatus({DateTime? deadline}) async =>
      const MilStatus({
        '7E8': MilSummary(
          milOn: true,
          confirmedCount: 1,
          readiness: Readiness(ignition: IgnitionType.spark, states: {}),
        ),
      });

  @override
  Future<String?> readVin({DateTime? deadline}) async => '1D4GP00R55B123456';

  @override
  Future<FreezeFrameRead> readFreezeFrames({DateTime? deadline}) async {
    freezeCalls++;
    return const FreezeFrameRead.complete([_frame]);
  }
}

void main() {
  group('a scan carries the freeze frames to the state', () {
    test('it asks for them, and keeps what comes back', () async {
      // Delete the block in `scan()` that calls `readFreezeFrames` and this is
      // the only thing that notices.
      final container = ProviderContainer(overrides: [
        obdSessionProvider.overrideWith(_ScriptedSession.new),
      ]);
      addTearDown(container.dispose);

      await container.read(dtcScanProvider.notifier).scan();
      final state = container.read(dtcScanProvider);

      expect(state.freezeFrames, hasLength(1));
      expect(state.freezeFrames.single.cause.code, 'P0301');
      expect(state.freezeFrames.single.readings, hasLength(1));
      expect(state.freezeFrames.single.undecodable, 1,
          reason: 'and the counts survive the trip, not just the values');
    });

    test('and does not ask when there is nothing to ask about', () async {
      // The read costs a round trip per frozen PID. A controller with no code
      // has no frame, and a spinner that runs twice as long on a healthy car
      // is how somebody decides the app is broken.
      // The instance the container actually builds, not a second one — an
      // earlier version of this asserted `freezeCalls` on a session it had
      // constructed itself and never registered, so the counter it checked
      // was always zero whatever the code did.
      late _NoCodes built;
      final container = ProviderContainer(overrides: [
        obdSessionProvider.overrideWith(() => built = _NoCodes()),
      ]);
      addTearDown(container.dispose);

      await container.read(dtcScanProvider.notifier).scan();
      expect(container.read(dtcScanProvider).freezeFrames, isEmpty);
      expect(built.freezeCalls, 0,
          reason: 'not asked for at all, rather than asked and discarded');
    });
  });

  group('dismissing the clear panel keeps everything else', () {
    test('the readiness card and the freeze frames both survive', () {
      // They did not. `withoutClearMessage()` listed the fields it carried by
      // hand and had not been updated twice — so closing the outcome panel, or
      // merely tapping 清除 (which goes through the same call), erased the MIL
      // and readiness card the app had already read from the car, and the
      // freeze frame the clear was about to destroy. The one record that
      // cannot be re-read, removed from the screen by the button that destroys
      // it, before anybody could look.
      //
      // Fixed structurally: it now goes through `copyWith`, so a field added
      // later is carried without anybody remembering to. This test states the
      // rule the structure enforces.
      final before = DtcScanState(
        scannedAt: DateTime(2026, 8, 17),
        results: {DtcKind.stored: const DtcCategoryResult.codes([_misfire])},
        vin: '1D4GP00R55B123456',
        optionalNotCovered: const {
          DtcKind.pending: {'7E9'}
        },
        mil: const MilStatus({
          '7E8': MilSummary(milOn: true, confirmedCount: 1),
        }),
        freezeFrames: const [_frame],
        clearMessage: '已送出清除指令',
        clearWorked: true,
        clearRepeatWouldHarm: true,
      );

      final after = before.withoutClearMessage();

      expect(after.clearMessage, isNull, reason: 'the one thing it removes');

      expect(after.mil, same(before.mil));
      expect(after.freezeFrames, same(before.freezeFrames));
      expect(after.results, same(before.results));
      expect(after.scannedAt, before.scannedAt);
      expect(after.vin, before.vin);
      expect(after.optionalNotCovered, same(before.optionalNotCovered));
      expect(after.clearWorked, isTrue);
      expect(after.clearRepeatWouldHarm, isTrue,
          reason: 'closing a message is not the same as learning what '
              'happened, and only a rescan is');
    });
  });

  group('a frame that could not be read is not a frame that is not there', () {
    // The worst of the round-40 findings by consequence, and the only one whose
    // fix needed a new fact rather than a new sentence: nothing in the model
    // could tell the two apart, so no screen could have.
    //
    // The chain it walks somebody down: a Mode 02 timeout — ordinary on a clone
    // adapter — showed no card; FIELD_GUIDE said no card means no frame was
    // stored and that this is not bad news; the next control on that screen is
    // 清除, which the same guide says destroys the frame permanently. The one
    // record of the fault actually happening, deleted because a read failed.

    test('the scan records that it tried and failed', () async {
      final container = ProviderContainer(overrides: [
        obdSessionProvider.overrideWith(() => _FreezeFails()),
      ]);
      addTearDown(container.dispose);

      await container.read(dtcScanProvider.notifier).scan();
      final state = container.read(dtcScanProvider);

      expect(state.freezeFrames, isEmpty);
      expect(state.freezeFrameUnread, isTrue,
          reason: 'and the codes it did read still stand — a freeze-frame '
              'failure must not cost the scan');
      expect(state.totalCodes, 1);
    });

    test('and does not claim it when the read succeeded with nothing',
        () async {
      // A controller that answered and said it has no frame. Same empty list,
      // opposite meaning, and the flag is what separates them.
      final container = ProviderContainer(overrides: [
        obdSessionProvider.overrideWith(() => _NoFrames()),
      ]);
      addTearDown(container.dispose);

      await container.read(dtcScanProvider.notifier).scan();
      final state = container.read(dtcScanProvider);

      expect(state.freezeFrames, isEmpty);
      expect(state.freezeFrameUnread, isFalse);
    });

    test('nor when there were no codes to have a frame for', () async {
      final container = ProviderContainer(overrides: [
        obdSessionProvider.overrideWith(() => _NoCodes()),
      ]);
      addTearDown(container.dispose);

      await container.read(dtcScanProvider.notifier).scan();
      expect(container.read(dtcScanProvider).freezeFrameUnread, isFalse,
          reason: 'not asked is not the same as asked and failed');
    });
  });
}

/// A session whose vehicle has no fault codes.
class _NoCodes extends _ScriptedSession {
  @override
  Future<List<Dtc>> readDtcs(DtcKind kind, {DateTime? deadline}) async =>
      const [];
}

/// A session whose freeze-frame read fails the way a real one does.
class _FreezeFails extends _ScriptedSession {
  @override
  Future<FreezeFrameRead> readFreezeFrames({DateTime? deadline}) async {
    freezeCalls++;
    throw const DtcReadException('凍結幀沒有讀到 —— 這不代表車上沒有。',
        kind: DtcReadFailure.noAnswer);
  }
}

/// A session whose controller answered and has no frame stored.
class _NoFrames extends _ScriptedSession {
  @override
  Future<FreezeFrameRead> readFreezeFrames({DateTime? deadline}) async {
    freezeCalls++;
    return const FreezeFrameRead.complete([]);
  }
}
