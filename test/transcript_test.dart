/// The record a failed trip to the car comes back with.
///
/// Every refusal in this app ends in a sentence written for a driver, and the
/// sentence is the whole of what the user has afterwards. These tests are about
/// the thing that makes a wasted trip worth something: the bytes.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/transcript.dart';

void main() {
  group('what crossed the wire, kept as it crossed', () {
    test('control characters survive, because they are the point', () {
      final t = ObdTranscript();
      final at = DateTime(2026, 8, 16, 12);
      t.recordWrite('ATZ\r'.codeUnits, at);
      // A reply with the terminator and the prompt, which is the shape the
      // framing depends on and the shape ordinary printing destroys.
      t.recordRead('ELM327 v2.1\r\r>'.codeUnits, at);

      final text = t.render();
      expect(text, contains(r'>> ATZ\r'));
      expect(text, contains(r'<< ELM327 v2.1\r\r>'));
    });

    test('a byte that should not be there is visible', () {
      // The datasheet warns an ELM327 may insert a NULL, and the client
      // filters them before framing. If the filter is ever the bug, the
      // transcript is the only place the NULL still exists.
      final t = ObdTranscript();
      t.recordRead([0x34, 0x31, 0x00, 0x30, 0x43], DateTime(2026));
      expect(t.render(), contains(r'41\x000C'));
    });

    test('hex rendering carries the octets a protocol question needs', () {
      final t = ObdTranscript();
      t.recordRead([0x7E, 0x08, 0xFF], DateTime(2026));
      expect(t.renderHex(), contains('7E 08 FF'));
    });

    test('an empty chunk records nothing', () {
      // The client re-enters its own byte handler with an empty list to drain
      // a buffered second reply. That is not traffic.
      final t = ObdTranscript();
      t.recordRead(const [], DateTime(2026));
      expect(t.isEmpty, isTrue);
    });

    test('timestamps are relative to the first entry', () {
      // The gap between a command and its reply is usually the thing being
      // diagnosed, and absolute clock time makes that arithmetic the reader's
      // problem.
      final t = ObdTranscript();
      final start = DateTime(2026, 8, 16, 12);
      t.recordWrite('0100\r'.codeUnits, start);
      t.recordRead('41 00\r>'.codeUnits, start.add(const Duration(milliseconds: 412)));
      final text = t.render();
      expect(text, contains('+      0ms'));
      expect(text, contains('+    412ms'));
    });
  });

  group('bounded, and honest about it', () {
    test('the oldest go first and the export says how many', () {
      // Unbounded would be a memory leak in the one place that must never be
      // why the app dies mid-drive.
      final t = ObdTranscript(maxEntries: 3);
      for (var i = 0; i < 10; i++) {
        t.recordWrite('CMD$i\r'.codeUnits, DateTime(2026).add(Duration(seconds: i)));
      }
      expect(t.entries.length, 3);
      expect(t.dropped, 7);
      expect(t.render(), contains('CMD9'));
      expect(t.render(), isNot(contains('CMD0')));
      expect(t.render(), contains('7 筆較早的紀錄已因容量上限捨棄'),
          reason: 'a truncated record must not read as a complete one');
    });

    test('a record with nothing in it says so rather than looking fine', () {
      expect(ObdTranscript().render(), contains('沒有任何傳輸紀錄'));
    });
  });

  group('the header is what makes a log usable by somebody else', () {
    test('it is carried through to the rendered file', () {
      final t = ObdTranscript();
      t.recordWrite('ATI\r'.codeUnits, DateTime(2026));
      expect(t.render(header: '# 協定：ISO 15765-4'), startsWith('# 協定：ISO 15765-4'));
    });
  });

  group("the app's own notes sit beside the traffic", () {
    test('a note explains what the bytes around it were doing', () {
      final t = ObdTranscript();
      final at = DateTime(2026);
      t.recordNote('開始讀取已儲存故障碼（Mode 03）', at);
      t.recordWrite('03\r'.codeUnits, at);
      final text = t.render();
      expect(text, contains('-- 開始讀取已儲存故障碼（Mode 03）'));
      expect(text.indexOf('--'), lessThan(text.indexOf('>>')));
    });
  });
}
