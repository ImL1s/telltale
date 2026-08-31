import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/physics/vehicle_profile.dart';
import 'package:torque_obd/obd/pid/pid.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/telemetry.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_registry.dart';
import 'package:torque_obd/state/settings.dart';
import 'package:torque_obd/state/telemetry_recorder.dart';
import 'package:torque_obd/state/telemetry_sessions.dart';
import 'package:torque_obd/telemetry/session/telemetry_recorder.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';
import 'package:torque_obd/telemetry/session/telemetry_session_codec.dart';

void main() {
  test(
    'replay is isolated from live PID profile and recorder providers',
    () async {
      final documents = await Directory.systemTemp.createTemp(
        'replay-isolated-',
      );
      addTearDown(() => documents.delete(recursive: true));
      const id = '00000000000000000000000000000011';
      await _writeSession(documents, id);

      var liveBuilds = 0;
      var pidBuilds = 0;
      var profileBuilds = 0;
      var recorderBuilds = 0;
      final container = ProviderContainer(
        overrides: [
          telemetrySessionLibraryServiceProvider.overrideWithValue(
            TelemetrySessionLibraryService(
              documentsDirectory: () async => documents,
            ),
          ),
          telemetryProvider.overrideWith((ref) {
            liveBuilds++;
            return Stream.value(const TelemetrySnapshot());
          }),
          activePidsProvider.overrideWith(
            () => _CountingActivePids(() => pidBuilds++),
          ),
          vehicleProfileProvider.overrideWith(
            () => _CountingProfile(() => profileBuilds++),
          ),
          telemetryRecorderProgressProvider.overrideWith(
            () => _CountingProgress(() => recorderBuilds++),
          ),
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(
        telemetrySessionReplayProvider(id).future,
      );

      expect(result.failure, isNull);
      expect(result.replay?.source, TelemetrySource.demo);
      expect(result.replay?.valueCount, 1);
      expect(result.replay?.lanes.single.name, PidLibrary.engineRpm.name);
      expect(liveBuilds, 0);
      expect(pidBuilds, 0);
      expect(profileBuilds, 0);
      expect(recorderBuilds, 0);
    },
  );
}

Future<void> _writeSession(Directory documents, String id) async {
  final started = DateTime.utc(2026, 8, 30, 1);
  final definition = freezePidDefinition(PidLibrary.engineRpm);
  final header = TelemetrySessionHeader(
    sessionId: id,
    startedAtUtc: started,
    source: TelemetrySource.demo,
    transport: TransportKind.demo,
    protocol: 'Demo',
    signals: [definition],
  );
  final events = [
    TelemetryEvent.value(
      observedAtUtc: started.add(const Duration(seconds: 1)),
      sourceTimestampUtc: started.add(const Duration(seconds: 1)),
      elapsedUs: 1000000,
      pidId: definition.definition.id,
      value: 1726,
    ),
  ];
  final prefix = TelemetrySessionCodec.encodePrefix(header, events);
  final session = TelemetrySession(
    header: header,
    events: events,
    footer: TelemetrySessionFooter(
      endedAtUtc: started.add(const Duration(seconds: 2)),
      terminalReason: TelemetryTerminalReason.user,
      valueCount: 1,
      statusCount: 0,
      gapCount: 0,
      bytesBeforeFooter: prefix.length,
    ),
  );
  final root = Directory('${documents.path}/telltale-telemetry');
  await root.create();
  await File('${root.path}/$id.ndjson')
      .writeAsBytes(TelemetrySessionCodec.encode(session));
}

class _CountingActivePids extends ActivePids {
  _CountingActivePids(this.onBuild);

  final void Function() onBuild;

  @override
  List<Pid> build() {
    onBuild();
    return const [PidLibrary.vehicleSpeed];
  }
}

class _CountingProfile extends VehicleProfileController {
  _CountingProfile(this.onBuild);

  final void Function() onBuild;

  @override
  VehicleProfile build() {
    onBuild();
    return const VehicleProfile(massKg: 9999);
  }
}

class _CountingProgress extends TelemetryRecorderProgressNotifier {
  _CountingProgress(this.onBuild);

  final void Function() onBuild;

  @override
  TelemetryRecorderProgress build() {
    onBuild();
    return const TelemetryRecorderProgress(
      state: TelemetryRecorderState.idle(),
      elapsedUs: 0,
      bytesBeforeFooter: 0,
      effectiveSessionLimit: null,
      sessionId: null,
    );
  }
}
