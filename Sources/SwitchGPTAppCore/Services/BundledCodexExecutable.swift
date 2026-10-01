import Foundation

public enum BundledCodexExecutable {
  public static let defaultApplicationURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")

  public static func resolve(in applicationURL: URL = defaultApplicationURL) -> URL {
    let resourcesURL = applicationURL.standardizedFileURL
      .appendingPathComponent("Contents/Resources", isDirectory: true)
    let candidates = [
      "codex-cli/bin/codex",
      "codex-cli/CodexCLI.app/Contents/MacOS/codex",
      "codex",
    ].map { resourcesURL.appendingPathComponent($0) }

    // Only use known bundled entrypoints, including the layout used by older clients.
    // A missing installation retains a concrete path so callers report their existing error.
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
      ?? candidates[0]
  }
}
