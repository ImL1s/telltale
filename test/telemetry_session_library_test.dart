import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/core/share/app_share_platform_bridge.dart';
import 'package:torque_obd/state/app_share_coordinator.dart';
import 'package:torque_obd/state/artifact_operation_gate.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/telemetry_sessions.dart';
import 'package:torque_obd/telemetry/session/telemetry_recorder.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_codec.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_store.dart';

Future<void> _writeSession(
  Directory documents,
  String id,
  TelemetrySource source, {
  Duration wallClockDuration = const Duration(seconds: 2),
  List<int> elapsedUsValues = const [1000000],
}) async {
  final started = DateTime.utc(2026, 8, 30, 1);
  final definition = freezePidDefinition(PidLibrary.engineRpm);
  final header = TelemetrySessionHeader(
    sessionId: id,
    startedAtUtc: started,
    source: source,
    transport: source == TelemetrySource.demo
        ? TransportKind.demo
        : TransportKind.wifi,
    protocol: 'ISO 15765-4 CAN',
    signals: [definition],
  );
  final events = <TelemetryEvent>[
    for (final elapsedUs in elapsedUsValues)
      TelemetryEvent.value(
        observedAtUtc: started.add(Duration(microseconds: elapsedUs)),
        sourceTimestampUtc: started.add(Duration(microseconds: elapsedUs)),
        elapsedUs: elapsedUs,
        pidId: definition.definition.id,
        value: 1726,
      ),
  ];
  final prefix = TelemetrySessionCodec.encodePrefix(header, events);
  final footer = TelemetrySessionFooter(
    endedAtUtc: started.add(wallClockDuration),
    terminalReason: TelemetryTerminalReason.user,
    valueCount: events.length,
    statusCount: 0,
    gapCount: 0,
    bytesBeforeFooter: prefix.length,
  );
  final root = Directory('${documents.path}/telltale-telemetry');
  await root.create(recursive: true);
  await File('${root.path}/$id.ndjson').writeAsBytes(
    TelemetrySessionCodec.encode(
      TelemetrySession(header: header, events: events, footer: footer),
    ),
  );
}

