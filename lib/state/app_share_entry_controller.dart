library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show Rect;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/share/share_lease_ledger.dart';
import '../obd/pid/pid.dart';
import '../obd/pid/pid_csv.dart';
import '../obd/transcript.dart';
import '../obd/transcript_store.dart';
import '../telemetry/session/telemetry_session_exporter.dart';
import '../telemetry/session/telemetry_session_reader.dart';
import 'app_share_coordinator.dart';

/// The only production facade that turns domain data into a Share request.
///
/// Inputs that callers can mutate are frozen synchronously, before coordinator
/// admission. Descriptor-backed sources remain lazy so no file handle is open
/// while another artifact operation owns the global gate.
final class AppShareEntryController {
  const AppShareEntryController(this._coordinator);

  final AppShareCoordinator _coordinator;

  Future<AppShareOutcome> shareTelemetryCsv({
    required Directory documents,
    required String sessionId,
    Rect? sharePositionOrigin,
  }) => _shareTelemetry(
    documents: documents,
    sessionId: sessionId,
    kind: ShareSourceKind.telemetryCsv,
    sharePositionOrigin: sharePositionOrigin,
  );

  Future<AppShareOutcome> shareTelemetryJson({
    required Directory documents,
    required String sessionId,
    Rect? sharePositionOrigin,
  }) => _shareTelemetry(
    documents: documents,
    sessionId: sessionId,
    kind: ShareSourceKind.telemetryJson,
    sharePositionOrigin: sharePositionOrigin,
  );

  Future<AppShareOutcome> _shareTelemetry({
    required Directory documents,
    required String sessionId,
    required ShareSourceKind kind,
    Rect? sharePositionOrigin,
  }) {
    if (!TelemetrySessionReader.isOpaqueId(sessionId)) {
      return Future.value(
        const AppShareOutcome(error: ShareError.storageFailure),
      );
    }
    final path = '${documents.path}/telltale-telemetry/$sessionId.ndjson';
    return _coordinator.share(
      AppShareRequest(
        sourceKind: kind,
        subject: '本機 OBD 紀錄 $sessionId',
        sharePositionOrigin: sharePositionOrigin,
        streamFactory: () => _offIsolateExportStream(
          path,
          json: kind == ShareSourceKind.telemetryJson,
        ),
      ),
    );
  }

  Future<AppShareOutcome> shareRawTranscript({
    required ObdTranscript transcript,
    required String header,
    required bool withHex,
    required DateTime subjectAt,
    Rect? sharePositionOrigin,
  }) {
    final frozen = transcript.frozenCopy();
    final at = subjectAt.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    final stamp =
        '${at.year}${two(at.month)}${two(at.day)}-'
        '${two(at.hour)}${two(at.minute)}${two(at.second)}';
    return _coordinator.share(
      AppShareRequest(
        sourceKind: ShareSourceKind.rawTranscript,
        subject: 'Telltale 傳輸紀錄 $stamp',
        sharePositionOrigin: sharePositionOrigin,
        streamFactory: () =>
            frozen.streamEncoded(header: header, withHex: withHex),
      ),
    );
  }

  Future<AppShareOutcome> shareRecoveredTranscript({
    required TranscriptStore store,
    required StoredTranscript expected,
    Rect? sharePositionOrigin,
  }) => _coordinator.share(
    AppShareRequest.lazy(
      sourceKind: ShareSourceKind.recoveredTranscript,
      subject: 'Telltale 傳輸紀錄（上一次連線）',
      sharePositionOrigin: sharePositionOrigin,
      prepareSource: () async {
        final descriptor = await store.openStreaming(expected: expected);
        if (descriptor == null) return null;
        return PreparedAppShareSource(
          streamFactory: descriptor.open,
          knownByteLength: descriptor.expectedByteLength,
          dispose: descriptor.close,
        );
      },
    ),
  );

  Future<AppShareOutcome> sharePidCsv({
    required Iterable<Pid> pids,
    Rect? sharePositionOrigin,
  }) {
    final frozen = List<Pid>.unmodifiable(pids);
    return _coordinator.share(
      AppShareRequest(
        sourceKind: ShareSourceKind.pidCsv,
        subject: 'Telltale 自訂 PID 定義',
        sharePositionOrigin: sharePositionOrigin,
        streamFactory: () => PidCsv.stream(frozen),
      ),
    );
  }
}

final appShareEntryControllerProvider = Provider<AppShareEntryController>(
  (ref) => AppShareEntryController(ref.watch(appShareCoordinatorProvider)),
);

Stream<List<int>> _offIsolateExportStream(String path, {required bool json}) =>
    telemetryExportWorkerStream(path, json: json);

typedef TelemetryExportWorker = Future<void> Function(List<Object?> args);

