import Cocoa
import Darwin
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Kept open for the process lifetime so a second macOS instance under the
  /// same account cannot run startup recovery against live Documents artifacts.
  private var singleInstanceLockFd: Int32 = -1

  override func applicationWillFinishLaunching(_ notification: Notification) {
    if !acquireSingleInstanceLock() {
      activateExistingInstance()
      NSApp.terminate(nil)
      return
    }
    super.applicationWillFinishLaunching(notification)
  }

  override func applicationWillTerminate(_ notification: Notification) {
    if singleInstanceLockFd >= 0 {
      flock(singleInstanceLockFd, LOCK_UN)
      close(singleInstanceLockFd)
      singleInstanceLockFd = -1
    }
    super.applicationWillTerminate(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  private func acquireSingleInstanceLock() -> Bool {
    let bundleId = Bundle.main.bundleIdentifier ?? "com.cbstudio.telltale"
    guard
      let support = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      return false
    }
    let dir = support.appendingPathComponent(bundleId, isDirectory: true)
    do {
      try FileManager.default.createDirectory(
        at: dir,
        withIntermediateDirectories: true
      )
    } catch {
      return false
    }
    let path = dir.appendingPathComponent("single_instance.lock").path
    let fd = open(path, O_RDWR | O_CREAT, 0o600)
    if fd < 0 {
      return false
    }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
      close(fd)
      return false
    }
    singleInstanceLockFd = fd
    return true
  }

  private func activateExistingInstance() {
    guard let bundleId = Bundle.main.bundleIdentifier else { return }
    let others = NSRunningApplication.runningApplications(
      withBundleIdentifier: bundleId
    ).filter { !$0.isEqual(NSRunningApplication.current) }
    others.first?.activate(options: [.activateAllWindows])
  }
}
