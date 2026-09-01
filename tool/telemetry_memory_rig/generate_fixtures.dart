import 'dart:io';

import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/telemetry/session/telemetry_recorder.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_codec.dart';

const _mib = 1024 * 1024;
// Kept under a static contract test against TelemetryQuota.footerReserveBytes.
const _footerReserveBytes = 2048;
const _sessionId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2 || arguments.first != '--output') {
    stderr.writeln('usage: dart generate_fixtures.dart --output <directory>');
    exitCode = 64;
    return;
  }
  final output = Directory(arguments[1]);
  if (await output.exists()) await output.delete(recursive: true);
  await output.create(recursive: true);

  final indexBytes = await _createIndexFixture(output);
  final session = await _createSessionFixture(output);
  final recoveredBytes = await _createRecoveredTranscript(output);
  stdout.writeln(
    'TELLTALE_MEMORY_HOST_FIXTURES_READY '
    'indexBytes=$indexBytes sessionBytes=${session.bytes} '
    'values=${session.values} session=$_sessionId '
    'recoveredBytes=$recoveredBytes',
  );
}

Future<int> _createRecoveredTranscript(Directory output) async {
  final file = File('${output.path}/last-session.log');
  final sink = file.openWrite();
  sink.write(
    '2026-08-30T00:00:00.000Z\n'
    '#### HARDWARE 0\n'
    'Memory rig recovered transcript\n'
    '#### TRANSCRIPT ####\n',
  );
  final line = List<int>.filled(1024, 0x41)..[1023] = 0x0a;
  for (var written = 0; written < 2 * _mib; written += line.length) {
    sink.add(line);
  }
  await sink.flush();
  await sink.close();
  return file.length();
}

Future<int> _createIndexFixture(Directory output) async {
  final root = Directory(
    '${output.path}/telltale-memory-rig/index-documents/telltale-telemetry',
  );
  await root.create(recursive: true);
  final zeroChunk = List<int>.filled(64 * 1024, 0);
  for (var index = 0; index < 20; index++) {
    final id = index.toRadixString(16).padLeft(32, '0');
    final handle = File('${root.path}/$id.ndjson')
        .openSync(mode: FileMode.write);
    for (var written = 0; written < 5 * _mib; written += zeroChunk.length) {
      handle.writeFromSync(zeroChunk);
    }
    handle.closeSync();
  }
  return 100 * _mib;
}

Future<({int bytes, int values})> _createSessionFixture(
  Directory output,
) async {
  final started = DateTime.utc(2026, 8, 30);
  final signals = [
    freezePidDefinition(PidLibrary.engineRpm),
    freezePidDefinition(PidLibrary.vehicleSpeed),
    freezePidDefinition(PidLibrary.coolantTemp),
    freezePidDefinition(PidLibrary.throttlePosition),
  ];
  final header = TelemetrySessionHeader(
    sessionId: _sessionId,
    startedAtUtc: started,
    source: TelemetrySource.demo,
    transport: TransportKind.demo,
    protocol: 'ISO 15765-4 CAN',
    signals: signals,
  );
  final root = Directory('${output.path}/telltale-telemetry');
  await root.create(recursive: true);
  final file = File('${root.path}/$_sessionId.ndjson');
  final handle = await file.open(mode: FileMode.write);
  var bytesBeforeFooter = 0;
  var values = 0;
  try {
    final headerLine = TelemetrySessionCodec.encodeHeaderLine(header);
    await handle.writeFrom(headerLine);
    bytesBeforeFooter += headerLine.length;
    const target = 25 * _mib - _footerReserveBytes;
    while (bytesBeforeFooter < target) {
      final elapsed = values * 1000;
      final signal = signals[values % signals.length];
      final line = TelemetrySessionCodec.encodeEventLine(
        TelemetryEvent.value(
          observedAtUtc: started.add(Duration(microseconds: elapsed)),
          sourceTimestampUtc: started.add(Duration(microseconds: elapsed)),
          elapsedUs: elapsed,
          pidId: signal.definition.id,
          value: (values % 8000).toDouble(),
        ),
      );
      await handle.writeFrom(line);
      bytesBeforeFooter += line.length;
      values++;
    }
    await handle.writeFrom(
      TelemetrySessionCodec.encodeFooterLine(
        TelemetrySessionFooter(
          endedAtUtc: started.add(Duration(microseconds: values * 1000)),
          terminalReason: TelemetryTerminalReason.user,
          valueCount: values,
          statusCount: 0,
          gapCount: 0,
          bytesBeforeFooter: bytesBeforeFooter,
        ),
      ),
    );
    await handle.flush();
  } finally {
    await handle.close();
  }
  final bytes = await file.length();
  if (bytes < 25 * _mib - 2048 || bytes > 25 * _mib) {
    throw StateError('unexpected canonical session size: $bytes');
  }
  return (bytes: bytes, values: values);
}
