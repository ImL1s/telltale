import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

class MainFlutterWindow: NSWindow {
  private var appShareHandler: AppShareHandler?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let capacityChannel = FlutterMethodChannel(
      name: "com.cbstudio.telltale/app_storage_capacity",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    capacityChannel.setMethodCallHandler { call, result in
      guard call.method == "getAvailableBytes" else {
        result(FlutterMethodNotImplemented)
        return
      }
      do {
        guard let cacheURL = FileManager.default.urls(
          for: .cachesDirectory,
          in: .userDomainMask
        ).first else {
          result(FlutterError(
            code: "capacity_unavailable",
            message: "Application cache directory is unavailable",
            details: nil
          ))
          return
        }
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

    let appShareHandler = AppShareHandler(window: self)
    self.appShareHandler = appShareHandler
    let shareChannel = FlutterMethodChannel(
      name: "com.cbstudio.telltale/app_share",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    shareChannel.setMethodCallHandler(appShareHandler.handle)

    super.awakeFromNib()
  }
}

/// Keeps the picker, selected service, and Flutter result alive until AppKit
/// reports service completion or failure. Picker selection alone is not the
/// lifecycle boundary for the immutable staged file.
private final class AppShareHandler: NSObject,
  NSSharingServicePickerDelegate,
  NSSharingServiceDelegate
{
  private weak var window: NSWindow?
  private var picker: NSSharingServicePicker?
  private var service: NSSharingService?
  private var items: [Any] = []
  private var subject: String?
  private var pendingResult: FlutterResult?

  init(window: NSWindow) {
    self.window = window
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "shareFile" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard pendingResult == nil else {
      result("unavailable")
      return
    }
    guard
      let arguments = call.arguments as? [String: Any],
      let path = arguments["path"] as? String,
      !path.isEmpty,
      let mimeType = arguments["mimeType"] as? String,
      let fileName = arguments["fileName"] as? String,
      let publicType = Self.publicType(mimeType: mimeType, fileName: fileName)
    else {
      result("failed")
      return
    }

    let url = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      !isDirectory.boolValue,
      let view = window?.contentView
    else {
      result("unavailable")
      return
    }

    let provider = NSItemProvider()
    provider.suggestedName = fileName
    provider.registerFileRepresentation(
      forTypeIdentifier: publicType.identifier,
      fileOptions: [],
      visibility: .all
    ) { completion in
      var isDirectory: ObjCBool = false
      guard
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else {
        completion(nil, false, CocoaError(.fileNoSuchFile))
        return nil
      }
      // AppKit copies the representation because open-in-place was not
      // requested. The app-owned source remains immutable under its Dart
      // lease until didShare/didFail/dismiss completes below.
      completion(url, false, nil)
      return nil
    }

    pendingResult = result
    items = [provider]
    subject = arguments["subject"] as? String
    let picker = NSSharingServicePicker(items: items)
    self.picker = picker
    picker.delegate = self
    picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
  }

  func sharingServicePicker(
    _ sharingServicePicker: NSSharingServicePicker,
    delegateFor sharingService: NSSharingService
  ) -> NSSharingServiceDelegate? {
    service = sharingService
    sharingService.subject = subject
    return self
  }

  func sharingServicePicker(
    _ sharingServicePicker: NSSharingServicePicker,
    didChoose sharingService: NSSharingService?
  ) {
    guard let sharingService else {
      finish("dismissed")
      return
    }
    guard picker != nil, !items.isEmpty, service === sharingService else {
      finish("failed")
      return
    }
    // NSSharingServicePicker performs the selected service itself. Waiting for
    // its delegate callbacks avoids both the stock didChoose race and a second
    // accidental perform(withItems:) invocation.
  }

  func sharingService(
    _ sharingService: NSSharingService,
    didShareItems items: [Any]
  ) {
    // "selected" is deliberately only an app-level handoff result. Even this
    // callback does not prove that a recipient delivered, saved, or sent data.
    finish("selected")
  }

  func sharingService(
    _ sharingService: NSSharingService,
    didFailToShareItems items: [Any],
    error: Error
  ) {
    let cocoaError = error as NSError
    if cocoaError.domain == NSCocoaErrorDomain,
      cocoaError.code == NSUserCancelledError
    {
      finish("dismissed")
    } else {
      finish("failed")
    }
  }

  private static func publicType(mimeType: String, fileName: String) -> UTType? {
    guard
      !fileName.isEmpty,
      fileName == URL(fileURLWithPath: fileName).lastPathComponent,
      !fileName.contains("/"),
      !fileName.contains("\\")
    else {
      return nil
    }
    let extensionName = URL(fileURLWithPath: fileName).pathExtension.lowercased()
    switch (mimeType, extensionName) {
    case ("text/csv", "csv"):
      return .commaSeparatedText
    case ("application/json", "json"):
      return .json
    case ("text/plain", "txt"):
      return .plainText
    default:
      return nil
    }
  }

  private func finish(_ value: String) {
    let result = pendingResult
    pendingResult = nil
    service = nil
    picker = nil
    items = []
    subject = nil
    result?(value)
  }
}
