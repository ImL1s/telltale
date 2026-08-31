library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:torque_obd/core/field_evidence/platform_metadata.dart';
import 'package:torque_obd/core/hash/fnv1a64.dart';
import 'package:torque_obd/core/share/app_share_platform_bridge.dart';
import 'package:torque_obd/core/share/share_lease_ledger.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/session_evidence.dart';
import 'package:torque_obd/obd/transcript.dart';
import 'package:torque_obd/state/app_share_coordinator.dart';
import 'package:torque_obd/state/app_share_entry_controller.dart';
import 'package:torque_obd/state/artifact_operation_gate.dart';

import 'rig_support.dart';

const _gateCEnabled = bool.fromEnvironment('TELLTALE_GATE_C_INSTRUMENTATION');
const _controlName = 'telltale-memory-rig-control';
const _sharesName = 'telltale-app-shares';
const _mib = 1024 * 1024;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Gate C process-kill and reconstruction target', (tester) async {
    final paths = await _requireExactGate();
    paths.control.createSync(recursive: true);
    debugPrint('TELLTALE_GATE_C_COMMAND_READY');
    final command = await _waitCommand(paths.control);
    switch (command.phase) {
      case 'seed':
        await _seed(paths, command);
      case 'recover':
        await _recover(tester, paths, command);
      case 'realPluginMirror':
        await _realPluginMirror(paths, command);
    }
  });
}

Future<_Paths> _requireExactGate() async {
  expect(Platform.isAndroid, isTrue);
  expect(kDebugMode, isTrue);
  expect(isObdTestRigBuild, isTrue);
  expect(_gateCEnabled, isTrue);
  final raw = await const MethodChannel(
    'com.cbstudio.telltale/platform_metadata',
  ).invokeMethod<Object?>('getPlatformMetadata');
  expect(raw, isA<Map<Object?, Object?>>());
  final metadata = PlatformMetadata.fromPlatformMap(
    (raw! as Map<Object?, Object?>).map(
      (key, value) => MapEntry(key.toString(), value),
    ),
  );
  expect(
    isRigShareCaptureEligible(
      metadata: metadata,
      buildFlag: isObdTestRigBuild,
      debugMode: kDebugMode,
    ),
    isTrue,
  );
  expect(metadata.applicationId, androidRigApplicationId);
  final cache = await getApplicationCacheDirectory();
  return _Paths(
    control: Directory('${cache.path}/$_controlName'),
    shares: Directory('${cache.path}/$_sharesName'),
  );
}

