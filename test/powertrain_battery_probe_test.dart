import 'dart:async';
import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/obd/addressing.dart';
import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/powertrain_battery/powertrain_battery_catalog.dart';
import 'package:torque_obd/obd/powertrain_battery/powertrain_battery_probe.dart';
import 'package:torque_obd/obd/powertrain_battery/profile_catalog_validator.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';

import 'support/fake_elm327.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PowertrainBatteryCatalogSnapshot snapshot;

  setUpAll(() async {
    snapshot = await PowertrainBatteryCatalogAsset.load();
  });

  test('only source-scoped executable entries are eligible for one-shot probing', () {
    const validator = PowertrainBatteryProfileCatalogValidator();
    final probeable = snapshot.catalog.profiles
        .where((profile) => validator.validateProfile(profile).canProbe)
        .map((profile) => profile.id)
        .toSet();

    expect(snapshot.profileCount, 210);
    expect(probeable, {
      'mg-zs-ev-au-2021',
      'lexus-rx450hl-2020-source-vehicle',
      'toyota-prius-tnga-2016-2026',
      'hyundai-ioniq5-egmp-2021-2024-community',
      'kia-ev6-egmp-2022-2024-community',
      'hyundai-kona-electric-os-2019-2023-community',
      'kia-niro-ev-de-2019-2022-community',
    });
    expect(
      snapshot.catalog.profiles
          .where((profile) => profile.status.name == 'researchOnly')
          .every((profile) => profile.commands.isEmpty),
      isTrue,
      reason: 'the lab switch must never turn metadata into wire commands',
    );
    expect(
      snapshot.catalog.profiles
          .where((profile) => validator.validateProfile(profile).canInstall)
          .map((profile) => profile.id),
      [
        'mg-zs-ev-au-2021',
        'hyundai-ioniq5-egmp-2021-2024-community',
        'kia-ev6-egmp-2022-2024-community',
        'hyundai-kona-electric-os-2019-2023-community',
        'kia-niro-ev-de-2019-2022-community',
      ],
      reason:
          'only the cross-corroborated community entry may reach the '
          'installer; the experimental entry stays probe-only',
    );
  });

  test('valid exact MG response preserves raw bytes and decoded value', () {
    final profile = snapshot.catalog.profiles.singleWhere(
      (profile) => profile.id == 'mg-zs-ev-au-2021',
    );
    final command = profile.commands.singleWhere(
      (command) => command.modeAndIdentifier == '22B046',
    );
    final result = PowertrainBatteryProbe.decode(
      profile: profile,
      command: command,
      catalogSha256: snapshot.catalogSha256,
      response: const ObdResponse(
        bytes: [0x62, 0xB0, 0x46, 0x01, 0xF4],
        frames: [
          ObdFrame([0x62, 0xB0, 0x46, 0x01, 0xF4], sourceId: '789'),
        ],
        headersEnabled: true,
      ),
    );

    expect(result.passed, isTrue);
    expect(result.responder, '789');
    expect(result.payloadBytes, [0x01, 0xF4]);
    expect(result.readings.single.value, 50);
    expect(result.readings.single.rawBytes, [0x01, 0xF4]);
  });

  test('wrong, anonymous, duplicate, short and extra replies fail closed', () {
    final profile = snapshot.catalog.profiles.singleWhere(
      (profile) => profile.id == 'mg-zs-ev-au-2021',
    );
    final command = profile.commands.singleWhere(
      (command) => command.modeAndIdentifier == '22B046',
    );
    PowertrainBatteryProbeResult decode(ObdResponse response) =>
        PowertrainBatteryProbe.decode(
          profile: profile,
          command: command,
          catalogSha256: snapshot.catalogSha256,
          response: response,
        );

    expect(
      decode(
        const ObdResponse(
          bytes: [0x62, 0xB0, 0x46, 0x01, 0xF4],
          frames: [
            ObdFrame([0x62, 0xB0, 0x46, 0x01, 0xF4]),
          ],
          headersEnabled: true,
        ),
      ).failure,
      PowertrainBatteryProbeFailure.responderMismatch,
    );
    expect(
      decode(
        const ObdResponse(
          bytes: [0x62, 0xB0, 0x46, 0x01, 0xF4],
          frames: [
            ObdFrame([0x62, 0xB0, 0x46, 0x01, 0xF4], sourceId: '7E8'),
          ],
          headersEnabled: true,
        ),
      ).failure,
      PowertrainBatteryProbeFailure.responderMismatch,
    );
    expect(
      decode(
        const ObdResponse(
          frames: [
            ObdFrame([0x62, 0xB0, 0x46, 0x01, 0xF4], sourceId: '789'),
            ObdFrame([0x62, 0xB0, 0x46, 0x01, 0xF4], sourceId: '789'),
          ],
          headersEnabled: true,
        ),
      ).failure,
      PowertrainBatteryProbeFailure.ambiguousResponse,
    );
    for (final bytes in [
      [0x62, 0xB0, 0x46, 0x01],
      [0x62, 0xB0, 0x46, 0x01, 0xF4, 0x00],
    ]) {
      expect(
        decode(
          ObdResponse(
            bytes: bytes,
            frames: [ObdFrame(bytes, sourceId: '789')],
            headersEnabled: true,
          ),
        ).failure,
        PowertrainBatteryProbeFailure.payloadLengthMismatch,
      );
    }
  });

  test(
    'a plausible-looking value outside the source range is not published',
    () {
      final profile = snapshot.catalog.profiles.singleWhere(
        (profile) => profile.id == 'mg-zs-ev-au-2021',
      );
      final command = profile.commands.singleWhere(
        (command) => command.modeAndIdentifier == '22B046',
      );
      final result = PowertrainBatteryProbe.decode(
        profile: profile,
        command: command,
        catalogSha256: snapshot.catalogSha256,
        response: const ObdResponse(
          frames: [
            ObdFrame([0x62, 0xB0, 0x46, 0x03, 0xE9], sourceId: '789'),
          ],
          headersEnabled: true,
        ),
      );

      expect(result.passed, isFalse);
      expect(result.failure, PowertrainBatteryProbeFailure.valueOutOfRange);
      expect(result.readings, isEmpty);
    },
  );

  test('unexpected decoder failure is typed and requires quarantine', () {
    final profile = snapshot.catalog.profiles.singleWhere(
      (profile) => profile.id == 'mg-zs-ev-au-2021',
    );
    final command = profile.commands.singleWhere(
      (command) => command.modeAndIdentifier == '22B046',
    );
    final throwingFrames = _ThrowingSingleFrameList();
    final diagnostics = <_CapturedDiagnostic>[];
    final result = PowertrainBatteryProbe.decode(
      profile: profile,
      command: command,
      catalogSha256: snapshot.catalogSha256,
      response: ObdResponse(frames: throwingFrames, headersEnabled: true),
      diagnosticSink: (exception, stackTrace, context) {
        diagnostics.add(_CapturedDiagnostic(exception, stackTrace, context));
      },
    );

    expect(result.failure, PowertrainBatteryProbeFailure.decoder);
    expect(result.failure!.requiresConnectionQuarantine, isTrue);
    expect(result.detail, isNot(contains('StateError')));
    expect(result.detail, isNot(contains('decoder defect')));
    expect(result.readings, isEmpty);
    expect(diagnostics, hasLength(1));
    expect(diagnostics.single.exception, same(throwingFrames.error));
    expect(
      diagnostics.single.stackTrace.toString(),
      contains('_ThrowingSingleFrameList.[]'),
    );
    expect(diagnostics.single.context, 'decode');
    expect(
      PowertrainBatteryProbeFailure.transport.requiresConnectionQuarantine,
      isFalse,
      reason: 'known communication failures remain distinct and retry-neutral',
    );
  });

  test(
    'unexpected wire failure is internal, sanitized, and not retried',
    () async {
      final profile = snapshot.catalog.profiles.singleWhere(
        (profile) => profile.id == 'mg-zs-ev-au-2021',
      );
      final command = profile.commands.singleWhere(
        (command) => command.modeAndIdentifier == '22B046',
      );
      final client = _UnexpectedWireFailureClient();
      final diagnostics = <_CapturedDiagnostic>[];
      addTearDown(client.dispose);

      final result = await PowertrainBatteryProbe.run(
        client: client,
        snapshot: snapshot,
        profileId: profile.id,
        commandKey: command.wireKey,
        diagnosticSink: (exception, stackTrace, context) {
          diagnostics.add(_CapturedDiagnostic(exception, stackTrace, context));
        },
      );

      expect(result.failure, PowertrainBatteryProbeFailure.internal);
      expect(result.failure!.requiresConnectionQuarantine, isTrue);
      expect(result.detail, isNot(contains('StateError')));
      expect(result.detail, isNot(contains('wire defect')));
      expect(client.sendGlobalCalls, 1, reason: 'the probe never retries');
      expect(diagnostics, hasLength(1));
      expect(diagnostics.single.exception, same(client.error));
      expect(
        diagnostics.single.stackTrace.toString(),
        contains('_UnexpectedWireFailureClient.sendGlobal'),
      );
      expect(diagnostics.single.context, 'sendGlobal');
    },
  );

  test('known transport failures never expose exception text to UI', () async {
    final profile = snapshot.catalog.profiles.singleWhere(
      (profile) => profile.id == 'mg-zs-ev-au-2021',
    );
    final command = profile.commands.singleWhere(
      (command) => command.modeAndIdentifier == '22B046',
    );
    for (final error in <Object>[
      TimeoutException('private timeout detail'),
      const TransportException('private transport detail'),
    ]) {
      final client = _KnownTransportFailureClient(error);
      final diagnostics = <_CapturedDiagnostic>[];
      addTearDown(client.dispose);

      final result = await PowertrainBatteryProbe.run(
        client: client,
        snapshot: snapshot,
        profileId: profile.id,
        commandKey: command.wireKey,
        diagnosticSink: (exception, stackTrace, context) {
          diagnostics.add(_CapturedDiagnostic(exception, stackTrace, context));
        },
      );

      expect(result.failure, PowertrainBatteryProbeFailure.transport);
      expect(result.detail, isNot(contains('private')));
      expect(result.detail, isNot(contains(error.runtimeType.toString())));
      expect(diagnostics, isEmpty);
      expect(client.sendGlobalCalls, 1);
    }
  });

  test('unknown profile/command is refused before any wire request', () async {
    final transport = FakeElm327(protocol: BusProtocol.can11, ecus: const []);
    final client = Elm327Client(
      transport,
      commandTimeout: const Duration(milliseconds: 50),
    );

    final result = await PowertrainBatteryProbe.run(
      client: client,
      snapshot: snapshot,
      profileId: 'forged-profile',
      commandKey: '7E0:7E8:22:FFFF',
    );

    expect(result.failure, PowertrainBatteryProbeFailure.commandNotInProfile);
    expect(
      transport.commandLog.where(
        (command) => command.startsWith('21') || command.startsWith('22'),
      ),
      isEmpty,
    );
  });

  test('CAN-width mismatch is refused before ATSH or probe bytes', () async {
    final profile = snapshot.catalog.profiles.singleWhere(
      (profile) => profile.id == 'mg-zs-ev-au-2021',
    );
    final command = profile.commands.singleWhere(
      (command) => command.modeAndIdentifier == '22B046',
    );
    final transport = FakeElm327(
      protocol: BusProtocol.can29,
      ecus: [
        FakeEcu(
          name: '29-bit ECM',
          requestId: '18DA10F1',
          responseId: '18DAF110',
          responses: const {
            '0100': [0x41, 0x00, 0x80, 0x00, 0x00, 0x00],
          },
        ),
      ],
    );
    final client = Elm327Client(
      transport,
      commandTimeout: const Duration(milliseconds: 50),
    );
    expect(await client.connect(), isTrue);
    final before = transport.commandLog.length;

    final result = await PowertrainBatteryProbe.run(
      client: client,
      snapshot: snapshot,
      profileId: profile.id,
      commandKey: command.wireKey,
    );

    expect(result.failure, PowertrainBatteryProbeFailure.unsupportedBus);
    expect(
      transport.commandLog.skip(before),
      isNot(contains('ATSH${command.requestHeader}')),
    );
    expect(
      transport.commandLog.skip(before),
      isNot(contains(command.modeAndIdentifier)),
    );
    await client.dispose();
  });
}

