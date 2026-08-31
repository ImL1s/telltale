import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/telemetry.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/artifact_operation_gate.dart';
import 'package:torque_obd/state/pid_mutation_lock.dart';
import 'package:torque_obd/state/telemetry_recorder.dart';
import 'package:torque_obd/state/telemetry_runtime.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_reader.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_store.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_codec.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_writer.dart';

void main() {
  late Directory temporary;
  late DateTime now;
  late int elapsedUs;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('telemetry-runtime-');
    now = DateTime.utc(2026, 8, 30, 1);
    elapsedUs = 1000000;
  });

  tearDown(() => temporary.delete(recursive: true));

  test(
    'real store path installs one valid header-event-footer session',
    () async {
      final store = TelemetrySessionStore(
        documentsDirectory: () async => temporary,
        idSource: () => '0123456789abcdef0123456789abcdef',
        nowUtc: () => now,
      );
      final environment = LiveTelemetryStartEnvironment(
        readConnection: () => const TelemetryConnectionSnapshot(
          connected: true,
          foreground: true,
          connectionGeneration: 4,
          foregroundEpoch: 2,
        ),
        utcNow: () => now,
        elapsedUs: () => elapsedUs,
      )..observeTelemetry(_speed(now, 0));
      final recorder = RootTelemetryRecorder(
        environment: environment,
        storage: FileTelemetryRecorderStorage(store),
        startCommandMutex: StartCommandMutex(),
        artifactGate: ArtifactOperationGate(),
        pidMutationLock: PidMutationLock(),
        utcNow: () => now,
        elapsedUs: () => elapsedUs,
      );

      final started = await recorder.start(
        TelemetryStartRequest(
          source: TelemetrySource.fieldAppConnection,
          transport: TransportKind.wifi,
          protocol: 'ISO 15765-4 CAN',
          activePids: const [PidLibrary.vehicleSpeed],
        ),
      );
      expect(started.outcome, TelemetryStartOutcome.recording);
      now = now.add(const Duration(milliseconds: 50));
      elapsedUs += 50000;
      recorder.onTelemetry(_speed(now, 12));
      recorder.stop();
      await recorder.drainFinalization();

      final finalFile = File(
        '${temporary.path}/telltale-telemetry/'
        '0123456789abcdef0123456789abcdef.ndjson',
      );
      expect(await finalFile.exists(), isTrue);
      expect(await File('${finalFile.path}.part').exists(), isFalse);
      final parsed = await const TelemetrySessionReader().read(
        FileTelemetryChunkSource(finalFile),
      );
      expect(parsed.isValid, isTrue);
      expect(parsed.valueCount, 1);
      expect(parsed.sessionFooter?.bytesBeforeFooter, greaterThan(0));
      expect(parsed.sessionHeader?.source, TelemetrySource.fieldAppConnection);
    },
  );

  test('writer retains the exact canonical header flushed to disk', () async {
    const id = '1023456789abcdef0123456789abcdef';
    final storage = FileTelemetryRecorderStorage(
      TelemetrySessionStore(
        documentsDirectory: () async => temporary,
        idSource: () => id,
      ),
    );
    await storage.prepareDirectory();
    final quota = await storage.scanQuota();
    var factoryCalls = 0;

    final writer = await storage.createExclusive((sessionId) {
      factoryCalls++;
      final base = _header(sessionId);
      return TelemetrySessionHeader(
        sessionId: sessionId,
        startedAtUtc: DateTime.utc(2026, 8, 30, 1, 0, factoryCalls),
        source: base.source,
        transport: base.transport,
        protocol: base.protocol,
        signals: base.signals,
      );
    }, quota: quota);

    final part = File('${temporary.path}/telltale-telemetry/$id.ndjson.part');
    final decoded = TelemetrySessionCodec.decodeHeaderLine(
      await part.readAsBytes(),
    );
    expect(decoded.isSuccess, isTrue);
    expect(decoded.value!.startedAtUtc, writer.header.startedAtUtc);
    expect(factoryCalls, 2, reason: 'one size probe and one durable id header');
    expect(await writer.closeForAbort(), TelemetryCloseResult.closed);
    expect(await writer.deleteZeroValue(), TelemetryCleanupResult.deleted);
  });

  for (final checkpoint in const <String>[
    'store.afterExclusiveCreate.0',
    'store.afterHeaderWrite.0',
    'storage.afterAppendReopen',
  ]) {
    test('$checkpoint revocation is typed and removes owned staging', () async {
      const id = '2023456789abcdef0123456789abcdef';
      final environment = _CheckpointEnvironment(checkpoint);
      final command = StartCommandMutex();
      final artifacts = ArtifactOperationGate();
      final pids = PidMutationLock();
      final recorder = RootTelemetryRecorder(
        environment: environment,
        storage: FileTelemetryRecorderStorage(
          TelemetrySessionStore(
            documentsDirectory: () async => temporary,
            idSource: () => id,
          ),
        ),
        startCommandMutex: command,
        artifactGate: artifacts,
        pidMutationLock: pids,
        utcNow: () => environment.now,
        elapsedUs: () => environment.elapsedUs,
      );

      final result = await recorder.start(_request());

      expect(result.outcome, TelemetryStartOutcome.startInvalidatedMoving);
      expect(environment.checkpoints, contains(checkpoint));
      expect(
        await File('${temporary.path}/telltale-telemetry/$id.ndjson.part')
            .exists(),
        isFalse,
      );
      expect(command.isLocked, isFalse);
      expect(artifacts.snapshot.isIdle, isTrue);
      expect(pids.isLocked, isFalse);
    });
  }

  test('zero-value stop deletes staging instead of installing it', () async {
    final store = TelemetrySessionStore(
      documentsDirectory: () async => temporary,
      idSource: () => '1123456789abcdef0123456789abcdef',
    );
    final environment = LiveTelemetryStartEnvironment(
      readConnection: () => const TelemetryConnectionSnapshot(
        connected: true,
        foreground: true,
        connectionGeneration: 1,
        foregroundEpoch: 0,
      ),
      utcNow: () => now,
      elapsedUs: () => elapsedUs,
    )..observeTelemetry(_speed(now, 0));
    final recorder = RootTelemetryRecorder(
      environment: environment,
      storage: FileTelemetryRecorderStorage(store),
      startCommandMutex: StartCommandMutex(),
      artifactGate: ArtifactOperationGate(),
      pidMutationLock: PidMutationLock(),
      utcNow: () => now,
      elapsedUs: () => elapsedUs,
    );
    expect(
      (await recorder.start(
        TelemetryStartRequest(
          source: TelemetrySource.fieldAppConnection,
          transport: TransportKind.wifi,
          protocol: 'CAN',
          activePids: const [PidLibrary.vehicleSpeed],
        ),
      )).outcome,
      TelemetryStartOutcome.recording,
    );
    recorder.stop();
    await recorder.drainFinalization();
    expect((await store.listSessions()).sessions, isEmpty);
    expect(await store.scanQuota().then((value) => value.groupCount), 0);
  });

  test('quota scan and typed create admission fail closed', () async {
    final directory = Directory('${temporary.path}/telltale-telemetry');
    await directory.create();
    for (var index = 0; index < TelemetryQuota.groupLimit; index++) {
      await File(
        '${directory.path}/${index.toRadixString(16).padLeft(32, '0')}.ndjson',
      ).writeAsString('x');
    }
    final storage = FileTelemetryRecorderStorage(
      TelemetrySessionStore(documentsDirectory: () async => temporary),
    );
    expect(
      (await storage.scanQuota()).rejection,
      TelemetryQuotaRejection.libraryGroupLimit,
    );

    await directory.delete(recursive: true);
    await storage.prepareDirectory();
    expect(
      () => storage.createExclusive(
        _header,
        quota: const TelemetryStorageQuota(
          effectiveSessionLimit: 1,
          sessionLimitIsLibraryBound: false,
        ),
      ),
      throwsA(
        isA<TelemetryStorageCreateException>().having(
          (error) => error.failure,
          'outcome',
          TelemetryStorageCreateFailure.noRoomForValue,
        ),
      ),
    );
  });

  test('exclusive-id exhaustion is surfaced as a typed collision', () async {
    const id = '2123456789abcdef0123456789abcdef';
    final directory = Directory('${temporary.path}/telltale-telemetry');
    await directory.create();
    await File('${directory.path}/$id.ndjson').writeAsString('occupied');
    final storage = FileTelemetryRecorderStorage(
      TelemetrySessionStore(
        documentsDirectory: () async => temporary,
        idSource: () => id,
      ),
    );
    final quota = await storage.scanQuota();
    expect(
      () => storage.createExclusive(_header, quota: quota),
      throwsA(
        isA<TelemetryStorageCreateException>().having(
          (error) => error.failure,
          'outcome',
          TelemetryStorageCreateFailure.idCollision,
        ),
      ),
    );
  });

  test(
    'append reopen failure deletes only part and preserves raced final',
    () async {
      const id = '2923456789abcdef0123456789abcdef';
      final store = TelemetrySessionStore(
        documentsDirectory: () async => temporary,
        idSource: () => id,
      );
      final storage = FileTelemetryRecorderStorage(
        store,
        appendSinkForFile: (_) async {
          await File('${temporary.path}/telltale-telemetry/$id.ndjson')
              .writeAsString('raced-final');
          throw const FileSystemException('append reopen');
        },
      );
      final quota = await storage.scanQuota();

      await expectLater(
        storage.createExclusive(_header, quota: quota),
        throwsA(
          isA<TelemetryStorageCreateException>().having(
            (error) => error.failure,
            'failure',
            TelemetryStorageCreateFailure.storageFailure,
          ),
        ),
      );

      final directory = '${temporary.path}/telltale-telemetry';
      expect(await File('$directory/$id.ndjson.part').exists(), isFalse);
      expect(await File('$directory/$id.ndjson').readAsString(), 'raced-final');
    },
  );

  test('root maps runtime no-room admission to noRoomForValue', () async {
    final directory = Directory('${temporary.path}/telltale-telemetry');
    await directory.create();
    final occupying = await File(
      '${directory.path}/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.ndjson',
    ).open(mode: FileMode.write);
    await occupying.truncate(TelemetryQuota.libraryByteLimit - 100);
    await occupying.close();
    final recorder = _rootRecorder(
      store: TelemetrySessionStore(documentsDirectory: () async => temporary),
      now: () => now,
      elapsedUs: () => elapsedUs,
    );
    final result = await recorder.start(_request());
    expect(result.outcome, TelemetryStartOutcome.noRoomForValue);
  });

  test('root maps runtime exclusive-id exhaustion to idCollision', () async {
    const id = '3123456789abcdef0123456789abcdef';
    final directory = Directory('${temporary.path}/telltale-telemetry');
    await directory.create();
    await File('${directory.path}/$id.ndjson').writeAsString('occupied');
    final recorder = _rootRecorder(
      store: TelemetrySessionStore(
        documentsDirectory: () async => temporary,
        idSource: () => id,
      ),
      now: () => now,
      elapsedUs: () => elapsedUs,
    );
    final result = await recorder.start(_request());
    expect(result.outcome, TelemetryStartOutcome.idCollision);
  });

  test('install collision preserves a closed recoverable part', () async {
    const id = '4123456789abcdef0123456789abcdef';
    final storage = FileTelemetryRecorderStorage(
      TelemetrySessionStore(
        documentsDirectory: () async => temporary,
        idSource: () => id,
      ),
    );
    final quota = await storage.scanQuota();
    final writer = await storage.createExclusive(_header, quota: quota);
    await writer.appendHeader(
      TelemetrySessionCodec.encodeHeaderLine(_header(id)),
    );
    await writer.flushHeader();
    final event = TelemetryEvent.value(
      observedAtUtc: now,
      sourceTimestampUtc: now,
      elapsedUs: 1,
      pidId: 'speed',
      value: 1,
    );
    expect(
      writer.tryAppendEvent(TelemetrySessionCodec.encodeEventLine(event)),
      TelemetryAppendResult.accepted,
    );
    final directory = Directory('${temporary.path}/telltale-telemetry');
    await File('${directory.path}/$id.ndjson').writeAsString('collision');
    final result = await writer.finalizeAndInstall(
      TelemetrySessionFooter(
        endedAtUtc: now,
        terminalReason: TelemetryTerminalReason.user,
        valueCount: 1,
        statusCount: 0,
        gapCount: 0,
        bytesBeforeFooter: writer.bytesBeforeFooter,
      ),
    );
    expect(result, TelemetryFinalizeResult.preservedFailure);
    final part = File('${directory.path}/$id.ndjson.part');
    expect(await part.exists(), isTrue);
    expect(
      (await const TelemetrySessionReader().read(
        FileTelemetryChunkSource(part),
      )).isValid,
      isTrue,
    );
  });

  for (final failureAt in const <String>['append', 'flush']) {
    test(
      '$failureAt failure is releasable only after close and stable stat',
      () async {
        const id = '5123456789abcdef0123456789abcdef';
        final sink = _RuntimeFailureSink(failureAt);
        final storage = FileTelemetryRecorderStorage(
          TelemetrySessionStore(
            documentsDirectory: () async => temporary,
            idSource: () => id,
          ),
          appendSinkForFile: (_) async => sink,
        );
        final quota = await storage.scanQuota();
        final writer = await storage.createExclusive(_header, quota: quota);
        await writer.appendHeader(
          TelemetrySessionCodec.encodeHeaderLine(_header(id)),
        );
        await writer.flushHeader();
        expect(
          writer.tryAppendEvent(
            TelemetrySessionCodec.encodeEventLine(
              TelemetryEvent.value(
                observedAtUtc: now,
                sourceTimestampUtc: now,
                elapsedUs: 1,
                pidId: 'speed',
                value: 1,
              ),
            ),
          ),
          TelemetryAppendResult.accepted,
        );

        final result = await writer.finalizeAndInstall(
          TelemetrySessionFooter(
            endedAtUtc: now,
            terminalReason: TelemetryTerminalReason.user,
            valueCount: 1,
            statusCount: 0,
            gapCount: 0,
            bytesBeforeFooter: writer.bytesBeforeFooter,
          ),
        );

        expect(result, TelemetryFinalizeResult.preservedFailure);
        expect(sink.calls.last, 'close');
      },
    );
  }

  test('finalize close failure is uncontained', () async {
    const id = '6123456789abcdef0123456789abcdef';
    final storage = FileTelemetryRecorderStorage(
      TelemetrySessionStore(
        documentsDirectory: () async => temporary,
        idSource: () => id,
      ),
      appendSinkForFile: (_) async => _RuntimeFailureSink('close'),
    );
    final quota = await storage.scanQuota();
    final writer = await storage.createExclusive(_header, quota: quota);
    await writer.appendHeader(
      TelemetrySessionCodec.encodeHeaderLine(_header(id)),
    );
    await writer.flushHeader();
    writer.tryAppendEvent(
      TelemetrySessionCodec.encodeEventLine(
        TelemetryEvent.value(
          observedAtUtc: now,
          sourceTimestampUtc: now,
          elapsedUs: 1,
          pidId: 'speed',
          value: 1,
        ),
      ),
    );

    expect(
      await writer.finalizeAndInstall(
        TelemetrySessionFooter(
          endedAtUtc: now,
          terminalReason: TelemetryTerminalReason.user,
          valueCount: 1,
          statusCount: 0,
          gapCount: 0,
          bytesBeforeFooter: writer.bytesBeforeFooter,
        ),
      ),
      TelemetryFinalizeResult.uncontainedFailure,
    );
  });

  test('never-completing finalize close never reports containment', () async {
    const id = '7123456789abcdef0123456789abcdef';
    final storage = FileTelemetryRecorderStorage(
      TelemetrySessionStore(
        documentsDirectory: () async => temporary,
        idSource: () => id,
      ),
      appendSinkForFile: (_) async => _RuntimeFailureSink('neverClose'),
    );
    final quota = await storage.scanQuota();
    final writer = await storage.createExclusive(_header, quota: quota);
    await writer.appendHeader(
      TelemetrySessionCodec.encodeHeaderLine(_header(id)),
    );
    await writer.flushHeader();
    writer.tryAppendEvent(
      TelemetrySessionCodec.encodeEventLine(
        TelemetryEvent.value(
          observedAtUtc: now,
          sourceTimestampUtc: now,
          elapsedUs: 1,
          pidId: 'speed',
          value: 1,
        ),
      ),
    );
    final future = writer.finalizeAndInstall(
      TelemetrySessionFooter(
        endedAtUtc: now,
        terminalReason: TelemetryTerminalReason.user,
        valueCount: 1,
        statusCount: 0,
        gapCount: 0,
        bytesBeforeFooter: writer.bytesBeforeFooter,
      ),
    );

    expect(await _completesSoon(future), isFalse);
  });

  test(
    'uncontained exclusive-create failure retains every root owner',
    () async {
      final command = StartCommandMutex();
      final artifacts = ArtifactOperationGate();
      final pids = PidMutationLock();
      final recorder = RootTelemetryRecorder(
        environment: LiveTelemetryStartEnvironment(
          readConnection: () => const TelemetryConnectionSnapshot(
            connected: true,
            foreground: true,
            connectionGeneration: 1,
            foregroundEpoch: 0,
          ),
          utcNow: () => now,
          elapsedUs: () => elapsedUs,
        )..observeTelemetry(_speed(now, 0)),
        storage: FileTelemetryRecorderStorage(
          TelemetrySessionStore(
            documentsDirectory: () async => temporary,
            idSource: () => '8' * 32,
            exclusiveCreateIo: _CloseFailCreateIo(),
          ),
        ),
        startCommandMutex: command,
        artifactGate: artifacts,
        pidMutationLock: pids,
        utcNow: () => now,
        elapsedUs: () => elapsedUs,
      );

      final result = await recorder.start(_request());

      expect(result.outcome, TelemetryStartOutcome.restartRequired);
      expect(recorder.state.requiresRestart, isTrue);
      expect(command.isLocked, isTrue);
      expect(artifacts.snapshot.operation, ArtifactOperation.record);
      expect(pids.isLocked, isTrue);
    },
  );

  test('live environment preserves transient speed and freshness evidence', () {
    var connection = const TelemetryConnectionSnapshot(
      connected: true,
      foreground: true,
      connectionGeneration: 8,
      foregroundEpoch: 3,
    );
    final environment = LiveTelemetryStartEnvironment(
      readConnection: () => connection,
      utcNow: () => now,
      elapsedUs: () => elapsedUs,
    );
    environment.observeTelemetry(_speed(now, 0));
    final stopped = environment.snapshot('stopped');
    expect(stopped.speedKnown, isTrue);
    expect(stopped.speedFreshUntilElapsedUs, greaterThan(elapsedUs));
    final stoppedEpoch = stopped.safetyEpoch;

    environment.observeTelemetry(_speed(now, 20));
    environment.observeTelemetry(_speed(now, 0));
    expect(
      environment.snapshot('again').safetyEpoch,
      greaterThan(stoppedEpoch),
    );

    now = now.add(const Duration(seconds: 11));
    elapsedUs += const Duration(seconds: 11).inMicroseconds;
    expect(environment.snapshot('stale').speedKnown, isFalse);
    connection = const TelemetryConnectionSnapshot(
      connected: true,
      foreground: false,
      connectionGeneration: 8,
      foregroundEpoch: 4,
    );
    expect(environment.snapshot('background').foreground, isFalse);
  });

  test('source classification never promotes simulated evidence', () {
    expect(
      telemetrySourceForConnection(
        transport: TransportKind.demo,
        requiresSimulatedEvidence: false,
      ),
      TelemetrySource.demo,
    );
    expect(
      telemetrySourceForConnection(
        transport: TransportKind.bluetoothLe,
        requiresSimulatedEvidence: true,
      ),
      TelemetrySource.simulatedRig,
    );
    expect(
      telemetrySourceForConnection(
        transport: TransportKind.bluetoothClassic,
        requiresSimulatedEvidence: false,
      ),
      TelemetrySource.fieldAppConnection,
    );
  });

  test('future-dated speed is unknown', () {
    final environment = LiveTelemetryStartEnvironment(
      readConnection: () => const TelemetryConnectionSnapshot(
        connected: true,
        foreground: true,
        connectionGeneration: 1,
        foregroundEpoch: 0,
      ),
      utcNow: () => now,
      elapsedUs: () => elapsedUs,
    )..observeTelemetry(_speed(now.add(const Duration(seconds: 1)), 0));

    expect(environment.snapshot('future').speedKnown, isFalse);
  });
}

