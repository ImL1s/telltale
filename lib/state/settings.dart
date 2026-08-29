/// User settings: vehicle parameters and appearance.
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/theme/gauge_skin.dart';
import '../obd/transport/obd_transport.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../obd/physics/vehicle_profile.dart';
import 'pid_registry.dart';

const _kVehicleProfileKey = 'vehicle_profile_v1';
const _kThemeModeKey = 'theme_mode_v1';

class VehicleProfileController extends Notifier<VehicleProfile> {
  @override
  VehicleProfile build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final raw = prefs.getString(_kVehicleProfileKey);
    if (raw == null) return const VehicleProfile();
    try {
      final decoded = jsonDecode(raw);
      // Valid JSON of the wrong shape parses and then throws `TypeError` on the
      // cast — a stored `[]`, or a field that changed type between builds.
      // That was unhandled, so a corrupt preference stopped the settings
      // screen from loading at all rather than falling back to defaults.
      if (decoded is! Map<String, dynamic>) return const VehicleProfile();
      // Assumptions persist; trust does not. A different launch or connection
      // may be a different vehicle, and no adapter identifier proves which car
      // is on the other side of the diagnostic socket.
      return VehicleProfile.fromJson(decoded).unconfirmed();
    } on Object {
      return const VehicleProfile();
    }
  }

  Future<void> update(VehicleProfile profile) async {
    // A profile is confirmed as a whole. Keeping the flag after one field is
    // changed would make the remaining assumptions look reviewed when they
    // are not, so every edit returns to the fail-closed state.
    final edited = profile.unconfirmed();
    state = edited;
    await _persistAssumptions(edited);
  }

  Future<void> confirm() async {
    final confirmed = state.confirmAssumptions();
    state = confirmed;
    // Store the editable assumptions, never a cross-session trust decision.
    await _persistAssumptions(confirmed);
  }

  /// Starts or ends a connection boundary.
  ///
  /// Confirmation is deliberately session-scoped because ELM327 adapters do
  /// not identify the vehicle they are plugged into. VIN is optional and may
  /// arrive only after the session is already live, so every connection must
  /// fail closed until the driver confirms the current car.
  Future<void> invalidateForVehicleBoundary() async {
    state = state.unconfirmed();
    await _persistAssumptions(state);
  }

  Future<void> _persistAssumptions(VehicleProfile profile) async {
    final stored = profile.unconfirmed();
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(_kVehicleProfileKey, jsonEncode(stored.toJson()));
  }
}

final vehicleProfileProvider =
    NotifierProvider<VehicleProfileController, VehicleProfile>(
      VehicleProfileController.new,
    );

class ThemeModeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final stored = prefs.getString(_kThemeModeKey);
    return switch (stored) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      // Dark is the default rather than following the system: this is an
      // instrument cluster, and a white screen at night is genuinely unsafe
      // to glance at while driving.
      _ => ThemeMode.dark,
    };
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(_kThemeModeKey, mode.name);
  }
}

final themeModeProvider = NotifierProvider<ThemeModeController, ThemeMode>(
  ThemeModeController.new,
);

const _kGaugeSkinKey = 'gauge_skin';

/// Which instrument the dashboard draws.
///
/// Separate from [themeModeProvider] because they answer different questions.
/// Light and dark are about the ambient light you are reading in; a skin is
/// about what kind of instrument you want — and every skin has to work in
/// both, which is why the two are not folded together into a list of "themes".
class GaugeSkinController extends Notifier<GaugeSkin> {
  @override
  GaugeSkin build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    // Unknown ids fall back rather than throwing: a skin removed in a later
    // release must not stop the app opening on a phone that had it selected.
    return GaugeSkin.byId(prefs.getString(_kGaugeSkinKey));
  }

  Future<void> set(GaugeSkin skin) async {
    state = skin;
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(_kGaugeSkinKey, skin.id);
  }
}

final gaugeSkinProvider = NotifierProvider<GaugeSkinController, GaugeSkin>(
  GaugeSkinController.new,
);

const _kLastAdapterKey = 'last_adapter_v1';

/// The adapter this app connected to last.
///
/// Remembered because of what the alternative looks like from a driving seat.
/// The bonded list comes from the phone, not from this app, so it is mostly
/// headphones, a car stereo and a laptop — and the one entry that matters is
/// somewhere in it, named `OBDII` or `V-LINK` or `Vgate` if you are lucky and
/// something worse if you are not. Doing that hunt every single time, in a car
/// park, is the difference between a tool and a chore.
///
/// Recorded on *attempt* rather than on success, for the same reason the Wi-Fi
/// address is: an adapter that failed once is still overwhelmingly the one you
/// meant, and the second try is exactly when not having to find it again
/// matters most.
class LastAdapter {
  const LastAdapter({
    required this.id,
    required this.name,
    required this.kind,
    this.port,
  });

  final String id;
  final String name;
  final TransportKind kind;

  /// A separate field rather than packed into [id].
  ///
  /// The first version encoded Wi-Fi as `host:port` and split on the colon,
  /// which is correct for `192.168.0.10:35000` and silently wrong for an IPv6
  /// address: `fe80::1` splits into `fe80` and an empty port, so the shortcut
  /// would have connected to a different host on the default port and said
  /// nothing about it. Rare, and exactly the class of quiet wrong answer this
  /// app refuses everywhere else.
  final int? port;

  String encode() => '${kind.name}\u0000$id\u0000$name\u0000${port ?? ''}';

  /// Null for anything that does not parse. A stored value from an older
  /// build, or a half-written one, must not stop the connect screen drawing.
  static LastAdapter? decode(String? raw) {
    if (raw == null) return null;
    final parts = raw.split('\u0000');
    // Three is the shape the first version wrote. Accepted so an adapter
    // remembered before this change is not silently forgotten on upgrade —
    // which would put somebody back in the list of headphones for no reason
    // they could see.
    if (parts.length != 3 && parts.length != 4) return null;
    final kind = TransportKind.values
        .where((k) => k.name == parts[0])
        .firstOrNull;
    if (kind == null || parts[1].isEmpty) return null;
    return LastAdapter(
      id: parts[1],
      name: parts[2],
      kind: kind,
      port: parts.length == 4 ? int.tryParse(parts[3]) : null,
    );
  }
}

class LastAdapterController extends Notifier<LastAdapter?> {
  @override
  LastAdapter? build() => LastAdapter.decode(
    ref.watch(sharedPreferencesProvider).getString(_kLastAdapterKey),
  );

  Future<void> remember(LastAdapter adapter) async {
    state = adapter;
    await ref
        .read(sharedPreferencesProvider)
        .setString(_kLastAdapterKey, adapter.encode());
  }

  Future<void> forget() async {
    state = null;
    await ref.read(sharedPreferencesProvider).remove(_kLastAdapterKey);
  }
}

final lastAdapterProvider =
    NotifierProvider<LastAdapterController, LastAdapter?>(
      LastAdapterController.new,
    );
