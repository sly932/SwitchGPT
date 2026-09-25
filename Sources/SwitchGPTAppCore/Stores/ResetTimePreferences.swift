import Foundation
import Observation

public enum ResetTimeFormat: String, CaseIterable, Identifiable, Sendable {
  case chinese
  case english
  case compact

  public var id: String { rawValue }

  public func text(for date: Date, timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone

    switch self {
    case .chinese:
      formatter.locale = Locale(identifier: "zh_CN")
      formatter.dateFormat = "yyyy年M月d日HH:mm"
      return "重置时间：" + formatter.string(from: date)
    case .english:
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "yyyy MMM d HH:mm"
      return "Reset at " + formatter.string(from: date)
    case .compact:
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "yyyy MMdd HH:mm"
      return formatter.string(from: date)
    }
  }
}

@MainActor
@Observable
public final class ResetTimePreferences {
  public private(set) var format: ResetTimeFormat

  @ObservationIgnored private let userDefaults: UserDefaults
  @ObservationIgnored private let storageKey: String

  public init(
    userDefaults: UserDefaults = .standard,
    storageKey: String = "SwitchGPT.resetTimeFormat.v1"
  ) {
    self.userDefaults = userDefaults
    self.storageKey = storageKey
    format = userDefaults.string(forKey: storageKey)
      .flatMap(ResetTimeFormat.init(rawValue:)) ?? .chinese
  }

  public func setFormat(_ format: ResetTimeFormat) {
    self.format = format
    userDefaults.set(format.rawValue, forKey: storageKey)
  }
}