Future<bool> _completesSoon(Future<Object?> future) async {
  final marker = Object();
  return !identical(
    await Future.any<Object?>(<Future<Object?>>[
      future,
      Future<Object?>.delayed(const Duration(milliseconds: 20), () => marker),
    ]),
    marker,
  );
}

final class _RuntimeFailureSink implements TelemetryAppendSink {
  _RuntimeFailureSink(this.failureAt);

  final String failureAt;
  final List<String> calls = <String>[];
  int flushCalls = 0;

  @override
  Future<void> append(List<int> chunk) async {
    calls.add('append');
    if (failureAt == 'append') throw StateError('append');
  }

  @override
  Future<void> flush() async {
    calls.add('flush');
    flushCalls++;
    if (failureAt == 'flush' && flushCalls == 2) {
      throw StateError('flush');
    }
  }

  @override
  Future<void> close() {
    calls.add('close');
    if (failureAt == 'close') return Future<void>.error(StateError('close'));
    if (failureAt == 'neverClose') return Completer<void>().future;
    return Future<void>.value();
  }
}

final class _CheckpointEnvironment implements TelemetryStartEnvironment {
  _CheckpointEnvironment(this.invalidateAt);

  final String invalidateAt;
  final DateTime now = DateTime.utc(2026, 8, 30, 1);
  int elapsedUs = 1000000;
  int safetyEpoch = 1;
  double speedKmh = 0;
  final List<String> checkpoints = <String>[];

