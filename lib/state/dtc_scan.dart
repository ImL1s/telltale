/// Fault-code scan results, held for the life of the connection.
///
/// This used to live in `_DtcScreenState`. The shell is an ordinary
/// `ShellRoute` driven by `context.go`, so switching tabs disposes the screen —
/// and a scan that takes ten seconds on a real car did not survive a glance at
/// the dashboard. Verified on a device: scan, tap 性能, tap back, "尚未掃描".
///
/// Widget-local state did buy one important property, and it is kept here
/// deliberately: results must never outlive the connection that produced them.
/// A verdict about the car in front of you is not a verdict about the next one,
/// and a stale green panel is the single most dangerous thing this screen can
/// show. The notifier clears itself the moment the session stops being
/// connected.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../obd/dtc/dtc.dart';
import '../obd/freeze_frame.dart';
import '../obd/polling_engine.dart';
import '../obd/transport/obd_transport.dart';
import 'obd_session.dart';

/// One code class's outcome: the codes it returned, or why it could not answer.
class DtcCategoryResult {
  const DtcCategoryResult.codes(this.codes) : failure = null;
  const DtcCategoryResult.failed(this.failure) : codes = const [];

  final List<Dtc> codes;
  final DtcReadException? failure;

  bool get answered => failure == null;

  /// Silence on an optional class is ordinary — Mode 0A is not universal
  /// before about 2012. On Mode 03 it means the question went unanswered,
  /// which is not the same as the car being clean.
  bool get isSilence => failure?.kind == DtcReadFailure.noAnswer;

  /// Codes read before a scan had to be abandoned.
  ///
  /// A category where one controller answered and another refused has produced
  /// real faults *and* an unknown remainder. Both are shown.
  List<Dtc> get partial => failure?.partial ?? const [];

  /// Controllers that gave this category a terminal answer.
  ///
  /// Distinct from [partial], which is what was *decoded*. A category can be
  /// answered by one controller and produce no codes at all, and "nobody
  /// answered" is the only state that justifies telling someone their vehicle
  /// does not provide it.
  Set<String> get answeredBy => failure?.terminalSources ?? const {};

  /// Whether any controller was heard from at all.
  ///
  /// Not the same as [answered], which is true only when the category
  /// *completed*. A Mode 03 that one controller answered with P0301 while
  /// another stayed silent has failed coverage and has plainly been answered,
  /// and passing `answered` where this was meant told the pending card that
  /// Mode 03 was silent — on a screen rendering that P0301 a few lines below.
  ///
  /// Controllers that said they were still working count: they identified
  /// themselves and named the service.
  bool get heardFromAnyone =>
      answered ||
      answeredBy.isNotEmpty ||
      partial.isNotEmpty ||
      (failure?.pendingSources.isNotEmpty ?? false) ||
      // A reply the adapter marked as damaged is not data, and the controller
      // that printed a response for this service into it did answer. Saying
      // otherwise contradicts what is on the wire.
      (failure?.heardAboutService.isNotEmpty ?? false);
}

class DtcScanState {
  const DtcScanState({
    this.results = const {},
    this.scannedAt,
    this.vin,
    this.error,
    this.loading = false,
    this.optionalNotCovered = const {},
    this.clearing = false,
    this.clearMessage,
    this.clearWorked = false,
    this.clearRepeatWouldHarm = false,
    this.mil,
    this.freezeFrames = const [],
    this.freezeFrameUnread = false,
  });

  final Map<DtcKind, DtcCategoryResult> results;

  /// When these results were obtained. Null means nothing valid is on screen —
  /// including after a scan that failed, so a previous verdict cannot outlive
  /// the attempt to refresh it.
  final DateTime? scannedAt;

  final String? vin;
  final String? error;
  final bool loading;

  bool get hasScanned => scannedAt != null;

  /// Every fault this scan actually observed, complete coverage or not.
  ///
  /// Codes read before a category had to be abandoned were retained on the
  /// exception, exposed on the result — and then counted by nobody. A real
  /// P0300 from a named controller could sit in memory while the screen said
  /// 已回應的項目沒有故障碼, because coverage was incomplete and the count only
  /// looked at complete categories. Observation and coverage are different
  /// questions and both have to be answered.
  int get totalCodes => results.values
      .fold(0, (sum, r) => sum + r.codes.length + r.partial.length);

  /// Classes that did not answer this time round.
  List<MapEntry<DtcKind, DtcCategoryResult>> get unanswered =>
      results.entries.where((e) => !e.value.answered).toList(growable: false);

