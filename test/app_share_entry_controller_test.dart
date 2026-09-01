import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/core/share/app_share_platform_bridge.dart';
import 'package:torque_obd/core/share/share_lease_ledger.dart';
import 'package:torque_obd/obd/pid/pid_csv.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/transcript.dart';
import 'package:torque_obd/obd/transcript_store.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/app_share_coordinator.dart';
import 'package:torque_obd/state/app_share_entry_controller.dart';
import 'package:torque_obd/state/artifact_operation_gate.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_codec.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_exporter.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_reader.dart';

void main() {
  test(
    'five production entry methods preserve canonical bytes and metadata',
    () async {
      final documents = Directory.systemTemp.createTempSync('share-entry-docs');
      final roots = Directory.systemTemp.createTempSync('share-entry-roots');
      addTearDown(() {
        if (documents.existsSync()) documents.deleteSync(recursive: true);
        if (roots.existsSync()) roots.deleteSync(recursive: true);
      });
      const sessionId = '0123456789abcdef0123456789abcdef';
      final telemetryDir = Directory('${documents.path}/telltale-telemetry')
        ..createSync();
      final telemetryFile = File('${telemetryDir.path}/$sessionId.ndjson');
      telemetryFile.writeAsBytesSync(_sessionBytes(sessionId));

      final csv = await _invoke(
        roots,
        1,
        (controller) => controller.shareTelemetryCsv(
          documents: documents,
          sessionId: sessionId,
        ),
      );
      final json = await _invoke(
        roots,
        2,
        (controller) => controller.shareTelemetryJson(
          documents: documents,
          sessionId: sessionId,
        ),
      );
      expect(csv.request.mimeType, 'text/csv');
      expect(csv.sourceKind, ShareSourceKind.telemetryCsv);
      expect(csv.request.fileName, endsWith('.csv'));
      expect(json.request.mimeType, 'application/json');
      expect(json.sourceKind, ShareSourceKind.telemetryJson);
      expect(json.request.fileName, endsWith('.json'));
      expect(
        csv.bytes,
        await _collect(
          TelemetrySessionExporter().csvStream(
            FileTelemetryChunkSource(telemetryFile),
          ),
        ),
      );
      expect(
        json.bytes,
        await _collect(
          TelemetrySessionExporter().jsonStream(
            FileTelemetryChunkSource(telemetryFile),
          ),
        ),
      );

      final transcript = ObdTranscript()
        ..recordWrite([0x41], DateTime.utc(2026));
      final expectedRaw = await _collect(
        transcript.frozenCopy().streamEncoded(
          header: 'Header\n',
          withHex: true,
        ),
      );
      final rawFuture = _invoke(
        roots,
        3,
        (controller) => controller.shareRawTranscript(
          transcript: transcript,
          header: 'Header\n',
          withHex: true,
          subjectAt: DateTime(2026, 8, 30, 1, 2, 3),
        ),
        afterAdmission: () =>
            transcript.recordWrite([0x42], DateTime.utc(2026, 1, 1, 0, 0, 1)),
      );
      final raw = await rawFuture;
      expect(raw.bytes, expectedRaw);
      expect(raw.request.subject, 'Telltale 傳輸紀錄 20260830-010203');
      expect(raw.request.mimeType, 'text/plain');
      expect(raw.sourceKind, ShareSourceKind.rawTranscript);

      final store = TranscriptStore(directory: () async => documents);
      final saved = ObdTranscript()
        ..recordRead([0x34, 0x31, 0x0d], DateTime.utc(2026));
      expect(
        await store.save(saved, 'Recovered\n', fromRealHardware: true),
        isTrue,
      );
      final displayed = await store.load();
      expect(displayed, isNotNull);
      final descriptor = await store.openStreaming(expected: displayed);
      expect(descriptor, isNotNull);
      final expectedRecovered = await _collect(descriptor!.open());
      final recovered = await _invoke(
        roots,
        4,
        (controller) => controller.shareRecoveredTranscript(
          store: store,
          expected: displayed!,
        ),
      );
      expect(recovered.bytes, expectedRecovered);
      expect(recovered.request.subject, 'Telltale 傳輸紀錄（上一次連線）');
      expect(recovered.sourceKind, ShareSourceKind.recoveredTranscript);

      final mutablePids = [PidLibrary.all.first];
      final expectedPid = await _collect(
        PidCsv.stream(List.unmodifiable(mutablePids)),
      );
      final pidFuture = _invoke(
        roots,
        5,
        (controller) => controller.sharePidCsv(pids: mutablePids),
        afterAdmission: mutablePids.clear,
      );
      final pid = await pidFuture;
      expect(pid.bytes, expectedPid);
      expect(pid.request.mimeType, 'text/csv');
      expect(pid.request.subject, 'Telltale 自訂 PID 定義');
      expect(pid.sourceKind, ShareSourceKind.pidCsv);
    },
  );

  test(
    'production request construction and native Share stay single-boundary',
    () {
      final lib = Directory('lib');
      final requestSites = <String>[];
      final nativeSites = <String>[];
      for (final entity in lib.listSync(recursive: true, followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final text = entity.readAsStringSync();
        if (text.contains('AppShareRequest(') ||
            text.contains('AppShareRequest.lazy(')) {
          // Constructor declarations are the request type boundary itself.
          if (!entity.path.endsWith('app_share_coordinator.dart')) {
            requestSites.add(entity.path);
          }
        }
        if (text.contains('SharePlus.instance.share')) {
          nativeSites.add(entity.path);
        }
      }
      expect(requestSites.toSet(), {
        'lib/state/app_share_entry_controller.dart',
      });
      expect(nativeSites, ['lib/core/share/app_share_platform_bridge.dart']);
    },
  );

  test('raw recovered and PID exports forward sharePositionOrigin', () async {
    final documents = Directory.systemTemp.createTempSync('share-entry-origin-docs');
    final roots = Directory.systemTemp.createTempSync('share-entry-origin-roots');
    addTearDown(() {
      if (documents.existsSync()) documents.deleteSync(recursive: true);
      if (roots.existsSync()) roots.deleteSync(recursive: true);
    });
    const origin = Rect.fromLTWH(12, 34, 56, 78);

    final raw = await _invoke(
      roots,
      61,
      (controller) => controller.shareRawTranscript(
        transcript: ObdTranscript(),
        header: 'Header\n',
        withHex: false,
        subjectAt: DateTime.utc(2026, 9, 1, 12),
        sharePositionOrigin: origin,
      ),
    );
    expect(raw.request.sharePositionOrigin, origin);

    final store = TranscriptStore(directory: () async => documents);
    final saved = ObdTranscript()
      ..recordRead([0x34, 0x31, 0x0d], DateTime.utc(2026));
    expect(
      await store.save(saved, 'Recovered\n', fromRealHardware: true),
      isTrue,
    );
    final displayed = await store.load();
    expect(displayed, isNotNull);
    final recovered = await _invoke(
      roots,
      62,
      (controller) => controller.shareRecoveredTranscript(
        store: store,
        expected: displayed!,
        sharePositionOrigin: origin,
      ),
    );
    expect(recovered.request.sharePositionOrigin, origin);

    final pid = await _invoke(
      roots,
      63,
      (controller) => controller.sharePidCsv(
        pids: [PidLibrary.all.first],
        sharePositionOrigin: origin,
      ),
    );
    expect(pid.request.sharePositionOrigin, origin);
  });

  test('telemetry facade rejects non-opaque IDs before admission', () async {
    final root = Directory.systemTemp.createTempSync('share-entry-invalid');
    addTearDown(() => root.deleteSync(recursive: true));
    final platform = _CapturePlatform();
    final coordinator = AppShareCoordinator(
      rootDirectory: () async => root,
      policy: const _Policy(),
      artifactGate: ArtifactOperationGate(),
      platform: platform,
      idSource: () => 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      nowUtc: () => DateTime.utc(2026),
      availableBytes: (_) async => 64 * 1024 * 1024,
    );
    expect(await coordinator.initialize(), AppShareInitializationOutcome.ready);
    final controller = AppShareEntryController(coordinator);
    for (final invalid in ['../secret', 'a/b', r'a\b', 'abc', '${'a' * 31}g']) {
      expect(
        (await controller.shareTelemetryCsv(
          documents: root,
          sessionId: invalid,
        )).error,
        ShareError.storageFailure,
      );
    }
    expect(platform.capture, isNull);
    expect(root.listSync(), isEmpty);
  });

  test('recovered descriptor opens only after synchronous admission', () async {
    for (final denial in ['policy', 'artifact', 'shareBusy']) {
      final root = Directory.systemTemp.createTempSync(
        'share-recovered-$denial',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final gate = ArtifactOperationGate();
      final policy = _MutablePolicy();
      final platform = denial == 'shareBusy'
          ? _NeverPlatform()
          : _CapturePlatform();
      var id = 0;
      final coordinator = AppShareCoordinator(
        rootDirectory: () async => root,
        policy: policy,
        artifactGate: gate,
        platform: platform,
        idSource: () => (++id).toRadixString(16).padLeft(32, '0'),
        nowUtc: () => DateTime.utc(2026),
        availableBytes: (_) async => 64 * 1024 * 1024,
      );
      expect(
        await coordinator.initialize(),
        AppShareInitializationOutcome.ready,
      );
      final store = _CountingStore();
      if (denial == 'policy') {
        policy.allow = false;
      } else if (denial == 'artifact') {
        expect(
          gate.tryAcquire('held', ArtifactOperation.delete).acquired,
          isTrue,
        );
      } else {
        unawaited(
          coordinator.share(
            AppShareRequest(
              sourceKind: ShareSourceKind.pidCsv,
              subject: 'held',
              streamFactory: () => Stream.value([1]),
            ),
          ),
        );
        await (platform as _NeverPlatform).invoked.future;
      }
      await AppShareEntryController(coordinator).shareRecoveredTranscript(
        store: store,
        expected: StoredTranscript(
          header: 'x',
          body: 'y',
          savedAt: DateTime.utc(2026),
        ),
      );
      expect(store.opens, 0, reason: denial);
    }
  });

  test(
    'telemetry worker exit before a terminal message fails closed',
    () async {
      await expectLater(
        telemetryExportWorkerStream(
          'unused',
          json: false,
          worker: _exitWithoutTerminal,
          gracefulExitTimeout: const Duration(seconds: 1),
          forcedExitTimeout: const Duration(seconds: 1),
        ),
        emitsError(
          isA<TelemetryExportException>().having(
            (error) => error.code,
            'code',
            'workerExitedPrematurely',
          ),
        ),
      );
    },
  );

  test('telemetry worker rejects terminal messages before handshake', () async {
    for (final worker in [_doneBeforeHandshake, _errorBeforeHandshake]) {
      await expectLater(
        telemetryExportWorkerStream(
          'unused',
          json: false,
          worker: worker,
          gracefulExitTimeout: const Duration(seconds: 1),
          forcedExitTimeout: const Duration(seconds: 1),
        ),
        emitsError(
          isA<TelemetryExportException>().having(
            (error) => error.code,
            'code',
            'workerProtocol',
          ),
        ),
      );
    }
  });

  test('telemetry worker preserves the exporter error code', () async {
    final file = File(
      '${Directory.systemTemp.createTempSync('share-worker-error').path}/bad.ndjson',
    )..writeAsStringSync('{bad}\n');
    addTearDown(() => file.parent.deleteSync(recursive: true));

    await expectLater(
      telemetryExportWorkerStream(file.path, json: false),
      emitsError(
        isA<TelemetryExportException>().having(
          (error) => error.code,
          'code',
          'invalidJson',
        ),
      ),
    );
  });

  test('completed stream waits for the worker exit acknowledgement', () async {
    final directory = Directory.systemTemp.createTempSync('share-worker-done');
    final marker = File('${directory.path}/exited');
    addTearDown(() => directory.deleteSync(recursive: true));

    await telemetryExportWorkerStream(
      marker.path,
      json: false,
      worker: _terminalMarkerWorker,
      gracefulExitTimeout: const Duration(seconds: 1),
      forcedExitTimeout: const Duration(seconds: 1),
    ).drain<void>();

    expect(marker.readAsStringSync(), 'terminalAck');
  });

  test('stream cancellation waits for contained worker shutdown', () async {
    final directory = Directory.systemTemp.createTempSync(
      'share-worker-cancel',
    );
    final marker = File('${directory.path}/exited');
    addTearDown(() => directory.deleteSync(recursive: true));
    final firstChunk = Completer<void>();

    final subscription =
        telemetryExportWorkerStream(
          marker.path,
          json: false,
          worker: _cancelMarkerWorker,
          gracefulExitTimeout: const Duration(seconds: 1),
          forcedExitTimeout: const Duration(seconds: 1),
        ).listen((_) {
          if (!firstChunk.isCompleted) firstChunk.complete();
        });
    await firstChunk.future.timeout(const Duration(seconds: 1));
    await subscription.cancel();

    expect(marker.readAsStringSync(), 'cancel');
  });
}

Future<void> _exitWithoutTerminal(List<Object?> args) async {}

Future<void> _doneBeforeHandshake(List<Object?> args) async {
  (args[0]! as SendPort).send('done');
  await Future<void>.delayed(const Duration(milliseconds: 25));
}

Future<void> _errorBeforeHandshake(List<Object?> args) async {
  (args[0]! as SendPort).send(<String, Object?>{
    'type': 'error',
    'code': 'invalidJson',
  });
  await Future<void>.delayed(const Duration(milliseconds: 25));
}

Future<void> _terminalMarkerWorker(List<Object?> args) async {
  final output = args[0]! as SendPort;
  final marker = File(args[1]! as String);
  final commands = ReceivePort();
  final iterator = StreamIterator<Object?>(commands);
  output.send(commands.sendPort);
  try {
    while (await iterator.moveNext()) {
      if (iterator.current != 'next') continue;
      output.send('done');
      while (await iterator.moveNext()) {
        final terminal = iterator.current;
        if (terminal == 'terminalAck' || terminal == 'cancel') {
          await Future<void>.delayed(const Duration(milliseconds: 25));
          marker.writeAsStringSync('$terminal');
          return;
        }
      }
    }
  } finally {
    await iterator.cancel();
    commands.close();
  }
}

Future<void> _cancelMarkerWorker(List<Object?> args) async {
  final output = args[0]! as SendPort;
  final marker = File(args[1]! as String);
  final commands = ReceivePort();
  output.send(commands.sendPort);
  await for (final command in commands) {
    if (command == 'next') {
      output.send(<int>[1]);
    } else if (command == 'cancel' || command == 'terminalAck') {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      marker.writeAsStringSync('$command');
      commands.close();
      return;
    }
  }
}

Future<_Capture> _invoke(
  Directory roots,
  int sequence,
  Future<AppShareOutcome> Function(AppShareEntryController) operation, {
  void Function()? afterAdmission,
}) async {
  final root = Directory('${roots.path}/$sequence')..createSync();
  final platform = _CapturePlatform();
  final coordinator = AppShareCoordinator(
    rootDirectory: () async => root,
    policy: const _Policy(),
    artifactGate: ArtifactOperationGate(),
    platform: platform,
    idSource: () => sequence.toRadixString(16).padLeft(32, '0'),
    nowUtc: () => DateTime.utc(2026, 8, 30),
    availableBytes: (_) async => 64 * 1024 * 1024,
  );
  expect(await coordinator.initialize(), AppShareInitializationOutcome.ready);
  final outcome = operation(AppShareEntryController(coordinator));
  afterAdmission?.call();
  expect((await outcome).result, AppShareResult.selected);
  final ledgerFile = root.listSync().whereType<File>().singleWhere(
    (file) => file.path.endsWith('.lease.json'),
  );
  final id = ledgerFile.uri.pathSegments.last.split('.').first;
  final record = await ShareLeaseLedger(root).read(id);
  return _Capture(
    platform.capture!.request,
    platform.capture!.bytes,
    record!.sourceKind,
  );
}

final class _Capture {
  const _Capture(this.request, this.bytes, this.sourceKind);
  final AppSharePlatformRequest request;
  final List<int> bytes;
  final ShareSourceKind sourceKind;
}

final class _CapturePlatform implements AppSharePlatform {
  _Capture? capture;
  @override
  Future<AppShareResult> share(AppSharePlatformRequest request) async {
    capture = _Capture(
      request,
      File(request.path).readAsBytesSync(),
      ShareSourceKind.pidCsv,
    );
    return AppShareResult.selected;
  }
}

final class _CountingStore extends TranscriptStore {
  int opens = 0;
  @override
  Future<StreamingStoredTranscript?> openStreaming({
    StoredTranscript? expected,
  }) async {
    opens++;
    throw StateError('descriptor must not open');
  }
}

final class _MutablePolicy implements AppSharePolicy {
  bool allow = true;
  @override
  SharePreparationPermit? freeze() => allow
      ? const SharePreparationPermit(
          recorderEpoch: 1,
          foregroundEpoch: 1,
          connectionEpoch: 1,
          safetyEpoch: 1,
          connectionClass: ShareConnectionClass.disconnected,
        )
      : null;
  @override
  SharePermitValidation validate(SharePreparationPermit permit) =>
      const SharePermitValidation.valid();
}

final class _NeverPlatform implements AppSharePlatform {
  final invoked = Completer<void>();
  @override
  Future<AppShareResult> share(AppSharePlatformRequest request) {
    invoked.complete();
    return Completer<AppShareResult>().future;
  }
}

final class _Policy implements AppSharePolicy {
  const _Policy();
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

Uint8List _sessionBytes(String id) {
  final definition = FrozenPidDefinition.freeze(
    const TelemetrySignalDefinition(
      id: '7E0:010C',
      name: 'RPM',
      shortName: 'RPM',
      request: '01 0C',
      header: '7E0',
      unit: 'rpm',
      unitProvenance: UnitProvenance.standardDirectCanonical,
      minimum: 0,
      maximum: 8000,
      isCustom: false,
      variant: '',
      priority: 0,
      equation: '(A*256+B)/4',
    ),
  );
  final header = TelemetrySessionHeader(
    sessionId: id,
    startedAtUtc: DateTime.utc(2026),
    source: TelemetrySource.demo,
    transport: TransportKind.demo,
    protocol: 'AUTO',
    signals: [definition],
  );
  final event = TelemetryEvent.value(
    observedAtUtc: DateTime.utc(2026, 1, 1, 0, 0, 1),
    sourceTimestampUtc: DateTime.utc(2026, 1, 1, 0, 0, 1),
    elapsedUs: 1000,
    pidId: definition.definition.id,
    value: 1000,
  );
  final prefix = TelemetrySessionCodec.encodePrefix(header, [event]);
  return TelemetrySessionCodec.encode(
    TelemetrySession(
      header: header,
      events: [event],
      footer: TelemetrySessionFooter(
        endedAtUtc: DateTime.utc(2026, 1, 1, 0, 0, 2),
        terminalReason: TelemetryTerminalReason.user,
        valueCount: 1,
        statusCount: 0,
        gapCount: 0,
        bytesBeforeFooter: prefix.length,
      ),
    ),
  );
}

Future<List<int>> _collect(Stream<List<int>> stream) async {
  final output = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    output.add(chunk);
  }
  return output.takeBytes();
}
