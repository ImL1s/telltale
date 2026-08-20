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
    required this.direction,
    required this.bytes,
    this.note,
  });

  final DateTime at;
  final TranscriptDirection direction;

  /// Exactly what crossed the wire. Empty for a note.
  final List<int> bytes;

  /// Set only for [TranscriptDirection.note].
  final String? note;

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
        // No `\0` shorthand: a NULL beside a hex digit renders as `41\00C`,
        // which reads as `\00` followed by `C` and is exactly as ambiguous as
        // the corruption it is there to reveal. `\x00` cannot be misread.
        default:
          if (b >= 0x20 && b <= 0x7E) {
            out.writeCharCode(b);
          } else {
            out.write('\\x${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
          }
      }
    }
    return out.toString();
  }

  /// The same bytes as hex, which is what a protocol question usually needs.
  String get hex =>
      bytes.map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0')).join(' ');
}

/// A bounded record of one connection.
///
/// Bounded because a dashboard polls several times a second and a session can
/// last an hour; an unbounded list would be a memory leak sitting in the one
/// place that must never be the reason the app dies mid-drive. When it is full
/// the oldest entries go, and the export says how many were dropped so nobody
/// reads a truncated record as a complete one.
class ObdTranscript {
  ObdTranscript({this.maxEntries = 4000});

  /// How many entries are kept.
  ///
  /// Four thousand is a few minutes of live polling, or the whole of a
  /// handshake, a fault-code scan and a clear several times over — which is
  /// what somebody diagnosing a failed session actually needs. At roughly 40
  /// bytes an entry it costs a couple of hundred kilobytes.
  final int maxEntries;

  final List<TranscriptEntry> _entries = [];
  int _dropped = 0;

  /// Every entry still held, oldest first.
  List<TranscriptEntry> get entries => List.unmodifiable(_entries);

  /// How many were discarded to stay within [maxEntries].
  int get dropped => _dropped;

  /// How many entries have ever been recorded, including the dropped ones.
  ///
  /// The periodic snapshot asks this to decide whether there is anything new
  /// worth writing. `entries.length` cannot answer it: once the ring buffer is
  /// full that number stops moving, and a long session would stop being saved
  /// at exactly the point it has the most to say.
  int get recorded => _entries.length + _dropped;

  bool get isEmpty => _entries.isEmpty;

  void _add(TranscriptEntry entry) {
    _entries.add(entry);
    if (_entries.length > maxEntries) {
      _entries.removeAt(0);
      _dropped++;
    }
  }

  void recordWrite(List<int> bytes, DateTime at) => _add(TranscriptEntry(
        at: at,
        direction: TranscriptDirection.out,
        bytes: List.unmodifiable(bytes),
      ));

  void recordRead(List<int> bytes, DateTime at) {
    if (bytes.isEmpty) return;
    _add(TranscriptEntry(
      at: at,
      direction: TranscriptDirection.incoming,
      bytes: List.unmodifiable(bytes),
    ));
  }

  void recordNote(String note, DateTime at) => _add(TranscriptEntry(
        at: at,
        direction: TranscriptDirection.note,
        bytes: const [],
        note: note,
      ));

  void clear() {
    _entries.clear();
    _dropped = 0;
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
    if (_dropped > 0) {
      out
        ..writeln('# $_dropped 筆較早的紀錄已因容量上限捨棄，'
            '以下不是完整的連線過程。')
        ..writeln();
    }
    if (_entries.isEmpty) {
      out.writeln('# 沒有任何傳輸紀錄。');
      return out.toString();
    }
    final start = _entries.first.at;
    for (final e in _entries) {
      // Milliseconds since the first entry, because the gap between a command
      // and its reply is usually the thing being diagnosed and absolute clock
      // time makes that arithmetic the reader's problem.
      final ms = e.at.difference(start).inMilliseconds;
      final stamp = '+${ms.toString().padLeft(7)}ms';
      switch (e.direction) {
        case TranscriptDirection.out:
          out.writeln('$stamp  >> ${e.text}');
        case TranscriptDirection.incoming:
          out.writeln('$stamp  << ${e.text}');
        case TranscriptDirection.note:
          out.writeln('$stamp  -- ${e.note}');
      }
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
    if (_dropped > 0) {
      out.writeln('# $_dropped 筆較早的紀錄已捨棄。');
    }
    if (_entries.isEmpty) {
      out.writeln('# 沒有任何傳輸紀錄。');
      return out.toString();
    }
    final start = _entries.first.at;
    for (final e in _entries) {
      final ms = e.at.difference(start).inMilliseconds;
      final stamp = '+${ms.toString().padLeft(7)}ms';
      switch (e.direction) {
        case TranscriptDirection.out:
          out.writeln('$stamp  >> ${e.text}\n${' ' * 13}   ${e.hex}');
        case TranscriptDirection.incoming:
          out.writeln('$stamp  << ${e.text}\n${' ' * 13}   ${e.hex}');
        case TranscriptDirection.note:
          out.writeln('$stamp  -- ${e.note}');
      }
    }
    return out.toString();
  }

  /// Bytes of the rendered text, for writing to a file.
  List<int> encode({String header = '', bool withHex = false}) =>
      utf8.encode(withHex ? renderHex(header: header) : render(header: header));
}