Future<_Command> _waitCommand(Directory control) async {
  final file = File('${control.path}/command.json');
  final deadline = DateTime.now().add(const Duration(minutes: 2));
  while (DateTime.now().isBefore(deadline)) {
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.file) {
      final value = jsonDecode(await file.readAsString());
      return _Command.parse(value);
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('Gate C command timed out');
}

Future<void> _seed(_Paths paths, _Command command) async {
  await paths.shares.create(recursive: true);
  final gate = ArtifactOperationGate();
  final _ObservedPlatform platform = command.cut == 'neverResult'
      ? _NeverPlatform()
      : _CompletablePlatform();
  late AppShareCoordinator coordinator;
  final selectedProbe = switch (command.cut) {
    'sourceVerified' => AppShareCrashCut.sourceVerified,
    'handedOffBeforePlatform' => AppShareCrashCut.handedOffLeaseVerified,
    'platformInvoked' => AppShareCrashCut.platformInvoked,
    _ => null,
  };
  final probe = selectedProbe == null
      ? null
      : _FileAcknowledgingCrashCutProbe(
          cut: selectedProbe,
          paths: paths,
          command: command,
          gate: gate,
          coordinator: () => coordinator,
          platform: () => platform,
        );
  coordinator = _coordinator(
    paths,
    command,
    gate: gate,
    platform: platform,
    probe: probe,
  );
  expect(await coordinator.initialize(), AppShareInitializationOutcome.ready);
  if (command.cut == 'allocated') {
    unawaited(
      coordinator.share(
        AppShareRequest(
          sourceKind: ShareSourceKind.rawTranscript,
          subject: 'Gate C allocated cut',
          knownByteLength: 64 * 1024,
          streamFactory: () => StreamController<List<int>>().stream,
        ),
      ),
    );
    final record = await _waitRecord(paths.shares, command.id);
    expect(record.state, ShareLeaseState.allocated);
    await _waitRegularFile(
      File('${paths.shares.path}/${record.sourceFileName}'),
    );
    final ownership = await _proveOwnership(coordinator, gate);
    await _ack(
      paths,
      command,
      record,
      platformCalls: 0,
      platformSemantic: 'notInvoked',
      pendingObservationMs: 0,
      ownership: ownership,
    );
  } else if (selectedProbe != null) {
    if (selectedProbe == AppShareCrashCut.platformInvoked) {
      unawaited(
        AppShareEntryController(coordinator)
            .sharePidCsv(pids: [PidLibrary.all.first]),
      );
    } else {
      final transcript = ObdTranscript()
        ..recordWrite([0x41, 0x54, 0x5a, 0x0d], DateTime.utc(2026));
      unawaited(
        AppShareEntryController(coordinator).shareRawTranscript(
          transcript: transcript,
          header: 'Gate C\n',
          withHex: true,
          subjectAt: DateTime.utc(2026),
        ),
      );
    }
    await probe!.acknowledged.future;
  } else {
    unawaited(
      AppShareEntryController(coordinator)
          .sharePidCsv(pids: [PidLibrary.all.first]),
    );
    await platform.invoked.future.timeout(const Duration(seconds: 30));
    final minimumObservationMs = command.cut == 'pendingResult' ? 2000 : 5000;
    await _observePendingFor(platform, minimumObservationMs);
    expect(platform.resultCompleted, isFalse);
    final record = await _waitRecord(paths.shares, command.id);
    expect(record.state, ShareLeaseState.handedOffLease);
    expect(record.result, 'pending');
    final ownership = await _proveOwnership(coordinator, gate);
    await _ack(
      paths,
      command,
      record,
      platformCalls: platform.calls,
      platformSemantic: command.cut == 'pendingResult'
          ? 'completablePending'
          : 'nonCompletablePending',
      pendingObservationMs: platform.pendingObservationMs,
      ownership: ownership,
    );
  }
  await Completer<void>().future;
}

Future<void> _observePendingFor(
  _ObservedPlatform platform,
  int minimumObservationMs,
) async {
  while (platform.pendingObservationMs < minimumObservationMs) {
    await Future<void>.delayed(
      Duration(
        milliseconds: minimumObservationMs - platform.pendingObservationMs,
      ),
    );
  }
}

Future<void> _recover(
  WidgetTester tester,
  _Paths paths,
  _Command command,
) async {
  debugPrint('TELLTALE_GATE_C_RESTORE_READY token=${command.runToken}');
  await _waitRegularFile(
    File('${paths.control.path}/${command.runToken}-restore-complete'),
  );
  final manifestFile = File(
    '${paths.control.path}/${command.runToken}-restore-manifest.json',
  );
  expect(
    await FileSystemEntity.type(manifestFile.path, followLinks: false),
    FileSystemEntityType.file,
  );
  final manifest = _RestoreManifest.parse(
    jsonDecode(await manifestFile.readAsString()),
    command,
  );
  await _verifyRestoredGroup(paths.shares, manifest);
  await startRigAppPreservingState(tester);
  final entries = await paths.shares.exists()
      ? await paths.shares.list(followLinks: false).toList()
      : <FileSystemEntity>[];
  if (command.cut == 'allocated' || command.cut == 'sourceVerified') {
    expect(entries, isEmpty);
  } else {
    final record = await _waitRecord(paths.shares, command.id);
    expect(record.state, ShareLeaseState.handedOffLease);
    expect(record.result, 'pending');
    await _verifyRecord(paths.shares, record);
  }
  debugPrint(
    'TELLTALE_GATE_C_RECOVERY_VERIFIED token=${command.runToken} '
    'cut=${command.cut}',
  );
  await _waitRegularFile(
    File('${paths.control.path}/${command.runToken}-capture-complete'),
  );
}

Future<void> _realPluginMirror(_Paths paths, _Command command) async {
  final platform = _CountingPlatform(const AppSharePlatformBridge());
  final gate = ArtifactOperationGate();
  final coordinator = _coordinator(
    paths,
    command,
    gate: gate,
    platform: platform,
  );
  expect(await coordinator.initialize(), AppShareInitializationOutcome.ready);
  unawaited(
    AppShareEntryController(coordinator)
        .sharePidCsv(pids: [PidLibrary.all.first]),
  );
  ShareLeaseRecord? record;
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    record = await ShareLeaseLedger(paths.shares).read(command.id);
    if (record?.state == ShareLeaseState.handedOffLease) break;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  expect(record?.state, ShareLeaseState.handedOffLease);
  expect(platform.calls, 1);
  final ownership = await _proveOwnership(coordinator, gate);
  await _ack(
    paths,
    command,
    record!,
    platformCalls: platform.calls,
    platformSemantic: 'realPluginInvoked',
    pendingObservationMs: 0,
    ownership: ownership,
  );
  await Completer<void>().future;
}

AppShareCoordinator _coordinator(
  _Paths paths,
  _Command command, {
  required ArtifactOperationGate gate,
  required AppSharePlatform platform,
  AppShareCrashCutProbe? probe,
}) => AppShareCoordinator(
  rootDirectory: () async => paths.shares,
  policy: const _Policy(),
  artifactGate: gate,
  platform: platform,
  idSource: () => command.id,
  nowUtc: () => DateTime.now().toUtc(),
  availableBytes: (_) async => 128 * _mib,
  crashCutProbe: probe,
);

Future<ShareLeaseRecord> _waitRecord(Directory root, String id) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    final value = await ShareLeaseLedger(root).read(id);
    if (value != null) return value;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  throw StateError('Gate C ledger did not appear');
}

