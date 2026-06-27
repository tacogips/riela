import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RielaAdapters
import RielaAddons
import RielaCore

public struct RielaCLIApplication: Sendable {
  public var parser: any CLIArgumentParsing
  public var validateCommand: WorkflowValidateCommand
  public var inspectCommand: WorkflowInspectCommand
  public var runCommand: WorkflowRunCommand
  public var manifestValidateCommand: WorkflowManifestValidateCommand
  public var workflowCatalogCommand: WorkflowCatalogCommand
  public var sessionRerunCommand: SessionRerunCommand
  public var sessionResumeCommand: SessionResumeCommand
  public var sessionInspectionCommand: SessionInspectionCommand
  public var workflowScaffoldCommand: WorkflowScaffoldCommand
  public var packageCommandRunner: WorkflowPackageCommandRunner
  public var memoryCommandRunner: MemoryCommandRunner
  public var loopCommandRunner: LoopCommandRunner
  public var sessionContinueCommand: SessionContinueCommand
  public var scopedCommandRunner: ScopedParityCommandRunner

  public init(
    parser: any CLIArgumentParsing = RielaArgumentParser(),
    validateCommand: WorkflowValidateCommand = WorkflowValidateCommand(),
    inspectCommand: WorkflowInspectCommand = WorkflowInspectCommand(),
    runCommand: WorkflowRunCommand = WorkflowRunCommand(),
    manifestValidateCommand: WorkflowManifestValidateCommand = WorkflowManifestValidateCommand(),
    workflowCatalogCommand: WorkflowCatalogCommand = WorkflowCatalogCommand(),
    sessionRerunCommand: SessionRerunCommand = SessionRerunCommand(),
    sessionResumeCommand: SessionResumeCommand = SessionResumeCommand(),
    sessionInspectionCommand: SessionInspectionCommand = SessionInspectionCommand(),
    workflowScaffoldCommand: WorkflowScaffoldCommand = WorkflowScaffoldCommand(),
    packageCommandRunner: WorkflowPackageCommandRunner = WorkflowPackageCommandRunner(),
    memoryCommandRunner: MemoryCommandRunner = MemoryCommandRunner(),
    loopCommandRunner: LoopCommandRunner = LoopCommandRunner(),
    sessionContinueCommand: SessionContinueCommand = SessionContinueCommand(),
    scopedCommandRunner: ScopedParityCommandRunner = ScopedParityCommandRunner()
  ) {
    self.parser = parser
    self.validateCommand = validateCommand
    self.inspectCommand = inspectCommand
    self.runCommand = runCommand
    self.manifestValidateCommand = manifestValidateCommand
    self.workflowCatalogCommand = workflowCatalogCommand
    self.sessionRerunCommand = sessionRerunCommand
    self.sessionResumeCommand = sessionResumeCommand
    self.sessionInspectionCommand = sessionInspectionCommand
    self.workflowScaffoldCommand = workflowScaffoldCommand
    self.packageCommandRunner = packageCommandRunner
    self.memoryCommandRunner = memoryCommandRunner
    self.loopCommandRunner = loopCommandRunner
    self.sessionContinueCommand = sessionContinueCommand
    self.scopedCommandRunner = scopedCommandRunner
  }

  public func run(_ arguments: [String]) async -> CLICommandResult {
    await run(arguments, environment: nil)
  }

  public func run(_ arguments: [String], environment: [String: String]?) async -> CLICommandResult {
    if let environment {
      return await CLIRuntimeEnvironment.$overrides.withValue(environment) {
        await runParsed(arguments)
      }
    }
    return await runParsed(arguments)
  }