final class _ThrowingSingleFrameList extends ListBase<ObdFrame> {
  final StateError error = StateError('decoder defect');

  @override
  int get length => 1;

  @override
  set length(int value) => throw UnsupportedError('fixed test list');

  @override
  ObdFrame operator [](int index) => throw error;

  @override
  void operator []=(int index, ObdFrame value) =>
      throw UnsupportedError('fixed test list');
}

final class _UnexpectedWireFailureClient extends Elm327Client {
  _UnexpectedWireFailureClient()
    : super(FakeElm327(protocol: BusProtocol.can11, ecus: const []));

  int sendGlobalCalls = 0;
  final StateError error = StateError('wire defect');

  @override
  BusAddressing get addressing => BusAddressing.forProtocolNumber('6');

  @override
  Future<ObdResponse> sendGlobal(
    String command, {
    Duration? timeout,
    Object? owner,
    DateTime? deadline,
    String? header,
  }) async {
    sendGlobalCalls += 1;
    throw error;
  }
}

final class _KnownTransportFailureClient extends Elm327Client {
  _KnownTransportFailureClient(this.error)
    : super(FakeElm327(protocol: BusProtocol.can11, ecus: const []));

  final Object error;
  int sendGlobalCalls = 0;

  @override
  BusAddressing get addressing => BusAddressing.forProtocolNumber('6');

  @override
  Future<ObdResponse> sendGlobal(
    String command, {
    Duration? timeout,
    Object? owner,
    DateTime? deadline,
    String? header,
  }) async {
    sendGlobalCalls += 1;
    throw error;
  }
}

final class _CapturedDiagnostic {
  const _CapturedDiagnostic(this.exception, this.stackTrace, this.context);

  final Object exception;
  final StackTrace stackTrace;
  final String context;
}
