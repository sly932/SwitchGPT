import Foundation
import SwitchGPTAppCore

@main
struct SwitchGPTCLI {
  static let help = """
    Usage: switchgpt <quota|usage> [--cached] [--state-file PATH] [--timeout SECONDS]

      quota     All saved accounts: plan, remaining percentages, reset times,
                credits and reset-card inventory (count and expiry metadata).
      usage     Quota plus all supported token activity and daily usage buckets.
      --cached  Read saved snapshots only; do not contact account services.
      --state-file PATH
                Use another private preview-state.json (default: SwitchGPT-sly).
      --timeout SECONDS
                Per-account live timeout, 1–120 (default: 20).

    JSON on stdout. Dates are ISO 8601 UTC; missing fields mean unknown, never zero.
    An account failure is an entry with status=error, not a command failure.
    Exit codes: 0 report produced (even all accounts failed), 1 state/output error,
    2 invalid arguments. Queries never update the app's saved state or switch accounts.
    """

  static func main() async {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty || args == ["--help"] || args == ["-h"] {
      print(help)
      return
    }
    guard let command = args.first, ["quota", "usage"].contains(command) else {
      fail(code: "invalid_arguments", message: help, exitCode: 2)
    }
    var cached = false
    var stateStore = PreviewStateFileStore.defaultStore
    var timeout = 20
    var index = 1
    while index < args.count {
      switch args[index] {
      case "--cached": cached = true
      case "--state-file":
        index += 1
        guard index < args.count, !args[index].hasPrefix("--") else {
          fail(code: "invalid_arguments", message: "--state-file requires a path.", exitCode: 2)
        }
        stateStore = PreviewStateFileStore(fileURL: URL(fileURLWithPath: args[index]))
      case "--timeout":
        index += 1
        guard index < args.count, let seconds = Int(args[index]), (1...120).contains(seconds) else {
          fail(code: "invalid_arguments", message: "--timeout requires 1–120 seconds.", exitCode: 2)
        }
        timeout = seconds
      default:
        fail(code: "invalid_arguments", message: "Unknown option. Use --help.", exitCode: 2)
      }
      index += 1
    }
    let state: PreviewState?
    do { state = try stateStore.load() } catch {
      fail(code: "state_unavailable", message: "Cannot read saved accounts. Check the state file and its private permissions.", exitCode: 1)
    }
    let service = AccountReportService(reader: CodexAppServerQuotaReader(
      timeout: .seconds(timeout), includeTokenActivity: command == "usage"))
    let report = await service.report(
      accounts: state?.accounts ?? [], includeUsage: command == "usage", cached: cached)
    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(report)
      try FileHandle.standardOutput.write(contentsOf: data + Data([0x0A]))
    } catch {
      fail(code: "output_failed", message: "Could not write the JSON report.", exitCode: 1)
    }
  }

  static func fail(code: String, message: String, exitCode: Int32) -> Never {
    let data = try? JSONSerialization.data(withJSONObject: [
      "error": ["code": code, "message": message]
    ], options: [.sortedKeys])
    if let data { try? FileHandle.standardError.write(contentsOf: data + Data([0x0A])) }
    exit(exitCode)
  }
}
