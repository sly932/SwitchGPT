import Foundation
import SwitchGPTDesktopIntegration

public struct CodexAppServerQuotaReader: QuotaReading, ReadOnlyAccountProbing, Sendable {
  public var codexBinaryURL: URL {
    configuredCodexBinaryURL ?? BundledCodexExecutable.resolve(in: desktopApplicationURL)
  }
  public let includeTokenActivity: Bool
  public let timeout: Duration
  private let configuredCodexBinaryURL: URL?
  private let desktopApplicationURL: URL

  public init(
    codexBinaryURL: URL? = nil,
    timeout: Duration = .seconds(60),
    includeTokenActivity: Bool = true,
    desktopApplicationURL: URL = BundledCodexExecutable.defaultApplicationURL
  ) {
    self.configuredCodexBinaryURL = codexBinaryURL?.standardizedFileURL
    self.desktopApplicationURL = desktopApplicationURL.standardizedFileURL
    self.includeTokenActivity = includeTokenActivity
    self.timeout = timeout
  }

  public func fetchSnapshots(for accounts: [AccountRecord]) async throws
    -> [AccountID: AccountQuotaSnapshot]
  {
    let realAccounts = accounts.compactMap { account -> (AccountID, String)? in
      guard case .codexHome(let path) = account.source else { return nil }
      return (account.id, path)
    }

    guard !realAccounts.isEmpty else {
      return [:]
    }

    let codexBinaryURL = self.codexBinaryURL
    let batchResult = await withTaskGroup(
      of: (AccountID, Result<AccountQuotaSnapshot, QuotaReadingError>).self,
      returning: Result<[AccountID: AccountQuotaSnapshot], QuotaReadingError>.self
    ) { group in
      // Each account starts its own app-server and several network reads. Bound the
      // fan-out so adding accounts does not overwhelm the local server or service.
      var pendingAccounts = realAccounts.makeIterator()
      func enqueue(_ accountID: AccountID, _ path: String) {
        group.addTask {
          do {
            let snapshot = try await Self.readSnapshot(
              from: path,
              binaryURL: codexBinaryURL,
              timeout: timeout,
              includeTokenActivity: includeTokenActivity
            )
            guard let account = accounts.first(where: { $0.id == accountID }),
              let expectedIdentityHash = account.identityHash
            else {
              return (accountID, .failure(.identityNotPinned))
            }
            guard snapshot.identityHash == expectedIdentityHash else {
              return (accountID, .failure(.identityMismatch))
            }
            return (
              accountID,
              .success(
                AccountQuotaSnapshot(
                  email: snapshot.email,
                  planName: snapshot.planName,
                  usage: snapshot.usage
                )
              )
            )
          } catch let error as QuotaReadingError {
            return (accountID, .failure(error))
          } catch {
            return (accountID, .failure(.invalidProtocolResponse))
          }
        }
      }

      for _ in 0..<min(4, realAccounts.count) {
        if let (accountID, path) = pendingAccounts.next() {
          enqueue(accountID, path)
        }
      }

      var result: [AccountID: AccountQuotaSnapshot] = [:]
      var firstFailure: QuotaReadingError?
      for await (accountID, attempt) in group {
        switch attempt {
        case .success(let snapshot):
          result[accountID] = snapshot
        case .failure(let error):
          if firstFailure == nil {
            firstFailure = error
          }
        }
        if let (nextAccountID, path) = pendingAccounts.next() {
          enqueue(nextAccountID, path)
        }
      }
      if result.isEmpty, let firstFailure {
        return .failure(firstFailure)
      }
      return .success(result)
    }
    return try batchResult.get()
  }

  public func probe(codexHomePath: String) async throws -> ReadOnlyAccountProbe {
    let snapshot = try await Self.readSnapshot(
      from: codexHomePath,
      binaryURL: codexBinaryURL,
      timeout: timeout,
      includeTokenActivity: includeTokenActivity
    )
    return snapshot.probe
  }

  public func probeActiveProfile(authenticationFileURL: URL) async throws -> ReadOnlyAccountProbe {
    let authentication = try ReadOnlyAccountAuthentication(authenticationFileURL: authenticationFileURL)
    return try await Self.readOnlySnapshot(
      authentication: authentication, binaryURL: codexBinaryURL, timeout: timeout,
      includeTokenActivity: includeTokenActivity
    ).probe
  }

