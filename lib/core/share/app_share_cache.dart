library;

import 'dart:io';

import '../hash/fnv1a64.dart';
import 'share_lease_ledger.dart';

class AppShareCache {
  const AppShareCache(this.root);
  final Directory root;

  static const maxSources = 2;
  static const maxBytes = 64 * 1024 * 1024;
  static final _sourcePattern = RegExp(
    r'^([0-9a-f]{32})\.(csv|json|txt)\.share$',
  );
  static final _ledgerPattern = RegExp(r'^([0-9a-f]{32})\.lease\.json$');
  static final _tempPattern = RegExp(r'^([0-9a-f]{32})\.lease\.json\.tmp$');

  Future<bool> containsGroup(String id, {void Function()? checkpoint}) async {
    if (!ShareLeaseRecord.idPattern.hasMatch(id)) return true;
    for (final suffix in const [
      '.csv.share',
      '.json.share',
      '.txt.share',
      '.lease.json',
      '.lease.json.tmp',
    ]) {
      final type = await FileSystemEntity.type(
        '${root.path}/$id$suffix',
        followLinks: false,
      );
      checkpoint?.call();
      if (type != FileSystemEntityType.notFound) return true;
    }
    return false;
  }

  Future<List<ShareLeaseRecord>> reconstructAndClean(
    DateTime nowUtc, {
    void Function()? checkpoint,
  }) async {
    await root.create(recursive: true);
    checkpoint?.call();
    final groups = <String, _ShareGroup>{};
    await for (final entity in root.list(followLinks: false)) {
      checkpoint?.call();
      if (entity is! File) {
        throw const FileSystemException('blocked share staging entry');
      }
      final name = entity.path.split(Platform.pathSeparator).last;
      final source = _sourcePattern.firstMatch(name);
      final ledger = _ledgerPattern.firstMatch(name);
      final temp = _tempPattern.firstMatch(name);
      final match = source ?? ledger ?? temp;
      if (match == null) {
        throw const FileSystemException('unrecognized share staging file');
      }
      final group = groups.putIfAbsent(match.group(1)!, _ShareGroup.new);
      if (source != null) {
        if (group.source != null) {
          throw const FileSystemException('share source group collision');
        }
        group.source = entity;
      } else if (ledger != null) {
        if (group.ledger != null) {
          throw const FileSystemException('share ledger group collision');
        }
        group.ledger = entity;
      } else {
        if (group.temp != null) {
          throw const FileSystemException('share temp group collision');
        }
        group.temp = entity;
      }
    }

    final restored = <ShareLeaseRecord>[];
    final ledgerReader = ShareLeaseLedger(root);
    for (final entry in groups.entries) {
      final id = entry.key;
      final group = entry.value;
      final main = group.ledger == null
          ? null
          : await ledgerReader.readFile(
              group.ledger!,
              expectedId: id,
              checkpoint: checkpoint,
            );
      var temp = group.temp == null
          ? null
          : await ledgerReader.readFile(
              group.temp!,
              expectedId: id,
              checkpoint: checkpoint,
            );
      if (group.ledger != null && main == null) {
        // Source-less unreadable/partial `.lease.json` is the initial-install
        // crash window (create before flush, or pre-atomic-install residue).
        // Handed-off shares always have a source beside the ledger until
        // cleanup, so keep fail-closed when a source is present.
        if (group.source == null) {
          await _deleteRegular(group.temp, checkpoint);
          await _deleteRegular(group.ledger, checkpoint);
          continue;
        }
        throw const FileSystemException('corrupt share lease');
      }
      if (group.temp != null && temp == null) {
        // A readable installed ledger is still authoritative when rename has
        // not committed. An unreadable regular `.tmp` beside a valid main is
        // an interrupted transition — discard it. A source-less unreadable
        // temp with no main is interrupted atomic initial install staging.
        if (main == null) {
          if (group.source == null && group.ledger == null) {
            await _deleteRegular(group.temp, checkpoint);
            continue;
          }
          throw const FileSystemException('corrupt share lease');
        }
        await _deleteRegular(group.temp, checkpoint);
        group.temp = null;
      }
      if (main == null && temp == null) {
        throw const FileSystemException('orphan share source');
      }
      if (main != null && temp != null && !_legalTemp(main, temp)) {
        throw const FileSystemException('mismatched share ledger temp');
      }

      // No installed ledger, or an allocated installed ledger, means the
      // platform could not have been invoked under the write-ahead order.
      if (main == null || main.state == ShareLeaseState.allocated) {
        await _deleteRegular(group.source, checkpoint);
        await _deleteRegular(group.temp, checkpoint);
        await _deleteRegular(group.ledger, checkpoint);
        continue;
      }

      if (group.source != null && _name(group.source!) != main.sourceFileName) {
        throw const FileSystemException('share source extension mismatch');
      }
      if (group.source == null) {
        // A valid handed-off ledger makes a missing ephemeral source
        // unambiguous: OS eviction, or a crash between source and ledger
        // cleanup. Canonical data is never stored here.
        await _deleteRegular(group.temp, checkpoint);
        await _deleteRegular(group.ledger, checkpoint);
        continue;
      }
      await _verifySource(group.source!, main, checkpoint);
      await _deleteRegular(group.temp, checkpoint);
      if (!nowUtc.toUtc().isBefore(main.cleanupEligibleAtUtc!)) {
        await _deleteRegular(group.source, checkpoint);
        await _deleteRegular(group.ledger, checkpoint);
        continue;
      }
      restored.add(main);
    }
    return restored;
  }

  static bool _legalTemp(ShareLeaseRecord main, ShareLeaseRecord temp) {
    return ShareLeaseLedger.isValidTransition(main, temp);
  }

  static Future<void> _verifySource(
    File source,
    ShareLeaseRecord record,
    void Function()? checkpoint,
  ) async {
    final type = await FileSystemEntity.type(source.path, followLinks: false);
    checkpoint?.call();
    if (type != FileSystemEntityType.file) {
      throw const FileSystemException('share source is not a regular file');
    }
    final hash = Fnv1a64();
    var bytes = 0;
    await for (final chunk in source.openRead()) {
      checkpoint?.call();
      bytes += chunk.length;
      if (bytes > ShareLeaseRecord.maxSourceBytes) {
        throw const FileSystemException('share source exceeds limit');
      }
      hash.add(chunk);
    }
    checkpoint?.call();
    if (bytes != record.bytes || hash.fingerprint != record.fingerprint) {
      throw const FileSystemException('share source verification mismatch');
    }
  }

  static Future<void> _deleteRegular(
    File? file,
    void Function()? checkpoint,
  ) async {
    if (file == null) return;
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    checkpoint?.call();
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.file) {
      throw const FileSystemException('refusing non-regular staging cleanup');
    }
    await file.delete();
    checkpoint?.call();
  }

  static String _name(File file) =>
      file.path.split(Platform.pathSeparator).last;
}

class _ShareGroup {
  File? source;
  File? ledger;
  File? temp;
}
