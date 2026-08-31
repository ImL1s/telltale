/// Diagnostic trouble codes: read stored, pending and permanent codes, and
/// clear the ones that can be cleared.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../obd/dtc/dtc.dart';
import '../../../obd/freeze_frame.dart';
import '../../../obd/polling_engine.dart';
import '../../../obd/readiness.dart';
import '../../../state/dtc_scan.dart';
import '../../../state/obd_session.dart';
import '../../widgets/panel.dart';

class DtcScreen extends ConsumerStatefulWidget {
  const DtcScreen({super.key});

  static const String path = '/dtc';

  @override
  ConsumerState<DtcScreen> createState() => _DtcScreenState();
}

/// The outcome of reading one class of fault codes.
///
/// Modelled per class rather than collapsed into one list, because the classes
/// fail independently: Mode 0A permanent codes are not universal on vehicles
/// built before about 2012, and its absence says nothing about Mode 03. The
/// old all-or-nothing loop discarded two successful reads because the third
/// was unsupported.
class _DtcScreenState extends ConsumerState<DtcScreen> {
  // The clear's outcome and its two safety flags used to live here. They do
  // not any more, and the reason is the one this file's sibling
  // (`state/dtc_scan.dart`) records in its own header: the shell is an
  // ordinary `ShellRoute` driven by `context.go`, so switching tabs disposes
  // this state. A glance at the dashboard and back rebuilt it with the
  // repeat-lock cleared and the warning gone, over codes that were still on
  // screen — and the next tap sent a second global `04`.

  Future<void> _clear() async {
    // What the scan could not establish, said at the point of no return.
    //
    // The dialog listed the consequences of clearing and nothing about the
    // evidence it is being decided on. A scan where Mode 03 completed with a
    // P0300 while Modes 07 and 0A timed out passes every engine-side guard —
    // every census controller answered Mode 03 — so the clear proceeds, and
    // the automatic rescan afterwards can return the same silent categories,
    // which reads as confirmation that it worked everywhere. Clearing is not
    // undoable and it costs the vehicle a drive cycle; the one screen that
    // asks before doing it should say what is unknown.
    final scan = ref.read(dtcScanProvider);
    final unanswered =
        scan.unanswered.map((e) => e.key.label).toList(growable: false);
    // The frames this clear is about to destroy, named at the point of no
    // return.
    //
    // The card that shows a freeze frame says clearing destroys it. That card
    // is somewhere above this button, possibly scrolled off, and this dialog is
    // where the decision actually happens — it already lists what the scan
    // could not establish, and the frame is the one thing on this screen that
    // cannot be read again afterwards. Fault codes come back if the fault
    // recurs; the snapshot of the moment it first happened does not.
    final frames = scan.freezeFrames
        .map((f) => f.cause.code)
        .toSet()
        .toList(growable: false);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除故障碼？'),
        content: Text(
          '這會清掉已儲存與待確認的故障碼並熄滅故障燈，同時重置排放就緒狀態 — '
          '車輛需要重新完成一輪自我診斷才能通過驗車。永久故障碼（Mode 0A）無法清除。'
          '${frames.isEmpty ? '' : '\n\n連同 ${frames.join('、')} 的凍結幀 —— '
              '故障發生當下的轉速、水溫、負荷那一整份紀錄 —— 也會一起消失，'
              '而且故障再次發生前讀不回來。'}'
          // The frame that may be there and was not read.
          //
          // The warning panel higher up says this, and by the time somebody
          // reaches this button it may have scrolled away. This dialog's own
          // comment says it exists because the frame is the one thing that
          // cannot be read again afterwards — and it was silent in exactly the
          // case where nobody knows whether there is one.
          '${scan.freezeFrameUnread ? '\n\n這次沒有讀到凍結幀，但不代表車上沒有。'
              '先重新掃描一次，再決定要不要清除。' : ''}'
          '${unanswered.isEmpty ? '' : '\n\n這次掃描有 ${unanswered.length} 個類別沒有得到完整回應'
              '（${unanswered.join('、')}），'
              '可能還有你沒看到的故障碼。清除後就再也讀不到了。'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('確定清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(dtcScanProvider.notifier).clear();
  }