  /// Controllers an optional class did not reach, by class. Empty when every
  /// class was answered by every known controller.
  final Map<DtcKind, Set<String>> optionalNotCovered;

  /// The vehicle's own summary: the fault lamp, and the emissions readiness
  /// monitors, per controller.
  ///
  /// Already read during every scan to question the categories' conclusions —
  /// a controller claiming a confirmed fault while Mode 03 comes back empty is
  /// a contradiction the verdict has to account for. It was never shown.
  ///
  /// Null means the summary could not be read, which qualifies nothing: only
  /// an explicit claim counts, in either direction.
  final MilStatus? mil;

  /// The snapshots the controllers stored when they confirmed these faults.
  ///
  /// Read only when the scan found codes, because a controller with no code has
  /// no frame — and because the read costs a round trip per frozen PID, which
  /// is not worth spending on a car that is fine.
  ///
  /// Empty is not "no frame": it is also what an unsupported service, a
  /// timeout, or a cleared memory produce. Nothing on screen may turn this into
  /// a claim about the vehicle.
  final List<FreezeFrame> freezeFrames;

  /// The scan tried to read a freeze frame and could not.
  ///
  /// Distinct from [freezeFrames] being empty, which is what a controller with
  /// no stored frame produces — and the two used to be the same thing on
  /// screen. That mattered more than it sounds: FIELD_GUIDE tells the reader
  /// that no card means no frame was stored and that this is not bad news, and
  /// the next control the screen offers is a clear, which destroys the frame
  /// permanently. A single Mode 02 timeout on a clone adapter was enough to
  /// walk somebody through that door.
  final bool freezeFrameUnread;

  /// A clear is on the wire right now.
  final bool clearing;

  /// What the last clear did, in the words shown to the user. Null until one
  /// has been attempted.
  final String? clearMessage;

  /// Whether that clear may be reported as having worked.
  final bool clearWorked;

  /// Whether sending another global clear could reach a controller that has
  /// already erased its memory.
  ///
  /// Here rather than in the screen, and that is the whole point of it living
  /// here. The header of this file records the lesson: the shell is an
  /// ordinary `ShellRoute` driven by `context.go`, so switching tabs disposes
  /// the screen. The scan results were moved here for exactly that reason and
  /// the clear's two safety flags were left behind — so a glance at the
  /// dashboard and back rebuilt a fresh state with the latch cleared, the
  /// warning gone, and the old codes still on screen. The next tap sent a
  /// second global `04`.
  final bool clearRepeatWouldHarm;

  ScanVerdict get verdict => scanVerdict(
        hasScanned: hasScanned,
        // Counts partial observations too, so a fault found during an
        // incomplete scan can never be reported as an absence of faults.
        totalCodes: totalCodes,
        answered: {
          for (final entry in results.entries)
            if (entry.value.answered) entry.key,
        },
        optionalCoverageComplete:
            optionalNotCovered.values.every((s) => s.isEmpty),
      );

  /// The controllers no optional class reached, flattened for the panel.
  Set<String> get optionalGaps =>
      {for (final s in optionalNotCovered.values) ...s};

  DtcScanState copyWith({
    Map<DtcKind, DtcCategoryResult>? results,
    DateTime? scannedAt,
    String? vin,
    String? error,
    bool? loading,
    Map<DtcKind, Set<String>>? optionalNotCovered,
    bool? clearing,
    String? clearMessage,
    bool? clearWorked,
    bool? clearRepeatWouldHarm,
    MilStatus? mil,
    List<FreezeFrame>? freezeFrames,
    bool? freezeFrameUnread,
    bool dropClearMessage = false,
  }) =>
      DtcScanState(
        results: results ?? this.results,
        scannedAt: scannedAt ?? this.scannedAt,
        vin: vin ?? this.vin,
        error: error ?? this.error,
        loading: loading ?? this.loading,
        optionalNotCovered: optionalNotCovered ?? this.optionalNotCovered,
        clearing: clearing ?? this.clearing,
        clearMessage: dropClearMessage ? null : clearMessage ?? this.clearMessage,
        clearWorked: clearWorked ?? this.clearWorked,
        clearRepeatWouldHarm:
            clearRepeatWouldHarm ?? this.clearRepeatWouldHarm,
        mil: mil ?? this.mil,
        freezeFrames: freezeFrames ?? this.freezeFrames,
        freezeFrameUnread: freezeFrameUnread ?? this.freezeFrameUnread,
      );

