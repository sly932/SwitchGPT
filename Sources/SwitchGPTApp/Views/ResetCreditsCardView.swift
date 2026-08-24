import SwiftUI
import SwitchGPTAppCore

struct ResetCreditsCardView: View {
  let summary: RateLimitResetCreditsSummary?

  @State private var isExpanded: Bool
  @State private var showsAllCredits = false

  private let previewGroupLimit = 3

  init(
    summary: RateLimitResetCreditsSummary?,
    initiallyExpanded: Bool = false
  ) {
    self.summary = summary
    _isExpanded = State(initialValue: initiallyExpanded)
  }

  var body: some View {
    VStack(spacing: 0) {
      header

      if isExpanded, canExpand {
        Divider()
          .padding(.horizontal, 16)

        expandedContent
      }
    }
    .chatGPTPanel()
    .animation(.easeOut(duration: 0.16), value: isExpanded)
    .onChange(of: summary) { _, _ in
      if !canExpand {
        isExpanded = false
      }
    }
    .sheet(isPresented: $showsAllCredits) {
      if let summary {
        ResetCreditsDetailSheet(summary: summary)
      }
    }
  }

  @ViewBuilder
  private var header: some View {
    if canExpand {
      Button {
        isExpanded.toggle()
      } label: {
        headerContent
      }
      .buttonStyle(.plain)
      .accessibilityLabel(titleText)
      .accessibilityValue(secondaryText)
      .accessibilityHint(isExpanded ? "Collapses expiration details" : "Expands expiration details")
    } else {
      headerContent
        .accessibilityElement(children: .combine)
    }
  }

  private var headerContent: some View {
    HStack(spacing: 12) {
      Image(systemName: "arrow.counterclockwise.circle")
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 28, height: 28)

      VStack(alignment: .leading, spacing: 3) {
        Text(titleText)
          .font(.system(size: 14, weight: .semibold))

        Text(secondaryText)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 12)

      if canExpand {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.tertiary)
          .frame(width: 16)
      }
    }
    .padding(.horizontal, 16)
    .frame(minHeight: 68)
    .contentShape(Rectangle())
  }

  private var expandedContent: some View {
    VStack(spacing: 0) {
      ForEach(Array(previewGroups.enumerated()), id: \.element) { index, group in
        if index > 0 {
          Divider()
            .padding(.horizontal, 16)
        }
        expirationRow(group)
      }

      if !showsViewAll, let summary, summary.missingDetailCount > 0 {
        if !previewGroups.isEmpty {
          Divider()
            .padding(.horizontal, 16)
        }
        unavailableDetailsRow(summary.missingDetailCount)
      }

      if showsViewAll, let summary {
        Divider()
          .padding(.horizontal, 16)

        Button {
          showsAllCredits = true
        } label: {
          HStack {
            Text("View all \(summary.availableCount) reset credits")
            Spacer()
            Image(systemName: "chevron.right")
              .font(.system(size: 11, weight: .semibold))
          }
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(ChatGPTStyle.actionBlue)
          .padding(.horizontal, 16)
          .frame(minHeight: 42)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the complete expiration list")
      }
    }
  }

  private func expirationRow(_ group: RateLimitResetCreditExpirationGroup) -> some View {
    HStack(spacing: 12) {
      Text(resetCreditExpirationText(group.expiresAt))
        .lineLimit(1)
      Spacer(minLength: 12)
      Text(String(group.count))
        .fontWeight(.semibold)
        .monospacedDigit()
    }
    .font(.system(size: 13))
    .padding(.horizontal, 16)
    .frame(minHeight: 42)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(expirationAccessibilityLabel(group))
  }

  private func unavailableDetailsRow(_ count: Int) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "info.circle")
        .foregroundStyle(.secondary)
      Text(unavailableDetailsText(count))
      Spacer()
    }
    .font(.system(size: 12))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 16)
    .frame(minHeight: 42)
  }

  private var canExpand: Bool {
    guard let summary, summary.availableCount > 1 else { return false }
    return !summary.expirationGroups.isEmpty
  }

  private var previewGroups: [RateLimitResetCreditExpirationGroup] {
    Array((summary?.expirationGroups ?? []).prefix(previewGroupLimit))
  }

  private var showsViewAll: Bool {
    (summary?.expirationGroups.count ?? 0) > previewGroupLimit
  }

  private var titleText: String {
    guard let summary else { return "Usage limit resets" }
    if summary.availableCount == 1 {
      return "1 usage limit reset"
    }
    return "\(summary.availableCount) usage limit resets"
  }

  private var secondaryText: String {
    guard let summary else { return "Availability unavailable" }
    guard summary.availableCount > 0 else { return "No reset credits available" }
    if let nearest = summary.nearestKnownExpiry {
      let prefix = summary.detailsAreComplete ? "Nearest expiry " : "Nearest known expiry "
      return prefix + resetCreditExpirationText(nearest)
    }
    if summary.knownDetailCount > 0, summary.missingDetailCount == 0 {
      return "No expiration date"
    }
    return "Expiry details unavailable"
  }

  private func expirationAccessibilityLabel(
    _ group: RateLimitResetCreditExpirationGroup
  ) -> String {
    let creditWord = group.count == 1 ? "credit" : "credits"
    if let expiresAt = group.expiresAt {
      return "\(group.count) reset \(creditWord) expire \(resetCreditExpirationText(expiresAt))"
    }
    return "\(group.count) reset \(creditWord) have no expiration date"
  }
}

private struct ResetCreditsDetailSheet: View {
  let summary: RateLimitResetCreditsSummary

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Usage limit resets")
            .font(.system(size: 18, weight: .semibold))
          Text("\(summary.availableCount) available")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(20)

      Divider()

      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(Array(summary.expirationGroups.enumerated()), id: \.element) {
            index,
            group in
            if index > 0 {
              Divider()
            }
            detailRow(group)
          }

          if summary.missingDetailCount > 0 {
            if !summary.expirationGroups.isEmpty {
              Divider()
            }
            HStack(spacing: 10) {
              Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
              Text(unavailableDetailsText(summary.missingDetailCount))
              Spacer()
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(.vertical, 14)
          }
        }
        .padding(.horizontal, 20)
      }

      Divider()

      HStack {
        Spacer()
        Button("Done") {
          dismiss()
        }
        .buttonStyle(ChatGPTPrimaryButtonStyle())
        .keyboardShortcut(.cancelAction)
      }
      .padding(16)
    }
    .frame(width: 480, height: 420)
    .background(ChatGPTStyle.surface(for: colorScheme))
  }

  private func detailRow(_ group: RateLimitResetCreditExpirationGroup) -> some View {
    HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 3) {
        Text(resetCreditExpirationText(group.expiresAt))
          .font(.system(size: 14, weight: .medium))
        Text(group.count == 1 ? "1 reset credit" : "\(group.count) reset credits")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text(String(group.count))
        .font(.system(size: 14, weight: .semibold))
        .monospacedDigit()
    }
    .padding(.vertical, 13)
    .accessibilityElement(children: .combine)
  }
}

private func resetCreditExpirationText(_ date: Date?) -> String {
  guard let date else { return "No expiration" }
  return date.formatted(date: .abbreviated, time: .shortened)
}

private func unavailableDetailsText(_ count: Int) -> String {
  if count == 1 {
    return "1 expiration detail unavailable"
  }
  return "\(count) expiration details unavailable"
}
