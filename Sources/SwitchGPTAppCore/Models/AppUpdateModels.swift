import Foundation

public struct AppReleaseVersion: Comparable, Hashable, Sendable {
  public let major: Int
  public let minor: Int
  public let patch: Int

  public var displayValue: String {
    "\(major).\(minor).\(patch)"
  }

  public init?(rawValue: String) {
    let normalized = rawValue.hasPrefix("v") ? String(rawValue.dropFirst()) : rawValue
    let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 3 else { return nil }

    let values = components.compactMap { component -> Int? in
      guard !component.isEmpty,
        component.allSatisfy(\.isNumber),
        let value = Int(component),
        value >= 0
      else { return nil }
      return value
    }
    guard values.count == 3 else { return nil }

    major = values[0]
    minor = values[1]
    patch = values[2]
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }
}

public struct AppUpdateInfo: Equatable, Hashable, Sendable {
  public let version: AppReleaseVersion
  public let releaseURL: URL

  public init?(version: AppReleaseVersion, releaseURL: URL) {
    guard Self.isOfficialReleaseURL(releaseURL, version: version) else { return nil }
    self.version = version
    self.releaseURL = releaseURL
  }

  private static func isOfficialReleaseURL(
    _ url: URL,
    version: AppReleaseVersion
  ) -> Bool {
    guard url.scheme == "https",
      url.host?.lowercased() == "github.com",
      url.user == nil,
      url.password == nil,
      url.port == nil,
      url.query == nil,
      url.fragment == nil
    else { return false }

    let components = url.pathComponents.filter { $0 != "/" }
    guard components.count == 5 else { return false }
    return components[0].lowercased() == "huipengxu"
      && components[1].lowercased() == "switchgpt"
      && components[2] == "releases"
      && components[3] == "tag"
      && AppReleaseVersion(rawValue: components[4]) == version
  }
}

public enum AppUpdateCheckResult: Equatable, Sendable {
  case updateAvailable(AppUpdateInfo)
  case upToDate
  case failed
}

public struct AppUpdateCheckNotice: Identifiable, Equatable, Sendable {
  public let id = UUID()
  public let result: AppUpdateCheckResult

  init(result: AppUpdateCheckResult) {
    self.result = result
  }
}