  /// What the clear's outcome panel says once a rescan has settled it.
  ///
  /// Every sentence a clear leaves behind is written for the moment *before*
  /// the rescan: it names controllers, warns against a second global `04`, and
  /// ends by asking for exactly the rescan that is now finishing. Carrying it
  /// through unchanged is how the panel came to sit beside a live 清除 button
  /// telling somebody not to press it — the app's own recovery step making its
  /// own warning false, with `FIELD_GUIDE.md` telling them to trust the
  /// button.
  ///
  /// Deleting it instead would be worse: a partial clear is a fact about the
  /// car that the rescan does not undo, and the panel is where it is recorded.
  /// So it is replaced by the part that stays true afterwards.
  ///
  /// A successful clear rescans itself and its lock was never set, so its
  /// sentence passes through — otherwise 已送出清除指令 would be erased by the
  /// rescan it triggers before anybody read it.
  String? get clearMessageAfterRescan => clearRepeatWouldHarm
      ? '上一次清除的結果無法完全確認，以下是重新掃描後的實際狀況。'
      : clearMessage;

  /// The same state with the clear's outcome panel dismissed.
  ///
  /// The latch is deliberately not cleared: closing a message is not the same
  /// as learning what happened, and only a rescan is.
  DtcScanState withoutClearMessage() => copyWith(dropClearMessage: true);
}

class DtcScanNotifier extends Notifier<DtcScanState> {
  /// How long a whole scan may take before it reports what it has.
  ///
  /// Nothing bounded this. Each command had its own timeout, and a category
  /// that meets a controller answering "still working" now retries — so a
  /// pathological adapter could hold the spinner for minutes with no way out
  /// but killing the app. A scan that has run this long is not going to
  /// improve; what it gathered is worth showing, and what it did not reach is
  /// worth naming.
  static const Duration budget = Duration(seconds: 45);

  /// How much longer the wrapper waits than the deadline it wraps.
  ///
  /// Both exist and they do different jobs. The deadline goes *into* the
  /// engine, where it can stop a retry from sleeping and transmitting again;
  /// `Future.timeout` cannot cancel anything, so on its own it bounded the
  /// spinner while the bus work carried on behind it. They were set to the
  /// same value, which meant the one that cannot cancel could win the race —
  /// and a category was then reported unfinished while the adapter was still
  /// executing it, with the next scan queueing behind work the UI had
  /// disowned.
  ///
  /// Giving the wrapper a margin makes the in-band deadline the one that
  /// normally fires. What is left for the wrapper is the case it is actually
  /// for: a transport that never returns at all.
  static const Duration _wrapperGrace = Duration(seconds: 3);

  @override
  DtcScanState build() {
    // Results belong to one connection. Losing the link — deliberately or not
    // — makes every verdict on screen a statement about a car the app is no
    // longer talking to.
    ref.listen(obdSessionProvider, (previous, next) {
      if (!next.isConnected) {
        // Not gated on `hasScanned`: a scan still in flight has the same
        // problem and worse, because its later categories would land against
        // whatever vehicle is connected by then.
        //
        // The clear's own outcome is the exception, and it survives here
        // deliberately. A link that drops between `04` going out and its
        // acknowledgement coming back is precisely when somebody needs to be
        // told that a clear may have happened — and wiping it left them
        // looking at 尚未掃描 with no sign that the vehicle had been changed.
        if (state.hasScanned || state.loading) {
          state = DtcScanState(
            clearMessage: state.clearMessage,
            clearWorked: state.clearWorked,
            clearRepeatWouldHarm: state.clearRepeatWouldHarm,
          );
        }
      } else if (previous?.isConnected != true) {
        // A connection just came up. The results are about the old one and go;
        // an unsettled clear is about a *vehicle* and stays.
        //
        // Codex round 31 asked for the wipe: a clear that landed in a state
        // the disconnect branch could no longer reach carried vehicle A's
        // 不要直接再清除一次 over vehicle B's fault codes.
        //
        // Codex round 32 showed the wipe was too wide, and quoted the previous
        // commit against itself — it said "a dropped link is not a different
        // car" while the code treated every reconnect as one. Drop the link
        // after `04` goes out, then reconnect the same adapter to the same
        // car, which is what anybody would do: warning gone, latch gone, and
        // the scan that finds the remaining fault offers a live 清除 over a
        // controller that already erased its memory.
        //
        // The two directions are not symmetric, so the tie goes to the lock.
        // Carrying a warning onto a car that was never cleared costs one
        // rescan, which the message asks for anyway and which settles it.
        // Dropping it on the car that *was* cleared costs a drive cycle, and
        // nothing gets it back. So an unsettled clear survives the
        // reconnection, and says where it came from rather than pretending to
        // describe this connection.
        state = state.clearRepeatWouldHarm
            ? const DtcScanState(
                clearRepeatWouldHarm: true,
                clearMessage: '上一次連線送出過清除指令，結果沒有確認。'
                    '請先重新掃描，確認哪些故障碼還在，再決定要不要清除。',
              )
            : const DtcScanState();
      }
    });
    return const DtcScanState();
  }

