import Foundation
import RielaAddons
import RielaCore
import RielaMemory

public let rielaSwiftMigrationVersion = "0.1.17"

public enum CLIExitCode: Int32, Codable, Equatable, Sendable {
  case success = 0
  case failure = 1
  case usage = 2
}

public enum WorkflowOutputFormat: String, Codable, Sendable {
  case text
  case json
  case jsonl
  case table
}

public extension WorkflowOutputFormat {
  var isStructured: Bool {
    self == .json || self == .jsonl
  }
}

public enum WorkflowScope: String, Codable, Sendable {
  case auto
  case project
  case user
  case direct
}

public enum RielaCommand: Equatable, Sendable {
  case help
  case packageHelp(PackageHelpScope)
  case version
  case workflow(WorkflowCommand)
  case session(SessionCommand)
  case loop(LoopCommand)
  case package(PackageCommand)
  case node(NodeCommand)
  case setup(CLICommandOptions)
  case memory(MemoryCommand)
  case note(NoteCommand)
  case instance(CLICommandOptions)
  case doctor(CLICommandOptions)
  case scoped(ScopedCommand)
}

public enum PackageHelpScope: String, Codable, Sendable {
  case package
  case workflowPackage = "workflow package"
}

public enum SessionCommand: Equatable, Sendable {
  case rerun(SessionRerunOptions)
  case resume(SessionResumeOptions)
  case list(CLICommandOptions)
  case latest(CLICommandOptions)
  case progress(CLICommandOptions)
  case health(CLICommandOptions)
  case status(CLICommandOptions)
  case continueSession(CLICommandOptions)
  case stepRuns(CLICommandOptions)
  case export(CLICommandOptions)
  case logs(CLICommandOptions)
}

public enum WorkflowCommand: Equatable, Sendable {
  case validate(WorkflowValidateOptions)
  case inspect(WorkflowInspectOptions)
  case usage(WorkflowInspectOptions)
  case run(WorkflowRunOptions)
  case runHelp(String?)
  case list(CLICommandOptions)
  case status(CLICommandOptions)
  case manifestValidate(WorkflowManifestValidateOptions)
  case checkout(CLICommandOptions)
  case create(CLICommandOptions)
  case selfImprove(CLICommandOptions)
  case package(PackageCommand)
}

public enum LoopCommandKind: String, Codable, Sendable {
  case status
  case evidence
  case gates
  case recover
  case list
  case history
}

public struct LoopCommand: Equatable, Sendable {
  public var kind: LoopCommandKind
  public var options: CLICommandOptions

  public init(kind: LoopCommandKind, options: CLICommandOptions) {
    self.kind = kind
    self.options = options
  }
}

public enum NoteCommandKind: String, Codable, Sendable {
  case add
  case edit
  case delete
  case show
  case list
  case search
  case tag
  case comment
  case attach
  case readonly
  case notebook
  case storage
  case client
}

public struct NoteCommand: Equatable, Sendable {
  public var kind: NoteCommandKind
  public var options: CLICommandOptions

  public init(kind: NoteCommandKind, options: CLICommandOptions) {
    self.kind = kind
    self.options = options
  }
}

public struct WorkflowManifestValidateOptions: Equatable, Sendable {
  public var manifestPath: String
  public var output: WorkflowOutputFormat
  public var executable: Bool
  public var workingDirectory: String

  public init(
    manifestPath: String,
    output: WorkflowOutputFormat = .jsonl,
    executable: Bool = false,
    workingDirectory: String = FileManager.default.currentDirectoryPath
  ) {
    self.manifestPath = manifestPath
    self.output = output
    self.executable = executable
    self.workingDirectory = workingDirectory
  }
}

public enum PackageCommandKind: String, Codable, Sendable {
  case search
  case list
  case status
  case install
  case ci
  case update
  case remove
  case checkout
  case run
  case tempRun = "temp-run"
  case initialize = "init"
  case validate
  case pack
  case publish
  case registry
}

public struct PackageCommand: Equatable, Sendable {
  public var kind: PackageCommandKind
  public var options: CLICommandOptions

  public init(kind: PackageCommandKind, options: CLICommandOptions) {
    self.kind = kind
    self.options = options
  }
}

public enum NodeCommandKind: String, Codable, Sendable {
  case search
  case list
  case install
  case run
}

public struct NodeCommand: Equatable, Sendable {
  public var kind: NodeCommandKind
  public var options: CLICommandOptions

  public init(kind: NodeCommandKind, options: CLICommandOptions) {
    self.kind = kind
    self.options = options
  }
}

public enum ScopedCommandKind: String, Codable, Sendable {
  case graphql
  case gql
  case hook
  case events
  case serve
  case callStep = "call-step"
  case workflowCall = "workflow-call"
}

public struct ScopedCommand: Equatable, Sendable {
  public var kind: ScopedCommandKind
  public var options: CLICommandOptions

