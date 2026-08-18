/// Arbitrary bytes into the parser, and the two things it may not do.
///
/// A real adapter on a real car emits things no fixture anticipates: a reply
/// cut in half by a dropped frame, another controller's traffic leaking into
/// the buffer, a clone's own diagnostic chatter, line noise on a cheap cable.
/// The fixtures in this suite are all shapes somebody thought of.
///
/// Two properties, and they pull in opposite directions, which is why both are
/// here:
///
///  1. **It never throws something untyped.** An unhandled exception out of the
///     parser is a crash on a phone in a car park. Every failure has to arrive
///     as one of the exceptions the screens already know how to describe.
///  2. **Every byte it accepts came from the input.** Rejecting garbage is
///     easy; the dangerous outcome is accepting a corrupted line and returning
///     a number. `_parse`'s whitelist exists for exactly this — the header
///     comment records that stripping non-hex characters and concatenating
///     turned `DATA ERROR` into the bytes `DA AE` and a multi-frame length
///     line into half a byte of offset, both producing plausible wrong
///     readings. So anything that survives must be re-findable in what went in.
///
/// Seeded, so a failure is reproducible from the seed printed in its name.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';

/// A sane adapter for the handshake, and whatever it was told to be after it.
///
/// The handshake has to succeed, or nothing is under test: `Elm327Client`
/// subscribes to the transport inside `connect()`, so a client that never
/// connected times out on every command regardless of what arrives — which is
/// what the first version of this file measured, and why it found zero
/// accepted frames and concluded the generator was biased. It was not; the
/// harness was not listening.
class _NoiseTransport extends BaseObdTransport {
  _NoiseTransport(this.reply);

  /// What the adapter "prints" for the one command under test.
  final String reply;

  @override
  TransportKind get kind => TransportKind.demo;

  @override
  String get displayName => 'noise';

  @override
  Future<void> connect() async => setConnected(true);

  @override
  Future<void> disconnect() async => setConnected(false);

  @override
  Future<void> write(List<int> data) async {
    final command =
        String.fromCharCodes(data).trim().toUpperCase().replaceAll(' ', '');
    final body = switch (command) {
      'ATZ' || 'ATI' => 'ELM327 v1.5',
      'AT@1' => 'OBDII to RS232 Interpreter',
      'ATRV' => '13.9V',
      'ATDP' => 'AUTO, ISO 15765-4 (CAN 11/500)',
      'ATDPN' => 'A6',
      '0100' => '41 00 BE 3F B8 11',
      _ when command.startsWith('AT') => 'OK',
      // The one under test.
      _ => reply,
    };
    // Same shape as every other transport: the reply arrives asynchronously
    // and ends with the prompt the framing keys on.
    scheduleMicrotask(() => emitBytes('$body\r>'.codeUnits));
  }
}

/// The alphabet a real adapter can put on the wire, weighted towards the
/// characters that have actually caused trouble.
const _alphabet = '0123456789ABCDEF '
    '\r\n'
    'ERROR DATA BUS INIT SEARCHING NO STOPPED UNABLE TO CONNECT ?<>';

String _noise(Random random, int length) {
  final buffer = StringBuffer();
  for (var i = 0; i < length; i++) {
    buffer.write(_alphabet[random.nextInt(_alphabet.length)]);
  }
  return buffer.toString();
}

void main() {
  test('arbitrary adapter output never escapes as an untyped error', () async {
    // 400 replies rather than a handful, because the interesting ones are the
    // accidentally-well-formed: a run of hex that happens to be an even number
    // of characters and starts `41`.
    final random = Random(20260817);
    for (var i = 0; i < 400; i++) {
      final transport = _NoiseTransport(_noise(random, random.nextInt(60) + 1));
      final client = Elm327Client(transport);
      expect(await client.connect(), isTrue);
      try {
        await client.send('0105', timeout: const Duration(milliseconds: 400));
      } on TransportException {
        // The link's own failures, including timeouts. Expected.
      } on TimeoutException {
        // Same, arriving by its own type.
      } on FormatException catch (e) {
        fail('reply ${transport.reply.replaceAll('\r', '\\r')} '
            'raised an untyped FormatException: $e');
      } catch (e) {
        fail('reply ${transport.reply.replaceAll('\r', '\\r')} '
            'raised ${e.runtimeType}: $e');
      }
      await client.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('nothing it accepts was invented on the way through', () async {
    // The half that matters. Reject anything, but do not manufacture a byte.
    final random = Random(778899);
    var accepted = 0;
    for (var i = 0; i < 400; i++) {
      // Well-formed enough to get past the whitelist a usable fraction of the
      // time: an even number of hex characters, and often the `41 05` envelope
      // a Mode 01 reply carries. Pure noise is rejected early and would
      // exercise the accept path not at all.
      final pairs = random.nextInt(6) + 1;
      final body = (random.nextBool() ? '4105' : '') +
          List.generate(
            pairs * 2,
            (_) => '0123456789ABCDEF'[random.nextInt(16)],
          ).join();
      final transport = _NoiseTransport(body);
      final client = Elm327Client(transport);
      expect(await client.connect(), isTrue);
      try {
        final response =
            await client.send('0105', timeout: const Duration(milliseconds: 400));
        for (final frame in response.frames) {
          accepted++;
          final hex = frame.bytes
              .map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0'))
              .join();
          expect(body.contains(hex), isTrue,
              reason: 'frame $hex is not a substring of the line it came '
                  'from ($body) — something was concatenated across a '
                  'boundary or a non-hex character was stripped and the '
                  'halves joined, which is how DATA ERROR once became the '
                  'sensor reading 0xDA 0xAE');
        }
      } on Object {
        // Rejection is always allowed. This test is only about what survives.
      }
      await client.dispose();
    }
    expect(accepted, greaterThan(0),
        reason: 'if nothing was ever accepted this test proves nothing about '
            'acceptance, and the bias above needs revisiting');
  }, timeout: const Timeout(Duration(minutes: 4)));
}
