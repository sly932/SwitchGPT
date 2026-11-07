import SwiftUI
import SwitchGPTAppCore
import WebKit

struct UsagePlanView: View {
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase
  @State private var subscriptions = SubscriptionDisplayStore.shared
  @State private var htmlURL: URL?
  @State private var notice: String?
  @State private var failure: String?
  @State private var reloadID = UUID()
  @State private var renderFailure: String?

  private var directory: URL {
    AccountSubscriptionStore.defaultStore.fileURL.deletingLastPathComponent()
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Text(L10n.string("Usage Plan"))
          .font(.system(size: 20, weight: .semibold))
        Spacer()
        Button {
          reload()
        } label: {
          Label(L10n.string("Reload plan"), systemImage: "arrow.clockwise")
        }
        if let htmlURL {
          Button {
            openURL(htmlURL)
          } label: {
            Label(L10n.string("Open HTML"), systemImage: "arrow.up.right.square")
          }
        }
      }
      .padding(.horizontal, 22)
      .padding(.vertical, 15)

      if let notice {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "exclamationmark.circle")
          Text(notice)
            .font(.system(size: 12))
          Spacer(minLength: 0)
        }
        .foregroundStyle(ChatGPTStyle.warningOrange)
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
      }

      if let renderFailure {
        Text(renderFailure)
          .font(.system(size: 12))
          .foregroundStyle(ChatGPTStyle.dangerRed)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 22)
          .padding(.bottom, 12)
      }

      Divider()

      if let htmlURL {
        LocalUsagePlanWebView(fileURL: htmlURL, reloadID: reloadID) { message in
          renderFailure = message
        }
      } else {
        ContentUnavailableView {
          Label(L10n.string("No saved usage plan"), systemImage: "calendar.badge.clock")
        } description: {
          Text(failure ?? L10n.string("Run the switchgpt-usage-plan skill to create or update your local plan."))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task { reload() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { reload() }
    }
    .onChange(of: subscriptions.lastReloadedAt) { _, _ in reload() }
  }

  private func reload() {
    renderFailure = nil
    let planURL = directory.appendingPathComponent("usage-plan.json")
    let pageURL = directory.appendingPathComponent("usage-plan.html")
    do {
      let plan = try readObject(at: planURL)
      let state = try readObject(at: AccountSubscriptionStore.defaultStore.fileURL)
      guard FileManager.default.fileExists(atPath: pageURL.path) else {
        throw CocoaError(.fileNoSuchFile)
      }
      let pageAttributes = try FileManager.default.attributesOfItem(atPath: pageURL.path)
      guard pageAttributes[.type] as? FileAttributeType == .typeRegular,
        ((pageAttributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 8 * 1024 * 1024
      else { throw CocoaError(.fileReadCorruptFile) }
      let revision = state["revision"].map { String(describing: $0) }
      let planRevision = plan["snapshotRevision"].map { String(describing: $0) }
      let expectedTimestamp = plan["snapshotGeneratedAt"] as? String
      let timeMatches = expectedTimestamp != nil && expectedTimestamp == (state["generatedAt"] as? String)
      if revision != nil ? revision != planRevision : !timeMatches {
        notice = L10n.string("Plan needs updating. Account data or subscription dates changed after this plan was generated.")
      } else {
        notice = nil
      }
      htmlURL = pageURL
      failure = nil
      reloadID = UUID()
    } catch {
      htmlURL = nil
      notice = nil
      failure = L10n.string("The local plan is missing or unreadable. Run the switchgpt-usage-plan skill and reload.")
    }
  }

  private func readObject(at url: URL) throws -> [String: Any] {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 8 * 1024 * 1024,
      let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    else { throw CocoaError(.fileReadCorruptFile) }
    return object
  }
}

private struct LocalUsagePlanWebView: NSViewRepresentable {
  let fileURL: URL
  let reloadID: UUID
  let onFailure: (String) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onFailure: onFailure) }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let script = """
      const nativeStyle = document.createElement('style');
      nativeStyle.textContent = '.sidebar,#export-button,#copy-button{display:none!important}.app{display:block}.main{max-width:none;padding:24px}';
      document.head.appendChild(nativeStyle);
      """
    configuration.userContentController.addUserScript(WKUserScript(
      source: script,
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: true
    ))
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
    context.coordinator.prepareContentRules(for: view)
    return view
  }

  func updateNSView(_ view: WKWebView, context: Context) {
    guard context.coordinator.reloadID != reloadID else { return }
    context.coordinator.reloadID = reloadID
    context.coordinator.onFailure = onFailure
    context.coordinator.directory = fileURL.deletingLastPathComponent().standardizedFileURL
    context.coordinator.pendingFileURL = fileURL
    context.coordinator.loadPendingFile(in: view)
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate {
    var reloadID: UUID?
    var directory: URL?
    var pendingFileURL: URL?
    private var contentRulesReady = false
    var onFailure: (String) -> Void

    init(onFailure: @escaping (String) -> Void) {
      self.onFailure = onFailure
    }

    func prepareContentRules(for view: WKWebView) {
      Task {
        do {
          let rule = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "SwitchGPTLocalUsagePlan",
            encodedContentRuleList: """
              [{"trigger":{"url-filter":"^http"},"action":{"type":"block"}},
               {"trigger":{"url-filter":"^ws"},"action":{"type":"block"}}]
              """
          )
          guard let rule else { throw CocoaError(.coderReadCorrupt) }
          view.configuration.userContentController.add(rule)
          contentRulesReady = true
          loadPendingFile(in: view)
        } catch {
          reportFailure(error)
          view.loadHTMLString(
            "<p>" + L10n.string("Unable to display the local plan. Open HTML in your browser.") + "</p>",
            baseURL: nil
          )
        }
      }
    }

    func loadPendingFile(in view: WKWebView) {
      guard contentRulesReady, let pendingFileURL else { return }
      view.loadFileURL(pendingFileURL, allowingReadAccessTo: pendingFileURL.deletingLastPathComponent())
    }

    private func reportFailure(_ error: Error) {
      let failure = error as NSError
      let detail = failure.userInfo[NSHelpAnchorErrorKey] as? String ?? failure.localizedDescription
      NSLog("[UsagePlan] Local renderer failed %@ %ld %@", failure.domain, failure.code, detail)
      onFailure(
        L10n.string("Unable to display the local plan. Open HTML in your browser.")
          + " (" + failure.domain + " " + String(failure.code) + ") " + detail
      )
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      reportFailure(error)
    }

    func webView(
      _ webView: WKWebView,
      didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      guard (error as NSError).code != NSURLErrorCancelled else { return }
      reportFailure(error)
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
      guard let url = navigationAction.request.url else {
        decisionHandler(.cancel)
        return
      }
      let allowed = url.absoluteString == "about:blank" || (url.isFileURL
        && directory.map { url.standardizedFileURL.path.hasPrefix($0.path + "/") } == true)
      decisionHandler(allowed ? .allow : .cancel)
    }
  }
}