  public init(kind: ScopedCommandKind, options: CLICommandOptions) {
    self.kind = kind
    self.options = options
  }
}

public struct CLICommandOptions: Equatable, Sendable {
  public var scope: String
  public var command: String?
  public var target: String?
  public var arguments: [String]
  public var output: WorkflowOutputFormat

  public init(
    scope: String,
    command: String? = nil,
    target: String? = nil,
    arguments: [String] = [],
    output: WorkflowOutputFormat = .jsonl
  ) {
    self.scope = scope
    self.command = command
    self.target = target
    self.arguments = arguments
    self.output = output
  }
}

public struct WorkflowResolutionOptions: Codable, Equatable, Sendable {
  public var workflowName: String
  public var scope: WorkflowScope
  public var workflowDefinitionDir: String?
  public var workingDirectory: String

  public init(
    workflowName: String,
    scope: WorkflowScope = .auto,
    workflowDefinitionDir: String? = nil,
    workingDirectory: String = FileManager.default.currentDirectoryPath
  ) {
    self.workflowName = workflowName
    self.scope = workflowDefinitionDir == nil ? scope : .direct
    self.workflowDefinitionDir = workflowDefinitionDir
    self.workingDirectory = workingDirectory
  }
}

public struct WorkflowValidateOptions: Equatable, Sendable {
  public var workflowName: String
  public var resolution: WorkflowResolutionOptions
  public var output: WorkflowOutputFormat
  public var executable: Bool
  public var nodePatch: String?

  public init(
    workflowName: String,
    resolution: WorkflowResolutionOptions,
    output: WorkflowOutputFormat = .jsonl,
    executable: Bool = false,
    nodePatch: String? = nil
  ) {
    self.workflowName = workflowName
    self.resolution = resolution
    self.output = output
    self.executable = executable
    self.nodePatch = nodePatch
  }
}

public struct WorkflowInspectOptions: Equatable, Sendable {
  public var workflowName: String
  public var resolution: WorkflowResolutionOptions
  public var output: WorkflowOutputFormat
  public var structure: Bool

  public init(
    workflowName: String,
    resolution: WorkflowResolutionOptions,
    output: WorkflowOutputFormat = .jsonl,
    structure: Bool = false
  ) {
    self.workflowName = workflowName
    self.resolution = resolution
    self.output = output
    self.structure = structure
  }
}

public struct WorkflowRunOptions: Equatable, Sendable {
  public var target: String
  public var resolution: WorkflowResolutionOptions?
  public var variables: String?
  public var nodePatch: String?
  public var instance: String?
  public var instanceScope: WorkflowInstanceScope?
  public var saveInstance: String?
  public var mockScenarioPath: String?
  public var output: WorkflowOutputFormat
  public var maxSteps: Int?
  public var maxConcurrency: Int?
  public var maxLoopIterations: Int?
  public var defaultTimeoutMs: Int?
  public var timeoutMs: Int?
  public var agentSilenceWarningMs: Int?
  public var agentSilenceMonitorIntervalMs: Int
  public var artifactRoot: String?
  public var sessionStore: String?
  public var workingDirectory: String
  public var explicitWorkingDirectory: Bool
  public var endpoint: String?
  public var authToken: String?
  public var authTokenEnv: String?
  public var fromRegistry: Bool
  public var autoImprove: Bool
  public var autoImprovePolicy: WorkflowAutoImprovePolicy

  public init(
    target: String,
    resolution: WorkflowResolutionOptions? = nil,
    variables: String? = nil,
    nodePatch: String? = nil,
    instance: String? = nil,
    instanceScope: WorkflowInstanceScope? = nil,
    saveInstance: String? = nil,
    mockScenarioPath: String? = nil,
    output: WorkflowOutputFormat = .jsonl,
    maxSteps: Int? = nil,
    maxConcurrency: Int? = nil,
    maxLoopIterations: Int? = nil,
    defaultTimeoutMs: Int? = nil,
    timeoutMs: Int? = nil,
    agentSilenceWarningMs: Int? = 120_000,
    agentSilenceMonitorIntervalMs: Int = 1_000,
    artifactRoot: String? = nil,
    sessionStore: String? = nil,
    workingDirectory: String = FileManager.default.currentDirectoryPath,
    explicitWorkingDirectory: Bool = false,
    endpoint: String? = nil,
    authToken: String? = nil,
    authTokenEnv: String? = nil,
    fromRegistry: Bool = false,
    autoImprove: Bool = false,
    autoImprovePolicy: WorkflowAutoImprovePolicy = WorkflowAutoImprovePolicy()
  ) {
    self.target = target
    self.resolution = resolution
    self.variables = variables
    self.nodePatch = nodePatch
    self.instance = instance
    self.instanceScope = instanceScope
    self.saveInstance = saveInstance
    self.mockScenarioPath = mockScenarioPath
    self.output = output
    self.maxSteps = maxSteps
    self.maxConcurrency = maxConcurrency
    self.maxLoopIterations = maxLoopIterations
    self.defaultTimeoutMs = defaultTimeoutMs
    self.timeoutMs = timeoutMs
    self.agentSilenceWarningMs = agentSilenceWarningMs
    self.agentSilenceMonitorIntervalMs = agentSilenceMonitorIntervalMs
    self.artifactRoot = artifactRoot
    self.sessionStore = sessionStore
    self.workingDirectory = workingDirectory
    self.explicitWorkingDirectory = explicitWorkingDirectory
    self.endpoint = endpoint
    self.authToken = authToken
    self.authTokenEnv = authTokenEnv
    self.fromRegistry = fromRegistry
    self.autoImprove = autoImprove
    self.autoImprovePolicy = autoImprovePolicy
  }
}

