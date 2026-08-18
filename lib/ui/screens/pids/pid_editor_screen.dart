/// Custom PID editor with a live formula preview.
///
/// The preview is the point: a formula is only correct against real bytes, so
/// the editor evaluates what the user typed against either the live reading or
/// a sample payload they can edit, and shows the result as they type.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../obd/addressing.dart';
import '../../../obd/pid/formula_engine.dart';
import '../../../obd/pid/pid.dart';
import '../../../obd/pid/priority_tier.dart';
import '../../../state/pid_registry.dart';
import '../../widgets/gauges/linear_gauge.dart';
import '../../widgets/panel.dart';

class PidEditorScreen extends ConsumerStatefulWidget {
  const PidEditorScreen({this.pidId, super.key});

  static const String path = '/pid-editor';

  final String? pidId;

  @override
  ConsumerState<PidEditorScreen> createState() => _PidEditorScreenState();
}

class _PidEditorScreenState extends ConsumerState<PidEditorScreen> {
  late final TextEditingController _name;
  late final TextEditingController _shortName;
  late final TextEditingController _modeAndPid;
  late final TextEditingController _equation;
  late final TextEditingController _min;
  late final TextEditingController _max;
  late final TextEditingController _units;
  late final TextEditingController _header;
  late final TextEditingController _sample;

  PriorityTier _priority = PriorityTier.medium;
  Pid? _original;

  /// The field values as they were when the screen opened.
  ///
  /// Compared on the way out so a back gesture cannot silently discard work.
  /// A formula takes real effort to get right, and losing one to a stray swipe
  /// is the kind of small betrayal people remember.
  late final Map<TextEditingController, String> _initialText;
  late final PriorityTier _initialPriority;

  bool get _isDirty =>
      _priority != _initialPriority ||
      _initialText.entries.any((e) => e.key.text != e.value);

  @override
  void initState() {
    super.initState();
    final existing = widget.pidId == null
        ? null
        : ref.read(pidRegistryProvider.notifier).byId(widget.pidId!);
    _original = existing;

    _name = TextEditingController(text: existing?.name ?? '');
    _shortName = TextEditingController(text: existing?.shortName ?? '');
    _modeAndPid = TextEditingController(text: existing?.modeAndPid ?? '01');
    _equation = TextEditingController(text: existing?.equation ?? 'A');
    _min = TextEditingController(text: '${existing?.minValue ?? 0}');
    _max = TextEditingController(text: '${existing?.maxValue ?? 100}');
    _units = TextEditingController(text: existing?.units ?? '');
    _header = TextEditingController(text: existing?.header ?? kDefaultHeader);
    _sample = TextEditingController(text: '41 00 7B 2C');
    _priority = existing?.priority ?? PriorityTier.medium;

    // Every field the save gate reads, not just the ones with a live preview.
    //
    // `_name`, `_header` and `_modeAndPid` were left out because their
    // validation used to run only through `PidDefinition.rejectionReason`,
    // which the build already re-evaluated. The duplicate-identity check reads
    // all three, so a collision created by editing *only* the header went
    // unnoticed until Save — which then destroyed the PID it collided with.
    for (final controller in [
      _equation,
      _sample,
      _min,
      _max,
      _name,
      _header,
      _modeAndPid,
    ]) {
      controller.addListener(() => setState(() {}));
    }

    _initialPriority = _priority;
    _initialText = {
      for (final c in [
        _name,
        _shortName,
        _modeAndPid,
        _equation,
        _min,
        _max,
        _units,
        _header,
      ])
        c: c.text,
    };
  }

