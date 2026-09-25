import Foundation

enum BundledCodexBinaryLocator {
  static func resolve(
    resourcesURL: URL = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources"),
    fileManager: FileManager = .default
  ) -> URL {
    let current = resourcesURL.appendingPathComponent("codex-cli/bin/codex")
    if fileManager.isExecutableFile(atPath: current.path) {
      return current
    }

    let legacy = resourcesURL.appendingPathComponent("codex")
    if fileManager.isExecutableFile(atPath: legacy.path) {
      return legacy
    }

    return current
  }
}
