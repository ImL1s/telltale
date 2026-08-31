/// Attribution-safe Android process-memory target.
///
/// `setup` creates fixtures in a disposable process. `measure` launches a
/// fresh process and labels every operation with timestamped BEGIN/END markers.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:torque_obd/core/hash/fnv1a64.dart';
import 'package:torque_obd/core/share/app_share_platform_bridge.dart';
import 'package:torque_obd/core/share/share_lease_ledger.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/transcript.dart';
import 'package:torque_obd/obd/transcript_store.dart';
import 'package:torque_obd/state/app_share_coordinator.dart';
import 'package:torque_obd/state/app_share_entry_controller.dart';
import 'package:torque_obd/state/artifact_operation_gate.dart';
import 'package:torque_obd/state/telemetry_sessions.dart';
import 'package:torque_obd/telemetry/session/telemetry_recorder.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_exporter.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_reader.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_store.dart';

import 'rig_support.dart';

const _mib = 1024 * 1024;
const _sessionId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('telemetry memory rig measures host fixtures', (tester) async {
    await _measure(tester);
  });
}

Future<void> _measure(WidgetTester tester) async {
  await startRigAppPreservingState(tester);
  final documents = await getApplicationDocumentsDirectory();
  final scratch = Directory('${documents.path}/telltale-memory-rig');
  final importComplete = File('${scratch.path}/.host-import-complete');
  debugPrint('TELLTALE_MEMORY_FIXTURE_IMPORT_READY epochUs=${_epochUs()}');
  final imported = await pumpUntil(
    tester,
    importComplete.existsSync,
    timeout: const Duration(seconds: 60),
    step: const Duration(milliseconds: 200),
  );
  expect(
    imported,
    isTrue,
    reason: 'host fixture import did not complete before measurement',
  );
  debugPrint('TELLTALE_MEMORY_FIXTURE_IMPORT_COMPLETE epochUs=${_epochUs()}');
  final session = File(
    '${documents.path}/telltale-telemetry/$_sessionId.ndjson',
  );
  expect(await scratch.exists(), isTrue);
  expect(await session.exists(), isTrue);

  await _stage('baseline', () => tester.pump(const Duration(seconds: 3)));
  await _stage('index', () => _index(scratch));
  await _stage('replay', () => _replay(documents));
  await _stage('directCsv', () => _directCsv(session));

  final actionPlatform = _MeasuredPlatform();
  const actionPolicy = _Policy.disconnected();
  var actionId = 0;
  final actionRoot = Directory('${scratch.path}/action-shares')..createSync();
  final actionCoordinator = AppShareCoordinator(
    rootDirectory: () async => actionRoot,
    policy: actionPolicy,
    artifactGate: ArtifactOperationGate(),
    platform: actionPlatform,
    idSource: () => (++actionId).toRadixString(16).padLeft(32, '0'),
    nowUtc: () => DateTime.now().toUtc(),
    availableBytes: (_) async => 128 * _mib,
  );
  expect(
    await actionCoordinator.initialize(),
    AppShareInitializationOutcome.ready,
  );
  final actions = TelemetrySessionActions(
    documentsDirectory: () async => documents,
    store: TelemetrySessionStore(documentsDirectory: () async => documents),
    shareEntryController: AppShareEntryController(actionCoordinator),
    artifactGate: ArtifactOperationGate(),
    sharePolicy: actionPolicy,
    readRecorderPhase: () => TelemetryRecorderPhase.idle,
  );
  await _stage('share_telemetryCsv', () async {
    final result = await actions.export(_sessionId, TelemetryExportFormat.csv);
    expect(result.isSuccess, isTrue);
  });
  await _stage('share_telemetryJson', () async {
    final result = await actions.export(_sessionId, TelemetryExportFormat.json);
    expect(result.isSuccess, isTrue);
  });
  expect(actionPlatform.extensions, ['csv', 'json']);
  debugPrint(
    'TELLTALE_MEMORY_PRODUCTION_EXPORT extensions='
    '${actionPlatform.extensions.join(',')}',
  );
  await _proveLeases(actionRoot);

  await _stage('share_rawTranscript', () => _rawTranscriptShare(scratch));
  await _stage(
    'share_recoveredTranscript',
    () => _recoveredTranscriptShare(scratch, documents),
  );
  await _stage('share_pidCsv', () => _pidCsvShare(scratch));
  // A canonical session is capped at 25 MiB, so its JSON export cannot reach
  // the independent 32 MiB coordinator limit. This separately named probe is
  // intentionally not presented as a TelemetrySessionActions export.
  await _stage('coordinatorExact32MiB', () => _exactLimit(scratch));
  await _stage('connectedFresh', () => _connectedExact(scratch, stale: false));
  await _stage('connectedStale', () => _connectedExact(scratch, stale: true));
  await _stage('allocatedCut', () => _allocatedCut(scratch));
  await _stage('crossFeatureBusy', () => _crossFeatureBusy(scratch));
  await _stage('cleanupOpportunity', () => _cleanupOpportunity(scratch));
  await _snapshotPluginMirror(scratch);
  await _stage('settled', () => tester.pump(const Duration(seconds: 3)));

  debugPrint('TELLTALE_MEMORY_RESIDUE_READY epochUs=${_epochUs()}');
  await tester.pump(const Duration(seconds: 8));
  debugPrint('TELLTALE_MEMORY_MEASURE_COMPLETE epochUs=${_epochUs()}');
}

