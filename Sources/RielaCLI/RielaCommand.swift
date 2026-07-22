import Foundation
import ArgumentParser
import RielaAddons
import RielaCore
import RielaMemory

public let rielaSwiftMigrationVersion = "0.1.20"

public enum CLIExitCode: Int32, Codable, Equatable, Sendable {
  case success = 0
  case failure = 1
  case usage = 2
  /// A required loop gate is rejected/needs-work/missing or carries blocking
  /// findings (`loop gates --check`). Distinct from operational failure (1).
  case gateCheckFailed = 3
  /// No loop evidence was recorded for the session (`loop gates --check`).
  case noLoopEvidence = 4
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
  case gc(CLICommandOptions)
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
  case register(WorkflowTemporaryRegistrationOptions)
  case registerHelp
  case manifestValidate(WorkflowManifestValidateOptions)
  case checkout(CLICommandOptions)
  case create(CLICommandOptions)
  case selfImprove(CLICommandOptions)
  case version(WorkflowVersionCommandOptions)
  case package(PackageCommand)
}

public enum WorkflowVersionCommandKind: String, Codable, Equatable, Sendable {
  case list
  case show
  case diff
  case restore
}

public struct WorkflowVersionCommandOptions: Equatable, Sendable {
  public var kind: WorkflowVersionCommandKind
  public var workflowName: String
  public var firstReference: String?
  public var secondReference: String?
  public var arguments: [String]

  public init(
    kind: WorkflowVersionCommandKind,
    workflowName: String,
    firstReference: String? = nil,
    secondReference: String? = nil,
    arguments: [String] = []
  ) {
    self.kind = kind
    self.workflowName = workflowName
    self.firstReference = firstReference
    self.secondReference = secondReference
    self.arguments = arguments
  }
}

