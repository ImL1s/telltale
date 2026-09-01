import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/pid/pid.dart';
import 'package:torque_obd/obd/pid/pid_csv.dart';
import 'package:torque_obd/obd/pid/priority_tier.dart';

void main() {
  _reorderedColumns();
  _strictParsingTests();
  _torqueProCompatibility();
  group('export / import round trip', () {
    test(
      'streamed export preserves exact CSV bytes in bounded chunks',
      () async {
        const pid = Pid(
          name: 'Coolant',
          shortName: 'ECT',
          modeAndPid: '0105',
          equation: 'A-40',
          minValue: -40,
          maxValue: 215,
          units: '°C',
        );
        final chunks = await PidCsv.stream([pid], maxChunkBytes: 32).toList();
        expect(chunks.every((chunk) => chunk.length <= 32), isTrue);
        expect(
          chunks.expand((chunk) => chunk),
          utf8.encode(PidCsv.export([pid])),
        );
      },
    );
    test('every field survives a round trip', () {
      const original = Pid(
        name: 'Transmission Fluid Temp',
        shortName: 'Trans',
        modeAndPid: '221E1C',
        equation: '((A*256)+B)/8-40',
        minValue: -40,
        maxValue: 215,
        units: '°C',
        header: '7E1',
        priority: PriorityTier.high,
        redlineFrom: 120,
        isCustom: true,
      );

      final result = PidCsv.parse(PidCsv.export([original]));
      expect(result.errors, isEmpty);
      final restored = result.pids.single;

      expect(restored.name, original.name);
      expect(restored.shortName, original.shortName);
      expect(restored.modeAndPid, original.modeAndPid);
      expect(restored.equation, original.equation);
      expect(restored.minValue, original.minValue);
      expect(restored.maxValue, original.maxValue);
      // Unit labels are the reason the exporter writes a BOM.
      expect(restored.units, '°C');
      expect(restored.header, '7E1');
      expect(restored.priority, PriorityTier.high);
      expect(restored.redlineFrom, 120);
      expect(restored.isCustom, isTrue);
    });
  });

  group('parsing files from elsewhere', () {
    test('reads a stock eight-column Torque file', () {
      const wire =
          'Name,ShortName,ModeAndPID,Equation,Min Value,Max Value,Units,Header\r\n'
          'Engine RPM,RPM,010C,((A*256)+B)/4,0,8000,rpm,7E0\r\n';
      final result = PidCsv.parse(wire);
      expect(result.errors, isEmpty);
      expect(result.pids.single.modeAndPid, '010C');
      expect(result.pids.single.units, 'rpm');
    });

    test('a file with no header row still parses', () {
      const wire = 'Boost,Boost,010B,A-101,-100,200,kPa,7E0\r\n';
      expect(PidCsv.parse(wire).pids, hasLength(1));
    });

    test('a UTF-8 BOM does not end up inside the first column', () {
      const wire =
          '﻿Name,ShortName,ModeAndPID,Equation,Min Value,Max Value,Units,Header\r\n'
          'Oil Temp,Oil,015C,A-40,-40,215,°C,7E0\r\n';
      final result = PidCsv.parse(wire);
      expect(result.pids.single.name, 'Oil Temp');
    });

    test('bad rows are reported rather than silently skipped', () {
      const wire =
          'Good,G,010C,A,0,100,x,7E0\r\n'
          'Broken,B,ZZ,A,0,100,x,7E0\r\n'
          'NoFormula,N,0105,,0,100,x,7E0\r\n';
      final result = PidCsv.parse(wire);
      expect(result.pids, hasLength(1));
      expect(result.errors, hasLength(2));
      expect(result.errors.first, contains('2'));
    });

    test('an empty file reports why nothing was imported', () {
      expect(PidCsv.parse('').errors, isNotEmpty);
    });

    test('imported definitions are namespaced away from the built-ins', () {
      // A stock Torque file contains 010C. It must not take over the shipped
      // Engine RPM definition, which the physics engine depends on.
      const wire = 'My RPM,RPM,010C,A*2,0,8000,rpm,7E0\r\n';
      final imported = PidCsv.parse(wire).pids.single;
      const builtIn = Pid(
        name: 'Engine RPM',
        shortName: 'RPM',
        modeAndPid: '010C',
        equation: '((A*256)+B)/4',
        minValue: 0,
        maxValue: 8000,
        units: 'rpm',
      );
      expect(imported.id, isNot(builtIn.id));
    });
  });
}

