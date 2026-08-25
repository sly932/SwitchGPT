import SwiftUI
import SwitchGPTAppCore

struct SwitchGPTCommands: Commands {
  let store: SwitchGPTAppStore
  let updateStore: AppUpdateStore

  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(after: .appInfo) {
      Button(updateStore.isChecking ? "Checking for Updates…" : "Check for Updates…") {
        openWindow(id: "dashboard")
        Task { await updateStore.checkManually() }
      }
      .disabled(updateStore.isChecking)
    }

    CommandMenu("SwitchGPT") {
      Button("Open Dashboard") {
        openWindow(id: "dashboard")
      }
      .keyboardShortcut("0")

      Button("Refresh Usage") {
        Task { await store.refresh() }
      }
      .keyboardShortcut("r", modifiers: [.command, .option])
      .disabled(store.activity.isBusy)
    }

    CommandGroup(replacing: .appSettings) {}
    CommandGroup(replacing: .sidebar) {}
  }
}
