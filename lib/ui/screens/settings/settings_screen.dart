/// Settings: the vehicle parameters the physics engine needs, plus appearance
/// and the current connection.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../obd/physics/vehicle_profile.dart';
import '../../../obd/physics/vehicle_evidence.dart';
import '../../../obd/transport/obd_transport.dart'
    show TransportException, TransportKind;
import '../../../obd/vehicle_catalog/us_vehicle_catalog.dart';
import '../../../obd/vehicle_catalog/us_vehicle_profile.dart';
import '../../../state/obd_session.dart';
import '../../../state/settings.dart';
import '../../../state/vehicle_catalog.dart';
import '../../../state/vehicle_identity.dart';
import '../../widgets/panel.dart';
import '../../widgets/gauges/dial_gauge.dart';
import '../../widgets/field_event_markers.dart';
import '../../../core/theme/gauge_skin.dart';
import '../../widgets/transcript_export.dart';
import '../connect/connect_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  static const String path = '/settings';

  /// What a failed manual command reads like on screen.
  ///
  /// The sentence, not the identifier. `'$e'` prefixes the Dart class name, so
  /// every refusal arrived as `TransportException: 清除故障碼請用…` — an
  /// English type name in front of a Chinese sentence, on the one screen
  /// somebody opens when they are already unsure whether the app is working.
  /// The app fixed exactly this once before for handshake failures; the manual
  /// box was the copy that got missed.
  ///
  /// A function rather than two catch clauses so it can be tested. The panel
  /// it renders into only exists while connected, and a connected session
  /// cannot be driven from `testWidgets` — the fake-async clock never advances
  /// for the poller's real delays, so the test deadlocks instead of failing.
  /// Anything that is not one of ours keeps its `toString`, because an
  /// unexpected type is exactly when the identifier is the useful part.
  @visibleForTesting
  static String describeManualFailure(Object error) =>
      error is TransportException ? error.message : '$error';

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _commandController = TextEditingController();
  String? _commandResult;
  bool _sending = false;
  bool _readingVin = false;
  bool _loadingVehicleCatalog = false;
  Future<UsVehicleCatalog>? _vehicleCatalogFuture;

  @override
  void dispose() {
    _commandController.dispose();
    super.dispose();
  }

  Future<void> _sendManual() async {
    final text = _commandController.text;
    if (text.trim().isEmpty) return;
    setState(() {
      _sending = true;
      _commandResult = null;
    });
    String result;
    try {
      result = await ref
          .read(obdSessionProvider.notifier)
          .sendManualCommand(text);
      if (result.trim().isEmpty) result = '（沒有回應內容）';
    } on Object catch (e) {
      // Shown rather than thrown. This screen exists for the case where things
      // are already going wrong; an exception escaping it would be the one
      // place a diagnostic tool goes quiet.
      result = SettingsScreen.describeManualFailure(e);
    }
    if (!mounted) return;
    setState(() {
      _sending = false;
      _commandResult = result;
    });
  }

  Future<void> _refreshVin() async {
    if (_readingVin) return;
    setState(() => _readingVin = true);
    await ref
        .read(obdSessionProvider.notifier)
        .refreshVehicleIdentity(
          deadline: DateTime.now().add(const Duration(seconds: 12)),
        );
    if (!mounted) return;
    setState(() => _readingVin = false);
  }

  Future<void> _selectOfficialVehicle() async {
    if (_loadingVehicleCatalog) return;
    setState(() => _loadingVehicleCatalog = true);
    UsVehicleCatalog catalog;
    try {
      _vehicleCatalogFuture ??= ref.read(usVehicleCatalogLoaderProvider)();
      catalog = await _vehicleCatalogFuture!;
    } on UsVehicleCatalogException {
      _vehicleCatalogFuture = null;
      if (!mounted) return;
      setState(() => _loadingVehicleCatalog = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('官方離線目錄損壞或無法載入，沒有套用任何資料。')));
      return;
    } on Object catch (error, stack) {
      _vehicleCatalogFuture = null;
      if (mounted) setState(() => _loadingVehicleCatalog = false);
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Telltale vehicle catalog',
          context: ErrorDescription(
            'while loading the bundled vehicle catalog',
          ),
        ),
      );
      return;
    }
    if (!mounted) return;
    setState(() => _loadingVehicleCatalog = false);
    final configuration = await showModalBottomSheet<UsEpaVehicleConfiguration>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _UsEpaVehiclePicker(catalog: catalog),
    );
    if (configuration == null || !mounted) return;
    final application = applyUsEpaConfiguration(
      catalog,
      epaId: configuration.epaId,
      baseProfile: ref.read(vehicleProfileProvider),
    );
    if (application.verifiedFieldKeys.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('這筆官方配置沒有可安全套用到目前公式的欄位，原設定保持不變。')),
      );
      return;
    }
    await ref.read(vehicleProfileProvider.notifier).update(application.profile);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final profile = ref.watch(vehicleProfileProvider);
    final themeMode = ref.watch(themeModeProvider);
    final connection = ref.watch(obdSessionProvider);
    final identity = ref.watch(vehicleIdentityProvider);
    final connected = connection.isConnected;

    void update(VehicleProfile next) =>
        ref.read(vehicleProfileProvider.notifier).update(next);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            Spacing.lg,
            Spacing.md,
            Spacing.lg,
            Spacing.xxl,
          ),
          children: [
            Text('設定', style: context.texts.headlineMedium),
            const SizedBox(height: Spacing.xl),

            const SectionHeading('連線'),
            Panel(
              child: Column(
                children: [
                  Row(
                    children: [
                      Icon(
                        connection.isConnected ? Icons.link : Icons.link_off,
                        size: 18,
                        color: connection.isConnected
                            ? palette.success
                            : palette.textTertiary,
                      ),
                      const SizedBox(width: Spacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              connection.isConnected
                                  ? connection.deviceName
                                  : '未連線',
                              style: context.texts.titleSmall,
                            ),
                            if (connection.protocol.isNotEmpty)
                              Text(
                                connection.protocol,
                                style: context.texts.bodySmall,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Spacing.lg),
                  SizedBox(
                    width: double.infinity,
                    child: connection.isConnected
                        ? OutlinedButton.icon(
                            onPressed: () async {
                              await ref
                                  .read(obdSessionProvider.notifier)
                                  .disconnect();
                              if (context.mounted) {
                                context.go(ConnectScreen.path);
                              }
                            },
                            icon: const Icon(Icons.link_off, size: 18),
                            label: const Text('中斷連線'),
                          )
                        : FilledButton.icon(
                            onPressed: () => context.go(ConnectScreen.path),
                            icon: const Icon(Icons.link, size: 18),
                            label: const Text('前往連線'),
                          ),
                  ),
                  const SizedBox(height: Spacing.md),
                  _VehicleIdentityPanel(
                    identity: identity,
                    connected: connected,
                    simulated: connection.kind == TransportKind.demo,
                    reading: _readingVin,
                    onRefresh: _refreshVin,
                  ),
                ],
              ),
            ),

            const SizedBox(height: Spacing.xl),
            const SectionHeading('車輛設定檔'),
            Panel(
              child: Column(
                children: [
                  Text(
                    '馬力、扭力與油耗都是由這些參數推算出來的，填得越接近實車，'
                    '推算值才越有意義。',
                    style: context.texts.bodySmall,
                  ),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    '品牌名稱或 VIN 本身都不能證明重量、風阻、VE 與傳動效率。',
                    style: context.texts.bodySmall,
                  ),
                  const SizedBox(height: Spacing.sm),
                  _ProfileProvenanceSummary(profile: profile),
                  const SizedBox(height: Spacing.md),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _loadingVehicleCatalog
                          ? null
                          : _selectOfficialVehicle,
                      icon: const Icon(Icons.directions_car_outlined, size: 18),
                      label: Text(
                        _loadingVehicleCatalog ? '驗證離線目錄中…' : '從官方目錄選擇',
                      ),
                    ),
                  ),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    '目前內建美國 EPA Find-a-Car 官方快照；只代表該市場與快照內的配置，'
                    '不是全球所有品牌或年式。',
                    style: context.texts.bodySmall,
                  ),
                  const SizedBox(height: Spacing.md),
                  _ProfileConfirmationStatus(
                    profile: profile,
                    connected: connected,
                  ),
                  const SizedBox(height: Spacing.lg),
                  _SliderRow(
                    label: '排氣量',
                    value: profile.displacementL,
                    min: VehicleProfile.minDisplacementL,
                    max: VehicleProfile.maxDisplacementL,
                    divisions: 79,
                    format: (v) => '${v.toStringAsFixed(1)} L',
                    onChanged: (v) =>
                        update(profile.copyWith(displacementL: v)),
                  ),
                  _SliderRow(
                    label: '車重（含駕駛）',
                    value: profile.massKg,
                    min: VehicleProfile.minMassKg,
                    max: VehicleProfile.maxMassKg,
                    divisions: 58,
                    format: (v) => '${v.round()} kg',
                    onChanged: (v) => update(profile.copyWith(massKg: v)),
                  ),
                  _SliderRow(
                    label: '容積效率 VE',
                    value: profile.volumetricEfficiency,
                    min: VehicleProfile.minVolumetricEfficiency,
                    max: VehicleProfile.maxVolumetricEfficiency,
                    divisions: 80,
                    format: (v) => '${v.round()} %',
                    onChanged: (v) =>
                        update(profile.copyWith(volumetricEfficiency: v)),
                  ),
                  _SliderRow(
                    label: '風阻係數 Cd',
                    value: profile.dragCoefficient,
                    min: VehicleProfile.minDragCoefficient,
                    max: VehicleProfile.maxDragCoefficient,
                    divisions: 45,
                    format: (v) => v.toStringAsFixed(2),
                    onChanged: (v) =>
                        update(profile.copyWith(dragCoefficient: v)),
                  ),
                  _SliderRow(
                    label: '正面投影面積',
                    value: profile.frontalAreaM2,
                    min: VehicleProfile.minFrontalAreaM2,
                    max: VehicleProfile.maxFrontalAreaM2,
                    divisions: 26,
                    format: (v) => '${v.toStringAsFixed(1)} m²',
                    onChanged: (v) =>
                        update(profile.copyWith(frontalAreaM2: v)),
                  ),
                  _SliderRow(
                    label: '滾動阻力係數 Crr',
                    value: profile.rollingResistance,
                    min: VehicleProfile.minRollingResistance,
                    max: VehicleProfile.maxRollingResistance,
                    divisions: 24,
                    format: (v) => v.toStringAsFixed(3),
                    onChanged: (v) =>
                        update(profile.copyWith(rollingResistance: v)),
                  ),
                ],
              ),
            ),

            const SizedBox(height: Spacing.lg),
            const SectionHeading('燃料與驅動'),
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('燃料種類', style: context.texts.labelSmall),
                  const SizedBox(height: Spacing.sm),
                  Wrap(
                    spacing: Spacing.sm,
                    runSpacing: Spacing.sm,
                    children: [
                      for (final fuel in FuelType.values)
                        ChoiceChip(
                          selected: profile.fuelType == fuel,
                          onSelected: (_) =>
                              update(profile.copyWith(fuelType: fuel)),
                          label: Text(fuel.label),
                          showCheckmark: false,
                          selectedColor: palette.accent.withValues(alpha: 0.16),
                          labelStyle: context.texts.labelMedium?.copyWith(
                            color: profile.fuelType == fuel
                                ? palette.accent
                                : palette.textSecondary,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    '空燃比 ${profile.stoichAfr} · 密度 ${profile.fuelDensityGPerL.round()} g/L',
                    style: context.texts.bodySmall,
                  ),
                  const SizedBox(height: Spacing.lg),
                  Text('驅動方式', style: context.texts.labelSmall),
                  const SizedBox(height: Spacing.sm),
                  Wrap(
                    spacing: Spacing.sm,
                    runSpacing: Spacing.sm,
                    children: [
                      for (final drivetrain in Drivetrain.values)
                        ChoiceChip(
                          selected: profile.drivetrain == drivetrain,
                          onSelected: (_) =>
                              update(profile.copyWith(drivetrain: drivetrain)),
                          label: Text(drivetrain.label),
                          showCheckmark: false,
                          selectedColor: palette.accent.withValues(alpha: 0.16),
                          labelStyle: context.texts.labelMedium?.copyWith(
                            color: profile.drivetrain == drivetrain
                                ? palette.accent
                                : palette.textSecondary,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    '傳動效率 ${(profile.drivetrainEfficiency * 100).round()} %',
                    style: context.texts.bodySmall,
                  ),
                  const SizedBox(height: Spacing.lg),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed:
                          !connected ||
                              profile.isConfirmed ||
                              !profile.hasValidAssumptions
                          ? null
                          : () => ref
                                .read(vehicleProfileProvider.notifier)
                                .confirm(),
                      icon: Icon(
                        profile.isConfirmed
                            ? Icons.verified
                            : Icons.fact_check_outlined,
                        size: 18,
                      ),
                      label: Text(
                        profile.isConfirmed
                            ? '本次連線資料已確認'
                            : connected
                            ? '確認本次連線車輛資料'
                            : '連線後確認此車資料',
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: Spacing.lg),
            const SectionHeading('診斷紀錄'),
            const RecoveredTranscriptPanel(),
            const _AdapterIdentityPanel(),
            FieldEventMarkerPanel(
              enabled: connected && connection.kind != TransportKind.demo,
              onRecord: ref.read(obdSessionProvider.notifier).recordFieldEvent,
            ),
            const SizedBox(height: Spacing.md),
            const Panel(child: TranscriptExportButtons()),
            const SizedBox(height: Spacing.md),
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('手動指令', style: context.texts.titleSmall),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    '直接送一條指令給轉接器，例如 ATI、ATDPN、0100。'
                    '會排在一般輪詢的同一條佇列上，不會插隊。',
                    style: context.texts.bodySmall,
                  ),
                  const SizedBox(height: Spacing.sm),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _commandController,
                          enabled: connected && !_sending,
                          autocorrect: false,
                          enableSuggestions: false,
                          textCapitalization: TextCapitalization.characters,
                          decoration: const InputDecoration(
                            labelText: '指令',
                            hintText: 'ATI',
                          ),
                          onSubmitted: (_) => _sendManual(),
                        ),
                      ),
                      const SizedBox(width: Spacing.sm),
                      FilledButton(
                        onPressed: connected && !_sending ? _sendManual : null,
                        child: const Text('送出'),
                      ),
                    ],
                  ),
                  if (_commandResult != null) ...[
                    const SizedBox(height: Spacing.sm),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(Spacing.sm),
                      decoration: BoxDecoration(
                        color: palette.surfaceAlt,
                        borderRadius: BorderRadius.circular(Radii.sm),
                      ),
                      child: SelectableText(
                        _commandResult!,
                        style: context.texts.bodySmall?.copyWith(
                          fontFeatures: const [],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: Spacing.lg),
            const SectionHeading('外觀'),
            Panel(
              child: SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
                  ButtonSegment(value: ThemeMode.light, label: Text('淺色')),
                  ButtonSegment(value: ThemeMode.system, label: Text('跟隨系統')),
                ],
                selected: {themeMode},
                onSelectionChanged: (s) =>
                    ref.read(themeModeProvider.notifier).set(s.first),
                showSelectedIcon: false,
              ),
            ),
            const SizedBox(height: Spacing.md),
            const _GaugeSkinPicker(),

            const SizedBox(height: Spacing.xl),
            Text(
              '本 App 的 OBD2 實作依據 SAE J1979 與 ELM327 datasheet 等公開標準；'
              '每一條影響硬體行為的公式與 AT 指令都經過交叉驗證，'
              '結果記錄於 docs/protocol-deviations.zh-TW.md。'
              '本 App 與 Torque / Torque Pro 無關聯。',
              style: context.texts.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _UsEpaVehiclePicker extends StatefulWidget {
  const _UsEpaVehiclePicker({required this.catalog});

  final UsVehicleCatalog catalog;

  @override
  State<_UsEpaVehiclePicker> createState() => _UsEpaVehiclePickerState();
}

class _UsEpaVehiclePickerState extends State<_UsEpaVehiclePicker> {
  int? _year;
  String? _make;
  String? _model;
  UsEpaVehicleConfiguration? _configuration;

  @override
  Widget build(BuildContext context) {
    final years = widget.catalog.years.reversed.toList(growable: false);
    final makes = _year == null
        ? const <String>[]
        : widget.catalog.makes(year: _year);
    final models = _year == null || _make == null
        ? const <String>[]
        : widget.catalog.models(year: _year!, make: _make!);
    final configurations = _year == null || _make == null || _model == null
        ? const <UsEpaVehicleConfiguration>[]
        : widget.catalog.configurations(
            year: _year!,
            make: _make!,
            model: _model!,
          );
    final application = _configuration == null
        ? null
        : applyUsEpaConfiguration(widget.catalog, epaId: _configuration!.epaId);

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.86,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '美國 EPA 官方車型目錄',
                      style: context.texts.titleLarge,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                    tooltip: '關閉',
                  ),
                ],
              ),
              Text(
                '僅限美國市場 1984–${widget.catalog.years.last} 的快照配置。'
                '選到同名車系仍要以年式、變速箱、燃料與 EPA ID 消歧。',
                style: context.texts.bodySmall,
              ),
              const SizedBox(height: Spacing.md),
              _CatalogDropdown<int>(
                dropdownKey: const Key('us_epa_year'),
                label: '年式',
                value: _year,
                values: years,
                display: (value) => '$value',
                onChanged: (value) => setState(() {
                  _year = value;
                  _make = null;
                  _model = null;
                  _configuration = null;
                }),
              ),
              const SizedBox(height: Spacing.sm),
              _CatalogDropdown<String>(
                dropdownKey: const Key('us_epa_make'),
                label: '廠牌（EPA make）',
                value: _make,
                values: makes,
                display: (value) => value,
                onChanged: _year == null
                    ? null
                    : (value) => setState(() {
                        _make = value;
                        _model = null;
                        _configuration = null;
                      }),
              ),
              const SizedBox(height: Spacing.sm),
              _CatalogDropdown<String>(
                dropdownKey: const Key('us_epa_model'),
                label: '車型',
                value: _model,
                values: models,
                display: (value) => value,
                onChanged: _make == null
                    ? null
                    : (value) => setState(() {
                        _model = value;
                        _configuration = null;
                      }),
              ),
              const SizedBox(height: Spacing.md),
              Expanded(
                child: configurations.isEmpty
                    ? Center(
                        child: Text(
                          _model == null ? '依序選擇年式、品牌與車型' : '這個車型沒有可用配置',
                          style: context.texts.bodySmall,
                        ),
                      )
                    : ListView.separated(
                        itemCount: configurations.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: Spacing.xs),
                        itemBuilder: (context, index) {
                          final item = configurations[index];
                          final selected = item.epaId == _configuration?.epaId;
                          return ListTile(
                            key: Key('us_epa_config_${item.epaId}'),
                            selected: selected,
                            onTap: () => setState(() => _configuration = item),
                            leading: Icon(
                              selected
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked,
                            ),
                            title: Text(_configurationTitle(item)),
                            subtitle: Text(
                              '${item.alternativeVehicleType.isEmpty ? '' : '${item.alternativeVehicleType} · '}'
                              '${item.fuelType.isEmpty ? '燃料未知' : item.fuelType} · '
                              '${item.drive.isEmpty ? '驅動未知' : item.drive} · '
                              'EPA ID ${item.epaId}',
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: Spacing.sm),
              if (application != null)
                Text(
                  application.verifiedFieldKeys.isEmpty
                      ? '此配置沒有能安全套用到目前公式的欄位；不會猜測。'
                      : '只會套用：${_verifiedFieldLabels(application.verifiedFieldKeys)}。'
                            '車重、VE、Cd、正面面積、Crr 與傳動效率仍保持未解析。',
                  style: context.texts.bodySmall,
                ),
              const SizedBox(height: Spacing.sm),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _configuration == null
                      ? null
                      : application!.verifiedFieldKeys.isEmpty
                      ? () => Navigator.pop(context)
                      : () => Navigator.pop(context, _configuration),
                  child: Text(
                    application == null
                        ? '選擇一個精確配置'
                        : application.verifiedFieldKeys.isEmpty
                        ? '關閉（沒有可套用欄位）'
                        : '套用 ${application.verifiedFieldKeys.length} 個官方欄位',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _configurationTitle(UsEpaVehicleConfiguration item) {
    final parts = <String>[
      if (item.displacementL != null) '${item.displacementL} L',
      if (item.cylinders != null) '${item.cylinders} 缸',
      if (item.transmission.isNotEmpty) item.transmission,
    ];
    return parts.isEmpty ? 'EPA 配置 ${item.epaId}' : parts.join(' · ');
  }

  static String _verifiedFieldLabels(Set<String> keys) => [
    if (keys.contains('displacementL')) '排氣量',
    if (keys.contains('fuelType')) '燃料種類',
  ].join('、');
}

class _CatalogDropdown<T> extends StatelessWidget {
  const _CatalogDropdown({
    required this.dropdownKey,
    required this.label,
    required this.value,
    required this.values,
    required this.display,
    required this.onChanged,
  });

  final Key dropdownKey;
  final String label;
  final T? value;
  final List<T> values;
  final String Function(T value) display;
  final ValueChanged<T?>? onChanged;

  @override
  Widget build(BuildContext context) => InputDecorator(
    decoration: InputDecoration(labelText: label),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        key: dropdownKey,
        value: value,
        isExpanded: true,
        items: [
          for (final item in values)
            DropdownMenuItem(value: item, child: Text(display(item))),
        ],
        onChanged: onChanged,
      ),
    ),
  );
}

class _ProfileProvenanceSummary extends StatelessWidget {
  const _ProfileProvenanceSummary({required this.profile});

  final VehicleProfile profile;

  static const _labels = <String, String>{
    'displacementL': '排氣量',
    'massKg': '車重',
    'volumetricEfficiency': 'VE',
    'fuelType': '燃料',
    'drivetrain': '驅動方式',
    'dragCoefficient': 'Cd',
    'frontalAreaM2': '正面投影面積',
    'rollingResistance': 'Crr',
  };

  @override
  Widget build(BuildContext context) {
    final fields = profile.inputFieldMap;
    final exact = fields.entries
        .where((entry) => entry.value.isVerifiedExact)
        .toList();
    final officialSourceCount = fields.values
        .where(
          (field) =>
              field.origin == VehicleFieldOrigin.officialRegistry ||
              field.origin == VehicleFieldOrigin.manufacturerPublication,
        )
        .length;
    final userSourceCount = fields.values
        .where((field) => field.origin == VehicleFieldOrigin.userEntered)
        .length;
    final genericSourceCount = fields.values
        .where((field) => field.origin == VehicleFieldOrigin.genericDefault)
        .length;
    final scientificSourceCount = fields.values
        .where((field) => field.origin == VehicleFieldOrigin.scientificModel)
        .length;
    int resolutionCount(EvidenceResolution resolution) =>
        fields.values.where((field) => field.resolution == resolution).length;
    final publishers =
        exact.map((entry) => entry.value.evidence!.publisher).toSet().toList()
          ..sort();
    final exactLabels = exact.map((entry) => _labels[entry.key]!).join('、');
    final exactEvidence = exact.isEmpty ? null : exact.first.value.evidence;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: context.palette.surfaceAlt,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '解析：官方精確 ${exact.length} / ${fields.length} 欄 · '
            '本次確認 ${resolutionCount(EvidenceResolution.userConfirmedSession)} / ${fields.length} 欄 · '
            '未解析 ${resolutionCount(EvidenceResolution.unknown)} / ${fields.length} 欄 · '
            '歧義 ${resolutionCount(EvidenceResolution.ambiguous)} / ${fields.length} 欄 · '
            '衝突 ${resolutionCount(EvidenceResolution.conflict)} / ${fields.length} 欄',
            style: context.texts.labelSmall,
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            '來源：官方／原廠 $officialSourceCount / ${fields.length} 欄 · '
            '手動 $userSourceCount / ${fields.length} 欄 · '
            '通用 $genericSourceCount / ${fields.length} 欄 · '
            '科學模型 $scientificSourceCount / ${fields.length} 欄',
            style: context.texts.labelSmall,
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            exact.isEmpty
                ? '目前沒有欄位已精確解析到這次車輛；通用值、手動值或舊來源值仍須確認。'
                : '目前只有$exactLabels有官方精確來源；其他欄位仍須逐項確認。',
            style: context.texts.bodySmall,
          ),
          if (publishers.isNotEmpty) ...[
            const SizedBox(height: Spacing.xs),
            Text('來源：${publishers.join('、')}', style: context.texts.bodySmall),
          ],
          if (exactEvidence != null) ...[
            const SizedBox(height: Spacing.xs),
            Text(
              '${exactEvidence.year} ${exactEvidence.make} '
              '${exactEvidence.model} · ${exactEvidence.trim}',
              style: context.texts.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

class _VehicleIdentityPanel extends StatelessWidget {
  const _VehicleIdentityPanel({
    required this.identity,
    required this.connected,
    required this.simulated,
    required this.reading,
    required this.onRefresh,
  });

  final VehicleIdentity identity;
  final bool connected;
  final bool simulated;
  final bool reading;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final (
      IconData icon,
      Color color,
      String title,
      String detail,
    ) = switch (identity.status) {
      VehicleIdentityStatus.notRead => (
        Icons.badge_outlined,
        palette.textSecondary,
        'VIN 尚未讀取',
        connected
            ? '可向目前車輛讀取 Mode 09 VIN；身分狀態只保留在這次連線中。'
                  '原始診斷紀錄仍可能包含 VIN。'
            : '連線後可讀取目前車輛自報的 VIN；身分狀態不會帶到下一次連線。'
                  '原始診斷紀錄仍可能包含 VIN。',
      ),
      VehicleIdentityStatus.vehicleReported => (
        Icons.directions_car_outlined,
        palette.info,
        simulated ? '模擬器回報 VIN' : '車輛回報 VIN',
        'VIN 是車輛自報身分，不代表車型規格已驗證。'
            '身分狀態不跨連線；診斷紀錄仍可能包含 VIN。',
      ),
      VehicleIdentityStatus.unavailable => (
        Icons.help_outline,
        palette.warning,
        'VIN 無法取得',
        '可能是車輛未提供、回覆不完整或這次連線沒有讀到；不會猜測或補字。',
      ),
      VehicleIdentityStatus.conflict => (
        Icons.warning_amber_outlined,
        palette.danger,
        'VIN 衝突',
        '不同控制器回報不同 VIN，無法確認車輛身分；所有候選都已丟棄。',
      ),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.25)),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: Spacing.sm),
              Expanded(child: Text(title, style: context.texts.titleSmall)),
              OutlinedButton(
                onPressed: connected && !reading ? onRefresh : null,
                child: Text(reading ? '讀取中…' : '讀取 VIN'),
              ),
            ],
          ),
          if (identity.vin != null) ...[
            const SizedBox(height: Spacing.xs),
            SelectableText(
              identity.vin!,
              style: AppTypography.code(palette, color: color),
            ),
          ],
          const SizedBox(height: Spacing.xs),
          Text(detail, style: context.texts.bodySmall?.copyWith(color: color)),
        ],
      ),
    );
  }
}

