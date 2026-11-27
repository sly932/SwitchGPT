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
    Group {
      if let template = Self.template, !renderFailed {
        QuotaTimelineWebView(
          template: template,
          snapshot: QuotaTimelineSnapshot(
            accounts: store.accounts,
            failedAccountIDs: store.quotaRefreshFailedAccountIDs,
            lastRefreshedAt: store.lastRefreshedAt,
            language: language,
            refreshing: store.activity == .refreshing,
            canRefresh: !store.activity.isBusy && !store.accounts.isEmpty
          ),
          onRefresh: refreshUsage,
          onFailure: { renderFailed = true }
        )
      } else {
        ContentUnavailableView {
          Label(L10n.string("Unable to display the quota timeline."), systemImage: "exclamationmark.circle")
        } actions: {
          if Self.template != nil {
            Button(L10n.string("Refresh usage")) {
              renderFailed = false
              refreshUsage()
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func refreshUsage() {
    guard !store.activity.isBusy, !store.accounts.isEmpty else { return }
    Task { await store.refresh() }
  }
}

private struct QuotaTimelineWebView: NSViewRepresentable {
  private static let refreshMessage = "refreshQuota"
  let template: String
  let snapshot: QuotaTimelineSnapshot
  let onRefresh: () -> Void
  let onFailure: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onRefresh: onRefresh, onFailure: onFailure)
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController.add(context.coordinator, name: Self.refreshMessage)
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
    view.loadHTMLString(template, baseURL: nil)
    return view
  }

  func updateNSView(_ view: WKWebView, context: Context) {
    context.coordinator.pending = snapshot
    context.coordinator.updateTimeline(in: view)
  }

  static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
    coordinator.detach()
    view.configuration.userContentController.removeScriptMessageHandler(forName: refreshMessage)
    view.navigationDelegate = nil
    view.stopLoading()
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var pending: QuotaTimelineSnapshot?
    private let onRefresh: () -> Void
    private let onFailure: () -> Void
    private var displayed: QuotaTimelineSnapshot?
    private var isReady = false
    private var isSending = false
    private var isAttached = true

    init(onRefresh: @escaping () -> Void, onFailure: @escaping () -> Void) {
      self.onRefresh = onRefresh
      self.onFailure = onFailure
    }

    func detach() {
      isAttached = false
      pending = nil
      displayed = nil
    }

    func updateTimeline(in view: WKWebView) {
      guard isAttached, isReady, !isSending, let pending, pending != displayed else { return }
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
          guard isAttached else { return }
          displayed = pending
          isSending = false
          updateTimeline(in: view)
        } catch {
          guard isAttached else { return }
          isSending = false
          let failure = error as NSError
          NSLog("[SwitchGPT/quota-timeline] Renderer update failed %@ %ld", failure.domain, failure.code)
          onFailure()
        }
      }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
      guard isAttached, isReady, message.name == QuotaTimelineWebView.refreshMessage,
        message.frameInfo.isMainFrame,
        message.webView?.url?.absoluteString == "about:blank",
        message.body as? String == "refresh"
      else { return }
      onRefresh()
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