  private func runParsed(_ arguments: [String]) async -> CLICommandResult {
    do {
      switch try parser.parse(arguments) {
      case .help:
        return CLICommandResult(exitCode: .success, stdout: rielaCLIHelpText)
      case .version:
        return CLICommandResult(exitCode: .success, stdout: "\(rielaSwiftMigrationVersion)\n")
      case let .workflow(.validate(options)):
        return await validateCommand.run(options)
      case let .workflow(.inspect(options)):
        return inspectCommand.run(options)
      case let .workflow(.usage(options)):
        return inspectCommand.run(options)
      case let .workflow(.runHelp(target)):
        return CLICommandResult(exitCode: .success, stdout: workflowRunHelpText(target: target))
      case let .workflow(.run(options)):
        return await runCommand.run(options)
      case let .workflow(.list(options)):
        return workflowCatalogCommand.list(options)
      case let .workflow(.status(options)):
        return workflowCatalogCommand.status(options)
      case let .workflow(.manifestValidate(options)):
        return await manifestValidateCommand.run(options)
      case let .workflow(.checkout(options)):
        return workflowScaffoldCommand.checkout(options)
      case let .workflow(.create(options)):
        return workflowScaffoldCommand.create(options)
      case let .workflow(.selfImprove(options)):
        return workflowScaffoldCommand.selfImprove(options)
      case let .workflow(.package(command)):
        return await packageCommandRunner.run(command)
      case let .session(.rerun(options)):
        return await sessionRerunCommand.run(options)
      case let .session(.resume(options)):
        return await sessionResumeCommand.run(options)
      case let .session(.progress(options)):
        return sessionInspectionCommand.run(options)
      case let .session(.health(options)):
        return sessionInspectionCommand.run(options)
      case let .session(.status(options)):
        return sessionInspectionCommand.run(options)
      case let .session(.continueSession(options)):
        return await sessionContinueCommand.run(options)
      case let .session(.stepRuns(options)):
        return sessionInspectionCommand.run(options)
      case let .session(.export(options)):
        return sessionInspectionCommand.run(options)
      case let .session(.logs(options)):
        return sessionInspectionCommand.run(options)
      case let .loop(command):
        return await loopCommandRunner.run(command)
      case let .package(command):
        return await packageCommandRunner.run(command)
      case let .memory(command):
        return memoryCommandRunner.run(command)
      case let .scoped(command):
        return await scopedCommandRunner.run(command)
      }
    } catch let error as CLIUsageError {
      return renderParserFailure(arguments: arguments, error: error)
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: "\(error)")
    }
  }

  private func renderParserFailure(arguments: [String], error: CLIUsageError) -> CLICommandResult {
    guard requestsStructuredOutput(arguments) else {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    }
    guard arguments.first == "workflow" else {
      let result = CLIUnsupportedCommandResult(
        scope: arguments.first ?? "riela",
        command: arguments.dropFirst().first,
        target: arguments.dropFirst(2).first,
        exitCode: CLIExitCode.usage.rawValue,
        error: error.message
      )
      return CLICommandResult(
        exitCode: .usage,
        stdout: (try? jsonString(result)) ?? #"{"error":"failed to encode parser failure","exitCode":2}"# + "\n"
      )
    }
    let subcommand = arguments.count > 1 ? arguments[1] : "workflow"
    let target = parserFailureTarget(arguments: arguments, subcommand: subcommand)
    let exitCode = CLIExitCode.usage.rawValue
    let stdout: String?
    switch subcommand {
    case "validate":
      stdout = try? jsonString(WorkflowValidationFailureResult(
        workflowId: target,
        error: error.message,
        exitCode: exitCode
      ))
    case "inspect":
      stdout = try? jsonString(WorkflowInspectionFailureResult(
        workflowId: target,
        error: error.message,
        exitCode: exitCode
      ))
    case "run":
      stdout = try? jsonString(WorkflowRunFailureResult(
        target: target,
        exitCode: exitCode,
        error: error.message
      ))
    default:
      stdout = try? jsonString(WorkflowRunFailureResult(
        target: target,
        exitCode: exitCode,
        error: error.message
      ))
    }
    return CLICommandResult(
      exitCode: .usage,
      stdout: stdout ?? #"{"error":"failed to encode parser failure","exitCode":2}"# + "\n"
    )
  }

  private func requestsStructuredOutput(_ arguments: [String]) -> Bool {
    for index in arguments.indices {
      if arguments[index] == "--output", index + 1 < arguments.count {
        return arguments[index + 1] != "text" && arguments[index + 1] != "table"
      }
      if arguments[index].hasPrefix("--output=") {
        let value = String(arguments[index].dropFirst("--output=".count))
        return value != "text" && value != "table"
      }
    }
    return true
  }

  private func parserFailureTarget(arguments: [String], subcommand: String) -> String {
    guard arguments.count > 2, !arguments[2].hasPrefix("--") else {
      return "workflow \(subcommand)"
    }
    return arguments[2]
  }

}

public struct CLIUnsupportedCommandResult: Codable, Equatable, Sendable {
  public var scope: String
  public var command: String?
  public var target: String?
  public var exitCode: Int32
  public var error: String

  public init(scope: String, command: String?, target: String?, exitCode: Int32, error: String) {
    self.scope = scope
    self.command = command
    self.target = target
    self.exitCode = exitCode
    self.error = error
  }
}

actor SupervisedScenarioNodeAdapter: NodeAdapter {
  private let scenario: WorkflowMockScenario
  private let fallback: any NodeAdapter
  private var callCounts: [String: Int] = [:]

  init(scenario: WorkflowMockScenario, fallback: any NodeAdapter = DeterministicLocalNodeAdapter()) {
    self.scenario = scenario
    self.fallback = fallback
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    guard let sequence = scenario.responses[input.node.id] else {
      return try await fallback.execute(input, context: context)
    }
    let nextIndex = (callCounts[input.node.id] ?? 0) + 1
    callCounts[input.node.id] = nextIndex
    let response = sequence.isEmpty ? MockNodeResponse() : sequence[min(nextIndex - 1, sequence.count - 1)]
    if response.fail == true {
      throw AdapterExecutionError(.providerError, "scenario forced failure for node '\(input.node.id)'")
    }
    return AdapterExecutionOutput(
      provider: response.provider ?? "scenario-mock",
      model: response.model ?? input.node.model,
      promptText: response.promptText ?? input.promptText,
      completionPassed: response.completionPassed ?? true,
      when: response.when ?? ["always": true],
      payload: response.payload ?? [:]
    )
  }
}

