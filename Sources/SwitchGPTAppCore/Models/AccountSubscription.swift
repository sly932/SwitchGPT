import Foundation

/// A subscription date supplied by the user, independent of a quota refresh.
/// `expiresOn` deliberately has day precision because a subscription screenshot may omit its time.
public struct AccountSubscription: Encodable, Equatable, Sendable {
  public let expiresOn: String
  public let source: String
  public let updatedAt: String

  public init(expiresOn: String, source: String, updatedAt: String) throws {
    guard Self.isValidDate(expiresOn), source == "manual", Self.isValidTimestamp(updatedAt) else {
      throw AccountSubscriptionStoreError.invalidSubscription
    }
    self.expiresOn = expiresOn
    self.source = source
    self.updatedAt = updatedAt
  }

  public static func isValidDate(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
      bytes.enumerated().allSatisfy({ index, byte in
        index == 4 || index == 7 || (48...57).contains(byte)
      }),
      let year = Int(value.prefix(4)), year > 0,
      let month = Int(value.dropFirst(5).prefix(2)),
      let day = Int(value.suffix(2))
    else { return false }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = DateComponents(year: year, month: month, day: day)
    guard let date = calendar.date(from: components) else { return false }
    let actual = calendar.dateComponents([.year, .month, .day], from: date)
    return actual.year == year && actual.month == month && actual.day == day
  }

  private static func isValidTimestamp(_ value: String) -> Bool {
    let formatter = ISO8601DateFormatter()
    if formatter.date(from: value) != nil { return true }
    formatter.formatOptions.insert(.withFractionalSeconds)
    return formatter.date(from: value) != nil
  }
}
