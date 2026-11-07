import Darwin
import Foundation
import Observation
import SwitchGPTAppCore

@MainActor
@Observable
final class SubscriptionDisplayStore {
  static let shared = SubscriptionDisplayStore()

  private(set) var subscriptions: [String: AccountSubscription] = [:]
  private(set) var errorMessage: String?
  private(set) var lastReloadedAt: Date?

  @ObservationIgnored private let fileStore: AccountSubscriptionStore
  @ObservationIgnored private var observedFiles: [ObservedPlanFile]?
  @ObservationIgnored private var directoryObserver: UsagePlanDirectoryObserver?

  init(fileStore: AccountSubscriptionStore = .defaultStore) {
    self.fileStore = fileStore
    directoryObserver = UsagePlanDirectoryObserver(
      directory: fileStore.fileURL.deletingLastPathComponent()
    ) { [weak self] in
      Task { @MainActor [weak self] in self?.reload() }
    }
    reload()
  }

  func expiry(for email: String?) -> String? {
    guard let email else { return nil }
    if let exact = subscriptions[email] { return exact.expiresOn }
    return subscriptions.first { $0.key.caseInsensitiveCompare(email) == .orderedSame }?.value.expiresOn
  }

  func reload() {
    let filesBeforeRead = planFiles()
    guard observedFiles != filesBeforeRead || errorMessage != nil else { return }
    do {
      subscriptions = try fileStore.read()
      errorMessage = nil
      observedFiles = filesBeforeRead
      lastReloadedAt = .now
      // An atomic replacement during the read must not mark the newer file as already loaded.
      if filesBeforeRead != planFiles() {
        Task { @MainActor [weak self] in self?.reload() }
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @discardableResult
  func saveExpiry(_ value: String?, for email: String) -> Bool {
    do {
      try fileStore.setExpiry(email: email, expiresOn: value)
      reload()
      return errorMessage == nil
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  private func planFiles() -> [ObservedPlanFile] {
    let directory = fileStore.fileURL.deletingLastPathComponent()
    return [fileStore.fileURL, directory.appendingPathComponent("usage-plan.json"),
      directory.appendingPathComponent("usage-plan.html")].map(ObservedPlanFile.init)
  }
}

private struct ObservedPlanFile: Equatable {
  let exists: Bool
  let device: dev_t
  let inode: ino_t
  let size: off_t
  let seconds: Int
  let nanoseconds: Int

  init(url: URL) {
    var info = stat()
    exists = url.path.withCString { lstat($0, &info) } == 0
    device = info.st_dev
    inode = info.st_ino
    size = info.st_size
    seconds = info.st_mtimespec.tv_sec
    nanoseconds = info.st_mtimespec.tv_nsec
  }
}

/// Watches the directory because atomic JSON writes replace the original file inode.
/// All mutable observation state stays on this private serial queue.
private final class UsagePlanDirectoryObserver: @unchecked Sendable {
  private let directory: URL
  private let onChange: @Sendable () -> Void
  private let queue = DispatchQueue(label: "SwitchGPT.usage-plan-observation")
  private var source: DispatchSourceFileSystemObject?
  private var pendingChange: DispatchWorkItem?

  init(directory: URL, onChange: @escaping @Sendable () -> Void) {
    self.directory = directory
    self.onChange = onChange
    queue.async { [weak self] in
      self?.startObserving()
      self?.onChange()
    }
  }

  deinit {
    pendingChange?.cancel()
    source?.cancel()
  }

  private func startObserving() {
    source?.cancel()
    source = nil
    var candidate = directory
    while true {
      let descriptor = candidate.path.withCString { open($0, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW) }
      var info = stat()
      if descriptor >= 0, fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
        let observation = DispatchSource.makeFileSystemObjectSource(
          fileDescriptor: descriptor,
          eventMask: [.write, .rename, .delete, .revoke],
          queue: queue
        )
        observation.setEventHandler { [weak self] in self?.scheduleReload() }
        observation.setCancelHandler { close(descriptor) }
        source = observation
        observation.resume()
        return
      }
      if descriptor >= 0 { close(descriptor) }
      let parent = candidate.deletingLastPathComponent()
      guard parent.path != candidate.path else { return }
      candidate = parent
    }
  }

  private func scheduleReload() {
    pendingChange?.cancel()
    let change = DispatchWorkItem { [weak self] in
      guard let self else { return }
      // The directory may just have been created or replaced. Reopen it before reading.
      self.startObserving()
      self.onChange()
    }
    pendingChange = change
    queue.asyncAfter(deadline: .now() + .milliseconds(120), execute: change)
  }
}
