/// Lazily loads the bundled vehicle catalog only when the driver opens it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../obd/vehicle_catalog/us_vehicle_catalog.dart';

typedef UsVehicleCatalogLoader = Future<UsVehicleCatalog> Function();

final usVehicleCatalogLoaderProvider = Provider<UsVehicleCatalogLoader>(
  (ref) => UsVehicleCatalog.load,
);
