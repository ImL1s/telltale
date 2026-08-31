library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

enum AppShareResult { selected, dismissed, unavailable, failed }

class AppSharePlatformRequest {
  const AppSharePlatformRequest({
    required this.path,
    required this.mimeType,
    required this.fileName,
    required this.subject,
    this.sharePositionOrigin,
  });
  final String path;
  final String mimeType;
  final String fileName;
  final String subject;

  /// Required on iPad for the share popover anchor; optional elsewhere.
  final Rect? sharePositionOrigin;
}

abstract interface class AppSharePlatform {
  Future<AppShareResult> share(AppSharePlatformRequest request);
}

/// The only production file-handoff adapter. macOS uses a native lifecycle
/// bridge; other supported platforms retain the pinned share_plus behavior.
class AppSharePlatformBridge implements AppSharePlatform {
  const AppSharePlatformBridge({this.useNativeMacOsShare});

  /// Test seam. Production leaves this null and follows [Platform.isMacOS].
  final bool? useNativeMacOsShare;

  static const _macOsChannel = MethodChannel('com.cbstudio.telltale/app_share');

  static AppShareResult mapStatus(ShareResultStatus status) => switch (status) {
    ShareResultStatus.success => AppShareResult.selected,
    ShareResultStatus.dismissed => AppShareResult.dismissed,
    ShareResultStatus.unavailable => AppShareResult.unavailable,
  };

  static AppShareResult mapNativeResult(Object? result) => switch (result) {
    'selected' => AppShareResult.selected,
    'dismissed' => AppShareResult.dismissed,
    'unavailable' => AppShareResult.unavailable,
    'failed' => AppShareResult.failed,
    _ => AppShareResult.failed,
  };

  @override
  Future<AppShareResult> share(AppSharePlatformRequest request) async {
    try {
      if (useNativeMacOsShare ?? Platform.isMacOS) {
        final result = await _macOsChannel.invokeMethod<Object?>('shareFile', {
          'path': request.path,
          'mimeType': request.mimeType,
          'fileName': request.fileName,
          'subject': request.subject,
        });
        return mapNativeResult(result);
      }
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(request.path, mimeType: request.mimeType)],
          subject: request.subject,
          fileNameOverrides: [request.fileName],
          sharePositionOrigin: request.sharePositionOrigin,
        ),
      );
      return mapStatus(result.status);
    } on Object {
      return AppShareResult.failed;
    }
  }
}
