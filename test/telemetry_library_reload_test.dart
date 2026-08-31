import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/state/telemetry_recorder.dart';
import 'package:torque_obd/state/telemetry_sessions.dart';
import 'package:torque_obd/telemetry/session/telemetry_recorder.dart';

/// Start used to key `telemetrySessionLibraryProvider` on `(phase, sessionId)`,
/// so preparing → recording launched a full library Isolate scan while the
/// writer was opening. Refresh must wait until the recorder settles.
void main() {
  test('active recorder phases block library reload keys', () {
    expect(
      telemetryRecorderPhaseBlocksLibraryReload(
        TelemetryRecorderPhase.preparing,
      ),
      isTrue,
    );
    expect(
      telemetryRecorderPhaseBlocksLibraryReload(
        TelemetryRecorderPhase.recording,
      ),
      isTrue,
    );
    expect(
      telemetryRecorderPhaseBlocksLibraryReload(
        TelemetryRecorderPhase.finalizing,
      ),
      isTrue,
    );
    expect(
      telemetryRecorderPhaseBlocksLibraryReload(TelemetryRecorderPhase.idle),
      isFalse,
    );
  });

  test('library reloads only after an active recorder settles', () async {
    var loads = 0;
    final service = TelemetrySessionLibraryService(
      loader: () async {
        loads++;
        return const TelemetrySessionLibrary(
          sessions: [],
          damaged: [],
          groupCount: 0,
          recognizedBytes: 0,
          omittedCount: 0,
          encodedProjectionBytes: 0,
          workerDebugName: 'counting-library-service',
        );
      },
    );
    final progress = _MutableProgressNotifier(
      const TelemetryRecorderProgress(
        state: TelemetryRecorderState(phase: TelemetryRecorderPhase.idle),
        elapsedUs: 0,
        bytesBeforeFooter: 0,
        effectiveSessionLimit: null,
        sessionId: null,
      ),
    );

    final container = ProviderContainer(
      overrides: [
        telemetrySessionLibraryServiceProvider.overrideWithValue(service),
        telemetryRecorderProgressProvider.overrideWith(() => progress),
      ],
    );
    addTearDown(container.dispose);

    await container.read(telemetrySessionLibraryProvider.future);
    expect(loads, 1);

    progress.set(
      const TelemetryRecorderProgress(
        state: TelemetryRecorderState(phase: TelemetryRecorderPhase.preparing),
        elapsedUs: 0,
        bytesBeforeFooter: 0,
        effectiveSessionLimit: null,
        sessionId: null,
      ),
    );
    await pumpEventQueue();
    expect(loads, 1, reason: 'preparing must not rescan');

    progress.set(
      const TelemetryRecorderProgress(
        state: TelemetryRecorderState(phase: TelemetryRecorderPhase.recording),
        elapsedUs: 1,
        bytesBeforeFooter: 64,
        effectiveSessionLimit: 1024 * 1024,
        sessionId: 'session-while-writing',
      ),
    );
    await pumpEventQueue();
    expect(loads, 1, reason: 'recording/sessionId must not rescan');

    progress.set(
      const TelemetryRecorderProgress(
        state: TelemetryRecorderState(phase: TelemetryRecorderPhase.finalizing),
        elapsedUs: 2,
        bytesBeforeFooter: 128,
        effectiveSessionLimit: 1024 * 1024,
        sessionId: 'session-while-writing',
      ),
    );
    await pumpEventQueue();
    expect(loads, 1, reason: 'finalizing must not rescan');

    progress.set(
      const TelemetryRecorderProgress(
        state: TelemetryRecorderState(phase: TelemetryRecorderPhase.idle),
        elapsedUs: 0,
        bytesBeforeFooter: 0,
        effectiveSessionLimit: null,
        sessionId: null,
      ),
    );
    await container.read(telemetrySessionLibraryProvider.future);
    expect(loads, 2, reason: 'settled idle must refresh history');
  });
}

final class _MutableProgressNotifier extends TelemetryRecorderProgressNotifier {
  _MutableProgressNotifier(this._value);

  TelemetryRecorderProgress _value;

  @override
  TelemetryRecorderProgress build() => _value;

  void set(TelemetryRecorderProgress next) {
    _value = next;
    state = next;
  }
}
