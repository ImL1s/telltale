/// A recording that exists must not be labelled as if it were empty.
///
/// Found on a phone, 2026-08-20. A BLE connection to a peripheral that was not
/// an ELM327 failed at `ATZ`, and the connect screen said — correctly, and
/// usefully — 「這次嘗試的完整往返紀錄留著了。帶回來比一句訊息有用。」On the
/// next launch the same recording was offered as **0 KB**.
///
/// The arithmetic was right and the message was wrong. `bytes / 1024` rounded
/// to zero decimals reads 0 for anything under 512 bytes, and a failed
/// handshake is a few hundred bytes: the reset, the timeout, and the step it
/// died on. That is the most diagnostic recording this app produces — the ones
/// that connect successfully are long and boring — and it was the one shown as
/// nothing. Nobody exports a file the app has just told them is empty.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/ui/widgets/transcript_export.dart';

void main() {
  test('a recording under a kilobyte is never shown as zero', () {
    // The size of a failed handshake: ATZ out, nothing back, one note.
    for (final bytes in [1, 40, 199, 400, 511, 1023]) {
      final label = formatTranscriptSize(bytes);
      expect(label.startsWith('0'), isFalse,
          reason: '$bytes bytes rendered as "$label", which reads as empty');
      expect(label, contains('$bytes'),
          reason: 'under a kilobyte the exact size is the useful number');
    }
  });

  test('kilobytes are still kilobytes', () {
    expect(formatTranscriptSize(1024), '1 KB');
    expect(formatTranscriptSize(140 * 1024), '140 KB');
    // Rounding, not truncation, at the boundary — 1536 is closer to 2 KB.
    expect(formatTranscriptSize(1536), '2 KB');
  });
}
