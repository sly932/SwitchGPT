import AppKit
import SwiftUI

struct WindowTitleUpdater: NSViewRepresentable {
  let title: String

  func makeNSView(context: Context) -> TitleView {
    let view = TitleView()
    view.title = title
    return view
  }

  func updateNSView(_ view: TitleView, context: Context) {
    view.title = title
    view.updateWindowTitle()
  }
}

final class TitleView: NSView {
  var title = ""

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateWindowTitle()
  }

  func updateWindowTitle() {
    guard let window, window.title != title else { return }
    window.title = title
  }
}
