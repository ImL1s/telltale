/// End-to-end against an ELM327 implementation this project did not write.
///
/// `Ircama/ELM327-emulator` is an independent oracle: its framing, its timing
/// and its quirks come from someone else's reading of the datasheet, so it can
/// disagree with mine. That is the entire point — every other test in this
/// suite is ultimately my code checking my own assumptions.
///
/// Skipped unless the emulator is running. From `app/`, start it with a private
/// PID directory; never bypass the wrapper with `python -m elm`:
///
///     ELM_PID_DIR="$(mktemp -d "${TMPDIR:-/tmp}/telltale-elm.XXXXXX")"
///     chmod 700 "$ELM_PID_DIR"
///     "$SP/harness/elmvenv/bin/python" tool/ble_test_rig/emulator_entrypoint.py \
///       --pid-directory "$ELM_PID_DIR" -n 35000 -s car \
///       -b "$ELM_PID_DIR/batch.log" &
///     flutter test test/emulator_integration_test.dart \
///       --dart-define=ELM_ORACLE_REQUIRED=true
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/core/share/app_share_platform_bridge.dart';
import 'package:torque_obd/obd/dtc/dtc.dart';
import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/polling_engine.dart';
import 'package:torque_obd/obd/telemetry.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/obd/transport/wifi_transport.dart';
import 'package:torque_obd/state/app_share_coordinator.dart';
import 'package:torque_obd/state/artifact_operation_gate.dart';
import 'package:torque_obd/state/pid_mutation_lock.dart';
import 'package:torque_obd/state/telemetry_recorder.dart';
import 'package:torque_obd/state/telemetry_runtime.dart';
import 'package:torque_obd/state/telemetry_sessions.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_store.dart';

const _host = '127.0.0.1';
const _port = int.fromEnvironment('ELM_ORACLE_PORT', defaultValue: 35000);
const _oracleRequired = bool.fromEnvironment('ELM_ORACLE_REQUIRED');

