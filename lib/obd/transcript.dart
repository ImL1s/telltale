/// Everything that crossed the wire, kept so a session that went wrong can be
/// looked at afterwards.
///
/// This exists because of what a failed trip to the car costs. Every refusal in
/// this app is written for a driver — 無法確認這輛車上有哪些控制器 — and every
/// one of them is the end of the story as far as the user is concerned. Somebody
/// drives out, plugs in an adapter, gets a sentence, and comes back with nothing
/// anyone can act on. One sentence is not evidence; the bytes are.
///
/// Recorded at the transport boundary, not after parsing. When the parser is the
/// thing that is wrong, a record of what the parser thought it saw is a record
/// of the bug agreeing with itself. What goes in here is what the adapter
/// actually sent, control characters and all.
library;

import 'dart:convert';
import 'dart:math' as math;

import '../core/field_evidence/evidence_text.dart';

/// One direction of one exchange.
enum TranscriptDirection {
  /// Written to the adapter.
  out,

  /// Received from it.
  incoming,

  /// The app's own note — a state change worth seeing beside the traffic.
  note,
}

/// A single line of the record.
class TranscriptEntry {
  const TranscriptEntry({
    required this.at,
    required this.elapsed,
    required this.direction,
    required this.bytes,
    this.note,
    this.pinned = false,
  });

  /// Wall-clock observation retained for human correlation only.
  ///
  /// Ordering and rendered delays use [elapsed], which is monotonic in a live
  /// session and clamped for legacy/test callers that still supply wall time.
  final DateTime at;
  final Duration elapsed;
  final TranscriptDirection direction;

  /// Exactly what crossed the wire. Empty for a note.
  final List<int> bytes;

  /// Set only for [TranscriptDirection.note].
  final String? note;

  /// Whether this note must survive eviction from the ordinary ring.
  ///
  /// Used only for explicit physical events entered by a passenger. Wire
  /// traffic stays in the bounded head/tail ring; making every note permanent
  /// would turn the diagnostic record back into an unbounded list.
  final bool pinned;

  /// The bytes as text, with the control characters made visible.
  ///
  /// `\r` is the ELM327's line terminator and `>` its prompt; both matter when
  /// reading a transcript and both vanish in ordinary printing. Anything that
  /// is not printable ASCII is shown as its hex value, because a byte that
  /// should not be there is exactly what somebody would be looking for.
  String get text {
    if (direction == TranscriptDirection.note) return note ?? '';
    final out = StringBuffer();
    for (final b in bytes) {
      switch (b) {
        case 0x0D:
          out.write(r'\r');
        case 0x0A:
          out.write(r'\n');
        case 0x5C:
          // The printable bytes `\` + `r` must not render the same as an
          // actual carriage return. Transcript text is an evidence format,
          // so its escaping has to be one-to-one rather than merely readable.
          out.write(r'\\');
        // No `\0` shorthand: a NULL beside a hex digit renders as `41\00C`,
        // which reads as `\00` followed by `C` and is exactly as ambiguous as
        // the corruption it is there to reveal. `\x00` cannot be misread.
        default:
          if (b >= 0x20 && b <= 0x7E) {
            out.writeCharCode(b);
          } else {
            out.write(
              '\\x${b.toRadixString(16).toUpperCase().padLeft(2, '0')}',
            );
          }
      }
    }
    return out.toString();
  }

  /// The same bytes as hex, which is what a protocol question usually needs.
  String get hex => bytes
      .map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0'))
      .join(' ');
}

/// A bounded record of one connection.
///
/// Bounded because a dashboard polls several times a second and a session can
/// last an hour; an unbounded list would be a memory leak sitting in the one
/// place that must never be the reason the app dies mid-drive. When it is full
/// the oldest entries go, and the export says how many were dropped so nobody
/// reads a truncated record as a complete one.
class ObdTranscript {
  ObdTranscript({
    this.maxEntries = 4000,
    int? preservedHeadEntries,
    this.maxPinnedNotes = 64,
    Duration Function()? elapsedNow,
  }) : assert(maxEntries > 0),
       assert(maxPinnedNotes > 0),
       preservedHeadEntries =
           preservedHeadEntries ?? math.min(200, math.max(1, maxEntries ~/ 4)),
       _elapsedClock = elapsedNow {
    assert(this.preservedHeadEntries <= maxEntries);
    _stopwatch.start();
  }

  /// How many entries are kept.
  ///
  /// Four thousand is a few minutes of live polling, or the whole of a
  /// handshake, a fault-code scan and a clear several times over — which is
  /// what somebody diagnosing a failed session actually needs. At roughly 40
  /// bytes an entry it costs a couple of hundred kilobytes.
  final int maxEntries;

  /// Entries at the beginning of the session that can never be evicted.
  ///
  /// The reset, adapter identity and protocol search are normally here. A
  /// plain ring buffer discarded exactly those facts after a few minutes of
  /// dashboard polling and kept only repetitive PID traffic.
  final int preservedHeadEntries;