public enum WorkflowMutationMode: String, Codable, CaseIterable, Sendable {
  case executionCopy = "execution-copy"
  case inPlace = "in-place"
  case disabled

  public var isForwardedToRemoteExecution: Bool {
    switch self {
    case .executionCopy, .inPlace:
      true
    case .disabled:
      false
    }
  }

  static var acceptedValuesDescription: String {
    Self.allCases.map(\.rawValue).joined(separator: ", ")
  }
}

public struct WorkflowAutoImprovePolicy: Codable, Equatable, Sendable {
  public var maxSupervisedAttempts: Int
  public var maxWorkflowPatches: Int
  public var monitorIntervalMs: Int
  public var stallTimeoutMs: Int
  public var stallDetectionEnabled: Bool
  public var workflowMutationMode: WorkflowMutationMode
  public var nestedSuperviser: Bool

  private enum CodingKeys: String, CodingKey {
    case maxSupervisedAttempts
    case maxWorkflowPatches
    case monitorIntervalMs
    case stallTimeoutMs
    case stallDetectionEnabled
    case workflowMutationMode
    case nestedSuperviser
  }

  public init(
    maxSupervisedAttempts: Int = 3,
    maxWorkflowPatches: Int = 2,
    monitorIntervalMs: Int = 1_000,
    stallTimeoutMs: Int = 30_000,
    stallDetectionEnabled: Bool = false,
    workflowMutationMode: WorkflowMutationMode = .executionCopy,
    nestedSuperviser: Bool = false
  ) {
    self.maxSupervisedAttempts = maxSupervisedAttempts
    self.maxWorkflowPatches = maxWorkflowPatches
    self.monitorIntervalMs = monitorIntervalMs
    self.stallTimeoutMs = stallTimeoutMs
    self.stallDetectionEnabled = stallDetectionEnabled
    self.workflowMutationMode = workflowMutationMode
    self.nestedSuperviser = nestedSuperviser
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    maxSupervisedAttempts = try container.decode(Int.self, forKey: .maxSupervisedAttempts)
    maxWorkflowPatches = try container.decode(Int.self, forKey: .maxWorkflowPatches)
    monitorIntervalMs = try container.decode(Int.self, forKey: .monitorIntervalMs)
    stallTimeoutMs = try container.decode(Int.self, forKey: .stallTimeoutMs)
    stallDetectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .stallDetectionEnabled) ?? false
    workflowMutationMode = try container.decode(WorkflowMutationMode.self, forKey: .workflowMutationMode)
    nestedSuperviser = try container.decode(Bool.self, forKey: .nestedSuperviser)
  }
}

public protocol CLIArgumentParsing: Sendable {
  func parse(_ arguments: [String]) throws -> RielaCommand
}

public struct CLIUsageError: Error, Equatable, Sendable {
  public var message: String

  public init(_ message: String) {
    self.message = message
  }
}

public struct RielaArgumentParser: CLIArgumentParsing {
  public init() {}

