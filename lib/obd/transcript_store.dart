/// The recording, on disk, so it outlives the app that made it.
///
/// `ObdTranscript` is a bounded ring buffer in memory, and everything that
/// reads it — the export button, the failure banner's appendix — reads it from
/// a live or just-torn-down session. That covers the failure this app was
/// built around: a connection that does not work, where the user is still
/// standing there with the app open.
///
/// It does not cover the other half. Android kills backgrounded apps, phones
/// run out of battery in car parks, and an app that has been force-stopped
/// took its only copy with it. Those are exactly the sessions somebody would
/// most want to look at afterwards, because they are the ones that went wrong
/// in a way the user could not sit and watch.
///
/// So a snapshot is written where the operating system cannot reclaim it
/// casually, and offered back on the next launch — on the connection screen as
/// well as in Settings, because the sequence this exists for ends with the app
/// being killed in a car park and the connection screen is where the next
/// launch lands. It is deliberately one file
/// and one session: the point is "what happened last time", not an archive,
/// and a growing pile of logs on a phone is a thing nobody prunes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../state/app_share_coordinator.dart';
import '../state/artifact_operation_gate.dart';
import 'transcript.dart';

/// A recording recovered from a previous run of the app.
class StoredTranscript {
  const StoredTranscript({
    required this.header,
    required this.body,
    required this.savedAt,
    this.fromRealHardware = true,
  });

  /// Whether a real adapter was on the other end of this recording.
  ///
  /// A simulator session is not allowed to overwrite one where this is true;
  /// see [TranscriptStore.save].
  final bool fromRealHardware;

  /// The heading the live session would have rendered — adapter, protocol,
  /// bus — so the bytes are not orphaned from what produced them.
  final String header;

  /// The transcript, already rendered. Kept as text rather than re-parsed:
  /// this file exists to be read by a person, and a format that has to be
  /// decoded before it can be read is one more thing that can be wrong when
  /// somebody needs it most.
  final String body;

  final DateTime savedAt;

  int get bytes => body.length;
}

/// Validated descriptor for a recovered transcript that can be copied without
/// loading its complete body into memory.
class StreamingStoredTranscript {
  StreamingStoredTranscript(
    this._handle, {
    required this.bodyOffset,
    required this.headerBytes,
    required this.savedAt,
    required this.fromRealHardware,
    required this.expectedByteLength,
  });

  final RandomAccessFile _handle;
  final int bodyOffset;
  final List<int> headerBytes;
  final DateTime savedAt;
  final bool fromRealHardware;
  final int expectedByteLength;
  bool _opened = false;
  bool _closed = false;
  Future<void>? _closing;

  Stream<List<int>> open({int maxChunkBytes = 64 * 1024}) async* {
    if (maxChunkBytes <= 0 || maxChunkBytes > 64 * 1024) {
      throw ArgumentError.value(maxChunkBytes);
    }
    if (_opened || _closed) {
      throw StateError('recovered transcript descriptor is single-use');
    }
    _opened = true;
    try {
      await _handle.setPosition(bodyOffset);
      for (
        var offset = 0;
        offset < headerBytes.length;
        offset += maxChunkBytes
      ) {
        final end = (offset + maxChunkBytes).clamp(0, headerBytes.length);
        yield headerBytes.sublist(offset, end);
      }
      while (true) {
        final chunk = await _handle.read(maxChunkBytes);
        if (chunk.isEmpty) break;
        yield chunk;
      }
    } finally {
      await close();
    }
  }

  Future<void> close() {
    if (_closed) return Future<void>.value();
    final active = _closing;
    if (active != null) return active;
    final operation = _closeHandle();
    _closing = operation;
    return operation;
  }

  Future<void> _closeHandle() async {
    await _handle.close();
    _closed = true;
  }
}

enum TranscriptMutationError {
  artifactBusy,
  policyDenied,
  safetyChanged,
  storageFailure,
}

class TranscriptMutationOutcome {
  const TranscriptMutationOutcome.success() : error = null;
  const TranscriptMutationOutcome.failure(this.error);
  final TranscriptMutationError? error;
  bool get succeeded => error == null;
}

/// Reads and writes the one snapshot.
class TranscriptStore {
  TranscriptStore({
    Future<Directory> Function()? directory,
    ArtifactOperationGate? artifactGate,
    ArtifactOperationGate? saveGate,
    this.destructivePolicy,
  }) : _directory = directory ?? getApplicationDocumentsDirectory,
       _artifactGate = artifactGate ?? _defaultArtifactGate,
       _saveGate = saveGate ?? _defaultSaveGate;

  static final ArtifactOperationGate _defaultArtifactGate =
      ArtifactOperationGate();
  static final ArtifactOperationGate _defaultSaveGate = ArtifactOperationGate();
  static int _ownerSequence = 0;

  /// Injected so a test can point this somewhere disposable. Documents rather
  /// than the temporary directory, which the system is free to clear exactly
  /// when storage runs short — which is when a phone is most likely to have
  /// been killing background apps.
  final Future<Directory> Function() _directory;
  final ArtifactOperationGate _artifactGate;
  final ArtifactOperationGate _saveGate;
  final AppSharePolicy? destructivePolicy;

