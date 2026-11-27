import SwiftUI
import SwitchGPTAppCore
import UniformTypeIdentifiers

struct SwitchGPTSidebar: View {
  let store: SwitchGPTAppStore
  let updateStore: AppUpdateStore
  let listPreferences: AccountListPreferences
  let resetTimePreferences: ResetTimePreferences
  let selection: AccountID?
  @Binding var showsOnlyFavorites: Bool
  @Binding var section: DashboardSection
  let topInset: CGFloat
  let onSelectAccount: (AccountID) -> Void
  let onAddOrCancel: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase
  @State private var subscriptions = SubscriptionDisplayStore.shared

  var body: some View {
    let accounts = listPreferences.sidebarAccounts(store.accounts, favoritesOnly: false)
    let favorites = accounts.filter { listPreferences.isSidebarFavorite($0.id) }
    let visibleAccounts = showsOnlyFavorites ? favorites : accounts

    VStack(spacing: 0) {
      VStack(spacing: 2) {
        SidebarActionRow(
          title: store.accountOnboardingActivity.isInProgress
            ? "Cancel sign-in" : "Add account",
          symbol: store.accountOnboardingActivity.isInProgress ? "xmark" : "plus",
          action: onAddOrCancel
        )

        if store.accountOnboardingActivity.isInProgress {
          AccountOnboardingStatusRow(
            message: L10n.string("Complete sign-in in your browser"),
            isFailure: false,
            onDismiss: nil
          )
        } else if let message = store.accountOnboardingActivity.failureMessage {
          AccountOnboardingStatusRow(
            message: L10n.string(message),
            isFailure: true,
            onDismiss: store.resetAccountOnboardingActivity
          )
        }

        SidebarActionRow(
          title: "账号总览",
          symbol: "chart.bar.xaxis",
          action: { section = .overview },
          isSelected: section == .overview
        )
        .padding(.top, 12)

        SidebarActionRow(
          title: "Quota Timeline",
          symbol: "chart.line.uptrend.xyaxis",
          action: { section = .quotaTimeline },
          isSelected: section == .quotaTimeline
        )

        SidebarActionRow(
          title: "Usage Plan",
          symbol: "calendar.badge.clock",
          action: { section = .usagePlan },
          isSelected: section == .usagePlan
        )

        SidebarActionRow(
          title: "Customize Display",
          symbol: "slider.horizontal.3",
          action: { section = .displaySettings },
          isSelected: section == .displaySettings
        )

        HStack(spacing: 4) {
          Text("Accounts")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
          Spacer(minLength: 0)
          Picker(L10n.string("Account filter"), selection: $showsOnlyFavorites) {
            Text("\(L10n.string("All")) \(accounts.count)").tag(false)
            Text("\(L10n.string("Favorites")) \(favorites.count)").tag(true)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .controlSize(.small)
          .frame(maxWidth: 144)

          Button {
            section = .displaySettings
          } label: {
            Image(systemName: "slider.horizontal.3")
              .font(.system(size: 11))
              .frame(width: 24, height: 24)
          }
          .buttonStyle(.plain)
          .help("Customize account list")
          .accessibilityLabel("Customize account list")
        }
        .padding(.horizontal, 7)
        .padding(.top, 16)
        .padding(.bottom, 5)
      }
      .padding(.horizontal, 8)

      ScrollView {
        LazyVStack(spacing: 2) {
          if showsOnlyFavorites && favorites.isEmpty {
            VStack(spacing: 7) {
              Label(L10n.string("No favorite accounts"), systemImage: "star")
                .font(.system(size: 12, weight: .medium))
              Text(L10n.string("Star an account in All to see it here."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
              Button(L10n.string("Show all accounts")) { showsOnlyFavorites = false }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .padding(.horizontal, 8)
          }

          ForEach(visibleAccounts) { account in
            AccountSidebarRow(
              account: account,
              isCurrent: store.currentAccountID == account.id,
              isSelected: section == .account && selection == account.id,
              isFavorite: listPreferences.isSidebarFavorite(account.id),
              refreshFailed: store.quotaRefreshFailedAccountIDs.contains(account.id),
              canReorder: visibleAccounts.count > 1,
              settings: listPreferences.sidebar,
              resetTimeFormat: resetTimePreferences.format,
              subscriptionExpiry: subscriptions.expiry(for: account.email),
              onSelect: { onSelectAccount(account.id) },
              onToggleFavorite: { listPreferences.toggleSidebarFavorite(account.id, accounts: store.accounts) },
              onDropAccount: { source, edge in moveAccount(source, relativeTo: account.id, edge: edge) },
              onMoveOnePosition: { edge in moveOnePosition(account.id, edge: edge) }
            )
          }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
      }
      .scrollIndicators(.automatic)

      VStack(spacing: 0) {
        if let availableUpdate = updateStore.availableUpdate {
          AppUpdateSidebarRow(
            update: availableUpdate,
            onOpen: {
              openURL(availableUpdate.releaseURL)
            },
            onLater: updateStore.snoozeAvailableUpdate
          )
          .padding(.horizontal, 8)
          .padding(.vertical, 8)
        }

        Divider()

        HStack(spacing: 8) {
          Image(systemName: "lock.fill")
            .font(.system(size: 10, weight: .medium))
          Text("Accounts stay on this Mac")
            .font(.system(size: 11))
          Spacer()
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .padding(.horizontal, 8)
        .padding(.top, 8)
      }
      .padding(.bottom, 10)
    }
    .task { subscriptions.reload() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { subscriptions.reload() }
    }
    .padding(.top, topInset)
    .background(ChatGPTStyle.sidebarBackground(for: colorScheme))
  }

  private func moveAccount(_ source: AccountID, relativeTo target: AccountID, edge: SidebarAccountDropEdge) {
    if showsOnlyFavorites {
      let favorites = listPreferences.sidebarAccounts(store.accounts, favoritesOnly: true)
      guard let sourceIndex = favorites.firstIndex(where: { $0.id == source }),
        let targetIndex = favorites.firstIndex(where: { $0.id == target })
      else { return }
      let boundary = targetIndex + (edge == .after ? 1 : 0)
      guard boundary != sourceIndex, boundary != sourceIndex + 1 else { return }
    }
    withAnimation(.easeOut(duration: 0.15)) {
      listPreferences.moveAccount(source, relativeTo: target, after: edge == .after, accounts: store.accounts, on: .sidebar)
    }
  }

  private func moveOnePosition(_ id: AccountID, edge: SidebarAccountDropEdge) {
    let visibleAccounts = listPreferences.sidebarAccounts(store.accounts, favoritesOnly: showsOnlyFavorites)
    guard let index = visibleAccounts.firstIndex(where: { $0.id == id }) else { return }
    let neighbor = index + (edge == .before ? -1 : 1)
    guard visibleAccounts.indices.contains(neighbor) else { return }
    moveAccount(id, relativeTo: visibleAccounts[neighbor].id, edge: edge)
  }
}

struct AppUpdateSidebarRow: View {
  let update: AppUpdateInfo
  let onOpen: () -> Void
  let onLater: () -> Void

  @State private var isHovered = false

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Button(action: onOpen) {
        HStack(spacing: 10) {
          Image(systemName: "arrow.down.circle")
            .font(.system(size: 21, weight: .medium))
            .symbolRenderingMode(.palette)
            .foregroundStyle(Color.white.opacity(0.90), ChatGPTStyle.actionBlue)
            .frame(width: 28, height: 28)

          VStack(alignment: .leading, spacing: 2) {
            Text("Update available")
              .font(.system(size: 13, weight: .medium))
              .lineLimit(1)
            Text(L10n.format("SwitchGPT %@", update.version.displayValue))
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }

          Spacer(minLength: 6)

          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.trailing, 16)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 58)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityHint("Opens the official GitHub release")

      Button(action: onLater) {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Remind me later")
      .accessibilityLabel("Remind me later")
      .padding(.top, 3)
      .padding(.trailing, 3)
    }
    .background(
      isHovered
        ? ChatGPTStyle.actionBlue.opacity(0.13)
        : ChatGPTStyle.semanticFill(ChatGPTStyle.actionBlue),
      in: RoundedRectangle(cornerRadius: ChatGPTStyle.rowRadius, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: ChatGPTStyle.rowRadius, style: .continuous)
        .stroke(ChatGPTStyle.semanticBorder(ChatGPTStyle.actionBlue), lineWidth: 1)
    }
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: 0.15), value: isHovered)
  }
}

private struct AccountOnboardingStatusRow: View {
  let message: String
  let isFailure: Bool
  let onDismiss: (() -> Void)?

  var body: some View {
    HStack(spacing: 8) {
      if isFailure {
        Image(systemName: "exclamationmark.circle.fill")
          .foregroundStyle(ChatGPTStyle.dangerRed)
      } else {
        ProgressView()
          .controlSize(.mini)
          .tint(ChatGPTStyle.actionBlue)
      }

      Text(L10n.string(message))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(2)

      Spacer(minLength: 4)

      if let onDismiss {
        Button(action: onDismiss) {
          Image(systemName: "xmark")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Dismiss")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
  }
}

private struct SidebarActionRow: View {
  let title: String
  let symbol: String
  let action: () -> Void
  var isSelected: Bool = false

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: symbol)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(ChatGPTStyle.actionBlue)
          .frame(width: 20)
        Text(L10n.string(title))
          .font(.system(size: 14))
        Spacer()
      }
      .padding(.horizontal, 10)
      .frame(height: 34)
      .background(
        isSelected ? ChatGPTStyle.subtleFill
          : isHovered ? ChatGPTStyle.hoverFill : Color.clear,
        in: RoundedRectangle(cornerRadius: ChatGPTStyle.rowRadius, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: 0.15), value: isHovered)
  }
}

private struct AccountSidebarRow: View {
  private enum Action: Hashable {
    case favorite
    case reorder
  }

  let account: AccountRecord
  let isCurrent: Bool
  let isSelected: Bool
  let isFavorite: Bool
  let refreshFailed: Bool
  let canReorder: Bool
  let settings: AccountListSettings
  let resetTimeFormat: ResetTimeFormat
  let subscriptionExpiry: String?
  let onSelect: () -> Void
  let onToggleFavorite: () -> Void
  let onDropAccount: (AccountID, SidebarAccountDropEdge) -> Void
  let onMoveOnePosition: (SidebarAccountDropEdge) -> Void

  @State private var isHovered = false
  @State private var rowHeight: CGFloat = 0
  @State private var dropEdge: SidebarAccountDropEdge?
  @FocusState private var focusedAction: Action?

  var body: some View {
    let row = ZStack(alignment: .topTrailing) {
      Button(action: onSelect) {
        accountLabel.contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(isSelected ? .isSelected : [])

      HStack(spacing: 1) {
        favoriteControl
        if canReorder {
          reorderControl
            .opacity(showsActions ? 1 : 0)
            .allowsHitTesting(showsActions)
        }
      }
      .padding(.trailing, 6)
      .frame(height: headerHeight)
    }
    .background(
      isSelected ? ChatGPTStyle.hoverFill : (isHovered ? ChatGPTStyle.subtleFill : Color.clear),
      in: RoundedRectangle(cornerRadius: ChatGPTStyle.rowRadius, style: .continuous)
    )
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: 0.15), value: isHovered)

    if canReorder, let dropType = SidebarAccountDrag.type {
      row
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowHeight = $0 }
        .onDrop(of: [dropType], delegate: SidebarAccountDrop(
          type: dropType,
          target: account.id,
          height: rowHeight,
          edge: $dropEdge,
          move: onDropAccount
        ))
        .overlay(alignment: dropEdge == .after ? .bottom : .top) {
          if dropEdge != nil {
            Capsule()
              .fill(ChatGPTStyle.actionBlue)
              .frame(height: 2)
              .padding(.horizontal, 3)
              .allowsHitTesting(false)
              .accessibilityHidden(true)
          }
        }
    } else {
      row
    }
  }

  private var headerHeight: CGFloat { settings.density == .compact ? 34 : 46 }
  private var showsActions: Bool { isHovered || focusedAction != nil }

  private var favoriteControl: some View {
    let actionName = L10n.format(isFavorite ? "Remove %@ from favorites" : "Favorite %@", account.accountLabel)
    return Button(action: onToggleFavorite) {
      Image(systemName: isFavorite ? "star.fill" : "star")
        .font(.system(size: 12))
        .foregroundStyle(isFavorite ? ChatGPTStyle.warningOrange : Color.secondary)
        .frame(width: 20, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusable()
    .focused($focusedAction, equals: .favorite)
    .help(actionName)
    .accessibilityLabel(actionName)
    .accessibilityAddTraits(isFavorite ? .isSelected : [])
    .opacity(isFavorite || showsActions ? 1 : 0)
    .allowsHitTesting(isFavorite || showsActions)
  }

  private var reorderControl: some View {
    Image(systemName: "line.3.horizontal")
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(.secondary)
      .frame(width: 20, height: 24)
      .contentShape(Rectangle())
      .focusable()
      .focused($focusedAction, equals: .reorder)
      .help(L10n.string("Drag to reorder, or use the up and down arrow keys"))
      .accessibilityLabel(L10n.format("Reorder %@", account.accountLabel))
      .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment: onMoveOnePosition(.after)
        case .decrement: onMoveOnePosition(.before)
        @unknown default: break
        }
      }
      .onKeyPress(keys: [.upArrow, .downArrow]) { press in
        onMoveOnePosition(press.key == .upArrow ? .before : .after)
        return .handled
      }
      .onDrag { SidebarAccountDrag.provider(for: account.id) }
  }

  private var accountLabel: some View {
    let otherDetails = settings.summary(
      for: account,
      resetTimeFormat: resetTimeFormat,
      refreshFailed: refreshFailed,
      excludingWeeklyReset: true,
      excludingSubscriptionExpiry: true,
      subscriptionExpiry: subscriptionExpiry
    )
    let resetText = settings.weeklyResetText(for: account, resetTimeFormat: resetTimeFormat)
    let expiryText = settings.subscriptionExpiryText(
      for: account, resetTimeFormat: resetTimeFormat, subscriptionExpiry: subscriptionExpiry
    )

    return VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: account.symbolName)
          .font(.system(size: 12, weight: .medium))
          .frame(width: 26, height: 26)
          .background(ChatGPTStyle.subtleFill, in: Circle())

        VStack(alignment: .leading, spacing: 1) {
          Text(account.accountLabel)
            .font(.system(size: settings.density == .compact ? 12 : 14, weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .help(account.accountLabel)
          if settings.density == .detailed, !otherDetails.isEmpty {
            Text(otherDetails)
              .font(.system(size: 11).monospacedDigit())
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .help(otherDetails)
          }
        }

        if settings.density == .compact, !otherDetails.isEmpty {
          Text(otherDetails)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(otherDetails)
        }

        Spacer(minLength: 4)

        if refreshFailed {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(ChatGPTStyle.warningOrange)
            .help("Refresh failed; showing previous usage")
            .accessibilityLabel("Refresh failed; showing previous usage")
        }

        if isCurrent {
          Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(ChatGPTStyle.successGreen)
            .accessibilityLabel("Current account")
        }
      }
      .padding(.leading, 10)
      .padding(.trailing, canReorder ? 50 : 29)
      .frame(height: headerHeight)

      if let resetText {
        Text(resetText)
          .font(.system(size: 11).monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
          .help(resetText)
          .padding(.horizontal, 10)
          .frame(height: 20)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let expiryText {
        Text(expiryText)
          .font(.system(size: 11).monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
          .help(expiryText)
          .padding(.horizontal, 10)
          .frame(height: 20)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

private enum SidebarAccountDropEdge {
  case before
  case after
}

private enum SidebarAccountDrag {
  static let type = UTType(mimeType: "application/x-switchgpt-sidebar-account-order", conformingTo: .data)
  private static let prefix = UUID().uuidString + ":"

  static func provider(for id: AccountID) -> NSItemProvider {
    let provider = NSItemProvider()
    guard let type else { return provider }
    let payload = Data((prefix + id.rawValue).utf8)
    provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { result in
      result(payload, nil)
      return nil
    }
    return provider
  }

  static func accountID(from data: Data) -> AccountID? {
    guard let value = String(data: data, encoding: .utf8), value.hasPrefix(prefix) else { return nil }
    return AccountID(String(value.dropFirst(prefix.count)))
  }
}

private struct SidebarAccountDrop: DropDelegate {
  let type: UTType
  let target: AccountID
  let height: CGFloat
  @Binding var edge: SidebarAccountDropEdge?
  let move: (AccountID, SidebarAccountDropEdge) -> Void

  func validateDrop(info: DropInfo) -> Bool {
    height > 0 && info.hasItemsConforming(to: [type])
  }

  func dropEntered(info: DropInfo) {
    edge = insertionEdge(at: info.location)
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    edge = insertionEdge(at: info.location)
    return DropProposal(operation: .move)
  }

  func dropExited(info: DropInfo) {
    edge = nil
  }

  func performDrop(info: DropInfo) -> Bool {
    edge = nil
    let insertionEdge = insertionEdge(at: info.location)
    guard let provider = info.itemProviders(for: [type]).first else { return false }
    provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
      guard let data, let source = SidebarAccountDrag.accountID(from: data), source != target else { return }
      Task { @MainActor in move(source, insertionEdge) }
    }
    return true
  }

  private func insertionEdge(at location: CGPoint) -> SidebarAccountDropEdge {
    location.y < height / 2 ? .before : .after
  }
}