  /// Rescans, which is also the only thing that re-enables the clear.
  ///
  /// A rescan turns "part of the vehicle was cleared, the rest is unknown"
  /// back into a state somebody can act on — it is the action every one of
  /// those messages asks for. `scan()` rebuilds the state wholesale, so the
  /// latch goes with it.
  Future<void> _rescan() => ref.read(dtcScanProvider.notifier).scan();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final connected = ref.watch(obdSessionProvider).isConnected;

    // Held in a provider rather than in this State, because the shell is an
    // ordinary ShellRoute and a tab switch disposes the screen — a ten-second
    // scan on a real car did not survive a glance at the dashboard.
    final scan = ref.watch(dtcScanProvider);
    final results = scan.results;
    final verdict = scan.verdict;
    final unansweredLabel = DtcKind.values
        .where((k) => !(results[k]?.answered ?? false))
        .map((k) => k.label)
        .join('、');

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          key: const ValueKey('dtc-page-scroll'),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.lg,
                  Spacing.md,
                  Spacing.lg,
                  Spacing.md,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('故障碼', style: context.texts.headlineMedium),
                          Text(
                            !scan.hasScanned
                                ? '尚未掃描'
                                : scan.totalCodes > 0
                                    ? '共 ${scan.totalCodes} 筆'
                                    : switch (verdict) {
                                        // The panel below has always said what
                                        // this actually establishes — that the
                                        // controllers which *replied* reported
                                        // nothing. The header said 未偵測到故障碼,
                                        // an unqualified statement about the
                                        // vehicle, and it is the line a glance
                                        // lands on. Somebody could drive away on
                                        // it while the hedge sits in body text
                                        // two paragraphs down.
                                        ScanVerdict.completeClean =>
                                          '已回應的控制器沒有故障碼',
                                        ScanVerdict.partialClean => '部分未確認',
                                        _ => '無法確認',
                                      },
                            style: context.texts.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    if (scan.hasScanned && scan.totalCodes > 0)
                      OutlinedButton.icon(
                        onPressed: scan.loading ||
                                scan.clearing ||
                                scan.clearRepeatWouldHarm
                            ? null
                            : _clear,
                        icon: scan.clearing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.delete_sweep_outlined, size: 18),
                        // Says why it cannot be pressed, and what makes it
                        // pressable again. A control that is merely dead invites
                        // the reading that the app has stopped working, on the
                        // screen where that guess is most expensive.
                        label: Text(scan.clearing
                            ? '清除中…'
                            : scan.clearRepeatWouldHarm
                                ? '請先重新掃描'
                                : '清除'),
                      ),
                  ],
                ),
              ),
            ),
            // The clear's own outcome, held until the next one replaces it.
            if (scan.clearMessage != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Spacing.lg,
                    0,
                    Spacing.lg,
                    Spacing.md,
                  ),
                  child: Panel(
                    accent: scan.clearWorked ? palette.success : palette.warning,
                    isActive: true,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          scan.clearWorked
                              ? Icons.check_circle_outline
                              : Icons.error_outline,
                          color: scan.clearWorked ? palette.success : palette.warning,
                          size: 22,
                        ),
                        const SizedBox(width: Spacing.md),
                        Expanded(
                          child: SelectableText(
                            scan.clearMessage!,
                            style: context.texts.bodySmall,
                          ),
                        ),
                        IconButton(
                          // Dismisses the message, not the lock. Closing a
                          // panel is not the same as learning what happened, and
                          // only a rescan is.
                          onPressed: () => ref
                              .read(dtcScanProvider.notifier)
                              .dismissClearMessage(),
                          icon: const Icon(Icons.close, size: 18),
                          tooltip: '關閉',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            SliverFillRemaining(
              child: !connected
                  ? const EmptyState(
                      icon: Icons.link_off,
                      title: '尚未連線',
                      message: '需要連上 ELM327 轉接器或啟動模擬器才能讀取故障碼。',
                    )
                  : !scan.hasScanned
                      ? EmptyState(
                          icon: scan.error == null ? Icons.search : Icons.error_outline,
                          title: scan.error == null ? '掃描車輛故障碼' : '讀取失敗',
                          message: scan.error ??
                              '讀取 Mode 03 已儲存、Mode 07 待確認與 Mode 0A 永久故障碼。',
                          action: FilledButton.icon(
                            onPressed: scan.loading ? null : _rescan,
                            icon: scan.loading
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.search, size: 20),
                            label: Text(
                              scan.loading
                                  ? '掃描中…'
                                  : (scan.error == null ? '開始掃描' : '重試'),
                            ),
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: _rescan,
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(
                              Spacing.lg,
                              0,
                              Spacing.lg,
                              Spacing.xxl,
                            ),
                            children: [
                              if (scan.vin != null) ...[
                                Panel(
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.directions_car_outlined,
                                        size: 18,
                                        color: palette.textSecondary,
                                      ),
                                      const SizedBox(width: Spacing.md),
                                      Text('VIN', style: context.texts.labelSmall),
                                      const SizedBox(width: Spacing.md),
                                      // A 17-character VIN in a monospace face
                                      // beside a label, both growing with the
                                      // system text scale, overflowed the row
                                      // at 2× — yellow-and-black stripes across
                                      // the panel, seen on a device. Shrinking
                                      // the value keeps it readable and whole;
                                      // wrapping a VIN would be worse, since it
                                      // is one identifier and people read it a
                                      // character at a time.
                                      Expanded(
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          alignment: Alignment.centerRight,
                                          child: Text(
                                            scan.vin!,
                                            style: AppTypography.code(
                                              palette,
                                              size: 13,
                                              color: palette.textPrimary,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: Spacing.lg),
                              ],
                              // The read that did not happen, said out loud.
                              //
                              // Without this the screen showed nothing, which
                              // is exactly what a controller with no stored
                              // frame shows — and FIELD_GUIDE tells the reader
                              // that means no frame was stored and is not bad
                              // news. The next control on this screen destroys
                              // the frame permanently. One Mode 02 timeout was
                              // enough to walk somebody through that.
                              if (scan.freezeFrameUnread) ...[
                                Panel(
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Icon(Icons.help_outline,
                                          size: 18, color: palette.warning),
                                      const SizedBox(width: Spacing.xs),
                                      Expanded(
                                        child: Text(
                                          '這次沒有讀到凍結幀 —— 不代表車上沒有。'
                                          '請先重新掃描再決定要不要清除故障碼，'
                                          '因為清除會永久銷毀故障當下的紀錄。'
                                          '如果每次掃描都一樣，可能是這台車不提供。',
                                          style: context.texts.bodySmall,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: Spacing.lg),
                              ],
                              // Above the readiness card, because it is about
                              // the fault somebody came here for, and readiness
                              // is about a test they may take later.
                              for (final frame in scan.freezeFrames) ...[
                                _FreezeFrameCard(frame: frame),
                                const SizedBox(height: Spacing.lg),
                              ],
                              if (scan.mil != null) ...[
                                _ReadinessCard(status: scan.mil!),
                                const SizedBox(height: Spacing.lg),
                              ],
                              for (final entry in scan.unanswered)
                                Padding(
                                  padding:
                                      const EdgeInsets.only(bottom: Spacing.md),
                                  child: _UnansweredCategory(
                                    // Heard from, not completed. See
                                    // `heardFromAnyone`.
                                    storedAnswered: results[DtcKind.stored]
                                            ?.heardFromAnyone ??
                                        false,
                                    kind: entry.key,
                                    result: entry.value,
                                  ),
                                ),
                              if (verdict == ScanVerdict.completeClean)
                                Panel(
                                  accent: palette.success,
                                  isActive: true,
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.verified_outlined,
                                        color: palette.success,
                                        size: 22,
                                      ),
                                      const SizedBox(width: Spacing.md),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              '已回應的控制器都沒有故障碼。',
                                              style: context.texts.titleSmall,
                                            ),
                                            const SizedBox(height: Spacing.xs),
                                            // The previous wording — 沒有偵測到
                                            // 任何故障碼 — described the whole
                                            // vehicle, which is more than the
                                            // scan establishes. A controller
                                            // whose reply is lost outright
                                            // leaves nothing to count as
                                            // missing, and the app has no
                                            // inventory of who should have
                                            // answered.
                                            Text(
                                              '這代表每個回覆的控制器都回報無故障碼，'
                                              '不代表車上每個模組都已被問到。',
                                              style: context.texts.bodySmall,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                )
                              else if (verdict == ScanVerdict.partialClean)
                                Panel(
                                  accent: palette.warning,
                                  isActive: true,
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.help_outline,
                                        color: palette.warning,
                                        size: 22,
                                      ),
                                      const SizedBox(width: Spacing.md),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              '已回應的項目沒有故障碼。',
                                              style: context.texts.titleSmall,
                                            ),
                                            const SizedBox(height: Spacing.xs),
                                            // Two different situations wore the
                                            // same sentence, and one of them is
                                            // an ordinary healthy car.
                                            //
                                            // Modes 07 and 0A are optional in
                                            // J1979. A vehicle whose
                                            // transmission answers Mode 03 and
                                            // implements neither is compliant
                                            // and fine — and reading 沒有回應，
                                            // 狀態無法確認 next to it sends
                                            // somebody debugging behaviour that
                                            // is correct. That is different
                                            // from a class nobody answered at
                                            // all, which is a real gap.
                                            if (unansweredLabel.isEmpty &&
                                                scan.optionalGaps.isNotEmpty)
                                              Text(
                                                '三個類別都查詢完成了。'
                                                '有 ${scan.optionalGaps.length} 個控制器'
                                                '（${scan.optionalGaps.join('、')}）'
                                                '沒有實作待確認或永久故障碼 —— '
                                                '這在很多車上是正常的，'
                                                '但也因此不能宣告全車都沒有故障碼。',
                                                style: context.texts.bodySmall,
                                              )
                                            else
                                              Text(
                                                '$unansweredLabel 沒有回應，'
                                                '狀態無法確認 — 這不等於車輛沒有問題。',
                                                style: context.texts.bodySmall,
                                              ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                )
                              else
                                for (final kind in DtcKind.values)
                                  if ((results[kind]?.codes ?? const [])
                                      .isNotEmpty)
                                    _DtcGroup(
                                      kind: kind,
                                      codes: results[kind]!.codes,
                                    ),
                            ],
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DtcGroup extends StatelessWidget {
  const _DtcGroup({required this.kind, required this.codes});

  final DtcKind kind;
  final List<Dtc> codes;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final tone = switch (kind) {
      DtcKind.stored => palette.danger,
      DtcKind.pending => palette.warning,
      DtcKind.permanent => palette.derived,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: Spacing.md, top: Spacing.lg),
          child: Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(shape: BoxShape.circle, color: tone),
              ),
              const SizedBox(width: Spacing.sm),
              Text(
                '${kind.label}（Mode ${kind.mode}）· ${codes.length}',
                style: context.texts.labelSmall?.copyWith(color: tone),
              ),
            ],
          ),
        ),
        Text(kind.description, style: context.texts.bodySmall),
        const SizedBox(height: Spacing.md),
        ...codes.map(
          (dtc) => Padding(
            padding: const EdgeInsets.only(bottom: Spacing.sm),
            child: Panel(
              accent: tone,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Spacing.md,
                      vertical: Spacing.sm,
                    ),
                    decoration: BoxDecoration(
                      color: tone.withValues(alpha: 0.13),
                      borderRadius: BorderRadius.circular(Radii.sm),
                      border: Border.all(color: tone.withValues(alpha: 0.30)),
                    ),
                    child: Text(
                      dtc.code,
                      style: AppTypography.code(palette, size: 15, color: tone)
                          .copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(width: Spacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          dtc.description ??
                              (dtc.isManufacturerSpecific
                                  ? '原廠自訂碼 — 需查閱該車系維修手冊'
                                  // The subsystem where the code's own third
                                  // digit gives one. 動力系統相關故障 is true
                                  // of every code on this screen and therefore
                                  // tells nobody anything.
                                  : dtc.subsystem != null
                                      ? '${dtc.subsystem} — 本 App 沒有這一碼的'
                                          '詳細說明'
                                      : '${dtc.category.label}相關故障'),
                          style: context.texts.bodyMedium?.copyWith(
                            color: palette.textPrimary,
                          ),
                        ),
                        const SizedBox(height: Spacing.xs),
                        Text(
                          // Named where the reply carried a header. Two
                          // modules reporting the same code is two of them
                          // seeing the fault, which is usually the difference
                          // between one problem and two — and the parser knew
                          // it all along.
                          dtc.sourceId == null
                              ? dtc.category.label
                              : '${dtc.category.label} · 控制器 ${dtc.sourceId}',
                          style: context.texts.labelSmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A class of fault codes that did not answer this scan.
///
/// Rendered explicitly rather than omitted. An omitted class is
/// indistinguishable from an empty one, and the difference between "the
/// transmission reported no permanent faults" and "the transmission never
/// answered" is the whole point of the screen.
class _UnansweredCategory extends StatelessWidget {
  const _UnansweredCategory({
    required this.kind,
    required this.result,
    required this.storedAnswered,
  });

  /// Whether Mode 03 answered.
  ///
  /// Changes what silence from an optional class *means*. If the one service
  /// every OBD-II vehicle must implement also went unanswered, the link or the
  /// ignition is the likelier explanation than the vehicle lacking a feature —
  /// so this must not say "此車輛未提供".
  final bool storedAnswered;

  final DtcKind kind;
  final DtcCategoryResult result;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final wording = unansweredCategoryWording(
      kind: kind,
      result: result,
      storedAnswered: storedAnswered,
    );
    final tone =
        wording.ordinarySilence ? palette.textSecondary : palette.warning;
    final ordinarySilence = wording.ordinarySilence;
    final headline = wording.headline;
    final detail = wording.detail;

    return Panel(
      accent: tone,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ordinarySilence
                ? Icons.remove_circle_outline
                : Icons.help_outline,
            color: tone,
            size: 20,
          ),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(headline, style: context.texts.titleSmall),
                const SizedBox(height: Spacing.xs),
                Text(detail, style: context.texts.bodySmall),
                // Codes this category *did* read before it had to stop.
                //
                // They were retained on the exception, exposed on the result,
                // and then rendered by nobody — so a real P0300 reported by a
                // named controller could sit in memory while the screen said
                // 已回應的項目沒有故障碼. Incomplete coverage is a reason to
                // qualify a finding, never to hide it.
                if (result.partial.isNotEmpty) ...[
                  const SizedBox(height: Spacing.md),
                  Text(
                    '這個類別中止前已讀到 ${result.partial.length} 筆故障碼，'
                    '但涵蓋範圍不完整：',
                    style: context.texts.bodySmall,
                  ),
                  const SizedBox(height: Spacing.sm),
                  Wrap(
                    spacing: Spacing.sm,
                    runSpacing: Spacing.sm,
                    children: [
                      // The controller travels with the code here as it
                      // does in a complete result. Two modules independently
                      // observing P0300 is different information from one
                      // module observing it, and rendering both as a bare
                      // `P0300` pill showed the user two identical chips with
                      // nothing to distinguish them — the attribution was
                      // carried the whole way and then dropped in the last
                      // widget.
                      for (final dtc in result.partial)
                        StatusPill(
                          label: dtc.sourceId == null
                              ? dtc.code
                              : '${dtc.code} · ${dtc.sourceId}',
                          tone: StatusTone.warn,
                          dense: true,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// What an unanswered fault-code category should say.
///
/// Extracted so the wording can be tested against the transcripts that broke
/// it, rather than only by rendering a screen that needs a live scan behind
/// it. Three separate facts decide it and they were being conflated: whether
/// the mandatory class answered, *who* answered this one, and whether anything
/// was decoded.
class UnansweredCategoryWording {
  const UnansweredCategoryWording({
    required this.headline,
    required this.detail,
    required this.ordinarySilence,
  });

  final String headline;
  final String detail;

  /// True only when this optional category was heard from by nobody at all,
  /// on a connection whose mandatory class did answer.
  final bool ordinarySilence;
}

UnansweredCategoryWording unansweredCategoryWording({
  required DtcKind kind,
  required DtcCategoryResult result,
  required bool storedAnswered,
}) {
  // Silence on an optional class is ordinary; on Mode 03 it means the question
  // went unanswered, which the driver needs to weigh differently.
  final isOptional = kind != DtcKind.stored;

  // Nobody answered — not "nothing was decoded".
  //
  // Whether a code came out is a different fact from whether a controller
  // replied, and every wording below depends on the second. A Mode 07 that
  // `7E8` answered cleanly while `7E9` stayed silent has no codes and no
  // partial, and calling that "this vehicle does not provide the category" is
  // false twice over: it was provided, and what is unknown is one controller's
  // coverage.
  //
  // An earlier version of this read `result.codes`, which a failed category
  // always leaves empty — so the guard was true in exactly the case it was
  // written to exclude.
  // A controller that said it was still working identified itself and named
  // the service; that is not nobody.
  final answeredByNobody = result.answeredBy.isEmpty &&
      result.partial.isEmpty &&
      (result.failure?.pendingSources.isEmpty ?? true) &&
      (result.failure?.heardAboutService.isEmpty ?? true);
  final ordinarySilence =
      result.isSilence && isOptional && storedAnswered && answeredByNobody;

  // Not "this vehicle does not provide the category".
  //
  // `NO DATA` is the adapter reporting that no matching message reached it
  // before its window closed — the datasheet allows that for a message that
  // never came *and* for one that failed the receive criteria. It cannot tell
  // an unimplemented service from a lost, filtered or late reply, and it says
  // nothing at all about whether a fault exists. Both claims were being made
  // from it.
  final headline = result.isSilence
      ? (ordinarySilence ? '這個類別沒有回應' : '無法確認')
      : '讀取失敗';

  final String detail;
  if (ordinarySilence) {
    // Mode 07 and Mode 0A are not the same feature and were sharing one
    // sentence. Pending codes have been part of OBD-II since 1996; it is
    // *permanent* codes that arrived with the 2010-2012 generation. Telling a
    // driver that their 2004 car is too old for pending codes is simply wrong.
    detail = switch (kind) {
      DtcKind.permanent =>
        '永久故障碼（Mode 0A）沒有回應。這個類別在 2010 年前後才隨新一代 OBD-II 導入，'
            '較舊的車輛不一定支援 —— 但沒有回應也可能只是這次沒讀到，'
            '兩者無法分辨。已儲存故障碼的結果不受影響。',
      DtcKind.pending =>
        '待確認故障碼（Mode 07）沒有回應。可能是這具 ECU 未實作這個服務，'
            '也可能是這次沒有讀到 —— 沒有回應無法分辨兩者，'
            '也不能當作「沒有待確認故障」。已儲存故障碼的結果不受影響。',
      DtcKind.stored => '',
    };
  } else if (result.isSilence) {
    if (!isOptional) {
      detail = '車輛沒有回應 Mode ${kind.mode} 查詢，因此無法確認是否有已儲存的故障碼。'
          '這與「沒有故障碼」不是同一件事。';
    } else if (!answeredByNobody) {
      // Some controllers answered and some did not. Saying the vehicle did not
      // respond is false, and so is saying Mode 03 was silent.
      detail = '這個類別只有部分控制器回應，其餘沒有回覆，因此不能當作全車的結果。'
          '${result.failure?.message ?? ''}';
    } else {
      detail = '車輛沒有回應 Mode ${kind.mode} 查詢，而 Mode 03 同樣沒有回應 — '
          '因此無法判斷這是車輛不支援，還是這次連線沒有讀到。';
    }
  } else {
    detail =
        '${kind.label}（Mode ${kind.mode}）：${result.failure?.message ?? '未知錯誤'}';
  }

  return UnansweredCategoryWording(
    headline: headline,
    detail: detail,
    ordinarySilence: ordinarySilence,
  );
}

/// The dashboard lamp, and whether the car is ready for an inspection.
///
/// The bytes for this have been arriving since the beginning — `readMilStatus`
/// requires a full six-byte reply *specifically* so B, C and D are known to
/// have arrived — and were being read for byte A alone. This is the rest of
/// the reply the vehicle was already sending.
///
/// It closes a loop the app had left open at exactly the wrong end. Every
/// clear here warns that 清除會重置排放就緒狀態 and that the car then needs a
/// full drive cycle before it can pass a test; until now it could say that and
/// never show it, so nobody could tell whether they had just done it.
/// The car as it was at the instant the controller confirmed the fault.
///
/// The reason this earns space above the readiness card: every other panel on
/// this screen describes the vehicle *now*, sitting still with the problem very
/// likely not occurring. This is the only view of it while the fault was
/// actually happening, and it cannot be recovered — the clear button two
/// hundred lines up destroys it.
///
/// It names the code that stored it in its own heading rather than in body
/// text, because a car with three stored codes has a frame belonging to exactly
/// one of them, and a snapshot read as belonging to the wrong fault is worse
/// than no snapshot.
class _FreezeFrameCard extends StatelessWidget {
  const _FreezeFrameCard({required this.frame});

  final FreezeFrame frame;

  /// Enough digits to be useful, not so many as to imply precision the sensor
  /// does not have. A frozen RPM of 2856 is a count; a frozen MAF of 18.4 g/s
  /// is a measurement to a tenth.
  static String _format(FreezeReading reading) {
    final v = reading.value;
    final text = v.abs() >= 100 || v == v.roundToDouble()
        ? v.toStringAsFixed(0)
        : v.toStringAsFixed(1);
    return reading.pid.units.isEmpty ? text : '$text ${reading.pid.units}';
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.ac_unit, size: 18, color: palette.accent),
              const SizedBox(width: Spacing.xs),
              Expanded(
                child: Text('故障發生當下的車況',
                    style: context.texts.titleSmall),
              ),
              Text('控制器 ${frame.source}', style: context.texts.labelSmall),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            '${frame.cause.code} 被確認的那一刻，這個控制器記下的數值。'
            '清除故障碼會一併銷毀這份紀錄。',
            style: context.texts.bodySmall,
          ),
          const SizedBox(height: Spacing.sm),
          if (frame.readings.isEmpty)
            Text(
              // Two different failures, two different sentences, because they
              // ask for different things. "We read it and understood none of
              // it" is a limit of this app. "It would not tell us" is worth
              // another scan.
              frame.contentsUnknown
                  ? '這個控制器有凍結幀，但沒有回應「裡面有哪些項目」的查詢，'
                      '所以讀不到內容。可以重新掃描再試一次。'
                  : '這個控制器有凍結幀，但其中沒有本 App 能解讀的項目。',
              style: context.texts.bodySmall
                  ?.copyWith(color: palette.textSecondary),
            )
          else
            // A two-column table rather than chips: these are name/value pairs
            // somebody reads down, often against a printout, and a wrap of
            // pills makes that scan impossible.
            Column(
              children: [
                for (final reading in frame.readings)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(reading.pid.name,
                              style: context.texts.bodySmall),
                        ),
                        const SizedBox(width: Spacing.sm),
                        Text(
                          _format(reading),
                          style: context.texts.bodySmall?.copyWith(
                            color: palette.textPrimary,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          if (frame.undecodable > 0) ...[
            const SizedBox(height: Spacing.xs),
            // Said rather than silently omitted, for the reason the readiness
            // card lists unsupported monitors: a list shortened to what the app
            // understands looks like the whole frame to somebody comparing it
            // against a scan tool.
            Text(
              '另有 ${frame.undecodable} 個項目在這份凍結幀裡，本 App 沒有對應的換算公式，'
              '所以沒有列出。',
              style: context.texts.labelSmall
                  ?.copyWith(color: palette.textTertiary),
            ),
          ],
          if (frame.unread > 0) ...[
            const SizedBox(height: Spacing.xs),
            // A different sentence from the one above, because it asks for a
            // different thing. "No formula here" is a limit to accept; "did not
            // come back" is worth another scan, and the freeze read runs last
            // under the scan's deadline so this is the one that shows up on a
            // slow adapter.
            Text(
              '有 ${frame.unread} 個項目這次沒有讀回來（可能是時間不夠或控制器沒回應）。'
              '重新掃描可能會讀到。',
              style: context.texts.labelSmall
                  ?.copyWith(color: palette.warning),
            ),
          ],
        ],
      ),
    );
  }
}

class _ReadinessCard extends StatelessWidget {
  const _ReadinessCard({required this.status});

  final MilStatus status;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    // One card per controller, because these are per-controller claims and
    // merging them is how one module's readiness became the vehicle's.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in status.bySource.entries) ...[
          _ReadinessForSource(
            source: entry.key,
            summary: entry.value,
            palette: palette,
          ),
          const SizedBox(height: Spacing.sm),
        ],
      ],
    );
  }
}

class _ReadinessForSource extends StatelessWidget {
  const _ReadinessForSource({
    required this.source,
    required this.summary,
    required this.palette,
  });

  final String source;
  final MilSummary summary;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final readiness = summary.readiness;
    final incomplete = readiness?.incomplete ?? const [];
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                summary.milOn ? Icons.error : Icons.check_circle_outline,
                size: 18,
                color: summary.milOn ? palette.danger : palette.success,
              ),
              const SizedBox(width: Spacing.xs),
              Expanded(
                child: Text(
                  summary.milOn ? '故障燈亮著' : '故障燈沒有亮',
                  style: context.texts.titleSmall,
                ),
              ),
              Text('控制器 $source', style: context.texts.labelSmall),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            summary.confirmedCount > 0
                ? '這個控制器自報有 ${summary.confirmedCount} 個已確認的故障碼。'
                : '這個控制器自報沒有已確認的故障碼。',
            style: context.texts.bodySmall,
          ),
          if (readiness != null) ...[
            const SizedBox(height: Spacing.md),
            Text('排放就緒狀態', style: context.texts.labelMedium),
            const SizedBox(height: Spacing.xs),
            Text(
              readiness.saysNothing
                  // Not "ready". A module that does not participate in
                  // emissions monitoring answers with all zeroes, and reading
                  // that as a clean bill of health turns silence into an
                  // answer.
                  ? '這個控制器沒有回報任何監控項目 —— 它可能不負責排放監控，'
                      '這不代表已經就緒。'
                  // `allSupportedComplete`, not `incomplete.isEmpty`. The
                  // decoder counts monitors this table cannot name so that one
                  // left unfinished still blocks "ready"; asking only about the
                  // named ones threw that away here and told somebody driving
                  // to an inspection that everything was done.
                  : readiness.allSupportedComplete
                      ? '這個控制器負責的監控項目都已完成。'
                      : '還有 ${incomplete.length + readiness.unnamedOutstanding} '
                          '項沒有完成，現在去驗車可能不會過。',
              style: context.texts.bodySmall,
            ),
            const SizedBox(height: Spacing.sm),
            Wrap(
              spacing: Spacing.xs,
              runSpacing: Spacing.xs,
              children: [
                for (final entry in readiness.states.entries)
                  // Unsupported monitors are listed rather than hidden: "this
                  // car does not have that one" is an answer somebody
                  // comparing against an inspection report needs, and hiding
                  // it makes a complete list look short.
                  _MonitorChip(
                    label: entry.key.label,
                    state: entry.value,
                    palette: palette,
                  ),
                // The ones the table has no name for, drawn rather than
                // dropped. Without these the sentence above could say "2 left"
                // over a row where every chip read ✓ or — and the card
                // contradicted itself in a single glance. One chip each, not a
                // count, because the number in the sentence has to be
                // countable here — that reconciliation against an inspection
                // report is the whole reason this row exists.
                for (var i = 0; i < readiness.unnamedOutstanding; i++)
                  _MonitorChip(
                    label: '未知監控項目',
                    state: ReadinessState.incomplete,
                    palette: palette,
                  ),
                for (var i = 0;
                    i < readiness.unnamedSupported - readiness.unnamedOutstanding;
                    i++)
                  _MonitorChip(
                    label: '未知監控項目',
                    state: ReadinessState.complete,
                    palette: palette,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _MonitorChip extends StatelessWidget {
  const _MonitorChip({
    required this.label,
    required this.state,
    required this.palette,
  });

  /// The monitor's name, or a stand-in for one the decoder could not name.
  final String label;
  final ReadinessState state;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final (colour, mark) = switch (state) {
      ReadinessState.complete => (palette.success, '✓'),
      ReadinessState.incomplete => (palette.warning, '…'),
      // Deliberately the quietest of the three. It is not a problem and must
      // not compete for attention with the one that is.
      ReadinessState.unsupported => (palette.textTertiary, '—'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm, vertical: Spacing.xs),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colour.withValues(alpha: 0.5)),
      ),
      child: Text(
        '$mark $label',
        style: context.texts.labelSmall?.copyWith(color: colour),
      ),
    );
  }
}