  /// What a scan that was interrupted leaves on screen.
  ///
  /// Not a bare empty state. Wiping silently returned the screen to 尚未掃描
  /// with nothing said, which contradicts this same function's rule about the
  /// budget path — that an unnamed absence and a timeout look identical
  /// otherwise. A user who backgrounded the app mid-scan and came back to a
  /// blank panel has no way to know whether the scan ran.
  ///
  /// It carries the clear's state through for the same reason the disconnect
  /// branch does: an interruption settles nothing. Cursor round 32 — tap 清除,
  /// get 不要再送一次全車清除…請重新掃描, tap 掃描 as instructed, and press Home
  /// during the census, which is simply what phones do. `superseded()` fires on
  /// the pause epoch, this state replaced the lock and the sentence with an
  /// error string, and the next successful scan then found nothing left to
  /// settle: 清除 live, no warning, over a controller that had already erased
  /// its memory.
  DtcScanState _interrupted() => DtcScanState(
        error: '掃描在中途被中斷（可能是切換到其他 App 或連線變更），'
            '沒有得到完整結果。請重新掃描。',
        clearMessage: state.clearMessage,
        clearWorked: state.clearWorked,
        clearRepeatWouldHarm: state.clearRepeatWouldHarm,
      );

  /// Reads every code class.
  ///
  /// A read that fails must never be reported as "no fault codes found". That
  /// is a false all-clear on a diagnostic screen, and someone could reasonably
  /// drive away on it. Any failure is surfaced as a failure, and the results
  /// are only marked valid when every read actually returned.
  Future<void> scan() async {
    if (state.loading) return;
    // A refresh discards the previous verdict rather than keeping it visible
    // underneath a spinner.
    //
    // `copyWith(loading: true)` kept `results`, `scannedAt` and `vin`, so
    // `hasScanned` stayed true and the screen went on rendering the old green
    // 未偵測到故障碼 for the whole scan — a verified all-clear about a car the
    // app is at that moment re-interrogating, and which may be a different car
    // entirely. `loading` only disabled some controls; nothing marked the
    // verdict stale.
    //
    // The failed-refresh case was already handled this way — a scan that could
    // not run must not leave the old panel standing — and the *running* case
    // was not.
    // The clear's outcome survives a rescan; a *completed* rescan settles it.
    //
    // Wiping everything is right for the verdict — a stale green panel under a
    // spinner is the most dangerous thing this screen can show — and wrong for
    // the sentence describing the clear that just happened, which a successful
    // clear immediately rescans and would therefore erase before anybody read
    // it.
    state = DtcScanState(
      loading: true,
      // Not settled yet, so neither the sentence nor the lock moves yet.
      //
      // Both used to be released here, at the *start* of the rescan. Nothing
      // caught it because a scan that dies leaves `scannedAt` null and the
      // clear button is not drawn — the lock was being held by the absence of
      // a button rather than by itself, and the reword below then had no flag
      // left to key on. A rescan settles the clear when it produces results,
      // not when it begins.
      clearMessage: state.clearMessage,
      clearWorked: state.clearWorked,
      clearRepeatWouldHarm: state.clearRepeatWouldHarm,
    );

    final session = ref.read(obdSessionProvider.notifier);

    // Captured before the census, not after it.
    //
    // The census await was inserted above this block, which put it outside
    // every token the rest of the scan is held to: it did not count against
    // the advertised budget, and a pause during it was invisible to an epoch
    // sampled once it finished. A 20-second census on a slow adapter bought a
    // 65-second scan, and backgrounding mid-census left the work looking as
    // though it had never been interrupted. The fix for one hole opened
    // another one line above itself.
    //
    // Captured once, for the reason it always was. A scan reads three code
    // classes and then a VIN, so it
    // spans several seconds and any number of awaits — long enough to
    // disconnect from one car and connect to another. Each `session.readDtcs`
    // resolves the *current* engine, and the listener below only clears once
    // `hasScanned` is true, so a first-ever scan interrupted this way ended up
    // holding vehicle A's stored codes beside vehicle B's pending codes and
    // VIN, presented as one vehicle's result.
    final deadline = DateTime.now().add(budget);
    final generation = session.generation;
    // Backgrounding counts as superseding. The OS can suspend the process
    // between a request and its reply, and a scan that continues across that
    // publishes a verdict assembled partly before and partly after an interval
    // nobody owned.
    //
    // Counted, not sampled. `isForeground` alone answers "are we backgrounded
    // *now*", which a suspension that began and ended between two checkpoints
    // passes cleanly — so the check missed the very case its own comment
    // describes. The epoch increments on every pause and cannot be stepped
    // over.
    final pauseEpoch = session.pauseEpoch;
    bool superseded() =>
        session.generation != generation ||
        session.pauseEpoch != pauseEpoch ||
        !session.isForeground;

    // The census has to exist before the first category is read.
    //
    // It is fired unawaited at connect, so a scan started promptly — which is
    // exactly what someone does after plugging in — found `_responders` null,
    // skipped the silence check, and let one controller's clean `43 00` close
    // the class while another sat silent with a real fault. Every test for
    // that check awaited the census first, so the hole stayed green.
    //
    // Failure here is not fatal: no census means no census-based refusal, and
    // the scan proceeds on the evidence it does have. Being interrupted during
    // it is a different matter, and is checked like every other step.
    try {
      await session.ensureResponderCensus(deadline: deadline);
    } on Object {
      // Deliberately ignored; the read below reports what it can establish.
    }
    final results = <DtcKind, DtcCategoryResult>{};
    String? vin;
    String? fatal;

    // What the vehicle says about itself — asked *before* the categories, not
    // after them.
    //
    // Mode 01 PID 01 carries each controller's fault lamp and confirmed-code
    // count, and the app read Modes 03, 07 and 0A without ever asking. A car
    // whose lamp is lit while Mode 03 answers `43 00` is not a contradiction
    // to resolve in favour of the empty list — it happens when a controller
    // sits outside the functional request's reach, when a gateway does not
    // forward Mode 03, or when a clone filters replies — and the screen said
    // 未偵測到故障碼 with the lamp on the dashboard in front of the user.
    //
    // The order is the point. Asked afterwards, a controller this exchange
    // discovers arrives too late: Modes 03, 07 and 0A have already been
    // certified against a census that did not include it, and a scan could
    // meet `7E9` here, never hear from it again, and still go green on `7E8`
    // alone. Answered first, the controllers it finds are part of the coverage
    // question every category then has to satisfy.
    //
    // Null is unknown and changes nothing. Only an explicit claim counts.
    MilStatus? mil;
    try {
      final remaining = deadline.difference(DateTime.now());
      mil = remaining <= Duration.zero
          ? null
          : await session
              .readMilStatus(deadline: deadline)
              .timeout(remaining + _wrapperGrace);
    } on Object {
      mil = null; // A summary that cannot be read qualifies nothing.
    }
    if (superseded()) {
      state = _interrupted();
      return;
    }

    // Each class is read on its own. One failing says nothing about the
    // others, and throwing away two good answers because the third was
    // unsupported is how a car with a real stored fault showed a bare error.
    for (final kind in DtcKind.values) {
      if (superseded()) {
        state = _interrupted();
        return;
      }

      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        // Named rather than silently omitted: an absent category and one that
        // ran out of time look identical on screen otherwise.
        results[kind] = const DtcCategoryResult.failed(
          DtcReadException(
            '掃描已達時間上限，這個類別沒有讀取到。請重新掃描。',
            kind: DtcReadFailure.noAnswer,
          ),
        );
        continue;
      }

      try {
        results[kind] = DtcCategoryResult.codes(
          // The deadline goes *in*, and the wrapper stays as a backstop for
          // the parts of one exchange it cannot reach. On its own the wrapper
          // bounded the spinner and not the bus: the detached read kept
          // sleeping and retransmitting, and an immediate rescan queued behind
          // the operation this line thought it had abandoned.
          await session.readDtcs(kind, deadline: deadline).timeout(remaining + _wrapperGrace),
        );
      } on DtcReadException catch (e) {
        if (e.kind == DtcReadFailure.disconnected) {
          fatal = '連線在掃描途中中斷，這次掃描沒有完成。';
          break;
        }
        results[kind] = DtcCategoryResult.failed(e);
      } on TimeoutException {
        results[kind] = const DtcCategoryResult.failed(
          DtcReadException('讀取逾時。請確認轉接器連線穩定、車輛電門已開啟。'),
        );
      } on Object catch (e) {
        results[kind] = DtcCategoryResult.failed(DtcReadException('$e'));
      }
    }