class _ProfileConfirmationStatus extends StatelessWidget {
  const _ProfileConfirmationStatus({
    required this.profile,
    required this.connected,
  });

  final VehicleProfile profile;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final confirmed = profile.isConfirmed;
    final color = confirmed ? palette.success : palette.warning;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            confirmed ? Icons.verified_outlined : Icons.info_outline,
            size: 18,
            color: color,
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              confirmed
                  ? '已確認本次連線的設定。修改任一項或重新連線後都要再確認。'
                  : connected
                  ? '本次連線尚未確認。仍可讀取 OBD 實測資料，'
                        '但不顯示依車重、VE 與風阻推算的數值。'
                  : '先連上目前這台車再確認。每次重新連線都會自動失效，'
                        '避免把上一台車的設定套到下一台。',
              style: context.texts.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.format,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String Function(double) format;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: context.texts.bodyMedium)),
              Text(format(value), style: AppTypography.readout(palette, 15)),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

/// What the adapter says about itself, and where that fails to add up.
///
/// Here rather than on the dashboard, deliberately. `v1.5` is a firmware Elm
/// Electronics never released and it is printed on a very large share of the
/// adapters people actually buy — most of which work — so putting it in front
/// of a driver mid-drive would be an alarm that is wrong more often than
/// right. In a diagnostics section it is what it actually is: a fact about the
/// device, for the moment somebody is trying to work out why a reading looks
/// odd.
///
/// It is also careful not to imply more than it knows. This says nothing about
/// whether the *numbers* are true — no software can, without a second
/// independent measurement — and the copy says so rather than leaving a green
/// tick to be misread as a clean bill of health.
class _AdapterIdentityPanel extends ConsumerWidget {
  const _AdapterIdentityPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(obdSessionProvider);
    if (!session.isConnected) return const SizedBox.shrink();
    final identity = ref
        .read(obdSessionProvider.notifier)
        .engine
        ?.client
        .adapterIdentity;
    if (identity == null) return const SizedBox.shrink();

