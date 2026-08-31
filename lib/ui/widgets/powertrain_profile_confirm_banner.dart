/// Per-connection vehicle confirmation for installed battery profiles.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../obd/powertrain_battery/powertrain_battery_catalog.dart';
import '../../obd/powertrain_battery/powertrain_battery_profile.dart';
import '../../state/obd_session.dart';
import '../../state/pid_registry.dart';
import '../../state/powertrain_battery_profiles.dart';
import 'panel.dart';

/// Shown on the dashboard while a connection is live and an installed
/// battery profile has not yet been confirmed for it.
///
/// Installation makes definitions available; it does not say "the vehicle at
/// the other end of this adapter is that vehicle". This banner is where the
/// driver says so, once per connection — the grant dies with the connection,
/// so plugging into a different car never inherits it.
class PowertrainProfileConfirmBanner extends ConsumerWidget {
  const PowertrainProfileConfirmBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(obdSessionProvider).isConnected;
    if (!connected) return const SizedBox.shrink();

    final registryPids = ref.watch(pidRegistryProvider);
    final authorizations = ref.watch(powertrainProfileAuthorizationsProvider);
    // One source revision per installed profile, taken from its own PIDs so
    // the liveness check below matches exactly what the polling filter sees.
    final installedRevisions = <String, String?>{
      for (final pid in registryPids)
        if (!pid.isCustom && pid.ownerProfileId != null)
          pid.ownerProfileId!: pid.sourceRevision,
    };
    final generation = ref
        .read(obdSessionProvider.notifier)
        .connectionGeneration;
    // The banner and the polling filter share one liveness predicate: any
    // grant the poller would refuse — stale generation, or a catalog
    // revision that changed under the install — makes the row reappear and
    // ask again, instead of hiding it over dark gauges.
    final unconfirmed = [
      for (final entry in installedRevisions.entries)
        if (!isLivePowertrainAuthorization(
          authorizations[entry.key],
          connectionGeneration: generation,
          sourceRevision: entry.value,
        ))
          entry.key,
    ];
    if (unconfirmed.isEmpty) return const SizedBox.shrink();

    final snapshot = ref
        .watch(powertrainBatteryCatalogSnapshotProvider)
        .value;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.lg,
        0,
        Spacing.lg,
        Spacing.md,
      ),
      child: Panel(
        key: const Key('powertrain_profile_confirm_banner'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('車輛電池訊號待確認', style: context.texts.titleMedium),
            const SizedBox(height: Spacing.xs),
            Text(
              '已安裝的車型訊號要先確認這台車就是該車型，本次連線才會開始讀取。'
              '確認只對這次連線有效。',
              style: context.texts.bodySmall,
            ),
            const SizedBox(height: Spacing.sm),
            for (final profileId in unconfirmed)
              _ConfirmRow(
                profileId: profileId,
                snapshot: snapshot,
                profile: snapshot?.catalog.profiles
                    .where((profile) => profile.id == profileId)
                    .firstOrNull,
              ),
          ],
        ),
      ),
    );
  }
}

class _ConfirmRow extends ConsumerWidget {
  const _ConfirmRow({
    required this.profileId,
    required this.snapshot,
    required this.profile,
  });

  final String profileId;
  final PowertrainBatteryCatalogSnapshot? snapshot;
  final PowertrainBatteryProfile? profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolved = profile;
    final resolvedSnapshot = snapshot;
    final year = ref
        .read(pidRegistryProvider.notifier)
        .installedVehicleYear(profileId);
    return Row(
      children: [
        Expanded(
          child: Text(
            resolved == null
                ? profileId
                : '${resolved.displayName}${year == null ? '' : ' · $year'}',
            style: context.texts.bodyMedium,
          ),
        ),
        FilledButton(
          key: Key('powertrain_confirm_connection_$profileId'),
          onPressed: resolved == null || resolvedSnapshot == null || year == null
              ? null
              : () => _confirm(context, ref, resolvedSnapshot, resolved, year),
          child: const Text('確認車輛'),
        ),
      ],
    );
  }

  Future<void> _confirm(
    BuildContext context,
    WidgetRef ref,
    PowertrainBatteryCatalogSnapshot snapshot,
    PowertrainBatteryProfile profile,
    int year,
  ) async {
    // Captured before the dialog opens. The confirmation is a statement
    // about the vehicle on the wire *now*; if the connection changes while
    // the dialog sits open — a different adapter, a different car — the
    // acceptance must not carry over to whatever connected next.
    final session = ref.read(obdSessionProvider.notifier);
    final generationAtPrompt = session.connectionGeneration;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('確認連線中的車輛'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$year ${profile.make} ${profile.model}\n'
              '${profile.variant} · ${profile.market}',
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              '確認後，這個車型的唯讀電池查詢會在本次連線內定期輪詢。'
              '接錯車型可能得到看似合理但錯誤的數字——不確定就取消。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('powertrain_confirm_connection_accept'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('就是這台車'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    if (!ref.read(obdSessionProvider).isConnected ||
        session.connectionGeneration != generationAtPrompt) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('連線已改變，請對新的連線重新確認車輛。')),
      );
      return;
    }

    final result = ref
        .read(powertrainProfileAuthorizationsProvider.notifier)
        .authorize(
          snapshot: snapshot,
          profileId: profile.id,
          vehicleYear: year,
          connectionGeneration: generationAtPrompt,
        );
    if (!context.mounted) return;
    final granted = result?.canInstall ?? false;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          granted
              ? '已啟用 ${profile.displayName} 的電池訊號（本次連線）'
              : '無法啟用：${result == null || result.issues.isEmpty ? '設定檔不在已驗證目錄中' : result.issues.first.message}',
        ),
      ),
    );
  }
}