    // The cross-check, per controller.
    //
    // It used to compare a vehicle-wide `claimsFault` against "did any
    // category produce any code at all", which is not a comparison of like
    // with like: a *pending* code in Mode 07 silenced a claim of two
    // *confirmed* codes that Mode 03 had not produced, and one confirmed code
    // satisfied a claim of two. What PID 01 states is per module and about
    // confirmed codes, so that is what it is checked against.
    if (mil != null) {
      final disagreements = <String>[];
      final stored = results[DtcKind.stored];
      final storedCodes = stored == null
          ? const <Dtc>[]
          : [...stored.codes, ...stored.partial];
      // Only against a Mode 03 that actually answered.
      //
      // A category that was refused — `7F 03 11`, a timeout, no bytes at all —
      // has an empty code list for a reason that is not "the controller read
      // zero". Comparing against it turned an accurate transport diagnosis
      // into 「Mode 03 只讀到 0 筆」, which is a false statement about the
      // vehicle replacing a true one about the link.
      final comparable = stored != null && stored.answered;
      for (final entry in comparable ? mil.bySource.entries : <MapEntry<String, MilSummary>>[]) {
        final summary = entry.value;
        if (!summary.claimsFault) continue;
        // Only this controller's confirmed codes answer this controller's
        // claim. A code from another module is another module's business.
        final mine =
            storedCodes.where((d) => d.sourceId == entry.key).length;
        if (summary.confirmedCount > mine) {
          disagreements.add(
            '控制器 ${entry.key} 回報 ${summary.confirmedCount} 筆已確認故障碼，'
            'Mode 03 只讀到 $mine 筆',
          );
        } else if (summary.milOn && mine == 0) {
          disagreements.add('控制器 ${entry.key} 回報故障燈亮起，但沒有讀到它的故障碼');
        }
      }
      if (disagreements.isNotEmpty && comparable) {
        results[DtcKind.stored] = DtcCategoryResult.failed(
          DtcReadException(
            '${disagreements.join('；')}。'
            '車輛自己回報的狀態與讀到的故障碼不一致，'
            '可能有控制器不在這次查詢的範圍內。請以車輛儀表為準，並洽維修廠。',
            kind: DtcReadFailure.noAnswer,
            partial: storedCodes,
          ),
        );
      }
    }