/// Runs a telemetry export in a contained worker isolate.
///
/// The worker must acknowledge a terminal message before it may exit. This
/// makes an unexpected exit observable instead of leaving the receive stream
/// and the global artifact gate waiting forever. The optional worker and
/// timeouts keep the containment protocol independently testable.
Stream<List<int>> telemetryExportWorkerStream(
  String path, {
  required bool json,
  TelemetryExportWorker worker = _exportWorker,
  Duration gracefulExitTimeout = const Duration(seconds: 15),
  Duration forcedExitTimeout = const Duration(seconds: 5),
}) async* {
  final receive = ReceivePort();
  final exitPort = ReceivePort();
  final exited = Completer<void>();
  final events = StreamController<_ExportWorkerEvent>(sync: true);
  final receiveSubscription = receive.listen(
    (message) => events.add(_ExportWorkerMessage(message)),
    onDone: () =>
        events.add(const _ExportWorkerMessage(_workerMessagePortClosed)),
  );
  final exitSubscription = exitPort.listen((_) {
    if (!exited.isCompleted) exited.complete();
    events.add(const _ExportWorkerExited());
  });
  Isolate? isolate;
  SendPort? commands;
  var terminalReceived = false;
  final workerEvents = StreamIterator<_ExportWorkerEvent>(events.stream);
  try {
    isolate = await Isolate.spawn(
      worker,
      <Object?>[receive.sendPort, path, json],
      debugName: 'telemetry-export-worker',
      onExit: exitPort.sendPort,
    );
    while (true) {
      if (!await workerEvents.moveNext()) {
        throw const TelemetryExportException('workerProtocol');
      }
      final event = workerEvents.current;
      if (event is _ExportWorkerExited) {
        throw const TelemetryExportException('workerExitedPrematurely');
      }
      final message = (event as _ExportWorkerMessage).value;
      if (message is SendPort) {
        if (commands != null) {
          throw const TelemetryExportException('workerProtocol');
        }
        commands = message;
        commands.send('next');
      } else if (message is List<int>) {
        if (commands == null) {
          throw const TelemetryExportException('workerProtocol');
        }
        yield message;
        commands.send('next');
      } else if (message == 'done') {
        if (commands == null) {
          throw const TelemetryExportException('workerProtocol');
        }
        terminalReceived = true;
        commands.send('terminalAck');
        break;
      } else if (message is Map &&
          message['type'] == 'error' &&
          message['code'] is String) {
        if (commands == null) {
          throw const TelemetryExportException('workerProtocol');
        }
        terminalReceived = true;
        commands.send('terminalAck');
        throw TelemetryExportException(
          message['code']! as String,
          detail: message['detail'] as String?,
          remoteStack: message['stack'] as String?,
        );
      } else {
        throw const TelemetryExportException('workerProtocol');
      }
    }
  } finally {
    commands?.send(terminalReceived ? 'terminalAck' : 'cancel');
    try {
      await workerEvents.cancel();
      await receiveSubscription.cancel();
      receive.close();
      final worker = isolate;
      if (worker != null) {
        await _waitForExportWorkerExit(
          worker,
          exited.future,
          gracefulTimeout: gracefulExitTimeout,
          forcedTimeout: forcedExitTimeout,
        );
      }
    } finally {
      await exitSubscription.cancel();
      exitPort.close();
      await events.close();
    }
  }
}

Future<void> _waitForExportWorkerExit(
  Isolate isolate,
  Future<void> exited, {
  required Duration gracefulTimeout,
  required Duration forcedTimeout,
}) async {
  try {
    await exited.timeout(gracefulTimeout);
    return;
  } on TimeoutException {
    isolate.kill(priority: Isolate.immediate);
  }
  try {
    await exited.timeout(forcedTimeout);
  } on TimeoutException {
    throw const TelemetryExportException('workerExitTimeout');
  }
}

Future<void> _exportWorker(List<Object?> args) async {
  final output = args[0]! as SendPort;
  final path = args[1]! as String;
  final json = args[2]! as bool;
  final commands = ReceivePort();
  output.send(commands.sendPort);
  final exporter = TelemetrySessionExporter();
  final source = FileTelemetryChunkSource(File(path));
  final iterator = StreamIterator<List<int>>(
    json ? exporter.jsonStream(source) : exporter.csvStream(source),
  );
  final commandIterator = StreamIterator<Object?>(commands);
  try {
    while (await commandIterator.moveNext()) {
      final command = commandIterator.current;
      if (command == 'cancel') break;
      if (command != 'next') continue;
      if (await iterator.moveNext()) {
        output.send(iterator.current);
      } else {
        output.send('done');
        await _waitForWorkerRelease(commandIterator);
        break;
      }
    }
  } on Object catch (error, stackTrace) {
    output.send(<String, Object?>{
      'type': 'error',
      'code': error is TelemetryExportException ? error.code : 'workerFailure',
      'detail': '$error',
      'stack': '$stackTrace',
    });
    await _waitForWorkerRelease(commandIterator);
  } finally {
    await iterator.cancel();
    await commandIterator.cancel();
    commands.close();
  }
}

Future<void> _waitForWorkerRelease(StreamIterator<Object?> commands) async {
  while (await commands.moveNext()) {
    if (commands.current == 'terminalAck' || commands.current == 'cancel') {
      return;
    }
  }
}

sealed class _ExportWorkerEvent {
  const _ExportWorkerEvent();
}

final class _ExportWorkerMessage extends _ExportWorkerEvent {
  const _ExportWorkerMessage(this.value);

  final Object? value;
}

final class _ExportWorkerExited extends _ExportWorkerEvent {
  const _ExportWorkerExited();
}

const _workerMessagePortClosed = Object();
