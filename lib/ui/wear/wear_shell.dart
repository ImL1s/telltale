/// The Wear OS shell: glance-first pages for a wrist-sized screen.
///
/// The watch runs the same engine, transports and providers as the phone —
/// this file only replaces the navigation shell. Design rules it encodes:
/// pure-black ground (AMOLED and the dark palette's own contract), one
/// reading per glance, no writes (fault-code clearing and the experimental
/// laboratory deliberately do not exist here), and every touch target large
/// enough for a gloved thumb. Bluetooth Classic adapters cannot be opened
/// from a watch, so the connect page offers BLE and the built-in Demo only.
///
/// Every reading shown here goes through [TelemetrySnapshot.valueOf] /
/// [TelemetrySnapshot.isStale] — never `readings[...]` directly. The
/// telemetry layer's own comment says why: staleness enforced at each call
/// site is how a sensor that stopped answering keeps its last believable
/// number on screen, styled exactly like a live one, and a glance-first
/// surface is where that lie does the most damage.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ble_scan_permissions.dart';
import '../../core/screen_wake.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../obd/pid/pid.dart';
import '../../obd/pid/pid_library.dart';
import '../../obd/powertrain_battery/powertrain_battery_catalog.dart';
import '../../obd/powertrain_battery/powertrain_battery_profile.dart';
import '../../obd/telemetry.dart';
import '../../obd/transport/ble_transport.dart';
import '../../obd/transport/obd_transport.dart';
import '../../state/obd_session.dart';
import '../../state/pid_registry.dart';
import '../../state/powertrain_battery_profiles.dart';
import '../widgets/gauges/dial_gauge.dart';

class WearShell extends ConsumerStatefulWidget {
  const WearShell({super.key});

  @override
  ConsumerState<WearShell> createState() => _WearShellState();
}

class _WearShellState extends ConsumerState<WearShell> {
  final PageController _pages = PageController();
  String _pageSetSignature = '';