  static const _fileName = 'last-session.log';
  static const _headerMarker = '#### TRANSCRIPT ####';

  /// Records whether a real adapter was on the other end.
  ///
  /// A line rather than a filename, so an older file without it still loads —
  /// and reads as real hardware, which is the safe direction: the cost of
  /// refusing to overwrite a simulator recording is nothing.
  static const _hardwareMarker = '#### HARDWARE ';

  Future<File> _file() async => File('${(await _directory()).path}/$_fileName');

  /// Writes [transcript] under [header], replacing whatever was there.
  ///
  /// Never throws. A snapshot that fails to save must not take down the
  /// session it was recording — the in-memory copy is still the primary one,
  /// and this is the belt to its braces. Returns false on a storage failure so
  /// a manual event marker can avoid claiming it was persisted.
  ///
  /// [fromRealHardware] decides whether it may replace a recording made from
  /// one. It may not, and the scenario is the ordinary one rather than a
  /// contrived one: the connection fails in the car, the phone kills the app —
  /// which is the entire reason this file exists — and back at home the owner
  /// opens the app to see whether it is all right, taps the Demo simulator
  /// because FIELD_GUIDE tells them to, and presses Home. The pause handler
  /// then saves a simulator transcript over the only record of the failure,
  /// with no prompt and nothing on screen having mentioned that a recording
  /// existed. A session with no hardware in it has no diagnostic value about a
  /// car, and it must not be able to destroy one that has.
  Future<bool> save(
    ObdTranscript transcript,
    String header, {
    required bool fromRealHardware,
  }) async {
    // Capture before the first await. Storage lookup and the demo-vs-hardware
    // guard can both yield long enough for live OBD traffic to arrive; a save
    // requested by an event marker must describe that exact moment.
    final snapshot = transcript.frozenCopy();
    if (snapshot.isEmpty) return true;
    final artifact = _saveGate.tryAcquire(
      'transcript-save-${_ownerSequence++}',
      ArtifactOperation.install,
    );
    if (!artifact.acquired) return false;
    try {
      final file = await _file();
      if (!fromRealHardware) {
        final existing = await load();
        if (existing != null && existing.fromRealHardware) return true;
      }
      // Written whole, to a temporary neighbour, then renamed. A process that
      // dies midway through writing this file would otherwise replace a
      // complete recording of the session that failed with half a recording of
      // the one that has not finished yet.
      final staging = File('${file.path}.part');
      await staging.writeAsString(
        '${DateTime.now().toIso8601String()}\n'
        '$_hardwareMarker${fromRealHardware ? '1' : '0'}\n'
        '$header'
        '$_headerMarker\n'
        '${snapshot.renderHex()}',
        flush: true,
      );
      await staging.rename(file.path);
      return true;
    } on Object {
      // Deliberately silent. There is nothing a driver could do about it and
      // nothing this app should stop doing because of it.
      return false;
    } finally {
      _saveGate.release(artifact.token!);
    }
  }

