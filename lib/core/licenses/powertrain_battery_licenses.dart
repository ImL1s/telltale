/// Packaged attribution and licence surface for the battery research catalog.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const powertrainBatteryLicenseAssets = <String>[
  'THIRD_PARTY_NOTICES_POWERTRAIN_BATTERY.md',
  'assets/licenses/Apache-2.0.txt',
  'assets/licenses/wican-bridge-MIT.txt',
  'assets/licenses/ovms-MIT.txt',
  'assets/licenses/GPL-3.0.txt',
];

bool _registered = false;

Future<String> loadPowertrainBatteryLicenseText({AssetBundle? bundle}) async {
  final source = bundle ?? rootBundle;
  final sections = <String>[];
  for (final asset in powertrainBatteryLicenseAssets) {
    sections.add(await source.loadString(asset));
  }
  return sections.join(
    '\n\n============================================================\n\n',
  );
}

/// Registers the bundled notices with Flutter's standard licence page.
///
/// Registration is idempotent so tests and hot reload cannot duplicate the
/// same entry. Asset reads remain lazy until a user opens the licence page.
void registerPowertrainBatteryLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'Telltale powertrain battery catalog sources',
    ], await loadPowertrainBatteryLicenseText());
  });
}
