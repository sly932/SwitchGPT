import Foundation

/// Serializes background capture with interactive switching. File metadata is cheap to poll
/// and observes ChatGPT's atomic file replacements as well as ordinary writes.
public final class LocalProjectStateMonitor: @unchecked Sendable {
  private let queue = DispatchQueue(label: "ai.shenliyuan.switchgpt.local-project-monitor")
  private let lock = NSLock()
  private let observedURLs: [URL]
  private let interval: TimeInterval
  private let update: @Sendable () throws -> Void
  private let reportFailure: @Sendable () -> Void
  private var timer: DispatchSourceTimer?
  private var running = false
  private var paused = false
  private var signature: [FileSignature]?
  private var reportedFailure = false

  public init(
    observedURLs: [URL],
    interval: TimeInterval = 1,
    update: @escaping @Sendable () throws -> Void,
    reportFailure: @escaping @Sendable () -> Void = {}
  ) {
    self.observedURLs = observedURLs
    self.interval = max(interval, 0.1)
    self.update = update
    self.reportFailure = reportFailure
  }

  public func start() {
    lock.lock()
    guard !running else { lock.unlock(); return }
    running = true
    paused = false
    let timer = DispatchSource.makeTimerSource(queue: queue)
    self.timer = timer
    timer.schedule(deadline: .now(), repeating: interval)
    timer.setEventHandler { [weak self] in self?.poll() }
    timer.resume()
    lock.unlock()
  }

  /// Returns after a capture already in progress has finished. No new capture can start
  /// until resume(), so a switch owns the shared state for its whole transaction.
  public func pauseAndWait() {
    lock.withLock { paused = true }
    queue.sync {}
  }

  public func resume() {
    lock.withLock { paused = false }
    queue.async { [weak self] in self?.poll(force: true) }
  }

  public func stop() {
    let timer = lock.withLock {
      running = false
      let timer = self.timer
      self.timer = nil
      return timer
    }
    timer?.cancel()
    queue.sync {}
  }

  private func poll(force: Bool = false) {
    guard lock.withLock({ running && !paused }) else { return }
    let current = observedURLs.map(FileSignature.init)
    guard force || signature != current else { return }
    do {
      try update()
      signature = current
      reportedFailure = false
    } catch {
      // Retry failed captures even when the file metadata is unchanged, while avoiding
      // repetitive error logs and keeping credentials out of diagnostics.
      if !reportedFailure { reportFailure() }
      reportedFailure = true
    }
  }
}

private struct FileSignature: Equatable {
  let modifiedAt: Date?
  let size: UInt64?
  let inode: UInt64?

  init(_ url: URL) {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    modifiedAt = attributes?[.modificationDate] as? Date
    size = (attributes?[.size] as? NSNumber)?.uint64Value
    inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
  }
}