  /// The snapshot from a previous run, or null.
  Future<StoredTranscript?> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final text = await file.readAsString();
      final firstBreak = text.indexOf('\n');
      if (firstBreak < 0) return null;
      final savedAt = DateTime.tryParse(text.substring(0, firstBreak));
      if (savedAt == null) return null;
      var bodyStart = firstBreak + 1;
      // Absent in files written before the marker existed, and those are read
      // as real hardware — the safe direction, since the only thing it costs
      // is refusing to overwrite a simulator recording.
      var fromRealHardware = true;
      if (text.startsWith(_hardwareMarker, bodyStart)) {
        final markerEnd = text.indexOf('\n', bodyStart);
        if (markerEnd < 0) return null;
        fromRealHardware =
            text.substring(bodyStart + _hardwareMarker.length, markerEnd) !=
            '0';
        bodyStart = markerEnd + 1;
      }
      final split = _standaloneHeaderMarker(text, bodyStart);
      if (split < 0) return null;
      return StoredTranscript(
        fromRealHardware: fromRealHardware,
        header: text.substring(bodyStart, split),
        body: text.substring(split + _headerMarker.length + 1),
        savedAt: savedAt,
      );
    } on Object {
      return null;
    }
  }

  /// Validates the bounded metadata prefix and returns a streaming body view.
  /// Metadata beyond 64 KiB is refused rather than guessed.
  Future<StreamingStoredTranscript?> openStreaming() async {
    RandomAccessFile? handle;
    var transferred = false;
    try {
      final file = await _file();
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type != FileSystemEntityType.file) return null;
      handle = await file.open();
      final fileLength = await handle.length();
      final prefix = <int>[];
      const marker = '\n$_headerMarker\n';
      final markerBytes = marker.codeUnits;
      final scanLimit = 64 * 1024 + markerBytes.length;
      var markerAt = -1;
      while (prefix.length < scanLimit && markerAt < 0) {
        final remaining = scanLimit - prefix.length;
        final chunk = await handle.read(remaining.clamp(1, 64 * 1024));
        if (chunk.isEmpty) break;
        prefix.addAll(chunk);
        markerAt = _indexOfBytes(prefix, markerBytes);
      }
      if (markerAt < 0 || markerAt > 64 * 1024) return null;
      final metadata = utf8.decode(prefix.sublist(0, markerAt));
      final firstBreak = metadata.indexOf('\n');
      if (firstBreak < 0) return null;
      final savedAt = DateTime.tryParse(metadata.substring(0, firstBreak));
      if (savedAt == null) return null;
      var headerStart = firstBreak + 1;
      var fromRealHardware = true;
      if (metadata.startsWith(_hardwareMarker, headerStart)) {
        final markerEnd = metadata.indexOf('\n', headerStart);
        if (markerEnd < 0) return null;
        fromRealHardware =
            metadata.substring(
              headerStart + _hardwareMarker.length,
              markerEnd,
            ) !=
            '0';
        headerStart = markerEnd + 1;
      }
      final header = metadata.substring(headerStart);
      final headerBytes = utf8.encode(header.isEmpty ? '' : '$header\n');
      final bodyOffset = markerAt + markerBytes.length;
      if (bodyOffset > fileLength) return null;
      transferred = true;
      return StreamingStoredTranscript(
        handle,
        bodyOffset: bodyOffset,
        headerBytes: headerBytes,
        savedAt: savedAt,
        fromRealHardware: fromRealHardware,
        expectedByteLength: headerBytes.length + fileLength - bodyOffset,
      );
    } on Object {
      return null;
    } finally {
      if (!transferred) await handle?.close();
    }
  }

  static int _indexOfBytes(List<int> haystack, List<int> needle) {
    for (var i = 0; i <= haystack.length - needle.length; i++) {
      var matches = true;
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          matches = false;
          break;
        }
      }
      if (matches) return i;
    }
    return -1;
  }

  /// Finds the header/body sentinel only when it occupies a complete line.
  ///
  /// Adapter identity strings are untrusted and may contain the sentinel text
  /// as ordinary data. Treating any substring as the delimiter would truncate
  /// that header and move the remainder into the recovered transcript.
  static int _standaloneHeaderMarker(String text, int start) {
    if (text.startsWith('$_headerMarker\n', start)) return start;
    const markerLine = '\n$_headerMarker\n';
    final precedingBreak = text.indexOf(markerLine, start);
    return precedingBreak < 0 ? -1 : precedingBreak + 1;
  }

  /// Removes the snapshot. Called once the user has taken it away.
  Future<TranscriptMutationOutcome> clear() async {
    final ownerId = 'transcript-clear-${_ownerSequence++}';
    final artifact = _artifactGate.tryAcquire(
      ownerId,
      ArtifactOperation.delete,
    );
    if (!artifact.acquired) {
      return const TranscriptMutationOutcome.failure(
        TranscriptMutationError.artifactBusy,
      );
    }
    final mutation = _saveGate.tryAcquire(
      '$ownerId-mutation',
      ArtifactOperation.delete,
    );
    if (!mutation.acquired) {
      _artifactGate.release(artifact.token!);
      return const TranscriptMutationOutcome.failure(
        TranscriptMutationError.artifactBusy,
      );
    }
    final policy = destructivePolicy;
    final permit = policy?.freeze();
    if (permit == null) {
      _saveGate.release(mutation.token!);
      _artifactGate.release(artifact.token!);
      return const TranscriptMutationOutcome.failure(
        TranscriptMutationError.policyDenied,
      );
    }
    try {
      bool valid() => policy!.validate(permit).isValid;
      if (!valid()) {
        return const TranscriptMutationOutcome.failure(
          TranscriptMutationError.safetyChanged,
        );
      }
      final file = await _file();
      if (!valid()) {
        return const TranscriptMutationOutcome.failure(
          TranscriptMutationError.safetyChanged,
        );
      }
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (!valid()) {
        return const TranscriptMutationOutcome.failure(
          TranscriptMutationError.safetyChanged,
        );
      }
      if (type == FileSystemEntityType.notFound) {
        return const TranscriptMutationOutcome.success();
      }
      if (type != FileSystemEntityType.file) {
        return const TranscriptMutationOutcome.failure(
          TranscriptMutationError.storageFailure,
        );
      }
      if (!valid()) {
        return const TranscriptMutationOutcome.failure(
          TranscriptMutationError.safetyChanged,
        );
      }
      await file.delete();
      if (!valid()) {
        return const TranscriptMutationOutcome.failure(
          TranscriptMutationError.safetyChanged,
        );
      }
      return const TranscriptMutationOutcome.success();
    } on Object {
      return const TranscriptMutationOutcome.failure(
        TranscriptMutationError.storageFailure,
      );
    } finally {
      _saveGate.release(mutation.token!);
      _artifactGate.release(artifact.token!);
    }
  }
}
