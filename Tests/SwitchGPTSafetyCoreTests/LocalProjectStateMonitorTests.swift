import Foundation
import XCTest

@testable import SwitchGPTDesktopIntegration

final class LocalProjectStateMonitorTests: XCTestCase {
  func testStartCapturesExistingStateWithoutWaitingForAnEdit() throws {
    let fixture = try ProjectMonitorFixture()
    defer { fixture.remove() }
    let captured = DispatchSemaphore(value: 0)
    let monitor = LocalProjectStateMonitor(observedURLs: [fixture.fileURL], interval: 0.1) {
      fixture.record(try fixture.read())
      captured.signal()
    }
    defer { monitor.stop() }

    monitor.start()
    monitor.start()
    try waitFor(captured)
    monitor.pauseAndWait()

    XCTAssertEqual(fixture.values, ["before"])
  }

  func testAtomicReplacementIsCapturedEvenWhenSizeAndModificationDateMatch() throws {
    let fixture = try ProjectMonitorFixture()
    defer { fixture.remove() }
    let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes(
      [.modificationDate: originalDate], ofItemAtPath: fixture.fileURL.path
    )
    let firstCapture = DispatchSemaphore(value: 0)
    let releaseFirstCapture = DispatchSemaphore(value: 0)
    let changedCapture = DispatchSemaphore(value: 0)
    let monitor = LocalProjectStateMonitor(observedURLs: [fixture.fileURL], interval: 0.1) {
      let value = try fixture.read()
      fixture.record(value)
      if value == "before" {
        firstCapture.signal()
        guard releaseFirstCapture.wait(timeout: .now() + 3) == .success else {
          throw ProjectMonitorFixtureError.timeout
        }
      } else {
        changedCapture.signal()
      }
    }
    defer { releaseFirstCapture.signal(); monitor.stop() }
    monitor.start()
    try waitFor(firstCapture)

    let previous = try FileManager.default.attributesOfItem(atPath: fixture.fileURL.path)
    try fixture.replace(with: "after!")
    try FileManager.default.setAttributes(
      [.modificationDate: originalDate],
      ofItemAtPath: fixture.fileURL.path
    )
    let current = try FileManager.default.attributesOfItem(atPath: fixture.fileURL.path)
    XCTAssertEqual(current[.size] as? NSNumber, previous[.size] as? NSNumber)
    XCTAssertEqual(current[.modificationDate] as? Date, previous[.modificationDate] as? Date)
    XCTAssertNotEqual(current[.systemFileNumber] as? NSNumber, previous[.systemFileNumber] as? NSNumber)

    // The first poll commits its original signature only after the replacement is complete.
    releaseFirstCapture.signal()
    try waitFor(changedCapture)
    monitor.pauseAndWait()
    XCTAssertEqual(fixture.values, ["before", "after!"])
  }

  func testPauseDrainsInFlightCaptureAndResumeAppliesThePendingEdit() throws {
    let fixture = try ProjectMonitorFixture()
    defer { fixture.remove() }
    let captureEntered = DispatchSemaphore(value: 0)
    let releaseCapture = DispatchSemaphore(value: 0)
    let pauseRequested = DispatchSemaphore(value: 0)
    let pauseCompleted = DispatchSemaphore(value: 0)
    let changedCapture = DispatchSemaphore(value: 0)
    let monitor = LocalProjectStateMonitor(observedURLs: [fixture.fileURL], interval: 0.1) {
      let attempt = fixture.beginAttempt()
      let value = try fixture.read()
      if attempt == 1 {
        captureEntered.signal()
        guard releaseCapture.wait(timeout: .now() + 3) == .success else {
          throw ProjectMonitorFixtureError.timeout
        }
      }
      fixture.record(value)
      if value == "after!" { changedCapture.signal() }
    }
    defer { releaseCapture.signal(); monitor.stop() }
    monitor.start()
    try waitFor(captureEntered)
    DispatchQueue.global().async {
      pauseRequested.signal()
      monitor.pauseAndWait()
      pauseCompleted.signal()
    }
    try waitFor(pauseRequested)
    XCTAssertEqual(pauseCompleted.wait(timeout: .now() + 0.1), .timedOut)

    releaseCapture.signal()
    try waitFor(pauseCompleted)
    XCTAssertEqual(fixture.values, ["before"])
    try fixture.replace(with: "after!")
    XCTAssertEqual(changedCapture.wait(timeout: .now() + 0.25), .timedOut)
    monitor.pauseAndWait()
    XCTAssertEqual(fixture.attempts, 1)

    monitor.resume()
    try waitFor(changedCapture)
    monitor.pauseAndWait()
    XCTAssertEqual(fixture.values, ["before", "after!"])
  }

  func testFailedCaptureRetriesWithoutAnEditAndReportsOnceUntilSuccess() throws {
    let fixture = try ProjectMonitorFixture()
    defer { fixture.remove() }
    let reported = DispatchSemaphore(value: 0)
    let recovered = DispatchSemaphore(value: 0)
    let changedCapture = DispatchSemaphore(value: 0)
    let monitor = LocalProjectStateMonitor(
      observedURLs: [fixture.fileURL], interval: 0.1,
      update: {
        guard fixture.beginAttempt() >= 3 else { throw ProjectMonitorFixtureError.retry }
        let value = try fixture.read()
        fixture.record(value)
        if value == "after!" { changedCapture.signal() } else { recovered.signal() }
      },
      reportFailure: {
        fixture.recordFailure()
        reported.signal()
      }
    )
    defer { monitor.stop() }
    monitor.start()
    try waitFor(reported)
    try waitFor(recovered)
    monitor.pauseAndWait()
    XCTAssertEqual(fixture.attempts, 3)
    XCTAssertEqual(fixture.failures, 1)
    XCTAssertEqual(fixture.values, ["before"])

    try fixture.replace(with: "after!")
    monitor.resume()
    try waitFor(changedCapture)
    monitor.pauseAndWait()
    XCTAssertEqual(fixture.values, ["before", "after!"])
  }

  private func waitFor(
    _ semaphore: DispatchSemaphore,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    guard semaphore.wait(timeout: .now() + 3) == .success else {
      XCTFail("Timed out waiting for a monitor callback", file: file, line: line)
      throw ProjectMonitorFixtureError.timeout
    }
  }
}

private enum ProjectMonitorFixtureError: Error {
  case timeout
  case retry
}

private final class ProjectMonitorFixture: @unchecked Sendable {
  let directory: URL
  let fileURL: URL
  private let lock = NSLock()
  private var capturedValues: [String] = []
  private var attemptCount = 0
  private var failureCount = 0

  var values: [String] { lock.withLock { capturedValues } }
  var attempts: Int { lock.withLock { attemptCount } }
  var failures: Int { lock.withLock { failureCount } }

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("switchgpt-project-monitor-\(UUID().uuidString)", isDirectory: true)
    fileURL = directory.appendingPathComponent("state.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try replace(with: "before")
  }

  func read() throws -> String { try String(contentsOf: fileURL, encoding: .utf8) }

  func replace(with value: String) throws {
    try Data(value.utf8).write(to: fileURL, options: .atomic)
  }

  func beginAttempt() -> Int {
    lock.withLock {
      attemptCount += 1
      return attemptCount
    }
  }

  func record(_ value: String) { lock.withLock { capturedValues.append(value) } }
  func recordFailure() { lock.withLock { failureCount += 1 } }
  func remove() { try? FileManager.default.removeItem(at: directory) }
}
