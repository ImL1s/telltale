import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/telemetry.dart';
import 'package:torque_obd/state/app_share_coordinator.dart';
import 'package:torque_obd/state/driving_interaction_safety.dart';
import 'package:torque_obd/state/obd_session.dart';

Reading _speed(double value, DateTime at) => Reading(
  pid: PidLibrary.vehicleSpeed,
  value: value,
  rawBytes: [value.round()],
  timestamp: at,
);

void main() {
  late DateTime now;
  late int monotonicUs;
  late DrivingSafetyInput input;
  late DrivingInteractionSafetyPolicy policy;

  setUp(() {
    now = DateTime.utc(2026, 8, 30);
    monotonicUs = 1000000;
    input = DrivingSafetyInput(
      connectionPhase: ConnectionPhase.disconnected,
      connectionEpoch: 1,
      foreground: true,
      foregroundEpoch: 1,
      recorderBlocksArtifacts: false,
      recorderEpoch: 1,
      telemetry: const TelemetrySnapshot(),
      nowUtc: now,
      monotonicUs: monotonicUs,
    );
    policy = DrivingInteractionSafetyPolicy(() => input);
  });

  test('disconnected Share permit has no elapsed-time expiry', () {
    final permit = policy.freeze();
    expect(permit, isNotNull);
    expect(permit!.connectionClass, ShareConnectionClass.disconnected);

    now = now.add(const Duration(seconds: 30));
    monotonicUs += const Duration(seconds: 30).inMicroseconds;
    input = input.copyWith(nowUtc: now, monotonicUs: monotonicUs);
    expect(policy.validate(permit).isValid, isTrue);

    input = input.copyWith(
      connectionPhase: ConnectionPhase.connected,
      connectionEpoch: 2,
      telemetry: TelemetrySnapshot(
        readings: {PidLibrary.vehicleSpeed.id: _speed(0, now)},
        capturedAt: now,
      ),
    );
    expect(policy.validate(permit).cause, SharePermitCause.connection);
  });

  test('connected Share remains valid across fresh stopped readings', () {
    input = input.copyWith(
      connectionPhase: ConnectionPhase.connected,
      telemetry: TelemetrySnapshot(
        readings: {PidLibrary.vehicleSpeed.id: _speed(0, now)},
        capturedAt: now,
      ),
    );
    final permit = policy.freeze()!;

    for (var second = 1; second <= 8; second++) {
      now = now.add(const Duration(seconds: 1));
      monotonicUs += const Duration(seconds: 1).inMicroseconds;
      input = input.copyWith(
        nowUtc: now,
        monotonicUs: monotonicUs,
        telemetry: TelemetrySnapshot(
          readings: {PidLibrary.vehicleSpeed.id: _speed(2, now)},
          capturedAt: now,
        ),
      );
      expect(
        policy.validate(permit).isValid,
        isTrue,
        reason: 'fresh <=5 readings keep a long preparation authorized',
      );
    }
  });

  test('moving or actually stale speed revokes and cannot heal old permit', () {
    input = input.copyWith(
      connectionPhase: ConnectionPhase.connected,
      telemetry: TelemetrySnapshot(
        readings: {PidLibrary.vehicleSpeed.id: _speed(0, now)},
        capturedAt: now,
      ),
    );
    final permit = policy.freeze()!;

    now = now.add(const Duration(milliseconds: 100));
    input = input.copyWith(
      nowUtc: now,
      telemetry: TelemetrySnapshot(
        readings: {PidLibrary.vehicleSpeed.id: _speed(20, now)},
        capturedAt: now,
      ),
    );
    expect(policy.validate(permit).cause, SharePermitCause.moving);

    now = now.add(const Duration(milliseconds: 100));
    input = input.copyWith(
      nowUtc: now,
      telemetry: TelemetrySnapshot(
        readings: {PidLibrary.vehicleSpeed.id: _speed(0, now)},
        capturedAt: now,
      ),
    );
    expect(
      policy.validate(permit).isValid,
      isFalse,
      reason: 'a moving transition permanently revokes the old permit',
    );

    final freshPermit = policy.freeze()!;
    now = now.add(const Duration(seconds: 3));
    input = input.copyWith(nowUtc: now, telemetry: const TelemetrySnapshot());
    expect(policy.validate(freshPermit).cause, SharePermitCause.speedUnknown);
  });

  test(
    'connected unknown blocks artifact management but disconnected allows',
    () {
      expect(policy.current.canManageArtifacts, isTrue);
      input = input.copyWith(connectionPhase: ConnectionPhase.connected);
      expect(
        policy.current.classification,
        DrivingSafetyClassification.unknown,
      );
      expect(policy.current.canManageArtifacts, isFalse);
      expect(policy.freeze(), isNull);
    },
  );

  test('Start permit accepts a renewed fresh stopped reading', () {
    input = input.copyWith(
      connectionPhase: ConnectionPhase.connected,
      telemetry: TelemetrySnapshot(
        readings: {PidLibrary.vehicleSpeed.id: _speed(0, now)},
        capturedAt: now,
      ),
    );
    final permit = policy.freezeStart();
    expect(permit, isNotNull);

    now = now.add(const Duration(seconds: 3));
    monotonicUs += const Duration(seconds: 3).inMicroseconds;
    input = input.copyWith(
      nowUtc: now,
      monotonicUs: monotonicUs,
      telemetry: TelemetrySnapshot(
        readings: {PidLibrary.vehicleSpeed.id: _speed(3, now)},
        capturedAt: now,
      ),
    );
    expect(policy.validateStart(permit!).isValid, isTrue);
  });

  test('Start permit fails closed while the stopped reading is stale', () {
    input = input.copyWith(
      connectionPhase: ConnectionPhase.connected,
      telemetry: TelemetrySnapshot(
        readings: {PidLibrary.vehicleSpeed.id: _speed(0, now)},
        capturedAt: now,
      ),
    );
    final permit = policy.freezeStart()!;

    now = now.add(const Duration(seconds: 3));
    monotonicUs += const Duration(seconds: 3).inMicroseconds;
    input = input.copyWith(nowUtc: now, monotonicUs: monotonicUs);

    expect(policy.validateStart(permit).cause, SharePermitCause.speedUnknown);
  });

  test('recorder and foreground epochs independently revoke Share', () {
    final permit = policy.freeze()!;
    input = input.copyWith(recorderEpoch: 2, recorderBlocksArtifacts: true);
    expect(policy.validate(permit).cause, SharePermitCause.recorder);

    input = input.copyWith(
      recorderEpoch: 1,
      recorderBlocksArtifacts: false,
      foreground: false,
      foregroundEpoch: 2,
    );
    expect(policy.validate(permit).cause, SharePermitCause.foreground);
  });

  test('future-dated speed fails closed and revokes an existing permit', () {
    input = input.copyWith(
      connectionPhase: ConnectionPhase.connected,
      telemetry: TelemetrySnapshot(
        readings: {PidLibrary.vehicleSpeed.id: _speed(0, now)},
        capturedAt: now,
      ),
    );
    final permit = policy.freeze()!;

    input = input.copyWith(
      telemetry: TelemetrySnapshot(
        readings: {
          PidLibrary.vehicleSpeed.id: _speed(
            0,
            now.add(const Duration(seconds: 1)),
          ),
        },
        capturedAt: now,
      ),
    );
    expect(policy.validate(permit).cause, SharePermitCause.speedUnknown);
    expect(policy.freezeStart(), isNull);
  });
}