Future<T> _stage<T>(String name, Future<T> Function() operation) async {
  debugPrint(
    'TELLTALE_MEMORY_STAGE stage=$name edge=BEGIN epochUs=${_epochUs()}',
  );
  final stopwatch = Stopwatch()..start();
  try {
    final result = await operation();
    // Leave enough time for three attributable samples even when consecutive
    // host samples reach the analyzer's one-second maximum gap. This is a
    // passive attribution window: it neither allocates fixtures nor requests
    // garbage collection.
    final remaining = const Duration(milliseconds: 3000) - stopwatch.elapsed;
    if (remaining > Duration.zero) await Future<void>.delayed(remaining);
    return result;
  } finally {
    debugPrint(
      'TELLTALE_MEMORY_STAGE stage=$name edge=END epochUs=${_epochUs()}',
    );
  }
}

int _epochUs() => DateTime.now().toUtc().microsecondsSinceEpoch;

Future<void> _index(Directory scratch) async {
  final library = await TelemetrySessionLibraryService(
    documentsDirectory: () async =>
        Directory('${scratch.path}/index-documents'),
  ).load();
  expect(library.groupCount, 20);
  expect(library.recognizedBytes, 100 * _mib);
  expect(library.encodedProjectionBytes, lessThanOrEqualTo(80 * 1024));
  debugPrint(
    'TELLTALE_MEMORY_INDEX bytes=${library.recognizedBytes} '
    'projection=${library.encodedProjectionBytes}',
  );
}

Future<void> _replay(Directory documents) async {
  final result = await TelemetrySessionLibraryService(
    documentsDirectory: () async => documents,
  ).replay(_sessionId);
  expect(result.replay, isNotNull);
  expect(result.replay!.lanes, hasLength(4));
  expect(
    result.replay!.lanes.every((lane) => lane.primitives.length <= 1200),
    isTrue,
  );
  debugPrint('TELLTALE_MEMORY_REPLAY lanes=${result.replay!.lanes.length}');
}

Future<void> _directCsv(File session) async {
  var bytes = 0;
  var maximumBuffers = 0;
  final exporter = TelemetrySessionExporter(
    onBufferUsage: (usage) {
      if (usage.totalBytes > maximumBuffers) maximumBuffers = usage.totalBytes;
    },
  );
  await for (final chunk in exporter.csvStream(
    FileTelemetryChunkSource(session),
  )) {
    bytes += chunk.length;
  }
  expect(bytes, greaterThan(0));
  expect(maximumBuffers, lessThanOrEqualTo(192 * 1024));
  debugPrint(
    'TELLTALE_MEMORY_DIRECT_CSV bytes=$bytes maxBuffers=$maximumBuffers',
  );
}

Future<void> _rawTranscriptShare(Directory scratch) async {
  final transcript = ObdTranscript();
  final at = DateTime.utc(2026, 8, 30);
  for (var index = 0; index < 4000; index++) {
    transcript.recordRead([
      0x34,
      0x31,
      0x20,
      index & 0xff,
      0x0d,
      0x3e,
    ], at.add(Duration(milliseconds: index)));
  }
  await _realSourceShare(
    scratch: scratch,
    kind: ShareSourceKind.rawTranscript,
    share: (controller) => controller.shareRawTranscript(
      transcript: transcript,
      header: 'Memory rig transcript\n',
      withHex: true,
      subjectAt: at,
    ),
  );
}