  @override
  TelemetryStartEnvironmentSnapshot snapshot(String checkpoint) {
    checkpoints.add(checkpoint);
    if (checkpoint == invalidateAt && speedKmh <= 5) {
      speedKmh = 20;
      safetyEpoch++;
    }
    return TelemetryStartEnvironmentSnapshot(
      connected: true,
      foreground: true,
      connectionGeneration: 1,
      foregroundEpoch: 1,
      safetyEpoch: safetyEpoch,
      speedKnown: true,
      speedKmh: speedKmh,
      speedFreshUntilElapsedUs: elapsedUs + 2000000,
      observedElapsedUs: elapsedUs,
    );
  }
}

final class _CloseFailCreateIo implements TelemetryExclusiveCreateIo {
  FileSystemEntityType type = FileSystemEntityType.notFound;

  @override
  Future<bool> exists(File file) async => false;

  @override
  Future<void> create(File file) async {
    type = FileSystemEntityType.file;
  }

  @override
  Future<TelemetryExclusiveCreateHandle> openWrite(File file) async =>
      _CloseFailCreateHandle();

  @override
  Future<FileSystemEntityType> typeNoFollow(File file) async => type;

  @override
  Future<void> delete(File file) async {
    type = FileSystemEntityType.notFound;
  }
}

