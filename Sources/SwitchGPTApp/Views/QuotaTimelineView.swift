import SwiftUI
import SwitchGPTAppCore
import WebKit

struct QuotaTimelineView: View {
  let store: SwitchGPTAppStore
  let language: String

  @State private var renderFailed = false

  private static let template: String? = Bundle.main.url(
    forResource: "quota-timeline", withExtension: "html"
  ).flatMap { try? String(contentsOf: $0, encoding: .utf8) }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Text(L10n.string("Quota Timeline"))
          .font(.system(size: 20, weight: .semibold))
        Spacer()
        if store.activity == .refreshing {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel(L10n.string("Refreshing usage"))
        }
        Button {
          renderFailed = false
          Task { await store.refresh() }
        } label: {
          Label(L10n.string("Refresh usage"), systemImage: "arrow.clockwise")
        }
        .disabled(store.activity.isBusy || store.accounts.isEmpty)
      }
      .padding(.horizontal, 22)
      .padding(.vertical, 15)

      Divider()

      if let template = Self.template, !renderFailed {
        QuotaTimelineWebView(
          template: template,
          snapshot: QuotaTimelineSnapshot(
            accounts: store.accounts,
            failedAccountIDs: store.quotaRefreshFailedAccountIDs,
            lastRefreshedAt: store.lastRefreshedAt,
            language: language
          ),
          onFailure: { renderFailed = true }
        )
      } else {
        ContentUnavailableView(
          L10n.string("Unable to display the quota timeline."),
          systemImage: "exclamationmark.circle"
        )
      }
    }
  }
}

private struct QuotaTimelineWebView: NSViewRepresentable {
  let template: String
  let snapshot: QuotaTimelineSnapshot
  let onFailure: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onFailure: onFailure) }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
    view.loadHTMLString(template, baseURL: nil)
    return view
  }

  func updateNSView(_ view: WKWebView, context: Context) {
    context.coordinator.pending = snapshot
    context.coordinator.updateTimeline(in: view)
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate {
    var pending: QuotaTimelineSnapshot?
    private let onFailure: () -> Void
    private var displayed: QuotaTimelineSnapshot?
    private var isReady = false
    private var isSending = false

    init(onFailure: @escaping () -> Void) {
      self.onFailure = onFailure
    }

    func updateTimeline(in view: WKWebView) {
      guard isReady, !isSending, let pending, pending != displayed else { return }
      isSending = true
      Task { @MainActor in
        do {
          let encoder = JSONEncoder()
          encoder.dateEncodingStrategy = .iso8601
          let json = String(decoding: try encoder.encode(pending), as: UTF8.self)
          _ = try await view.callAsyncJavaScript(
            "window.updateQuotaTimeline(JSON.parse(json))",
            arguments: ["json": json], contentWorld: .page
          )
          displayed = pending
          isSending = false
          updateTimeline(in: view)
        } catch {
          isSending = false
          let failure = error as NSError
          NSLog("[SwitchGPT/quota-timeline] Renderer update failed %@ %ld", failure.domain, failure.code)
          onFailure()
        }
      }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      isReady = true
      updateTimeline(in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      onFailure()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      onFailure()
    }

    func webView(
      _ webView: WKWebView,
      didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      if (error as NSError).code != NSURLErrorCancelled { onFailure() }
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
      decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
  }
}