Future<void> _verifyRecord(Directory root, ShareLeaseRecord record) async {
  final ledgerPath = '${root.path}/${record.ledgerFileName}';
  final sourcePath = '${root.path}/${record.sourceFileName}';
  expect(
    await FileSystemEntity.type(ledgerPath, followLinks: false),
    FileSystemEntityType.file,
  );
  expect(
    await FileSystemEntity.type(sourcePath, followLinks: false),
    FileSystemEntityType.file,
  );
  final hash = Fnv1a64();
  var bytes = 0;
  await for (final chunk in File(sourcePath).openRead()) {
    bytes += chunk.length;
    hash.add(chunk);
  }
  expect(bytes, record.bytes);
  expect(hash.fingerprint, record.fingerprint);
}

Future<void> _ack(
  _Paths paths,
  _Command command,
  ShareLeaseRecord record, {
  required int platformCalls,
  required String platformSemantic,
  required int pendingObservationMs,
  required _OwnershipProof ownership,
  int? verifiedBytes,
  String? verifiedFingerprint,
}) async {
  if (record.state == ShareLeaseState.handedOffLease) {
    await _verifyRecord(paths.shares, record);
  }
  final file = File(
    '${paths.control.path}/${command.runToken}-${command.cut}-ready.json',
  );
  await file.create(exclusive: true);
  final sink = file.openWrite(mode: FileMode.writeOnly);
  final evidenceBytes = verifiedBytes ?? record.bytes;
  final evidenceFingerprint = verifiedFingerprint ?? record.fingerprint;
  sink.write(
    jsonEncode({
      'version': 1,
      'runToken': command.runToken,
      'phase': command.phase,
      'cut': command.cut,
      'id': record.id,
      'state': record.state.name,
      'sourceKind': record.sourceKind.name,
      'sourceFileName': record.sourceFileName,
      'ledgerFileName': record.ledgerFileName,
      'bytes': evidenceBytes,
      'fingerprint': evidenceFingerprint,
      'result': record.result,
      'platformCalls': platformCalls,
      'platformSemantic': platformSemantic,
      'pendingObservationMs': pendingObservationMs,
      'gateIdle': ownership.gateIdle,
      'secondShareError': ownership.secondShareError.name,
      'crossFeatureDenied': ownership.crossFeatureDenied,
    }),
  );
  await sink.flush();
  await sink.close();
  debugPrint(
    'TELLTALE_GATE_C_CUT_READY token=${command.runToken} cut=${command.cut} '
    'id=${record.id} bytes=${evidenceBytes ?? 0} '
    'fingerprint=${evidenceFingerprint ?? 'none'} state=${record.state.name} '
    'result=${record.result ?? 'none'} platformCalls=$platformCalls',
  );
}