  /// Additional bounded capacity for evidence and physical-event markers.
  ///
  /// A normal dashboard session can evict most of its middle while polling.
  /// Losing "engine started", "road test began", or the profile provenance
  /// in force makes the retained wire bytes impossible to correlate, so those
  /// rare notes get their own small, bounded overflow lane.
  final int maxPinnedNotes;

  final Duration Function()? _elapsedClock;
  final Stopwatch _stopwatch = Stopwatch();

  final List<TranscriptEntry> _head = [];
  final List<TranscriptEntry> _pinnedNotes = [];
  final List<TranscriptEntry> _tail = [];
  Duration? _elapsedOrigin;
  DateTime? _wallOrigin;
  Duration _lastElapsed = Duration.zero;
  Duration? _firstDroppedElapsed;
  Duration? _lastDroppedElapsed;

  int _dropped = 0;
  int _droppedPinnedNotes = 0;

  /// Every entry still held, oldest first.
  List<TranscriptEntry> get entries =>
      List.unmodifiable(<TranscriptEntry>[..._head, ..._pinnedNotes, ..._tail]);

  /// How many were discarded to stay within [maxEntries].
  int get dropped => _dropped;

  /// How many pinned evidence/event markers exceeded [maxPinnedNotes].
  ///
  /// Included in [dropped], but exposed separately so an evidence export can
  /// distinguish repetitive traffic loss from a physical event it could not
  /// retain.
  int get droppedPinnedNotes => _droppedPinnedNotes;

  /// How many entries have ever been recorded, including the dropped ones.
  ///
  /// The periodic snapshot asks this to decide whether there is anything new
  /// worth writing. `entries.length` cannot answer it: once the ring buffer is
  /// full that number stops moving, and a long session would stop being saved
  /// at exactly the point it has the most to say.
  int get recorded =>
      _head.length + _pinnedNotes.length + _tail.length + _dropped;

  bool get isEmpty => _head.isEmpty && _pinnedNotes.isEmpty && _tail.isEmpty;

  void _add(TranscriptEntry entry) {
    if (_head.length < preservedHeadEntries) {
      _head.add(entry);
      return;
    }

    _tail.add(entry);
    final tailCapacity = maxEntries - preservedHeadEntries;
    if (_tail.length > tailCapacity) {
      final removed = _tail.removeAt(0);
      if (removed.pinned && _pinnedNotes.length < maxPinnedNotes) {
        _pinnedNotes.add(removed);
        return;
      }
      if (removed.pinned) _droppedPinnedNotes++;
      _firstDroppedElapsed ??= removed.elapsed;
      _lastDroppedElapsed = removed.elapsed;
      _dropped++;
    }
  }

  /// Returns time since this transcript began without allowing it to reverse.
  ///
  /// Production callers omit [wallAt] and therefore use [Stopwatch]. The
  /// optional wall time keeps deterministic tests and old call sites source
  /// compatible while clamping device clock corrections to the last elapsed
  /// value. It is deliberately not used by the live transport path.
  ({DateTime wall, Duration elapsed}) _stamp(DateTime? wallAt) {
    final wall = wallAt ?? DateTime.now();
    late Duration elapsed;
    if (wallAt != null) {
      _wallOrigin ??= wallAt;
      elapsed = wallAt.difference(_wallOrigin!);
    } else {
      final current = (_elapsedClock ?? () => _stopwatch.elapsed)();
      _elapsedOrigin ??= current;
      elapsed = current - _elapsedOrigin!;
    }
    if (elapsed.isNegative || elapsed < _lastElapsed) elapsed = _lastElapsed;
    _lastElapsed = elapsed;
    return (wall: wall, elapsed: elapsed);
  }

  void recordWrite(List<int> bytes, [DateTime? at]) {
    final stamp = _stamp(at);
    _add(
      TranscriptEntry(
        at: stamp.wall,
        elapsed: stamp.elapsed,
        direction: TranscriptDirection.out,
        bytes: List.unmodifiable(bytes),
      ),
    );
  }

  void recordRead(List<int> bytes, [DateTime? at]) {
    if (bytes.isEmpty) return;
    final stamp = _stamp(at);
    _add(
      TranscriptEntry(
        at: stamp.wall,
        elapsed: stamp.elapsed,
        direction: TranscriptDirection.incoming,
        bytes: List.unmodifiable(bytes),
      ),
    );
  }

  void recordNote(String note, [DateTime? at]) {
    final stamp = _stamp(at);
    _add(
      TranscriptEntry(
        at: stamp.wall,
        elapsed: stamp.elapsed,
        direction: TranscriptDirection.note,
        bytes: const [],
        note: note,
      ),
    );
  }

  /// Records evidence or an explicit physical event that survives ordinary
  /// ring eviction.
  ///
  /// Still bounded by [maxPinnedNotes]. If a passenger somehow records more
  /// than that, overflow follows the same honest dropped-entry path as wire
  /// traffic rather than growing memory without limit.
  void recordPinnedNote(String note, [DateTime? at]) {
    final stamp = _stamp(at);
    _add(
      TranscriptEntry(
        at: stamp.wall,
        elapsed: stamp.elapsed,
        direction: TranscriptDirection.note,
        bytes: const [],
        note: note,
        pinned: true,
      ),
    );
  }

