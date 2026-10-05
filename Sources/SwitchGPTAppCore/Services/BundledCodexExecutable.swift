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

    // Only run regular bundled files, not symlinks to another location.
    // A missing installation retains a concrete path so callers report their existing error.
    return candidates.first { candidate in
      guard let values = try? candidate.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
        values.isRegularFile == true,
        values.isSymbolicLink != true
      else { return false }
      return FileManager.default.isExecutableFile(atPath: candidate.path)
    }
      ?? candidates[0]
  }
}
