/// Fail-closed handshake proof through the real Wi-Fi transport and TCP fault
/// proxy.
///
/// This is skipped during the ordinary unit suite. CI and the documented local
/// harness enable one deterministic fault at a time against Ircama's independent
/// ELM327 emulator:
///
///     flutter test test/chaos_oracle_test.dart \
///       --dart-define=CHAOS_ORACLE=true \
///       --dart-define=CHAOS_ORACLE_PORT=35001 \
///       --dart-define=CHAOS_FAULT=close
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/polling_engine.dart';
import 'package:torque_obd/obd/transport/wifi_transport.dart';

const _enabled = bool.fromEnvironment('CHAOS_ORACLE');
const _host = '127.0.0.1';
const _port = int.fromEnvironment('CHAOS_ORACLE_PORT', defaultValue: 35001);
const _fault = String.fromEnvironment('CHAOS_FAULT');

const _expectedFailureCommand = <String, String>{
  'close': 'ATE0',
  'no_prompt': 'ATE0',
  'corrupt': 'ATSP0',
};

void main() {
  test('critical handshake faults fail closed through the TCP proxy', () async {
    if (!_enabled) {
      markTestSkipped(
        'Start Ircama and the chaos proxy, then set CHAOS_ORACLE=true.',
      );
      return;
    }

    final expectedCommand = _expectedFailureCommand[_fault];
    expect(
      expectedCommand,
      isNotNull,
      reason: 'CHAOS_FAULT must be close, no_prompt, or corrupt; got "$_fault"',
    );

    final transport = WifiTransport(host: _host, port: _port);
    final client = Elm327Client(transport);
    addTearDown(client.dispose);
    final poller = PollingEngine(client);
    addTearDown(poller.dispose);

    final progress = <int, InitProgress>{};
    final progressFinished = Completer<void>();
    final subscription = client.initProgress.listen((event) {
      progress[event.index] = event;
      if (event.index == Elm327Client.initSequence.length - 1 &&
          event.status != InitStatus.running &&
          !progressFinished.isCompleted) {
        progressFinished.complete();
      }
    });
    addTearDown(subscription.cancel);

    final connected = await client.connect().timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw TimeoutException(
        'handshake did not fail within the oracle deadline',
        const Duration(seconds: 15),
      ),
    );
    await progressFinished.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () => throw TimeoutException(
        'the terminal init progress event was not delivered',
        const Duration(seconds: 2),
      ),
    );

    final failed = progress.values
        .where((event) => event.status == InitStatus.failed)
        .toList();
    final trace = progress.values
        .map(
          (event) =>
              '${event.step.command}=${event.status.name}'
              '${event.detail == null ? '' : '(${event.detail})'}',
        )
        .join(', ');

    expect(connected, isFalse, reason: 'handshake trace: $trace');
    expect(client.isInitialized, isFalse, reason: 'handshake trace: $trace');
    expect(
      poller.current.readings,
      isEmpty,
      reason: 'a failed handshake accepts zero structured telemetry values',
    );
    expect(
      poller.isRunning,
      isFalse,
      reason: 'no recording/polling was invented',
    );
    expect(
      progress.keys,
      orderedEquals(
        List<int>.generate(Elm327Client.initSequence.length, (index) => index),
      ),
      reason: 'every init step must reach a terminal state: $trace',
    );
    expect(failed, hasLength(1), reason: 'handshake trace: $trace');
    expect(
      failed.single.step.command,
      expectedCommand,
      reason: 'handshake trace: $trace',
    );
    expect(
      progress.values
          .where((event) => event.index > failed.single.index)
          .every((event) => event.status == InitStatus.skipped),
      isTrue,
      reason:
          'commands after a critical failure must not reach the adapter: '
          '$trace',
    );
    expect(failed.single.detail, switch (_fault) {
      'close' => 'TransportException: 連線已中斷。',
      'corrupt' => '轉接器未確認此指令',
      _ => '逾時',
    }, reason: 'the injected fault must be the observed failure: $trace');
    expect(
      transport.isConnected,
      _fault != 'close',
      reason: _fault == 'close'
          ? 'peer EOF must clear Wi-Fi transport connection state'
          : 'a damaged response must not masquerade as a TCP disconnect',
    );
  });
}
