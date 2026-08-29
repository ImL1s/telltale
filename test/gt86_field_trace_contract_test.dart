/// De-identified regression fixture shaped like the GT86 field session.
///
/// Values below are synthetic. The fixture intentionally contains no VIN,
/// MAC address, UUID, adapter serial number, or other device identifier. What
/// it preserves is only the wire shape that matters to the protocol client:
/// arbitrary notification boundaries, one stray byte after reset, chained
/// support masks, a negative response, and a numbered multi-frame batch.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/polling_engine.dart';
import 'package:torque_obd/obd/telemetry.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';

class _Gt86FieldTraceTransport extends BaseObdTransport {
  _Gt86FieldTraceTransport({this.fuelRateReply = '7F0112'});

  final String fuelRateReply;
  final List<String> commands = [];

  @override
  TransportKind get kind => TransportKind.bluetoothLe;

  @override
  String get displayName => 'De-identified field trace';

  @override
  Future<void> connect() async => setConnected(true);

  @override
  Future<void> disconnect() async => setConnected(false);

  @override
  Future<void> write(List<int> data) async {
    final command = ascii
        .decode(data, allowInvalid: true)
        .trim()
        .replaceAll(' ', '')
        .toUpperCase();
    commands.add(command);

    if (command == 'ATZ') {
      // Literal notification boundary from the field shape: reset echo and
      // one clone byte arrive first, while the banner and prompt arrive in a
      // second notification. 0xFC is neither payload nor an identifier.
      emitBytes([...ascii.encode('ATZ\r'), 0xFC]);
      await Future<void>.delayed(Duration.zero);
      emitBytes(ascii.encode('ELM327 v1.5\r>'));
      return;
    }

    if (command == '015E') {
      emitBytes(ascii.encode('$fuelRateReply\r'));
      await Future<void>.delayed(Duration.zero);
      emitBytes(ascii.encode('>'));
      return;
    }

    if (command == '010C0D04110B10') {
      // Headers-off ELM rendering: a three-hex-digit ISO-TP length followed
      // by numbered segments. The prompt is deliberately its own chunk.
      emitBytes(ascii.encode('00F\r'));
      emitBytes(ascii.encode('0:410C1AF80D00\r'));
      emitBytes(ascii.encode('1:043311200B6410\r'));
      // The ELM pads the last numbered segment past the declared 0x00F-byte
      // payload. Those zeroes must be retained at the framing boundary and
      // then trimmed by the declared length, not treated as another PID.
      emitBytes(ascii.encode('2:01900000000000\r'));
      await Future<void>.delayed(Duration.zero);
      emitBytes(ascii.encode('>'));
      return;
    }

    final reply = switch (command) {
      'ATE0' ||
      'ATL0' ||
      'ATM0' ||
      'ATS0' ||
      'ATAT1' ||
      'ATST66' ||
      'ATSP0' ||
      'ATSH7E0' => 'OK',
      'ATI' => 'ELM327 v1.5',
      'AT@1' => 'Synthetic field fixture',
      'ATRV' => '14.2V',
      'ATDP' => 'AUTO, ISO 15765-4 (CAN 11/500)',
      'ATDPN' => 'A6',
      'ATPPS' => '?',
      '0100' => '4100BE3FA813',
      '0120' => '4120B007B011',
      '0140' => '4140FEDC8051',
      '0160' => '416008000000',
      _ => 'NO DATA',
    };
    emitBytes(ascii.encode('$reply\r>'));
  }
}