  void clear() {
    _head.clear();
    _pinnedNotes.clear();
    _tail.clear();
    _dropped = 0;
    _droppedPinnedNotes = 0;
    _firstDroppedElapsed = null;
    _lastDroppedElapsed = null;
    _elapsedOrigin = null;
    _wallOrigin = null;
    _lastElapsed = Duration.zero;
    _stopwatch
      ..reset()
      ..start();
  }

  /// An immutable-by-convention view for a queued disk write or export.
  ///
  /// Entries own unmodifiable byte lists, so copying the two bounded lists is
  /// enough. The live session may continue appending while this object is
  /// rendered without changing the moment the snapshot represents.
  ObdTranscript frozenCopy() {
    final copy = ObdTranscript(
      maxEntries: maxEntries,
      preservedHeadEntries: preservedHeadEntries,
      maxPinnedNotes: maxPinnedNotes,
    );
    copy
      .._head.addAll(_head)
      .._pinnedNotes.addAll(_pinnedNotes)
      .._tail.addAll(_tail)
      .._dropped = _dropped
      .._droppedPinnedNotes = _droppedPinnedNotes
      .._firstDroppedElapsed = _firstDroppedElapsed
      .._lastDroppedElapsed = _lastDroppedElapsed
      .._lastElapsed = _lastElapsed;
    return copy;
  }

  String get _droppedMessage {
    final first = _firstDroppedElapsed?.inMilliseconds;
    final last = _lastDroppedElapsed?.inMilliseconds;
    final range = first == null || last == null
        ? ''
        : '（+$first ms ～ +$last ms）';
    final markerLoss = _droppedPinnedNotes == 0
        ? '開頭握手、全部證據／實車事件與最新資料仍保留。'
        : '其中 $_droppedPinnedNotes 筆是超過容量上限的證據／實車事件；'
              '開頭握手與最新資料仍保留。';
    return '# 中間 $_dropped 筆紀錄已因容量上限捨棄$range；$markerLoss';
  }

  static String _stampFor(TranscriptEntry entry) =>
      '+${entry.elapsed.inMilliseconds.toString().padLeft(7)}ms';

  void _writeTextEntry(StringBuffer out, TranscriptEntry entry) {
    final stamp = _stampFor(entry);
    switch (entry.direction) {
      case TranscriptDirection.out:
        out.writeln('$stamp  >> ${entry.text}');
      case TranscriptDirection.incoming:
        out.writeln('$stamp  << ${entry.text}');
      case TranscriptDirection.note:
        out.writeln('$stamp  -- ${escapeEvidenceText(entry.note ?? '')}');
    }
  }

  void _writeHexEntry(StringBuffer out, TranscriptEntry entry) {
    final stamp = _stampFor(entry);
    switch (entry.direction) {
      case TranscriptDirection.out:
        out.writeln('$stamp  >> ${entry.text}\n${' ' * 13}   ${entry.hex}');
      case TranscriptDirection.incoming:
        out.writeln('$stamp  << ${entry.text}\n${' ' * 13}   ${entry.hex}');
      case TranscriptDirection.note:
        out.writeln('$stamp  -- ${escapeEvidenceText(entry.note ?? '')}');
    }
  }

  /// The record as a text file, ready to send to somebody.
  ///
  /// [header] carries whatever the app knows about the session — adapter
  /// identity, protocol, app version — because a transcript with no idea what
  /// produced it is most of the way to useless.
  String render({String header = ''}) {
    final out = StringBuffer();
    if (header.isNotEmpty) {
      out
        ..writeln(header.trimRight())
        ..writeln();
    }
    if (isEmpty) {
      out.writeln('# 沒有任何傳輸紀錄。');
      return out.toString();
    }
    for (final entry in _head) {
      _writeTextEntry(out, entry);
    }
    if (_dropped > 0) out.writeln(_droppedMessage);
    for (final entry in _pinnedNotes) {
      _writeTextEntry(out, entry);
    }
    for (final entry in _tail) {
      _writeTextEntry(out, entry);
    }
    return out.toString();
  }

  /// The same record with the bytes in hex as well, for a protocol question
  /// where the exact octets are the point.
  String renderHex({String header = ''}) {
    final out = StringBuffer();
    if (header.isNotEmpty) {
      out
        ..writeln(header.trimRight())
        ..writeln();
    }
    if (isEmpty) {
      out.writeln('# 沒有任何傳輸紀錄。');
      return out.toString();
    }
    for (final entry in _head) {
      _writeHexEntry(out, entry);
    }
    if (_dropped > 0) out.writeln(_droppedMessage);
    for (final entry in _pinnedNotes) {
      _writeHexEntry(out, entry);
    }
    for (final entry in _tail) {
      _writeHexEntry(out, entry);
    }
    return out.toString();
  }

  /// Bytes of the rendered text, for writing to a file.
  List<int> encode({String header = '', bool withHex = false}) =>
      utf8.encode(withHex ? renderHex(header: header) : render(header: header));
}
