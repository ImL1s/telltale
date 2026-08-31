import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let capacityChannel = FlutterMethodChannel(
      name: "com.cbstudio.telltale/app_storage_capacity",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    capacityChannel.setMethodCallHandler { call, result in
      guard call.method == "getAvailableBytes" else {
        result(FlutterMethodNotImplemented)
        return
      }
      do {
        let cacheURL = try FileManager.default.url(
          for: .cachesDirectory,
          in: .userDomainMask,
          appropriateFor: nil,
          create: true
        )
        let values = try cacheURL.resourceValues(
          forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let bytes = values.volumeAvailableCapacityForImportantUsage, bytes > 0 else {
          result(FlutterError(
            code: "capacity_invalid",
            message: "Available bytes were not positive",
            details: nil
          ))
          return
        }
        result(bytes)
      } catch {
        result(FlutterError(
          code: "capacity_failed",
          message: error.localizedDescription,
          details: nil
        ))
      }
    }
  }
}
