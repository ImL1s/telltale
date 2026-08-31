/// The record a failed trip to the car comes back with.
///
/// Every refusal in this app ends in a sentence written for a driver, and the
/// sentence is the whole of what the user has afterwards. These tests are about
/// the thing that makes a wasted trip worth something: the bytes.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/physics/vehicle_profile.dart';
import 'package:torque_obd/obd/session_evidence.dart';
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
      t.recordRead(
        '41 00\r>'.codeUnits,
        start.add(const Duration(milliseconds: 412)),
      );
      final text = t.render();
      expect(text, contains('+      0ms'));
      expect(text, contains('+    412ms'));
    });

    test('a wall-clock correction cannot make elapsed time go backwards', () {
      final t = ObdTranscript();
      final start = DateTime(2026, 8, 16, 12);
      t.recordWrite('0100\r'.codeUnits, start);
      t.recordRead(
        '41 00\r>'.codeUnits,
        start.subtract(const Duration(seconds: 5)),
      );

      final text = t.render();
      expect(text, isNot(contains('+-')));
      expect(RegExp(r'\+\s*-\d+ms').hasMatch(text), isFalse);
      expect(RegExp(r'\+\s+0ms').allMatches(text), hasLength(2));
    });

    test('literal backslashes cannot masquerade as escaped control bytes', () {
      final t = ObdTranscript();
      final at = DateTime(2026);
      t.recordRead([0x5C, 0x72], at); // The two printable bytes `\\` and `r`.
      t.recordRead([0x0D], at); // An actual carriage return.

      final lines = t.render().split('\n').where((line) => line.contains('<<'));
      expect(lines.first, contains(r'\\r'));
      expect(lines.last, contains(r'\r'));
      expect(lines.first, isNot(equals(lines.last)));
    });
  });

  group('bounded, and honest about it', () {
    test('the middle goes first and the export says how many', () {
      // Unbounded would be a memory leak in the one place that must never be
      // why the app dies mid-drive.
      final t = ObdTranscript(maxEntries: 3);
      for (var i = 0; i < 10; i++) {
        t.recordWrite(
          'CMD$i\r'.codeUnits,
          DateTime(2026).add(Duration(seconds: i)),
        );
      }
      expect(t.entries.length, 3);
      expect(t.dropped, 7);
      expect(t.render(), contains('CMD0'));
      expect(t.render(), contains('CMD8'));
      expect(t.render(), contains('CMD9'));
      expect(t.render(), isNot(contains('CMD1')));
      expect(
        t.render(),
        contains('中間 7 筆紀錄已因容量上限捨棄'),
        reason: 'a truncated record must not read as a complete one',
      );
    });

    test('the handshake head and newest tail survive a long session', () {
      final t = ObdTranscript(maxEntries: 4000);
      final start = DateTime(2026);
      for (var i = 0; i < 5000; i++) {
        t.recordWrite(
          'CMD$i\r'.codeUnits,
          start.add(Duration(milliseconds: i)),
        );
      }

      expect(t.entries, hasLength(4000));
      expect(t.entries.first.text, r'CMD0\r');
      expect(t.entries[199].text, r'CMD199\r');
      expect(t.entries[200].text, r'CMD1200\r');
      expect(t.entries.last.text, r'CMD4999\r');
      expect(t.dropped, 1000);

      final rendered = t.render();
      expect(rendered, contains('中間 1000 筆紀錄已因容量上限捨棄'));
      expect(rendered, contains('+      0ms'));
      expect(rendered, contains('+   4999ms'));
    });

    test('a record with nothing in it says so rather than looking fine', () {
      expect(ObdTranscript().render(), contains('沒有任何傳輸紀錄'));
    });
  });

  group('the header is what makes a log usable by somebody else', () {
    test('streamed export is byte-identical and bounded', () async {
      final t = ObdTranscript()
        ..recordWrite('ATI\r'.codeUnits, DateTime(2026))
        ..recordRead([0x41, 0x00, 0x0d], DateTime(2026));
      final chunks = await t
          .streamEncoded(header: '# test', withHex: true, maxChunkBytes: 32)
          .toList();
      expect(chunks.every((chunk) => chunk.length <= 32), isTrue);
      expect(
        chunks.expand((chunk) => chunk),
        t.encode(header: '# test', withHex: true),
      );
    });
    test('it is carried through to the rendered file', () {
      final t = ObdTranscript();
      t.recordWrite('ATI\r'.codeUnits, DateTime(2026));
      expect(
        t.render(header: '# 協定：ISO 15765-4'),
        startsWith('# 協定：ISO 15765-4'),
      );
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

    test('untrusted note text cannot forge or visually reorder lines', () {
      final t = ObdTranscript()
        ..recordNote('adapter\n# forged\x00\x1B\u202Ehidden', DateTime(2026));

      final text = t.render();
      expect(text, contains(r'adapter\n# forged\x00\x1B\u{202E}hidden'));
      expect(text.split('\n'), isNot(contains('# forged')));
      expect(text, isNot(contains('\x00')));
      expect(text, isNot(contains('\x1B')));
      expect(text, isNot(contains('\u202E')));
    });

    test(
      'a preserved field marker survives beyond the production capacity',
      () {
        final t = ObdTranscript(maxEntries: 4000);
        final start = DateTime(2026);
        for (var i = 0; i < 500; i++) {
          t.recordWrite(
            'HEAD$i\r'.codeUnits,
            start.add(Duration(milliseconds: i)),
          );
        }
        t.recordPinnedNote(
          '實車事件：道路測試開始',
          start.add(const Duration(seconds: 1)),
        );
        for (var i = 0; i < 5000; i++) {
          t.recordRead(
            '410C1AF8\r>'.codeUnits,
            start.add(Duration(seconds: 2, milliseconds: i)),
          );
        }

        expect(t.dropped, greaterThan(0));
        expect(t.render(), contains('實車事件：道路測試開始'));
        expect(t.frozenCopy().render(), contains('實車事件：道路測試開始'));
      },
    );

    test('a profile provenance snapshot survives ordinary ring eviction', () {
      final t = ObdTranscript(maxEntries: 4, preservedHeadEntries: 1);
      final start = DateTime.utc(2026, 8, 29);
      t.recordWrite('ATZ\r'.codeUnits, start);
      t.recordPinnedNote(
        SessionEvidenceMetadata.vehicleProfileChangeNote(
          const VehicleProfile().copyWith(massKg: 1280),
          recordedAt: start.add(const Duration(seconds: 1)),
        ),
        start.add(const Duration(seconds: 1)),
      );
      for (var i = 0; i < 20; i++) {
        t.recordRead(
          '410C1AF8\r>'.codeUnits,
          start.add(Duration(seconds: 2, milliseconds: i)),
        );
      }

      final rendered = t.render();
      expect(t.dropped, greaterThan(0));
      expect(rendered, contains('車輛設定變更快照 v1'));
      expect(rendered, contains('"massKg":1280.0'));
      expect(rendered, contains('"origin":"userEntered"'));
    });

    test('the field-marker retention lane stays bounded', () {
      final t = ObdTranscript(
        maxEntries: 2,
        preservedHeadEntries: 1,
        maxPinnedNotes: 2,
      );
      final start = DateTime(2026);
      t.recordWrite('ATZ\r'.codeUnits, start);
      for (var i = 0; i < 5; i++) {
        t.recordPinnedNote('實車事件 $i', start.add(Duration(milliseconds: i + 1)));
      }
      t.recordRead('OK\r>'.codeUnits, start.add(const Duration(seconds: 1)));

      expect(t.entries, hasLength(4));
      expect(
        t.entries.length,
        lessThanOrEqualTo(t.maxEntries + t.maxPinnedNotes),
      );
      expect(t.dropped, 3);
      expect(t.droppedPinnedNotes, 3);
      expect(t.render(), contains('實車事件 0'));
      expect(t.render(), contains('實車事件 1'));
      expect(t.render(), isNot(contains('實車事件 4')));
      expect(t.render(), contains('其中 3 筆是超過容量上限的證據／實車事件'));
      expect(t.renderHex(), contains('其中 3 筆是超過容量上限的證據／實車事件'));
      expect(t.render(), isNot(contains('全部證據／實車事件與最新資料仍保留')));
      expect(t.frozenCopy().droppedPinnedNotes, 3);
    });
  });
}
