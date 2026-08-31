library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../obd/session_evidence.dart';
import '../field_evidence/platform_metadata.dart';
import 'app_share_platform_bridge.dart';

const rigShareCaptureDirectoryName = 'telltale-rig-captured-shares';

Future<Directory> rigShareCaptureDirectory() async => Directory(
  '${(await getApplicationCacheDirectory()).path}/$rigShareCaptureDirectoryName',
);

/// Capture-only final hand-off for the isolated Android rig application.
///
/// This is never selected by a field build. It deliberately reports only that
/// the rig sink accepted a byte-for-byte copy; it is not evidence of an OS
/// chooser selection, external delivery, radio, adapter, or vehicle.
final class RigAppSharePlatform implements AppSharePlatform {
  const RigAppSharePlatform({required this.metadata});

  final PlatformMetadata metadata;

  @override
  Future<AppShareResult> share(AppSharePlatformRequest request) async {
    if (!isRigShareCaptureEligible(
      metadata: metadata,
      buildFlag: isObdTestRigBuild,
      debugMode: kDebugMode,
    )) {
      throw StateError('rig Share capture is disabled in field builds');
    }
    if (request.fileName.isEmpty ||
        request.fileName.contains('/') ||
        request.fileName.contains(r'\')) {
      return AppShareResult.failed;
    }
    final source = File(request.path);
    if (await FileSystemEntity.type(source.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return AppShareResult.failed;
    }
    final root = await rigShareCaptureDirectory();
    await root.create(recursive: true);
    final destination = File('${root.path}/${request.fileName}');
    final staging = File('${destination.path}.part');
    if (await staging.exists()) await staging.delete();
    await source.copy(staging.path);
    if (await destination.exists()) await destination.delete();
    await staging.rename(destination.path);
    return AppShareResult.selected;
  }
}