void main() {
  Future<PidFault?> pollFuelRate(String reply) async {
    final transport = _Gt86FieldTraceTransport(fuelRateReply: reply);
    final client = Elm327Client(
      transport,
      commandTimeout: const Duration(milliseconds: 500),
    );
    final engine = PollingEngine(client)
      ..setActivePids(const [
        PidLibrary.engineFuelRate,
      ], includeProfileDerivedInputs: false);
    try {
      expect(await client.connect(), isTrue);
      engine.start();
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (engine.current.faults[PidLibrary.engineFuelRate.id] == null &&
          !engine.current.readings.containsKey(PidLibrary.engineFuelRate.id) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      return engine.current.faults[PidLibrary.engineFuelRate.id];
    } finally {
      await engine.dispose();
      await client.dispose();
    }
  }

  test(
    'only an exact complete 7F 01 12 reply is capability evidence',
    () async {
      expect(await pollFuelRate('7F0112'), PidFault.unsupported);
      expect(
        await pollFuelRate('7F0112\r415E0078'),
        isNot(PidFault.unsupported),
        reason: 'one controller refusal cannot hide another positive response',
      );
      expect(
        await pollFuelRate('7F0112DEAD'),
        isNot(PidFault.unsupported),
        reason: 'trailing bytes make the negative response ambiguous',
      );
    },
  );

  test(
    'de-identified GT86 field trace survives the real wire shapes',
    () async {
      final transport = _Gt86FieldTraceTransport();
      final client = Elm327Client(
        transport,
        commandTimeout: const Duration(milliseconds: 500),
      );
      addTearDown(client.dispose);

      expect(await client.connect(), isTrue);
      expect(client.deviceVersion, 'ELM327 v1.5');
      expect(client.protocolNumber, 'A6');
      expect(
        client.transcript.entries.any((entry) => entry.bytes.contains(0xFC)),
        isTrue,
        reason: 'the raw diagnostic transcript must retain the clone byte',
      );

      final unsupportedEngine = PollingEngine(client)
        ..setActivePids(const [
          PidLibrary.engineFuelRate,
        ], includeProfileDerivedInputs: false)
        ..start();
      final unsupportedDeadline = DateTime.now().add(
        const Duration(seconds: 5),
      );
      while (unsupportedEngine.current.faults[PidLibrary.engineFuelRate.id] ==
              null &&
          DateTime.now().isBefore(unsupportedDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        unsupportedEngine.current.faults[PidLibrary.engineFuelRate.id],
        PidFault.unsupported,
        reason: '`7F 01 12` is an unsupported ECU service, not sensor data',
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        transport.commands.where((command) => command == '015E').length,
        1,
        reason: 'unsupported low-rate data must not be retried in a hot loop',
      );
      await unsupportedEngine.dispose();

      final engine = PollingEngine(client);
      final discoveryStart = transport.commands.length;
      final supported = await engine.discoverSupportedPids();
      expect(
        transport.commands
            .sublist(discoveryStart)
            .where(
              (command) => RegExp(r'^01(?:00|20|40|60|80)$').hasMatch(command),
            )
            .toList(),
        const ['0100', '0120', '0140', '0160'],
        reason: 'the final continuation bit is clear, so 0180 is forbidden',
      );
      expect(supported, const {
        '0101',
        '0103',
        '0104',
        '0105',
        '0106',
        '0107',
        '010B',
        '010C',
        '010D',
        '010E',
        '010F',
        '0110',
        '0111',
        '0113',
        '0115',
        '011C',
        '011F',
        '0120',
        '0121',
        '0123',
        '0124',
        '012E',
        '012F',
        '0130',
        '0131',
        '0133',
        '0134',
        '013C',
        '0140',
        '0141',
        '0142',
        '0143',
        '0144',
        '0145',
        '0146',
        '0147',
        '0149',
        '014A',
        '014C',
        '014D',
        '014E',
        '0151',
        '015A',
        '015C',
        '0160',
        '0165',
      });

      final batch = await client.queryPid('010C0D04110B10');
      expect(batch.isSuccess, isTrue);
      expect(batch.bytes, const [
        0x41,
        0x0C,
        0x1A,
        0xF8,
        0x0D,
        0x00,
        0x04,
        0x33,
        0x11,
        0x20,
        0x0B,
        0x64,
        0x10,
        0x01,
        0x90,
      ]);

      final directBatchCount = transport.commands
          .where((command) => command == '010C0D04110B10')
          .length;
      engine
        ..setActivePids(const [
          PidLibrary.engineRpm,
          PidLibrary.vehicleSpeed,
          PidLibrary.engineLoad,
          PidLibrary.throttlePosition,
          PidLibrary.manifoldPressure,
          PidLibrary.mafRate,
        ], includeProfileDerivedInputs: false)
        ..start();
      final batchDeadline = DateTime.now().add(const Duration(seconds: 5));
      while (!const [
            PidLibrary.engineRpm,
            PidLibrary.vehicleSpeed,
            PidLibrary.engineLoad,
            PidLibrary.throttlePosition,
            PidLibrary.manifoldPressure,
            PidLibrary.mafRate,
          ].every((pid) => engine.current.readings.containsKey(pid.id)) &&
          DateTime.now().isBefore(batchDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(engine.current.valueOf(PidLibrary.engineRpm), closeTo(1726, 0.1));
      expect(engine.current.valueOf(PidLibrary.vehicleSpeed), 0);
      expect(engine.current.valueOf(PidLibrary.engineLoad), closeTo(20, 0.1));
      expect(
        engine.current.valueOf(PidLibrary.throttlePosition),
        closeTo(12.55, 0.1),
      );
      expect(engine.current.valueOf(PidLibrary.manifoldPressure), 100);
      expect(engine.current.valueOf(PidLibrary.mafRate), closeTo(4, 0.01));
      expect(
        transport.commands
            .where((command) => command == '010C0D04110B10')
            .length,
        greaterThan(directBatchCount),
        reason: 'PollingEngine must split and publish the real six-PID batch',
      );
      await engine.dispose();
    },
  );
}
