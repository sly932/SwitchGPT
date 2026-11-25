import AppKit
import Darwin
import Foundation

public final class MacOSChatGPTProcessController: DesktopProcessControlling {
  public let bundleIdentifier: String
  public let applicationURL: URL
  public let timeout: TimeInterval
  public let terminationGracePeriod: TimeInterval
  public let launchStabilityPeriod: TimeInterval
  public let allowsTerminationFallback: Bool
  private let terminationStabilityPeriod: Duration = .milliseconds(500)
  private var processObservation = DesktopProcessObservation()

  public init(
    bundleIdentifier: String = "com.openai.codex",
    applicationURL: URL = URL(fileURLWithPath: "/Applications/ChatGPT.app"),
    timeout: TimeInterval = 30,
    terminationGracePeriod: TimeInterval = 2,
    launchStabilityPeriod: TimeInterval = 2,
    allowsTerminationFallback: Bool = true
  ) {
    self.bundleIdentifier = bundleIdentifier
    self.applicationURL = applicationURL.standardizedFileURL
    self.timeout = timeout
    self.terminationGracePeriod = min(max(terminationGracePeriod, 0), timeout)
    self.launchStabilityPeriod = min(max(launchStabilityPeriod, 0), timeout)
    self.allowsTerminationFallback = allowsTerminationFallback
    // The independent recovery helper is initialized before the first quit request. Capture
    // the running PID here so it can still see it while waiting for the transaction lock.
    observe(registeredApplications, at: .now)
  }

  public func isRunning() throws -> Bool {
    observe(registeredApplications, at: .now)
    return !processObservation.processIdentifiers.isEmpty
  }

  public func terminateAndWait() throws {
    let running = registeredApplications
    let originalProcessIdentifiers = Set(running.map(\.processIdentifier).filter { $0 > 0 })
    let start = ContinuousClock.now
    observe(running, at: start)
    for application in running {
      _ = application.terminate()
    }
    let deadline = start.advanced(by: .seconds(timeout))
    let fallbackDeadline = start.advanced(by: .seconds(terminationGracePeriod))
    var sentTerminationFallback = false
    while ContinuousClock.now < deadline {
      let remaining = registeredApplications
      let now = ContinuousClock.now
      observe(remaining, at: now)
      if processObservation.hasStopped(at: now, stabilityPeriod: terminationStabilityPeriod) {
        return
      }
      if allowsTerminationFallback, !sentTerminationFallback, now >= fallbackDeadline {
        for processIdentifier in Self.originalProcessesStillRunning(
          original: originalProcessIdentifiers,
          current: Set(remaining.map(\.processIdentifier))
        ) {
          _ = Darwin.kill(processIdentifier, SIGTERM)
        }
        sentTerminationFallback = true
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    throw DesktopIntegrationError.desktopDidNotTerminate
  }

  private var registeredApplications: [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
  }

  private func observe(_ running: [NSRunningApplication], at time: ContinuousClock.Instant) {
    processObservation.update(
      registered: Set(running.map(\.processIdentifier).filter { $0 > 0 }),
      at: time,
      isAlive: Self.isProcessAlive
    )
  }

  private static func isProcessAlive(_ processIdentifier: pid_t) -> Bool {
    // Signal 0 checks for the process without sending a signal. Permission errors still mean
    // the process may exist and must be treated as running.
    Darwin.kill(processIdentifier, 0) == 0 || errno != ESRCH
  }

  static func originalProcessesStillRunning(
    original: Set<pid_t>,
    current: Set<pid_t>
  ) -> Set<pid_t> {
    original.intersection(current)
  }

  public func launchAndWait() throws {
    guard FileManager.default.fileExists(atPath: applicationURL.path) else {
      throw DesktopIntegrationError.desktopDidNotLaunch
    }
    guard !(try isRunning()) else {
      throw DesktopIntegrationError.desktopDidNotTerminate
    }

    let launcher = Process()
    launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    launcher.arguments = ["-n", applicationURL.path]
    launcher.standardOutput = Pipe()
    launcher.standardError = Pipe()
    do {
      try launcher.run()
      launcher.waitUntilExit()
    } catch {
      throw DesktopIntegrationError.desktopDidNotLaunch
    }
    guard launcher.terminationStatus == 0 else {
      throw DesktopIntegrationError.desktopDidNotLaunch
    }

    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    var observedProcessIdentifier: pid_t?
    var observedSince: ContinuousClock.Instant?
    while ContinuousClock.now < deadline {
      let running = registeredApplications
      let now = ContinuousClock.now
      observe(running, at: now)
      if processObservation.processIdentifiers.count == 1,
        running.count == 1, let application = running.first,
        application.processIdentifier > 0, Self.isProcessAlive(application.processIdentifier)
      {
        if observedProcessIdentifier != application.processIdentifier {
          observedProcessIdentifier = application.processIdentifier
          observedSince = now
        }
        if let observedSince,
          observedSince.duration(to: now) >= .seconds(launchStabilityPeriod)
        {
          application.activate(options: [.activateAllWindows])
          return
        }
      } else {
        observedProcessIdentifier = nil
        observedSince = nil
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    throw DesktopIntegrationError.desktopDidNotLaunch
  }
}

struct DesktopProcessObservation {
  private(set) var processIdentifiers: Set<pid_t> = []
  private var stoppedSince: ContinuousClock.Instant?

  mutating func update(
    registered: Set<pid_t>,
    at time: ContinuousClock.Instant,
    isAlive: (pid_t) -> Bool
  ) {
    // During shutdown the app can temporarily disappear from AppKit's list while its PID
    // is still alive. Keep tracking every observed PID until both sources agree.
    processIdentifiers = processIdentifiers.filter(isAlive).union(registered)
    if processIdentifiers.isEmpty {
      stoppedSince = stoppedSince ?? time
    } else {
      stoppedSince = nil
    }
  }

  func hasStopped(at time: ContinuousClock.Instant, stabilityPeriod: Duration) -> Bool {
    guard let stoppedSince else { return false }
    return stoppedSince.duration(to: time) >= stabilityPeriod
  }
}