/// A malformed import must fail the row rather than become a different,
/// perfectly valid request.
void _strictParsingTests() {
  group('malformed rows are rejected, not repaired', () {
    const columns =
        'Name,ShortName,ModeAndPID,Equation,Min Value,Max Value,'
        'Units,Header,Priority,Redline,Variant\r\n';

    PidCsvResult parseRow(String row) => PidCsv.parse('$columns$row\r\n');

    test(
      'a letter O typed for a zero fails instead of changing the request',
      () {
        // `22-11O1` had every non-hex character deleted, yielding a request the
        // author never wrote. The gauge then polled a different identifier and
        // displayed whatever came back.
        final result = parseRow('Trans,T,22-11O1,A,0,100,C,7E0');
        expect(result.pids, isEmpty);
        expect(result.errors, isNotEmpty);
      },
    );

    test('an odd number of hex digits fails', () {
      final result = parseRow('Odd,O,010C0,A,0,100,C,7E0');
      expect(result.pids, isEmpty);
      expect(result.errors, isNotEmpty);
    });

    test('spaces between bytes are still accepted', () {
      final result = parseRow('Spaced,S,22 1E 1C,A,0,100,C,7E0');
      expect(result.errors, isEmpty);
      expect(result.pids.single.modeAndPid, '221E1C');
    });

    test('unparseable bounds fail instead of defaulting to 0 and 100', () {
      // Silently substituting 0/100 gave the gauge a scale nobody chose, and
      // the needle then read as authoritative against invented bounds.
      final result = parseRow('Bad,B,0105,A,foo,bar,C,7E0');
      expect(result.pids, isEmpty);
      expect(result.errors, isNotEmpty);
    });

    test('an inverted range fails', () {
      final result = parseRow('Inv,I,0105,A,100,0,C,7E0');
      expect(result.pids, isEmpty);
      expect(result.errors, isNotEmpty);
    });

    test('a header of an impossible width fails', () {
      final result = parseRow('Head,H,0105,A,0,100,C,7E01');
      expect(result.pids, isEmpty);
      expect(result.errors, isNotEmpty);
    });

    test('the three legal header widths are accepted', () {
      for (final header in ['7E0', '6810F1', '18DA10F1']) {
        final result = parseRow('Head,H,0105,A,0,100,C,$header');
        expect(result.errors, isEmpty, reason: header);
        expect(result.pids.single.header, header);
      }
    });
  });

  group('the editor and the importer agree', () {
    test('one rule decides whether a definition is admissible', () {
      // These used to disagree: the importer refused a malformed header or an
      // inverted range, while the editor accepted both and substituted 0/100
      // for bounds it could not parse — a gauge given a scale nobody chose,
      // whose needle then reads as authoritative against it.
      expect(
        PidDefinition.rejectionReason(
          name: 'x',
          modeAndPid: '010C',
          header: '7EG',
          minText: '0',
          maxText: '100',
        ),
        contains('標頭'),
      );
      expect(
        PidDefinition.rejectionReason(
          name: 'x',
          modeAndPid: '010C',
          header: '7E0',
          minText: '100',
          maxText: '10',
        ),
        contains('上限'),
      );
      expect(
        PidDefinition.rejectionReason(
          name: 'x',
          modeAndPid: '010C',
          header: '7E0',
          minText: 'abc',
          maxText: '100',
        ),
        contains('下限'),
      );

      // Blank bounds are a spreadsheet's business and not the editor's, which
      // is the one place the two callers legitimately differ.
      expect(
        PidDefinition.rejectionReason(
          name: 'x',
          modeAndPid: '010C',
          header: '7E0',
          minText: '',
          maxText: '',
        ),
        isNull,
      );
      expect(
        PidDefinition.rejectionReason(
          name: 'x',
          modeAndPid: '010C',
          header: '7E0',
          minText: '',
          maxText: '',
          requireBounds: true,
        ),
        isNotNull,
      );

      // And a well-formed definition passes both ways.
      expect(
        PidDefinition.rejectionReason(
          name: 'x',
          modeAndPid: '010C',
          header: '7E0',
          minText: '0',
          maxText: '8000',
          requireBounds: true,
        ),
        isNull,
      );
    });
  });
}

