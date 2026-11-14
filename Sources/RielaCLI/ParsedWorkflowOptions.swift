import ArgumentParser
import Foundation

struct ParsedWorkflowOptions: ParsableArguments {
  @Option var workflowDefinitionDir: String?
  @Option var scope: WorkflowScope = .auto
  @Option var output: WorkflowOutputFormat = .jsonl
  @Flag var executable = false
  @Flag var structure = false
  @Option var host: String?
  @Flag var strictHost = false
  @Option var variables: String?
  @Option var variablesFile: String?
  @Option var nodePatch: String?
  @Option var instance: String?
  @Option var instanceScope: WorkflowInstanceScope?
  @Option var saveInstance: String?
  @Option(name: .customLong("mock-scenario")) var mockScenarioPath: String?
  @Option(help: "Hard per-session step limit; inherited unchanged by cross-workflow child sessions.")
  var maxSteps: Int?
  @Option var maxConcurrency: Int?
  @Option var maxLoopIterations: Int?
  @Flag(help: "Disable the synthesized loop convergence guard (4 gate visits, 2 identical-finding rounds, 3 reserved terminal steps) only for workflows without workflow.loop.")
  var disableDefaultLoopGuard = false
  @Option var defaultTimeoutMs: Int?
  @Option var timeoutMs: Int?
  @Option var agentSilenceWarningMs = 120_000
  @Option var agentSilenceMonitorIntervalMs = 1_000
  @Option var artifactRoot: String?
  @Option var sessionStore: String?
  /// Internal durable-supervisor handoff. It is intentionally parsed with the
  /// normal workflow-run options so an independently monitored child can
  /// resume the exact session reserved in canonical SQLite.
  @Option var resumeSessionId: String?
  @Option(name: [.customLong("working-dir"), .customLong("working-directory")])
  var workingDirectory: String?
  @Option var endpoint: String?
  @Option var authToken: String?
  @Option var authTokenEnv: String?
  @Flag var fromRegistry = false
  @Flag(inversion: .prefixedNo, help: "Allow Codex nodes to use multi-agent supervisor mode for this run.")
  var supervisorMode = false

  private static let runOptionNames: Set<String> = [
    "--variables",
    "--variables-file",
    "--instance",
    "--instance-scope",
    "--save-instance",
    "--mock-scenario",
    "--artifact-root",
    "--session-store",
    "--resume-session-id",
    "--auth-token",
    "--auth-token-env",
    "--max-steps",
    "--max-concurrency",
    "--max-loop-iterations",
    "--disable-default-loop-guard",
    "--default-timeout-ms",
    "--timeout-ms",
    "--agent-silence-warning-ms",
    "--agent-silence-monitor-interval-ms",
    "--supervisor-mode",
    "--no-supervisor-mode"
  ]

  init() {}

  init(_ tokens: [String], allowRunOptions: Bool = false, allowTableOutput: Bool = false) throws {
    if !allowRunOptions, let token = tokens.first(where: Self.isRunOption) {
      let name = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
      throw CLIUsageError("\(name) is supported only by workflow run")
    }

    do {
      self = try Self.parse(tokens)
    } catch {
      throw CLIUsageError(argumentParserUsageMessage(Self.message(for: error)))
    }

    try validateParsedOptions(tokens: tokens, allowTableOutput: allowTableOutput)
  }

  /// Resolved variables reference for the run. `--variables-file` always names a
  /// file (never inline JSON) so its value is prefixed with `@` before it reaches
  /// `JSONReferenceLoader`, which then reads it from disk. `--variables` keeps its
  /// inline-or-path behavior unchanged.
  var variablesReference: String? {
    if let variablesFile {
      return "@" + variablesFile
    }
    return variables
  }

  private static func isRunOption(_ token: String) -> Bool {
    let name = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
    return runOptionNames.contains(name)
  }

  private mutating func validateParsedOptions(tokens: [String], allowTableOutput: Bool) throws {
    if scope == .direct {
      throw CLIUsageError("invalid --scope value 'direct'; expected auto, project, or user")
    }
    if output == .table && !allowTableOutput {
      throw CLIUsageError(
        "`--output table` is only supported for workflow list, workflow status, package search, and package list"
      )
    }
    if let instanceScope, instanceScope == .all {
      throw CLIUsageError("invalid --instance-scope value 'all'; expected project or user")
    }
    try requirePositive(maxSteps, option: "--max-steps")
    try requirePositive(maxConcurrency, option: "--max-concurrency")
    try requirePositive(maxLoopIterations, option: "--max-loop-iterations")
    try requirePositive(defaultTimeoutMs, option: "--default-timeout-ms")
    try requirePositive(timeoutMs, option: "--timeout-ms")
    try requireNonNegative(agentSilenceWarningMs, option: "--agent-silence-warning-ms")
    try requirePositive(agentSilenceMonitorIntervalMs, option: "--agent-silence-monitor-interval-ms")
    if variables != nil && variablesFile != nil {
      throw CLIUsageError("--variables and --variables-file are mutually exclusive")
    }
  }

  private func requirePositive(_ value: Int?, option: String) throws {
    if let value, value <= 0 {
      throw CLIUsageError("\(option) requires a positive integer")
    }
  }

  private func requireNonNegative(_ value: Int?, option: String) throws {
    if let value, value < 0 {
      throw CLIUsageError("\(option) must be a non-negative integer")
    }
  }

}

extension WorkflowOutputFormat: ExpressibleByArgument {}
extension WorkflowInstanceScope: ExpressibleByArgument {}