  /// The caller owns the account lock and has verified that this is the inactive
  /// managed profile. Codex may renew directly into its authoritative auth.json.
  func probeManagedProfile(codexHomePath: String) async throws -> ReadOnlyAccountProbe {
    let profileURL = URL(fileURLWithPath: codexHomePath).standardizedFileURL
    let entries = try FileManager.default.contentsOfDirectory(atPath: profileURL.path)
    guard !entries.contains("config.toml"), !entries.contains(".codex") else {
      throw QuotaReadingError.invalidHomePath
    }
    let client = CodexAppServerClient(
      binaryURL: codexBinaryURL, codexHome: profileURL, timeout: timeout,
      includeTokenActivity: includeTokenActivity, access: .managed
    )
    return try await Task.detached(priority: .utility) { try client.readSnapshot().probe }.value
  }

  private static func readSnapshot(
    from path: String, binaryURL: URL, timeout: Duration, includeTokenActivity: Bool
  )
    async throws -> ReadOnlyQuotaSnapshot
  {
    let home = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    let activeHome = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex", isDirectory: true).standardizedFileURL
    let authentication = try home == activeHome
      ? ReadOnlyAccountAuthentication(authenticationFileURL: home.appendingPathComponent("auth.json"))
      : ReadOnlyAccountAuthentication(sourcePath: path)
    return try await readOnlySnapshot(
      authentication: authentication, binaryURL: binaryURL, timeout: timeout,
      includeTokenActivity: includeTokenActivity
    )
  }

  private static func readOnlySnapshot(
    authentication: ReadOnlyAccountAuthentication, binaryURL: URL, timeout: Duration,
    includeTokenActivity: Bool
  ) async throws -> ReadOnlyQuotaSnapshot {
    let fileManager = FileManager.default
    let stagedHome = fileManager.temporaryDirectory
      .appendingPathComponent("switchgpt-readonly-" + UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(
      at: stagedHome,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? fileManager.removeItem(at: stagedHome) }

    return try await Task.detached(priority: .utility) {
      let client = CodexAppServerClient(
        binaryURL: binaryURL,
        codexHome: stagedHome,
        timeout: timeout,
        includeTokenActivity: includeTokenActivity,
        access: .readOnly(authentication)
      )
      return try client.readSnapshot()
    }.value
  }
}

private struct ReadOnlyQuotaSnapshot: Sendable {
  let identityHash: String
  let email: String
  let planName: String
  let usage: AccountUsage

  var probe: ReadOnlyAccountProbe {
    ReadOnlyAccountProbe(identityHash: identityHash, email: email, planName: planName, usage: usage)
  }
}

public struct MixedQuotaReader: QuotaReading, Sendable {
  private let mockReader: MockQuotaReader
  private let codexReader: CodexAppServerQuotaReader

  public init(codexReader: CodexAppServerQuotaReader = CodexAppServerQuotaReader()) {
    self.mockReader = MockQuotaReader()
    self.codexReader = codexReader
  }

  public func fetchSnapshots(for accounts: [AccountRecord]) async throws
    -> [AccountID: AccountQuotaSnapshot]
  {
    let mockAccounts = accounts.filter {
      if case .mock = $0.source { return true }
      return false
    }
    let realAccounts = accounts.filter {
      if case .codexHome = $0.source { return true }
      return false
    }

    var result = try await mockReader.fetchSnapshots(for: mockAccounts)
    if !realAccounts.isEmpty {
      result.merge(try await codexReader.fetchSnapshots(for: realAccounts)) { _, latest in latest }
    }
    return result
  }
}

private struct ReadOnlyAccountAuthentication: Sendable {
  let accessToken: String
  let accountID: String
  let email: String
  let planType: String?
  let hasMatchingUserClaims: Bool

  init(sourcePath: String) throws {
    let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
    let fileManager = FileManager.default
    let sourceValues = try sourceURL.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard sourceValues.isSymbolicLink != true else {
      throw QuotaReadingError.invalidHomePath
    }
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw QuotaReadingError.invalidHomePath
    }

    let homeAttributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
    let homePermissions = (homeAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    guard homePermissions & 0o077 == 0 else {
      throw QuotaReadingError.insecureHomePermissions
    }

    try self.init(authenticationFileURL: sourceURL.appendingPathComponent("auth.json"))
  }

