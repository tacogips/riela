import ArgumentParser
import Foundation

struct ParsedSessionPruneArguments: ParsableArguments {
  @Option var sessionStore: String
  @Option var artifactRoot: String
  @Option var memoryRoot: String
  @Option(name: .customLong("workflow-id")) var workflowIds: [String] = []
  @Option var retentionHours = 24
  @Option var maxPayloadBytes: Int64 = 268_435_456
  @Flag var dryRun = false
  @Option var output = "json"
}

struct SessionPruneCommandRunner {
  func run(_ arguments: [String]) -> CLICommandResult {
    if arguments.contains("--help") || arguments.contains("-h") {
      return CLICommandResult(exitCode: .success, stdout: ParsedSessionPruneArguments.helpMessage()
        .replacingOccurrences(of: "parsed-session-prune-arguments", with: "riela session prune")
        .replacingOccurrences(of: "parsed_session_prune_arguments", with: "riela session prune") + "\n")
    }
    do {
      let parsed: ParsedSessionPruneArguments
      do { parsed = try ParsedSessionPruneArguments.parse(arguments) } catch { throw CLIUsageError(ParsedSessionPruneArguments.message(for: error)) }
      guard ["json", "jsonl"].contains(parsed.output) else { throw CLIUsageError("session prune requires JSON output") }
      let paths = try TerminalRetentionPaths(sessionRoot: parsed.sessionStore,
        artifactRoot: parsed.artifactRoot, memoryRoot: parsed.memoryRoot)
      let result = try TerminalRetentionExecutor().run(paths: paths, workflows: Set(parsed.workflowIds),
        retentionHours: parsed.retentionHours, maxPayloadBytes: parsed.maxPayloadBytes, dryRun: parsed.dryRun)
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
      return CLICommandResult(exitCode: .success, stdout: (String(data: try encoder.encode(result), encoding: .utf8) ?? "{}") + "\n")
    } catch {
      let message = (error as? CLIUsageError)?.message ?? String(describing: error)
      let data = (try? JSONEncoder().encode(["error": message])) ?? Data()
      return CLICommandResult(exitCode: error is CLIUsageError ? .usage : .failure,
        stdout: (String(data: data, encoding: .utf8) ?? "{}") + "\n")
    }
  }
}
