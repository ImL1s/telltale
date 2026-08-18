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
import 'dart:io';

import 'package:path_provider/path_provider.dart';

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

/// Reads and writes the one snapshot.
class TranscriptStore {
  TranscriptStore({Future<Directory> Function()? directory})
      : _directory = directory ?? getApplicationDocumentsDirectory;

  /// Injected so a test can point this somewhere disposable. Documents rather
  /// than the temporary directory, which the system is free to clear exactly
  /// when storage runs short — which is when a phone is most likely to have
  /// been killing background apps.
  final Future<Directory> Function() _directory;

  static const _fileName = 'last-session.log';
  static const _headerMarker = '#### TRANSCRIPT ####';

  /// Records whether a real adapter was on the other end.
  ///
  /// A line rather than a filename, so an older file without it still loads —
  /// and reads as real hardware, which is the safe direction: the cost of
  /// refusing to overwrite a simulator recording is nothing.
  static const _hardwareMarker = '#### HARDWARE ';

  Future<File> _file() async =>
      File('${(await _directory()).path}/$_fileName');

  /// Writes [transcript] under [header], replacing whatever was there.
  ///
  /// Never throws. A snapshot that fails to save must not take down the
  /// session it was recording — the in-memory copy is still the primary one,
  /// and this is the belt to its braces.
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
  Future<void> save(
    ObdTranscript transcript,
    String header, {
    required bool fromRealHardware,
  }) async {
    try {
      if (transcript.isEmpty) return;
      final file = await _file();
      if (!fromRealHardware) {
        final existing = await load();
        if (existing != null && existing.fromRealHardware) return;
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
        '${transcript.renderHex()}',
        flush: true,
      );
      await staging.rename(file.path);
    } on Object {
      // Deliberately silent. There is nothing a driver could do about it and
      // nothing this app should stop doing because of it.
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
            text.substring(bodyStart + _hardwareMarker.length, markerEnd) != '0';
        bodyStart = markerEnd + 1;
      }
      final split = text.indexOf(_headerMarker, bodyStart);
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

  /// Removes the snapshot. Called once the user has taken it away.
  Future<void> clear() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } on Object {
      // Nothing to report: the next save overwrites it anyway.
    }
  }
}
