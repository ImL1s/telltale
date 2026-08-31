library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

import 'telemetry_session_reader.dart';
import 'telemetry_session.dart';
import 'telemetry_session_codec.dart';

abstract final class TelemetryQuota {
  static const groupLimit = 20;
  static const libraryByteLimit = 100 * 1024 * 1024;
  static const sessionByteLimit = 25 * 1024 * 1024;
  static const footerReserveBytes = 2048;
}

final class TelemetryQuotaSnapshot {
  const TelemetryQuotaSnapshot({
    required this.groupCount,
    required this.recognizedBytes,
  });

  final int groupCount;
  final int recognizedBytes;

  int get remainingLibraryBytes =>
      max(0, TelemetryQuota.libraryByteLimit - recognizedBytes);
  int get effectiveSessionLimit =>
      min(TelemetryQuota.sessionByteLimit, remainingLibraryBytes);
  bool get sessionLimitIsLibraryBound =>
      remainingLibraryBytes < TelemetryQuota.sessionByteLimit;
}

enum TelemetryCreateOutcome {
  created,
  invalidHeader,
  libraryGroupLimit,
  libraryByteLimit,
  noRoomForValue,
  idCollision,
  storageError,
  uncontainedFailure,
}

final class TelemetryCreateResult {
  const TelemetryCreateResult({
    required this.outcome,
    this.sessionId,
    this.file,
    this.effectiveSessionLimit,
    this.sessionLimitIsLibraryBound,
  });

  final TelemetryCreateOutcome outcome;
  final String? sessionId;
  final File? file;
  final int? effectiveSessionLimit;
  final bool? sessionLimitIsLibraryBound;
}

enum TelemetryInstallOutcome {
  installed,
  invalidId,
  missingStaging,
  destinationExists,
  storageError,
}

enum TelemetryDeleteOutcome {
  deleted,
  notFound,
  invalidId,
  storageError,
  uncontainedFailure,
}

enum TelemetryRecoveryOutcome {
  recoveredAndInstalled,
  installedUnchanged,
  deletedZeroValue,
  corruptDeleteOnly,
  collisionDeleteOnly,
  mutationBlocked,
  retryableFailure,
  restartRequired,
}

final class TelemetryRecoveryResult {
  const TelemetryRecoveryResult(this.byId);

  final Map<String, TelemetryRecoveryOutcome> byId;
}

enum TelemetryRecoveryClassification {
  recoverAndInstall,
  installUnchanged,
  deleteZeroValue,
  corruptDeleteOnly,
  collisionDeleteOnly,
}

enum TelemetryRecoveryRunDisposition { completed, retryable, restartRequired }

final class TelemetryArtifactStatIdentity {
  const TelemetryArtifactStatIdentity({
    required this.size,
    required this.modifiedUs,
    required this.changedUs,
  });

  final int size;
  final int modifiedUs;
  final int changedUs;
}

/// A path-free, isolate-safe description of one validated startup artifact.
final class TelemetryRecoveryInspectionItem {
  const TelemetryRecoveryInspectionItem({
    required this.id,
    required this.classification,
    required this.expectedStat,
    required this.completePrefixBytes,
    required this.valueCount,
    required this.statusCount,
    required this.gapCount,
  });

  final String id;
  final TelemetryRecoveryClassification classification;
  final TelemetryArtifactStatIdentity expectedStat;
  final int completePrefixBytes;
  final int valueCount;
  final int statusCount;
  final int gapCount;
}

final class TelemetryRecoveryInspection {
  const TelemetryRecoveryInspection(this.items);

  final List<TelemetryRecoveryInspectionItem> items;
}

final class TelemetryRecoveryCommitResult {
  const TelemetryRecoveryCommitResult({
    required this.disposition,
    required this.byId,
  });

  final TelemetryRecoveryRunDisposition disposition;
  final Map<String, TelemetryRecoveryOutcome> byId;
}

final class TelemetrySessionIndexEntry {
  const TelemetrySessionIndexEntry({
    required this.id,
    required this.startedAtUtc,
    required this.file,
  });

  final String id;
  final DateTime startedAtUtc;
  final File file;
}

enum DamagedTelemetryArtifactKind { corrupt, collision }

final class DamagedTelemetryArtifact {
  const DamagedTelemetryArtifact({
    required this.id,
    required this.filesystemModifiedAtUtc,
    required this.kind,
  });

  final String id;
  final DamagedTelemetryArtifactKind kind;

  /// Untrusted artifact contents never supply this display timestamp.
  final DateTime filesystemModifiedAtUtc;
}

final class TelemetrySessionIndex {
  const TelemetrySessionIndex({required this.sessions, required this.damaged});

  final List<TelemetrySessionIndexEntry> sessions;
  final List<DamagedTelemetryArtifact> damaged;
}

typedef TelemetryIdSource = String Function();
typedef TelemetryMutationPermit = FutureOr<bool> Function();

