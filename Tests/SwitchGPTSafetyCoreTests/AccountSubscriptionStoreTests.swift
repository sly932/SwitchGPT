import Darwin
import XCTest

@testable import SwitchGPTAppCore

@MainActor
final class AccountSubscriptionStoreTests: XCTestCase {
  func testDateValidationPreservesCalendarDayPrecision() {
    for value in ["2026-11-07", "2028-02-29", "0001-01-01"] {
      XCTAssertTrue(AccountSubscription.isValidDate(value), value)
    }
    for value in ["2026-02-29", "2026-11-31", "2026-13-01", "2026-00-01", "2026-1-01", "0000-01-01", "2026-11-07T00:00:00Z", "２０２６-11-07"] {
      XCTAssertFalse(AccountSubscription.isValidDate(value), value)
    }
    XCTAssertThrowsError(try AccountSubscription(expiresOn: "2026-11-07", source: "api", updatedAt: "2026-11-07T04:02:01Z"))
    XCTAssertThrowsError(try AccountSubscription(expiresOn: "2026-11-07", source: "manual", updatedAt: "2026-11-07T04:02:01"))
  }

  func testManualEditsPreserveSnapshotAndOtherAccounts() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("account-state.json")
    let original: [String: Any] = [
      "schemaVersion": 1, "source": "live", "command": "quota",
      "generatedAt": "2026-11-07T04:02:01Z", "unknownFutureField": ["keep": true],
      "accounts": [
        ["email": "first@example.com", "status": "ok", "quota": ["weekly": ["remainingPercent": 97]]],
        ["email": "other@example.com", "status": "error", "error": ["code": "timed_out"]],
      ],
    ]
    try write(original, to: file)
    let store = AccountSubscriptionStore(fileURL: file)

    try store.setExpiry(email: "first@example.com", expiresOn: "2026-11-19")

    let subscriptions = try store.read()
    XCTAssertEqual(subscriptions["first@example.com"]?.expiresOn, "2026-11-19")
    XCTAssertEqual(subscriptions["first@example.com"]?.source, "manual")
    let saved = try snapshot(at: file)
    XCTAssertEqual(saved["generatedAt"] as? String, original["generatedAt"] as? String)
    XCTAssertEqual(saved["unknownFutureField"] as? NSDictionary, original["unknownFutureField"] as? NSDictionary)
    let before = try XCTUnwrap(original["accounts"] as? [[String: Any]])
    let after = try XCTUnwrap(saved["accounts"] as? [[String: Any]])
    XCTAssertEqual(after[0]["quota"] as? NSDictionary, before[0]["quota"] as? NSDictionary)
    XCTAssertEqual(after[1] as NSDictionary, before[1] as NSDictionary)
    XCTAssertNotNil(saved["revision"] as? String)
    XCTAssertNotNil(saved["metadataUpdatedAt"] as? String)
    let firstRevision = saved["revision"] as? String

    try store.setExpiry(email: "first@example.com", expiresOn: nil)