final class _CloseFailCreateHandle implements TelemetryExclusiveCreateHandle {
  @override
  Future<void> write(List<int> bytes) async {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async => throw const FileSystemException('close');
}

TelemetrySessionHeader _header(String id) => TelemetrySessionHeader(
  sessionId: id,
  startedAtUtc: DateTime.utc(2026, 8, 30),
  source: TelemetrySource.fieldAppConnection,
  transport: TransportKind.wifi,
  protocol: 'CAN',
  signals: [
    FrozenPidDefinition.freeze(
      const TelemetrySignalDefinition(
        id: 'speed',
        name: 'Speed',
        shortName: 'SPD',
        request: '01 0D',
        header: '7E0',
        unit: 'km/h',
        unitProvenance: UnitProvenance.standardDirectCanonical,
        minimum: 0,
        maximum: 255,
        isCustom: false,
        variant: '',
        priority: 0,
        equation: 'A',
      ),
    ),
  ],
);

RootTelemetryRecorder _rootRecorder({
  required TelemetrySessionStore store,
  required DateTime Function() now,
  required int Function() elapsedUs,
}) {
  final environment = LiveTelemetryStartEnvironment(
    readConnection: () => const TelemetryConnectionSnapshot(
      connected: true,
      foreground: true,
      connectionGeneration: 1,
      foregroundEpoch: 0,
    ),
    utcNow: now,
    elapsedUs: elapsedUs,
  )..observeTelemetry(_speed(now(), 0));
  return RootTelemetryRecorder(
    environment: environment,
    storage: FileTelemetryRecorderStorage(store),
    startCommandMutex: StartCommandMutex(),
    artifactGate: ArtifactOperationGate(),
    pidMutationLock: PidMutationLock(),
    utcNow: now,
    elapsedUs: elapsedUs,
  );
}

TelemetryStartRequest _request() => TelemetryStartRequest(
  source: TelemetrySource.fieldAppConnection,
  transport: TransportKind.wifi,
  protocol: 'CAN',
  activePids: const [PidLibrary.vehicleSpeed],
);

TelemetrySnapshot _speed(DateTime timestamp, double value) => TelemetrySnapshot(
  readings: {
    PidLibrary.vehicleSpeed.id: Reading(
      pid: PidLibrary.vehicleSpeed,
      value: value,
      rawBytes: [value.round()],
      timestamp: timestamp,
    ),
  },
  capturedAt: timestamp,
);
