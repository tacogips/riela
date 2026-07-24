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
  public var workflowMutableRegistrationCommand: WorkflowMutableRegistrationCommand
  public var sessionRerunCommand: SessionRerunCommand
  public var sessionResumeCommand: SessionResumeCommand
  public var sessionDiscoveryCommand: SessionDiscoveryCommand
  public var sessionInspectionCommand: SessionInspectionCommand
  public var workflowScaffoldCommand: WorkflowScaffoldCommand
  public var workflowVersionCommand: WorkflowVersionCommand
  public var packageCommandRunner: WorkflowPackageCommandRunner
  public var nodeCommandRunner: NodeCommandRunner
  public var setupContainerCommand: SetupContainerCommand
  public var memoryCommandRunner: MemoryCommandRunner
  public var noteCommandRunner: NoteCommandRunner
  public var instanceCommandRunner: InstanceCommandRunner
  public var doctorCommand: DoctorCommand
  public var garbageCollectionCommand: GarbageCollectionCommand
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
    workflowMutableRegistrationCommand: WorkflowMutableRegistrationCommand = WorkflowMutableRegistrationCommand(),
    sessionRerunCommand: SessionRerunCommand = SessionRerunCommand(),
    sessionResumeCommand: SessionResumeCommand = SessionResumeCommand(),
    sessionDiscoveryCommand: SessionDiscoveryCommand = SessionDiscoveryCommand(),
    sessionInspectionCommand: SessionInspectionCommand = SessionInspectionCommand(),
    workflowScaffoldCommand: WorkflowScaffoldCommand = WorkflowScaffoldCommand(),
    workflowVersionCommand: WorkflowVersionCommand = WorkflowVersionCommand(),
    packageCommandRunner: WorkflowPackageCommandRunner = WorkflowPackageCommandRunner(),
    nodeCommandRunner: NodeCommandRunner = NodeCommandRunner(),
    setupContainerCommand: SetupContainerCommand = SetupContainerCommand(),
    memoryCommandRunner: MemoryCommandRunner = MemoryCommandRunner(),
    noteCommandRunner: NoteCommandRunner = NoteCommandRunner(),
    instanceCommandRunner: InstanceCommandRunner = InstanceCommandRunner(),
    doctorCommand: DoctorCommand = DoctorCommand(),
    garbageCollectionCommand: GarbageCollectionCommand = GarbageCollectionCommand(),
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
    self.workflowMutableRegistrationCommand = workflowMutableRegistrationCommand
    self.sessionRerunCommand = sessionRerunCommand
    self.sessionResumeCommand = sessionResumeCommand
    self.sessionDiscoveryCommand = sessionDiscoveryCommand
    self.sessionInspectionCommand = sessionInspectionCommand
    self.workflowScaffoldCommand = workflowScaffoldCommand
    self.workflowVersionCommand = workflowVersionCommand
    self.packageCommandRunner = packageCommandRunner
    self.nodeCommandRunner = nodeCommandRunner
    self.setupContainerCommand = setupContainerCommand
    self.memoryCommandRunner = memoryCommandRunner
    self.noteCommandRunner = noteCommandRunner
    self.instanceCommandRunner = instanceCommandRunner
    self.doctorCommand = doctorCommand
    self.garbageCollectionCommand = garbageCollectionCommand
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
      case let .workflow(command):
        return await runWorkflow(command)
      case let .session(command):
        return await runSession(command)
      case let .loop(command):
        return await loopCommandRunner.run(command)
      case let .package(command):
        return await packageCommandRunner.run(command)
      case let .node(command):
        return await nodeCommandRunner.run(command)
      case let .setup(options):
        return await setupContainerCommand.run(options)
      case let .memory(command):
        return memoryCommandRunner.run(command)
      case let .note(command):
        return await noteCommandRunner.run(command)
      case let .instance(options):
        return instanceCommandRunner.run(options)
      case let .doctor(options):
        return await doctorCommand.run(options)
      case let .gc(options):
        return garbageCollectionCommand.run(options)
      case let .scoped(command):
        return await scopedCommandRunner.run(command)
      }
    } catch let error as CLIUsageError {
      return renderParserFailure(arguments: arguments, error: error)
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: "\(error)")
    }
  }

  private func runWorkflow(_ command: WorkflowCommand) async -> CLICommandResult {
    switch command {
    case let .validate(options):
      return await validateCommand.run(options)
    case let .inspect(options), let .usage(options):
      return await inspectCommand.run(options)
    case let .runHelp(target):
      return CLICommandResult(exitCode: .success, stdout: workflowRunHelpText(target: target))
    case let .run(options):
      return await runCommand.run(options)
    case let .list(options):
      return workflowCatalogCommand.list(options)
    case let .status(options):
      return workflowCatalogCommand.status(options)
    case let .register(options):
      return workflowMutableRegistrationCommand.run(options)
    case .registerHelp:
      return CLICommandResult(exitCode: .success, stdout: workflowRegisterHelpText)
    case let .registry(options):
      return WorkflowRegistryCLICommand().run(options)
    case let .manifestValidate(options):
      return await manifestValidateCommand.run(options)
    case let .checkout(options):
      return workflowScaffoldCommand.checkout(options)
    case let .create(options):
      return workflowScaffoldCommand.create(options)
    case let .selfImprove(options):
      return workflowScaffoldCommand.selfImprove(options)
    case let .version(options):
      return workflowVersionCommand.run(options)
    case let .package(command):
      return await packageCommandRunner.run(command)
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
      return await sessionInspectionCommand.run(options)
    case let .continueSession(options):
      return await sessionContinueCommand.run(options)
    }
  }

  private func renderParserFailure(arguments: [String], error: CLIUsageError) -> CLICommandResult {
    guard requestsStructuredOutput(arguments) else {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    }
    let invocation = ParsedClientInvocation.parseCLI(arguments)
    guard invocation.scope == "workflow" else {
      let result = CLIUnsupportedCommandResult(
        scope: invocation.scope,
        command: invocation.command,
        target: invocation.target,
        exitCode: CLIExitCode.usage.rawValue,
        error: error.message
      )
      return CLICommandResult(
        exitCode: .usage,
        stdout: (try? jsonString(result)) ?? #"{"error":"failed to encode parser failure","exitCode":2}"# + "\n"
      )
    }
    let subcommand = invocation.command ?? "workflow"
    let target = invocation.target ?? "workflow \(subcommand)"
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
    let output = try? parseOutputOnly(arguments, allowTableOutput: true, defaultOutput: .json)
    return output != .text && output != .table
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
  riela workflow list [query] [--scope project|user|auto] [--exclude-mutable] [--activation active|deactivated] [--provenance mutable|immutable] [--output jsonl|json|text|table]
    (--exclude-temporary remains a deprecated alias for --exclude-mutable)
  riela workflow status <workflow> [--output jsonl|json|text|table]
  riela workflow register <path> --mutable [--overwrite] [--working-dir <dir>] [--output jsonl|json|text|table]
    (--temporary remains a deprecated alias for --mutable)
  riela workflow update <workflow> <path> [--scope auto|project|user] [--origin-id <id>] [--output jsonl|json|text]
  riela workflow delete|activate|deactivate <workflow> [--scope auto|project|user] [--origin-id <id>] [--output jsonl|json|text]
  riela workflow consolidate --source <workflow> --source <workflow> --replacement <path> --retire deactivate|delete [--output jsonl|json|text]
  riela workflow manifest validate <manifest-path> [--output jsonl|json|text]
  riela workflow checkout|create|self-improve <workflow> [options]
  riela workflow versions <workflow> [--output json|text]
  riela workflow version show <workflow> <snapshot-id> [--output json|text]
  riela workflow version diff <workflow> <from> <to> [--output json|text]
  riela workflow restore <workflow> <snapshot-id> [--yes] [--output json|text]
  riela workflow package <search|list|status|install|ci|update|remove|checkout|init|validate|pack|publish> [options]
  riela workflow run <workflow> [--variables <json|@file>] [--instance <name>] [--mock-scenario <path>] [--auto-improve] [--output jsonl|json|text]
  riela instance list|show|create|update|remove [identity] [--workflow <id>] [--scope project|user|all] [--output json|jsonl|text|table]
  riela doctor [--scope project|user|auto] [--working-dir <dir>] [--output json|text]
  riela gc [--retention-days <days>] [--scope user|project|all] [--working-dir <dir>] [--dry-run] [--output json|text]
  riela package <search|list|status|install|ci|update|remove|checkout|init|validate|pack|publish> [options]
  riela node search [query] [--scope project|user|auto] [--registry default] [--refresh] [--output json|text|table]
  riela node list [query] [--scope project|user|auto] [--registry default] [--refresh] [--output json|text|table]
  riela node install <addon-or-package> [--scope project|user] [--registry default] [--source <path>] [--output json|text]
  riela node run <addon-name> [--variables <json|@file>] [--mock-scenario <path>] [--output json|text]
  riela rrun <addon-name> [--variables <json|@file>] [--mock-scenario <path>] [--output json|text]
  riela setup container [--yes] [--dry-run] [--print-script] [--open-installer] [--output json|text]
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
  riela serve [--host <host>] [--port <port>]
  riela serve --note-api [--note-root <dir>] [--host <host>] [--port <port>]
  riela session rerun <session-id> <step-id> [--scope project|user|auto] [--output jsonl|json|text]
  riela session resume <session-id> [--max-steps <n>] [--scope project|user|auto] [--output jsonl|json|text]
  riela session list [--workflow <name>] [--status created|running|completed|failed] [--limit 10] [--scope project|user|auto] [--output jsonl|json|text|table]
  riela session latest --workflow <name> [--scope project|user|auto] [--output jsonl|json|text|table]
  riela session progress <session-id> [--follow] [--poll-interval 2.0] [--include-children] [--output text|jsonl|json]
  riela session health <session-id> [--output text|jsonl|json]  # backendActivity: active|quiet|stalled-suspect|unknown
  riela session status|continue|step-runs|export|logs <session-id> [options]
  riela loop status|evidence|gates <session-id> [--session-store <dir>] [--output jsonl|json|text]
  riela loop list [--workflow <name>] [--status active|created|running|completed|failed] [--gate-decision accepted|rejected|needs_work|skipped] [--limit 50] [--session-store <dir>] [--output jsonl|json|text|table]
  riela loop history <workflow> [--status active|created|running|completed|failed] [--gate-decision accepted|rejected|needs_work|skipped] [--limit 50] [--session-store <dir>] [--output jsonl|json|text|table]
  riela loop recover <session-id> --from-step <step-id>|--from-gate <gate-id> [--session-store <dir>] [--output jsonl|json|text]
  riela loop start <workflow> [--var k=v ...] [workflow run options] [--output jsonl|json|text]
  riela loop promote <workflow> [--scope project|user|auto] [--workflow-definition-dir <dir>] [--output jsonl|json|text]
  riela graphql|gql|hook|events|serve|call-step|workflow-call [command] [target] [options]

Output defaults to JSONL for machine-readable commands. Prefer --output jsonl
for automation, agents, and LLM-driven tool use, especially for workflow run.
Use --output text for human-readable output. Use --output json only when a
legacy caller explicitly requires one non-streaming JSON document after
completion.

Session progress observers are read-only. `--follow` and `--poll-interval`
(finite `0.1...3600`, default `2.0`) are progress-only; follow rejects
`--output json`, emits one text or JSONL digest per refresh, and exits after the
requested session or included child tree is terminal.

Bare `riela serve` starts an HTTP listener and remains active until SIGINT or
SIGTERM. The default address is 127.0.0.1:8787. The status, health, overview,
and graphql serve subcommands remain one-shot commands.

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
    \(commandPrefix) install [package-name|package-dir|archive.rielapkg|archive.zip] [--source <path>] [--locked] [--scope project|user] [--overwrite] [--pre-install-check off|warn|reject] [--output jsonl|json|text]
    \(commandPrefix) ci [package-name] [--scope project|user] [--working-dir <dir>] [--output jsonl|json|text]
    \(commandPrefix) list|search|status [package-name] [--scope project|user|auto] [--tag <tag>] [--backend <backend>] [--limit <n>] [--output jsonl|json|text|table]
    \(commandPrefix) publish <workflow-dir> [--package-id <id>] [--registry <id|url>] [--registry-local-path <path>] [--branch <branch>] [--create-pr] [--pr-base <branch>] [--yes] [--dry-run] [--output jsonl|json|text]
    \(commandPrefix) run|temp-run <package-name|package-dir|archive.rielapkg|archive.zip> [--mock-scenario <path>] [--output jsonl|json|text]
    \(commandPrefix) registry add|list|sync|index [options]

  Package archives:
    A .rielapkg or .zip is a portable package archive containing riela-package.json
    and its workflow files. Create one with pack, validate the archive, then install
    it into the project or user package catalog.

  Registry index:
    registry index <registry-root> writes registry-index.json from packages/* manifests
    for GitHub-hosted distributed registry search. Use --destination <path> to
    write elsewhere, --registry <id> and --registry-url <url> to stamp metadata.
    Use --check in CI to fail when the checked-in registry-index.json is stale.

  Lockfile installs:
    install writes riela-lock.json with package checksums, integrity metadata,
    archive sha256 pins, and add-on content digests. install with no package,
    install --locked, and ci reinstall locked packages from that file and verify
    locked archive digests before installing.

  Pre-install checks:
    --pre-install-check warn|reject opts into an offline static content scan of
    the staged package before any file is installed. warn reports findings and
    proceeds; reject blocks install on high/critical findings and leaves nothing
    written. --pre-install-check-container docker|podman|auto adds an optional
    no-network container inspection (read-only mount, no privileged mode, secret
    env filtered); it degrades to a diagnostic when no runtime is present.
    Finding excerpts are redacted and never contain full secret values.

  Publish:
    publish computes a real md5 checksum over the staged workflow, writes a
    normalized riela-package.json, and derives backend hints from node payloads.
    With a git registry checkout it verifies the remote, refuses a dirty
    worktree, then pushes directly (permission-probed) or opens a pull request
    with --create-pr (--pr-base selects the base branch). --dry-run mutates
    nothing.

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
    \(commandPrefix) ci --scope project
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
    --variables-file <path>        Read runtime variables from a JSON file. Mutually exclusive with --variables.
    --instance <name>              Run a saved workflow instance. Defaults to the implicit default instance.
    --instance-scope project|user  Restrict instance lookup to one persistence scope.
    --save-instance <name>         Save the materialized temporary instance before the local run.
    --mock-scenario <path>         Deterministic mock responses for local verification.
    --node-patch <json|@file>      Patch node payloads before running.
    --workflow-definition-dir <dir>
    --scope project|user|auto
    --working-dir <dir>

  Runtime options:
    --session-store <path>         Persist CLI session records under this store.
    --artifact-root <path>         Write runtime artifacts under this root.
    --max-steps <n>               Hard per-session limit inherited by child workflows.
    --disable-default-loop-guard  Disable the synthesized loop convergence guard (4 gate
                                  visits, 2 identical-finding rounds, 3 terminal steps)
                                  only for workflows without workflow.loop.
    --max-concurrency <n>          Cap concurrent fanout branch execution.
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
    cancellation decisions. codex-agent disables unified_exec by default for
    command observability; set node variables.codexUnifiedExec to true only when
    a workflow explicitly needs Codex unified exec shell-state persistence.

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
