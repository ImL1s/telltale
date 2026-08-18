/// Refusing to send a request is a statement about the request.
///
/// The poller keeps a last-line-of-defence allowlist: a stored definition whose
/// service is not a read-only query never goes on the wire, however it got into
/// the registry. That refusal is correct and is not in question here. What was
/// wrong is what the user was told about it — `PidFault.unsupported`, which
/// `telemetry.dart` documents as "the only state that justifies telling the
/// user the car lacks the sensor", and which the dashboard renders as
/// 此車輛不支援 over a blanked-out dial.
///
/// Nothing had been asked of the vehicle. `02 05` is a Mode 02 request missing
/// its frame number, so the app declined to transmit it — and then reported the
/// verdict as the car's. The same file had already split `headerNotOnThisBus`
/// out of `unsupported` for exactly this reason, one screen away; this is that
/// distinction applied to the other refusal.
///
/// The second assertion in each test is the one that keeps two screens
/// agreeing. `PidManagerScreen` asks `engine.isKnownUnsupported`, which is a
/// different source of truth from the fault map the dashboard reads — so the
/// list could call a PID supported while the tile called it unsupported, about
/// the same definition, in the same session.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/pid/pid.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/polling_engine.dart';
import 'package:torque_obd/obd/telemetry.dart';

import 'support/dashboard_harness.dart';
import 'support/fake_elm327.dart';

/// The Mode 01 answers the handshake and the merged physics inputs need before
/// any of this is reached. `0100` is the critical one: without it `connect()`
/// returns false and the test fails somewhere else entirely.
Map<String, List<int>> _physicsReplies() => {
      '0100': [0x41, 0x00, 0xBE, 0x3F, 0xA8, 0x13],
      '0120': [0x41, 0x20, 0x80, 0x00, 0x00, 0x01],
      '0140': [0x41, 0x40, 0x40, 0x00, 0x00, 0x00],
      '010C': [0x41, 0x0C, 0x1A, 0xF8],
      '010D': [0x41, 0x0D, 0x3C],
      '0110': [0x41, 0x10, 0x0A, 0xF0],
      '010B': [0x41, 0x0B, 0x64],
      '010F': [0x41, 0x0F, 0x50],
      '015E': [0x41, 0x5E, 0x0B, 0xB8],
    };

/// A definition an older build could have stored, restored the way the registry
/// restores it.
///
/// Through `Pid.fromJson` on purpose: that is the path the allowlist does *not*
/// guard. The editor and the CSV importer both refuse to write `0205`, and
/// `PollableServices.normalise` — the only validation `fromJson` performs — is
/// a spelling rule, not a safety one.
Pid _storedUnsafePid() => Pid.fromJson(const {
      'name': 'Freeze frame, no frame number',
      'shortName': 'FF 05',
      'modeAndPid': '0205',
      'equation': 'A-40',
      'minValue': -100.0,
      'maxValue': 300.0,
      'units': '°C',
      'header': kDefaultHeader,
      'isCustom': true,
    });

FakeElm327 _canEcm() => FakeElm327(
      protocol: BusProtocol.can11,
      ecus: [
        FakeEcu(
          name: 'ECM',
          requestId: '7E0',
          responseId: '7E8',
          responses: _physicsReplies(),
        ),
      ],
    );

Future<PollingEngine> _connect(FakeElm327 transport) async {
  final client = Elm327Client(
    transport,
    commandTimeout: const Duration(milliseconds: 200),
    responsePendingTimeout: const Duration(milliseconds: 280),
  );
  expect(await client.connect(), isTrue,
      reason: 'the fake must complete the handshake, or this test fails '
          'before reaching what it is about');
  return PollingEngine(client);
}

void main() {
  group('a definition the poller refuses to transmit', () {
    late PollingEngine engine;
    late Pid unsafe;

    setUp(() async {
      unsafe = _storedUnsafePid();
      engine = await _connect(_canEcm());
      await engine.discoverSupportedPids();
      engine.setActivePids([unsafe]);
      engine.start();
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!engine.current.faults.containsKey(unsafe.id) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await engine.stop();
      expect(engine.current.faults, contains(unsafe.id),
          reason: 'the engine never reached a verdict, so whatever this test '
              'asserts next is about nothing having happened');
    });

    tearDown(() async => engine.dispose());

    test('is not reported as something the vehicle lacks', () {
      expect(
        engine.current.faults[unsafe.id],
        isNot(PidFault.unsupported),
        reason: 'no request was sent, so the vehicle has said nothing about '
            'this PID — and 此車輛不支援 sends somebody looking at their car '
            'for a problem that is in a field they can edit',
      );
    });

    test('is reported as the refusal it is', () {
      expect(engine.current.faults[unsafe.id], PidFault.refusedUnsafeService);
    });

    test('and the PID list agrees with the dashboard about it', () {
      // Two sources of truth for one question. `PidManagerScreen` reads this
      // method; the dashboard reads the fault map. They have to say the same
      // thing about the same definition.
      expect(engine.isKnownUnsupported(unsafe), isFalse);
    });
  });

  group('the tile for such a definition', () {
    testWidgets('keeps its dial and says why, instead of blaming the vehicle',
        (tester) async {
      final unsafe = _storedUnsafePid();
      await pumpDashboard(
        tester,
        snapshot: TelemetrySnapshot(
          faults: {unsafe.id: PidFault.refusedUnsafeService},
          capturedAt: DateTime.now(),
        ),
        activePids: [unsafe],
      );

      expect(find.text('此車輛不支援'), findsNothing,
          reason: 'the vehicle was never asked');
      expect(find.text('此服務不是唯讀查詢，已停止發送'), findsOneWidget);
    });

    testWidgets('while a genuine support-mask refusal still says so',
        (tester) async {
      // The mirror case. Without it, deleting 此車輛不支援 outright would pass
      // the test above — and that string is correct for the one fault that
      // does carry evidence about the car.
      await pumpDashboard(
        tester,
        snapshot: TelemetrySnapshot(
          faults: {PidLibrary.engineRpm.id: PidFault.unsupported},
          capturedAt: DateTime.now(),
        ),
        activePids: [PidLibrary.engineRpm],
      );

      expect(find.text('此車輛不支援'), findsOneWidget);
    });
  });
}