Future<void> _recoveredTranscriptShare(
  Directory scratch,
  Directory documents,
) async {
  final store = TranscriptStore(directory: () async => documents);
  final expected = await store.load();
  expect(expected, isNotNull);
  await _realSourceShare(
    scratch: scratch,
    kind: ShareSourceKind.recoveredTranscript,
    share: (controller) => controller.shareRecoveredTranscript(
      store: store,
      expected: expected!,
    ),
  );
}

Future<void> _pidCsvShare(Directory scratch) => _realSourceShare(
  scratch: scratch,
  kind: ShareSourceKind.pidCsv,
  share: (controller) => controller.sharePidCsv(pids: PidLibrary.all),
);

Future<void> _realSourceShare({
  required Directory scratch,
  required ShareSourceKind kind,
  required Future<AppShareOutcome> Function(AppShareEntryController) share,
}) async {
  final platform = _MeasuredPlatform();
  final root = Directory('${scratch.path}/production-${kind.name}')
    ..createSync();
  final coordinator = await _initializedCoordinator(
    root,
    platform,
    const _Policy.disconnected(),
    _idFor(kind.index + 5),
  );
  final outcome = await share(AppShareEntryController(coordinator));
  expect(outcome.result, AppShareResult.selected);
  expect(platform.calls, 1);
  await _proveLeases(root);
  debugPrint('TELLTALE_MEMORY_PRODUCTION_SHARE kind=${kind.name}');
}

Future<void> _exactLimit(Directory scratch) async {
  final platform = _MeasuredPlatform(delay: const Duration(milliseconds: 2200));
  final stopwatch = Stopwatch()..start();
  final root = Directory('${scratch.path}/exact-limit')..createSync();
  final coordinator = await _initializedCoordinator(
    root,
    platform,
    const _Policy.disconnected(),
    _idFor(13),
  );
  final outcome = await coordinator.share(
    AppShareRequest(
      sourceKind: ShareSourceKind.telemetryJson,
      subject: 'coordinator exact limit',
      knownByteLength: 32 * _mib,
      streamFactory: () => _slowChunks(32 * _mib),
    ),
  );
  stopwatch.stop();
  expect(outcome.result, AppShareResult.selected);
  expect(stopwatch.elapsed, greaterThan(const Duration(seconds: 2)));
  await _proveLeases(root);
  debugPrint(
    'TELLTALE_MEMORY_EXACT32 elapsedMs=${stopwatch.elapsedMilliseconds}',
  );
}

Future<void> _connectedExact(Directory scratch, {required bool stale}) async {
  final platform = _MeasuredPlatform();
  final policy = _TimedConnectedPolicy();
  Timer? renewal;
  if (!stale) {
    renewal = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => policy.renewStoppedReading(),
    );
  }
  final root = Directory('${scratch.path}/connected-$stale')..createSync();
  final coordinator = await _initializedCoordinator(
    root,
    platform,
    policy,
    _idFor(stale ? 15 : 14),
  );
  final outcome = await coordinator.share(
    AppShareRequest(
      sourceKind: ShareSourceKind.pidCsv,
      subject: 'connected-$stale',
      knownByteLength: 32 * _mib,
      streamFactory: () => _slowChunks(32 * _mib),
    ),
  );
  renewal?.cancel();
  if (stale) {
    expect(outcome.error, ShareError.shareSafetyChangedSpeedUnknown);
    expect(platform.calls, 0);
  } else {
    expect(outcome.result, AppShareResult.selected);
    expect(platform.calls, 1);
    await _proveLeases(root);
  }
  debugPrint(
    'TELLTALE_MEMORY_CONNECTED stale=$stale result=${outcome.result?.name} '
    'platformCalls=${platform.calls} validations=${policy.validations} '
    'renewals=${policy.renewals}',
  );
}

