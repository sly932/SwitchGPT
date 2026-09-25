import Foundation
import Observation

public enum AccountListSurface: String, Codable, CaseIterable, Sendable {
  case menu
  case sidebar
}

public enum AccountListDensity: String, Codable, CaseIterable, Sendable {
  case compact
  case detailed
}

public enum AccountDisplayField: String, Codable, CaseIterable, Identifiable, Sendable {
  case plan
  case weeklyRemaining
  case lastUpdated
  case fiveHourRemaining
  case credits
  case weeklyReset

  public var id: String { rawValue }
}

public struct AccountListSettings: Codable, Equatable, Sendable {
  public var fieldOrder: [AccountDisplayField]
  public var visibleFields: [AccountDisplayField]
  public var accountOrder: [AccountID]
  public var density: AccountListDensity

  public static let standard = AccountListSettings(
    fieldOrder: AccountDisplayField.allCases,
    visibleFields: [.plan, .weeklyRemaining, .lastUpdated],
    accountOrder: [],
    density: .detailed
  )

  public init(
    fieldOrder: [AccountDisplayField],
    visibleFields: [AccountDisplayField],
    accountOrder: [AccountID],
    density: AccountListDensity
  ) {
    self.fieldOrder = fieldOrder
    self.visibleFields = visibleFields
    self.accountOrder = accountOrder
    self.density = density
  }

  public var orderedVisibleFields: [AccountDisplayField] {
    fieldOrder.filter { visibleFields.contains($0) }
  }

  public func orderedAccounts(_ accounts: [AccountRecord]) -> [AccountRecord] {
    var positions: [AccountID: Int] = [:]
    for (index, id) in accountOrder.enumerated() where positions[id] == nil {
      positions[id] = index
    }
    return accounts.enumerated().sorted { lhs, rhs in
      let left = positions[lhs.element.id] ?? accountOrder.count + lhs.offset
      let right = positions[rhs.element.id] ?? accountOrder.count + rhs.offset
      return left < right
    }.map(\.element)
  }

  fileprivate func normalized() -> AccountListSettings {
    var result = self
    var seen = Set<AccountDisplayField>()
    result.fieldOrder = fieldOrder.filter { seen.insert($0).inserted }
    result.fieldOrder += AccountDisplayField.allCases.filter { seen.insert($0).inserted }
    result.visibleFields = Array(Set(visibleFields)).sorted {
      (result.fieldOrder.firstIndex(of: $0) ?? 0) < (result.fieldOrder.firstIndex(of: $1) ?? 0)
    }
    var seenAccounts = Set<AccountID>()
    result.accountOrder = accountOrder.filter { seenAccounts.insert($0).inserted }
    return result
  }
}

private struct StoredListPreferences: Codable {
  var menu: AccountListSettings
  var sidebar: AccountListSettings
}

@MainActor
@Observable
public final class AccountListPreferences {
  public private(set) var menu: AccountListSettings
  public private(set) var sidebar: AccountListSettings

  @ObservationIgnored private let userDefaults: UserDefaults
  @ObservationIgnored private let storageKey: String

  public init(
    userDefaults: UserDefaults = .standard,
    storageKey: String = "SwitchGPT.accountListPreferences.v1"
  ) {
    self.userDefaults = userDefaults
    self.storageKey = storageKey
    if let data = userDefaults.data(forKey: storageKey),
      let saved = try? JSONDecoder().decode(StoredListPreferences.self, from: data)
    {
      menu = saved.menu.normalized()
      sidebar = saved.sidebar.normalized()
    } else {
      menu = .standard
      sidebar = .standard
    }
  }

  public func settings(for surface: AccountListSurface) -> AccountListSettings {
    surface == .menu ? menu : sidebar
  }

  public func setVisible(_ visible: Bool, field: AccountDisplayField, on surface: AccountListSurface) {
    var value = settings(for: surface)
    value.visibleFields.removeAll { $0 == field }
    if visible { value.visibleFields.append(field) }
    set(value, for: surface)
  }

  public func setDensity(_ density: AccountListDensity, on surface: AccountListSurface) {
    var value = settings(for: surface)
    value.density = density
    set(value, for: surface)
  }

  public func moveField(
    _ source: AccountDisplayField,
    relativeTo target: AccountDisplayField,
    after: Bool,
    on surface: AccountListSurface
  ) {
    var value = settings(for: surface)
    guard source != target, value.fieldOrder.contains(source),
      let sourceIndex = value.fieldOrder.firstIndex(of: source)
    else { return }
    value.fieldOrder.remove(at: sourceIndex)
    guard let targetIndex = value.fieldOrder.firstIndex(of: target) else { return }
    value.fieldOrder.insert(source, at: targetIndex + (after ? 1 : 0))
    set(value, for: surface)
  }

  public func moveAccount(
    _ source: AccountID,
    relativeTo target: AccountID,
    after: Bool,
    accounts: [AccountRecord],
    on surface: AccountListSurface
  ) {
    guard source != target else { return }
    var value = settings(for: surface)
    var order = value.orderedAccounts(accounts).map(\.id)
    guard let sourceIndex = order.firstIndex(of: source) else { return }
    order.remove(at: sourceIndex)
    guard let targetIndex = order.firstIndex(of: target) else { return }
    order.insert(source, at: targetIndex + (after ? 1 : 0))
    value.accountOrder = order
    set(value, for: surface)
  }

  public func reset(_ surface: AccountListSurface) {
    set(.standard, for: surface)
  }

  private func set(_ value: AccountListSettings, for surface: AccountListSurface) {
    if surface == .menu { menu = value.normalized() } else { sidebar = value.normalized() }
    let stored = StoredListPreferences(menu: menu, sidebar: sidebar)
    if let data = try? JSONEncoder().encode(stored) {
      userDefaults.set(data, forKey: storageKey)
    }
  }
}
