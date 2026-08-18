/// Tapping 中斷連線 while a command is still on the wire.
///
/// `disconnect` fails whatever is in flight. That has two halves, and only one
/// of them can be held here.
///
/// **The half this file guards:** a caller who *is* waiting must be told. The
/// fix for the other half marks the pending future as handled, and the obvious
/// way to write that — swallow the error — would leave a scan hanging forever
/// on a link that is already gone. Mutation-checked: make `_failPending` return
/// without completing and this times out.
///
/// **The half it does not:** the unhandled-error escape itself. Some of what is
/// in flight at teardown is not something a caller is waiting on, and failing
/// *that* future made Dart report an unhandled asynchronous exception — a red
/// screen in debug, a logged crash in release, from the ordinary act of
/// disconnecting after a scan. I could not reproduce it against the in-repo
/// fake: slowing the header restore that trails a `sendGlobal` looked like the
/// path and is not, and the test written that way passed with the fix reverted.
/// It reproduces reliably against the third-party server in
/// `freeze_frame_oracle_test.dart`, which goes red without the fix and green
/// with it.
///
/// So the guard for that half is an integration test that skips unless a server
/// is running. That is worth saying out loud rather than leaving a
/// nothing-proving unit test here to look like coverage: if `_failPending`
/// changes, run the oracle test.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/obd/elm327_client.dart';

import 'support/fake_elm327.dart';

FakeElm327 _adapter({Map<String, Duration> slow = const {}}) {
  final fake = FakeElm327(
    protocol: BusProtocol.can11,
    ecus: [
      FakeEcu(
        name: 'ECM',
        requestId: '7E0',
        responseId: '7E8',
        responses: {
          '0100': [0x41, 0x00, 0x00, 0x08, 0x00, 0x00],
          '0101': [0x41, 0x01, 0x81, 0x07, 0x65, 0x04],
        },
      ),
    ],
  );
  fake.slowCommands.addAll(slow);
  return fake;
}

void main() {
  test('a caller still waiting is told, rather than silenced', () async {
    // The reason the fix is `ignore()` and not a swallow: marking the future
    // handled must not stop the failure reaching somebody who asked for it. A
    // disconnect that left a caller's command hanging — or worse, resolved it
    // as a success — would be a worse bug than the crash it replaced.
    final client = Elm327Client(
      _adapter(slow: {'0101': const Duration(seconds: 4)}),
    );
    expect(await client.connect(), isTrue);

    final inFlight = client.sendGlobal('0101');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await client.dispose();

    await expectLater(inFlight, throwsA(isA<Exception>()));
  });
}
