import Foundation
import RielaCore

public enum WorkflowServeSelectionKind: String, Codable, Equatable, Sendable {
  case directDirectory = "direct-directory"
  case scopedName = "scoped-name"
  case manifestEntry = "manifest-entry"
  case package = "package"
}

public enum WorkflowServeStatus: String, Codable, Equatable, Sendable {
  case stopped
  case starting
  case running
  case reloading
  case stopping
  case failed
}

public enum WorkflowServeReloadMode: String, Codable, Equatable, Sendable {
  case validateThenSwap = "validate-then-swap"
}

public enum WorkflowServeRestartPolicy: String, Codable, Equatable, Sendable {
  case keepRunningOnFailure = "keep-running-on-failure"
  case failIfReplacementFails = "fail-if-replacement-fails"
}

public struct WorkflowServeSelection: Codable, Equatable, Sendable {
  public var kind: WorkflowServeSelectionKind
  public var identifier: String
  public var path: String?
  public var scope: String?
  public var manifestEntryId: String?

  public init(
    kind: WorkflowServeSelectionKind,
    identifier: String,
    path: String? = nil,
    scope: String? = nil,
    manifestEntryId: String? = nil
  ) {
    self.kind = kind
    self.identifier = identifier
    self.path = path
    self.scope = scope
    self.manifestEntryId = manifestEntryId
  }

  public static func directDirectory(_ path: String, identifier: String? = nil) -> WorkflowServeSelection {
    WorkflowServeSelection(kind: .directDirectory, identifier: identifier ?? path, path: path)
  }

  public static func scopedName(_ name: String, scope: String = "auto") -> WorkflowServeSelection {
    WorkflowServeSelection(kind: .scopedName, identifier: name, scope: scope)
  }

  public static func package(_ id: String) -> WorkflowServeSelection {
    WorkflowServeSelection(kind: .package, identifier: id)
  }

  public static func manifestEntry(manifestPath: String, entryId: String) -> WorkflowServeSelection {
    WorkflowServeSelection(kind: .manifestEntry, identifier: manifestPath, path: manifestPath, manifestEntryId: entryId)
  }
}

public struct WorkflowServeRuntimeConfiguration: Codable, Equatable, Sendable {
  public var workingDirectory: String?
  public var inheritedEnvironment: [String: String]
  public var defaultVariables: JSONObject
  public var nodePatch: JSONObject?

  public init(
    workingDirectory: String? = nil,
    inheritedEnvironment: [String: String] = [:],
    defaultVariables: JSONObject = [:],
    nodePatch: JSONObject? = nil
  ) {
    self.workingDirectory = workingDirectory
    self.inheritedEnvironment = inheritedEnvironment
    self.defaultVariables = defaultVariables
    self.nodePatch = nodePatch
  }

  public func effectiveWorkingDirectory(default defaultWorkingDirectory: String) -> String {
    let normalized = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let normalized, !normalized.isEmpty else {
      return defaultWorkingDirectory
    }
    return normalized
  }
}

public struct WorkflowServeStartRequest: Codable, Equatable, Sendable {
  public var selection: WorkflowServeSelection
  public var server: RielaServerConfiguration
  public var configuration: WorkflowServeRuntimeConfiguration
  public var artifactRoot: String?
  public var sessionStoreRoot: String?
  public var eventRoot: String?
  public var startsEventSources: Bool

  private enum CodingKeys: String, CodingKey {
    case selection
    case server
    case configuration
    case workingDirectory
    case artifactRoot
    case sessionStoreRoot
    case eventRoot
    case inheritedEnvironment
    case defaultVariables
    case nodePatch
    case startsEventSources
  }