  /// Asks before throwing away edits. Returns true when it is safe to leave.
  Future<bool> _confirmDiscard() async {
    if (!_isDirty) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('放棄未儲存的變更？'),
        content: const Text('這個 PID 的修改還沒有儲存，離開後會遺失。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('繼續編輯'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('放棄'),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  @override
  void dispose() {
    for (final controller in [
      _name,
      _shortName,
      _modeAndPid,
      _equation,
      _min,
      _max,
      _units,
      _header,
      _sample,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  /// PIDs this formula depends on via `VAL{...}`.
  Iterable<String> get _dependencies => FormulaEngine.valReferences(_equation.text);

  ({double? value, String? error}) get _preview {
    try {
      final engine = FormulaEngine();
      // At runtime an unresolved `VAL{}` is an error — substituting zero would
      // turn `A-VAL{0133}` into raw manifold pressure labelled as boost. In the
      // editor there is no live data at all, so applying that rule unchanged
      // would make every formula using `VAL{}` permanently unsaveable, even
      // though the help text offers it. Seeding a stand-in value keeps the
      // preview about whether the formula is *well-formed*, which is the only
      // question the editor can answer.
      engine.seedForAuthoring(_equation.text, sample: _sampleDependencyValue);
      final value = engine.evaluate(
        _equation.text,
        _sample.text,
        requester: FormulaEngine.probePid('0000'),
      );
      return (value: value, error: null);
    } on FormulaException catch (e) {
      return (value: null, error: e.message);
    } on Object catch (e) {
      return (value: null, error: '$e');
    }
  }

  /// Stand-in for a dependency the editor cannot read. 100 is chosen because it
  /// is a plausible kPa/percent/°C value and makes the substitution obvious in
  /// the preview rather than looking like a real measurement.
  static const double _sampleDependencyValue = 100;

  /// Why the current request cannot be polled, or null when it can.
  ///
  /// The editor is the other door onto a car's bus, alongside CSV import. A
  /// gauge polls its request over and over for as long as it is on the
  /// dashboard, so a write or control service typed in here would be
  /// transmitted repeatedly — `2F` actuates outputs, `2E` writes ECU
  /// configuration, `31` starts routines.
  String? get _serviceRejection =>
      PollableServices.rejectionReason(_modeAndPid.text.trim().toUpperCase());

  /// Why the definition cannot be saved, or null.
  ///
  /// Shared with the CSV importer, which already refused a malformed range or
  /// header while this screen accepted both — and then substituted `0`/`100`
  /// for bounds it could not parse, giving a gauge a scale nobody chose.
  String? get _definitionRejection =>
      PidDefinition.rejectionReason(
        name: _name.text,
        modeAndPid: PollableServices.normalise(_modeAndPid.text),
        header: _header.text,
        minText: _min.text,
        maxText: _max.text,
        requireBounds: true,
      ) ??
      _collision;

  /// Whether the edited identity already belongs to a different custom PID.
  ///
  /// `Pid.id` is header, mode+PID and variant, and `upsertCustom` replaces by
  /// id. So editing one PID's mode onto another's silently destroyed the
  /// second — its definition gone from the registry, its gauge gone from the
  /// dashboard, and nothing said so. Refusing is the only answer that does not
  /// throw away something the user made.
  String? get _collision {
    final candidate = Pid(
      name: _name.text.trim().isEmpty ? 'x' : _name.text.trim(),
      shortName: '',
      modeAndPid: PollableServices.normalise(_modeAndPid.text),
      equation: 'A',
      minValue: 0,
      maxValue: 1,
      units: '',
      header: BusAddressing.resolveHeader(_header.text),
      isCustom: true,
      variant: _original?.variant,
    );
    if (candidate.id == _original?.id) return null;
    final clash = ref
        .read(pidRegistryProvider)
        .where((p) => p.isCustom && p.id == candidate.id);
    if (clash.isEmpty) return null;
    return '已經有一個自訂 PID 使用這組設定（${clash.first.name}）。'
        '請改用不同的模式 + PID、標頭或名稱後綴。';
  }

  bool get _canSave =>
      _modeAndPid.text.trim().length >= 4 &&
      _definitionRejection == null &&
      _preview.error == null;

  Future<void> _save() async {
    final pid = Pid(
      name: _name.text.trim(),
      shortName: _shortName.text.trim().isEmpty
          ? _name.text.trim()
          : _shortName.text.trim(),
      modeAndPid: PollableServices.normalise(_modeAndPid.text),
      equation: _equation.text.trim(),
      // Not `?? 0` / `?? 100`: unparseable bounds are refused above rather
      // than replaced with a scale the author never chose.
      minValue: double.parse(_min.text.trim()),
      maxValue: double.parse(_max.text.trim()),
      units: _units.text.trim(),
      header: BusAddressing.resolveHeader(_header.text),
      priority: _priority,
      isCustom: true,
      // Carried over so an edit replaces the original entry rather than
      // creating a second one beside it — and so an imported definition keeps
      // whatever distinguished it from a same-PID built-in.
      variant: _original?.variant,
      // Likewise. The importer accepts a redline and this screen has no field
      // for one, so reconstructing without it silently deleted a value the
      // author had set and had not come here to change. An editor may not
      // destroy what it cannot show.
      redlineFrom: _original?.redlineFrom,
    );

    final previous = _original;
    final registry = ref.read(pidRegistryProvider.notifier);
    // Changing the header or the command changes the wire identity, so the old
    // entry is no longer the same signal. Remove it explicitly instead of
    // leaving an orphan the dashboard may still be pointing at.
    final active = ref.read(activePidsProvider.notifier);
    final wasOnDashboard = previous != null && active.contains(previous);
    // Captured before anything moves, because that is the only moment it is
    // still true.
    final index = wasOnDashboard
        ? ref.read(activePidsProvider).indexWhere((p) => p.id == previous.id)
        : -1;

    if (previous != null && previous.id != pid.id) {
      await registry.removeCustom(previous);
    }
    await registry.upsertCustom(pid);

    // Removing the old entry also removed it from the dashboard. Put the
    // replacement back *where it was* — appending sent a gauge the user had
    // placed second to the end of the grid every time they corrected a
    // mistyped PID.
    if (wasOnDashboard) {
      final current = ref.read(activePidsProvider);
      if (index >= 0 && index <= current.length) {
        await active.insert(index, pid);
      } else {
        await active.add(pid);
      }
    }
    if (mounted) context.pop();
  }

  Future<void> _delete() async {
    final pid = _original;
    if (pid == null) return;
    // Asked, because this screen already asks about something smaller.
    //
    // Abandoning an unsaved edit gets a dialog; deleting the whole definition —
    // which also takes the gauge off the dashboard and cannot be undone — took
    // one tap on a bin icon in the app bar. This file's own header calls losing
    // a formula somebody wrote "the kind of small betrayal people remember",
    // and the confirmation was on the lesser of the two actions.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('刪除這個 PID？'),
        content: Text('「${pid.name}」的定義會被移除，儀表板上的這個錶也會一起'
            '消失，而且無法復原。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('刪除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(pidRegistryProvider.notifier).removeCustom(pid);
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final preview = _preview;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
      appBar: AppBar(
        title: Text(_original == null ? '新增自訂 PID' : '編輯 PID'),
        actions: [
          if (_original != null)
            IconButton(
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline),
              tooltip: '刪除',
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          Spacing.lg,
          Spacing.md,
          Spacing.lg,
          Spacing.xxxl,
        ),
        children: [
          const SectionHeading('識別'),
          TextField(
            controller: _name,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: '名稱'),
          ),
          const SizedBox(height: Spacing.md),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _shortName,
                  decoration: const InputDecoration(labelText: '簡稱（顯示於錶面）'),
                ),
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: TextField(
                  controller: _units,
                  decoration: const InputDecoration(labelText: '單位'),
                ),
              ),
            ],
          ),

          const SizedBox(height: Spacing.xl),
          const SectionHeading('查詢'),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _modeAndPid,
                  onChanged: (_) => setState(() {}),
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]')),
                    LengthLimitingTextInputFormatter(8),
                  ],
                  style: AppTypography.code(palette, size: 15, color: palette.textPrimary),
                  decoration: InputDecoration(
                    labelText: '模式 + PID',
                    errorText: _modeAndPid.text.trim().length >= 4
                        ? _serviceRejection
                        : null,
                    errorMaxLines: 3,
                    helperText: '例如 010C 或 221101',
                  ),
                ),
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: TextField(
                  controller: _header,
                  textCapitalization: TextCapitalization.characters,
                  style: AppTypography.code(palette, size: 15, color: palette.textPrimary),
                  decoration: const InputDecoration(
                    labelText: 'CAN 標頭',
                    helperText: '7E0 = 引擎',
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: Spacing.xl),
          const SectionHeading('公式'),
          TextField(
            controller: _equation,
            maxLines: 2,
            style: AppTypography.code(palette, size: 15, color: palette.textPrimary),
            decoration: InputDecoration(
              labelText: '運算式',
              errorText: preview.error,
              helperText: 'A..N 對應回應位元組；可用 SIGNED()、ABS()、LOG10()、VAL{PID}、BARO',
              helperMaxLines: 2,
            ),
          ),
          const SizedBox(height: Spacing.md),
          TextField(
            controller: _sample,
            style: AppTypography.code(palette, size: 15, color: palette.textPrimary),
            decoration: const InputDecoration(
              labelText: '測試用回應位元組',
              helperText: '輸入十六進位，即時預覽計算結果',
            ),
          ),
          const SizedBox(height: Spacing.lg),
          _PreviewPanel(
            value: preview.value,
            error: preview.error,
            substitutedDependencies: _dependencies.toList(),
            units: _units.text,
            minValue: double.tryParse(_min.text) ?? 0,
            maxValue: double.tryParse(_max.text) ?? 100,
            sampleBytes: FormulaEngine.parseUserTypedSampleBytes(_sample.text),
          ),

          const SizedBox(height: Spacing.xl),
          const SectionHeading('錶面範圍與優先權'),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _min,
                  keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                  decoration: const InputDecoration(labelText: '最小值'),
                ),
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: TextField(
                  controller: _max,
                  keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                  decoration: const InputDecoration(labelText: '最大值'),
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          SegmentedButton<PriorityTier>(
            segments: [
              for (final tier in PriorityTier.values.reversed)
                ButtonSegment(value: tier, label: Text(tier.label)),
            ],
            selected: {_priority},
            onSelectionChanged: (s) => setState(() => _priority = s.first),
            showSelectedIcon: false,
          ),

          const SizedBox(height: Spacing.xxl),
          // A disabled save button with no explanation is a dead end. The
          // reason was computed and never shown, so a malformed header or an
          // inverted range simply greyed the button out.
          // Only once there is something to judge. An empty form is not a
          // wrong one, and opening "new PID" to a red error is a poor way to
          // begin.
          if (!_canSave &&
              _modeAndPid.text.trim().length >= 4 &&
              _definitionRejection != null) ...[
            Text(
              _definitionRejection!,
              style: context.texts.bodySmall?.copyWith(color: palette.danger),
            ),
            const SizedBox(height: Spacing.md),
          ],
          FilledButton.icon(
            onPressed: _canSave ? _save : null,
            icon: const Icon(Icons.check, size: 20),
            label: const Text('儲存'),
          ),
        ],
      ),
      ),
    );
  }
}