/// Whether the thing on the port is the oracle these tests were written for.
///
/// "Something is listening" is not the same question, and answering that one
/// instead cost three separate red runs that had nothing to do with this app.
/// Port 35000 is `WifiTransport.defaultPort`, so it is exactly where anybody
/// developing against *any* ELM327 simulator will put theirs — and a second
/// implementation answers this suite's fixtures differently while claiming the
/// same `ELM327 v1.5` banner.
///
/// `AT@1` is the discriminator: the datasheet defines it as the device
/// description, and Ircama's emulator answers `OBDII to RS232 Interpreter`. A
/// different server answering here means these assertions would be testing
/// somebody else's implementation and blaming this one for the difference.
Future<bool> _oracleIsIrcama() async {
  Socket? socket;
  try {
    socket = await Socket.connect(
      _host,
      _port,
      timeout: const Duration(seconds: 2),
    );
    final replies = StringBuffer();
    socket.listen(
      (bytes) => replies.write(String.fromCharCodes(bytes)),
      onError: (_) {},
    );

    // Both phases are drained by polling. Neither is timed.
    //
    // The version this replaces armed a completer before `ATZ` and then waited
    // a flat 400 ms for the reset. `ATZ` on this emulator models a real
    // adapter's reset and takes longer than that, so the buffer was cleared
    // while the banner was still in flight; the banner then arrived inside the
    // `AT@1` window, satisfied the completer's `'>'` test, and the answer this
    // function exists to read never landed. `available` came back false, all
    // six tests below reported *skipped*, and `flutter test` exited 0 — six
    // consecutive runs of the unfixed file gave pass/skip/skip/skip/pass/pass,
    // green every time. A suite that silently stops checking is worse than one
    // that fails, because nothing distinguishes it from one that checked.
    //
    // `freeze_frame_oracle_test.dart` fixed the same defect and its comment
    // says why, but it polls only the second phase and still sleeps a fixed
    // 500 ms before clearing. Measured against this emulator, `ATZ` returns
    // `ELM327 v1.5` and its prompt 504-509 ms after the write across three
    // trials — so that constant would have five milliseconds of slack here,
    // and raising 400 to any particular number is the same bet with longer
    // odds. Both phases wait for evidence instead: the reset until its prompt
    // appears, and `AT@1` until the discriminator itself appears. Waiting on
    // the discriminator rather than on a prompt is what makes a stray prompt
    // harmless no matter which phase emitted it.
    socket.write('ATZ\r');
    for (var i = 0; i < 30; i++) {
      if (replies.toString().contains('>')) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    replies.clear();
    socket.write('AT@1\r');
    for (var i = 0; i < 30; i++) {
      if (replies.toString().contains('RS232')) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return replies.toString().contains('RS232');
  } on Object {
    return false;
  } finally {
    socket?.destroy();
  }
}

void main() {
  late bool available;

  setUpAll(() async {
    available = await _oracleIsIrcama();
  });

  /// Reports the test as *skipped* rather than passed when the oracle is
  /// absent.
  ///
  /// These used to `return` early, which the runner counts as a pass. The
  /// whole point of this file is that it checks the implementation against
  /// something nobody here wrote — so a green run with the emulator offline
  /// claimed exactly the evidence it did not have, and the summary line said
  /// so in the same numbers as a real one.
  bool oracleReady() {
    if (available) return true;
    const message =
        'Ircama/ELM327-emulator not answering on $_host:$_port. Start '
        '`tool/ble_test_rig/emulator_entrypoint.py` with an owner-only '
        '`--pid-directory`; do not invoke `python -m elm` directly. A '
        'different simulator on that port is not valid for these fixtures.';
    if (_oracleRequired) {
      fail(message);
    }
    markTestSkipped(
      '$message Re-run with `--dart-define=ELM_ORACLE_REQUIRED=true` when '
      'collecting oracle evidence so this condition is a failure.',
    );
    return false;
  }

  group('against ELM327-emulator', () {
    test('the handshake completes', () async {
      if (!oracleReady()) return;
      final transport = WifiTransport(host: _host, port: _port);
      await transport.connect();
      final client = Elm327Client(transport);
      // The emulator serves one connection at a time, so a test that fails
      // before its own cleanup would lock every later one out.
      addTearDown(client.dispose);

      final progress = <int, InitProgress>{};
      final sub = client.initProgress.listen((p) => progress[p.index] = p);

      final ok = await client.connect();
      // Progress arrives on a broadcast stream, so the last events land after
      // connect() returns. Reading them immediately reports "no failures" for
      // a handshake that plainly failed — the same race that makes the
      // connection wizard's error message unhelpful.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await sub.cancel();

      final trace = progress.values
          .map(
            (p) =>
                '${p.step.command}=${p.status.name}'
                '${p.detail == null ? '' : '(${p.detail})'}',
          )
          .join(', ');

      expect(ok, isTrue, reason: 'handshake trace: $trace');
    });

    test('it reports a CAN protocol', () async {
      if (!oracleReady()) return;
      final transport = WifiTransport(host: _host, port: _port);
      await transport.connect();
      final client = Elm327Client(transport);
      // The emulator serves one connection at a time, so a test that fails
      // before its own cleanup would lock every later one out.
      addTearDown(client.dispose);
      expect(await client.connect(), isTrue);
      expect(DtcDecoder.protocolIsCan(client.protocolNumber), isTrue);
    });

    test('the VIN reads back as 17 legal characters', () async {
      if (!oracleReady()) return;
      final transport = WifiTransport(host: _host, port: _port);
      await transport.connect();
      final client = Elm327Client(transport);
      // The emulator serves one connection at a time, so a test that fails
      // before its own cleanup would lock every later one out.
      addTearDown(client.dispose);
      expect(await client.connect(), isTrue);
      final vin = await PollingEngine(client).readVin();
      expect(vin, isNotNull);
      expect(vin, hasLength(17));
    });

    test('production polling records simulated-rig telemetry and exports exact counts', () async {
      if (!oracleReady()) return;
      final documents = await Directory.systemTemp.createTemp(
        'ircama-telemetry-',
      );
      final shareRoot = await Directory.systemTemp.createTemp('ircama-share-');
      addTearDown(() => documents.delete(recursive: true));
      addTearDown(() => shareRoot.delete(recursive: true));
      final transport = WifiTransport(host: _host, port: _port);
      await transport.connect();
      final client = Elm327Client(transport);
      addTearDown(client.dispose);
      expect(await client.connect(), isTrue);
      expect(DtcDecoder.protocolIsCan(client.protocolNumber), isTrue);

      final poller = PollingEngine(client)
        ..setActivePids(const [
          PidLibrary.vehicleSpeed,
          PidLibrary.engineRpm,
        ], includeProfileDerivedInputs: false);
      addTearDown(poller.dispose);
      final complete = Completer<TelemetrySnapshot>();
      final snapshots = poller.snapshots.listen((snapshot) {
        final speed = snapshot.readings[PidLibrary.vehicleSpeed.id]?.value;
        if (!complete.isCompleted &&
            speed != null &&
            speed <= 5 &&
            snapshot.readings.containsKey(PidLibrary.engineRpm.id)) {
          complete.complete(snapshot);
        }
      });
      addTearDown(snapshots.cancel);
      poller.start();
      final snapshot = await complete.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw TimeoutException(
          'production poller did not produce RPM with a stopped speed sample',
          const Duration(seconds: 30),
        ),
      );
      await poller.stop();
      expect(snapshot.readings[PidLibrary.engineRpm.id]?.value, isA<double>());
      expect(
        snapshot.readings[PidLibrary.vehicleSpeed.id]?.value,
        inInclusiveRange(0, 5),
      );

      const sessionId = '00000000000000000000000000000031';
      final store = TelemetrySessionStore(
        documentsDirectory: () async => documents,
        idSource: () => sessionId,
      );
      final environment = LiveTelemetryStartEnvironment(
        readConnection: () => const TelemetryConnectionSnapshot(
          connected: true,
          foreground: true,
          connectionGeneration: 1,
          foregroundEpoch: 1,
        ),
        utcNow: () => DateTime.now().toUtc(),
        elapsedUs: () => DateTime.now().microsecondsSinceEpoch,
      )..observeTelemetry(snapshot);
      final recorder = RootTelemetryRecorder(
        environment: environment,
        storage: FileTelemetryRecorderStorage(store),
        startCommandMutex: StartCommandMutex(),
        artifactGate: ArtifactOperationGate(),
        pidMutationLock: PidMutationLock(),
        utcNow: () => DateTime.now().toUtc(),
        elapsedUs: () => DateTime.now().microsecondsSinceEpoch,
      );
      final started = await recorder.start(
        TelemetryStartRequest(
          source: TelemetrySource.simulatedRig,
          transport: TransportKind.wifi,
          protocol: 'ELM protocol ${client.protocolNumber}',
          activePids: const [PidLibrary.vehicleSpeed, PidLibrary.engineRpm],
        ),
      );
      expect(started.outcome, TelemetryStartOutcome.recording);
      recorder.onTelemetry(snapshot);
      recorder.stop();
      await recorder.drainFinalization();

      final service = TelemetrySessionLibraryService(
        documentsDirectory: () async => documents,
      );
      final library = await service.load();
      final session = library.sessions.single;
      expect(session.source, TelemetrySource.simulatedRig);
      expect(session.valueCount, 2);
      expect(session.statusCount, 0);
      expect(session.gapCount, 0);
      expect(session.terminalReason, TelemetryTerminalReason.user);
      final replay = await service.replay(sessionId);
      expect(replay.failure, isNull);
      expect(replay.replay?.source, TelemetrySource.simulatedRig);
      expect(replay.replay?.valueCount, 2);

      final platform = _CapturingPlatform();
      final policy = _PermittingPolicy();
      final gate = ArtifactOperationGate();
      var shareId = 0;
      final coordinator = AppShareCoordinator(
        rootDirectory: () async => shareRoot,
        policy: policy,
        artifactGate: gate,
        platform: platform,
        idSource: () => (++shareId).toRadixString(16).padLeft(32, '0'),
        nowUtc: () => DateTime.now().toUtc(),
        availableBytes: (_) async => 64 * 1024 * 1024,
      );
      expect(
        await coordinator.initialize(),
        AppShareInitializationOutcome.ready,
      );
      final actions = TelemetrySessionActions(
        documentsDirectory: () async => documents,
        store: store,
        shareCoordinator: coordinator,
        artifactGate: gate,
        sharePolicy: policy,
        readRecorderPhase: () => recorder.progress.state.phase,
      );
      expect(
        (await actions.export(sessionId, TelemetryExportFormat.csv)).isSuccess,
        isTrue,
      );
      expect(
        (await actions.export(sessionId, TelemetryExportFormat.json)).isSuccess,
        isTrue,
      );
      final csv = utf8.decode(platform.byExtension['csv']!);
      final jsonText = utf8.decode(platform.byExtension['json']!);
      final json = jsonDecode(jsonText) as Map<String, Object?>;
      expect(json['events'], hasLength(2));
      expect(jsonText, contains('"source":"simulatedRig"'));
      expect(csv, contains('Engine RPM'));
      expect(csv, contains('Vehicle Speed'));
      final jsonPayload = jsonEncode({
        'header': json['header'],
        'events': json['events'],
        'footer': json['footer'],
      });
      final csvPayload = csv
          .split('\r\n')
          .where((line) => line.isNotEmpty && !line.startsWith('#'))
          .join('\r\n');
      for (final forbidden in const [
        'VIN',
        'GPS',
        'account',
        'adapterAddress',
        'vehicleProfile',
        'rawDiagnosticTraffic',
      ]) {
        expect(csvPayload, isNot(contains(forbidden)));
        expect(jsonPayload, isNot(contains('"$forbidden"')));
      }
    });

    test('an unanswered scan is a failure, never a clean bill of health', () async {
      if (!oracleReady()) return;
      // This emulator does not model functional addressing: with `7DF`
      // selected it answers Mode 03 with `NO DATA`, though it answers the same
      // request on the engine's physical address. That is a limitation of the
      // oracle rather than of the app — `7DF` is the functional address the
      // datasheet names for 11-bit CAN — but it makes an excellent fixture for
      // the property that matters most on this screen.
      //
      // The app asks functionally, gets no answer, and must say so. Reporting
      // "no fault codes" here would be a false all-clear a person could drive
      // away on.
      final transport = WifiTransport(host: _host, port: _port);
      await transport.connect();
      final client = Elm327Client(transport);
      addTearDown(client.dispose);
      expect(await client.connect(), isTrue);

      await expectLater(
        PollingEngine(client).readDtcs(DtcKind.stored),
        throwsA(
          isA<DtcReadException>().having(
            (e) => e.kind,
            'kind',
            DtcReadFailure.noAnswer,
          ),
        ),
      );
    });

    test('a reply with the wrong service byte is refused, not decoded', () async {
      if (!oracleReady()) return;
      // This oracle answers Mode 03 inconsistently — `41 00` in one state,
      // `43 00` in another — and its author documents that it deliberately
      // returns wrong service bytes. That is a gift: an independently produced
      // malformed reply, which is exactly the input this app has to survive.
      //
      // `41` is a positive response to Mode 01, not Mode 03. Decoding its
      // payload as fault codes is how a car with no faults acquires some.
      final transport = WifiTransport(host: _host, port: _port);
      await transport.connect();
      final client = Elm327Client(transport);
      addTearDown(client.dispose);
      expect(await client.connect(), isTrue);

      final response = await client.sendAddressed('7E0', '03');
      expect(response.isSuccess, isTrue, reason: 'the adapter did answer');

      if (response.bytes.first == 0x43) {
        // A well-formed answer: a healthy vehicle, decoded honestly.
        expect(
          DtcDecoder.decodeResponse(
            response.bytes,
            DtcKind.stored,
            hasCountByte: true,
          ),
          isEmpty,
        );
      } else {
        // A mismatched one: the engine must refuse it rather than read the
        // payload as codes.
        await expectLater(
          PollingEngine(client).readDtcs(DtcKind.stored),
          throwsA(isA<DtcReadException>()),
        );
      }
    });
  });
}

class _CapturingPlatform implements AppSharePlatform {
  final Map<String, List<int>> byExtension = {};

  @override
  Future<AppShareResult> share(AppSharePlatformRequest request) async {
    byExtension[request.fileName.split('.').last] = await File(request.path)
        .readAsBytes();
    return AppShareResult.selected;
  }
}

class _PermittingPolicy implements AppSharePolicy {
  @override
  SharePreparationPermit? freeze() => const SharePreparationPermit(
    recorderEpoch: 1,
    foregroundEpoch: 1,
    connectionEpoch: 1,
    safetyEpoch: 1,
    connectionClass: ShareConnectionClass.disconnected,
  );

  @override
  SharePermitValidation validate(SharePreparationPermit permit) =>
      const SharePermitValidation.valid();
}
