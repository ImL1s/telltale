/// Searchable, evidence-labelled vehicle-specific traction-battery catalog.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../obd/powertrain_battery/powertrain_battery_profile.dart';
import '../../../obd/powertrain_battery/powertrain_battery_catalog.dart';
import '../../../obd/powertrain_battery/powertrain_battery_probe.dart';
import '../../../obd/powertrain_battery/profile_catalog_validator.dart';
import '../../../obd/powertrain_battery/profile_pid_installer.dart';
import '../../../state/obd_session.dart';
import '../../../state/pid_mutation_lock.dart';
import '../../../state/pid_registry.dart';
import '../../../state/powertrain_battery_profiles.dart';
import '../../../state/powertrain_battery_experiments.dart';
import '../../widgets/panel.dart';

class PowertrainBatteryCatalogScreen extends ConsumerStatefulWidget {
  const PowertrainBatteryCatalogScreen({super.key});

  static const String path = '/powertrain-battery';

  @override
  ConsumerState<PowertrainBatteryCatalogScreen> createState() =>
      _PowertrainBatteryCatalogScreenState();
}

class _PowertrainBatteryCatalogScreenState
    extends ConsumerState<PowertrainBatteryCatalogScreen> {
  static const _filters = <String>[
    'all',
    'PHEV',
    'HEV',
    'BEV',
    'MHEV',
    'REEV',
    'FCEV',
  ];

  late Future<PowertrainBatteryCatalogSnapshot> _catalog;
  String _query = '';
  String _powertrain = 'all';
  String? _probingCommandKey;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    // The shared provider, not a private loader call: the restore path, the
    // dashboard banner and this screen must all see the same verified
    // snapshot (and the same failure), not three separate loads.
    _catalog = ref.read(powertrainBatteryCatalogSnapshotProvider.future);
  }

  void _retry() {
    ref.invalidate(powertrainBatteryCatalogSnapshotProvider);
    setState(_load);
  }

  Future<void> _probeExperimental(
    PowertrainBatteryCatalogSnapshot snapshot,
    PowertrainBatteryProfile profile,
  ) async {
    if (!ref.read(powertrainBatteryExperimentalAccessProvider)) {
      _snack('請先到設定開啟「大電池證據實驗室」。');
      return;
    }
    if (!ref.read(obdSessionProvider).isConnected) {
      _snack('請先連線；實驗授權不會跨連線保留。');
      return;
    }
    final quarantine = ref
        .read(powertrainExperimentalProbeConsentsProvider.notifier)
        .quarantineReason(profile.id);
    if (quarantine != null) {
      _snack('本次連線已隔離：$quarantine');
      return;
    }

    final command = await _chooseExperimentalCommand(profile);
    if (command == null || !mounted) return;
    final year = await _confirmExperimentalProbe(profile, command);
    if (year == null || !mounted) return;

    final session = ref.read(obdSessionProvider.notifier);
    final decision = ref
        .read(powertrainExperimentalProbeConsentsProvider.notifier)
        .authorize(
          snapshot: snapshot,
          profileId: profile.id,
          commandKey: command.wireKey,
          vehicleYear: year,
          connectionGeneration: session.connectionGeneration,
        );
    if (!decision.accepted) {
      _snack('未授權：${decision.reason}');
      return;
    }

    setState(() => _probingCommandKey = command.wireKey);
    try {
      final result = await session.probePowertrainBatteryCommand(
        snapshot: snapshot,
        profileId: profile.id,
        commandKey: command.wireKey,
        vehicleYear: year,
      );
      if (mounted) await _showProbeResult(result);
    } on Object catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Telltale powertrain battery laboratory',
          context: ErrorDescription('while running a one-shot probe'),
        ),
      );
      if (mounted) _snack('單次查詢沒有完成；沒有發布或保留數值。');
    } finally {
      if (mounted) setState(() => _probingCommandKey = null);
    }
  }

  Future<void> _installProfile(
    PowertrainBatteryCatalogSnapshot snapshot,
    PowertrainBatteryProfile profile,
  ) async {
    // Captured before the dialog opens. The install dialog doubles as this
    // connection's vehicle confirmation, and that statement is about the
    // vehicle on the wire *now* — if the connection changes while the
    // dialog sits open, the acceptance must not authorize whatever
    // connected next; the dashboard banner will ask for it instead.
    final session = ref.read(obdSessionProvider.notifier);
    final wasConnected = ref.read(obdSessionProvider).isConnected;
    final generationAtPrompt = session.connectionGeneration;

    final year = await _confirmInstall(profile);
    if (year == null || !mounted) return;

    // Serialize with the startup restore: installing before it finishes
    // would persist a reference list that misses whatever restore was about
    // to rebuild. An integrity failure means the catalog itself is not
    // usable; any other failure is retryable, so re-arm the provider and
    // say so instead of locking installation behind a misleading message
    // until the next app start.
    try {
      await ref.read(installedPowertrainProfilesRestoreProvider.future);
    } on PowertrainBatteryCatalogAssetException {
      _snack('目錄尚未通過驗證，無法安裝。');
      return;
    } on Object {
      ref.invalidate(installedPowertrainProfilesRestoreProvider);
      _snack('還原先前安裝時發生儲存錯誤，已重新排程，請再試一次。');
      return;
    }
    if (!mounted) return;

    try {
      final outcome = await ref
          .read(pidRegistryProvider.notifier)
          .installPowertrainProfile(snapshot, profile.id, vehicleYear: year);
      if (outcome.isLocked) {
        _snack(kPidMutationLockedMessage);
        return;
      }
    } on PowertrainProfileInstallException catch (error) {
      _snack('無法安裝：${error.message}');
      return;
    }

    // A live connection can be confirmed in the same gesture — but only the
    // connection the dialog was opened against.
    if (wasConnected &&
        ref.read(obdSessionProvider).isConnected &&
        session.connectionGeneration == generationAtPrompt) {
      ref
          .read(powertrainProfileAuthorizationsProvider.notifier)
          .authorize(
            snapshot: snapshot,
            profileId: profile.id,
            vehicleYear: year,
            connectionGeneration: generationAtPrompt,
          );
    }
    final signals = profile.commands.fold<int>(
      0,
      (total, command) => total + command.signals.length,
    );
    _snack('已安裝 $signals 個訊號。到 PID 頁面加入儀表板；每次連線需確認車輛。');
    setState(() {});
  }

  Future<void> _uninstallProfile(PowertrainBatteryProfile profile) async {
    final outcome = await ref
        .read(pidRegistryProvider.notifier)
        .uninstallPowertrainProfile(profile.id);
    if (outcome.isLocked) {
      _snack(kPidMutationLockedMessage);
      return;
    }
    ref
        .read(powertrainProfileAuthorizationsProvider.notifier)
        .revoke(profile.id);
    _snack('已移除 ${profile.displayName} 的已安裝訊號。');
    setState(() {});
  }

  static String _installDisclosure(PowertrainBatteryProfile profile) {
    const prefix =
        '安裝只是把唯讀電池 PID 加進 PID 管理。開始讀取前，'
        '每次連線都要在儀表板確認「這台車就是這個車型」。';
    return switch (profile.status) {
      PowertrainProfileStatus.community =>
        '$prefix資料來自社群來源並經獨立比對，仍非原廠保證。',
      PowertrainProfileStatus.experimental =>
        '$prefix這是實驗解碼，沒有獨立佐證要求，本車未驗證，仍非原廠保證。',
      PowertrainProfileStatus.ready => '$prefix來源資料較完整，仍非原廠保證。',
      PowertrainProfileStatus.researchOnly => '$prefix此列僅供研究，不應安裝。',
    };
  }

  Future<int?> _confirmInstall(PowertrainBatteryProfile profile) =>
      showDialog<int>(
        context: context,
        builder: (context) {
          var year = profile.yearFrom;
          var identityAcknowledged = false;
          final years = [
            for (var value = profile.yearFrom; value <= profile.yearTo; value++)
              value,
          ];
          return StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              title: const Text('安裝車型電池訊號'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${profile.market} · ${profile.make} ${profile.model}\n'
                      '${profile.variant} · ${profile.powertrain}',
                    ),
                    const SizedBox(height: Spacing.sm),
                    Text(
                      '主要來源：${profile.source.name}（${profile.source.license}）',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    for (final source in profile.secondarySources)
                      Text(
                        '獨立佐證：${source.name}（${source.license}）',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    const SizedBox(height: Spacing.sm),
                    Text(
                      _installDisclosure(profile),
                      key: const Key('powertrain_install_disclosure'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: Spacing.md),
                    if (years.length > 1)
                      DropdownButtonFormField<int>(
                        key: const Key('powertrain_install_year'),
                        initialValue: year,
                        decoration: const InputDecoration(labelText: '車輛年式'),
                        items: [
                          for (final value in years)
                            DropdownMenuItem(
                              value: value,
                              child: Text('$value'),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) setDialogState(() => year = value);
                        },
                      )
                    else
                      Text('車輛年式：$year'),
                    const SizedBox(height: Spacing.sm),
                    CheckboxListTile(
                      key: const Key('powertrain_install_identity_ack'),
                      value: identityAcknowledged,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('我的車輛符合上述市場、車型與年式'),
                      onChanged: (value) => setDialogState(
                        () => identityAcknowledged = value ?? false,
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                FilledButton(
                  key: const Key('powertrain_confirm_install'),
                  onPressed: identityAcknowledged
                      ? () => Navigator.pop(context, year)
                      : null,
                  child: const Text('安裝'),
                ),
              ],
            ),
          );
        },
      );

  Future<PowertrainBatteryCommand?> _chooseExperimentalCommand(
    PowertrainBatteryProfile profile,
  ) => showDialog<PowertrainBatteryCommand>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('選擇一條固定唯讀查詢'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.lg,
            0,
            Spacing.lg,
            Spacing.sm,
          ),
          child: Text(
            '每次只送一條，不掃描、不批次、不自動重試。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        for (final command in profile.commands)
          SimpleDialogOption(
            key: Key(
              'powertrain_probe_command_${profile.id}_${command.modeAndIdentifier}',
            ),
            onPressed: () => Navigator.pop(context, command),
            child: Text(
              '${command.modeAndIdentifier} · '
              '${command.requestHeader} → ${command.expectedResponder}\n'
              '${command.signals.map((signal) => signal.name).join('、')}',
            ),
          ),
      ],
    ),
  );

  Future<int?> _confirmExperimentalProbe(
    PowertrainBatteryProfile profile,
    PowertrainBatteryCommand command,
  ) => showDialog<int>(
    context: context,
    builder: (context) {
      var year = profile.yearFrom;
      var identityAcknowledged = false;
      var parkedAcknowledged = false;
      final years = [
        for (var value = profile.yearFrom; value <= profile.yearTo; value++)
          value,
      ];
      return StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('單次實驗唯讀確認'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${profile.market} · ${profile.make} ${profile.model}\n'
                  '${profile.variant} · ${profile.powertrain}',
                ),
                const SizedBox(height: Spacing.sm),
                Text(
                  'TX ${command.requestHeader} ${command.modeAndIdentifier}\n'
                  '只接受 RX ${command.expectedResponder}，'
                  '資料長度 ${command.payloadLength} bytes',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: Spacing.sm),
                Text(
                  '來源檔 SHA-256：${profile.source.artifactSha256.substring(0, 12)}…',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                const SizedBox(height: Spacing.sm),
                Text(
                  _identityEvidenceSummary(profile.identityEvidence),
                  key: const Key('powertrain_experimental_identity_evidence'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: Spacing.sm),
                Text(
                  '這是來源作者標示的候選讀取，不是原廠或跨車款安全保證；'
                  'ELM327 只負責轉送命令。原始指令與回覆會留在本機診斷紀錄，'
                  '不會由此功能自動上傳；解碼值不會安裝成 PID 或加入儀表。'
                  '取消不影響一般 OBD 功能。',
                  key: const Key('powertrain_experimental_data_disclosure'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: Spacing.md),
                DropdownButtonFormField<int>(
                  key: const Key('powertrain_experimental_year'),
                  initialValue: year,
                  decoration: const InputDecoration(labelText: '車輛年式'),
                  items: [
                    for (final value in years)
                      DropdownMenuItem(value: value, child: Text('$value')),
                  ],
                  onChanged: (value) {
                    if (value != null) setDialogState(() => year = value);
                  },
                ),
                const SizedBox(height: Spacing.sm),
                CheckboxListTile(
                  key: const Key('powertrain_experimental_identity_ack'),
                  value: identityAcknowledged,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('我已核對來源已知的市場、車型與年式，並接受未證實欄位'),
                  onChanged: (value) => setDialogState(
                    () => identityAcknowledged = value ?? false,
                  ),
                ),
                CheckboxListTile(
                  key: const Key('powertrain_experimental_parked_ack'),
                  value: parkedAcknowledged,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('車輛已安全停妥；我知道這只讀一次，數字仍可能不適用'),
                  onChanged: (value) =>
                      setDialogState(() => parkedAcknowledged = value ?? false),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('powertrain_confirm_experimental_probe'),
              onPressed: identityAcknowledged && parkedAcknowledged
                  ? () => Navigator.pop(context, year)
                  : null,
              child: const Text('只讀這一次'),
            ),
          ],
        ),
      );
    },
  );

  Future<void> _showProbeResult(
    PowertrainBatteryProbeResult result,
  ) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(result.passed ? '單次查詢通過' : '單次查詢已拒絕'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'catalog ${result.catalogSha256.substring(0, 12)}…\n'
              'source ${result.sourceRevision.substring(0, 12)}…\n'
              'TX ${result.command?.requestHeader ?? '—'} '
              '${result.command?.modeAndIdentifier ?? '—'}\n'
              'RX ${result.responder ?? '—'}',
            ),
            const SizedBox(height: Spacing.sm),
            if (result.rawResponseBytes.isNotEmpty)
              SelectableText(
                'RAW ${_hex(result.rawResponseBytes)}',
                key: const Key('powertrain_probe_raw_result'),
              ),
            if (result.passed) ...[
              const SizedBox(height: Spacing.sm),
              const Text('已通過 responder、echo、exact length、公式與範圍檢查。'),
              for (final reading in result.readings)
                Text(
                  '${reading.signal.name}: ${reading.value} '
                  '${reading.signal.unit} · bytes ${_hex(reading.rawBytes)}',
                ),
            ] else ...[
              const SizedBox(height: Spacing.sm),
              Text('${result.failure?.name}: ${result.detail}'),
              const Text('沒有發布數值；結構或解碼錯誤會隔離到重新連線。'),
            ],
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('關閉'),
        ),
      ],
    ),
  );

  static String _hex(Iterable<int> bytes) => bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');

  static String _identityEvidenceSummary(
    PowertrainBatteryIdentityEvidence? evidence,
  ) {
    if (evidence == null) {
      return '來源身分證據：市場 未知 · 年式 未知 · 車型 未知 · 版本 未知\n'
          '未證實欄位：市場、年式、車型、版本';
    }
    final fields = <(String, PowertrainIdentityEvidenceLevel)>[
      ('市場', evidence.market),
      ('年式', evidence.year),
      ('車型', evidence.model),
      ('版本', evidence.variant),
    ];
    final unknown = [
      for (final field in fields)
        if (field.$2 == PowertrainIdentityEvidenceLevel.unknown) field.$1,
    ];
    return '來源身分證據：${fields.map((field) => '${field.$1} ${_identityEvidenceLabel(field.$2)}').join(' · ')}\n'
        '未證實欄位：${unknown.isEmpty ? '無' : unknown.join('、')}';
  }

  static String _identityEvidenceLabel(PowertrainIdentityEvidenceLevel level) =>
      switch (level) {
        PowertrainIdentityEvidenceLevel.exact => '直接證據',
        PowertrainIdentityEvidenceLevel.sourcePartial => '部分證據',
        PowertrainIdentityEvidenceLevel.unknown => '未知',
      };

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('大電池車型目錄')),
      body: FutureBuilder<PowertrainBatteryCatalogSnapshot>(
        future: _catalog,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || snapshot.data == null) {
            return EmptyState(
              icon: Icons.inventory_2_outlined,
              title: '離線目錄無法載入',
              message: '完整性驗證沒有通過，因此沒有顯示或安裝任何車型資料。',
              action: OutlinedButton(
                onPressed: _retry,
                child: const Text('重新驗證'),
              ),
            );
          }
          return _catalogBody(snapshot.data!);
        },
      ),
    );
  }

  Widget _catalogBody(PowertrainBatteryCatalogSnapshot snapshot) {
    final catalog = snapshot.catalog;
    ref.watch(powertrainExperimentalProbeConsentsProvider);
    final connected = ref.watch(obdSessionProvider).isConnected;
    final experimentalAccess = ref.watch(
      powertrainBatteryExperimentalAccessProvider,
    );
    final installedIds = {
      for (final pid in ref.watch(pidRegistryProvider))
        if (!pid.isCustom && pid.ownerProfileId != null) pid.ownerProfileId!,
    };
    final query = _query.trim().toLowerCase();
    final visible =
        catalog.profiles
            .where((profile) {
              if (_powertrain != 'all' &&
                  profile.powertrain.toUpperCase() != _powertrain) {
                return false;
              }
              if (query.isEmpty) return true;
              final haystack = [
                profile.displayName,
                profile.make,
                profile.model,
                profile.variant,
                profile.market,
                profile.powertrain,
              ].join(' ').toLowerCase();
              return haystack.contains(query);
            })
            .toList(growable: false)
          ..sort((a, b) {
            final statusOrder = _statusOrder(a.status)
                .compareTo(_statusOrder(b.status));
            if (statusOrder != 0) return statusOrder;
            return a.displayName.compareTo(b.displayName);
          });

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.lg,
              Spacing.md,
              Spacing.lg,
              Spacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${catalog.profiles.length} 個車型 · '
                  '${catalog.profiles.where((p) => const PowertrainBatteryProfileCatalogValidator().validateProfile(p).canProbe).length} 個實驗單次唯讀',
                  style: context.texts.titleMedium,
                ),
                const SizedBox(height: Spacing.xs),
                Text(
                  '目錄很廣，但「找到資料」不等於「已支援」。'
                  '僅研究項目永遠沒有指令；實驗項目也只能逐次確認後讀一條。',
                  style: context.texts.bodySmall,
                ),
                const SizedBox(height: Spacing.md),
                TextField(
                  key: const Key('powertrain_profile_search'),
                  onChanged: (value) => setState(() => _query = value),
                  decoration: const InputDecoration(
                    hintText: '搜尋品牌、車型、版本或市場…',
                    prefixIcon: Icon(Icons.search),
                  ),
                ),
                const SizedBox(height: Spacing.sm),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final filter in _filters) ...[
                        FilterChip(
                          key: Key('powertrain_filter_$filter'),
                          selected: _powertrain == filter,
                          showCheckmark: false,
                          label: Text(filter == 'all' ? '全部' : filter),
                          onSelected: (_) =>
                              setState(() => _powertrain = filter),
                        ),
                        const SizedBox(width: Spacing.xs),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: visible.isEmpty
                ? const EmptyState(
                    icon: Icons.search_off,
                    title: '沒有符合的車型',
                    message: '改用品牌、車型名稱，或切換其他動力型式。',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(
                      Spacing.lg,
                      Spacing.sm,
                      Spacing.lg,
                      Spacing.xxl,
                    ),
                    itemCount: visible.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: Spacing.sm),
                    itemBuilder: (context, index) {
                      final profile = visible[index];
                      return _ProfileCard(
                        profile: profile,
                        connected: connected,
                        experimentalAccess: experimentalAccess,
                        installed: installedIds.contains(profile.id),
                        quarantined:
                            ref
                                .read(
                                  powertrainExperimentalProbeConsentsProvider
                                      .notifier,
                                )
                                .quarantineReason(profile.id) !=
                            null,
                        probing: _probingCommandKey != null,
                        onProbe: () => _probeExperimental(snapshot, profile),
                        onInstall: () => _installProfile(snapshot, profile),
                        onUninstall: () => _uninstallProfile(profile),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  int _statusOrder(PowertrainProfileStatus status) => switch (status) {
    PowertrainProfileStatus.ready => 0,
    PowertrainProfileStatus.community => 1,
    PowertrainProfileStatus.experimental => 2,
    PowertrainProfileStatus.researchOnly => 3,
  };
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.profile,
    required this.connected,
    required this.experimentalAccess,
    required this.installed,
    required this.quarantined,
    required this.probing,
    required this.onProbe,
    required this.onInstall,
    required this.onUninstall,
  });

  final PowertrainBatteryProfile profile;
  final bool connected;
  final bool experimentalAccess;
  final bool installed;
  final bool quarantined;
  final bool probing;
  final VoidCallback onProbe;
  final VoidCallback onInstall;
  final VoidCallback onUninstall;

  @override
  Widget build(BuildContext context) {
    final validation = const PowertrainBatteryProfileCatalogValidator()
        .validateProfile(profile);
    final probeable = validation.canProbe;
    final installable = validation.canInstall;
    final years = profile.yearFrom == profile.yearTo
        ? '${profile.yearFrom}'
        : '${profile.yearFrom}–${profile.yearTo}';
    final status = switch (profile.status) {
      PowertrainProfileStatus.ready => ('來源較完整', StatusTone.good),
      PowertrainProfileStatus.community => ('社群資料 · 未驗證', StatusTone.accent),
      PowertrainProfileStatus.experimental => installable
          ? ('實驗 · 未驗證', StatusTone.warn)
          : ('實驗單次唯讀', StatusTone.warn),
      PowertrainProfileStatus.researchOnly => ('僅研究', StatusTone.neutral),
    };
    final evidence = switch (profile.evidence) {
      PowertrainProfileEvidence.sourceBacked => '來源資料',
      PowertrainProfileEvidence.syntheticRig => '合成測試台',
      PowertrainProfileEvidence.physicalVehicle => '專案實車',
    };
    final signalCount = profile.commands.fold<int>(
      0,
      (total, command) => total + command.signals.length,
    );

    return Panel(
      key: Key('powertrain_profile_${profile.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  profile.displayName,
                  style: context.texts.titleMedium,
                ),
              ),
              StatusPill(label: status.$1, tone: status.$2, dense: true),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Wrap(
            spacing: Spacing.xs,
            runSpacing: Spacing.xs,
            children: [
              StatusPill(
                label: profile.powertrain,
                tone: StatusTone.accent,
                dense: true,
              ),
              StatusPill(label: evidence, dense: true),
              if (quarantined)
                const StatusPill(
                  label: '本次連線已隔離',
                  tone: StatusTone.warn,
                  dense: true,
                ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            '$years · ${profile.market} · ${profile.variant}',
            style: context.texts.bodySmall,
          ),
          const SizedBox(height: Spacing.xs),
          Text(profile.description, style: context.texts.bodyMedium),
          const SizedBox(height: Spacing.xs),
          for (final limitation in profile.limitations.take(2))
            Text('• $limitation', style: context.texts.bodySmall),
          const SizedBox(height: Spacing.sm),
          Text(
            '${profile.source.name} · ${profile.source.license} · '
            '${profile.source.revision.substring(0, 8)} · '
            '$signalCount 個訊號',
            style: context.texts.labelSmall,
          ),
          const SizedBox(height: Spacing.sm),
          if (installable) ...[
            Row(
              children: [
                Expanded(
                  child: installed
                      ? OutlinedButton(
                          key: Key('powertrain_uninstall_${profile.id}'),
                          onPressed: onUninstall,
                          child: const Text('已安裝 · 移除訊號'),
                        )
                      : FilledButton(
                          key: Key('powertrain_install_${profile.id}'),
                          onPressed: onInstall,
                          child: const Text('安裝電池訊號'),
                        ),
                ),
              ],
            ),
            // Try-before-install: the same consented one-shot read the
            // experimental tier uses, available while the lab is open.
            if (probeable && experimentalAccess)
              Padding(
                padding: const EdgeInsets.only(top: Spacing.xs),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        key: Key('powertrain_probe_${profile.id}'),
                        onPressed: connected && !quarantined && !probing
                            ? onProbe
                            : null,
                        child: Text(
                          quarantined
                              ? '重新連線後再試'
                              : !connected
                              ? '連線後可先單次試讀'
                              : probing
                              ? '單次查詢中…'
                              : '先試讀一次',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ] else
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    key: Key('powertrain_probe_${profile.id}'),
                    onPressed: probeable
                        ? experimentalAccess &&
                                  connected &&
                                  !quarantined &&
                                  !probing
                              ? onProbe
                              : null
                        : null,
                    child: Text(
                      probeable
                          ? quarantined
                                ? '重新連線後再試'
                                : !experimentalAccess
                                ? '先在設定開啟實驗室'
                                : !connected
                                ? '連線後單次唯讀'
                                : probing
                                ? '單次查詢中…'
                                : '選一條，唯讀一次'
                          : profile.status ==
                                PowertrainProfileStatus.researchOnly
                          ? '僅研究，不會查詢'
                          : '此版本不可安裝',
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