  public func parse(_ arguments: [String]) throws -> RielaCommand {
    if arguments == ["--help"] || arguments == ["-h"] || arguments == ["help"] {
      return .help
    }
    if arguments.isEmpty || arguments == ["--version"] || arguments == ["version"] {
      return .version
    }
    if let command = try parseTopLevelCommand(arguments) {
      return command
    }
    guard arguments.first == "workflow" else {
      throw CLIUsageError("expected 'workflow', 'package', 'node', 'rrun', 'setup', 'memory', 'note', 'instance', 'doctor', 'session', 'loop', 'graphql', 'gql', 'hook', 'events', 'serve', or 'call-step' command")
    }
    guard arguments.count >= 2 else {
      throw CLIUsageError("workflow command requires a subcommand and workflow name")
    }
    if arguments[1] == "package" {
      let packageArguments = Array(arguments.dropFirst(2))
      if isPackageHelpRequest(packageArguments) {
        return .packageHelp(.workflowPackage)
      }
      if isPackageSubcommandHelpRequest(packageArguments) {
        return .packageHelp(.workflowPackage)
      }
      return .workflow(.package(try parsePackage(scope: "workflow package", arguments: packageArguments)))
    }
    if arguments[1] == "manifest" {
      return .workflow(.manifestValidate(try parseWorkflowManifest(Array(arguments.dropFirst(2)))))
    }
    if arguments[1] == "list" {
      let remaining = Array(arguments.dropFirst(2))
      let target = remaining.first?.hasPrefix("--") == false ? remaining.first : nil
      let optionTokens = target == nil ? remaining : Array(remaining.dropFirst())
      return .workflow(.list(try parseGeneric(
        scope: "workflow",
        command: "list",
        target: target,
        arguments: optionTokens,
        allowTableOutput: true
      )))
    }
    if arguments[1] == "status" {
      let remaining = Array(arguments.dropFirst(2))
      let target = remaining.first?.hasPrefix("--") == false ? remaining.first : nil
      let optionTokens = target == nil ? remaining : Array(remaining.dropFirst())
      return .workflow(.status(try parseGeneric(
        scope: "workflow",
        command: "status",
        target: target,
        arguments: optionTokens,
        allowTableOutput: true
      )))
    }
    let subcommand = arguments[1]
    guard arguments.count >= 3 else {
      throw CLIUsageError("workflow command requires a subcommand and workflow name")
    }
    if subcommand == "run", isHelpOption(arguments[2]) {
      return .workflow(.runHelp(nil))
    }
    let target = arguments[2]
    guard !target.hasPrefix("--") else {
      throw CLIUsageError("workflow \(subcommand) requires a workflow name")
    }
    let optionTokens = Array(arguments.dropFirst(3))
    switch subcommand {
    case "validate":
      return .workflow(.validate(try parseValidate(target: target, tokens: optionTokens)))
    case "inspect":
      return .workflow(.inspect(try parseInspect(target: target, tokens: optionTokens)))
    case "usage":
      return .workflow(.usage(try parseInspect(target: target, tokens: optionTokens)))
    case "run":
      if optionTokens.contains(where: isHelpOption) {
        return .workflow(.runHelp(target))
      }
      return .workflow(.run(try parseRun(target: target, tokens: optionTokens)))
    case "checkout":
      return .workflow(.checkout(try parseGeneric(scope: "workflow", command: subcommand, target: target, arguments: optionTokens)))
    case "create":
      return .workflow(.create(try parseGeneric(scope: "workflow", command: subcommand, target: target, arguments: optionTokens)))
    case "self-improve":
      return .workflow(.selfImprove(try parseGeneric(scope: "workflow", command: subcommand, target: target, arguments: optionTokens)))
    default:
      throw CLIUsageError("unsupported workflow subcommand '\(subcommand)'")
    }
  }

  private func isHelpOption(_ token: String) -> Bool {
    token == "--help" || token == "-h"
  }

  private func parseTopLevelCommand(_ arguments: [String]) throws -> RielaCommand? {
    if let scopedKind = ScopedCommandKind(rawValue: arguments[0]) {
      return .scoped(try parseScoped(kind: scopedKind, arguments: Array(arguments.dropFirst())))
    }
    if arguments.first == "package" {
      let packageArguments = Array(arguments.dropFirst())
      if isPackageHelpRequest(packageArguments) || isPackageSubcommandHelpRequest(packageArguments) {
        return .packageHelp(.package)
      }
      return .package(try parsePackage(scope: "package", arguments: packageArguments))
    }
    if arguments.first == "node" {
      return .node(try parseNode(Array(arguments.dropFirst())))
    }
    if arguments.first == "rrun" {
      return .node(try parseRrun(Array(arguments.dropFirst())))
    }
    if arguments.first == "setup" {
      return .setup(try parseSetup(Array(arguments.dropFirst())))
    }
    if arguments.first == "memory" {
      return .memory(try parseMemory(Array(arguments.dropFirst())))
    }
    if arguments.first == "note" {
      return .note(try parseNote(Array(arguments.dropFirst())))
    }
    if arguments.first == "instance" {
      return .instance(try parseInstance(Array(arguments.dropFirst())))
    }
    if arguments.first == "doctor" {
      return .doctor(try parseGeneric(
        scope: "doctor",
        command: "doctor",
        arguments: Array(arguments.dropFirst()),
        allowTableOutput: false,
        defaultOutput: .text
      ))
    }
    if arguments.first == "session" {
      return try parseSession(Array(arguments.dropFirst()))
    }
    if arguments.first == "loop" {
      return .loop(try parseLoop(Array(arguments.dropFirst())))
    }
    return nil
  }

  private func isPackageHelpRequest(_ arguments: [String]) -> Bool {
    arguments.isEmpty || (arguments.count == 1 && (isHelpOption(arguments[0]) || arguments[0] == "help"))
  }

  private func isPackageSubcommandHelpRequest(_ arguments: [String]) -> Bool {
    arguments.count >= 2 && arguments.dropFirst().contains(where: isHelpOption)
  }