void _invokeCheckpoint(
  void Function(String checkpoint)? checkpoint,
  String name,
) {
  if (checkpoint == null) return;
  try {
    checkpoint(name);
  } on Object catch (error, stackTrace) {
    throw _TelemetryStoreCheckpointFailure(error, stackTrace);
  }
}

final class _TelemetryStoreCheckpointFailure implements Exception {
  const _TelemetryStoreCheckpointFailure(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}

abstract interface class TelemetryExclusiveCreateHandle {
  Future<void> write(List<int> bytes);
  Future<void> flush();
  Future<void> close();
}

abstract interface class TelemetryExclusiveCreateIo {
  Future<bool> exists(File file);
  Future<void> create(File file);
  Future<TelemetryExclusiveCreateHandle> openWrite(File file);
  Future<FileSystemEntityType> typeNoFollow(File file);
  Future<void> delete(File file);
}

final class FileTelemetryExclusiveCreateIo
    implements TelemetryExclusiveCreateIo {
  const FileTelemetryExclusiveCreateIo();

  @override
  Future<bool> exists(File file) => file.exists();

  @override
  Future<void> create(File file) => file.create(exclusive: true);

  @override
  Future<TelemetryExclusiveCreateHandle> openWrite(File file) async =>
      _FileTelemetryExclusiveCreateHandle(
        await file.open(mode: FileMode.writeOnly),
      );

  @override
  Future<FileSystemEntityType> typeNoFollow(File file) =>
      FileSystemEntity.type(file.path, followLinks: false);

  @override
  Future<void> delete(File file) => file.delete();
}

final class _FileTelemetryExclusiveCreateHandle
    implements TelemetryExclusiveCreateHandle {
  _FileTelemetryExclusiveCreateHandle(this._handle);

  final RandomAccessFile _handle;

  @override
  Future<void> write(List<int> bytes) => _handle.writeFrom(bytes);

  @override
  Future<void> flush() => _handle.flush();

  @override
  Future<void> close() => _handle.close();
}

/// Owns only canonical telemetry artifacts below `telltale-telemetry/`.
final class TelemetrySessionStore {
  TelemetrySessionStore({
    Future<Directory> Function()? documentsDirectory,
    TelemetryIdSource? idSource,
    this.reader = const TelemetrySessionReader(),
    DateTime Function()? nowUtc,
    this.exclusiveCreateIo = const FileTelemetryExclusiveCreateIo(),
  }) : _documentsDirectory =
           documentsDirectory ?? getApplicationDocumentsDirectory,
       _idSource = idSource ?? _secureId,
       _nowUtc = nowUtc ?? _systemNowUtc;

  static final RegExp _artifactName = RegExp(
    r'^([0-9a-f]{32})\.ndjson(?:\.part)?$',
  );

  final Future<Directory> Function() _documentsDirectory;
  final TelemetryIdSource _idSource;
  final TelemetrySessionReader reader;
  final DateTime Function() _nowUtc;
  final TelemetryExclusiveCreateIo exclusiveCreateIo;

  Future<String> recoveryDocumentsPath() async =>
      (await _documentsDirectory()).path;

  Future<Directory> _ensureDirectory({
    void Function(String checkpoint)? checkpoint,
  }) async {
    final documents = await _documentsDirectory();
    _invokeCheckpoint(checkpoint, 'store.afterDocumentsDirectory');
    final result = Directory('${documents.path}/telltale-telemetry');
    final exists = await result.exists();
    _invokeCheckpoint(checkpoint, 'store.afterTelemetryDirectoryProbe');
    if (!exists) {
      await result.create(recursive: true);
      _invokeCheckpoint(checkpoint, 'store.afterTelemetryDirectoryCreate');
    }
    return result;
  }

  /// Looks up the telemetry root without changing the filesystem.
  ///
  /// History, quota display, and replay are read-only surfaces. A first launch
  /// with no recordings must stay indistinguishable from an empty library and
  /// must not create `telltale-telemetry/` merely because a widget was built.
  Future<Directory?> _existingDirectory({
    void Function(String checkpoint)? checkpoint,
  }) async {
    final documents = await _documentsDirectory();
    _invokeCheckpoint(checkpoint, 'store.afterDocumentsDirectory');
    final result = Directory('${documents.path}/telltale-telemetry');
    final type = await FileSystemEntity.type(result.path, followLinks: false);
    _invokeCheckpoint(checkpoint, 'store.afterTelemetryDirectoryProbe');
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.directory) {
      throw const FileSystemException('Telemetry root is not a directory');
    }
    return result;
  }

  Future<TelemetryQuotaSnapshot> scanQuota({
    void Function(String checkpoint)? checkpoint,
  }) async {
    try {
      return await _scanQuota(checkpoint: checkpoint);
    } on _TelemetryStoreCheckpointFailure catch (failure) {
      Error.throwWithStackTrace(failure.error, failure.stackTrace);
    }
  }