  init(authenticationFileURL authURL: URL) throws {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: authURL.path) else {
      throw QuotaReadingError.missingAuthenticationFile
    }
    let data: Data
    do {
      data = try SecureAuthenticationFileInstaller.readPrivateAuthenticationFile(at: authURL)
    } catch DesktopIntegrationError.insecureAuthenticationFile {
      throw QuotaReadingError.insecureHomePermissions
    } catch {
      throw QuotaReadingError.invalidAuthenticationFile
    }
    let credentials = try CodexCredentialClaims(authenticationData: data)
    guard let idClaims = credentials.idClaims,
      let email = idClaims["email"] as? String, !email.isEmpty,
      let accessToken = credentials.tokens["access_token"] as? String,
      let accessClaims = credentials.accessClaims
    else {
      throw QuotaReadingError.invalidAuthenticationFile
    }
    let idAuth = idClaims["https://api.openai.com/auth"] as? [String: Any]
    let accessAuth = accessClaims["https://api.openai.com/auth"] as? [String: Any]
    guard let accountID = credentials.accountID,
      !accountID.isEmpty, accountID.trimmingCharacters(in: .whitespacesAndNewlines) == accountID
    else {
      throw QuotaReadingError.invalidAuthenticationFile
    }
    if let accessAccount = accessAuth?["chatgpt_account_id"] as? String,
      accessAccount != accountID
    {
      throw QuotaReadingError.identityMismatch
    }
    let idUser = (idAuth?["chatgpt_user_id"] as? String) ?? (idAuth?["user_id"] as? String)
    let accessUser = (accessAuth?["chatgpt_user_id"] as? String) ?? (accessAuth?["user_id"] as? String)
    let idSubject = idClaims["sub"] as? String
    let accessSubject = accessClaims["sub"] as? String
    if let idUser, let accessUser, idUser != accessUser {
      throw QuotaReadingError.identityMismatch
    }
    self.accessToken = accessToken
    self.accountID = accountID
    self.email = email
    let accessPlanType = accessAuth?["chatgpt_plan_type"] as? String
    let idPlanType = idAuth?["chatgpt_plan_type"] as? String
    // The ID token may still refer to the previous workspace after a workspace switch.
    self.planType = (idAuth?["chatgpt_account_id"] as? String) == accountID
      ? idPlanType ?? accessPlanType
      : accessPlanType ?? idPlanType
    hasMatchingUserClaims = (idUser?.isEmpty == false && idUser == accessUser)
      || (idSubject?.isEmpty == false && idSubject == accessSubject)
  }

  func accountMetadata(from data: Data) throws -> CodexAccountMetadata {
    guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      var account = response["account"] as? [String: Any],
      account["type"] as? String == "chatgpt"
    else {
      throw QuotaReadingError.invalidProtocolResponse
    }
    if let routing = response["workspaceRouting"] as? [String: Any],
      let routedAccount = routing["chatgptAccountId"] as? String, routedAccount != accountID
    {
      throw QuotaReadingError.identityMismatch
    }
    if let returnedEmail = account["email"] as? String, !returnedEmail.isEmpty {
      guard returnedEmail.caseInsensitiveCompare(email) == .orderedSame else {
        throw QuotaReadingError.identityMismatch
      }
    } else {
      // An externally supplied access token may omit email. In this case the
      // two tokens from the original private file must identify the same user.
      guard hasMatchingUserClaims else { throw QuotaReadingError.identityMismatch }
    }
    account["email"] = email
    return try CodexAccountDecoder.decode(from: JSONSerialization.data(withJSONObject: account))
  }

}

struct CodexCredentialClaims {
  let tokens: [String: Any]
  let mode: String?
  let idClaims: [String: Any]?
  let accessClaims: [String: Any]?
  let accountID: String?
  let userID: String?

  init(authenticationData: Data) throws {
    guard let document = try? JSONSerialization.jsonObject(with: authenticationData) as? [String: Any],
      let tokens = document["tokens"] as? [String: Any]
    else { throw QuotaReadingError.invalidAuthenticationFile }
    idClaims = Self.jwtClaims(from: tokens["id_token"] as? String)
    accessClaims = Self.jwtClaims(from: tokens["access_token"] as? String)
    let idAuth = idClaims?["https://api.openai.com/auth"] as? [String: Any]
    let accessAuth = accessClaims?["https://api.openai.com/auth"] as? [String: Any]
    self.tokens = tokens
    mode = document["auth_mode"] as? String
    accountID = (tokens["account_id"] as? String)
      ?? (accessAuth?["chatgpt_account_id"] as? String)
      ?? (idAuth?["chatgpt_account_id"] as? String)
    userID = (accessAuth?["chatgpt_user_id"] as? String)
      ?? (accessAuth?["user_id"] as? String)
      ?? (accessClaims?["sub"] as? String)
  }

