import Foundation
import SwitchGPTAppCore

enum AppLanguage: String, CaseIterable, Identifiable {
  case system
  case simplifiedChinese = "zh-Hans"
  case english = "en"

  static let storageKey = "SwitchGPT.appLanguage.v1"

  var id: String { rawValue }

  static var selected: AppLanguage {
    AppLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
  }

  var locale: Locale {
    switch self {
    case .system: .autoupdatingCurrent
    case .simplifiedChinese: Locale(identifier: "zh-Hans")
    case .english: Locale(identifier: "en")
    }
  }

  var resourceCode: String {
    switch self {
    case .system:
      return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-Hans" : "en"
    case .simplifiedChinese: return "zh-Hans"
    case .english: return "en"
    }
  }
}

enum L10n {
  static func string(_ key: String) -> String {
    let code = AppLanguage.selected.resourceCode
    guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
      let bundle = Bundle(path: path)
    else { return key }
    return bundle.localizedString(forKey: key, value: key, table: nil)
  }

  static func format(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: string(key), locale: AppLanguage.selected.locale, arguments: arguments)
  }

  static func date(_ value: Date, date: DateFormatter.Style, time: DateFormatter.Style) -> String {
    let formatter = DateFormatter()
    formatter.locale = AppLanguage.selected.locale
    formatter.dateStyle = date
    formatter.timeStyle = time
    return formatter.string(from: value)
  }

  static func month(_ number: Int) -> String {
    let formatter = DateFormatter()
    formatter.locale = AppLanguage.selected.locale
    return formatter.shortMonthSymbols[number - 1]
  }

  static func activityMessage(_ activity: SwitchGPTActivity) -> String {
    switch activity {
    case .ready:
      return string("Ready")
    case .refreshing:
      return string("Refreshing usage…")
    case .simulating(let name):
      return format("Simulating switch to %@…", name)
    case .switching(let name):
      return format("Switching ChatGPT to %@…", name)
    case .success(let message), .partial(let message), .failure(let message):
      return activityMessage(message)
    }
  }

  private static func activityMessage(_ message: String) -> String {
    let accountPrefixes = [
      "Added read-only account: ", "Added mock account: ", "Removed mock account: ",
      "Removed account: ", "ChatGPT switched to ",
    ]
    for prefix in accountPrefixes where message.hasPrefix(prefix) {
      if prefix == "ChatGPT switched to " {
        let suffixes = [
          ". A private metadata-only verification receipt was saved.",
          ". The local verification receipt could not be saved.",
        ]
        for suffix in suffixes where message.hasSuffix(suffix) {
          let name = String(message.dropFirst(prefix.count).dropLast(suffix.count))
          return format("ChatGPT switched to %@", name) + string(suffix)
        }
      }
      return string(prefix) + String(message.dropFirst(prefix.count))
    }

    let pattern = #"^Updated (\d+) of (\d+) accounts\. (\d+) accounts? kept previous usage\.$"#
    if let match = message.range(of: pattern, options: .regularExpression) {
      let numbers = message[match].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
      if numbers.count == 3 {
        return format("Updated %d of %d accounts. %d kept previous usage.", numbers[0], numbers[1], numbers[2])
      }
    }
    return string(message)
  }
}