public enum LoopCommandKind: String, Codable, Sendable {
  case status
  case evidence
  case gates
  case recover
  case list
  case history
  case stats
  case diff
  case findings
  case start
  case promote
  case baseline
  case regress
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
  case autoAction = "auto-action"
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
    let route: any ParsableCommand
    do {
      route = try RielaClientCommandRouter.parseAsRoot(arguments)
    } catch {
      let message = RielaClientCommandRouter.message(for: error)
      if message == rielaSwiftMigrationVersion {
        return .version
      }
      throw CLIUsageError(message)
    }
    switch route {
    case let route as WorkflowRoute:
      return try parseWorkflow(route.passthroughArguments)
    case let route as PackageRoute:
      return try parsePackageRoute(route.passthroughArguments, scope: .package)
    case let route as NodeRoute:
      return .node(try parseNode(route.passthroughArguments))
    case let route as RrunRoute:
      return .node(try parseRrun(route.passthroughArguments))
    case let route as SetupRoute:
      return .setup(try parseSetup(route.passthroughArguments))
    case let route as MemoryRoute:
      return .memory(try parseMemory(route.passthroughArguments))
    case let route as NoteRoute:
      return .note(try parseNote(route.passthroughArguments))
    case let route as InstanceRoute:
      return .instance(try parseInstance(route.passthroughArguments))
    case let route as DoctorRoute:
      return .doctor(try parseGeneric(
        scope: "doctor",
        command: "doctor",
        arguments: route.passthroughArguments,
        allowTableOutput: false,
        defaultOutput: .text
      ))
    case let route as GarbageCollectionRoute:
      return .gc(try parseGeneric(
        scope: "gc",
        command: "gc",
        arguments: route.passthroughArguments,
        allowTableOutput: false,
        defaultOutput: .text
      ))
    case let route as SessionRoute:
      return try parseSession(route.passthroughArguments)
    case let route as LoopRoute:
      return .loop(try parseLoop(route.passthroughArguments))
    case let route as GraphQLRoute:
      return .scoped(try parseScoped(kind: .graphql, arguments: route.passthroughArguments))
    case let route as GQLRoute:
      return .scoped(try parseScoped(kind: .gql, arguments: route.passthroughArguments))
    case let route as HookRoute:
      return .scoped(try parseScoped(kind: .hook, arguments: route.passthroughArguments))
    case let route as EventsRoute:
      return .scoped(try parseScoped(kind: .events, arguments: route.passthroughArguments))
    case let route as ServeRoute:
      return .scoped(try parseScoped(kind: .serve, arguments: route.passthroughArguments))
    case let route as CallStepRoute:
      return .scoped(try parseScoped(kind: .callStep, arguments: route.passthroughArguments))
    case let route as WorkflowCallRoute:
      return .scoped(try parseScoped(kind: .workflowCall, arguments: route.passthroughArguments))
    case is VersionRoute:
      return .version
    case is RielaClientCommandRouter:
      return .version
    default:
      return arguments.contains("--version") ? .version : .help
    }
  }

  private func parseWorkflow(_ arguments: [String]) throws -> RielaCommand {
    if arguments.count == 1, arguments.contains(where: isHelpOption) {
      return .help
    }
    let family = try ParsedWorkflowFamily.parseCLI(arguments)
    if family.subcommand == .package {
      let packageArguments = family.remainder
      if isPackageHelpRequest(packageArguments) {
        return .packageHelp(.workflowPackage)
      }
      if isPackageSubcommandHelpRequest(packageArguments) {
        return .packageHelp(.workflowPackage)
      }
      return .workflow(.package(try parsePackage(scope: "workflow package", arguments: packageArguments)))
    }
    if family.subcommand == .manifest {
      return .workflow(.manifestValidate(try parseWorkflowManifest(family.remainder)))
    }
    if family.subcommand == .list {
      let route = try ParsedTargetAndOptions.parseCLI(family.remainder)
      return .workflow(.list(try parseGeneric(
        scope: "workflow",
        command: "list",
        target: route.target,
        arguments: route.options,
        allowTableOutput: true
      )))
    }
    if family.subcommand == .status {
      let route = try ParsedTargetAndOptions.parseCLI(family.remainder)
      return .workflow(.status(try parseGeneric(
        scope: "workflow",
        command: "status",
        target: route.target,
        arguments: route.options,
        allowTableOutput: true
      )))
    }
    if family.subcommand == .register {
      return try parseWorkflowRegister(
        family.remainder,
        helpRequested: family.remainder.contains(where: isHelpOption)
      )
    }
    if [.versions, .version, .restore].contains(family.subcommand) {
      let versionCommand = try parseWorkflowVersionCommand(
        subcommand: family.subcommand,
        arguments: family.remainder
      )
      return .workflow(.version(versionCommand))
    }
    let route = try ParsedTargetAndOptions.parseCLI(family.remainder)
    if family.subcommand == .run,
       route.target == nil,
       route.options.contains(where: isHelpOption) {
      return .workflow(.runHelp(nil))
    }
    guard let target = route.target else {
      throw CLIUsageError("workflow \(family.subcommand.rawValue) requires a workflow name")
    }
    switch family.subcommand {
    case .validate:
      return .workflow(.validate(try parseValidate(target: target, tokens: route.options)))
    case .inspect:
      return .workflow(.inspect(try parseInspect(target: target, tokens: route.options)))
    case .usage:
      return .workflow(.usage(try parseInspect(target: target, tokens: route.options)))
    case .run:
      if route.options.contains(where: isHelpOption) {
        return .workflow(.runHelp(target))
      }
      return .workflow(.run(try parseRun(target: target, tokens: route.options)))
    case .checkout:
      return .workflow(.checkout(try parseGeneric(
        scope: "workflow",
        command: family.subcommand.rawValue,
        target: target,
        arguments: route.options
      )))
    case .create:
      return .workflow(.create(try parseGeneric(
        scope: "workflow",
        command: family.subcommand.rawValue,
        target: target,
        arguments: route.options
      )))
    case .selfImprove:
      return .workflow(.selfImprove(try parseGeneric(
        scope: "workflow",
        command: family.subcommand.rawValue,
        target: target,
        arguments: route.options
      )))
    case .package, .manifest, .list, .status, .register, .versions, .version, .restore:
      throw CLIUsageError("unsupported target-based workflow route '\(family.subcommand.rawValue)'")
    }
  }

  private func isHelpOption(_ token: String) -> Bool {
    token == "--help" || token == "-h"
  }

  private func parsePackageRoute(
    _ arguments: [String],
    scope: PackageHelpScope
  ) throws -> RielaCommand {
    if isPackageHelpRequest(arguments) || isPackageSubcommandHelpRequest(arguments) {
      return .packageHelp(scope)
    }
    return .package(try parsePackage(scope: scope.rawValue, arguments: arguments))
  }

  private func isPackageHelpRequest(_ arguments: [String]) -> Bool {
    arguments.isEmpty || (
      arguments.count == 1 && arguments.allSatisfy { isHelpOption($0) || $0 == "help" }
    )
  }

  private func isPackageSubcommandHelpRequest(_ arguments: [String]) -> Bool {
    arguments.count >= 2 && arguments.dropFirst().contains(where: isHelpOption)
  }

  private func parseLoop(_ arguments: [String]) throws -> LoopCommand {
    let family = try ParsedLoopFamily.parseCLI(arguments)
    let kind = family.subcommand
    let remaining = family.remainder
    let subcommand = kind.rawValue
    if kind == .list {
      return LoopCommand(
        kind: kind,
        options: try parseGeneric(
          scope: "loop",
          command: subcommand,
          arguments: remaining,
          allowTableOutput: true
        )
      )
    }
    if kind == .baseline {
      let route: ParsedLoopBaselineRoute
      do {
        route = try ParsedLoopBaselineRoute.parseCLI(remaining)
      } catch {
        throw CLIUsageError(
          "usage: riela loop baseline set|show|clear <workflow> [<session-id>] [--note <text>] [--force]"
        )
      }
      return LoopCommand(
        kind: kind,
        options: try parseGeneric(
          scope: "loop",
          command: "baseline",
          target: route.workflowId,
          arguments: [route.action.rawValue] + route.options
        )
      )
    }
    if kind == .diff {
      let route = try ParsedLoopBaselineDiffRoute.parseCLI(remaining)
      if route.baseline {
        return LoopCommand(
          kind: kind,
          options: try parseGeneric(
            scope: "loop",
            command: "diff",
            target: route.workflowId,
            arguments: ["--baseline"] + route.options
          )
        )
      }
    }
    if kind == .diff {
      let route = try ParsedLoopDiffRoute.parseCLI(remaining)
      // session-a is the target; session-b leads the remaining args and is
      // recovered in the command runner (the loop parser threads one target).
      return LoopCommand(
        kind: kind,
        options: try parseGeneric(
          scope: "loop",
          command: subcommand,
          target: route.firstSessionId,
          arguments: [route.secondSessionId] + route.options
        )
      )
    }
    guard !remaining.isEmpty else {
      if kind == .history || kind == .stats || kind == .start || kind == .promote || kind == .regress {
        throw CLIUsageError("loop \(subcommand) requires a workflow id")
      }
      throw CLIUsageError("loop \(subcommand) requires a session id")
    }
    let route = try ParsedLoopTargetRoute.parseCLI(remaining)
    return LoopCommand(
      kind: kind,
      options: try parseGeneric(
        scope: "loop",
        command: subcommand,
        target: route.target,
        arguments: route.options,
        allowTableOutput: kind == .history
      )
    )
  }

  private func parseWorkflowManifest(_ arguments: [String]) throws -> WorkflowManifestValidateOptions {
    let family = try ParsedWorkflowManifestFamily.parseCLI(arguments)
    let parsed = try ParsedWorkflowManifestOptions(family.remainder)
    let manifestPath = try parsed.resolvedManifestPath(
      environment: CLIRuntimeEnvironment.mergedProcessEnvironment()
    )
    return WorkflowManifestValidateOptions(
      manifestPath: manifestPath,
      output: parsed.output,
      executable: parsed.executable,
      workingDirectory: parsed.workingDirectory
    )
  }

  private func parsePackage(scope: String, arguments: [String]) throws -> PackageCommand {
    let family = try ParsedPackageFamily.parseCLI(arguments)
    if family.subcommand == .registry {
      let route = try ParsedPackageRegistryRoute.parseCLI(family.remainder)
      return PackageCommand(
        kind: .registry,
        options: try parseGeneric(
          scope: scope,
          command: PackageCommandKind.registry.rawValue,
          target: route.action.rawValue,
          arguments: route.remainder,
          defaultOutput: .text
        )
      )
    }
    let route = try ParsedTargetAndOptions.parseCLI(family.remainder)
    let kind = family.subcommand
    let options = try parseGeneric(
      scope: scope,
      command: kind.rawValue,
      target: route.target,
      arguments: route.options,
      allowTableOutput: kind == .search || kind == .list,
      defaultOutput: .text
    )
    return PackageCommand(kind: kind, options: options)
  }

  private func parseNode(_ arguments: [String]) throws -> NodeCommand {
    let family = try ParsedNodeFamily.parseCLI(arguments)
    let route = try ParsedTargetAndOptions.parseCLI(family.remainder)
    let kind = family.subcommand
    if kind != .search, kind != .list, route.target == nil {
      throw CLIUsageError("node \(kind.rawValue) requires an add-on or package name")
    }
    let options = try parseGeneric(
      scope: "node",
      command: kind.rawValue,
      target: route.target,
      arguments: route.options,
      allowTableOutput: kind == .search || kind == .list,
      defaultOutput: kind == .run ? .json : .text
    )
    return NodeCommand(kind: kind, options: options)
  }

  private func parseRrun(_ arguments: [String]) throws -> NodeCommand {
    let route = try ParsedTargetAndOptions.parseCLI(arguments)
    guard let target = route.target else {
      throw CLIUsageError("rrun requires an add-on name")
    }
    let options = try parseGeneric(
      scope: "node",
      command: NodeCommandKind.run.rawValue,
      target: target,
      arguments: route.options,
      allowTableOutput: false,
      defaultOutput: .json
    )
    return NodeCommand(kind: .run, options: options)
  }

  private func parseSetup(_ arguments: [String]) throws -> CLICommandOptions {
    let family = try ParsedSetupFamily.parseCLI(arguments)
    return try parseGeneric(
      scope: "setup",
      command: family.subcommand.rawValue,
      arguments: family.remainder,
      allowTableOutput: false,
      defaultOutput: .text
    )
  }

  private func parseInstance(_ arguments: [String]) throws -> CLICommandOptions {
    let family = try ParsedInstanceFamily.parseCLI(arguments)
    let route = try ParsedTargetAndOptions.parseCLI(family.remainder)
    if family.subcommand != .list, route.target == nil {
      throw CLIUsageError("instance \(family.subcommand.rawValue) requires an instance identity")
    }
    return try parseGeneric(
      scope: "instance",
      command: family.subcommand.rawValue,
      target: route.target,
      arguments: route.options,
      allowTableOutput: family.subcommand == .list,
      defaultOutput: family.subcommand == .list ? .table : .json
    )
  }

  private func parseMemory(_ arguments: [String]) throws -> MemoryCommand {
    let family = try ParsedMemoryFamily.parseCLI(arguments)
    let route = try ParsedTargetAndOptions.parseCLI(family.remainder)
    let kind = family.subcommand
    guard let memoryId = route.target else {
      throw CLIUsageError("memory \(kind.rawValue) requires a memory id")
    }
    let options = try parseMemoryOptions(memoryId: memoryId, tokens: route.options)
    switch kind {
    case .save, .update:
      if options.payloadJSON != nil && options.payloadFile != nil {
        throw CLIUsageError("memory \(kind.rawValue) accepts only one of --payload-json or --payload-file")
      }
      if options.payloadJSON == nil && options.payloadFile == nil {
        throw CLIUsageError("memory \(kind.rawValue) requires --payload-json or --payload-file")
      }
      if options.workflowId == nil {
        throw CLIUsageError("memory \(kind.rawValue) requires --workflow-id")
      }
      if kind == .update && options.recordId == nil {
        throw CLIUsageError("memory update requires --record-id")
      }
      if kind == .save && options.clearFiles {
        throw CLIUsageError("memory save does not support --clear-files")
      }
      if options.clearFiles && !options.filePaths.isEmpty {
        throw CLIUsageError("memory \(kind.rawValue) cannot combine --clear-files with --file")
      }
    case .load, .search:
      if options.workflowId == nil && !options.allWorkflows {
        throw CLIUsageError("memory \(kind.rawValue) requires --workflow-id")
      }
    case .metadata, .tags, .relatedIds:
      break
    }
    return MemoryCommand(kind: kind, options: options)
  }

  private func parseNote(_ arguments: [String]) throws -> NoteCommand {
    let family = try ParsedNoteFamily.parseCLI(arguments)
    let kind = family.subcommand
    if kind == .notebook {
      let route = try ParsedNoteNotebookRoute.parseCLI(family.remainder)
      return NoteCommand(
        kind: kind,
        options: try parseGeneric(
          scope: "note",
          command: kind.rawValue,
          target: route.action.rawValue,
          arguments: route.options,
          allowTableOutput: route.action == .list,
          defaultOutput: .text
        )
      )
    }
    if kind == .storage {
      let route = try ParsedNoteStorageRoute.parseCLI(family.remainder)
      return NoteCommand(
        kind: kind,
        options: try parseGeneric(
          scope: "note",
          command: kind.rawValue,
          target: route.action.rawValue,
          arguments: route.options,
          defaultOutput: .text
        )
      )
    }
    if kind == .client {
      let route = try ParsedNoteClientRegistrationRoute.parseCLI(family.remainder)
      return NoteCommand(
        kind: kind,
        options: try parseGeneric(
          scope: "note",
          command: kind.rawValue,
          target: route.action.rawValue,
          arguments: route.options,
          allowTableOutput: route.action == .list,
          defaultOutput: .text
        )
      )
    }
    if kind == .autoAction {
      let route = try ParsedNoteAutoActionRoute.parseCLI(family.remainder)
      return NoteCommand(
        kind: kind,
        options: try parseGeneric(
          scope: "note",
          command: kind.rawValue,
          target: route.action.rawValue,
          arguments: route.options,
          defaultOutput: .text
        )
      )
    }
    let route = try ParsedTargetAndOptions.parseCLI(family.remainder)
    return NoteCommand(
      kind: kind,
      options: try parseGeneric(
        scope: "note",
        command: kind.rawValue,
        target: route.target,
        arguments: route.options,
        allowTableOutput: kind == .list || kind == .search,
        defaultOutput: .text
      )
    )
  }

}
