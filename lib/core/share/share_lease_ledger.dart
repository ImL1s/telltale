library;

import 'dart:convert';
import 'dart:io';

enum ShareSourceKind {
  telemetryCsv('csv', 'text/csv'),
  telemetryJson('json', 'application/json'),
  rawTranscript('txt', 'text/plain'),
  recoveredTranscript('txt', 'text/plain'),
  pidCsv('csv', 'text/csv');

  const ShareSourceKind(this.extension, this.mimeType);
  final String extension;
  final String mimeType;
}

enum ShareLeaseState { allocated, handedOffLease }

class ShareLeaseCollisionException extends FileSystemException {
  const ShareLeaseCollisionException(super.message);
}

/// A file/stream handle could not be positively closed or cancelled.
///
/// Callers must retain their in-memory ownership tokens until a fresh process
/// reconstructs the durable directory. Treating this as an ordinary I/O error
/// could unlink an open file on Android/Linux and falsely claim containment.
class ShareResourceUncontainedException extends FileSystemException {
  const ShareResourceUncontainedException(super.message);
}

class ShareLeaseRecord {
  const ShareLeaseRecord({
    required this.id,
    required this.sourceKind,
    required this.state,
    required this.createdAtUtc,
    this.bytes,
    this.fingerprint,
    this.handedOffAtUtc,
    this.cleanupEligibleAtUtc,
    this.cleanupDueAtUtc,
    this.result,
    this.resultAtUtc,
  });

  factory ShareLeaseRecord.allocated({
    required String id,
    required ShareSourceKind sourceKind,
    required DateTime createdAtUtc,
  }) => ShareLeaseRecord(
    id: id,
    sourceKind: sourceKind,
    state: ShareLeaseState.allocated,
    createdAtUtc: createdAtUtc.toUtc(),
  );

  static const maxSourceBytes = 32 * 1024 * 1024;
  static final idPattern = RegExp(r'^[0-9a-f]{32}$');
  static final _fingerprintPattern = RegExp(r'^fnv1a64:[0-9a-f]{16}$');
  static const _terminalResults = {
    'selected',
    'dismissed',
    'unavailable',
    'failed',
    'notInvokedSafetyChanged.recorder',
    'notInvokedSafetyChanged.connection',
    'notInvokedSafetyChanged.moving',
    'notInvokedSafetyChanged.speedUnknown',
    'notInvokedSafetyChanged.foreground',
  };

  final String id;
  final ShareSourceKind sourceKind;
  final ShareLeaseState state;
  final DateTime createdAtUtc;
  final int? bytes;
  final String? fingerprint;
  final DateTime? handedOffAtUtc;
  final DateTime? cleanupEligibleAtUtc;
  final DateTime? cleanupDueAtUtc;
  final String? result;
  final DateTime? resultAtUtc;

  String get sourceFileName => '$id.${sourceKind.extension}.share';
  String get ledgerFileName => '$id.lease.json';

  ShareLeaseRecord handedOff({
    required int bytes,
    required String fingerprint,
    required DateTime atUtc,
  }) {
    final at = atUtc.toUtc();
    return ShareLeaseRecord(
      id: id,
      sourceKind: sourceKind,
      state: ShareLeaseState.handedOffLease,
      createdAtUtc: createdAtUtc,
      bytes: bytes,
      fingerprint: fingerprint,
      handedOffAtUtc: at,
      cleanupEligibleAtUtc: at.add(const Duration(minutes: 15)),
      cleanupDueAtUtc: at.add(const Duration(hours: 24)),
      result: 'pending',
    );
  }

  ShareLeaseRecord withResult(String value, DateTime atUtc) {
    final handed = handedOffAtUtc?.toUtc();
    var resultAt = atUtc.toUtc();
    // Wall-clock steps backward while the share sheet is open must not make
    // resultAtUtc precede handedOffAtUtc — fromJson rejects that ordering and
    // the ledger transition would then fail after the UI already opened.
    if (handed != null && resultAt.isBefore(handed)) {
      resultAt = handed;
    }
    return ShareLeaseRecord(
      id: id,
      sourceKind: sourceKind,
      state: state,
      createdAtUtc: createdAtUtc,
      bytes: bytes,
      fingerprint: fingerprint,
      handedOffAtUtc: handedOffAtUtc,
      cleanupEligibleAtUtc: cleanupEligibleAtUtc,
      cleanupDueAtUtc: cleanupDueAtUtc,
      result: value,
      resultAtUtc: resultAt,
    );
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'id': id,
    'sourceKind': sourceKind.name,
    'extension': sourceKind.extension,
    'mimeType': sourceKind.mimeType,
    'state': state.name,
    'createdAtUtc': createdAtUtc.toUtc().toIso8601String(),
    if (bytes != null) 'bytes': bytes,
    if (fingerprint != null) 'fingerprint': fingerprint,
    if (handedOffAtUtc != null)
      'handedOffAtUtc': handedOffAtUtc!.toUtc().toIso8601String(),
    if (cleanupEligibleAtUtc != null)
      'cleanupEligibleAtUtc': cleanupEligibleAtUtc!.toUtc().toIso8601String(),
    if (cleanupDueAtUtc != null)
      'cleanupDueAtUtc': cleanupDueAtUtc!.toUtc().toIso8601String(),
    if (result != null) 'result': result,
    if (resultAtUtc != null)
      'resultAtUtc': resultAtUtc!.toUtc().toIso8601String(),
  };

