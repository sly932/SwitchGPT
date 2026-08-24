import Foundation
import Observation

@MainActor
@Observable
public final class AppUpdateStore {
  public static let automaticCheckInterval: TimeInterval = 24 * 60 * 60
  public static let snoozeInterval: TimeInterval = 7 * 24 * 60 * 60

  public private(set) var availableUpdate: AppUpdateInfo?
  public private(set) var isChecking = false

  private let releaseFetcher: any AppReleaseFetching
  private let currentVersion: AppReleaseVersion
  private let userDefaults: UserDefaults
  private let now: () -> Date

  private let lastCheckedAtKey = "appUpdate.lastCheckedAt"
  private let cachedVersionKey = "appUpdate.cachedVersion"
  private let cachedReleaseURLKey = "appUpdate.cachedReleaseURL"
  private let snoozedVersionKey = "appUpdate.snoozedVersion"
  private let snoozedUntilKey = "appUpdate.snoozedUntil"

  public init(
    releaseFetcher: any AppReleaseFetching = GitHubLatestReleaseClient(),
    currentVersion: AppReleaseVersion? = nil,
    userDefaults: UserDefaults = .standard,
    now: @escaping () -> Date = Date.init
  ) {
    self.releaseFetcher = releaseFetcher
    self.currentVersion = currentVersion ?? Self.bundleVersion()
    self.userDefaults = userDefaults
    self.now = now
    availableUpdate = nil
    availableUpdate = visibleUpdate(from: cachedRelease(), at: now())
  }

  public func checkIfStale(
    maxAge: TimeInterval = AppUpdateStore.automaticCheckInterval
  ) async {
    let currentDate = now()
    if let lastCheckedAt = userDefaults.object(forKey: lastCheckedAtKey) as? Date {
      let age = currentDate.timeIntervalSince(lastCheckedAt)
      if age >= 0, age < maxAge {
        return
      }
    }
    await checkNow()
  }

  public func checkNow() async {
    guard !isChecking else { return }
    isChecking = true
    defer { isChecking = false }

    do {
      let release = try await releaseFetcher.fetchLatestRelease()
      let currentDate = now()
      userDefaults.set(currentDate, forKey: lastCheckedAtKey)
      cache(release)
      availableUpdate = visibleUpdate(from: release, at: currentDate)
    } catch {
      // Automatic update checks are intentionally silent. A temporary network
      // or GitHub failure must not interfere with account or quota workflows.
    }
  }

  public func snoozeAvailableUpdate() {
    guard let availableUpdate else { return }
    userDefaults.set(availableUpdate.version.displayValue, forKey: snoozedVersionKey)
    userDefaults.set(
      now().addingTimeInterval(Self.snoozeInterval),
      forKey: snoozedUntilKey
    )
    self.availableUpdate = nil
  }

  private func visibleUpdate(from release: AppUpdateInfo?, at date: Date) -> AppUpdateInfo? {
    guard let release, release.version > currentVersion else { return nil }

    let snoozedVersion = userDefaults.string(forKey: snoozedVersionKey)
    let snoozedUntil = userDefaults.object(forKey: snoozedUntilKey) as? Date
    if snoozedVersion == release.version.displayValue,
      let snoozedUntil,
      snoozedUntil > date
    {
      return nil
    }

    let snoozeHasExpired = snoozedUntil.map { $0 <= date } ?? true
    if snoozedVersion != release.version.displayValue || snoozeHasExpired {
      userDefaults.removeObject(forKey: snoozedVersionKey)
      userDefaults.removeObject(forKey: snoozedUntilKey)
    }
    return release
  }

  private func cache(_ release: AppUpdateInfo?) {
    guard let release else {
      userDefaults.removeObject(forKey: cachedVersionKey)
      userDefaults.removeObject(forKey: cachedReleaseURLKey)
      return
    }
    userDefaults.set(release.version.displayValue, forKey: cachedVersionKey)
    userDefaults.set(release.releaseURL.absoluteString, forKey: cachedReleaseURLKey)
  }

  private func cachedRelease() -> AppUpdateInfo? {
    guard let rawVersion = userDefaults.string(forKey: cachedVersionKey),
      let version = AppReleaseVersion(rawValue: rawVersion),
      let rawURL = userDefaults.string(forKey: cachedReleaseURLKey),
      let releaseURL = URL(string: rawURL)
    else { return nil }
    return AppUpdateInfo(version: version, releaseURL: releaseURL)
  }

  private static func bundleVersion() -> AppReleaseVersion {
    let rawValue = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    return rawValue.flatMap(AppReleaseVersion.init(rawValue:))
      ?? AppReleaseVersion(rawValue: "0.0.0")!
  }
}