void main() {
  test(
    'library partitions validated and damaged artifacts off-isolate',
    () async {
      final documents = await Directory.systemTemp.createTemp('library');
      addTearDown(() => documents.delete(recursive: true));
      const validId = '00000000000000000000000000000001';
      const damagedId = '00000000000000000000000000000002';
      await _writeSession(documents, validId, TelemetrySource.demo);
      final root = Directory('${documents.path}/telltale-telemetry');
      await File('${root.path}/$damagedId.ndjson').writeAsString('{bad\n');

      final library = await TelemetrySessionLibraryService(
        documentsDirectory: () async => documents,
      ).load();

      expect(library.sessions.single.id, validId);
      expect(library.sessions.single.sourceLabel, '內建模擬');
      expect(library.sessions.single.valueCount, 1);
      expect(library.damaged.single.id, damagedId);
      expect(library.damaged.single.kind, DamagedTelemetryKind.corrupt);
      expect(library.groupCount, 2);
      expect(library.remainingGroups, 18);
      expect(library.recognizedBytes, greaterThan(0));
      expect(library.encodedProjectionBytes, lessThanOrEqualTo(80 * 1024));
      expect(library.workerDebugName, isNot(Isolate.current.debugName));
    },
  );

  test(
    'history duration uses monotonic event span, not recovery wall clock',
    () async {
      final documents = await Directory.systemTemp.createTemp(
        'library-duration',
      );
      addTearDown(() => documents.delete(recursive: true));
      const id = '00000000000000000000000000000004';
      // Five-minute recording recovered the next morning: wall span is ~24h,
      // but history must show the ~5 minute monotonic event span.
      await _writeSession(
        documents,
        id,
        TelemetrySource.demo,
        wallClockDuration: const Duration(hours: 23),
        elapsedUsValues: const [1_000_000, 301_000_000],
      );

      final library = await TelemetrySessionLibraryService(
        documentsDirectory: () async => documents,
      ).load();

      final session = library.sessions.single;
      expect(
        session.endedAtUtc.difference(session.startedAtUtc),
        const Duration(hours: 23),
      );
      expect(session.elapsedDurationUs, 300_000_000);
      expect(session.duration, const Duration(minutes: 5));
    },
  );

  test('library labels final plus staging group as collision', () async {
    final documents = await Directory.systemTemp.createTemp(
      'library-collision',
    );
    addTearDown(() => documents.delete(recursive: true));
    const id = '00000000000000000000000000000003';
    await _writeSession(documents, id, TelemetrySource.demo);
    final root = Directory('${documents.path}/telltale-telemetry');
    await File('${root.path}/$id.ndjson.part').writeAsString('{staging}\n');

    final library = await TelemetrySessionLibraryService(
      documentsDirectory: () async => documents,
    ).load();

    expect(library.sessions, isEmpty);
    expect(library.damaged.single.id, id);
    expect(library.damaged.single.kind, DamagedTelemetryKind.collision);
  });

  test('index projection retains at most twenty newest groups', () async {
    final documents = await Directory.systemTemp.createTemp('library-cap');
    addTearDown(() => documents.delete(recursive: true));
    final root = Directory('${documents.path}/telltale-telemetry');
    await root.create(recursive: true);
    for (var index = 0; index < 24; index++) {
      final id = index.toRadixString(16).padLeft(32, '0');
      final file = File('${root.path}/$id.ndjson');
      await file.writeAsString('{damaged:$index}\n');
      await file.setLastModified(
        DateTime.utc(2026, 8, 30).add(Duration(seconds: index)),
      );
    }

    final library = await TelemetrySessionLibraryService(
      documentsDirectory: () async => documents,
    ).load();

    expect(library.sessions.length + library.damaged.length, 20);
    expect(library.omittedCount, 4);
    expect(
      library.groupCount,
      24,
      reason: 'quota reports all groups, not projection',
    );
    expect(library.encodedProjectionBytes, lessThanOrEqualTo(80 * 1024));
  });

  test('source labels never turn field-app provenance into real-car proof', () {
    expect(telemetrySourceLabel(TelemetrySource.demo), '內建模擬');
    expect(telemetrySourceLabel(TelemetrySource.simulatedRig), '測試馬具');
    expect(
      telemetrySourceLabel(TelemetrySource.fieldAppConnection),
      '一般 field App 連線',
    );
  });

  test(
    'delete requires confirmation, recorder-first guard, policy checkpoint',
    () async {
      final documents = await Directory.systemTemp.createTemp('delete-action');
      addTearDown(() => documents.delete(recursive: true));
      const id = '00000000000000000000000000000009';
      await _writeSession(documents, id, TelemetrySource.demo);
      final policy = _PermittingPolicy();
      var phase = TelemetryRecorderPhase.recording;
      final actions = TelemetrySessionActions(
        documentsDirectory: () async => documents,
        store: TelemetrySessionStore(documentsDirectory: () async => documents),
        artifactGate: ArtifactOperationGate(),
        sharePolicy: policy,
        readRecorderPhase: () => phase,
      );

      final recorderBlocked = await actions.delete(id, confirmed: true);
      expect(
        recorderBlocked.failure,
        TelemetrySessionActionFailure.recorderActive,
      );
      expect(
        policy.freezeCount,
        0,
        reason: 'recorder guard wins before policy',
      );

      phase = TelemetryRecorderPhase.idle;
      final unconfirmed = await actions.delete(id, confirmed: false);
      expect(
        unconfirmed.failure,
        TelemetrySessionActionFailure.confirmationRequired,
      );
      expect(
        File('${documents.path}/telltale-telemetry/$id.ndjson').existsSync(),
        isTrue,
      );

      final deleted = await actions.delete(id, confirmed: true);
      expect(deleted.isSuccess, isTrue);
      expect(policy.freezeCount, 1);
      expect(policy.validationCount, 6);
      expect(
        File('${documents.path}/telltale-telemetry/$id.ndjson').existsSync(),
        isFalse,
      );
    },
  );

  test(
    'delete revocation before first stat is policyChanged and releasable',
    () async {
      final documents = await Directory.systemTemp.createTemp('delete-revoke');
      addTearDown(() => documents.delete(recursive: true));
      const id = '0000000000000000000000000000000a';
      await _writeSession(documents, id, TelemetrySource.demo);
      final policy = _PermittingPolicy(invalidateAtValidation: 2);
      final gate = ArtifactOperationGate();
      final actions = TelemetrySessionActions(
        documentsDirectory: () async => documents,
        store: TelemetrySessionStore(documentsDirectory: () async => documents),
        artifactGate: gate,
        sharePolicy: policy,
        readRecorderPhase: () => TelemetryRecorderPhase.idle,
      );

      final result = await actions.delete(id, confirmed: true);

      expect(result.failure, TelemetrySessionActionFailure.policyChanged);
      expect(gate.snapshot.isIdle, isTrue);
      expect(
        File('${documents.path}/telltale-telemetry/$id.ndjson').existsSync(),
        isTrue,
      );
    },
  );

  test('delete post-mutation ambiguity retains artifact gate', () async {
    final documents = await Directory.systemTemp.createTemp('delete-ambiguous');
    addTearDown(() => documents.delete(recursive: true));
    const id = '0000000000000000000000000000000b';
    await _writeSession(documents, id, TelemetrySource.demo);
    final policy = _PermittingPolicy(invalidateAtValidation: 6);
    final gate = ArtifactOperationGate();
    var restartNotices = 0;
    final actions = TelemetrySessionActions(
      documentsDirectory: () async => documents,
      store: TelemetrySessionStore(documentsDirectory: () async => documents),
      artifactGate: gate,
      sharePolicy: policy,
      readRecorderPhase: () => TelemetryRecorderPhase.idle,
      onRestartRequired: () => restartNotices++,
    );

    final result = await actions.delete(id, confirmed: true);

    expect(result.failure, TelemetrySessionActionFailure.restartRequired);
    expect(result.message, telemetryArtifactRestartRequiredCopy);
    expect(restartNotices, 1);
    expect(gate.snapshot.isIdle, isFalse);
    expect(gate.snapshot.operation, ArtifactOperation.delete);

    final refused = await actions.delete(id, confirmed: true);
    expect(refused.failure, TelemetrySessionActionFailure.restartRequired);
    expect(refused.message, telemetryArtifactRestartRequiredCopy);
    expect(restartNotices, 1);
  });

  test(
    'share cleanup ambiguity becomes a persistent restart refusal',
    () async {
      final documents = await Directory.systemTemp.createTemp(
        'export-cleanup-required',
      );
      addTearDown(() => documents.delete(recursive: true));
      const id = '0000000000000000000000000000000c';
      await _writeSession(documents, id, TelemetrySource.demo);
      final shareRoot = Directory('${documents.path}/share-cache');
      await shareRoot.create();
      await File('${shareRoot.path}/unrecognized').writeAsBytes([1]);
      final policy = _PermittingPolicy();
      final gate = ArtifactOperationGate();
      var restartNotices = 0;
      final actions = TelemetrySessionActions(
        documentsDirectory: () async => documents,
        store: TelemetrySessionStore(documentsDirectory: () async => documents),
        shareCoordinator: AppShareCoordinator(
          rootDirectory: () async => shareRoot,
          policy: policy,
          artifactGate: gate,
          platform: _UnusedPlatform(),
          idSource: () => '11111111111111111111111111111111',
          nowUtc: () => DateTime.utc(2026),
          availableBytes: (_) async => 80 * 1024 * 1024,
        ),
        artifactGate: gate,
        sharePolicy: policy,
        readRecorderPhase: () => TelemetryRecorderPhase.idle,
        onRestartRequired: () => restartNotices++,
      );

      final result = await actions.export(id, TelemetryExportFormat.json);

      expect(result.failure, TelemetrySessionActionFailure.restartRequired);
      expect(result.message, telemetryArtifactRestartRequiredCopy);
      expect(restartNotices, 1);
      expect(
        (await actions.export(id, TelemetryExportFormat.csv)).failure,
        TelemetrySessionActionFailure.restartRequired,
      );
      expect(restartNotices, 1);
    },
  );
}

class _UnusedPlatform implements AppSharePlatform {
  @override
  Future<AppShareResult> share(AppSharePlatformRequest request) {
    fail('platform share must not run after startup cache ambiguity');
  }
}

class _PermittingPolicy implements AppSharePolicy {
  _PermittingPolicy({this.invalidateAtValidation});

  final int? invalidateAtValidation;
  var freezeCount = 0;
  var validationCount = 0;

  @override
  SharePreparationPermit? freeze() {
    freezeCount++;
    return const SharePreparationPermit(
      recorderEpoch: 1,
      foregroundEpoch: 1,
      connectionEpoch: 1,
      safetyEpoch: 1,
      connectionClass: ShareConnectionClass.disconnected,
    );
  }

  @override
  SharePermitValidation validate(SharePreparationPermit permit) {
    validationCount++;
    if (validationCount >= (invalidateAtValidation ?? 1 << 30)) {
      return const SharePermitValidation.invalid(SharePermitCause.connection);
    }
    return const SharePermitValidation.valid();
  }
}