void _reorderedColumns() {
  group('a header row means the names decide, not the positions', () {
    test('columns in a different order are read correctly', () {
      // Found by an independent audit of the importer. The header row was read
      // only to decide whether to skip it, and every field was then taken by
      // index — so a file with exactly the right column names in a different
      // order was misread without a word.
      //
      // The worst arrangement is not the one that fails. `Units` and `Header`
      // landing where `Min Value` and `Max Value` are expected produces a PID
      // that polls the wrong controller and renders against wrong bounds: two
      // numbers on a gauge that look exactly like the right ones.
      const csv =
          'Header,Name,Equation,ModeAndPID,Units,Max Value,Min Value\r\n'
          '7E1,Trans Temp,A-40,2211A6,°C,215,-40\r\n';
      final result = PidCsv.parse(csv);
      expect(result.errors, isEmpty);
      final pid = result.pids.single;
      expect(pid.name, 'Trans Temp');
      expect(pid.modeAndPid, '2211A6');
      expect(pid.equation, 'A-40');
      expect(
        pid.header,
        '7E1',
        reason:
            'the header decides which controller is asked; reading it '
            'from the wrong column asks a different module',
      );
      expect(pid.units, '°C');
      expect(pid.minValue, -40);
      expect(pid.maxValue, 215);
    });

    test('a header row missing a required column is refused, not guessed', () {
      const csv = 'Name,Units\r\nTrans Temp,°C\r\n';
      final result = PidCsv.parse(csv);
      expect(result.pids, isEmpty);
      expect(result.errors.single, contains('ModeAndPID'));
    });

    test('no header row still means positional, as it always did', () {
      const csv = 'Trans Temp,TTemp,2211A6,A-40,-40,215,°C,7E1\r\n';
      final result = PidCsv.parse(csv);
      expect(result.errors, isEmpty);
      final pid = result.pids.single;
      expect(pid.modeAndPid, '2211A6');
      expect(pid.header, '7E1');
      expect(pid.minValue, -40);
    });

    test('a duplicated column name is refused, not resolved by position', () {
      // Taking the first occurrence is a silent choice between two columns
      // that both claim to be the equation. Whichever is wrong produces a PID
      // that computes with the wrong formula — a number on a gauge that looks
      // exactly like the right one, from a file the author believed was fine.
      const csv =
          'Name,ModeAndPID,Equation,Equation\r\n'
          'Trans Temp,2211A6,A-40,A*100/255\r\n';
      final result = PidCsv.parse(csv);
      expect(result.pids, isEmpty);
      expect(result.errors.single, contains('Equation'));
      expect(result.errors.single, contains('重複'));
    });

    test(
      'and a duplicated Header, which decides which controller is asked',
      () {
        const csv =
            'Name,ModeAndPID,Equation,Header,Header\r\n'
            'Trans Temp,2211A6,A-40,7E0,7E1\r\n';
        expect(PidCsv.parse(csv).pids, isEmpty);
      },
    );

    test('spelling variants of a column name are the same column', () {
      const csv =
          'name,modeandpid,equation,minvalue,max value\r\n'
          'Trans Temp,2211A6,A-40,-40,215\r\n';
      final result = PidCsv.parse(csv);
      expect(result.errors, isEmpty);
      expect(result.pids.single.minValue, -40);
      expect(result.pids.single.maxValue, 215);
    });
  });
}

/// Files written for Torque Pro, which is where nearly all of these come from.
///
/// torque-bhp.com documents the columns as `Name`, `ShortName`, `ModeAndPID`,
/// `Equation`, `Min Value`, `Max Value`, `Units`, `OBD Header`. The first seven
/// are this app's names exactly; the eighth is not, and the mismatch was
/// silent — the file imported with no errors and every PID quietly addressed
/// to the default `7E0`.
///
/// That is the shape this file exists to prevent. A community set for a
/// transmission (`7E1`) or a body module (`7E2`) does not fail to import; it
/// imports and asks the *engine* the transmission's question. Best case, no
/// data. Worst case `7E0` answers something at that address and the gauge
/// shows a number that looks exactly like the right one.
void _torqueProCompatibility() {
  group('a file written for Torque Pro keeps its addressing', () {
    test('OBD Header is the same column as Header', () {
      // The documented column names, and the documented example row.
      const file =
          'Name,ShortName,ModeAndPID,Equation,Min Value,Max Value,Units,OBD Header\r\n'
          '"Transmission Temperature(Method 3)","Trans","0105","A-40",0,200,"C",""\r\n'
          '"Trans Temp","TT","221E1C","((A*256)+B)/8-40",-40,215,"C","7E1"\r\n';
      final result = PidCsv.parse(file);
      expect(result.errors, isEmpty);
      expect(result.pids, hasLength(2));

      expect(
        result.pids[1].header,
        '7E1',
        reason:
            'this PID is addressed to the transmission; sending it to '
            'the engine is how an imported set produces a plausible wrong '
            'number',
      );
      expect(result.pids[1].modeAndPid, '221E1C');
      expect(result.pids[1].equation, '((A*256)+B)/8-40');

      // The blank-header row is the documented "auto" case and must still fall
      // back rather than fail.
      expect(result.pids[0].header, isNotEmpty);
    });

    test('and the spelling this app exports still wins when both appear', () {
      // Not a real file, but the ambiguity has to resolve somewhere, and a
      // round trip through this app must not be degraded by an alias.
      const file =
          'Name,ModeAndPID,Equation,Header,OBD Header\r\n'
          '"X","0105","A",7E1,7E2\r\n';
      final result = PidCsv.parse(file);
      expect(result.errors, isEmpty);
      expect(result.pids.single.header, '7E1');
    });
  });
}