  Future<TelemetryQuotaSnapshot> _scanQuota({
    void Function(String checkpoint)? checkpoint,
  }) async {
    final directory = await _existingDirectory(checkpoint: checkpoint);
    if (directory == null) {
      _invokeCheckpoint(checkpoint, 'store.afterQuotaDirectory');
      return const TelemetryQuotaSnapshot(groupCount: 0, recognizedBytes: 0);
    }
    _invokeCheckpoint(checkpoint, 'store.afterQuotaDirectory');
    final groups = <String>{};
    var bytes = 0;
    await for (final entity in directory.list(followLinks: false)) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      _invokeCheckpoint(checkpoint, 'store.afterQuotaEntityType');
      final match = _artifactName.firstMatch(_basename(entity.path));
      if (match == null) continue;
      groups.add(match.group(1)!);
      if (type == FileSystemEntityType.file) {
        bytes += await File(entity.path).length();
        _invokeCheckpoint(checkpoint, 'store.afterQuotaEntityLength');
      } else {
        // A grammar-owned path whose byte size cannot be read without
        // following or traversing an untrusted entity fails the byte quota
        // closed. Replacing a large owned file with a link/directory/socket
        // must never manufacture apparent free capacity.
        bytes = max(bytes, TelemetryQuota.libraryByteLimit);
      }
    }
    _invokeCheckpoint(checkpoint, 'store.afterQuotaEnumeration');
    return TelemetryQuotaSnapshot(
      groupCount: groups.length,
      recognizedBytes: bytes,
    );
  }

  Future<TelemetryCreateResult> createStaging({
    List<int>? headerLine,
    List<int> Function(String sessionId)? headerLineForId,
    required int minimalValueLineBytes,
    void Function(String checkpoint)? checkpoint,
  }) async {
    try {
      if ((headerLine == null) == (headerLineForId == null) ||
          minimalValueLineBytes <= 0) {
        return const TelemetryCreateResult(
          outcome: TelemetryCreateOutcome.invalidHeader,
        );
      }
      final quota = await scanQuota(checkpoint: checkpoint);
      _invokeCheckpoint(checkpoint, 'store.afterCreateQuotaScan');
      if (quota.groupCount >= TelemetryQuota.groupLimit) {
        return const TelemetryCreateResult(
          outcome: TelemetryCreateOutcome.libraryGroupLimit,
        );
      }
      if (quota.remainingLibraryBytes <= 0) {
        return const TelemetryCreateResult(
          outcome: TelemetryCreateOutcome.libraryByteLimit,
        );
      }
      final directory = await _ensureDirectory(checkpoint: checkpoint);
      _invokeCheckpoint(checkpoint, 'store.afterCreateDirectory');
      for (var attempt = 0; attempt < 8; attempt++) {
        final id = _idSource();
        if (!TelemetrySessionReader.isOpaqueId(id)) {
          return const TelemetryCreateResult(
            outcome: TelemetryCreateOutcome.invalidHeader,
          );
        }
        final finalFile = File('${directory.path}/$id.ndjson');
        final staging = File('${directory.path}/$id.ndjson.part');
        final finalType = await exclusiveCreateIo.typeNoFollow(finalFile);
        _invokeCheckpoint(checkpoint, 'store.afterFinalIdProbe.$attempt');
        if (finalType != FileSystemEntityType.notFound) continue;
        final stagingType = await exclusiveCreateIo.typeNoFollow(staging);
        _invokeCheckpoint(checkpoint, 'store.afterStagingIdProbe.$attempt');
        if (stagingType != FileSystemEntityType.notFound) continue;

        late final List<int> encodedHeader;
        try {
          encodedHeader = headerLineForId?.call(id) ?? headerLine!;
        } on Object {
          return const TelemetryCreateResult(
            outcome: TelemetryCreateOutcome.invalidHeader,
          );
        }
        if (!_validHeaderBytes(encodedHeader) ||
            !_headerMatches(encodedHeader, id)) {
          return const TelemetryCreateResult(
            outcome: TelemetryCreateOutcome.invalidHeader,
          );
        }
        if (encodedHeader.length +
                TelemetryQuota.footerReserveBytes +
                minimalValueLineBytes >
            quota.effectiveSessionLimit) {
          return const TelemetryCreateResult(
            outcome: TelemetryCreateOutcome.noRoomForValue,
          );
        }

        _invokeCheckpoint(checkpoint, 'store.beforeExclusiveCreate.$attempt');
        try {
          await exclusiveCreateIo.create(staging);
        } on Object {
          // A path that exists after a failed exclusive create may have been
          // created by this exact call. It is not a proven collision and must
          // retain root ownership for process-level recovery.
          try {
            final postStagingType = await exclusiveCreateIo.typeNoFollow(
              staging,
            );
            if (postStagingType != FileSystemEntityType.notFound) {
              return const TelemetryCreateResult(
                outcome: TelemetryCreateOutcome.uncontainedFailure,
              );
            }
            final postFinalType = await exclusiveCreateIo.typeNoFollow(
              finalFile,
            );
            if (postFinalType != FileSystemEntityType.notFound) {
              continue;
            }
          } on Object {
            return const TelemetryCreateResult(
              outcome: TelemetryCreateOutcome.uncontainedFailure,
            );
          }
          return const TelemetryCreateResult(
            outcome: TelemetryCreateOutcome.storageError,
          );
        }

        try {
          _invokeCheckpoint(checkpoint, 'store.afterExclusiveCreate.$attempt');
        } on _TelemetryStoreCheckpointFailure {
          final cleanup = await _deleteExactStaging(staging);
          if (cleanup == TelemetryDeleteOutcome.deleted ||
              cleanup == TelemetryDeleteOutcome.notFound) {
            rethrow;
          }
          return const TelemetryCreateResult(
            outcome: TelemetryCreateOutcome.uncontainedFailure,
          );
        }

        TelemetryExclusiveCreateHandle? handle;
        var closeProven = false;
        try {
          handle = await exclusiveCreateIo.openWrite(staging);
          _invokeCheckpoint(checkpoint, 'store.afterHeaderOpen.$attempt');
          await handle.write(encodedHeader);
          _invokeCheckpoint(checkpoint, 'store.afterHeaderWrite.$attempt');
          await handle.flush();
          _invokeCheckpoint(checkpoint, 'store.afterHeaderFlush.$attempt');
          await handle.close();
          closeProven = true;
          _invokeCheckpoint(checkpoint, 'store.afterHeaderClose.$attempt');
          return TelemetryCreateResult(
            outcome: TelemetryCreateOutcome.created,
            sessionId: id,
            file: staging,
            effectiveSessionLimit: quota.effectiveSessionLimit,
            sessionLimitIsLibraryBound: quota.sessionLimitIsLibraryBound,
          );
        } on Object catch (error) {
          if (handle != null && !closeProven) {
            try {
              await handle.close();
              closeProven = true;
            } on Object {
              return const TelemetryCreateResult(
                outcome: TelemetryCreateOutcome.uncontainedFailure,
              );
            }
          }
          final cleanup = await _deleteExactStaging(staging);
          if (cleanup != TelemetryDeleteOutcome.deleted &&
              cleanup != TelemetryDeleteOutcome.notFound) {
            return const TelemetryCreateResult(
              outcome: TelemetryCreateOutcome.uncontainedFailure,
            );
          }
          if (error is _TelemetryStoreCheckpointFailure) rethrow;
          return const TelemetryCreateResult(
            outcome: TelemetryCreateOutcome.storageError,
          );
        }
      }
      return const TelemetryCreateResult(
        outcome: TelemetryCreateOutcome.idCollision,
      );
    } on _TelemetryStoreCheckpointFailure catch (failure) {
      Error.throwWithStackTrace(failure.error, failure.stackTrace);
    }
  }

  Future<TelemetryInstallOutcome> install(String id) async {
    if (!TelemetrySessionReader.isOpaqueId(id)) {
      return TelemetryInstallOutcome.invalidId;
    }
    final directory = await _ensureDirectory();
    final staging = File('${directory.path}/$id.ndjson.part');
    final destination = File('${directory.path}/$id.ndjson');
    try {
      if (await FileSystemEntity.type(staging.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return TelemetryInstallOutcome.missingStaging;
      }
      if (await FileSystemEntity.type(destination.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        return TelemetryInstallOutcome.destinationExists;
      }
      // This recheck is intentionally adjacent to the atomic rename. rename()
      // itself is never used as an overwrite primitive by this store.
      if (await FileSystemEntity.type(destination.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        return TelemetryInstallOutcome.destinationExists;
      }
      await staging.rename(destination.path);
      return TelemetryInstallOutcome.installed;
    } on FileSystemException {
      return TelemetryInstallOutcome.storageError;
    }
  }

  Future<TelemetryDeleteOutcome> deleteGroup(
    String id, {
    void Function(String checkpoint)? checkpoint,
  }) async {
    if (!TelemetrySessionReader.isOpaqueId(id)) {
      return TelemetryDeleteOutcome.invalidId;
    }
    var found = false;
    var mutated = false;
    try {
      final documents = await _documentsDirectory();
      final directory = Directory('${documents.path}/telltale-telemetry');
      _invokeCheckpoint(checkpoint, 'delete.beforeRootStat');
      final rootType = await FileSystemEntity.type(
        directory.path,
        followLinks: false,
      );
      if (rootType == FileSystemEntityType.notFound) {
        return TelemetryDeleteOutcome.notFound;
      }
      if (rootType != FileSystemEntityType.directory) {
        return TelemetryDeleteOutcome.storageError;
      }
      for (final suffix in const <String>['.ndjson', '.ndjson.part']) {
        final path = '${directory.path}/$id$suffix';
        _invokeCheckpoint(checkpoint, 'delete.beforeStat.$suffix');
        final type = await FileSystemEntity.type(path, followLinks: false);
        if (type == FileSystemEntityType.notFound) {
          continue;
        }
        found = true;
        _invokeCheckpoint(checkpoint, 'delete.beforeDelete.$suffix');
        mutated = true;
        await _deleteExactEntity(path, type);
        _invokeCheckpoint(checkpoint, 'delete.beforePostStat.$suffix');
        if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          return TelemetryDeleteOutcome.uncontainedFailure;
        }
      }
      return found
          ? TelemetryDeleteOutcome.deleted
          : TelemetryDeleteOutcome.notFound;
    } on _TelemetryStoreCheckpointFailure catch (failure) {
      if (mutated) return TelemetryDeleteOutcome.uncontainedFailure;
      Error.throwWithStackTrace(failure.error, failure.stackTrace);
    } on FileSystemException {
      return mutated
          ? TelemetryDeleteOutcome.uncontainedFailure
          : TelemetryDeleteOutcome.storageError;
    }
  }

  /// Deletes only the exact owned staging artifact. The installed artifact
  /// with the same id is never considered by this operation.
  Future<TelemetryDeleteOutcome> deleteStaging(String id) async {
    if (!TelemetrySessionReader.isOpaqueId(id)) {
      return TelemetryDeleteOutcome.invalidId;
    }
    final directory = await _existingDirectory();
    if (directory == null) return TelemetryDeleteOutcome.notFound;
    return _deleteExactStaging(File('${directory.path}/$id.ndjson.part'));
  }

  Future<bool> stagingIsStableRegularFile(String id) async {
    if (!TelemetrySessionReader.isOpaqueId(id)) return false;
    final directory = await _existingDirectory();
    if (directory == null) return false;
    final file = File('${directory.path}/$id.ndjson.part');
    try {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return false;
      }
      final first = await file.stat();
      await Future<void>.delayed(Duration.zero);
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return false;
      }
      final second = await file.stat();
      return first.type == FileSystemEntityType.file &&
          second.type == FileSystemEntityType.file &&
          first.size == second.size &&
          first.modified == second.modified &&
          first.changed == second.changed;
    } on FileSystemException {
      return false;
    }
  }

  Future<TelemetryDeleteOutcome> _deleteExactStaging(File staging) async {
    try {
      final type = await exclusiveCreateIo.typeNoFollow(staging);
      if (type == FileSystemEntityType.notFound) {
        return TelemetryDeleteOutcome.notFound;
      }
      if (type != FileSystemEntityType.file) {
        return TelemetryDeleteOutcome.storageError;
      }
      await exclusiveCreateIo.delete(staging);
      return await exclusiveCreateIo.typeNoFollow(staging) ==
              FileSystemEntityType.notFound
          ? TelemetryDeleteOutcome.deleted
          : TelemetryDeleteOutcome.storageError;
    } on Object {
      return TelemetryDeleteOutcome.storageError;
    }
  }

  Future<TelemetrySessionIndex> listSessions() async {
    final directory = await _existingDirectory();
    if (directory == null) {
      return const TelemetrySessionIndex(sessions: [], damaged: []);
    }
    final grouped = await _groupArtifacts(directory);
    final sessions = <TelemetrySessionIndexEntry>[];
    final damaged = <DamagedTelemetryArtifact>[];
    for (final entry in grouped.entries) {
      final id = entry.key;
      final group = entry.value;
      final finalFile = group.finalFile;
      if (finalFile != null &&
          finalFile.isRegularFile &&
          group.staging == null) {
        final parsed = await reader.read(
          FileTelemetryChunkSource(finalFile.file),
        );
        final started = parsed.sessionHeader?.startedAtUtc;
        if (parsed.isValid && parsed.sessionFooter != null && started != null) {
          sessions.add(
            TelemetrySessionIndexEntry(
              id: id,
              startedAtUtc: started,
              file: finalFile.file,
            ),
          );
          continue;
        }
      }
      damaged.add(
        DamagedTelemetryArtifact(
          id: id,
          filesystemModifiedAtUtc: await _latestModifiedUtc(group),
          kind: group.finalFile != null && group.staging != null
              ? DamagedTelemetryArtifactKind.collision
              : DamagedTelemetryArtifactKind.corrupt,
        ),
      );
    }
    sessions.sort((a, b) => b.startedAtUtc.compareTo(a.startedAtUtc));
    damaged.sort(
      (a, b) => b.filesystemModifiedAtUtc.compareTo(a.filesystemModifiedAtUtc),
    );
    return TelemetrySessionIndex(
      sessions: List.unmodifiable(sessions),
      damaged: List.unmodifiable(damaged),
    );
  }

  Future<TelemetryRecoveryResult> recover({
    TelemetryMutationPermit? mutationAllowed,
  }) async {
    final inspection = await inspectRecovery();
    void Function(String)? checkpoint;
    var permitted = true;
    if (mutationAllowed != null) {
      final first = mutationAllowed();
      final permitWasAsync = first is Future<bool>;
      // Future.value(true) must grant — do not discard the awaited bool.
      permitted = permitWasAsync ? await first : first;
      if (permitted) {
        // Sync re-checks during commit stay for sync authorities. An async
        // permit cannot be re-polled on the sync checkpoint path without
        // treating every Future as a revocation (which made Future.value(true)
        // permanently mutationBlocked). The initial await is the grant for
        // this recover() call.
        if (!permitWasAsync) {
          checkpoint = (_) {
            final next = mutationAllowed();
            if (next is Future<bool> || !next) {
              throw StateError('Recovery mutation authority changed');
            }
          };
        }
      }
    }
    if (!permitted) {
      return TelemetryRecoveryResult(
        Map.unmodifiable(<String, TelemetryRecoveryOutcome>{
          for (final item in inspection.items)
            item.id:
                item.classification ==
                    TelemetryRecoveryClassification.corruptDeleteOnly
                ? TelemetryRecoveryOutcome.corruptDeleteOnly
                : item.classification ==
                      TelemetryRecoveryClassification.collisionDeleteOnly
                ? TelemetryRecoveryOutcome.collisionDeleteOnly
                : TelemetryRecoveryOutcome.mutationBlocked,
        }),
      );
    }
    final committed = await commitRecovery(inspection, checkpoint: checkpoint);
    if (mutationAllowed == null) {
      return TelemetryRecoveryResult(committed.byId);
    }
    return TelemetryRecoveryResult(
      Map.unmodifiable(<String, TelemetryRecoveryOutcome>{
        for (final entry in committed.byId.entries)
          entry.key: entry.value == TelemetryRecoveryOutcome.retryableFailure
              ? TelemetryRecoveryOutcome.mutationBlocked
              : entry.value,
      }),
    );
  }

  /// Performs no filesystem mutation and returns no filesystem paths.
  Future<TelemetryRecoveryInspection> inspectRecovery() async {
    final documents = await _documentsDirectory();
    final directory = Directory('${documents.path}/telltale-telemetry');
    final directoryType = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (directoryType == FileSystemEntityType.notFound) {
      return const TelemetryRecoveryInspection(
        <TelemetryRecoveryInspectionItem>[],
      );
    }
    if (directoryType != FileSystemEntityType.directory) {
      throw const FileSystemException('Telemetry root is not a directory');
    }
    final grouped = await _groupArtifacts(directory);
    final items = <TelemetryRecoveryInspectionItem>[];
    for (final entry in grouped.entries) {
      final id = entry.key;
      final group = entry.value;
      final staging = group.staging;
      if (staging == null) continue;
      if (!staging.isRegularFile) {
        items.add(
          TelemetryRecoveryInspectionItem(
            id: id,
            classification: group.finalFile == null
                ? TelemetryRecoveryClassification.corruptDeleteOnly
                : TelemetryRecoveryClassification.collisionDeleteOnly,
            expectedStat: const TelemetryArtifactStatIdentity(
              size: 0,
              modifiedUs: 0,
              changedUs: 0,
            ),
            completePrefixBytes: 0,
            valueCount: 0,
            statusCount: 0,
            gapCount: 0,
          ),
        );
        continue;
      }
      final stagingFile = staging.file;
      final stat = await stagingFile.stat();
      final identity = _statIdentity(stat);
      if (group.finalFile != null) {
        items.add(
          TelemetryRecoveryInspectionItem(
            id: id,
            classification: TelemetryRecoveryClassification.collisionDeleteOnly,
            expectedStat: identity,
            completePrefixBytes: 0,
            valueCount: 0,
            statusCount: 0,
            gapCount: 0,
          ),
        );
        continue;
      }
      final parsed = await reader.read(
        FileTelemetryChunkSource(stagingFile),
        allowIncompleteTail: true,
      );
      final classification =
          !parsed.isValid || parsed.sessionHeader?.sessionId != id
          ? TelemetryRecoveryClassification.corruptDeleteOnly
          : parsed.valueCount == 0
          ? TelemetryRecoveryClassification.deleteZeroValue
          : parsed.footerSeen
          ? TelemetryRecoveryClassification.installUnchanged
          : TelemetryRecoveryClassification.recoverAndInstall;
      items.add(
        TelemetryRecoveryInspectionItem(
          id: id,
          classification: classification,
          expectedStat: identity,
          completePrefixBytes: parsed.completePrefixBytes,
          valueCount: parsed.valueCount,
          statusCount: parsed.statusCount,
          gapCount: parsed.gapCount,
        ),
      );
    }
    items.sort((a, b) => a.id.compareTo(b.id));
    return TelemetryRecoveryInspection(List.unmodifiable(items));
  }

  /// Commits a previously inspected plan. Paths are derived from validated
  /// opaque ids and each artifact is revalidated immediately before mutation.
  Future<TelemetryRecoveryCommitResult> commitRecovery(
    TelemetryRecoveryInspection inspection, {
    void Function(String checkpoint)? checkpoint,
  }) async {
    final outcomes = <String, TelemetryRecoveryOutcome>{};
    var disposition = TelemetryRecoveryRunDisposition.completed;
    for (final item in inspection.items) {
      if (!TelemetrySessionReader.isOpaqueId(item.id)) {
        outcomes[item.id] = TelemetryRecoveryOutcome.retryableFailure;
        disposition = TelemetryRecoveryRunDisposition.retryable;
        break;
      }
      if (item.classification ==
          TelemetryRecoveryClassification.corruptDeleteOnly) {
        outcomes[item.id] = TelemetryRecoveryOutcome.corruptDeleteOnly;
        continue;
      }
      if (item.classification ==
          TelemetryRecoveryClassification.collisionDeleteOnly) {
        outcomes[item.id] = TelemetryRecoveryOutcome.collisionDeleteOnly;
        continue;
      }
      final result = await _commitRecoveryItem(item, checkpoint: checkpoint);
      outcomes[item.id] = result.outcome;
      if (result.disposition ==
          TelemetryRecoveryRunDisposition.restartRequired) {
        disposition = TelemetryRecoveryRunDisposition.restartRequired;
        break;
      }
      if (result.disposition == TelemetryRecoveryRunDisposition.retryable) {
        disposition = TelemetryRecoveryRunDisposition.retryable;
        break;
      }
    }
    return TelemetryRecoveryCommitResult(
      disposition: disposition,
      byId: Map.unmodifiable(outcomes),
    );
  }

  Future<_RecoveryItemCommit> _commitRecoveryItem(
    TelemetryRecoveryInspectionItem item, {
    void Function(String checkpoint)? checkpoint,
  }) async {
    var mutated = false;
    RandomAccessFile? handle;
    try {
      final documents = await _documentsDirectory();
      final staging = File(
        '${documents.path}/telltale-telemetry/${item.id}.ndjson.part',
      );
      final destination = File(
        '${documents.path}/telltale-telemetry/${item.id}.ndjson',
      );
      if (!await _matchesInspection(staging, item)) {
        return const _RecoveryItemCommit.retryable();
      }
      if (await FileSystemEntity.type(destination.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        return const _RecoveryItemCommit.retryable();
      }
      if (item.classification ==
          TelemetryRecoveryClassification.deleteZeroValue) {
        _invokeCheckpoint(checkpoint, 'recovery.beforeDelete.${item.id}');
        mutated = true;
        await staging.delete();
        if (await FileSystemEntity.type(staging.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw const FileSystemException('Delete postcondition failed');
        }
        return const _RecoveryItemCommit.completed(
          TelemetryRecoveryOutcome.deletedZeroValue,
        );
      }
      if (item.classification ==
          TelemetryRecoveryClassification.recoverAndInstall) {
        final footer = TelemetrySessionCodec.encodeFooterLine(
          TelemetrySessionFooter(
            endedAtUtc: _nowUtc(),
            terminalReason: TelemetryTerminalReason.recoveredAfterInterruption,
            valueCount: item.valueCount,
            statusCount: item.statusCount,
            gapCount: item.gapCount,
            bytesBeforeFooter: item.completePrefixBytes,
          ),
        );
        if (footer.length > TelemetryQuota.footerReserveBytes) {
          return const _RecoveryItemCommit.retryable();
        }
        _invokeCheckpoint(checkpoint, 'recovery.beforeTruncate.${item.id}');
        handle = await staging.open(mode: FileMode.append);
        mutated = true;
        await handle.truncate(item.completePrefixBytes);
        await handle.setPosition(item.completePrefixBytes);
        _invokeCheckpoint(checkpoint, 'recovery.beforeWrite.${item.id}');
        await handle.writeFrom(footer);
        _invokeCheckpoint(checkpoint, 'recovery.beforeFlush.${item.id}');
        await handle.flush();
        _invokeCheckpoint(checkpoint, 'recovery.beforeClose.${item.id}');
        await handle.close();
        handle = null;
      }
      _invokeCheckpoint(checkpoint, 'recovery.beforeRename.${item.id}');
      mutated = true;
      await staging.rename(destination.path);
      if (await FileSystemEntity.type(staging.path, followLinks: false) !=
              FileSystemEntityType.notFound ||
          await FileSystemEntity.type(destination.path, followLinks: false) !=
              FileSystemEntityType.file) {
        throw const FileSystemException('Install postcondition failed');
      }
      final parsed = await reader.read(FileTelemetryChunkSource(destination));
      if (!parsed.isValid ||
          parsed.sessionHeader?.sessionId != item.id ||
          parsed.sessionFooter == null) {
        throw const FileSystemException('Installed artifact failed validation');
      }
      return _RecoveryItemCommit.completed(
        item.classification == TelemetryRecoveryClassification.installUnchanged
            ? TelemetryRecoveryOutcome.installedUnchanged
            : TelemetryRecoveryOutcome.recoveredAndInstalled,
      );
    } on Object {
      if (handle != null) {
        try {
          await handle.close();
        } on Object {
          mutated = true;
        }
      }
      return mutated
          ? const _RecoveryItemCommit.restartRequired()
          : const _RecoveryItemCommit.retryable();
    }
  }

  Future<bool> _matchesInspection(
    File staging,
    TelemetryRecoveryInspectionItem item,
  ) async {
    if (await FileSystemEntity.type(staging.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return false;
    }
    final stat = await staging.stat();
    if (!_sameStat(_statIdentity(stat), item.expectedStat)) return false;
    final parsed = await reader.read(
      FileTelemetryChunkSource(staging),
      allowIncompleteTail: true,
    );
    return parsed.isValid &&
        parsed.sessionHeader?.sessionId == item.id &&
        parsed.completePrefixBytes == item.completePrefixBytes &&
        parsed.valueCount == item.valueCount &&
        parsed.statusCount == item.statusCount &&
        parsed.gapCount == item.gapCount &&
        parsed.footerSeen ==
            (item.classification ==
                TelemetryRecoveryClassification.installUnchanged);
  }

  static TelemetryArtifactStatIdentity _statIdentity(FileStat stat) =>
      TelemetryArtifactStatIdentity(
        size: stat.size,
        modifiedUs: stat.modified.microsecondsSinceEpoch,
        changedUs: stat.changed.microsecondsSinceEpoch,
      );

  static bool _sameStat(
    TelemetryArtifactStatIdentity a,
    TelemetryArtifactStatIdentity b,
  ) =>
      a.size == b.size &&
      a.modifiedUs == b.modifiedUs &&
      a.changedUs == b.changedUs;

  static bool _validHeaderBytes(List<int> bytes) =>
      bytes.isNotEmpty &&
      bytes.length <= TelemetrySessionReader.headerLineBytes &&
      bytes.last == 0x0A;

  static bool _headerMatches(List<int> bytes, String id) {
    final decoded = TelemetrySessionCodec.decodeHeaderLine(bytes);
    return decoded.value?.sessionId == id;
  }

  Future<Map<String, _ArtifactGroup>> _groupArtifacts(
    Directory directory,
  ) async {
    final grouped = <String, _ArtifactGroup>{};
    await for (final entity in directory.list(followLinks: false)) {
      final name = _basename(entity.path);
      final match = _artifactName.firstMatch(name);
      if (match == null) continue;
      final id = match.group(1)!;
      final group = grouped.putIfAbsent(id, _ArtifactGroup.new);
      final slot = _ArtifactSlot(
        path: entity.path,
        type: await FileSystemEntity.type(entity.path, followLinks: false),
      );
      if (name.endsWith('.part')) {
        group.staging = slot;
      } else {
        group.finalFile = slot;
      }
    }
    return grouped;
  }

  static Future<DateTime> _latestModifiedUtc(_ArtifactGroup group) async {
    var latest = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    for (final slot in <_ArtifactSlot?>[group.finalFile, group.staging]) {
      if (slot == null) continue;
      final modified = await slot.modifiedAtUtc();
      if (modified.isAfter(latest)) latest = modified;
    }
    return latest;
  }

  static String _basename(String path) =>
      path.substring(path.lastIndexOf(Platform.pathSeparator) + 1);

  static String _secureId() {
    final random = Random.secure();
    return List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  static DateTime _systemNowUtc() => DateTime.now().toUtc();
}

final class _ArtifactGroup {
  _ArtifactSlot? finalFile;
  _ArtifactSlot? staging;
}

final class _ArtifactSlot {
  const _ArtifactSlot({required this.path, required this.type});

  final String path;
  final FileSystemEntityType type;

  bool get isRegularFile => type == FileSystemEntityType.file;
  File get file => File(path);

  Future<DateTime> modifiedAtUtc() async {
    try {
      // Do not stat links: FileStat follows them on some platforms and an
      // untrusted exact-name link must never cause target I/O.
      if (type == FileSystemEntityType.link) {
        return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      }
      return (await FileStat.stat(path)).modified.toUtc();
    } on FileSystemException {
      return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
  }
}

Future<void> _deleteExactEntity(String path, FileSystemEntityType type) async {
  if (type == FileSystemEntityType.link) {
    await Link(path).delete();
    return;
  }
  if (type == FileSystemEntityType.directory) {
    // Non-recursive is intentional: an exact-name directory is delete-only
    // only when empty. Never walk untrusted children or follow nested links.
    await Directory(path).delete();
    return;
  }
  await File(path).delete();
}

final class _RecoveryItemCommit {
  const _RecoveryItemCommit._(this.disposition, this.outcome);

  const _RecoveryItemCommit.completed(TelemetryRecoveryOutcome outcome)
    : this._(TelemetryRecoveryRunDisposition.completed, outcome);

  const _RecoveryItemCommit.retryable()
    : this._(
        TelemetryRecoveryRunDisposition.retryable,
        TelemetryRecoveryOutcome.retryableFailure,
      );

  const _RecoveryItemCommit.restartRequired()
    : this._(
        TelemetryRecoveryRunDisposition.restartRequired,
        TelemetryRecoveryOutcome.restartRequired,
      );

  final TelemetryRecoveryRunDisposition disposition;
  final TelemetryRecoveryOutcome outcome;
}
