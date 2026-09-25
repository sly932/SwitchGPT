import AppKit
import Darwin
import SwiftUI
import SwitchGPTAppCore

final class SwitchGPTAppDelegate: NSObject, NSApplicationDelegate {
  private let logger = LoggerBridge.lifecycle
  private var instanceLockFD: Int32 = -1

  func applicationWillFinishLaunching(_ notification: Notification) {
    guard acquireInstanceLock() else {
      if let bundleIdentifier = Bundle.main.bundleIdentifier {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
          .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })?
          .activate(options: [.activateAllWindows])
      }
      NSApp.terminate(nil)
      return
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard instanceLockFD >= 0 else { return }
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    logger.info("SwitchGPT UI launched in read-only quota mode")
  }

  func applicationWillTerminate(_ notification: Notification) {
    if instanceLockFD >= 0 {
      close(instanceLockFD)
      instanceLockFD = -1
    }
  }

  private func acquireInstanceLock() -> Bool {
    guard let bundleIdentifier = Bundle.main.bundleIdentifier,
      let applicationSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    else { return false }

    let directory = applicationSupport.appendingPathComponent(bundleIdentifier, isDirectory: true)
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true
      )
    } catch {
      logger.error("Could not create the single-instance lock directory: \(error)")
      return false
    }

    let descriptor = open(directory.appendingPathComponent("instance.lock").path,
      O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      logger.error("Could not open the single-instance lock file")
      return false
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      close(descriptor)
      return false
    }
    instanceLockFD = descriptor
    return true
  }
}

@main
struct SwitchGPTApp: App {
  @NSApplicationDelegateAdaptor(SwitchGPTAppDelegate.self) private var appDelegate
  @AppStorage(AppLanguage.storageKey) private var languageRawValue = AppLanguage.system.rawValue
  @State private var store = SwitchGPTAppStore(
    persistence: PreviewStateFileStore.defaultStore,
    initialAccounts: []
  )
  @State private var updateStore = AppUpdateStore()
  @State private var listPreferences = AccountListPreferences()

  private var appLocale: Locale {
    (AppLanguage(rawValue: languageRawValue) ?? .system).locale
  }

  var body: some Scene {
    Window("switchgpt-sly", id: "dashboard") {
      DashboardView(store: store, updateStore: updateStore, listPreferences: listPreferences)
        .environment(\.locale, appLocale)
    }
    .defaultSize(width: 820, height: 592)
    .windowStyle(.hiddenTitleBar)
    .commands {
      SwitchGPTCommands(store: store, updateStore: updateStore)
    }

    Window(L10n.string("Settings"), id: "display-settings") {
      AccountListSettingsView(preferences: listPreferences, store: store)
        .environment(\.locale, appLocale)
    }
    .defaultSize(width: 590, height: 660)

    MenuBarExtra {
      MenuBarView(store: store, listPreferences: listPreferences)
        .id(languageRawValue)
        .environment(\.locale, appLocale)
    } label: {
      MenuBarLabel(store: store)
        .environment(\.locale, appLocale)
    }
    .menuBarExtraStyle(.window)
  }
}

private enum LoggerBridge {
  static let lifecycle = OSLogProxy(subsystem: "com.kunpeng.switchgpt", category: "lifecycle")
}

private struct OSLogProxy {
  let subsystem: String
  let category: String

  func info(_ message: String) {
    NSLog("[%@/%@] %@", subsystem, category, message)
  }

  func error(_ message: String) {
    NSLog("[%@/%@] ERROR: %@", subsystem, category, message)
  }
}