Future<void> _crossFeatureBusy(Directory scratch) async {
  final root = Directory('${scratch.path}/never-result')..createSync();
  final platform = _NeverPlatform();
  final gate = ArtifactOperationGate();
  final coordinator = AppShareCoordinator(
    rootDirectory: () async => root,
    policy: const _Policy.disconnected(),
    artifactGate: gate,
    platform: platform,
    idSource: () => _idFor(20),
    nowUtc: () => DateTime.now().toUtc(),
    availableBytes: (_) async => 128 * _mib,
  );
  expect(await coordinator.initialize(), AppShareInitializationOutcome.ready);
  unawaited(
    coordinator.share(
      AppShareRequest(
        sourceKind: ShareSourceKind.pidCsv,
        subject: 'never result seed',
        knownByteLength: 64 * 1024,
        streamFactory: () => _chunks(64 * 1024),
      ),
    ),
  );
  await platform.invoked.future.timeout(const Duration(seconds: 10));
  final second = await coordinator.share(
    AppShareRequest(
      sourceKind: ShareSourceKind.rawTranscript,
      subject: 'must be busy',
      knownByteLength: 1,
      streamFactory: () => _chunks(1),
    ),
  );
  expect(second.error, ShareError.shareBusy);
  final crossFeature = gate.tryAcquire(
    'cross-feature-delete',
    ArtifactOperation.delete,
  );
  expect(crossFeature.token, isNull);
  await _proveLeases(root, expectedResult: 'pending');
  final reconstructed = AppShareCoordinator(
    rootDirectory: () async => root,
    policy: const _Policy.disconnected(),
    artifactGate: ArtifactOperationGate(),
    platform: _MeasuredPlatform(),
    idSource: () => _idFor(23),
    nowUtc: () => DateTime.now().toUtc(),
    availableBytes: (_) async => 128 * _mib,
  );
  expect(await reconstructed.initialize(), AppShareInitializationOutcome.ready);
  await _proveLeases(root, expectedResult: 'pending');
  debugPrint(
    'TELLTALE_MEMORY_RECONSTRUCTION scope=freshCoordinator '
    'state=handedOffLease result=pending',
  );
  for (final cut in const [
    'handedOffLease',
    'postPlatform',
    'pendingResult',
    'neverResult',
  ]) {
    debugPrint(
      'TELLTALE_MEMORY_CRASH_CUT_READY cut=$cut epochUs=${_epochUs()}',
    );
  }
  debugPrint(
    'TELLTALE_MEMORY_BUSY share=${second.error?.name} '
    'crossFeature=${crossFeature.failure?.name}',
  );
}

Future<void> _allocatedCut(Directory scratch) async {
  final root = Directory('${scratch.path}/allocated-cut')..createSync();
  final gate = ArtifactOperationGate();
  final coordinator = AppShareCoordinator(
    rootDirectory: () async => root,
    policy: const _Policy.disconnected(),
    artifactGate: gate,
    platform: _MeasuredPlatform(),
    idSource: () => _idFor(19),
    nowUtc: () => DateTime.now().toUtc(),
    availableBytes: (_) async => 128 * _mib,
  );
  expect(await coordinator.initialize(), AppShareInitializationOutcome.ready);
  final neverSource = StreamController<List<int>>();
  unawaited(
    coordinator.share(
      AppShareRequest(
        sourceKind: ShareSourceKind.rawTranscript,
        subject: 'allocated crash cut',
        knownByteLength: 64 * 1024,
        streamFactory: () => neverSource.stream,
      ),
    ),
  );
  final ledger = ShareLeaseLedger(root);
  ShareLeaseRecord? record;
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    record = await ledger.read(_idFor(19));
    if (record?.state == ShareLeaseState.allocated) break;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  expect(record?.state, ShareLeaseState.allocated);
  expect(File('${root.path}/${record!.sourceFileName}').existsSync(), isTrue);
  expect(
    (await coordinator.share(
      AppShareRequest(
        sourceKind: ShareSourceKind.pidCsv,
        subject: 'allocated cut must stay busy',
        knownByteLength: 1,
        streamFactory: () => _chunks(1),
      ),
    )).error,
    ShareError.shareBusy,
  );
  expect(
    gate.tryAcquire('allocated-cross-feature', ArtifactOperation.delete).token,
    isNull,
  );
  debugPrint(
    'TELLTALE_MEMORY_CRASH_CUT_READY cut=allocated epochUs=${_epochUs()}',
  );
}