class _PreviewPanel extends StatelessWidget {
  const _PreviewPanel({
    required this.value,
    required this.error,
    required this.units,
    required this.minValue,
    required this.maxValue,
    required this.sampleBytes,
    required this.substitutedDependencies,
  });

  final double? value;
  final String? error;
  final String units;
  final double minValue;
  final double maxValue;
  final List<int> sampleBytes;

  /// PIDs whose value the editor stood in for, since it has no live data.
  final List<String> substitutedDependencies;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final ok = error == null && value != null;

    return Panel(
      accent: ok ? palette.success : palette.danger,
      isActive: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                ok ? Icons.check_circle_outline : Icons.error_outline,
                size: 16,
                color: ok ? palette.success : palette.danger,
              ),
              const SizedBox(width: Spacing.sm),
              Text('即時預覽', style: context.texts.labelSmall),
            ],
          ),
          const SizedBox(height: Spacing.md),
          if (!ok)
            Text(
              error ?? '無法計算',
              style: context.texts.bodyMedium?.copyWith(color: palette.danger),
            )
          else ...[
            // Show the variable binding, because "why is my formula wrong" is
            // almost always "A is not the byte I thought it was".
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.xs,
              children: [
                for (var i = 0; i < sampleBytes.length && i < 8; i++)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: palette.surfaceAlt,
                      borderRadius: BorderRadius.circular(Radii.sm - 2),
                      border: Border.all(color: palette.hairline),
                    ),
                    child: Text(
                      '${String.fromCharCode(0x41 + i)} = '
                      '0x${sampleBytes[i].toRadixString(16).toUpperCase().padLeft(2, '0')}'
                      ' (${sampleBytes[i]})',
                      style: AppTypography.code(palette, size: 11),
                    ),
                  ),
              ],
            ),
            if (substitutedDependencies.isNotEmpty) ...[
              const SizedBox(height: Spacing.sm),
              Text(
                '預覽時以 100 代入 ${substitutedDependencies.map((d) => 'VAL{$d}').join('、')}；'
                '實際數值會在連線後由該 PID 提供。',
                style: context.texts.bodySmall,
              ),
            ],
            const SizedBox(height: Spacing.lg),
            LinearGauge(
              value: value!,
              minValue: minValue,
              maxValue: maxValue,
              label: '計算結果',
              units: units,
            ),
          ],
        ],
      ),
    );
  }
}
