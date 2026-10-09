import Foundation

/// Compatibility entrypoint retained for existing callers and tests.
enum ChatGPTCodexCLI {
  static let desktopAppURL = BundledCodexExecutable.defaultApplicationURL

  static func binaryURL(in appURL: URL = desktopAppURL) -> URL {
    BundledCodexExecutable.resolve(in: appURL)
  }
}
