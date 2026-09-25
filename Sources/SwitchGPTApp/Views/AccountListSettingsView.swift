import SwiftUI
import SwitchGPTAppCore

struct AccountListSettingsView: View {
  let preferences: AccountListPreferences
  let store: SwitchGPTAppStore

  @State private var surface: AccountListSurface = .menu
  @State private var targetedField: AccountDisplayField?
  @State private var targetedAccount: AccountID?

  private var settings: AccountListSettings { preferences.settings(for: surface) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 5) {
          Text("Customize account lists")
            .font(.system(size: 22, weight: .semibold))
          Text("Choose what appears in each list. Drag the handles to change the order. Changes save automatically on this Mac.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }

        Picker("Location", selection: $surface) {
          Text("Menu bar popover").tag(AccountListSurface.menu)
          Text("Dashboard sidebar").tag(AccountListSurface.sidebar)
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        settingsSection(title: "Visible information", subtitle: "The account name and current marker always remain visible.") {
          ForEach(settings.fieldOrder) { field in
            fieldRow(field)
          }
        }

        settingsSection(title: "Account order", subtitle: "Drag an account to its preferred position.") {
          ForEach(settings.orderedAccounts(store.accounts)) { account in
            accountOrderRow(account)
          }
        }

        settingsSection(title: "List density", subtitle: "Use a second line when you want to see more detail at a glance.") {
          Picker("Density", selection: Binding(
            get: { settings.density },
            set: { preferences.setDensity($0, on: surface) }
          )) {
            Text("Compact · one line").tag(AccountListDensity.compact)
            Text("Detailed · two lines").tag(AccountListDensity.detailed)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
        }

        settingsSection(title: "Preview", subtitle: "This uses your current local account data.") {
          if store.accounts.isEmpty {
            Text("Add an account to preview the list.")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
          } else {
            ForEach(settings.orderedAccounts(store.accounts)) { account in
              HStack(spacing: 8) {
                Image(systemName: account.symbolName)
                  .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                  Text(account.accountLabel)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                  if settings.density == .detailed, !settings.orderedVisibleFields.isEmpty {
                    Text(settings.summary(
                      for: account,
                      refreshFailed: store.quotaRefreshFailedAccountIDs.contains(account.id)
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                  }
                }
                if settings.density == .compact {
                  Text(settings.summary(for: account))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                if store.currentAccountID == account.id {
                  Image(systemName: "checkmark")
                    .foregroundStyle(ChatGPTStyle.successGreen)
                }
              }
              .padding(.vertical, 4)
            }
          }
        }

        HStack {
          Button("Restore defaults for this list") {
            preferences.reset(surface)
          }
          Spacer()
          Text("Saved automatically")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
      }
      .padding(22)
      .frame(maxWidth: 560)
      .frame(maxWidth: .infinity)
    }
    .frame(minWidth: 510, minHeight: 500)
  }

  private func settingsSection<Content: View>(
    title: String,
    subtitle: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(title)
        .font(.system(size: 14, weight: .semibold))
      Text(subtitle)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
      content()
    }
    .padding(15)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(ChatGPTStyle.subtleFill, in: RoundedRectangle(cornerRadius: 12))
  }

  private func fieldRow(_ field: AccountDisplayField) -> some View {
    HStack(spacing: 10) {
      Toggle(field.title, isOn: Binding(
        get: { settings.visibleFields.contains(field) },
        set: { preferences.setVisible($0, field: field, on: surface) }
      ))
      .toggleStyle(.checkbox)
      Spacer(minLength: 5)
      dragHandle("field:" + field.rawValue, label: "Reorder \(field.title)")
        .onKeyPress { press in
          moveFieldWithKeyboard(field, key: press.key)
        }
    }
    .padding(.horizontal, 10)
    .frame(height: 38)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(targetedField == field ? ChatGPTStyle.actionBlue : ChatGPTStyle.border)
    }
    .dropDestination(for: String.self) { items, location in
      guard let raw = items.first, raw.hasPrefix("field:"),
        let source = AccountDisplayField(rawValue: String(raw.dropFirst(6)))
      else { return false }
      preferences.moveField(source, relativeTo: field, after: location.y > 19, on: surface)
      return true
    } isTargeted: { targetedField = $0 ? field : nil }
  }

  private func accountOrderRow(_ account: AccountRecord) -> some View {
    HStack(spacing: 10) {
      Text(account.accountLabel)
        .font(.system(size: 12))
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 5)
      dragHandle("account:" + account.id.rawValue, label: "Reorder \(account.accountLabel)")
        .onKeyPress { press in
          moveAccountWithKeyboard(account.id, key: press.key)
        }
    }
    .padding(.horizontal, 10)
    .frame(height: 38)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(targetedAccount == account.id ? ChatGPTStyle.actionBlue : ChatGPTStyle.border)
    }
    .dropDestination(for: String.self) { items, location in
      guard let raw = items.first, raw.hasPrefix("account:") else { return false }
      let source = AccountID(String(raw.dropFirst(8)))
      preferences.moveAccount(
        source,
        relativeTo: account.id,
        after: location.y > 19,
        accounts: store.accounts,
        on: surface
      )
      return true
    } isTargeted: { targetedAccount = $0 ? account.id : nil }
  }

  private func dragHandle(_ value: String, label: String) -> some View {
    Image(systemName: "line.3.horizontal")
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(.secondary)
      .frame(width: 30, height: 30)
      .background(ChatGPTStyle.subtleFill, in: RoundedRectangle(cornerRadius: 6))
      .help("Drag to reorder, or use the up and down arrow keys")
      .accessibilityLabel(label)
      .focusable()
      .draggable(value)
  }

  private func moveFieldWithKeyboard(_ field: AccountDisplayField, key: KeyEquivalent) -> KeyPress.Result {
    guard key == .upArrow || key == .downArrow,
      let index = settings.fieldOrder.firstIndex(of: field)
    else { return .ignored }
    let targetIndex = index + (key == .upArrow ? -1 : 1)
    guard settings.fieldOrder.indices.contains(targetIndex) else { return .handled }
    preferences.moveField(
      field,
      relativeTo: settings.fieldOrder[targetIndex],
      after: key == .downArrow,
      on: surface
    )
    return .handled
  }

  private func moveAccountWithKeyboard(_ id: AccountID, key: KeyEquivalent) -> KeyPress.Result {
    guard key == .upArrow || key == .downArrow else { return .ignored }
    let order = settings.orderedAccounts(store.accounts).map(\.id)
    guard let index = order.firstIndex(of: id) else { return .ignored }
    let targetIndex = index + (key == .upArrow ? -1 : 1)
    guard order.indices.contains(targetIndex) else { return .handled }
    preferences.moveAccount(
      id,
      relativeTo: order[targetIndex],
      after: key == .downArrow,
      accounts: store.accounts,
      on: surface
    )
    return .handled
  }
}