Future<void> _cleanupOpportunity(Directory scratch) async {
  final root = Directory('${scratch.path}/cleanup-opportunity')..createSync();
  var now = DateTime.utc(2026, 8, 30);
  final coordinator = AppShareCoordinator(
    rootDirectory: () async => root,
    policy: const _Policy.disconnected(),
    artifactGate: ArtifactOperationGate(),
    platform: _MeasuredPlatform(),
    idSource: () => _idFor(21),
    nowUtc: () => now,
    availableBytes: (_) async => 128 * _mib,
  );
  expect(await coordinator.initialize(), AppShareInitializationOutcome.ready);
  expect(
    (await coordinator.share(
      AppShareRequest(
        sourceKind: ShareSourceKind.rawTranscript,
        subject: 'cleanup opportunity',
        knownByteLength: 64 * 1024,
        streamFactory: () => _chunks(64 * 1024),
      ),
    )).result,
    AppShareResult.selected,
  );
  final before = await _regularFileNames(root);
  now = now.add(const Duration(minutes: 16));
  await Future<void>.delayed(const Duration(milliseconds: 250));
  expect(await _regularFileNames(root), before);
  debugPrint('TELLTALE_MEMORY_CLOCK_ONLY retained=${before.length}');
  final freshCoordinator = AppShareCoordinator(
    rootDirectory: () async => root,
    policy: const _Policy.disconnected(),
    artifactGate: ArtifactOperationGate(),
    platform: _MeasuredPlatform(),
    idSource: () => _idFor(22),
    nowUtc: () => now,
    availableBytes: (_) async => 128 * _mib,
  );
  expect(
    await freshCoordinator.initialize(),
    AppShareInitializationOutcome.ready,
  );
  expect(await _regularFileNames(root), isEmpty);
  debugPrint('TELLTALE_MEMORY_NEXT_OPPORTUNITY_CLEANUP remaining=0');
}

Future<void> _snapshotPluginMirror(Directory scratch) async {
  final cache = await getTemporaryDirectory();
  final mirror = Directory('${cache.path}/share_plus');
  var files = 0;
  var bytes = 0;
  if (await mirror.exists()) {
    await for (final entity in mirror.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) {
        files++;
        bytes += await entity.length();
      }
    }
  }
  debugPrint(
    'TELLTALE_MEMORY_PLUGIN_MIRROR path=${mirror.path} files=$files bytes=$bytes '
    'ownership=observedOnly',
  );
}

Future<AppShareCoordinator> _initializedCoordinator(
  Directory root,
  _MeasuredPlatform platform,
  AppSharePolicy policy,
  String id,
) async {
  final coordinator = AppShareCoordinator(
    rootDirectory: () async => root,
    policy: policy,
    artifactGate: ArtifactOperationGate(),
    platform: platform,
    idSource: () => id,
    nowUtc: () => DateTime.now().toUtc(),
    availableBytes: (_) async => 128 * _mib,
  );
  expect(await coordinator.initialize(), AppShareInitializationOutcome.ready);
  return coordinator;
}

Future<void> _proveLeases(Directory root, {String? expectedResult}) async {
  final ledgers = await root
      .list(followLinks: false)
      .where((entity) => entity is File && entity.path.endsWith('.lease.json'))
      .cast<File>()
      .toList();
  expect(ledgers, isNotEmpty);
  var sourceBytes = 0;
  var ledgerBytes = 0;
  for (final ledgerFile in ledgers) {
    final ledgerLength = await ledgerFile.length();
    expect(ledgerLength, lessThanOrEqualTo(4096));
    ledgerBytes += ledgerLength;
    final name = ledgerFile.uri.pathSegments.last;
    final id = name.substring(0, name.length - '.lease.json'.length);
    final record = await ShareLeaseLedger(root).read(id);
    expect(record, isNotNull);
    expect(record!.state, ShareLeaseState.handedOffLease);
    if (expectedResult != null) expect(record.result, expectedResult);
    final source = File('${root.path}/${record.sourceFileName}');
    final hash = Fnv1a64();
    var bytes = 0;
    await for (final chunk in source.openRead()) {
      bytes += chunk.length;
      hash.add(chunk);
    }
    expect(bytes, record.bytes);
    expect(hash.fingerprint, record.fingerprint);
    sourceBytes += bytes;
    debugPrint(
      'TELLTALE_MEMORY_FINGERPRINT kind=${record.sourceKind.name} id=$id '
      'bytes=$bytes fingerprint=${hash.fingerprint} result=${record.result} '
      'ledgerBytes=$ledgerLength',
    );
  }
  final temps = await root
      .list(followLinks: false)
      .where((entity) => entity is File && entity.path.endsWith('.tmp'))
      .cast<File>()
      .toList();
  var tempBytes = 0;
  for (final temp in temps) {
    tempBytes += await temp.length();
  }
  expect(ledgers.length, lessThanOrEqualTo(2));
  expect(sourceBytes, lessThanOrEqualTo(64 * _mib));
  expect(ledgerBytes, lessThanOrEqualTo(2 * 4096));
  debugPrint(
    'TELLTALE_MEMORY_APP_STAGING root=${root.uri.pathSegments.last} '
    'sources=${ledgers.length} sourceBytes=$sourceBytes '
    'ledgers=${ledgers.length} ledgerBytes=$ledgerBytes '
    'temps=${temps.length} tempBytes=$tempBytes',
  );
}