  static ShareLeaseRecord? fromJson(Object? value) {
    if (value is! Map<String, dynamic> || value['version'] != 1) return null;
    final id = value['id'];
    if (id is! String || !idPattern.hasMatch(id)) return null;
    final kinds = ShareSourceKind.values.where(
      (e) => e.name == value['sourceKind'],
    );
    final states = ShareLeaseState.values.where(
      (e) => e.name == value['state'],
    );
    if (kinds.length != 1 || states.length != 1) return null;
    final kind = kinds.single;
    final state = states.single;
    if (value['extension'] != kind.extension ||
        value['mimeType'] != kind.mimeType) {
      return null;
    }
    DateTime? date(String key) {
      final raw = value[key];
      if (raw is! String) return null;
      final parsed = DateTime.tryParse(raw);
      if (parsed == null || !parsed.isUtc) return null;
      final utc = parsed.toUtc();
      return utc.toIso8601String() == raw ? utc : null;
    }

    final created = date('createdAtUtc');
    if (created == null) return null;
    const base = {
      'version',
      'id',
      'sourceKind',
      'extension',
      'mimeType',
      'state',
      'createdAtUtc',
    };
    if (state == ShareLeaseState.allocated) {
      if (!_sameKeys(value.keys, base)) return null;
      return ShareLeaseRecord(
        id: id,
        sourceKind: kind,
        state: state,
        createdAtUtc: created,
      );
    }
    const handedKeys = {
      ...base,
      'bytes',
      'fingerprint',
      'handedOffAtUtc',
      'cleanupEligibleAtUtc',
      'cleanupDueAtUtc',
      'result',
    };
    final result = value['result'];
    final terminal = result is String && _terminalResults.contains(result);
    if (!_sameKeys(
      value.keys,
      terminal ? {...handedKeys, 'resultAtUtc'} : handedKeys,
    )) {
      return null;
    }
    final bytes = value['bytes'];
    final fingerprint = value['fingerprint'];
    final handed = date('handedOffAtUtc');
    final eligible = date('cleanupEligibleAtUtc');
    final due = date('cleanupDueAtUtc');
    final resultAt = terminal ? date('resultAtUtc') : null;
    if (bytes is! int ||
        bytes < 0 ||
        bytes > maxSourceBytes ||
        fingerprint is! String ||
        !_fingerprintPattern.hasMatch(fingerprint) ||
        handed == null ||
        eligible == null ||
        due == null ||
        created.isAfter(handed) ||
        eligible != handed.add(const Duration(minutes: 15)) ||
        due != handed.add(const Duration(hours: 24)) ||
        (result != 'pending' && !terminal) ||
        (terminal && (resultAt == null || resultAt.isBefore(handed)))) {
      return null;
    }
    return ShareLeaseRecord(
      id: id,
      sourceKind: kind,
      state: state,
      createdAtUtc: created,
      bytes: bytes,
      fingerprint: fingerprint,
      handedOffAtUtc: handed,
      cleanupEligibleAtUtc: eligible,
      cleanupDueAtUtc: due,
      result: result as String,
      resultAtUtc: resultAt,
    );
  }

  static bool _sameKeys(Iterable<String> actual, Set<String> expected) {
    final keys = actual.toSet();
    return keys.length == expected.length && keys.containsAll(expected);
  }
}

class ShareLeaseLedger {
  const ShareLeaseLedger(this.root);
  final Directory root;

  static List<int> encode(ShareLeaseRecord record) {
    final bytes = utf8.encode(jsonEncode(record.toJson()));
    if (bytes.length > 4096 ||
        ShareLeaseRecord.fromJson(jsonDecode(utf8.decode(bytes))) == null) {
      throw const FormatException('invalid share ledger');
    }
    return bytes;
  }

  Future<void> install(
    ShareLeaseRecord record, {
    void Function()? checkpoint,
  }) async {
    await root.create(recursive: true);
    checkpoint?.call();
    final bytes = encode(record);
    final target = File('${root.path}/${record.ledgerFileName}');
    final targetType = await FileSystemEntity.type(
      target.path,
      followLinks: false,
    );
    checkpoint?.call();
    if (targetType != FileSystemEntityType.notFound) {
      throw const ShareLeaseCollisionException('share ledger collision');
    }
    try {
      await target.create(exclusive: true);
    } on FileSystemException {
      final racedType = await FileSystemEntity.type(
        target.path,
        followLinks: false,
      );
      checkpoint?.call();
      if (racedType != FileSystemEntityType.notFound) {
        throw const ShareLeaseCollisionException('share ledger collision');
      }
      rethrow;
    }
    checkpoint?.call();
    final sink = await target.open(mode: FileMode.writeOnly);
    checkpoint?.call();
    await _writeFlushAndClose(sink, bytes, checkpoint: checkpoint);
    final installed = await readFile(
      target,
      expectedId: record.id,
      checkpoint: checkpoint,
    );
    if (installed == null ||
        jsonEncode(installed.toJson()) != jsonEncode(record.toJson())) {
      throw const FileSystemException('share ledger verification failed');
    }
  }

