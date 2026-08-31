import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/pid/pid.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/polling_engine.dart';

import 'support/fake_elm327.dart';

Future<PollingEngine> _connect(FakeElm327 transport) async {
  final client = Elm327Client(
    transport,
    commandTimeout: const Duration(milliseconds: 200),
    responsePendingTimeout: const Duration(milliseconds: 280),
  );
  expect(await client.connect(), isTrue);
  return PollingEngine(client);
}

void main() {
  test('summary is immutable and separates exact evidence from coverage', () {
    final verified = <String>{'0100'};
    final supported = <String>{'010C', '0120'};
    final directlyAnswered = <String>{};
    final summary = ObdCapabilitySummary(
      phase: ObdCapabilityDiscoveryPhase.attemptFinished,
      verifiedBlockIds: verified,
      supportedMode01Requests: supported,
      directlyAnsweredDefinitionIds: directlyAnswered,
    );

    verified.add('0120');
    supported.add('0105');
    directlyAnswered.add(PidLibrary.coolantTemp.id);

    expect(summary.verifiedBlockIds, {'0100'});
    expect(
      summary.statusFor(PidLibrary.engineRpm),
      PidCapabilityStatus.positive,
    );
    expect(
      summary.statusFor(PidLibrary.coolantTemp),
      PidCapabilityStatus.unsupported,
    );
    expect(summary.contiguousVerifiedBlockIds, ['0100']);
    expect(summary.contiguousCoverageThroughPid, 0x20);
    expect(summary.contiguousCoverageReachedVerifiedTerminal, isFalse);
    expect(summary.unknownOrUnverifiedBlockCount, 3);
    expect(() => summary.verifiedBlockIds.add('0120'), throwsUnsupportedError);
  });

  test('a direct answer promotes only its exact definition', () {
    const directlyAnsweredVariant = Pid(
      name: 'Direct variant',
      shortName: 'Direct',
      modeAndPid: '0121',
      equation: 'A',
      minValue: 0,
      maxValue: 255,
      units: '',
      variant: 'direct',
    );
    const sibling = Pid(
      name: 'Sibling',
      shortName: 'Sibling',
      modeAndPid: '0121',
      equation: 'A*2',
      minValue: 0,
      maxValue: 510,
      units: '',
      variant: 'sibling',
    );
    final summary = ObdCapabilitySummary(
      phase: ObdCapabilityDiscoveryPhase.interrupted,
      verifiedBlockIds: const <String>{},
      supportedMode01Requests: const <String>{},
      directlyAnsweredDefinitionIds: const <String>{'7E0:0121#direct'},
    );

    expect(
      summary.statusFor(directlyAnsweredVariant),
      PidCapabilityStatus.positive,
    );
    expect(summary.statusFor(sibling), PidCapabilityStatus.unknown);
    expect(summary.contiguousVerifiedBlockIds, isEmpty);
    expect(summary.contiguousCoverageThroughPid, isNull);
  });

  test('verified terminal makes later published blocks irrelevant', () {
    final summary = ObdCapabilitySummary(
      phase: ObdCapabilityDiscoveryPhase.attemptFinished,
      verifiedBlockIds: const <String>{'0100', '0140'},
      supportedMode01Requests: const <String>{'010C'},
      directlyAnsweredDefinitionIds: const <String>{},
    );

    expect(summary.contiguousVerifiedBlockIds, ['0100']);
    expect(summary.contiguousCoverageReachedVerifiedTerminal, isTrue);
    expect(summary.unknownOrUnverifiedBlockCount, 0);
  });

  test('interrupt retires an in-flight block without committing it', () async {
    final transport = FakeElm327(
      protocol: BusProtocol.can11,
      ecus: [
        FakeEcu(
          name: 'ECM',
          requestId: '7E0',
          responseId: '7E8',
          responses: const {
            '0100': [0x41, 0x00, 0x00, 0x18, 0x00, 0x00],
          },
        ),
      ],
    );
    final engine = await _connect(transport);
    addTearDown(engine.dispose);
    transport.slowCommands['0100'] = const Duration(milliseconds: 80);

    final discovery = engine.discoverSupportedPids();
    expect(engine.capabilitySummary.phase, ObdCapabilityDiscoveryPhase.running);
    engine.interruptCapabilityDiscovery();
    await discovery;

    final summary = engine.capabilitySummary;
    expect(summary.phase, ObdCapabilityDiscoveryPhase.interrupted);
    expect(summary.verifiedBlockIds, isEmpty);
    expect(
      summary.statusFor(PidLibrary.engineRpm),
      PidCapabilityStatus.unknown,
    );
  });

  test('successful attempt publishes verified terminal coverage', () async {
    final transport = FakeElm327(
      protocol: BusProtocol.can11,
      ecus: [
        FakeEcu(
          name: 'ECM',
          requestId: '7E0',
          responseId: '7E8',
          responses: const {
            '0100': [0x41, 0x00, 0x00, 0x18, 0x00, 0x00],
          },
        ),
      ],
    );
    final engine = await _connect(transport);
    addTearDown(engine.dispose);
    final phases = <ObdCapabilityDiscoveryPhase>[];
    final subscription = engine.capabilitySummaries.listen(
      (summary) => phases.add(summary.phase),
    );
    addTearDown(subscription.cancel);

    expect(
      engine.capabilitySummary.phase,
      ObdCapabilityDiscoveryPhase.notStarted,
    );
    await engine.discoverSupportedPids();

    final summary = engine.capabilitySummary;
    expect(summary.phase, ObdCapabilityDiscoveryPhase.attemptFinished);
    expect(summary.verifiedBlockIds, {'0100'});
    expect(summary.unknownOrUnverifiedBlockCount, 0);
    expect(summary.contiguousCoverageReachedVerifiedTerminal, isTrue);
    expect(
      summary.statusFor(PidLibrary.engineRpm),
      PidCapabilityStatus.positive,
    );
    expect(
      summary.statusFor(PidLibrary.coolantTemp),
      PidCapabilityStatus.unsupported,
    );
    expect(phases, [
      ObdCapabilityDiscoveryPhase.running,
      ObdCapabilityDiscoveryPhase.running,
      ObdCapabilityDiscoveryPhase.attemptFinished,
    ], reason: 'UI observes the start, evidence commit, and terminal phase');
  });
}