    final concerns = identity.concerns;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('轉接器自述', style: context.texts.titleSmall),
            const SizedBox(height: Spacing.xs),
            SelectableText(
              identity.version.isEmpty ? '（未回報版本）' : identity.version,
              style: context.texts.bodyMedium,
            ),
            if (identity.identity.isNotEmpty)
              SelectableText(identity.identity, style: context.texts.bodySmall),
            const SizedBox(height: Spacing.xs),
            if (concerns.isEmpty)
              Text(
                '沒有發現自述矛盾。這只表示它對自己的描述前後一致 —— '
                '既不代表它是原廠晶片，也不代表它回報的數值正確。'
                '版本號在仿製品上就是一段可以任意填的文字。',
                style: context.texts.bodySmall,
              )
            else ...[
              for (final concern in concerns) ...[
                Text('⚠ ${concern.summary}', style: context.texts.bodyMedium),
                Text(concern.detail, style: context.texts.bodySmall),
                const SizedBox(height: Spacing.xs),
              ],
              Text(
                '這些是轉接器對自己的描述對不起來，不是它讀錯了車。'
                '要確認數值，只能拿第二個獨立量測去對（見速查表）。',
                style: context.texts.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Choosing the instrument, by looking at it.
///
/// A list of five names would be five names. These are five genuinely
/// different dials — one has no needle, one draws blocks instead of a sweep,
/// one moves like a mechanical needle and two refuse to animate at all — and
/// none of that is conveyed by the word 極簡. So each option draws itself, at
/// a fixed value, using the real gauge with the real painter.
class _GaugeSkinPicker extends ConsumerWidget {
  const _GaugeSkinPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(gaugeSkinProvider);
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('儀表樣式', style: context.texts.titleSmall),
          const SizedBox(height: Spacing.xs),
          Text(
            '不只是換顏色 —— 每一種的刻度盤形狀、指針、動態都不一樣。'
            '深色與淺色底下都可以用。',
            style: context.texts.bodySmall,
          ),
          const SizedBox(height: Spacing.md),
          SizedBox(
            height: 168,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: GaugeSkin.all.length,
              separatorBuilder: (_, _) => const SizedBox(width: Spacing.sm),
              itemBuilder: (context, i) {
                final skin = GaugeSkin.all[i];
                final selected = skin.id == current.id;
                return _SkinChoice(
                  skin: skin,
                  selected: selected,
                  onTap: () => ref.read(gaugeSkinProvider.notifier).set(skin),
                );
              },
            ),
          ),
          const SizedBox(height: Spacing.sm),
          Text(current.description, style: context.texts.bodySmall),
        ],
      ),
    );
  }
}

class _SkinChoice extends StatelessWidget {
  const _SkinChoice({
    required this.skin,
    required this.selected,
    required this.onTap,
  });

  final GaugeSkin skin;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 132,
        padding: const EdgeInsets.all(Spacing.sm),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? palette.accent : palette.hairline,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The real gauge, under a theme carrying only this skin, so the
            // preview cannot drift from what selecting it produces.
            Expanded(
              child: Theme(
                data: Theme.of(context).copyWith(extensions: [palette, skin]),
                child: const IgnorePointer(
                  child: DialGauge(
                    label: 'RPM',
                    value: 2740,
                    minValue: 0,
                    maxValue: 8000,
                    units: 'rpm',
                  ),
                ),
              ),
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              skin.name,
              style: context.texts.labelMedium?.copyWith(
                color: selected ? palette.accent : palette.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