    // The whole-vehicle question, asked once and here.
    //
    // Each category answers for itself inside the engine, because asking the
    // union there made one candidate raised by Mode 0A fail the *next* scan's
    // Mode 03 and Mode 07 before Mode 0A got to replace its own stale set —
    // the app asked for a rescan and one rescan was not enough. But a token
    // nobody could name is a fact about the car, not about the category that
    // happened to see it, so no category may be rendered as a whole-vehicle
    // result while one stands. Asked after every category has staged its
    // result, which is the only point where both are true.
    final unresolved = session.engine?.openIdentityQuestions ?? const <String>{};
    if (fatal == null && unresolved.isNotEmpty) {
      final message = '有 ${unresolved.length} 筆回應無法判斷是哪個控制器送出的'
          '（未能辨識的位址：${unresolved.join('、')}）。'
          '已讀到的結果仍然有效，但不能當作全車結果。請重新掃描。';
      for (final entry in results.entries.toList()) {
        if (!entry.value.answered) continue;
        results[entry.key] = DtcCategoryResult.failed(
          DtcReadException(
            message,
            kind: DtcReadFailure.noAnswer,
            partial: entry.value.codes,
          ),
        );
      }
    }

    if (superseded()) {
      state = _interrupted();
      return;
    }

    if (fatal == null) {
      try {
        final remaining = deadline.difference(DateTime.now());
        vin = remaining <= Duration.zero
            ? null
            // The lease goes *in*. It was added to `PollingEngine.readVin`
            // and `ObdSession.readVin` and then not passed here, so two
            // signatures changed and the one line that mattered did not — the
            // VIN exchange kept detaching behind the wrapper exactly as
            // before. An earlier attempt at this edit used a string replace
            // with no assertion and failed silently, which is how it survived.
            : await session
                .readVin(deadline: deadline)
                .timeout(remaining + _wrapperGrace);
      } on Object {
        vin = null; // The VIN is context, never a reason to fail a scan.
      }
    }

    if (superseded()) {
      state = _interrupted();
      return;
    }

