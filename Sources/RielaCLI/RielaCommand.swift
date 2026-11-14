import Foundation
import RielaAddons
import RielaCore

public let rielaSwiftMigrationVersion = "0.1.2"

public enum CLIExitCode: Int32, Codable, Equatable, Sendable {
  case success = 0
  case failure = 1
  case usage = 2
}

public enum WorkflowOutputFormat: String, Codable, Sendable {
  case text
  case json
  case table
}

public enum WorkflowScope: String, Codable, Sendable {
  case auto
  case project
  case user
  case direct
}

public enum RielaCommand: Equatable, Sendable {
  case help
  case version
  case workflow(WorkflowCommand)
  case session(SessionCommand)
  case package(PackageCommand)
  case scoped(ScopedCommand)
}

public enum SessionCommand: Equatable, Sendable {
  case rerun(SessionRerunOptions)
  case resume(SessionResumeOptions)
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
  case list(CLICommandOptions)
  case status(CLICommandOptions)
  case manifestValidate(WorkflowManifestValidateOptions)
  case checkout(CLICommandOptions)
  case create(CLICommandOptions)
  case selfImprove(CLICommandOptions)
  case package(PackageCommand)
}

public struct WorkflowManifestValidateOptions: Equatable, Sendable {
  public var manifestPath: String
  public var output: WorkflowOutputFormat
  public var executable: Bool
  public var workingDirectory: String