  private func parseLoop(_ arguments: [String]) throws -> LoopCommand {
    guard let subcommand = arguments.first else {
      throw CLIUsageError("loop command requires a subcommand")
    }
    guard let kind = LoopCommandKind(rawValue: subcommand) else {
      throw CLIUsageError("unsupported loop subcommand '\(subcommand)'")
    }
    if kind == .list {
      return LoopCommand(
        kind: kind,
        options: try parseGeneric(
          scope: "loop",
          command: subcommand,
          arguments: Array(arguments.dropFirst()),
          allowTableOutput: true
        )
      )
    }
    guard arguments.count >= 2, !arguments[1].hasPrefix("--") else {
      if kind == .history {
        throw CLIUsageError("loop history requires a workflow id")
      }
      throw CLIUsageError("loop \(subcommand) requires a session id")
    }
    return LoopCommand(
      kind: kind,
      options: try parseGeneric(
        scope: "loop",
        command: subcommand,
        target: arguments[1],
        arguments: Array(arguments.dropFirst(2)),
        allowTableOutput: kind == .history
      )
    )
  }

  private func parseWorkflowManifest(_ arguments: [String]) throws -> WorkflowManifestValidateOptions {
    guard arguments.first == "validate" else {
      throw CLIUsageError("unsupported workflow manifest subcommand '\(arguments.first ?? "")'")
    }
    var manifestPath: String?
    var optionTokens: [String] = []
    var index = 1
    while index < arguments.count {
      let token = arguments[index]
      if token.hasPrefix("--") {
        if token == "--workflow-manifest" {
          guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
            throw CLIUsageError("--workflow-manifest requires a value")
          }
          manifestPath = arguments[index + 1]
          index += 2
          continue
        }
        optionTokens.append(token)
        if Set(["--output", "--working-dir", "--working-directory"]).contains(token) {
          guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
            throw CLIUsageError("\(token) requires a value")
          }
          optionTokens.append(arguments[index + 1])
          index += 2
        } else {
          index += 1
        }
        continue
      }
      guard manifestPath == nil else {
        throw CLIUsageError("workflow manifest validate accepts at most one manifest path")
      }
      manifestPath = token
      index += 1
    }
    if manifestPath == nil {
      let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
      manifestPath = environment["RIELA_WORKFLOW_MANIFEST"].flatMap { $0.isEmpty ? nil : $0 }
    }
    guard let manifestPath, !manifestPath.isEmpty else {
      throw CLIUsageError("workflow manifest validate requires a manifest path, --workflow-manifest, or RIELA_WORKFLOW_MANIFEST")
    }
    let parsed = try ParsedWorkflowOptions(optionTokens)
    return WorkflowManifestValidateOptions(
      manifestPath: manifestPath,
      output: parsed.output,
      executable: parsed.executable,
      workingDirectory: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    )
  }

  private func parsePackage(scope: String, arguments: [String]) throws -> PackageCommand {
    guard let subcommand = arguments.first else {
      throw CLIUsageError("\(scope) command requires a subcommand")
    }
    guard let kind = PackageCommandKind(rawValue: subcommand) else {
      throw CLIUsageError("unsupported \(scope) subcommand '\(subcommand)'")
    }
    let target = arguments.count >= 2 && !arguments[1].hasPrefix("--") ? arguments[1] : nil
    let optionStart = target == nil ? 1 : 2
    let options = try parseGeneric(
      scope: scope,
      command: subcommand,
      target: target,
      arguments: Array(arguments.dropFirst(optionStart)),
      allowTableOutput: kind == .search || kind == .list,
      defaultOutput: .text
    )
    return PackageCommand(kind: kind, options: options)
  }

  private func parseNode(_ arguments: [String]) throws -> NodeCommand {
    guard let subcommand = arguments.first else {
      throw CLIUsageError("node command requires a subcommand")
    }
    guard let kind = NodeCommandKind(rawValue: subcommand) else {
      throw CLIUsageError("unsupported node subcommand '\(subcommand)'")
    }
    let target = arguments.count >= 2 && !arguments[1].hasPrefix("--") ? arguments[1] : nil
    if kind != .search, kind != .list, target == nil {
      throw CLIUsageError("node \(subcommand) requires an add-on or package name")
    }
    let optionStart = target == nil ? 1 : 2
    let options = try parseGeneric(
      scope: "node",
      command: subcommand,
      target: target,
      arguments: Array(arguments.dropFirst(optionStart)),
      allowTableOutput: kind == .search || kind == .list,
      defaultOutput: kind == .run ? .json : .text
    )
    return NodeCommand(kind: kind, options: options)
  }

  private func parseRrun(_ arguments: [String]) throws -> NodeCommand {
    guard let target = arguments.first, !target.hasPrefix("--") else {
      throw CLIUsageError("rrun requires an add-on name")
    }
    let options = try parseGeneric(
      scope: "node",
      command: NodeCommandKind.run.rawValue,
      target: target,
      arguments: Array(arguments.dropFirst()),
      allowTableOutput: false,
      defaultOutput: .json
    )
    return NodeCommand(kind: .run, options: options)
  }

  private func parseSetup(_ arguments: [String]) throws -> CLICommandOptions {
    guard let subcommand = arguments.first else {
      throw CLIUsageError("setup command requires a subcommand")
    }
    guard subcommand == "container" else {
      throw CLIUsageError("unsupported setup subcommand '\(subcommand)'")
    }
    return try parseGeneric(
      scope: "setup",
      command: subcommand,
      arguments: Array(arguments.dropFirst()),
      allowTableOutput: false,
      defaultOutput: .text
    )
  }

  private func parseInstance(_ arguments: [String]) throws -> CLICommandOptions {
    guard let subcommand = arguments.first else {
      throw CLIUsageError("instance command requires a subcommand")
    }
    let supported = Set(["list", "show", "create", "update", "remove"])
    guard supported.contains(subcommand) else {
      throw CLIUsageError("unsupported instance subcommand '\(subcommand)'")
    }
    let target = arguments.count >= 2 && !arguments[1].hasPrefix("--") ? arguments[1] : nil
    if subcommand != "list", target == nil {
      throw CLIUsageError("instance \(subcommand) requires an instance identity")
    }
    let optionStart = target == nil ? 1 : 2
    return try parseGeneric(
      scope: "instance",
      command: subcommand,
      target: target,
      arguments: Array(arguments.dropFirst(optionStart)),
      allowTableOutput: subcommand == "list",
      defaultOutput: subcommand == "list" ? .table : .json
    )
  }

  private func parseMemory(_ arguments: [String]) throws -> MemoryCommand {
    guard let subcommand = arguments.first else {
      throw CLIUsageError("memory command requires a subcommand")
    }
    guard let kind = MemoryCommandKind(rawValue: subcommand) else {
      throw CLIUsageError("unsupported memory subcommand '\(subcommand)'")
    }
    guard arguments.count >= 2, !arguments[1].hasPrefix("--") else {
      throw CLIUsageError("memory \(subcommand) requires a memory id")
    }
    let options = try parseMemoryOptions(memoryId: arguments[1], tokens: Array(arguments.dropFirst(2)))
    switch kind {
    case .save, .update:
      if options.payloadJSON != nil && options.payloadFile != nil {
        throw CLIUsageError("memory \(subcommand) accepts only one of --payload-json or --payload-file")
      }
      if options.payloadJSON == nil && options.payloadFile == nil {
        throw CLIUsageError("memory \(subcommand) requires --payload-json or --payload-file")
      }
      if options.workflowId == nil {
        throw CLIUsageError("memory \(subcommand) requires --workflow-id")
      }
      if kind == .update && options.recordId == nil {
        throw CLIUsageError("memory update requires --record-id")
      }
      if kind == .save && options.clearFiles {
        throw CLIUsageError("memory save does not support --clear-files")
      }
      if options.clearFiles && !options.filePaths.isEmpty {
        throw CLIUsageError("memory \(subcommand) cannot combine --clear-files with --file")
      }
    case .load, .search:
      if options.workflowId == nil && !options.allWorkflows {
        throw CLIUsageError("memory \(subcommand) requires --workflow-id")
      }
    case .metadata, .tags, .relatedIds:
      break
    }
    return MemoryCommand(kind: kind, options: options)
  }

  private func parseNote(_ arguments: [String]) throws -> NoteCommand {
    guard let subcommand = arguments.first else {
      throw CLIUsageError("note command requires a subcommand")
    }
    guard let kind = NoteCommandKind(rawValue: subcommand) else {
      throw CLIUsageError("unsupported note subcommand '\(subcommand)'")
    }
    if kind == .notebook || kind == .storage || kind == .client {
      guard arguments.count >= 2, !arguments[1].hasPrefix("--") else {
        throw CLIUsageError("note \(subcommand) requires a subcommand")
      }
      let action = arguments[1]
      return NoteCommand(
        kind: kind,
        options: try parseGeneric(
          scope: "note",
          command: subcommand,
          target: action,
          arguments: Array(arguments.dropFirst(2)),
          allowTableOutput: (kind == .notebook || kind == .client) && action == "list",
          defaultOutput: .text
        )
      )
    }
    let target = arguments.count >= 2 && !arguments[1].hasPrefix("--") ? arguments[1] : nil
    let optionStart = target == nil ? 1 : 2
    return NoteCommand(
      kind: kind,
      options: try parseGeneric(
        scope: "note",
        command: subcommand,
        target: target,
        arguments: Array(arguments.dropFirst(optionStart)),
        allowTableOutput: kind == .list || kind == .search,
        defaultOutput: .text
      )
    )
  }

  private func parseMemoryOptions(memoryId: String, tokens: [String]) throws -> MemoryCommandOptions {
    var workflowId: String?
    var allWorkflows = false
    var nodeId: String?
    var recordId: Int64?
    var payloadJSON: String?
    var payloadFile: String?
    var registeredAt: String?
    var matchPatterns: [String] = []
    var tags: [String] = []
    var relatedRecordIds: [Int64] = []
    var filePaths: [String] = []
    var clearFiles = false
    var sortOrder: MemoryValueSortOrder = .valueAsc
    var limit = 30
    var offset = 0
    var databaseRoot: String?
    var workingDirectory = FileManager.default.currentDirectoryPath
    var output: WorkflowOutputFormat = .jsonl
    var index = 0
    while index < tokens.count {
      let token = tokens[index]
      guard token.hasPrefix("-") else {
        throw CLIUsageError("unexpected positional argument '\(token)'")
      }
      if let value = inlineOptionValue(token, prefix: "--output=") {
        output = try parseOutputValue(value, allowTableOutput: false)
        index += 1
        continue
      }
      if let value = inlineOptionValue(token, prefix: "--sort=") {
        sortOrder = try parseMemoryValueSort(value)
        index += 1
        continue
      }
      let value: () throws -> String = {
        guard index + 1 < tokens.count, !tokens[index + 1].hasPrefix("--") else {
          throw CLIUsageError("\(token) requires a value")
        }
        index += 1
        return tokens[index]
      }
      switch token {
      case "--all-workflows":
        allWorkflows = true
      case "--workflow-id":
        workflowId = try value()
      case "--node-id":
        nodeId = try value()
      case "--record-id":
        guard let parsed = Int64(try value()), parsed > 0 else {
          throw CLIUsageError("--record-id must be a positive integer")
        }
        recordId = parsed
      case "--payload-json":
        payloadJSON = try value()
      case "--payload-file":
        payloadFile = try value()
      case "--registered-at":
        registeredAt = try value()
      case "--match", "-e":
        matchPatterns.append(try value())
      case "--tag":
        tags.append(try value())
      case "--related-id", "--related-record-id":
        guard let parsed = Int64(try value()), parsed > 0 else {
          throw CLIUsageError("\(token) must be a positive integer")
        }
        relatedRecordIds.append(parsed)
      case "--file", "--file-path":
        filePaths.append(try value())
      case "--clear-files":
        clearFiles = true
      case "--sort":
        sortOrder = try parseMemoryValueSort(try value())
      case "--limit":
        guard let parsed = Int(try value()), parsed > 0 else {
          throw CLIUsageError("--limit must be a positive integer")
        }
        limit = parsed
      case "--offset":
        guard let parsed = Int(try value()), parsed >= 0 else {
          throw CLIUsageError("--offset must be zero or a positive integer")
        }
        offset = parsed
      case "--database-root", "--memory-root":
        databaseRoot = try value()
      case "--working-dir", "--working-directory":
        workingDirectory = try value()
      case "--output":
        output = try parseOutputValue(try value(), allowTableOutput: false)
      default:
        throw CLIUsageError("unsupported memory option '\(token)'")
      }
      index += 1
    }
    return MemoryCommandOptions(
      memoryId: memoryId,
      workflowId: workflowId,
      allWorkflows: allWorkflows,
      nodeId: nodeId,
      recordId: recordId,
      payloadJSON: payloadJSON,
      payloadFile: payloadFile,
      registeredAt: registeredAt,
      matchPatterns: matchPatterns,
      tags: tags,
      relatedRecordIds: relatedRecordIds,
      filePaths: filePaths,
      clearFiles: clearFiles,
      sortOrder: sortOrder,
      limit: limit,
      offset: offset,
      databaseRoot: databaseRoot,
      workingDirectory: workingDirectory,
      output: output
    )
  }

  private func parseScoped(kind: ScopedCommandKind, arguments: [String]) throws -> ScopedCommand {
    if kind == .callStep || kind == .workflowCall {
      guard arguments.count >= 3,
        !arguments[0].hasPrefix("--"),
        !arguments[1].hasPrefix("--"),
        !arguments[2].hasPrefix("--")
      else {
        throw CLIUsageError("\(kind.rawValue) requires <workflow-id> <workflow-run-id> <step-id>")
      }
      return ScopedCommand(
        kind: kind,
        options: try parseGeneric(
          scope: kind.rawValue,
          command: arguments[0],
          target: arguments[1],
          arguments: Array(arguments.dropFirst(2))
        )
      )
    }
    let command = arguments.first?.hasPrefix("--") == false ? arguments.first : nil
    let targetIndex = command == nil ? 0 : 1
    let target = arguments.count > targetIndex && !arguments[targetIndex].hasPrefix("--") ? arguments[targetIndex] : nil
    let optionStart = target == nil ? targetIndex : targetIndex + 1
    return ScopedCommand(
      kind: kind,
      options: try parseGeneric(
        scope: kind.rawValue,
        command: command,
        target: target,
        arguments: Array(arguments.dropFirst(optionStart))
      )
    )
  }

  private func parseValidate(target: String, tokens: [String]) throws -> WorkflowValidateOptions {
    let parsed = try ParsedWorkflowOptions(tokens)
    try rejectUnsafeScopedWorkflowName(target, parsed: parsed)
    try rejectRemoteResolutionOptions(parsed, subcommand: "validate")
    let resolution = WorkflowResolutionOptions(
      workflowName: target,
      scope: parsed.scope,
      workflowDefinitionDir: parsed.workflowDefinitionDir,
      workingDirectory: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    )
    return WorkflowValidateOptions(
      workflowName: target,
      resolution: resolution,
      output: parsed.output,
      executable: parsed.executable,
      nodePatch: parsed.nodePatch
    )
  }

  private func parseInspect(target: String, tokens: [String]) throws -> WorkflowInspectOptions {
    let parsed = try ParsedWorkflowOptions(tokens)
    try rejectUnsafeScopedWorkflowName(target, parsed: parsed)
    try rejectRemoteResolutionOptions(parsed, subcommand: "inspect")
    let resolution = WorkflowResolutionOptions(
      workflowName: target,
      scope: parsed.scope,
      workflowDefinitionDir: parsed.workflowDefinitionDir,
      workingDirectory: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    )
    return WorkflowInspectOptions(
      workflowName: target,
      resolution: resolution,
      output: parsed.output,
      structure: parsed.structure
    )
  }

  private func parseRun(target: String, tokens: [String]) throws -> WorkflowRunOptions {
    let parsed = try ParsedWorkflowOptions(tokens, allowRunOptions: true)
    if !parsed.fromRegistry {
      try rejectUnsafeScopedRunTarget(target, parsed: parsed)
    }
    let resolution = WorkflowResolutionOptions(
      workflowName: target,
      scope: parsed.scope,
      workflowDefinitionDir: parsed.workflowDefinitionDir,
      workingDirectory: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    )
    return WorkflowRunOptions(
      target: target,
      resolution: resolution,
      variables: parsed.variables,
      nodePatch: parsed.nodePatch,
      instance: parsed.instance,
      instanceScope: parsed.instanceScope,
      saveInstance: parsed.saveInstance,
      mockScenarioPath: parsed.mockScenarioPath,
      output: parsed.output,
      maxSteps: parsed.maxSteps,
      maxConcurrency: parsed.maxConcurrency,
      maxLoopIterations: parsed.maxLoopIterations,
      defaultTimeoutMs: parsed.defaultTimeoutMs,
      timeoutMs: parsed.timeoutMs,
      agentSilenceWarningMs: parsed.agentSilenceWarningMs,
      agentSilenceMonitorIntervalMs: parsed.agentSilenceMonitorIntervalMs,
      artifactRoot: parsed.artifactRoot,
      sessionStore: parsed.sessionStore,
      workingDirectory: resolution.workingDirectory,
      explicitWorkingDirectory: parsed.workingDirectory != nil,
      endpoint: parsed.endpoint,
      authToken: parsed.authToken,
      authTokenEnv: parsed.authTokenEnv,
      fromRegistry: parsed.fromRegistry,
      autoImprove: parsed.autoImprove,
      autoImprovePolicy: parsed.autoImprovePolicy
    )
  }

  private func rejectRemoteResolutionOptions(_ parsed: ParsedWorkflowOptions, subcommand: String) throws {
    if parsed.endpoint != nil || parsed.fromRegistry {
      throw CLIUsageError("remote workflow \(subcommand) is not supported by the local CLI runner")
    }
  }

  private func rejectUnsafeScopedWorkflowName(_ target: String, parsed: ParsedWorkflowOptions) throws {
    guard parsed.workflowDefinitionDir == nil,
      !isSafeScopedWorkflowName(target),
      !WorkflowPackageManifestValidator.isSafePackageName(target)
    else {
      return
    }
    throw CLIUsageError("invalid scoped workflow or package name '\(target)'")
  }

  private func rejectUnsafeScopedRunTarget(_ target: String, parsed: ParsedWorkflowOptions) throws {
    guard parsed.workflowDefinitionDir == nil, !isTemporaryWorkflowRunTarget(target, workingDirectory: parsed.workingDirectory) else {
      return
    }
    try rejectUnsafeScopedWorkflowName(target, parsed: parsed)
  }

  private func isTemporaryWorkflowRunTarget(_ target: String, workingDirectory: String?) -> Bool {
    if target.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
      return true
    }
    let directory = URL(fileURLWithPath: workingDirectory ?? FileManager.default.currentDirectoryPath)
    let url = absoluteURL(target, relativeTo: directory)
    return FileManager.default.fileExists(atPath: url.path) && url.pathExtension == "json"
  }
}
