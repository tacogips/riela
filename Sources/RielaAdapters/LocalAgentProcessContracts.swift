import Foundation
import RielaCore

public struct LocalAgentProcessConfiguration: Equatable, Sendable {
  public var executableURL: URL
  public var arguments: [String]
  public var environment: [String: String]
  public var unsetEnvironmentKeys: Set<String>
  public var workingDirectoryURL: URL?
  public var sandboxPolicy: LocalProcessSandboxPolicy?

  public init(
    executableURL: URL,
    arguments: [String] = [],
    environment: [String: String] = [:],
    unsetEnvironmentKeys: Set<String> = [],
    workingDirectoryURL: URL? = nil,
    sandboxPolicy: LocalProcessSandboxPolicy? = nil
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.environment = environment
    self.unsetEnvironmentKeys = unsetEnvironmentKeys
    self.workingDirectoryURL = workingDirectoryURL
    self.sandboxPolicy = sandboxPolicy
  }
}

/// Backend-specific tool-child liveness monitor (codex terminal-child stall
/// recovery). The adapter drives its lifecycle: `start` before the process
/// spawns, `processSpawned` once the direct agent child's pid is known, raw
/// stdout lines during streaming, and `stop` on completion, failure, or
/// cancellation — after `stop` returns, no monitor task or signal may remain
/// live.
public protocol LocalAgentToolChildMonitoring: Sendable {
  func start(emitBackendEvent: @escaping @Sendable (AdapterBackendEvent) -> Void)
  func processSpawned(_ processId: Int32)
  func observeStdoutLine(_ line: String)
  func stop() async
}

public struct LocalAgentCommand: Sendable {
  public var provider: String
  public var metadata: JSONObject
  public var additionalSensitiveValues: [String]
  public var configuration: LocalAgentProcessConfiguration
  public var stdin: String
  public var normalizeStdout: @Sendable (String) -> String
  public var backendEventType: @Sendable (String) -> String?
  public var classifyBackendEvent: (@Sendable (String) -> AdapterBackendEvent?)?
  /// Optional terminal tool-child stall monitor (nil = policy off).
  public var toolChildMonitor: (any LocalAgentToolChildMonitoring)?

  public init(
    provider: String,
    metadata: JSONObject = [:],
    additionalSensitiveValues: [String] = [],
    configuration: LocalAgentProcessConfiguration,
    stdin: String,
    normalizeStdout: @escaping @Sendable (String) -> String = { $0 },
    backendEventType: @escaping @Sendable (String) -> String? = { _ in nil },
    classifyBackendEvent: (@Sendable (String) -> AdapterBackendEvent?)? = nil,
    toolChildMonitor: (any LocalAgentToolChildMonitoring)? = nil
  ) {
    self.provider = provider
    self.metadata = metadata
    self.additionalSensitiveValues = additionalSensitiveValues
    self.configuration = configuration
    self.stdin = stdin
    self.normalizeStdout = normalizeStdout
    self.backendEventType = backendEventType
    self.classifyBackendEvent = classifyBackendEvent
    self.toolChildMonitor = toolChildMonitor
  }
}

public protocol LocalAgentCommandBuilding: Sendable {
  var provider: String { get }
  func buildCommand(for input: AdapterExecutionInput) throws -> LocalAgentCommand
}

public struct LocalAgentProcessResult: Equatable, Sendable {
  public var stdout: String
  public var stderr: String
  public var terminationStatus: Int32

  public init(stdout: String, stderr: String, terminationStatus: Int32) {
    self.stdout = stdout
    self.stderr = stderr
    self.terminationStatus = terminationStatus
  }
}

public protocol LocalAgentProcessRunning: Sendable {
  func run(configuration: LocalAgentProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalAgentProcessResult
}

public enum LocalAgentProcessOutputStream: String, Equatable, Sendable {
  case stdout
  case stderr
}

public struct LocalAgentProcessOutputEvent: Equatable, Sendable {
  public var stream: LocalAgentProcessOutputStream
  public var line: String

  public init(stream: LocalAgentProcessOutputStream, line: String) {
    self.stream = stream
    self.line = line
  }
}

public protocol LocalAgentProcessEventStreaming: LocalAgentProcessRunning {
  func run(
    configuration: LocalAgentProcessConfiguration,
    stdin: String,
    deadline: Date?,
    outputEventHandler: (@Sendable (LocalAgentProcessOutputEvent) -> Void)?
  ) async throws -> LocalAgentProcessResult
}

/// Streaming runners that can additionally report the spawned direct child's
/// pid, enabling tool-child correlation. Optional capability; runners without
/// it simply never bind process identities.
public protocol LocalAgentProcessSpawnObserving: LocalAgentProcessEventStreaming {
  func run(
    configuration: LocalAgentProcessConfiguration,
    stdin: String,
    deadline: Date?,
    outputEventHandler: (@Sendable (LocalAgentProcessOutputEvent) -> Void)?,
    spawnHandler: (@Sendable (Int32) -> Void)?
  ) async throws -> LocalAgentProcessResult
}