Future<_OwnershipProof> _proveOwnership(
  AppShareCoordinator coordinator,
  ArtifactOperationGate gate,
) async {
  final gateIdle = gate.snapshot.isIdle;
  final second = await coordinator.share(
    AppShareRequest(
      sourceKind: ShareSourceKind.rawTranscript,
      subject: 'Gate C ownership check',
      streamFactory: () => Stream.value([1]),
    ),
  );
  final crossFeature = gate.tryAcquire(
    'gate-c-cross-feature',
    ArtifactOperation.delete,
  );
  expect(gateIdle, isFalse);
  expect(second.error, ShareError.shareBusy);
  expect(crossFeature.token, isNull);
  return _OwnershipProof(
    gateIdle: gateIdle,
    secondShareError: second.error!,
    crossFeatureDenied: crossFeature.token == null,
  );
}

Future<void> _waitRegularFile(File file) async {
  final deadline = DateTime.now().add(const Duration(minutes: 2));
  while (DateTime.now().isBefore(deadline)) {
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.file) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('Gate C host handshake timed out: ${file.path}');
}

final class _FileAcknowledgingCrashCutProbe implements AppShareCrashCutProbe {
  _FileAcknowledgingCrashCutProbe({
    required this.cut,
    required this.paths,
    required this.command,
    required this.gate,
    required this.coordinator,
    required this.platform,
  });
  final AppShareCrashCut cut;
  final _Paths paths;
  final _Command command;
  final ArtifactOperationGate gate;
  final AppShareCoordinator Function() coordinator;
  final _ObservedPlatform Function() platform;
  final acknowledged = Completer<void>();

  @override
  Future<void>? pauseAt(AppShareCrashCutSnapshot snapshot) {
    if (snapshot.cut != cut) return null;
    return _verifyAndPause(snapshot);
  }

