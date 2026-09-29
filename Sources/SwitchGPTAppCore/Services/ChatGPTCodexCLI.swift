import Foundation

/// Selects the Codex CLI bundled with ChatGPT Desktop. Recent desktop builds
/// moved it into codex-cli/bin; older builds keep it directly in Resources.
enum ChatGPTCodexCLI {
  static let desktopAppURL = URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)

  static func binaryURL(in appURL: URL = desktopAppURL) -> URL {
    let resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
    let currentURL = resourcesURL.appendingPathComponent("codex-cli/bin/codex")
    let legacyURL = resourcesURL.appendingPathComponent("codex")

    for candidate in [currentURL, legacyURL] {
      guard let values = try? candidate.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
        values.isRegularFile == true,
        values.isSymbolicLink != true,
        FileManager.default.isExecutableFile(atPath: candidate.path)
      else { continue }
      return candidate
    }

    // Callers retain their existing missing-binary error when neither layout exists.
    return currentURL
  }
}