Future<List<String>> _regularFileNames(Directory root) async {
  final names = <String>[];
  await for (final entity in root.list(followLinks: false)) {
    if (entity is File) names.add(entity.uri.pathSegments.last);
  }
  names.sort();
  return names;
}

String _idFor(int value) => value.toRadixString(16).padLeft(32, '0');

Stream<List<int>> _chunks(int bytes) async* {
  final chunk = Uint8List(64 * 1024);
  var remaining = bytes;
  while (remaining > 0) {
    final count = remaining < chunk.length ? remaining : chunk.length;
    yield count == chunk.length
        ? chunk
        : Uint8List.sublistView(chunk, 0, count);
    remaining -= count;
  }
}

Stream<List<int>> _slowChunks(int bytes) async* {
  await for (final chunk in _chunks(bytes)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    yield chunk;
  }
}

final class _MeasuredPlatform implements AppSharePlatform {
  _MeasuredPlatform({this.delay = Duration.zero});
  final Duration delay;
  final List<String> extensions = [];
  int calls = 0;

  @override
  Future<AppShareResult> share(AppSharePlatformRequest request) async {
    calls++;
    expect(await File(request.path).length(), greaterThan(0));
    extensions.add(request.fileName.split('.').last);
    if (delay != Duration.zero) await Future<void>.delayed(delay);
    return AppShareResult.selected;
  }
}

final class _NeverPlatform implements AppSharePlatform {
  final Completer<void> invoked = Completer<void>();

  @override
  Future<AppShareResult> share(AppSharePlatformRequest request) {
    expect(File(request.path).existsSync(), isTrue);
    if (!invoked.isCompleted) invoked.complete();
    return Completer<AppShareResult>().future;
  }
}

final class _TimedConnectedPolicy implements AppSharePolicy {
  DateTime _lastStoppedReading = DateTime.now().toUtc();
  int validations = 0;
  int renewals = 0;

  void renewStoppedReading() {
    renewals++;
    _lastStoppedReading = DateTime.now().toUtc();
  }

  @override
  SharePreparationPermit freeze() => const SharePreparationPermit(
    recorderEpoch: 1,
    foregroundEpoch: 1,
    connectionEpoch: 1,
    safetyEpoch: 1,
    connectionClass: ShareConnectionClass.connected,
  );

  @override
  SharePermitValidation validate(SharePreparationPermit permit) {
    validations++;
    final age = DateTime.now().toUtc().difference(_lastStoppedReading);
    return age <= const Duration(milliseconds: 300)
        ? const SharePermitValidation.valid()
        : const SharePermitValidation.invalid(SharePermitCause.speedUnknown);
  }
}

final class _Policy implements AppSharePolicy {
  const _Policy.disconnected();

  @override
  SharePreparationPermit? freeze() => const SharePreparationPermit(
    recorderEpoch: 1,
    foregroundEpoch: 1,
    connectionEpoch: 1,
    safetyEpoch: 1,
    connectionClass: ShareConnectionClass.disconnected,
  );

  @override
  SharePermitValidation validate(SharePreparationPermit permit) {
    return const SharePermitValidation.valid();
  }
}