  Future<void> _verifyAndPause(AppShareCrashCutSnapshot snapshot) async {
    expect(
      await FileSystemEntity.type(
        '${paths.shares.path}/${snapshot.ledgerFileName}',
        followLinks: false,
      ),
      FileSystemEntityType.file,
    );
    expect(
      await FileSystemEntity.type(
        '${paths.shares.path}/${snapshot.sourceFileName}',
        followLinks: false,
      ),
      FileSystemEntityType.file,
    );
    final record = await ShareLeaseLedger(paths.shares).read(snapshot.id);
    expect(record, isNotNull);
    expect(record!.state, snapshot.ledgerState);
    expect(record.sourceFileName, snapshot.sourceFileName);
    if (snapshot.ledgerState == ShareLeaseState.handedOffLease) {
      expect(record.bytes, snapshot.bytes);
      expect(record.fingerprint, snapshot.fingerprint);
      expect(record.result, snapshot.result);
    } else {
      final hash = Fnv1a64();
      var bytes = 0;
      await for (final chunk in File(
        '${paths.shares.path}/${snapshot.sourceFileName}',
      ).openRead()) {
        bytes += chunk.length;
        hash.add(chunk);
      }
      expect(bytes, snapshot.bytes);
      expect(hash.fingerprint, snapshot.fingerprint);
    }
    final ownership = await _proveOwnership(coordinator(), gate);
    await _ack(
      paths,
      command,
      record,
      platformCalls: platform().calls,
      platformSemantic: cut == AppShareCrashCut.platformInvoked
          ? 'invokedBeforeAwait'
          : 'notInvoked',
      pendingObservationMs: 0,
      ownership: ownership,
      verifiedBytes: snapshot.bytes,
      verifiedFingerprint: snapshot.fingerprint,
    );
    acknowledged.complete();
    await Completer<void>().future;
  }
}

final class _OwnershipProof {
  const _OwnershipProof({
    required this.gateIdle,
    required this.secondShareError,
    required this.crossFeatureDenied,
  });
  final bool gateIdle;
  final ShareError secondShareError;
  final bool crossFeatureDenied;
}

Future<void> _verifyRestoredGroup(
  Directory root,
  _RestoreManifest manifest,
) async {
  expect(
    await FileSystemEntity.type(root.path, followLinks: false),
    FileSystemEntityType.directory,
  );
  final entries = await root.list(followLinks: false).toList();
  expect(entries, hasLength(2));
  final names = <String>{};
  for (final entry in entries) {
    expect(
      await FileSystemEntity.type(entry.path, followLinks: false),
      FileSystemEntityType.file,
    );
    names.add(entry.uri.pathSegments.last);
  }
  expect(names, {manifest.sourceFileName, manifest.ledgerFileName});
  final record = await ShareLeaseLedger(root).read(manifest.id);
  expect(record, isNotNull);
  expect(record!.id, manifest.id);
  expect(record.sourceKind.name, manifest.sourceKind);
  expect(record.state.name, manifest.state);
  expect(record.result, manifest.result);
  if (record.state == ShareLeaseState.handedOffLease) {
    expect(record.bytes, manifest.sourceBytes);
    expect(record.fingerprint, manifest.sourceFingerprint);
  }
  final source = File('${root.path}/${manifest.sourceFileName}');
  final hash = Fnv1a64();
  var bytes = 0;
  await for (final chunk in source.openRead()) {
    bytes += chunk.length;
    hash.add(chunk);
  }
  expect(bytes, manifest.sourceBytes);
  expect(hash.fingerprint, manifest.sourceFingerprint);
}

final class _RestoreManifest {
  const _RestoreManifest({
    required this.id,
    required this.sourceKind,
    required this.state,
    required this.sourceFileName,
    required this.ledgerFileName,
    required this.sourceBytes,
    required this.sourceFingerprint,
    required this.result,
    required this.platformCalls,
    required this.platformSemantic,
    required this.pendingObservationMs,
  });

  final String id;
  final String sourceKind;
  final String state;
  final String sourceFileName;
  final String ledgerFileName;
  final int sourceBytes;
  final String sourceFingerprint;
  final String? result;
  final int platformCalls;
  final String platformSemantic;
  final int pendingObservationMs;

  static final _sha256 = RegExp(r'^[0-9a-f]{64}$');

