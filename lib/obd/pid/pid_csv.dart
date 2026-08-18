/// Import and export of PID definitions in Torque's CSV schema.
///
/// The column order matches the on-disk format the original app uses, so a
/// definition list exported from Torque can be dropped straight in, and one
/// exported here can be taken back out.
library;

import 'package:csv/csv.dart';

import '../addressing.dart';
import 'pid.dart';
import 'priority_tier.dart';

class PidCsvResult {
  final List<Pid> pids;

  /// One entry per row that could not be parsed, with the reason. Surfaced to
  /// the user rather than swallowed: a silently-skipped row looks identical to
  /// a successful import that happened to be short.
  final List<String> errors;

  /// Rows that were imported, but not exactly as written.
  ///
  /// Distinct from [errors], which reject a row. A warning means the app made
  /// a choice on the author's behalf — and the one that matters is a
  /// substituted scale, because a needle reads as authoritative against
  /// whatever bounds it is drawn on, whoever picked them.
  final List<String> warnings;

  const PidCsvResult({
    required this.pids,
    required this.errors,
    this.warnings = const [],
  });

  bool get hasErrors => errors.isNotEmpty;

  bool get hasWarnings => warnings.isNotEmpty;
}

abstract final class PidCsv {
  /// The column names this importer must be able to find.
  ///
  /// The rest are optional: a file without `Units` or `Priority` is still a
  /// usable set of PIDs, and Torque's own community files vary in how many
  /// trailing columns they carry.
  static final Set<String> _required = {'name', 'modeandpid', 'equation'};

  /// Column names compared without spaces or case, because the same column is
  /// written `Min Value`, `min value` and `MinValue` in files that are all
  /// otherwise fine.
  static String _key(String name) =>
      name.trim().toLowerCase().replaceAll(RegExp(r'[\s_]'), '');

  /// The same column under another tool's name.
  ///
  /// Nearly every PID file in circulation was written for Torque Pro, whose
  /// documented columns are `Name`, `ShortName`, `ModeAndPID`, `Equation`,
  /// `Min Value`, `Max Value`, `Units`, `OBD Header`. The first seven are this
  /// app's names exactly. The eighth is not, and the mismatch was silent: the
  /// file imported with no errors and every PID in it was quietly addressed to
  /// the default `7E0`.
  ///
  /// A community set for a transmission (`7E1`) or a body module (`7E2`) then
  /// asks the *engine* the transmission's question. Best case there is no
  /// answer. Worst case `7E0` answers something at that address and the gauge
  /// shows a number that looks exactly like the right one, which is the
  /// failure this whole file is arranged around.
  ///
  /// Aliases resolve *to* this app's spelling, so a column that is already
  /// named `Header` keeps precedence — a round trip through this app must not
  /// be degraded by accepting somebody else's name for the same thing.
  static const Map<String, String> _aliases = {'obdheader': 'header'};

  static const List<String> header = [
    'Name',
    'ShortName',
    'ModeAndPID',
    'Equation',
    'Min Value',
    'Max Value',
    'Units',
    'Header',
    'Priority',
    'Redline',
    'Variant',
  ];

  /// `\r\n` line endings and a BOM: this file is most often opened in Excel,
  /// which needs both to read the UTF-8 unit labels (°C, g/s) correctly.
  static final Csv _codec = Csv(lineDelimiter: '\r\n', addBom: true);

  /// A wire command: whole hex bytes, nothing else.
  static final RegExp _hexCommand = RegExp(r'^(?:[0-9A-F]{2})+$');

  /// A transmit header, at one of the three widths a bus can take: 3 hex
  /// digits for 11-bit CAN, 6 for a legacy three-byte header, 8 for 29-bit CAN.

  static String export(List<Pid> pids) {
    return _codec.encode(<List<dynamic>>[
      header,
      for (final pid in pids) pid.toCsvRow(),
    ]);
  }