  Future<void> transition({
    required ShareLeaseRecord expected,
    required ShareLeaseRecord next,
    void Function()? checkpoint,
  }) async {
    if (!isValidTransition(expected, next)) {
      throw const FileSystemException('invalid share ledger transition');
    }
    final current = await read(expected.id, checkpoint: checkpoint);
    if (!_sameRecord(current, expected)) {
      throw const FileSystemException('share ledger state changed');
    }
    final target = File('${root.path}/${expected.ledgerFileName}');
    final temp = File('${target.path}.tmp');
    final tempType = await FileSystemEntity.type(temp.path, followLinks: false);
    checkpoint?.call();
    if (tempType != FileSystemEntityType.notFound) {
      throw const FileSystemException('share ledger temp collision');
    }
    await temp.create(exclusive: true);
    checkpoint?.call();
    final sink = await temp.open(mode: FileMode.writeOnly);
    checkpoint?.call();
    await _writeFlushAndClose(sink, encode(next), checkpoint: checkpoint);
    final staged = await readFile(
      temp,
      expectedId: next.id,
      checkpoint: checkpoint,
    );
    if (!_sameRecord(staged, next)) {
      throw const FileSystemException('share ledger verification failed');
    }
    final unchanged = await read(expected.id, checkpoint: checkpoint);
    if (!_sameRecord(unchanged, expected)) {
      throw const FileSystemException('share ledger state changed');
    }
    await temp.rename(target.path);
    checkpoint?.call();
    final verified = await read(next.id, checkpoint: checkpoint);
    if (!_sameRecord(verified, next)) {
      throw const FileSystemException('share ledger re-read failed');
    }
  }

  static bool isValidTransition(
    ShareLeaseRecord expected,
    ShareLeaseRecord next,
  ) {
    if (expected.id != next.id ||
        expected.sourceKind != next.sourceKind ||
        expected.createdAtUtc != next.createdAtUtc) {
      return false;
    }
    if (expected.state == ShareLeaseState.allocated) {
      return next.state == ShareLeaseState.handedOffLease &&
          next.result == 'pending';
    }
    if (next.state != ShareLeaseState.handedOffLease ||
        expected.bytes != next.bytes ||
        expected.fingerprint != next.fingerprint ||
        expected.handedOffAtUtc != next.handedOffAtUtc ||
        expected.cleanupEligibleAtUtc != next.cleanupEligibleAtUtc ||
        expected.cleanupDueAtUtc != next.cleanupDueAtUtc ||
        expected.result != 'pending' ||
        next.result == 'pending') {
      return false;
    }
    return true;
  }

  static bool _sameRecord(
    ShareLeaseRecord? actual,
    ShareLeaseRecord expected,
  ) =>
      actual != null &&
      jsonEncode(actual.toJson()) == jsonEncode(expected.toJson());

  Future<ShareLeaseRecord?> read(String id, {void Function()? checkpoint}) {
    if (!ShareLeaseRecord.idPattern.hasMatch(id)) return Future.value(null);
    return readFile(
      File('${root.path}/$id.lease.json'),
      expectedId: id,
      checkpoint: checkpoint,
    );
  }

  Future<ShareLeaseRecord?> readFile(
    File file, {
    required String expectedId,
    void Function()? checkpoint,
  }) async {
    RandomAccessFile? handle;
    try {
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      checkpoint?.call();
      if (type != FileSystemEntityType.file) return null;
      final length = await file.length();
      checkpoint?.call();
      if (length <= 0 || length > 4096) return null;
      handle = await file.open();
      checkpoint?.call();
      final bytes = await handle.read(length);
      checkpoint?.call();
      if (bytes.length != length) return null;
      final record = ShareLeaseRecord.fromJson(jsonDecode(utf8.decode(bytes)));
      return record?.id == expectedId ? record : null;
    } on Object {
      return null;
    } finally {
      if (handle != null) {
        try {
          await handle.close();
        } on Object {
          throw const ShareResourceUncontainedException(
            'share ledger read handle did not close',
          );
        }
        checkpoint?.call();
      }
    }
  }

  static Future<void> _writeFlushAndClose(
    RandomAccessFile handle,
    List<int> bytes, {
    void Function()? checkpoint,
  }) async {
    Object? operationError;
    StackTrace? operationStack;
    try {
      await handle.writeFrom(bytes);
      checkpoint?.call();
      await handle.flush();
      checkpoint?.call();
    } on Object catch (error, stack) {
      operationError = error;
      operationStack = stack;
    }
    try {
      await handle.close();
    } on Object {
      throw const ShareResourceUncontainedException(
        'share ledger write handle did not close',
      );
    }
    checkpoint?.call();
    if (operationError != null) {
      Error.throwWithStackTrace(operationError, operationStack!);
    }
  }
}