  factory _RestoreManifest.parse(Object? value, _Command command) {
    const keys = {
      'version',
      'runToken',
      'cut',
      'id',
      'sourceKind',
      'state',
      'sourceFileName',
      'ledgerFileName',
      'sourceBytes',
      'sourceFingerprint',
      'result',
      'platformCalls',
      'platformSemantic',
      'pendingObservationMs',
      'archiveSha256',
      'sourceSha256',
      'ledgerSha256',
    };
    if (value is! Map<String, dynamic> ||
        value.keys.toSet().difference(keys).isNotEmpty ||
        value.keys.length != keys.length ||
        value['version'] != 1 ||
        value['runToken'] != command.runToken ||
        value['cut'] != command.cut ||
        value['id'] != command.id) {
      throw const FormatException('invalid Gate C restore manifest');
    }
    final sourceKind = value['sourceKind'];
    final state = value['state'];
    final sourceFileName = value['sourceFileName'];
    final ledgerFileName = value['ledgerFileName'];
    final sourceBytes = value['sourceBytes'];
    final sourceFingerprint = value['sourceFingerprint'];
    final result = value['result'];
    final platformCalls = value['platformCalls'];
    final platformSemantic = value['platformSemantic'];
    final pendingObservationMs = value['pendingObservationMs'];
    final archiveSha = value['archiveSha256'];
    final sourceSha = value['sourceSha256'];
    final ledgerSha = value['ledgerSha256'];
    final expectedKind =
        command.cut == 'allocated' ||
            command.cut == 'sourceVerified' ||
            command.cut == 'handedOffBeforePlatform'
        ? ShareSourceKind.rawTranscript
        : ShareSourceKind.pidCsv;
    final expectedState =
        command.cut == 'allocated' || command.cut == 'sourceVerified'
        ? ShareLeaseState.allocated
        : ShareLeaseState.handedOffLease;
    final expectedPlatformCalls = switch (command.cut) {
      'platformInvoked' ||
      'pendingResult' ||
      'neverResult' ||
      'realPluginMirror' => 1,
      _ => 0,
    };
    final expectedPlatformSemantic = switch (command.cut) {
      'platformInvoked' => 'invokedBeforeAwait',
      'pendingResult' => 'completablePending',
      'neverResult' => 'nonCompletablePending',
      'realPluginMirror' => 'realPluginInvoked',
      _ => 'notInvoked',
    };
    final minimumObservationMs = switch (command.cut) {
      'pendingResult' => 2000,
      'neverResult' => 5000,
      _ => 0,
    };
    if (sourceKind is! String ||
        sourceKind != expectedKind.name ||
        state is! String ||
        state != expectedState.name ||
        sourceFileName is! String ||
        sourceFileName != '${command.id}.${expectedKind.extension}.share' ||
        ledgerFileName is! String ||
        ledgerFileName != '${command.id}.lease.json' ||
        sourceBytes is! int ||
        sourceBytes < 0 ||
        sourceBytes > ShareLeaseRecord.maxSourceBytes ||
        sourceFingerprint is! String ||
        !RegExp(r'^fnv1a64:[0-9a-f]{16}$').hasMatch(sourceFingerprint) ||
        result !=
            (expectedState == ShareLeaseState.handedOffLease
                ? 'pending'
                : null) ||
        platformCalls is! int ||
        platformCalls != expectedPlatformCalls ||
        platformSemantic is! String ||
        platformSemantic != expectedPlatformSemantic ||
        pendingObservationMs is! int ||
        pendingObservationMs < minimumObservationMs ||
        (minimumObservationMs == 0 && pendingObservationMs != 0) ||
        archiveSha is! String ||
        !_sha256.hasMatch(archiveSha) ||
        sourceSha is! String ||
        !_sha256.hasMatch(sourceSha) ||
        ledgerSha is! String ||
        !_sha256.hasMatch(ledgerSha)) {
      throw const FormatException('invalid Gate C restore manifest fields');
    }
    return _RestoreManifest(
      id: command.id,
      sourceKind: sourceKind,
      state: state,
      sourceFileName: sourceFileName,
      ledgerFileName: ledgerFileName,
      sourceBytes: sourceBytes,
      sourceFingerprint: sourceFingerprint,
      result: result as String?,
      platformCalls: platformCalls,
      platformSemantic: platformSemantic,
      pendingObservationMs: pendingObservationMs,
    );
  }
}

