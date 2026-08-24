import Foundation

public protocol AppReleaseFetching: Sendable {
  func fetchLatestRelease() async throws -> AppUpdateInfo?
}

public enum AppReleaseFetchError: Error, Equatable {
  case invalidResponse
  case unexpectedStatus(Int)
  case responseTooLarge
  case malformedRelease
}

public struct GitHubLatestReleaseClient: AppReleaseFetching, Sendable {
  public static let endpoint = URL(
    string: "https://api.github.com/repos/HuipengXu/SwitchGPT/releases/latest"
  )!

  private let session: URLSession

  public init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 8
    configuration.timeoutIntervalForResource = 12
    session = URLSession(configuration: configuration)
  }

  init(session: URLSession) {
    self.session = session
  }

  public func fetchLatestRelease() async throws -> AppUpdateInfo? {
    var request = URLRequest(url: Self.endpoint)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("SwitchGPT-Update-Check", forHTTPHeaderField: "User-Agent")

    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw AppReleaseFetchError.invalidResponse
    }
    if response.statusCode == 404 {
      return nil
    }
    guard response.statusCode == 200 else {
      throw AppReleaseFetchError.unexpectedStatus(response.statusCode)
    }
    guard data.count <= 256 * 1024 else {
      throw AppReleaseFetchError.responseTooLarge
    }
    return try GitHubLatestReleaseDecoder.decode(data)
  }
}

enum GitHubLatestReleaseDecoder {
  static func decode(_ data: Data) throws -> AppUpdateInfo {
    let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
    guard !release.draft,
      !release.prerelease,
      let version = AppReleaseVersion(rawValue: release.tagName),
      let update = AppUpdateInfo(version: version, releaseURL: release.htmlURL)
    else {
      throw AppReleaseFetchError.malformedRelease
    }
    return update
  }

  private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool

    private enum CodingKeys: String, CodingKey {
      case tagName = "tag_name"
      case htmlURL = "html_url"
      case draft
      case prerelease
    }
  }
}