    if (fatal != null) {
      // A scan that did not run must not leave the previous verdict standing.
      // Keeping the old green panel while the link was down is exactly how a
      // failed refresh looked greener than an honest unknown.
      state = DtcScanState(
        error: fatal,
        // A rescan that could not run settles nothing, so the warning and
        // the lock both stand exactly as the clear left them.
        clearMessage: state.clearMessage,
        clearWorked: state.clearWorked,
        clearRepeatWouldHarm: state.clearRepeatWouldHarm,
      );
      return;
    }

    // Only once the categories have found something. A controller with no
    // stored code has no frame, and the read costs a round trip for every PID
    // the frame carries — not worth spending on a car that is fine, and a
    // spinner that runs twice as long on a healthy vehicle is how somebody
    // decides the app is broken.
    //
    // Failure here is silence, not an error: the codes are the answer this
    // screen exists for, and losing them to a service the vehicle may not
    // implement would trade the whole scan for an extra.
    var freezeFrames = const <FreezeFrame>[];
    var freezeFrameUnread = false;
    final foundCodes =
        results.values.fold(0, (s, r) => s + r.codes.length + r.partial.length);
    if (foundCodes > 0 && !superseded()) {
      try {
        final remaining = deadline.difference(DateTime.now());
        if (remaining > Duration.zero) {
          final read = await session
              .readFreezeFrames(deadline: deadline)
              .timeout(remaining + _wrapperGrace);
          freezeFrames = read.frames;
          // Damage inside a reply the adapter called successful counts the
          // same as a read that never happened: what came back is trustworthy,
          // and it is not known to be all of it.
          freezeFrameUnread = read.incomplete;
        } else {
          // Out of budget before the question was asked. Not an absence of
          // frames, and it used to be indistinguishable from one.
          freezeFrameUnread = true;
        }
      } on Object {
        freezeFrames = const [];
        freezeFrameUnread = true;
      }
      if (superseded()) {
        state = _interrupted();
        return;
      }
    }