@visibleForTesting
void validateGateCRestoreManifestForTest({
  required Object? value,
  required String runToken,
  required String cut,
}) {
  final id = _Command._ids[cut];
  if (id == null) throw const FormatException('invalid Gate C test cut');
  _RestoreManifest.parse(value, _Command(runToken, 'recover', cut, id));
}

final class _Command {
  const _Command(this.runToken, this.phase, this.cut, this.id);
  final String runToken;
  final String phase;
  final String cut;
  final String id;

  static const _seedCuts = {
    'allocated',
    'sourceVerified',
    'handedOffBeforePlatform',
    'platformInvoked',
    'pendingResult',
    'neverResult',
  };
  static const _ids = {
    'allocated': '11000000000000000000000000000001',
    'sourceVerified': '22000000000000000000000000000002',
    'handedOffBeforePlatform': '33000000000000000000000000000003',
    'platformInvoked': '44000000000000000000000000000004',
    'pendingResult': '55000000000000000000000000000005',
    'neverResult': '66000000000000000000000000000006',
    'realPluginMirror': '77000000000000000000000000000007',
  };

  factory _Command.parse(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.keys.toSet().difference({
          'version',
          'runToken',
          'phase',
          'cut',
        }).isNotEmpty ||
        value.keys.length != 4 ||
        value['version'] != 1) {
      throw const FormatException('invalid Gate C command schema');
    }
    final token = value['runToken'];
    final phase = value['phase'];
    final cut = value['cut'];
    if (token is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(token)) {
      throw const FormatException('invalid Gate C token');
    }
    if (phase is! String || cut is! String) {
      throw const FormatException('invalid Gate C phase/cut');
    }
    final valid = switch (phase) {
      'seed' => _seedCuts.contains(cut),
      'recover' => _seedCuts.contains(cut) || cut == 'realPluginMirror',
      'realPluginMirror' => cut == 'realPluginMirror',
      _ => false,
    };
    if (!valid) throw const FormatException('invalid Gate C phase/cut pair');
    return _Command(token, phase, cut, _ids[cut]!);
  }
}

final class _Paths {
  const _Paths({required this.control, required this.shares});
  final Directory control;
  final Directory shares;
}

abstract interface class _ObservedPlatform implements AppSharePlatform {
  Completer<void> get invoked;
  int get calls;
  bool get resultCompleted;
  int get pendingObservationMs;
}

final class _CompletablePlatform implements _ObservedPlatform {
  @override
  final invoked = Completer<void>();
  final result = Completer<AppShareResult>();
  final _pending = Stopwatch();
  @override
  int calls = 0;
  @override
  bool get resultCompleted => result.isCompleted;
  @override
  int get pendingObservationMs => _pending.elapsedMilliseconds;
  @override
  Future<AppShareResult> share(AppSharePlatformRequest request) {
    calls++;
    _pending.start();
    if (!invoked.isCompleted) invoked.complete();
    return result.future;
  }
}

final class _NeverPlatform implements _ObservedPlatform {
  @override
  final invoked = Completer<void>();
  final _pending = Stopwatch();
  @override
  int calls = 0;
  @override
  bool get resultCompleted => false;
  @override
  int get pendingObservationMs => _pending.elapsedMilliseconds;
  @override
  Future<AppShareResult> share(AppSharePlatformRequest request) {
    calls++;
    _pending.start();
    if (!invoked.isCompleted) invoked.complete();
    return Completer<AppShareResult>().future;
  }
}

final class _CountingPlatform implements AppSharePlatform {
  _CountingPlatform(this.delegate);
  final AppSharePlatform delegate;
  int calls = 0;
  @override
  Future<AppShareResult> share(AppSharePlatformRequest request) {
    calls++;
    return delegate.share(request);
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
