/// What an unanswered fault-code category is allowed to say.
///
/// Codex rounds 16 to 18 found three wrong sentences here in a row, each
/// because two different facts were being read as one: whether the mandatory
/// class answered, *who* answered this class, and whether anything was
/// decoded. The transcripts below are its, and each one is a sentence the
/// screen used to show beside evidence that contradicted it.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/obd/dtc/dtc.dart';
import 'package:torque_obd/state/dtc_scan.dart';
import 'package:torque_obd/ui/screens/dtc/dtc_screen.dart';

DtcCategoryResult _failed({
  required Set<String> answeredBy,
  List<Dtc> partial = const [],
}) =>
    DtcCategoryResult.failed(DtcReadException(
      '有 1 個控制器沒有回應',
      kind: DtcReadFailure.noAnswer,
      partial: partial,
      terminalSources: answeredBy,
    ));

DtcCategoryResult _pending(Set<String> sources) =>
    DtcCategoryResult.failed(DtcReadException(
      '仍在處理',
      kind: DtcReadFailure.pending,
      pendingSources: sources,
    ));

void main() {
  group('what "heard from" means', () {
    // Codex round 20: every wording test supplied `storedAnswered` by hand, so
    // the production mapping that computes it could regress without any of
    // them noticing. These assert the mapping itself.
    test('R20-codex 04: a partial answer counts as having been heard', () {
      const p0301 = Dtc(
        code: 'P0301',
        category: DtcCategory.powertrain,
        kind: DtcKind.stored,
        sourceId: '7E8',
        isManufacturerSpecific: false,
      );
      // Mode 03 returned a code from `7E8` and failed coverage because `7E9`
      // was silent. It did not *complete*; it was plainly answered.
      final stored =
          _failed(answeredBy: const {'7E8'}, partial: const [p0301]);
      expect(stored.answered, isFalse,
          reason: 'sanity: coverage failed, so it did not complete');
      expect(stored.heardFromAnyone, isTrue,
          reason: 'and the pending card must not be told Mode 03 was silent');
    });

    test('R20-codex 04: "still working" counts too', () {
      final class07 = _pending(const {'7E9'});
      expect(class07.answeredBy, isEmpty);
      expect(class07.partial, isEmpty);
      expect(class07.heardFromAnyone, isTrue,
          reason: 'a controller that said it was still working identified '
              'itself and named the service');

      final wording = unansweredCategoryWording(
        kind: DtcKind.pending,
        result: class07,
        storedAnswered: true,
      );
      expect(wording.ordinarySilence, isFalse,
          reason: 'and that is not "this vehicle does not provide it"');
    });

    test('R20-codex 04: heard about a service through a damaged reply', () {
      const damaged = DtcCategoryResult.failed(DtcReadException(
        '收到的資料不正確',
        kind: DtcReadFailure.error,
        heardAboutService: {'7E9'},
      ));
      expect(damaged.heardFromAnyone, isTrue,
          reason: 'the reply was not readable and the controller answered');
    });

    test('nothing at all is nothing', () {
      final nothing = _failed(answeredBy: const {});
      expect(nothing.heardFromAnyone, isFalse);
    });
  });

  test('nobody answered an optional class, and the mandatory one did', () {
    final wording = unansweredCategoryWording(
      kind: DtcKind.pending,
      result: _failed(answeredBy: const {}),
      storedAnswered: true,
    );
    expect(wording.ordinarySilence, isTrue);
    // Not "this vehicle does not provide the category": `NO DATA` cannot tell
    // an unimplemented service from a reply that was lost, filtered or late,
    // and this headline used to assert the first.
    expect(wording.headline, '這個類別沒有回應');
    expect(wording.detail, isNot(contains('這通常表示目前沒有尚未確認的故障')),
        reason: 'silence is not evidence that there is no fault');
    expect(wording.detail, contains('無法分辨'));
  });

  test('R18-codex 03: one controller answered and another did not', () {
    // No codes and no partial — and Mode 07 was plainly provided, by `7E8`.
    // Calling that "this vehicle does not provide the category" is false
    // twice: it was provided, and what is unknown is one controller's
    // coverage.
    final wording = unansweredCategoryWording(
      kind: DtcKind.pending,
      result: _failed(answeredBy: const {'7E8'}),
      storedAnswered: true,
    );
    expect(wording.ordinarySilence, isFalse);
    expect(wording.headline, '無法確認');
    expect(wording.detail, contains('部分控制器回應'));
    expect(wording.detail, isNot(contains('Mode 03 同樣沒有回應')),
        reason: 'Mode 03 answered; saying otherwise is simply untrue');
    expect(wording.detail, isNot(contains('目前沒有尚未確認的故障')),
        reason: 'and there is no basis for telling anyone there is no fault');
  });

  test('R17-codex 03: a partial code is not an unprovided category', () {
    const p0301 = Dtc(
      code: 'P0301',
      category: DtcCategory.powertrain,
      kind: DtcKind.pending,
      sourceId: '7E8',
      isManufacturerSpecific: false,
    );
    final wording = unansweredCategoryWording(
      kind: DtcKind.pending,
      result: _failed(answeredBy: const {'7E8'}, partial: const [p0301]),
      storedAnswered: true,
    );
    expect(wording.ordinarySilence, isFalse,
        reason: 'the screen renders P0301 directly below this sentence');
    expect(wording.detail, isNot(contains('Mode 03 同樣沒有回應')));
  });

  test('the mandatory class is never ordinary silence', () {
    final wording = unansweredCategoryWording(
      kind: DtcKind.stored,
      result: _failed(answeredBy: const {}),
      storedAnswered: false,
    );
    expect(wording.ordinarySilence, isFalse);
    expect(wording.detail, contains('這與「沒有故障碼」不是同一件事'));
  });

  test('both classes silent says so, and says it is unknown why', () {
    final wording = unansweredCategoryWording(
      kind: DtcKind.permanent,
      result: _failed(answeredBy: const {}),
      storedAnswered: false,
    );
    expect(wording.ordinarySilence, isFalse);
    expect(wording.detail, contains('Mode 03 同樣沒有回應'));
  });
}
