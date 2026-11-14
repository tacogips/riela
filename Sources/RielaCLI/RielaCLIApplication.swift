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
  public var sessionDiscoveryCommand: SessionDiscoveryCommand
  public var sessionInspectionCommand: SessionInspectionCommand
  public var workflowScaffoldCommand: WorkflowScaffoldCommand
  public var packageCommandRunner: WorkflowPackageCommandRunner
  public var memoryCommandRunner: MemoryCommandRunner
  public var noteCommandRunner: NoteCommandRunner
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
    sessionDiscoveryCommand: SessionDiscoveryCommand = SessionDiscoveryCommand(),
    sessionInspectionCommand: SessionInspectionCommand = SessionInspectionCommand(),
    workflowScaffoldCommand: WorkflowScaffoldCommand = WorkflowScaffoldCommand(),
    packageCommandRunner: WorkflowPackageCommandRunner = WorkflowPackageCommandRunner(),
    memoryCommandRunner: MemoryCommandRunner = MemoryCommandRunner(),
    noteCommandRunner: NoteCommandRunner = NoteCommandRunner(),
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
    self.sessionDiscoveryCommand = sessionDiscoveryCommand
    self.sessionInspectionCommand = sessionInspectionCommand
    self.workflowScaffoldCommand = workflowScaffoldCommand
    self.packageCommandRunner = packageCommandRunner
    self.memoryCommandRunner = memoryCommandRunner
    self.noteCommandRunner = noteCommandRunner
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
      case let .packageHelp(scope):
        return CLICommandResult(exitCode: .success, stdout: packageHelpText(scope: scope))
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
      case let .session(command):
        return await runSession(command)
      case let .loop(command):
        return await loopCommandRunner.run(command)
      case let .package(command):
        return await packageCommandRunner.run(command)
      case let .memory(command):
        return memoryCommandRunner.run(command)
      case let .note(command):
        return await noteCommandRunner.run(command)
      case let .scoped(command):
        return await scopedCommandRunner.run(command)
      }
    } catch let error as CLIUsageError {
      return renderParserFailure(arguments: arguments, error: error)
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: "\(error)")
    }
  }

  private func runSession(_ command: SessionCommand) async -> CLICommandResult {
    switch command {
    case let .rerun(options):
      return await sessionRerunCommand.run(options)
    case let .resume(options):
      return await sessionResumeCommand.run(options)
    case let .list(options), let .latest(options):
      return sessionDiscoveryCommand.run(options)
    case let .progress(options), let .health(options), let .status(options),
         let .stepRuns(options), let .export(options), let .logs(options):
      return sessionInspectionCommand.run(options)
    case let .continueSession(options):
      return await sessionContinueCommand.run(options)
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
  riela workflow package <search|list|status|install|update|remove|checkout|init|validate|pack|publish> [options]
  riela workflow run <workflow> [--variables <json|@file>] [--mock-scenario <path>] [--auto-improve] [--output jsonl|json|text]
  riela package <search|list|status|install|update|remove|checkout|init|validate|pack|publish> [options]
  riela memory save <memory-id> --workflow-id <workflow> --payload-json <json> [--node-id <node>] [--tag <tag>] [--related-id <id>] [--file <path>] [--memory-root <dir>]
  riela memory update <memory-id> --workflow-id <workflow> --record-id <id> --payload-json <json> [--tag <tag>] [--related-id <id>] [--file <path>|--clear-files] [--memory-root <dir>]
  riela memory load|search <memory-id> --workflow-id <workflow> [--match <regex>] [--tag <tag>] [--related-id <id>] [--limit 30] [--memory-root <dir>]
  riela memory metadata|tags|related-ids <memory-id> [--limit 30] [--offset 0] [--sort value-asc|value-desc] [--memory-root <dir>]
  riela note add --body <markdown> [--tag <tag>] [--notebook-id <id>] [--note-root <dir>] [--output json|text]
  riela note edit|show|delete|tag|comment|attach|readonly <note-id> [options]
  riela note list|search [query] [--tag <tag>] [--limit 50] [--note-root <dir>] [--output json|text|table]
  riela note notebook list|create|show|delete [target] [--note-root <dir>] [--output json|text|table]
  riela note storage migrate <file-id|--all> --s3-endpoint <url> --s3-region <region> --s3-bucket <bucket> [--output json|text]
  riela note client register|list|revoke [target] [--direct] [--note-root <dir>] [--output json|text|table]
  riela serve --note-api [--note-root <dir>] [--host <host>] [--port <port>]
  riela session rerun <session-id> <step-id> [--scope project|user|auto] [--output jsonl|json|text]
  riela session resume <session-id> [--max-steps <n>] [--scope project|user|auto] [--output jsonl|json|text]
  riela session list [--workflow <name>] [--status created|running|completed|failed] [--limit 10] [--scope project|user|auto] [--output jsonl|json|text|table]
  riela session latest --workflow <name> [--scope project|user|auto] [--output jsonl|json|text|table]
  riela session progress|health|status|continue|step-runs|export|logs [session-id] [options]
  riela loop status|evidence|gates <session-id> [--session-store <dir>] [--output jsonl|json|text]
  riela loop list [--workflow <name>] [--status active|created|running|completed|failed] [--gate-decision accepted|rejected|needs_work|skipped] [--limit 50] [--session-store <dir>] [--output jsonl|json|text|table]
  riela loop history <workflow> [--status active|created|running|completed|failed] [--gate-decision accepted|rejected|needs_work|skipped] [--limit 50] [--session-store <dir>] [--output jsonl|json|text|table]
  riela loop recover <session-id> --from-step <step-id>|--from-gate <gate-id> [--session-store <dir>] [--output jsonl|json|text]
  riela graphql|gql|hook|events|serve|call-step|workflow-call [command] [target] [options]

Output defaults to JSONL for machine-readable commands. Prefer --output jsonl
for automation, agents, and LLM-driven tool use, especially for workflow run.
Use --output text for human-readable output. Use --output json only when a
legacy caller explicitly requires one non-streaming JSON document after
completion.

The Swift CLI is the production Homebrew runtime. The formula installs only the riela command on macOS; Linux users install CLI release tarballs directly. The macOS Cask installs RielaApp.app and riela together.

"""

func packageHelpText(scope: PackageHelpScope) -> String {
  let commandPrefix = scope == .workflowPackage ? "riela workflow package" : "riela package"
  return """
  Riela package

  Usage:
    \(commandPrefix) init <workflow-or-package-dir> [--package-name <name>] [--workflow-definition-dir <relative-path>] [--overwrite] [--output jsonl|json|text]
    \(commandPrefix) pack <package-dir> [--destination <path>] [--overwrite] [--output jsonl|json|text]
    \(commandPrefix) validate <package-dir|archive.rielapkg|archive.zip> [--output jsonl|json|text]
    \(commandPrefix) install <package-name|package-dir|archive.rielapkg|archive.zip> [--source <path>] [--scope project|user] [--overwrite] [--output jsonl|json|text]
    \(commandPrefix) list|search|status [package-name] [--scope project|user|auto] [--output jsonl|json|text|table]
    \(commandPrefix) run|temp-run <package-name|package-dir|archive.rielapkg|archive.zip> [--mock-scenario <path>] [--output jsonl|json|text]
    \(commandPrefix) registry add|list [options]

  Package archives:
    A .rielapkg or .zip is a portable package archive containing riela-package.json
    and its workflow files. Create one with pack, validate the archive, then install
    it into the project or user package catalog.

  Output:
    Package commands default to human-readable text. Pass --output json or
    --output jsonl when another tool needs structured output.

  Package init:
    init writes riela-package.json with package metadata, workflowDirectory, and
    a content-derived checksum. Edit name, description, and tags if needed, then
    run pack. If <workflow-or-package-dir> contains workflow.json, init packages
    that workflow directly. If it contains exactly one workflows/<name>/workflow.json,
    init uses that workflow automatically; pass --workflow-definition-dir when
    multiple workflows are present.

  Manual manifests:
    If authoring riela-package.json by hand, include name, version, description,
    tags, registry, checksum, checksumAlgorithm, and workflowDirectory. Current
    package validation expects checksumAlgorithm to be md5 for local package
    metadata parity.

  App import:
    RielaApp can import the same package folder, .rielapkg, or .zip from Workflows... >
    Add Workflow/Package..., or launch RielaApp with --import-workflow-or-package <path> --open-workflows.
    The app stores imported packages under the selected profile, so switching
    profiles keeps enabled workflows and imported packages separate.

  Examples:
    \(commandPrefix) init ./my-workflow --package-name my-package
    \(commandPrefix) init ./my-package-source --package-name my-package
    \(commandPrefix) pack ./my-package
    \(commandPrefix) validate ./my-package.rielapkg
    \(commandPrefix) install ./my-package.rielapkg --scope project
    riela workflow run my-package --scope project --output jsonl

  """
}

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
    --max-concurrency <n>          Reserved for fanout execution; not supported yet.
    --max-loop-iterations <n>
    --default-timeout-ms <n>
    --timeout-ms <n>
    --auto-improve                 Retry failed supervised runs and record supervision state.
    --max-supervised-attempts <n>  Maximum auto-improve attempts.
    --monitor-interval-ms <n>      Polling interval for explicit stall detection.
    --stall-timeout-ms <n>         Enable stall detection for local non-agent executions.
    --agent-silence-warning-ms <n> Emit a warning event when an agent backend is silent this long.
                                   Use 0 to disable. Defaults to 120000.
    --agent-silence-monitor-interval-ms <n>
                                   Polling interval for agent silence warnings. Defaults to 1000.
    --output jsonl|json|text       Defaults to jsonl. Prefer jsonl for agents/LLMs; json is legacy and emits only after completion.

  Stall detection:
    --stall-timeout-ms is opt-in. CLI agent and official SDK backends are not
    treated as stalled from missing session heartbeats, because a long LLM
    inference and a provider-side stall are not distinguishable from local
    session records alone. Agent silence warnings are observability hints, not
    cancellation decisions. For codex-agent command observability issues, set
    node variables.codexUnifiedExec to false to pass --disable unified_exec.

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