  /// Parses [contents]. Tolerant by design — files in the wild come from other
  /// tools and often carry extra columns, missing headers, or a stray BOM.
  static PidCsvResult parse(String contents) {
    final pids = <Pid>[];
    final errors = <String>[];
    final warnings = <String>[];

    // Strip a UTF-8 BOM: Excel writes one, and it would otherwise become part
    // of the first column's name.
    final cleaned = contents.startsWith('﻿') ? contents.substring(1) : contents;

    final List<List<dynamic>> rows;
    try {
      rows = Csv().decode(cleaned);
    } on FormatException catch (e) {
      return PidCsvResult(pids: const [], errors: ['CSV 格式錯誤：${e.message}']);
    }
    if (rows.isEmpty) {
      return const PidCsvResult(pids: [], errors: ['檔案沒有任何資料列。']);
    }

    var startIndex = 0;
    final first = rows.first.map((c) => c.toString().trim().toLowerCase()).toList();
    // Where each field lives. Positional by default, because a file with no
    // header row has nothing else to go on — and by *name* when there is a
    // header, which is the case this used to get wrong.
    //
    // The header row was read only to decide whether to skip it; every field
    // was then taken by index. So a file carrying exactly the right column
    // names in a different order — a spreadsheet somebody re-sorted, an export
    // from a tool that orders them differently — was misread without a word.
    // The worst arrangement is not the one that fails: it is `Units` and
    // `Header` landing where `Min Value` and `Max Value` are expected, which
    // produces a PID that polls the wrong controller and renders against wrong
    // bounds. Both of those are numbers on a gauge that look exactly like the
    // right ones.
    var columns = <String, int>{
      for (var i = 0; i < header.length; i++) _key(header[i]): i,
    };
    if (first.isNotEmpty && (first.first == 'name' || first.contains('modeandpid'))) {
      startIndex = 1;
      final named = <String, int>{};
      final duplicated = <String>{};
      for (var i = 0; i < first.length; i++) {
        final key = _key(first[i]);
        if (key.isEmpty) continue;
        if (named.containsKey(key)) {
          // Reported as the file spells it, not as the comparison normalises
          // it — somebody has to find the column in a spreadsheet.
          duplicated.add(rows.first[i].toString().trim());
          continue;
        }
        named[key] = i;
      }
      // Another tool's name for a column this file did not otherwise supply.
      //
      // A second pass, and only for names still unclaimed, so this can never
      // collide with the real spelling or turn one into a duplicate of the
      // other. A file carrying both `Header` and `OBD Header` keeps `Header`,
      // because that is the one this app writes and a round trip through it
      // must not be degraded by accepting somebody else's word for the same
      // thing.
      for (final entry in _aliases.entries) {
        if (named.containsKey(entry.value)) continue;
        final at = named[entry.key];
        if (at != null) named[entry.value] = at;
      }
      // Refused, not resolved by position.
      //
      // Taking the first occurrence is a silent choice between two columns
      // that both claim to be the equation, or the header. Whichever one is
      // wrong produces a PID that computes with the wrong formula or asks the
      // wrong controller — a number on a gauge that looks exactly like the
      // right one, from a file the author believed was fine.
      if (duplicated.isNotEmpty) {
        return PidCsvResult(
          pids: const [],
          errors: [
            '標題列有重複的欄位名稱：${duplicated.join('、')}。'
                '無法判斷該用哪一欄，請先修正檔案。',
          ],
        );
      }
      final missing = _required.where((r) => !named.containsKey(r)).toList();
      if (missing.isNotEmpty) {
        return PidCsvResult(
          pids: const [],
          errors: [
            '標題列缺少必要欄位：${missing.join('、')}。'
                '需要 Name、ModeAndPID、Equation。',
          ],
        );
      }
      columns = named;
    }

    for (var i = startIndex; i < rows.length; i++) {
      final row = rows[i];
      final lineNumber = i + 1;
      if (row.every((c) => c.toString().trim().isEmpty)) continue;

      if (row.length < 4) {
        errors.add('第 $lineNumber 行：欄位不足，至少需要名稱、簡稱、PID、公式。');
        continue;
      }

      String at(int index) =>
          index >= 0 && index < row.length ? row[index].toString().trim() : '';
      String cell(int index) => at(columns[_key(header[index])] ?? -1);

      // Reject, do not repair.
      //
      // Deleting every character that is not hex turns a typo into a different,
      // perfectly valid request: `22-11O1` (letter O for zero) became `22111`,
      // and an odd length was accepted too. The row then polls an identifier
      // the author never wrote and the number is displayed with whatever bounds
      // happened to parse. Spaces are a legitimate separator; nothing else is.
      final modeAndPid = PollableServices.normalise(cell(2));
      if (!_hexCommand.hasMatch(modeAndPid) || modeAndPid.length < 4) {
        errors.add(
          '第 $lineNumber 行：「${cell(2)}」不是有效的模式+PID'
          '（只接受十六進位字元，且位元組須成對）。',
        );
        continue;
      }
      // A CSV is the easiest way to get an arbitrary command onto a car's bus,
      // and the scheduler would send it repeatedly for as long as the gauge is
      // on screen.
      final unsafe = PollableServices.rejectionReason(modeAndPid);
      if (unsafe != null) {
        errors.add('第 $lineNumber 行：$unsafe');
        continue;
      }

      final equation = cell(3);
      if (equation.isEmpty) {
        errors.add('第 $lineNumber 行：公式為空。');
        continue;
      }

      final minCell = cell(4);
      final maxCell = cell(5);
      final min = double.tryParse(minCell);
      final max = double.tryParse(maxCell);
      final headerValue = BusAddressing.normaliseHeader(cell(7));

      // The same rule the editor applies. They used to disagree: a definition
      // this importer refused could be typed in by hand and accepted, with
      // unparseable bounds quietly replaced by 0/100 — a gauge given a scale
      // nobody chose, whose needle then reads as authoritative against it.
      final rejection = PidDefinition.rejectionReason(
        name: cell(0),
        modeAndPid: PollableServices.normalise(cell(2)),
        header: headerValue,
        minText: minCell,
        maxText: maxCell,
        redlineText: cell(9),
      );
      if (rejection != null) {
        errors.add('第 $lineNumber 行：$rejection');
        continue;
      }

      // A blank bound is accepted here and refused by the editor, which is a
      // deliberate asymmetry — a spreadsheet column can legitimately be empty
      // — but the substituted 0/100 is still a scale nobody chose, and a
      // needle reads as authoritative against whatever it is drawn on. The
      // importer says so rather than letting the difference be invisible.
      if (min == null || max == null) {
        warnings.add('第 $lineNumber 行：量程留空，已套用預設 '
            '${min ?? 0}–${max ?? (min ?? 0) + 100}。'
            '請確認這個刻度適合這個感測器。');
      }
      pids.add(
        Pid(
          name: cell(0).isEmpty ? modeAndPid : cell(0),
          shortName: cell(1).isEmpty ? cell(0) : cell(1),
          modeAndPid: modeAndPid,
          equation: equation,
          minValue: min ?? 0,
          maxValue: max ?? (min ?? 0) + 100,
          units: cell(6),
          header: BusAddressing.resolveHeader(headerValue),
          priority: PriorityTier.fromName(cell(8).isEmpty ? null : cell(8)),
          redlineFrom: double.tryParse(cell(9)),
          variant: cell(10).isEmpty ? null : cell(10),
          isCustom: true,
        ),
      );
    }

    if (pids.isEmpty && errors.isEmpty) {
      errors.add('檔案中沒有可匯入的 PID 定義。');
    }
    return PidCsvResult(pids: pids, errors: errors, warnings: warnings);
  }
}