  public init(
    manifestPath: String,
    output: WorkflowOutputFormat = .text,
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
  case update
  case remove
  case checkout
  case run
  case tempRun = "temp-run"
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
    output: WorkflowOutputFormat = .text
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
    output: WorkflowOutputFormat = .text,
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
    output: WorkflowOutputFormat = .text,
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
  public var mockScenarioPath: String?
  public var output: WorkflowOutputFormat
  public var maxSteps: Int?
  public var maxConcurrency: Int?
  public var maxLoopIterations: Int?
  public var defaultTimeoutMs: Int?
  public var timeoutMs: Int?
  public var artifactRoot: String?
  public var sessionStore: String?
  public var workingDirectory: String
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
    mockScenarioPath: String? = nil,
    output: WorkflowOutputFormat = .text,
    maxSteps: Int? = nil,
    maxConcurrency: Int? = nil,
    maxLoopIterations: Int? = nil,
    defaultTimeoutMs: Int? = nil,
    timeoutMs: Int? = nil,
    artifactRoot: String? = nil,
    sessionStore: String? = nil,
    workingDirectory: String = FileManager.default.currentDirectoryPath,
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
    self.mockScenarioPath = mockScenarioPath
    self.output = output
    self.maxSteps = maxSteps
    self.maxConcurrency = maxConcurrency
    self.maxLoopIterations = maxLoopIterations
    self.defaultTimeoutMs = defaultTimeoutMs
    self.timeoutMs = timeoutMs
    self.artifactRoot = artifactRoot
    self.sessionStore = sessionStore
    self.workingDirectory = workingDirectory
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
  public var workflowMutationMode: WorkflowMutationMode
  public var nestedSuperviser: Bool

  public init(
    maxSupervisedAttempts: Int = 3,
    maxWorkflowPatches: Int = 2,
    monitorIntervalMs: Int = 1_000,
    stallTimeoutMs: Int = 30_000,
    workflowMutationMode: WorkflowMutationMode = .executionCopy,
    nestedSuperviser: Bool = false
  ) {
    self.maxSupervisedAttempts = maxSupervisedAttempts
    self.maxWorkflowPatches = maxWorkflowPatches
    self.monitorIntervalMs = monitorIntervalMs
    self.stallTimeoutMs = stallTimeoutMs
    self.workflowMutationMode = workflowMutationMode
    self.nestedSuperviser = nestedSuperviser
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
    if let scopedKind = ScopedCommandKind(rawValue: arguments[0]) {
      return .scoped(try parseScoped(kind: scopedKind, arguments: Array(arguments.dropFirst())))
    }
    if arguments.first == "package" {
      return .package(try parsePackage(scope: "package", arguments: Array(arguments.dropFirst())))
    }
    if arguments.first == "session" {
      return try parseSession(Array(arguments.dropFirst()))
    }
    guard arguments.first == "workflow" else {
      throw CLIUsageError("expected 'workflow', 'package', 'session', 'graphql', 'gql', 'hook', 'events', 'serve', or 'call-step' command")
    }
    guard arguments.count >= 2 else {
      throw CLIUsageError("workflow command requires a subcommand and workflow name")
    }
    if arguments[1] == "package" {
      return .workflow(.package(try parsePackage(scope: "workflow package", arguments: Array(arguments.dropFirst(2)))))
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

  private func parseSession(_ arguments: [String]) throws -> RielaCommand {
    guard let subcommand = arguments.first else {
      throw CLIUsageError("session command requires a subcommand")
    }
    switch subcommand {
    case "rerun":
      guard arguments.count >= 3, !arguments[1].hasPrefix("--"), !arguments[2].hasPrefix("--") else {
        throw CLIUsageError("usage: riela session rerun <session-id> <step-id> [options]")
      }
      let optionTokens = Array(arguments.dropFirst(3))
      let parsed = try ParsedWorkflowOptions(optionTokens, allowRunOptions: true)
      if parsed.endpoint != nil || parsed.fromRegistry {
        throw CLIUsageError("Swift TASK-007 supports local session commands only")
      }
      let workingDirectory = parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
      return .session(.rerun(SessionRerunOptions(
        sessionId: arguments[1],
        stepId: arguments[2],
        output: parsed.output,
        scope: parsed.scope,
        workflowDefinitionDir: parsed.workflowDefinitionDir,
        workingDirectory: workingDirectory,
        mockScenarioPath: parsed.mockScenarioPath,
        sessionStore: parsed.sessionStore,
        nestedSuperviser: parsed.nestedSuperviser
      )))
    case "resume":
      guard arguments.count >= 2, !arguments[1].hasPrefix("--") else {
        throw CLIUsageError("usage: riela session resume <session-id> [options]")
      }
      let optionTokens = Array(arguments.dropFirst(2))
      let parsed = try ParsedWorkflowOptions(optionTokens, allowRunOptions: true)
      if parsed.endpoint != nil || parsed.fromRegistry {
        throw CLIUsageError("Swift TASK-007 supports local session commands only")
      }
      let workingDirectory = parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
      return .session(.resume(SessionResumeOptions(
        sessionId: arguments[1],
        output: parsed.output,
        scope: parsed.scope,
        workflowDefinitionDir: parsed.workflowDefinitionDir,
        workingDirectory: workingDirectory,
        mockScenarioPath: parsed.mockScenarioPath,
        sessionStore: parsed.sessionStore
      )))
    case "progress":
      return .session(.progress(try parseSessionGeneric(subcommand: subcommand, arguments: arguments)))
    case "health":
      return .session(.health(try parseSessionGeneric(subcommand: subcommand, arguments: arguments)))
    case "status":
      return .session(.status(try parseSessionGeneric(subcommand: subcommand, arguments: arguments)))
    case "continue":
      return .session(.continueSession(try parseSessionGeneric(subcommand: subcommand, arguments: arguments)))
    case "step-runs":
      return .session(.stepRuns(try parseSessionGeneric(subcommand: subcommand, arguments: arguments)))
    case "export":
      return .session(.export(try parseSessionGeneric(subcommand: subcommand, arguments: arguments)))
    case "logs":
      return .session(.logs(try parseSessionGeneric(subcommand: subcommand, arguments: arguments)))
    default:
      throw CLIUsageError("unsupported session subcommand '\(subcommand)'")
    }
  }

  private func parseSessionGeneric(subcommand: String, arguments: [String]) throws -> CLICommandOptions {
    let target = arguments.count >= 2 && !arguments[1].hasPrefix("--") ? arguments[1] : nil
    let optionStart = target == nil ? 1 : 2
    if target == nil {
      throw CLIUsageError("session \(subcommand) requires a session id")
    }
    return try parseGeneric(
      scope: "session",
      command: subcommand,
      target: target,
      arguments: Array(arguments.dropFirst(optionStart))
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
      manifestPath = environment["RIEL_WORKFLOW_MANIFEST"].flatMap { $0.isEmpty ? nil : $0 }
        ?? environment["RIELA_WORKFLOW_MANIFEST"].flatMap { $0.isEmpty ? nil : $0 }
    }
    guard let manifestPath, !manifestPath.isEmpty else {
      throw CLIUsageError("workflow manifest validate requires a manifest path, --workflow-manifest, RIEL_WORKFLOW_MANIFEST, or RIELA_WORKFLOW_MANIFEST")
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
      allowTableOutput: kind == .search || kind == .list
    )
    return PackageCommand(kind: kind, options: options)
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

  private func parseGeneric(
    scope: String,
    command: String?,
    target: String? = nil,
    arguments: [String],
    allowTableOutput: Bool = false
  ) throws -> CLICommandOptions {
    let output = try parseOutputOnly(arguments, allowTableOutput: allowTableOutput)
    return CLICommandOptions(scope: scope, command: command, target: target, arguments: arguments, output: output)
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
      mockScenarioPath: parsed.mockScenarioPath,
      output: parsed.output,
      maxSteps: parsed.maxSteps,
      maxConcurrency: parsed.maxConcurrency,
      maxLoopIterations: parsed.maxLoopIterations,
      defaultTimeoutMs: parsed.defaultTimeoutMs,
      timeoutMs: parsed.timeoutMs,
      artifactRoot: parsed.artifactRoot,
      sessionStore: parsed.sessionStore,
      workingDirectory: resolution.workingDirectory,
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
      throw CLIUsageError("Swift TASK-007 supports local workflow \(subcommand) only")
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

private struct ParsedWorkflowOptions {
  var workflowDefinitionDir: String?
  var scope: WorkflowScope = .auto
  var output: WorkflowOutputFormat = .text
  var executable = false
  var structure = false
  var variables: String?
  var nodePatch: String?
  var mockScenarioPath: String?
  var maxSteps: Int?
  var maxConcurrency: Int?
  var maxLoopIterations: Int?
  var defaultTimeoutMs: Int?
  var timeoutMs: Int?
  var artifactRoot: String?
  var sessionStore: String?
  var workingDirectory: String?
  var endpoint: String?
  var authToken: String?
  var authTokenEnv: String?
  var fromRegistry = false
  var nestedSuperviser = false
  var autoImprove = false
  var maxSupervisedAttempts = 3
  var maxWorkflowPatches = 2
  var monitorIntervalMs = 1_000
  var stallTimeoutMs = 30_000
  var workflowMutationMode = WorkflowMutationMode.executionCopy

  init(_ tokens: [String], allowRunOptions: Bool = false, allowTableOutput: Bool = false) throws {
    var index = 0
    while index < tokens.count {
      let token = tokens[index]
      guard token.hasPrefix("--") else {
        throw CLIUsageError("unexpected positional argument '\(token)'")
      }
      try consumeOption(
        token,
        tokens: tokens,
        index: &index,
        allowRunOptions: allowRunOptions,
        allowTableOutput: allowTableOutput
      )
      index += 1
    }
    if stallTimeoutMs < monitorIntervalMs {
      throw CLIUsageError("invalid --auto-improve policy: stallTimeoutMs must be greater than or equal to monitorIntervalMs")
    }
  }

  private mutating func consumeOption(
    _ token: String,
    tokens: [String],
    index: inout Int,
    allowRunOptions: Bool,
    allowTableOutput: Bool
  ) throws {
    if try consumeCoreOption(token, tokens: tokens, index: &index, allowTableOutput: allowTableOutput) {
      return
    }
    if try consumeStringOption(token, tokens: tokens, index: &index, allowRunOptions: allowRunOptions) {
      return
    }
    if try consumeLimitOption(token, tokens: tokens, index: &index, allowRunOptions: allowRunOptions) {
      return
    }
    if try consumeAutoImproveOption(token, tokens: tokens, index: &index, allowRunOptions: allowRunOptions) {
      return
    }
    throw CLIUsageError("unknown option '\(token)'")
  }

  private mutating func consumeCoreOption(
    _ token: String,
    tokens: [String],
    index: inout Int,
    allowTableOutput: Bool
  ) throws -> Bool {
    switch token {
    case "--workflow-definition-dir":
      workflowDefinitionDir = try readOptionValue(token, tokens: tokens, index: &index)
    case "--scope":
      let raw = try readOptionValue(token, tokens: tokens, index: &index)
      guard let value = WorkflowScope(rawValue: raw), value != .direct else {
        throw CLIUsageError("invalid --scope value '\(raw)'; expected auto, project, or user")
      }
      scope = value
    case "--output":
      let raw = try readOptionValue(token, tokens: tokens, index: &index)
      guard let value = WorkflowOutputFormat(rawValue: raw) else {
        throw CLIUsageError("invalid --output value '\(raw)'; expected text, json, or table")
      }
      if value == .table && !allowTableOutput {
        throw CLIUsageError("`--output table` is only supported for workflow list, workflow status, package search, and package list")
      }
      output = value
    case "--executable":
      executable = true
    case "--structure":
      structure = true
    case "--from-registry":
      fromRegistry = true
    case "--nested-superviser", "--nested-supervisor":
      nestedSuperviser = true
    default:
      return false
    }
    return true
  }

  private mutating func consumeStringOption(
    _ token: String,
    tokens: [String],
    index: inout Int,
    allowRunOptions: Bool
  ) throws -> Bool {
    switch token {
    case "--node-patch":
      nodePatch = try readOptionValue(token, tokens: tokens, index: &index)
    case "--variables":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      variables = try readOptionValue(token, tokens: tokens, index: &index)
    case "--mock-scenario":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      mockScenarioPath = try readOptionValue(token, tokens: tokens, index: &index)
    case "--artifact-root":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      artifactRoot = try readOptionValue(token, tokens: tokens, index: &index)
    case "--session-store":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      sessionStore = try readOptionValue(token, tokens: tokens, index: &index)
    case "--working-dir", "--working-directory":
      workingDirectory = try readOptionValue(token, tokens: tokens, index: &index)
    case "--endpoint":
      endpoint = try readOptionValue(token, tokens: tokens, index: &index)
    case "--auth-token":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      authToken = try readOptionValue(token, tokens: tokens, index: &index)
    case "--auth-token-env":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      authTokenEnv = try readOptionValue(token, tokens: tokens, index: &index)
    default:
      return false
    }
    return true
  }

  private mutating func consumeLimitOption(
    _ token: String,
    tokens: [String],
    index: inout Int,
    allowRunOptions: Bool
  ) throws -> Bool {
    switch token {
    case "--max-steps":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      maxSteps = try positiveInt(token, readOptionValue(token, tokens: tokens, index: &index))
    case "--max-concurrency":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      maxConcurrency = try positiveInt(token, readOptionValue(token, tokens: tokens, index: &index))
    case "--max-loop-iterations":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      maxLoopIterations = try positiveInt(token, readOptionValue(token, tokens: tokens, index: &index))
    case "--default-timeout-ms":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      defaultTimeoutMs = try positiveInt(token, readOptionValue(token, tokens: tokens, index: &index))
    case "--timeout-ms":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      timeoutMs = try positiveInt(token, readOptionValue(token, tokens: tokens, index: &index))
    default:
      return false
    }
    return true
  }

  private mutating func consumeAutoImproveOption(
    _ token: String,
    tokens: [String],
    index: inout Int,
    allowRunOptions: Bool
  ) throws -> Bool {
    switch token {
    case "--auto-improve":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      autoImprove = true
    case "--no-auto-improve":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      autoImprove = false
      maxWorkflowPatches = 0
    case "--max-supervised-attempts":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      maxSupervisedAttempts = try positiveInt(token, readOptionValue(token, tokens: tokens, index: &index))
    case "--max-workflow-patches":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      maxWorkflowPatches = try nonNegativeInt(token, readOptionValue(token, tokens: tokens, index: &index))
    case "--monitor-interval-ms":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      monitorIntervalMs = try positiveInt(token, readOptionValue(token, tokens: tokens, index: &index))
    case "--stall-timeout-ms":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      stallTimeoutMs = try positiveInt(token, readOptionValue(token, tokens: tokens, index: &index))
    case "--workflow-mutation-mode":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      let rawMode = try readOptionValue(token, tokens: tokens, index: &index)
      guard let mode = WorkflowMutationMode(rawValue: rawMode) else {
        throw CLIUsageError("invalid --workflow-mutation-mode value '\(rawMode)'; expected \(WorkflowMutationMode.acceptedValuesDescription)")
      }
      workflowMutationMode = mode
    default:
      return false
    }
    return true
  }

  var autoImprovePolicy: WorkflowAutoImprovePolicy {
    WorkflowAutoImprovePolicy(
      maxSupervisedAttempts: maxSupervisedAttempts,
      maxWorkflowPatches: maxWorkflowPatches,
      monitorIntervalMs: monitorIntervalMs,
      stallTimeoutMs: stallTimeoutMs,
      workflowMutationMode: workflowMutationMode,
      nestedSuperviser: nestedSuperviser
    )
  }
}

private func parseOutputOnly(_ tokens: [String], allowTableOutput: Bool) throws -> WorkflowOutputFormat {
  var output = WorkflowOutputFormat.text
  var index = 0
  while index < tokens.count {
    let token = tokens[index]
    if token == "--output" {
      guard index + 1 < tokens.count, !tokens[index + 1].hasPrefix("--") else {
        throw CLIUsageError("--output requires a value")
      }
      guard let value = WorkflowOutputFormat(rawValue: tokens[index + 1]) else {
        throw CLIUsageError("invalid --output value '\(tokens[index + 1])'; expected text, json, or table")
      }
      if value == .table && !allowTableOutput {
        throw CLIUsageError("`--output table` is only supported for workflow list, workflow status, package search, and package list")
      }
      output = value
      index += 2
      continue
    }
    if token.hasPrefix("--output=") {
      let raw = String(token.dropFirst("--output=".count))
      guard let value = WorkflowOutputFormat(rawValue: raw) else {
        throw CLIUsageError("invalid --output value '\(raw)'; expected text, json, or table")
      }
      if value == .table && !allowTableOutput {
        throw CLIUsageError("`--output table` is only supported for workflow list, workflow status, package search, and package list")
      }
      output = value
    }
    index += 1
  }
  return output
}

private func requireRunOption(_ token: String, allowRunOptions: Bool) throws {
  if !allowRunOptions {
    throw CLIUsageError("\(token) is supported only by workflow run")
  }
}

private func readOptionValue(_ token: String, tokens: [String], index: inout Int) throws -> String {
  guard index + 1 < tokens.count, !tokens[index + 1].hasPrefix("--") else {
    throw CLIUsageError("\(token) requires a value")
  }
  index += 1
  return tokens[index]
}

private func positiveInt(_ token: String, _ raw: String) throws -> Int {
  guard let value = Int(raw), value > 0 else {
    throw CLIUsageError("\(token) requires a positive integer")
  }
  return value
}

private func nonNegativeInt(_ token: String, _ raw: String) throws -> Int {
  guard let value = Int(raw), value >= 0 else {
    throw CLIUsageError("\(token) must be a non-negative integer")
  }
  return value
}

func isSafeScopedWorkflowName(_ value: String) -> Bool {
  let scalars = Array(value.unicodeScalars)
  guard (1...64).contains(scalars.count), let first = scalars.first, isASCIIAlphaNumeric(first) else {
    return false
  }
  return scalars.allSatisfy { scalar in
    isASCIIAlphaNumeric(scalar) || scalar == "-" || scalar == "_"
  }
}

private func isASCIIAlphaNumeric(_ scalar: UnicodeScalar) -> Bool {
  let value = scalar.value
  return (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
}