  @override
  void initState() {
    super.initState();
    // Synchronize with the state the shell mounted into, not only with
    // transitions: a shell created while a session is already live must hold
    // the screen from its first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ScreenWake.keepOn(ref.read(obdSessionProvider).isConnected));
    });
  }

  @override
  void dispose() {
    _pages.dispose();
    // The flag is window-scoped and clears with the activity anyway; this
    // just releases it earlier when the shell goes away in-place.
    unawaited(ScreenWake.keepOn(false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<ObdConnectionState>(obdSessionProvider, (previous, next) {
      final was = previous?.isConnected ?? false;
      if (was != next.isConnected) {
        unawaited(ScreenWake.keepOn(next.isConnected));
      }
    });
    final connection = ref.watch(obdSessionProvider);
    final hasBatterySignals = ref
        .watch(pidRegistryProvider)
        .any((pid) => !pid.isCustom && pid.ownerProfileId != null);

    final pages = connection.isConnected
        ? [
            const _WearDialPage(),
            if (hasBatterySignals) const _WearBatteryPage(),
            const _WearNumbersPage(),
          ]
        : [const _WearConnectPage()];

    // When the page set itself changes — connect, disconnect, a battery
    // profile arriving — the current index means something different, so
    // start over at the first page rather than landing on whatever now
    // happens to live at the old index.
    final signature = '${connection.isConnected}_$hasBatterySignals';
    if (signature != _pageSetSignature) {
      _pageSetSignature = signature;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pages.hasClients) _pages.jumpToPage(0);
      });
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView(controller: _pages, children: pages),
          // Simulated data must say so, permanently: the phone dashboard
          // keeps "Demo ECU" in its status strip, and a glance surface has
          // even less room for a number of ambiguous provenance.
          if (connection.isConnected && connection.kind == TransportKind.demo)
            // IgnorePointer: text hit-tests opaquely, and the badge sits on
            // the dial's tap-to-cycle surface.
            const IgnorePointer(
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: EdgeInsets.only(top: Spacing.md),
                  child: _DemoBadge(),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DemoBadge extends StatelessWidget {
  const _DemoBadge();

  @override
  Widget build(BuildContext context) => Text(
    'DEMO',
    key: const Key('wear_demo_badge'),
    style: context.texts.labelSmall,
  );
}

/// Connect page: Demo in one tap, BLE in two.
class _WearConnectPage extends ConsumerStatefulWidget {
  const _WearConnectPage();

  @override
  ConsumerState<_WearConnectPage> createState() => _WearConnectPageState();
}

class _WearConnectPageState extends ConsumerState<_WearConnectPage> {
  StreamSubscription<(String, String, int?)>? _scan;
  final List<(String, String, int?)> _found = [];
  bool _scanning = false;
  bool _showingScanResults = false;
  String? _note;

  @override
  void dispose() {
    unawaited(_scan?.cancel());
    super.dispose();
  }

  Future<void> _startBleScan() async {
    // The shared version-aware rule: on Android 12+ this asks for the two
    // Bluetooth runtime permissions, below that it asks for location —
    // skipping which makes the scan return an empty list with no error,
    // which looks exactly like "no adapters nearby".
    final permission = await ensureBluetoothPermissions(forScanning: true);
    if (!mounted) return;
    if (!permission.granted) {
      final what = permission.deniedLabel ?? '藍牙';
      setState(
        () => _note =
            permission.outcome == BlePermissionOutcome.permanentlyDenied
            ? '$what權限已被永久拒絕，請到系統設定開啟後再試'
            : '需要$what權限才能掃描',
      );
      return;
    }
    setState(() {
      _scanning = true;
      _showingScanResults = true;
      _found.clear();
      _note = null;
    });
    _scan = BleTransport.scanEntries().listen(
      (entry) {
        if (!mounted) return;
        setState(() {
          final index = _found.indexWhere((e) => e.$1 == entry.$1);
          if (index >= 0) {
            _found[index] = entry;
          } else {
            _found.add(entry);
          }
        });
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _scanning = false;
          _note = '掃描失敗，請再試一次';
        });
      },
      onDone: () {
        if (mounted) setState(() => _scanning = false);
      },
    );
  }

  Future<void> _connectBle((String, String, int?) entry) async {
    await _scan?.cancel();
    if (!mounted) return;
    setState(() => _scanning = false);
    final ok = await ref
        .read(obdSessionProvider.notifier)
        .connectBle(
          BleAdapterHandle(id: entry.$1, name: entry.$2, rssi: entry.$3),
        );
    if (!ok && mounted) {
      setState(
        () => _note = '連線失敗：${entry.$2.isEmpty ? entry.$1 : entry.$2}',
      );
    }
  }

  Future<void> _leaveScanResults() async {
    await _scan?.cancel();
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _showingScanResults = false;
      _found.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final connecting = ref.watch(
      obdSessionProvider.select(
        (state) => state.phase == ConnectionPhase.connecting,
      ),
    );

    if (_showingScanResults) {
      return _RoundInset(
        child: Column(
          children: [
            const SizedBox(height: Spacing.sm),
            Text('BLE 轉接器', style: context.texts.titleSmall),
            if (_scanning)
              const Padding(
                padding: EdgeInsets.all(Spacing.xs),
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            // The failure note renders on this view too — a connect attempt
            // can only start from here, so a message only the other view
            // shows is a message nobody sees.
            if (_note != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
                child: Text(
                  _note!,
                  textAlign: TextAlign.center,
                  style: context.texts.bodySmall,
                ),
              ),
            Expanded(
              child: _found.isEmpty
                  ? Center(
                      child: Text(
                        _scanning ? '掃描中…' : '沒有找到裝置',
                        style: context.texts.bodySmall,
                      ),
                    )
                  : ListView(
                      children: [
                        for (final entry in _found)
                          SizedBox(
                            height: 52,
                            child: FilledButton.tonal(
                              key: Key('wear_ble_${entry.$1}'),
                              onPressed: connecting
                                  ? null
                                  : () => _connectBle(entry),
                              child: Text(
                                entry.$2.isEmpty ? entry.$1 : entry.$2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    key: const Key('wear_scan_back'),
                    onPressed: _leaveScanResults,
                    child: const Text('返回'),
                  ),
                ),
                Expanded(
                  child: TextButton(
                    key: const Key('wear_scan_again'),
                    onPressed: _scanning || connecting ? null : _startBleScan,
                    child: const Text('重新掃描'),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return _RoundInset(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Telltale',
            textAlign: TextAlign.center,
            style: context.texts.titleMedium,
          ),
          const SizedBox(height: Spacing.md),
          SizedBox(
            height: 56,
            child: FilledButton(
              key: const Key('wear_connect_demo'),
              onPressed: connecting
                  ? null
                  : () => ref.read(obdSessionProvider.notifier).connectDemo(),
              child: Text(connecting ? '連線中…' : 'Demo 模擬器'),
            ),
          ),
          const SizedBox(height: Spacing.sm),
          SizedBox(
            height: 56,
            child: OutlinedButton(
              key: const Key('wear_scan_ble'),
              onPressed: connecting ? null : _startBleScan,
              child: const Text('BLE 轉接器'),
            ),
          ),
          if (_note != null) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              _note!,
              textAlign: TextAlign.center,
              style: context.texts.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

/// One large dial; tap cycles the reading, long-press disconnects.
class _WearDialPage extends ConsumerStatefulWidget {
  const _WearDialPage();

  @override
  ConsumerState<_WearDialPage> createState() => _WearDialPageState();
}

class _WearDialPageState extends ConsumerState<_WearDialPage> {
  static const List<(Pid, GaugeHue)> _cycle = [
    (PidLibrary.vehicleSpeed, GaugeHue.amber),
    (PidLibrary.engineRpm, GaugeHue.violet),
    (PidLibrary.coolantTemp, GaugeHue.aqua),
  ];
  int _index = 0;

  Future<void> _confirmDisconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: const Text('中斷連線？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('wear_disconnect_confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('中斷'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await ref.read(obdSessionProvider.notifier).disconnect();
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot =
        ref.watch(telemetryProvider).value ?? const TelemetrySnapshot();
    final (pid, hue) = _cycle[_index];

    return GestureDetector(
      key: const Key('wear_dial'),
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _index = (_index + 1) % _cycle.length),
      onLongPress: _confirmDisconnect,
      child: Padding(
        padding: const EdgeInsets.all(Spacing.sm),
        child: Center(
          child: AspectRatio(
            aspectRatio: 1,
            child: DialGauge(
              // valueOf/isStale, not readings[...]: a reading that stopped
              // updating must dim, not keep glowing its last number.
              value: snapshot.valueOf(pid),
              minValue: pid.minValue,
              maxValue: pid.maxValue,
              label: pid.shortName,
              units: pid.units,
              hue: hue,
              redlineFrom: pid.redlineFrom,
              isStale: snapshot.isStale(pid),
            ),
          ),
        ),
      ),
    );
  }
}

/// Battery page: one installed community profile's key readings, behind the
/// same per-connection confirmation the phone dashboard requires.
///
/// Scoped to a single owner on purpose: the profile whose identity the
/// driver confirms is exactly the profile whose signals may appear here.
/// Mixing another installed profile's PID into this page would show a value
/// under a confirmation that never covered it.
class _WearBatteryPage extends ConsumerWidget {
  const _WearBatteryPage();

  Pid? _bySignal(List<Pid> pids, List<String> preferredIds) {
    for (final wanted in preferredIds) {
      for (final pid in pids) {
        if (pid.sourceSignalId == wanted) return pid;
      }
    }
    return null;
  }

  Future<void> _confirmVehicle(
    BuildContext context,
    WidgetRef ref,
    PowertrainBatteryCatalogSnapshot snapshot,
    PowertrainBatteryProfile profile,
    int year,
  ) async {
    // Same contract as the phone banner: capture the connection identity
    // before the dialog, refuse if it changed while the dialog sat open.
    // The snapshot and profile were captured together by the caller, so the
    // identity on screen is the identity that gets authorized.
    final session = ref.read(obdSessionProvider.notifier);
    final generationAtPrompt = session.connectionGeneration;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$year ${profile.make} ${profile.model}\n'
                '${profile.variant} · ${profile.market}',
                key: const Key('wear_confirm_vehicle_identity'),
              ),
              const SizedBox(height: Spacing.sm),
              Text(
                '確認後，這個車型的唯讀電池查詢會在本次連線內定期輪詢。'
                '接錯車型可能得到看似合理但錯誤的數字——不確定就取消。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('wear_confirm_vehicle_accept'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('就是這台車'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // The dialog rides the root navigator, so a real disconnect can swap the
    // shell back to the connect page — unmounting this element — while the
    // dialog stays up. An accept that lands after that must refuse quietly;
    // touching ref below an unmounted element throws instead of declining.
    if (!context.mounted) return;
    if (!ref.read(obdSessionProvider).isConnected ||
        session.connectionGeneration != generationAtPrompt) {
      return;
    }
    ref
        .read(powertrainProfileAuthorizationsProvider.notifier)
        .authorize(
          snapshot: snapshot,
          profileId: profile.id,
          vehicleYear: year,
          connectionGeneration: generationAtPrompt,
        );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registryPids = ref.watch(pidRegistryProvider);
    // One owner only, chosen deterministically. Every lookup below — the
    // liveness check, the confirmation, the signal picks — uses this owner's
    // PIDs and nothing else.
    final ownerIds =
        <String>{
            for (final pid in registryPids)
              if (!pid.isCustom && pid.ownerProfileId != null)
                pid.ownerProfileId!,
          }.toList()
          ..sort();
    if (ownerIds.isEmpty) return const SizedBox.shrink();
    final profileId = ownerIds.first;
    final profilePids = [
      for (final pid in registryPids)
        if (!pid.isCustom && pid.ownerProfileId == profileId) pid,
    ];

    final authorizations = ref.watch(powertrainProfileAuthorizationsProvider);
    final generation = ref
        .read(obdSessionProvider.notifier)
        .connectionGeneration;
    final live = isLivePowertrainAuthorization(
      authorizations[profileId],
      connectionGeneration: generation,
      sourceRevision: profilePids.first.sourceRevision,
    );

    if (!live) {
      final year = ref
          .read(pidRegistryProvider.notifier)
          .installedVehicleYear(profileId);
      // Snapshot and profile captured as one pair: what the dialog shows is
      // what gets authorized.
      final snapshot = ref
          .watch(powertrainBatteryCatalogSnapshotProvider)
          .value;
      final profile = snapshot?.catalog.profiles
          .where((candidate) => candidate.id == profileId)
          .firstOrNull;
      return _RoundInset(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              profile?.displayName ?? profileId,
              textAlign: TextAlign.center,
              style: context.texts.bodyMedium,
            ),
            const SizedBox(height: Spacing.sm),
            SizedBox(
              height: 56,
              child: FilledButton(
                key: const Key('wear_confirm_vehicle'),
                onPressed: snapshot == null || profile == null || year == null
                    ? null
                    : () => _confirmVehicle(
                        context,
                        ref,
                        snapshot,
                        profile,
                        year,
                      ),
                child: const Text('確認車輛'),
              ),
            ),
          ],
        ),
      );
    }

    final snapshot =
        ref.watch(telemetryProvider).value ?? const TelemetrySnapshot();
    final soc = _bySignal(profilePids, const [
      'soc_display',
      'soc_bms',
      'raw_soc',
      'hybrid_soc',
    ]);
    final volts = _bySignal(profilePids, const [
      'pack_voltage',
      'hv_pack_voltage',
    ]);
    final amps = _bySignal(profilePids, const [
      'pack_current',
      'hv_pack_current',
    ]);
    String value(Pid? pid, int digits) {
      // valueOf, not readings[...]: a stale reading is no reading.
      final live = pid == null ? null : snapshot.valueOf(pid);
      return live == null ? '--' : live.toStringAsFixed(digits);
    }

    return _RoundInset(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('SOC', style: context.texts.labelSmall),
          Text(
            value(soc, 1),
            key: const Key('wear_battery_soc'),
            style: context.texts.displayLarge,
          ),
          Text('%', style: context.texts.labelSmall),
          const SizedBox(height: Spacing.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _MiniNumber(label: 'Pack V', text: value(volts, 1)),
              _MiniNumber(label: 'Pack A', text: value(amps, 1)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Four numbers, no dials: the readings a glance actually resolves.
class _WearNumbersPage extends ConsumerWidget {
  const _WearNumbersPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot =
        ref.watch(telemetryProvider).value ?? const TelemetrySnapshot();
    String reading(Pid pid, int digits) {
      // valueOf, not readings[...]: a stale reading is no reading.
      final value = snapshot.valueOf(pid);
      return value == null ? '--' : value.toStringAsFixed(digits);
    }

    // batteryVoltage is age-bounded upstream in the client (a parsed-but-bad
    // ATRV clears it at once; a silent one expires at the cache's max age),
    // so reading it directly keeps the phone's semantics.
    final voltage = snapshot.batteryVoltage;
    return _RoundInset(
      child: GridView.count(
        crossAxisCount: 2,
        physics: const NeverScrollableScrollPhysics(),
        childAspectRatio: 1.4,
        children: [
          _MiniNumber(
            label: 'Coolant',
            text: reading(PidLibrary.coolantTemp, 0),
          ),
          _MiniNumber(label: 'IAT', text: reading(PidLibrary.intakeAirTemp, 0)),
          _MiniNumber(label: 'RPM', text: reading(PidLibrary.engineRpm, 0)),
          _MiniNumber(
            label: '電瓶',
            text: voltage == null ? '--' : voltage.toStringAsFixed(1),
          ),
        ],
      ),
    );
  }
}

class _MiniNumber extends StatelessWidget {
  const _MiniNumber({required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Text(text, style: context.texts.titleLarge),
      Text(label, style: context.texts.labelSmall),
    ],
  );
}

/// Insets content away from a round bezel without measuring the shape: the
/// margin that clears a circle's chord also looks right on a square face.
class _RoundInset extends StatelessWidget {
  const _RoundInset({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final shortest = MediaQuery.sizeOf(context).shortestSide;
    final inset = shortest * 0.12;
    return Padding(padding: EdgeInsets.all(inset), child: child);
  }
}
