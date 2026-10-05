import XCTest

@testable import SwitchGPTAppCore

final class BundledCodexExecutableTests: XCTestCase {
  func testPrefersPackagedEntrypointWhenBothLayoutsExist() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let legacy = try installExecutable("codex", in: fixture.application)
    let packaged = try installExecutable("codex-cli/bin/codex", in: fixture.application)

    XCTAssertEqual(BundledCodexExecutable.resolve(in: fixture.application), packaged)
    XCTAssertNotEqual(packaged, legacy)
  }

  func testSupportsLegacyLayout() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let legacy = try installExecutable("codex", in: fixture.application)

    XCTAssertEqual(BundledCodexExecutable.resolve(in: fixture.application), legacy)
  }

  func testUsesNestedBinaryWhenPackagedEntrypointIsMissing() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let nested = try installExecutable(
      "codex-cli/CodexCLI.app/Contents/MacOS/codex",
      in: fixture.application
    )

    XCTAssertEqual(BundledCodexExecutable.resolve(in: fixture.application), nested)
  }

  func testSkipsNonExecutableEntrypoint() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let packaged = try installExecutable("codex-cli/bin/codex", in: fixture.application)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: packaged.path)
    let legacy = try installExecutable("codex", in: fixture.application)

    XCTAssertEqual(BundledCodexExecutable.resolve(in: fixture.application), legacy)
  }

  func testExistingClientsResolveNewLayoutAfterDesktopUpdate() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let legacy = try installExecutable("codex", in: fixture.application)
    let onboarder = CodexManagedAccountOnboarder(desktopApplicationURL: fixture.application)
    let reader = CodexAppServerQuotaReader(desktopApplicationURL: fixture.application)
    XCTAssertEqual(onboarder.codexBinaryURL, legacy)
    XCTAssertEqual(reader.codexBinaryURL, legacy)

    try FileManager.default.removeItem(at: legacy)
    let packaged = try installExecutable("codex-cli/bin/codex", in: fixture.application)

    XCTAssertEqual(onboarder.codexBinaryURL, packaged)
    XCTAssertEqual(reader.codexBinaryURL, packaged)
  }

  func testExplicitBinaryOverrideIsPreserved() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try installExecutable("codex-cli/bin/codex", in: fixture.application)
    let override = fixture.root.appendingPathComponent("explicit-binary")

    XCTAssertEqual(
      CodexManagedAccountOnboarder(
        codexBinaryURL: override,
        desktopApplicationURL: fixture.application
      ).codexBinaryURL,
      override
    )
    XCTAssertEqual(
      CodexAppServerQuotaReader(
        codexBinaryURL: override,
        desktopApplicationURL: fixture.application
      ).codexBinaryURL,
      override
    )
  }

  func testMissingComponentFailsBeforeCreatingAccountStorage() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let accounts = fixture.root.appendingPathComponent("Accounts", isDirectory: true)
    let onboarder = CodexManagedAccountOnboarder(
      accountsRootURL: accounts,
      desktopApplicationURL: fixture.application
    )

    do {
      _ = try await onboarder.signIn()
      XCTFail("Missing component must not start a login")
    } catch {
      XCTAssertEqual(error as? ManagedAccountOnboardingError, .missingCodexBinary)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: accounts.path))
  }

  func testPackagedEntrypointSupportsIsolatedLoginAndQuotaProbe() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try installExecutable("codex-cli/bin/codex", in: fixture.application)
    let accounts = fixture.root.appendingPathComponent("Accounts", isDirectory: true)
    let onboarder = CodexManagedAccountOnboarder(
      timeout: 2,
      accountsRootURL: accounts,
      desktopApplicationURL: fixture.application
    )

    let home = URL(fileURLWithPath: try await onboarder.signIn(), isDirectory: true)
    XCTAssertEqual(home.deletingLastPathComponent(), accounts)
    XCTAssertEqual(
      try String(contentsOf: home.appendingPathComponent("login-invoked"), encoding: .utf8), "login"
    )
    let homeAttributes = try FileManager.default.attributesOfItem(atPath: home.path)
    XCTAssertEqual((homeAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    let authURL = home.appendingPathComponent("auth.json")
    try Data("{}".utf8).write(to: authURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)

    let probe = try await CodexAppServerQuotaReader(
      timeout: .seconds(2),
      desktopApplicationURL: fixture.application
    ).probe(codexHomePath: home.path)

    XCTAssertEqual(probe.planName, "Plus")
    XCTAssertEqual(probe.usage.fiveHour?.usedPercent, 12)
    XCTAssertEqual(probe.usage.weekly.usedPercent, 34)
    XCTAssertEqual(try Data(contentsOf: authURL), Data("{}".utf8))
  }

  private func makeFixture() throws -> (root: URL, application: URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("switchgpt-bundled-codex-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    return (root, root.appendingPathComponent("ChatGPT.app", isDirectory: true))
  }

  private func installExecutable(_ relativePath: String, in application: URL) throws -> URL {
    let binary = application.appendingPathComponent("Contents/Resources/" + relativePath)
    try FileManager.default.createDirectory(
      at: binary.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let script = #"""
      #!/bin/bash
      if [[ "$1" == login ]]; then
        [[ -n "$CODEX_HOME" ]] || exit 1
        printf 'login' > "$CODEX_HOME/login-invoked"
        exit 0
      fi
      [[ "$1" == app-server && "$2" == --stdio ]] || exit 1
      request_count=0
      while IFS= read -r line; do
        [[ "$line" == *'"id":'* ]] || continue
        request_count=$((request_count + 1))
        request_id="$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')"
        case "$request_count" in
          1) printf '{"id":%s,"result":{}}\n' "$request_id" ;;
          2) printf '{"id":%s,"result":{"account":{"email":"fixture@example.com","planType":"plus"}}}\n' "$request_id" ;;
          3) printf '{"id":%s,"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1900000000},"secondary":{"usedPercent":34,"windowDurationMins":10080,"resetsAt":1900500000}}}}\n' "$request_id" ;;
        esac
      done
      """#
    try Data(script.utf8).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    return binary
  }
}