  public init(
    selection: WorkflowServeSelection,
    server: RielaServerConfiguration = RielaServerConfiguration(),
    workingDirectory: String = FileManager.default.currentDirectoryPath,
    artifactRoot: String? = nil,
    sessionStoreRoot: String? = nil,
    eventRoot: String? = nil,
    inheritedEnvironment: [String: String] = [:],
    defaultVariables: JSONObject = [:],
    nodePatch: JSONObject? = nil,
    startsEventSources: Bool = true
  ) {
    self.selection = selection
    self.server = server
    configuration = WorkflowServeRuntimeConfiguration(
      workingDirectory: workingDirectory,
      inheritedEnvironment: inheritedEnvironment,
      defaultVariables: defaultVariables,
      nodePatch: nodePatch
    )
    self.artifactRoot = artifactRoot
    self.sessionStoreRoot = sessionStoreRoot
    self.eventRoot = eventRoot
    self.startsEventSources = startsEventSources
  }

  public init(
    selection: WorkflowServeSelection,
    server: RielaServerConfiguration = RielaServerConfiguration(),
    configuration: WorkflowServeRuntimeConfiguration,
    artifactRoot: String? = nil,
    sessionStoreRoot: String? = nil,
    eventRoot: String? = nil,
    startsEventSources: Bool = true
  ) {
    self.selection = selection
    self.server = server
    self.configuration = configuration
    self.artifactRoot = artifactRoot
    self.sessionStoreRoot = sessionStoreRoot
    self.eventRoot = eventRoot
    self.startsEventSources = startsEventSources
  }

  public var workingDirectory: String {
    get { configuration.effectiveWorkingDirectory(default: FileManager.default.currentDirectoryPath) }
    set { configuration.workingDirectory = newValue }
  }

  public var inheritedEnvironment: [String: String] {
    get { configuration.inheritedEnvironment }
    set { configuration.inheritedEnvironment = newValue }
  }

  public var defaultVariables: JSONObject {
    get { configuration.defaultVariables }
    set { configuration.defaultVariables = newValue }
  }

  public var nodePatch: JSONObject? {
    get { configuration.nodePatch }
    set { configuration.nodePatch = newValue }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    selection = try container.decode(WorkflowServeSelection.self, forKey: .selection)
    server = try container.decodeIfPresent(RielaServerConfiguration.self, forKey: .server) ?? RielaServerConfiguration()
    if let decodedConfiguration = try container.decodeIfPresent(
      WorkflowServeRuntimeConfiguration.self,
      forKey: .configuration
    ) {
      configuration = decodedConfiguration
    } else {
      configuration = WorkflowServeRuntimeConfiguration(
        workingDirectory: try container.decodeIfPresent(String.self, forKey: .workingDirectory)
          ?? FileManager.default.currentDirectoryPath,
        inheritedEnvironment: try container.decodeIfPresent([String: String].self, forKey: .inheritedEnvironment) ?? [:],
        defaultVariables: try container.decodeIfPresent(JSONObject.self, forKey: .defaultVariables) ?? [:],
        nodePatch: try container.decodeIfPresent(JSONObject.self, forKey: .nodePatch)
      )
    }
    artifactRoot = try container.decodeIfPresent(String.self, forKey: .artifactRoot)
    sessionStoreRoot = try container.decodeIfPresent(String.self, forKey: .sessionStoreRoot)
    eventRoot = try container.decodeIfPresent(String.self, forKey: .eventRoot)
    startsEventSources = try container.decodeIfPresent(Bool.self, forKey: .startsEventSources) ?? true
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(selection, forKey: .selection)
    try container.encode(server, forKey: .server)
    try container.encode(configuration, forKey: .configuration)
    try container.encodeIfPresent(artifactRoot, forKey: .artifactRoot)
    try container.encodeIfPresent(sessionStoreRoot, forKey: .sessionStoreRoot)
    try container.encodeIfPresent(eventRoot, forKey: .eventRoot)
    try container.encode(startsEventSources, forKey: .startsEventSources)
  }
}

public struct WorkflowServeReloadRequest: Codable, Equatable, Sendable {
  public var mode: WorkflowServeReloadMode
  public var replacementSelection: WorkflowServeSelection?
  public var restartPolicy: WorkflowServeRestartPolicy