    state = DtcScanState(
      results: Map.unmodifiable(results),
      vin: vin,
      mil: mil,
      freezeFrames: List.unmodifiable(freezeFrames),
      freezeFrameUnread: freezeFrameUnread,
      scannedAt: DateTime.now(),
      clearMessage: state.clearMessageAfterRescan,
      clearWorked: state.clearWorked,
          optionalNotCovered: Map.unmodifiable({
        for (final e in (session.engine?.optionalNotCovered ?? const {}).entries)
          e.key: Set<String>.unmodifiable(e.value),
      }),
    );
  }

  /// Dismisses the clear's outcome panel without forgetting what it said.
  void dismissClearMessage() => state = state.withoutClearMessage();

  /// Clears fault codes, and holds on to what that means.
  ///
  /// Here rather than in the screen because both of its safety properties are
  /// about the *vehicle*, not about a widget: whether a clear is on the wire
  /// right now, and whether sending another one could reach a controller that
  /// has already erased its memory. Held in the screen, both were reset by
  /// switching tabs — the file header records that lesson being learned once
  /// already, for the scan results, and the clear was left behind.
  Future<void> clear() async {
    if (state.clearing) return;
    // Via `withoutClearMessage`, because `copyWith` cannot express this.
    //
    // `copyWith`'s `clearMessage ?? this.clearMessage` reads null as "leave it
    // alone", which is right for every other caller and wrong for the one that
    // means it: passing null here retained the previous attempt's panel, so a
    // second clear ran under the first one's verdict.
    state = state.withoutClearMessage().copyWith(clearing: true);

    // Which connection this outcome will describe.
    //
    // The listener above wipes the clear state when a new link comes up, and
    // that alone leaves a window: the drop is what makes `clearDtcs` fail, so
    // a reconnection that completes before this method's continuation runs is
    // wiped *first* and then written over.
    //
    // `connectEpoch`, not `generation`. Generation is bumped by anything that
    // invalidates in-flight work — and losing the link is the loudest such
    // thing — so guarding on it suppressed exactly the outcome this guard was
    // added to protect. Yank the adapter between `04` going out and its reply:
    // the engine correctly produced 清除指令送出後連線中斷…不要直接再清除一次,
    // and the guard threw it away, leaving a blank panel and a live button
    // over a controller that may have just erased its memory.
    //
    // A clear whose link died still describes the car it was sent to. Only
    // somebody connecting to a different one makes it stop describing anything.
    //
    // Not reachable in today's ordering, and kept anyway. Connecting tears
    // down the in-flight client, which fails the pending exchange, so `clear()`
    // resolves and publishes before the new connection completes — and the
    // listener's wipe-on-connect then removes it. Every attempt to construct
    // the race has landed on that path, so nothing below fails when this guard
    // is deleted; it is one integer comparison standing between a reordering
    // and a verdict about the wrong car, which is the trade this file exists to
    // make.
    final startedOn = ref.read(obdSessionProvider.notifier).connectEpoch;

    var worked = false;
    var repeatWouldHarm = false;
    String message;
    try {
      final outcome = await ref.read(obdSessionProvider.notifier).clearDtcs();
      worked = outcome.isSuccess;
      repeatWouldHarm = outcome.repeatWouldHarm;
      message = switch (outcome) {
        ClearOutcome.confirmed => '已送出清除指令',
        // The state a boolean could not express, and the one that matters
        // most: part of the vehicle has already erased its fault memory, so
        // the worst possible advice here is "try again". A second global clear
        // reaches the controller that finished and resets its readiness
        // monitors a second time — another full drive cycle before the car can
        // pass an emissions test.
        ClearOutcome.partiallyConfirmed =>
          '已有控制器回報清除完成，但其餘控制器無法確認。'
              '不要再送一次清除 —— 重複清除會讓已完成的控制器再一次重置排放就緒狀態。'
              '請重新掃描確認結果。',
        // Transmitted, and the answer never legibly arrived. Not a failure —
        // a controller may have erased its memory and had the reply destroyed
        // on the way back — and not a success either. The rescan is what turns
        // it into something somebody can act on.
        ClearOutcome.sentUnconfirmed =>
          '清除指令已送出，但回應在傳輸過程中損毀，無法確認車輛是否已清除。'
              '請重新掃描確認結果，不要直接再清除一次 —— '
              '如果其實已經清除成功，再清一次會重置排放就緒狀態。',
        ClearOutcome.notAccepted => '清除失敗，沒有控制器接受指令。',
      };
    } on DtcReadException catch (e) {
      // A diagnosis rather than a failure — most usefully, "accepted but not
      // yet confirmed", where a blind retry would reset readiness monitors a
      // second time.
      message = e.message;
      repeatWouldHarm = e.repeatWouldHarm;
    } on TimeoutException {
      // Reached only if something outside `clearDtcs` times out, since the
      // engine now classifies its own failures by whether `04` was written.
      // Conservative here because this branch no longer knows: an unknown
      // clear must not invite a blind retry.
      message = '清除指令送出後沒有回應，無法確認是否已清除。請重新掃描確認。';
      repeatWouldHarm = true;
    } on OperationRetiredException {
      // Backgrounding the app between tapping 清除 and the exchange's first
      // write retires the lease, and `_sendNow` throws before anything is
      // transmitted. It reached the branch below and printed its own Dart
      // class name into a sentence a driver reads at a car.
      message = '清除已取消，指令還沒送出到車上。可以重新掃描後再試一次。';
      repeatWouldHarm = false;
    } on Object catch (e) {
      // Genuinely unexpected: `clearDtcs` classifies everything it can and the
      // retired case is handled above. Conservative for the same reason the
      // timeout is — an unknown clear must not invite a blind retry — and the
      // detail is kept, because in an unforeseen case it is the only clue, but
      // it no longer leads the sentence.
      message = '清除失敗，無法確認車輛是否已清除，請重新掃描確認。（$e）';
      repeatWouldHarm = true;
    }

    // Kept on screen rather than shown for four seconds.
    //
    // These messages name controllers — 有 2 個控制器沒有回應清除指令（7E9、
    // 7EA）— and those addresses appear nowhere else in the app. A default
    // SnackBar took the only copy away after four seconds, at a car, on the
    // one operation that cannot be undone.
    if (ref.read(obdSessionProvider.notifier).connectEpoch != startedOn) {
      // A different connection owns the screen now. Saying 已送出清除指令 over
      // another vehicle's codes is the one thing worse than saying nothing.
      //
      // The in-flight flag still has to come down: it belongs to this
      // notifier, not to the outcome, and leaving it set hands the next
      // connection a clear that is not running.
      state = state.copyWith(clearing: false);
      return;
    }

    state = state.copyWith(
      clearing: false,
      clearMessage: message,
      clearWorked: worked,
      clearRepeatWouldHarm: repeatWouldHarm,
    );
    if (worked) await scan();
  }
}

final dtcScanProvider =
    NotifierProvider<DtcScanNotifier, DtcScanState>(DtcScanNotifier.new);