  static func jwtClaims(from jwt: String?) -> [String: Any]? {
    guard let jwt else { return nil }
    let segments = jwt.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count == 3 else { return nil }
    var payload = segments[1].replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let data = Data(base64Encoded: payload) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }
}

private struct CodexAppServerClient: Sendable {
  enum Access: Sendable {
    case readOnly(ReadOnlyAccountAuthentication)
    case managed

    var storageMode: String {
      switch self {
      case .readOnly: "ephemeral"
      case .managed: "file"
      }
    }

    var experimentalAPI: Bool {
      if case .readOnly = self { return true }
      return false
    }
  }

  let binaryURL: URL
  let codexHome: URL
  let timeout: Duration
  let includeTokenActivity: Bool
  let access: Access

  func readSnapshot() throws -> ReadOnlyQuotaSnapshot {
    guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
      throw QuotaReadingError.missingCodexBinary
    }

    let process = Process()
    process.executableURL = binaryURL
    process.currentDirectoryURL = codexHome
    process.arguments = [
      "-c", "cli_auth_credentials_store=\"\(access.storageMode)\"",
      "-c", "project_root_markers=[]", "app-server", "--stdio",
    ]

    var environment = ProcessInfo.processInfo.environment.filter {
      !$0.key.hasPrefix("CODEX_TOKEN_")
    }
    environment["CODEX_HOME"] = codexHome.path
    for key in [
      "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN",
      "CODEX_REFRESH_TOKEN_URL_OVERRIDE", "CODEX_REVOKE_TOKEN_URL_OVERRIDE",
      "CODEX_APP_SERVER_LOGIN_CLIENT_ID", "CODEX_APP_SERVER_LOGIN_ISSUER", "RUST_LOG",
    ] {
      environment.removeValue(forKey: key)
    }
    process.environment = environment

    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      throw QuotaReadingError.processLaunchFailed
    }

    let deadline = ContinuousClock.now.advanced(by: timeout)
    let timeoutItem = DispatchWorkItem {
      if process.isRunning {
        process.terminate()
      }
    }
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + timeout.timeInterval,
      execute: timeoutItem
    )

    defer {
      timeoutItem.cancel()
      if process.isRunning {
        process.terminate()
      }
      process.waitUntilExit()
    }

    var nextID = 1
    _ = try request(
      method: "initialize",
      params: [
        "clientInfo": [
          "name": "switchgpt-read-only",
          "title": "SwitchGPT read-only quota reader",
          "version": "0.1.0",
        ],
        "capabilities": ["experimentalApi": access.experimentalAPI],
      ],
      input: input,
      output: output,
      nextID: &nextID
    )
    try sendNotification(method: "initialized", input: input)
    if case .readOnly(let authentication) = access {
      var params: [String: Any] = [
        "type": "chatgptAuthTokens",
        "accessToken": authentication.accessToken,
        "chatgptAccountId": authentication.accountID,
      ]
      if let planType = authentication.planType { params["chatgptPlanType"] = planType }
      let loginData = try request(
        method: "account/login/start", params: params, input: input, output: output,
        nextID: &nextID
      )
      guard let login = try? JSONSerialization.jsonObject(with: loginData) as? [String: Any],
        login["type"] as? String == "chatgptAuthTokens"
      else {
        throw QuotaReadingError.invalidProtocolResponse
      }
    }
    let accountData = try request(
      method: "account/read",
      params: ["refreshToken": false],
      input: input,
      output: output,
      nextID: &nextID
    )
    let accountMetadata: CodexAccountMetadata
    switch access {
    case .readOnly(let authentication):
      accountMetadata = try authentication.accountMetadata(from: accountData)
    case .managed:
      accountMetadata = try CodexAccountDecoder.decode(from: accountData)
    }
    let rateLimitsData = try request(
      method: "account/rateLimits/read",
      params: NSNull(),
      input: input,
      output: output,
      nextID: &nextID
    )
    var quotaUsage = try CodexRateLimitDecoder.decodeUsage(from: rateLimitsData)
    var planName = try CodexRateLimitDecoder.decodePlanName(
      from: rateLimitsData, fallback: accountMetadata.planName
    )
    // Token activity is optional on older app-server builds and can be unavailable
    // independently of rate limits. Keep the valid quota snapshot in that case.
    let tokenActivity: AccountTokenActivity?
    if includeTokenActivity {
      tokenActivity = readTokenActivity(
        input: input, output: output, nextID: &nextID, deadline: deadline)
    } else {
      tokenActivity = nil
    }

    // A count-only response means the separate detail lookup did not return rows.
    // Retry it once after token activity, within the original account deadline.
    // Never replace a valid snapshot with an error or reuse saved expiration data.
    if let resetCredits = quotaUsage.resetCredits,
      resetCredits.availableCount > 0, resetCredits.credits == nil,
      ContinuousClock.now < deadline,
      let retriedData = try? request(
        method: "account/rateLimits/read", params: NSNull(),
        input: input, output: output, nextID: &nextID),
      let retriedUsage = try? CodexRateLimitDecoder.decodeUsage(from: retriedData),
      retriedUsage.resetCredits != nil
    {
      quotaUsage = retriedUsage
      planName = (try? CodexRateLimitDecoder.decodePlanName(
        from: retriedData, fallback: planName)) ?? planName
    }
    return ReadOnlyQuotaSnapshot(
      identityHash: accountMetadata.identityHash,
      email: accountMetadata.email,
      planName: planName,
      usage: tokenActivity.map { quotaUsage.withTokenActivity($0) } ?? quotaUsage
    )
  }

  private func readTokenActivity(
    input: Pipe, output: Pipe, nextID: inout Int, deadline: ContinuousClock.Instant
  ) -> AccountTokenActivity? {
    for attempt in 0..<2 {
      do {
        return try CodexTokenActivityDecoder.decode(from: request(
          method: "account/usage/read", params: NSNull(),
          input: input, output: output, nextID: &nextID))
      } catch let error as AppServerResponseError
        where attempt == 0 && error.isRetryable && ContinuousClock.now < deadline
      {
        continue
      } catch {
        // Do not log upstream messages, which can contain account or credential data.
        NSLog("[SwitchGPT/quota] token activity unavailable")
        return nil
      }
    }
    return nil
  }

  private func sendNotification(method: String, input: Pipe) throws {
    let encoded = try JSONSerialization.data(withJSONObject: ["method": method])
    input.fileHandleForWriting.write(encoded)
    input.fileHandleForWriting.write(Data([0x0A]))
  }

  private func request(
    method: String,
    params: Any,
    input: Pipe,
    output: Pipe,
    nextID: inout Int
  ) throws -> Data {
    let requestID = nextID
    nextID += 1
    let message: [String: Any] = ["id": requestID, "method": method, "params": params]
    let encoded = try JSONSerialization.data(withJSONObject: message)
    input.fileHandleForWriting.write(encoded)
    input.fileHandleForWriting.write(Data([0x0A]))

    var buffer = Data()
    while true {
      // `readData(ofLength:)` can wait for the full requested byte count on a pipe. App-server
      // responses are normally much smaller, so that behavior deadlocks until our timeout kills
      // the child. `availableData` returns as soon as a response chunk is available.
      let chunk = output.fileHandleForReading.availableData
      if chunk.isEmpty {
        throw QuotaReadingError.timedOut
      }
      buffer.append(chunk)

      while let newline = buffer.firstIndex(of: 0x0A) {
        let line = buffer.prefix(upTo: newline)
        buffer.removeSubrange(...newline)
        guard !line.isEmpty else { continue }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
          let response = object as? [String: Any],
          let responseID = response["id"] as? NSNumber,
          responseID.intValue == requestID
        else {
          continue
        }

        if let error = response["error"] as? [String: Any] {
          let code = (error["code"] as? NSNumber)?.intValue
          let message = error["message"] as? String
          let authenticationRejected = message?.contains(" failed: 401 Unauthorized;") == true
            || message == "codex account authentication required to read rate limits"
            || message == "codex account authentication required to read token usage"
          throw AppServerResponseError(code: code, authenticationRejected: authenticationRejected)
        }
        guard let result = response["result"] else {
          throw QuotaReadingError.invalidProtocolResponse
        }
        return try JSONSerialization.data(withJSONObject: result)
      }
    }
  }
}

private struct AppServerResponseError: Error {
  let code: Int?
  let authenticationRejected: Bool

  var isRetryable: Bool {
    // Authentication, invalid parameters and unsupported methods require action
    // outside this read. Only retry potentially transient server failures.
    !authenticationRejected && ![-32600, -32601, -32602].contains(code ?? 0)
  }
}

extension Duration {
  fileprivate var timeInterval: TimeInterval {
    let components = self.components
    return TimeInterval(components.seconds) + TimeInterval(components.attoseconds)
      / 1_000_000_000_000_000_000
  }
}