  public init(
    mode: WorkflowServeReloadMode = .validateThenSwap,
    replacementSelection: WorkflowServeSelection? = nil,
    restartPolicy: WorkflowServeRestartPolicy = .keepRunningOnFailure
  ) {
    self.mode = mode
    self.replacementSelection = replacementSelection
    self.restartPolicy = restartPolicy
  }
}

public struct WorkflowServeDiagnostics: Codable, Equatable, Sendable {
  public var code: String
  public var message: String
  public var selection: WorkflowServeSelection?

  public init(code: String, message: String, selection: WorkflowServeSelection? = nil) {
    self.code = code
    self.message = message
    self.selection = selection
  }
}

public struct WorkflowServeEventSourceStatus: Codable, Equatable, Sendable {
  public var sourceId: String
  public var status: String
  public var generationId: String

  public init(sourceId: String, status: String, generationId: String) {
    self.sourceId = sourceId
    self.status = status
    self.generationId = generationId
  }
}

public struct WorkflowServeGeneration: Codable, Equatable, Sendable {
  public var generationId: String
  public var workflowId: String
  public var selectedIdentity: String
  public var endpoint: String
  public var eventSources: [WorkflowServeEventSourceStatus]
  public var sessionStoreRoot: String?
  public var eventRoot: String?
  public var validationDiagnostics: [WorkflowServeDiagnostics]

  public init(
    generationId: String,
    workflowId: String,
    selectedIdentity: String,
    endpoint: String,
    eventSources: [WorkflowServeEventSourceStatus] = [],
    sessionStoreRoot: String? = nil,
    eventRoot: String? = nil,
    validationDiagnostics: [WorkflowServeDiagnostics] = []
  ) {
    self.generationId = generationId
    self.workflowId = workflowId
    self.selectedIdentity = selectedIdentity
    self.endpoint = endpoint
    self.eventSources = eventSources
    self.sessionStoreRoot = sessionStoreRoot
    self.eventRoot = eventRoot
    self.validationDiagnostics = validationDiagnostics
  }
}

public struct WorkflowServeState: Codable, Equatable, Sendable {
  public var status: WorkflowServeStatus
  public var generation: WorkflowServeGeneration?
  public var diagnostics: [WorkflowServeDiagnostics]

  public init(
    status: WorkflowServeStatus = .stopped,
    generation: WorkflowServeGeneration? = nil,
    diagnostics: [WorkflowServeDiagnostics] = []
  ) {
    self.status = status
    self.generation = generation
    self.diagnostics = diagnostics
  }
}

public struct WorkflowServeResolvedWorkflow: Codable, Equatable, Sendable {
  public var workflowId: String
  public var selectedIdentity: String
  public var workflowDirectory: String?
  public var diagnostics: [WorkflowServeDiagnostics]

  public init(
    workflowId: String,
    selectedIdentity: String,
    workflowDirectory: String? = nil,
    diagnostics: [WorkflowServeDiagnostics] = []
  ) {
    self.workflowId = workflowId
    self.selectedIdentity = selectedIdentity
    self.workflowDirectory = workflowDirectory
    self.diagnostics = diagnostics
  }
}

public enum WorkflowServeError: Error, Equatable, Sendable, CustomStringConvertible {
  case alreadyRunning
  case notRunning
  case noAcceptedStartRequest
  case validationFailed(WorkflowServeDiagnostics)
  case startupFailed(WorkflowServeDiagnostics)
  case shutdownFailed(WorkflowServeDiagnostics)

  public var description: String {
    switch self {
    case .alreadyRunning:
      "workflow serving is already running"
    case .notRunning:
      "workflow serving is not running"
    case .noAcceptedStartRequest:
      "workflow serving has no accepted start request"
    case let .validationFailed(diagnostic),
      let .startupFailed(diagnostic),
      let .shutdownFailed(diagnostic):
      diagnostic.message
    }
  }
}
