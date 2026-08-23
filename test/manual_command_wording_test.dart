/// What the manual command box actually puts on the screen.
///
/// `manual_command_test.dart` pins which commands are refused. This pins what
/// the refusal *reads like*, which is a separate thing and was wrong: the
/// handler stringified the exception, so every refusal arrived as
/// `TransportException: 清除故障碼請用…` — a Dart class name in English in
/// front of a Chinese sentence, on the one screen somebody opens when they are
/// already unsure whether the app is working.
///
/// The app fixed exactly this once before, for handshake failures, where the
/// note in `elm327_client.dart` says: "The sentence, not the identifier." The
/// manual box was the copy that got missed, and nothing could see it because
/// no test looked at the rendered string. Found by typing `04` into the box on
/// a Galaxy S24 Ultra and reading the screen.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/obd/dtc/dtc.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/ui/screens/settings/settings_screen.dart';

String _shown(Object error) => SettingsScreen.describeManualFailure(error);

void main() {
  test('every refusal shows its sentence, not its Dart type', () {
    // Each refusal this box can produce, rendered the way the screen renders
    // it. Mode 04 is the one somebody is likeliest to try from here, and the
    // one whose message has the most to say.
    for (final command in ['04', 'ATZ', 'ZZ', '03\r04', '08', '']) {
      final why = ObdSession.manualCommandRefusal(command);
      expect(why, isNotNull, reason: command);
      final shown = _shown(TransportException(why!));
      expect(shown, why,
          reason: 'the sentence the refusal was written as, and nothing else');
      expect(shown, isNot(contains('Exception')), reason: command);
    }
  });

  test('the not-connected refusal reads as a sentence too', () {
    // The path the box takes when nothing is connected, which is how somebody
    // first meets it.
    expect(_shown(const TransportException('尚未連線')), '尚未連線');
  });

  test('an unexpected type keeps its identifier, which is the useful part',
      () {
    // The over-correction guard. Stripping every type name would hide the one
    // case where the class *is* the diagnosis: something the app never
    // anticipated reaching this screen, on the screen that exists for when
    // things have already gone wrong.
    final shown = _shown(StateError('boom'));
    expect(shown, contains('boom'));
    expect(shown, contains('Bad state'),
        reason: 'an unrecognised failure is exactly when the identifier helps');
  });

  test('a fault-code failure was already safe, for a different reason', () {
    // `DtcReadException` does not reach this box today, and if it ever does it
    // reads correctly anyway — its own `toString` is the message, with no type
    // name in front. That is worth pinning rather than assuming: it is the
    // reason the defect showed up on `TransportException` alone, and the
    // reason a future exception type here would need checking rather than
    // trusting.
    const e = DtcReadException('掃描時有回應無法判斷是哪個控制器送出的');
    expect(_shown(e), isNot(contains('Exception')));
    expect('$e', e.message,
        reason: 'if this ever stops being true, this box needs the same '
            'treatment TransportException got');
  });

  test('the refusal text carries no type name of its own', () {
    // Whatever the widget does with it, the message itself has to be a
    // sentence — a `toString()` creeping into the *message* would satisfy
    // every assertion above.
    for (final command in ['04', 'ATZ', 'ZZ', '03\r04', '08']) {
      final why = ObdSession.manualCommandRefusal(command);
      expect(why, isNotNull, reason: command);
      expect(why, isNot(contains('Exception')), reason: command);
      expect(why, isNot(contains('Instance of')), reason: command);
    }
  });
}
