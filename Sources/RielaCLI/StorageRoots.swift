import ArgumentParser
import Foundation

enum StorageClientAction: String, CaseIterable, ExpressibleByArgument {
  case compact
}

struct ParsedStorageCommandArguments: ParsableArguments {
  @Option var scope = "auto"
  @Option var workingDir: String?
  @Option var sessionStore: String?
  @Option var memoryRoot: String?
  @Option var cacheRoot: String?
  @Option var kvRoot: String?
  @Option var top = 10
  @Option var output = "text"
  @Flag var apply = false
  @Flag(name: .long) var allowLiveVacuum = false
  @Option var maxBatch = 500
  @Option var abandonedAfterHours = 24
  @Option var resultsMaxAgeDays: Int?
  @Option var resultsMaxTotalBytes: Int64?
  @Option var messagesMaxAgeDays: Int?
  @Option var messagesMaxTotalBytes: Int64?

  func validate(doctor: Bool, tokens: [String]) throws {
    let compactFlags = ["--apply", "--allow-live-vacuum", "--max-batch", "--abandoned-after-hours", "--results-max-age-days",
      "--results-max-total-bytes", "--messages-max-age-days", "--messages-max-total-bytes"]
    if doctor, tokens.contains(where: { token in compactFlags.contains { token == $0 || token.hasPrefix($0 + "=") } }) {
      throw CLIUsageError("compact-only option used with doctor storage")
    }
    if !doctor, tokens.contains(where: { $0 == "--top" || $0.hasPrefix("--top=") }) {
      throw CLIUsageError("--top is only valid for doctor storage")
    }
    guard ["project", "user", "auto"].contains(scope) else { throw CLIUsageError("--scope must be project, user, or auto") }
    guard ["text", "json"].contains(output) else { throw CLIUsageError("--output must be text or json") }
    guard (1...1000).contains(top), (1...10_000).contains(maxBatch) else {
      throw CLIUsageError("--top must be 1...1000 and --max-batch must be 1...10000")
    }
    guard (1...8760).contains(abandonedAfterHours) else { throw CLIUsageError("--abandoned-after-hours must be 1...8760") }
  }
}