    XCTAssertTrue(try store.read().isEmpty)
    let cleared = try snapshot(at: file)
    XCTAssertEqual(cleared["generatedAt"] as? String, original["generatedAt"] as? String)
    XCTAssertNotEqual(cleared["revision"] as? String, firstRevision)
    let clearedAccounts = try XCTUnwrap(cleared["accounts"] as? [[String: Any]])
    XCTAssertNil(clearedAccounts[0]["subscription"])
    XCTAssertEqual(clearedAccounts[0]["quota"] as? NSDictionary, before[0]["quota"] as? NSDictionary)
    try store.setExpiry(email: "FIRST@example.com", expiresOn: "2026-12-01")
    XCTAssertEqual(try store.read()["first@example.com"]?.expiresOn, "2026-12-01")
    XCTAssertEqual(try (snapshot(at: file)["accounts"] as? [[String: Any]])?.count, 2)
  }

  func testFirstManualEntryCreatesMetadataOnlySnapshotWithPrivatePermissions() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let directory = folder.appendingPathComponent("UsagePlan")
    let file = directory.appendingPathComponent("account-state.json")
    let store = AccountSubscriptionStore(fileURL: file)
    XCTAssertTrue(try store.read().isEmpty)

    try store.setExpiry(email: "manual@example.com", expiresOn: "2026-12-01")

    let saved = try snapshot(at: file)
    let account = try XCTUnwrap((saved["accounts"] as? [[String: Any]])?.first)
    XCTAssertEqual(account["status"] as? String, "unknown")
    XCTAssertNil(account["quota"])
    XCTAssertNil(account["planName"])
    XCTAssertTrue(saved["generatedAt"] is NSNull)
    XCTAssertEqual(saved["totalCount"] as? Int, 1)
    XCTAssertEqual(try permissions(at: directory), 0o700)
    XCTAssertEqual(try permissions(at: file), 0o600)
    XCTAssertEqual(try permissions(at: directory.appendingPathComponent(".lock")), 0o600)
  }

  func testInvalidInputsAndMalformedSnapshotDoNotOverwriteData() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("account-state.json")
    let store = AccountSubscriptionStore(fileURL: file)
    try store.setExpiry(email: "first@example.com", expiresOn: "2026-11-19")
    let original = try Data(contentsOf: file)
    XCTAssertThrowsError(try store.setExpiry(email: "first@example.com", expiresOn: "2026-02-29"))
    XCTAssertThrowsError(try store.setExpiry(email: "invalid", expiresOn: "2026-11-19"))
    XCTAssertEqual(try Data(contentsOf: file), original)

    try write(["schemaVersion": true, "accounts": [[String: Any]]()], to: file)
    let wrongSchema = try Data(contentsOf: file)
    XCTAssertThrowsError(try store.setExpiry(email: "first@example.com", expiresOn: "2026-12-01"))
    XCTAssertEqual(try Data(contentsOf: file), wrongSchema)

    let corrupt = Data("{broken".utf8)
    try corrupt.write(to: file)
    XCTAssertThrowsError(try store.read())
    XCTAssertThrowsError(try store.setExpiry(email: "first@example.com", expiresOn: "2026-12-01"))
    XCTAssertEqual(try Data(contentsOf: file), corrupt)
  }

  func testUnsafeAndOversizedSnapshotsAreRejectedWithoutOverwrite() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("account-state.json")
    let store = AccountSubscriptionStore(fileURL: file)
    let target = folder.appendingPathComponent("other.json")
    let bytes = Data("{\"private\":true}".utf8)
    try bytes.write(to: target)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    XCTAssertThrowsError(try store.read())
    XCTAssertThrowsError(try store.setExpiry(email: "first@example.com", expiresOn: "2026-12-01"))
    XCTAssertEqual(try Data(contentsOf: target), bytes)
    try FileManager.default.removeItem(at: file)

    try bytes.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    XCTAssertThrowsError(try store.setExpiry(email: "first@example.com", expiresOn: "2026-12-01"))
    XCTAssertEqual(try Data(contentsOf: file), bytes)

    let oversized = Data(repeating: 32, count: AccountSubscriptionStore.maximumFileSize + 1)
    try oversized.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    XCTAssertThrowsError(try store.setExpiry(email: "first@example.com", expiresOn: "2026-12-01"))
    XCTAssertEqual(try Data(contentsOf: file), oversized)
  }

  func testConcurrentManualEditsMergeWithoutLostAccounts() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("account-state.json")
    let store = AccountSubscriptionStore(fileURL: file)
    try store.setExpiry(email: "original@example.com", expiresOn: "2026-11-19")

    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<16 {
        group.addTask {
          try store.setExpiry(email: "account-\(index)@example.com", expiresOn: "2026-12-01")
        }
      }
      try await group.waitForAll()
    }

    XCTAssertEqual(try store.read().count, 17)
    XCTAssertEqual(try snapshot(at: file)["totalCount"] as? Int, 17)
  }

  private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("subscription-store-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return url
  }

  private func write(_ value: [String: Any], to file: URL) throws {
    try JSONSerialization.data(withJSONObject: value).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }

  private func snapshot(at file: URL) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
  }

  private func permissions(at file: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
  }
}
