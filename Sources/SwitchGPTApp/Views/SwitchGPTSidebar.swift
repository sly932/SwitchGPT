import SwiftUI
import SwitchGPTAppCore

struct SwitchGPTSidebar: View {
  let store: SwitchGPTAppStore
  let updateStore: AppUpdateStore
  let listPreferences: AccountListPreferences
  let resetTimePreferences: ResetTimePreferences
  @Binding var selection: AccountID?
  let topInset: CGFloat
  let onAddOrCancel: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.openURL) private var openURL
  @Environment(\.openWindow) private var openWindow

  var body: some View {
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

        HStack {
          Text("Accounts")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
          Spacer()
          Text(String(store.accounts.count))
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(.tertiary)
          Button {
            openWindow(id: "display-settings")
          } label: {
            Image(systemName: "slider.horizontal.3")
              .font(.system(size: 11))
              .frame(width: 24, height: 24)
          }
          .buttonStyle(.plain)
          .help("Customize account list")
          .accessibilityLabel("Customize account list")
        }
        .padding(.horizontal, 10)
        .padding(.top, 16)
        .padding(.bottom, 5)
      }
      .padding(.horizontal, 8)

      ScrollView {
        LazyVStack(spacing: 2) {
          ForEach(listPreferences.sidebar.orderedAccounts(store.accounts)) { account in
            Button {
              selection = account.id
            } label: {
              AccountSidebarRow(
                account: account,
                isCurrent: store.currentAccountID.map { $0 == account.id } ?? false,
                isSelected: selection == account.id,
                refreshFailed: store.quotaRefreshFailedAccountIDs.contains(account.id),
                settings: listPreferences.sidebar,
                resetTimeFormat: resetTimePreferences.format
              )
            }
            .buttonStyle(.plain)
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
    .padding(.top, topInset)
    .background(ChatGPTStyle.sidebarBackground(for: colorScheme))
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
        isHovered ? ChatGPTStyle.hoverFill : Color.clear,
        in: RoundedRectangle(cornerRadius: ChatGPTStyle.rowRadius, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: 0.15), value: isHovered)
  }
}

private struct AccountSidebarRow: View {
  let account: AccountRecord
  let isCurrent: Bool
  let isSelected: Bool
  let refreshFailed: Bool
  let settings: AccountListSettings
  let resetTimeFormat: ResetTimeFormat

  @State private var isHovered = false

  var body: some View {
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
        if settings.density == .detailed, !settings.orderedVisibleFields.isEmpty {
          Text(settings.summary(
            for: account,
            resetTimeFormat: resetTimeFormat,
            refreshFailed: refreshFailed
          ))
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(settings.summary(
              for: account,
              resetTimeFormat: resetTimeFormat,
              refreshFailed: refreshFailed
            ))
        }
      }

      if settings.density == .compact, !settings.orderedVisibleFields.isEmpty {
        Text(settings.summary(
          for: account,
          resetTimeFormat: resetTimeFormat,
          refreshFailed: refreshFailed
        ))
          .font(.system(size: 11).monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .help(settings.summary(
            for: account,
            resetTimeFormat: resetTimeFormat,
            refreshFailed: refreshFailed
          ))
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
    .padding(.horizontal, 10)
    .frame(height: settings.density == .compact ? 34 : 46)
    .background(
      isSelected ? ChatGPTStyle.hoverFill : (isHovered ? ChatGPTStyle.subtleFill : Color.clear),
      in: RoundedRectangle(cornerRadius: ChatGPTStyle.rowRadius, style: .continuous)
    )
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: 0.15), value: isHovered)
  }
}