public let rielaCLIHelpText = """
Riela CLI

Usage:
  riela --version
  riela workflow validate <workflow> [--scope project|user|auto] [--output jsonl|json|text]
  riela workflow inspect <workflow> [--scope project|user|auto] [--output jsonl|json|text]
  riela workflow usage <workflow> [--scope project|user|auto] [--output jsonl|json|text]
  riela workflow list|status [--output jsonl|json|text|table]
  riela workflow manifest validate <manifest-path> [--output jsonl|json|text]
  riela workflow checkout|create|self-improve <workflow> [options]
  riela workflow package <search|list|status|install|update|remove|checkout|validate|pack|publish> [options]
  riela workflow run <workflow> [--variables <json|@file>] [--mock-scenario <path>] [--auto-improve] [--output jsonl|json|text]
  riela package <search|list|status|install|update|remove|checkout|validate|pack|publish> [options]
  riela memory save <memory-id> --workflow-id <workflow> --payload-json <json> [--node-id <node>] [--tag <tag>] [--related-id <id>] [--file <path>] [--memory-root <dir>]
  riela memory update <memory-id> --workflow-id <workflow> --record-id <id> --payload-json <json> [--tag <tag>] [--related-id <id>] [--file <path>|--clear-files] [--memory-root <dir>]
  riela memory load|search <memory-id> --workflow-id <workflow> [--match <regex>] [--tag <tag>] [--related-id <id>] [--limit 30] [--memory-root <dir>]
  riela memory metadata|tags|related-ids <memory-id> [--limit 30] [--offset 0] [--sort value-asc|value-desc] [--memory-root <dir>]
  riela session rerun <session-id> <step-id> [--scope project|user|auto] [--output jsonl|json|text]
  riela session resume <session-id> [--scope project|user|auto] [--output jsonl|json|text]
  riela session progress|health|status|continue|step-runs|export|logs [session-id] [options]
  riela loop status|evidence|gates <session-id> [--session-store <dir>] [--output jsonl|json|text]
  riela loop recover <session-id> --from-step <step-id> [--session-store <dir>] [--output jsonl|json|text]
  riela graphql|gql|hook|events|serve|call-step|workflow-call [command] [target] [options]

Output defaults to JSONL for machine-readable commands. Prefer --output jsonl
for automation, agents, and LLM-driven tool use, especially for workflow run.
Use --output text for human-readable output. Use --output json only when a
legacy caller explicitly requires one non-streaming JSON document after
completion.

The Swift CLI is the production Homebrew runtime. The formula installs only the riela command on macOS; Linux users install CLI release tarballs directly. The macOS Cask installs RielaApp.app and riela together.

"""

func workflowRunHelpText(target: String?) -> String {
  let workflow = target ?? "<workflow>"
  return """
  Riela workflow run

  Usage:
    riela workflow run \(workflow) [options]

  Input options:
    --variables <json|@file>       Runtime variables JSON object or a JSON file reference.
    --mock-scenario <path>         Deterministic mock responses for local verification.
    --node-patch <json|@file>      Patch node payloads before running.
    --workflow-definition-dir <dir>
    --scope project|user|auto
    --working-dir <dir>

  Runtime options:
    --session-store <path>         Persist CLI session records under this store.
    --artifact-root <path>         Write runtime artifacts under this root.
    --max-steps <n>
    --max-concurrency <n>
    --max-loop-iterations <n>
    --default-timeout-ms <n>
    --timeout-ms <n>
    --auto-improve                 Retry failed supervised runs and record supervision state.
    --max-supervised-attempts <n>  Maximum auto-improve attempts.
    --monitor-interval-ms <n>      Polling interval for explicit stall detection.
    --stall-timeout-ms <n>         Enable stall detection for local non-agent executions.
    --output jsonl|json|text       Defaults to jsonl. Prefer jsonl for agents/LLMs; json is legacy and emits only after completion.

  Stall detection:
    --stall-timeout-ms is opt-in. CLI agent and official SDK backends are not
    treated as stalled from missing session heartbeats, because a long LLM
    inference and a provider-side stall are not distinguishable from local
    session records alone.

  Remote options:
    --endpoint <url>
    --auth-token <token>
    --auth-token-env <name>
    --from-registry

  Examples:
    riela workflow run \(workflow) --variables '{"workflowInput":{"request":"hello"}}' --output jsonl
    riela workflow run \(workflow) --mock-scenario ./mock-scenario.json --output jsonl

  """
}

func jsonString<T: Encodable>(_ value: T) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  encoder.dateEncodingStrategy = .iso8601
  let data = try encoder.encode(value)
  guard let json = String(data: data, encoding: .utf8) else {
    throw CLIUsageError("failed to encode JSON as UTF-8")
  }
  return json + "\n"
}
