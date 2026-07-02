import Darwin
import Foundation
import XCTest
@testable import ClaudeCodeAgent
@testable import CodexAgent
@testable import CursorCLIAgent
@testable import RielaAdapters
@testable import RielaCore

struct CapturingRunner: LocalAgentProcessRunning {
  let output: String
  let error: String
  let status: Int32

  init(output: String, error: String = "", status: Int32 = 0) {
    self.output = output
    self.error = error
    self.status = status
  }

  func run(configuration: LocalAgentProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalAgentProcessResult {
    XCTAssertEqual(configuration.environment["RIELA_AGENT_BACKEND"]?.isEmpty, false)
    return LocalAgentProcessResult(stdout: output, stderr: error, terminationStatus: status)
  }
}

struct RecordedRun: Equatable {
  var configuration: LocalAgentProcessConfiguration
  var stdin: String
  var deadline: Date?
}

actor RecordingRunnerStore {
  private var recordedRuns: [RecordedRun] = []

  func append(_ run: RecordedRun) {
    recordedRuns.append(run)
  }

  func runs() -> [RecordedRun] {
    recordedRuns
  }
}

final class RecordingRunner: LocalAgentProcessRunning, @unchecked Sendable {
  private let store = RecordingRunnerStore()
  private let output: String
  private let error: String
  private let status: Int32

  init(output: String = "done", error: String = "", status: Int32 = 0) {
    self.output = output
    self.error = error
    self.status = status
  }

  func run(configuration: LocalAgentProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalAgentProcessResult {
    await store.append(RecordedRun(configuration: configuration, stdin: stdin, deadline: deadline))
    return LocalAgentProcessResult(stdout: output, stderr: error, terminationStatus: status)
  }

  func runs() async -> [RecordedRun] {
    await store.runs()
  }
}

actor BackendEventRecorder {
  private var events: [AdapterBackendEvent] = []

  func append(_ event: AdapterBackendEvent) {
    events.append(event)
  }

  func recordedEvents() -> [AdapterBackendEvent] {
    events
  }
}

final class StreamingRecordingRunner: LocalAgentProcessRunning, LocalAgentProcessEventStreaming, @unchecked Sendable {
  private let output: String
  private let error: String
  private let status: Int32

  init(output: String, error: String = "", status: Int32 = 0) {
    self.output = output
    self.error = error
    self.status = status
  }

  func run(configuration: LocalAgentProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalAgentProcessResult {
    try await run(configuration: configuration, stdin: stdin, deadline: deadline, outputEventHandler: nil)
  }

  func run(
    configuration: LocalAgentProcessConfiguration,
    stdin: String,
    deadline: Date?,
    outputEventHandler: (@Sendable (LocalAgentProcessOutputEvent) -> Void)?
  ) async throws -> LocalAgentProcessResult {
    for line in output.split(whereSeparator: \.isNewline).map(String.init) {
      outputEventHandler?(LocalAgentProcessOutputEvent(stream: .stdout, line: line))
    }
    for line in error.split(whereSeparator: \.isNewline).map(String.init) {
      outputEventHandler?(LocalAgentProcessOutputEvent(stream: .stderr, line: line))
    }
    return LocalAgentProcessResult(stdout: output, stderr: error, terminationStatus: status)
  }
}

actor SequencedRunnerStore {
  private var results: [LocalAgentProcessResult]
  private var recordedRuns: [RecordedRun] = []

  init(results: [LocalAgentProcessResult]) {
    self.results = results
  }

  func run(configuration: LocalAgentProcessConfiguration, stdin: String, deadline: Date?) -> LocalAgentProcessResult {
    recordedRuns.append(RecordedRun(configuration: configuration, stdin: stdin, deadline: deadline))
    if results.isEmpty {
      return LocalAgentProcessResult(stdout: "", stderr: "missing sequenced result", terminationStatus: 1)
    }
    return results.removeFirst()
  }

  func runs() -> [RecordedRun] {
    recordedRuns
  }
}

final class SequencedRunner: LocalAgentProcessRunning, @unchecked Sendable {
  private let store: SequencedRunnerStore

  init(_ results: [LocalAgentProcessResult]) {
    self.store = SequencedRunnerStore(results: results)
  }

  func run(configuration: LocalAgentProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalAgentProcessResult {
    await store.run(configuration: configuration, stdin: stdin, deadline: deadline)
  }

  func runs() async -> [RecordedRun] {
    await store.runs()
  }
}

enum ProcessRunOutcome: Sendable {
  case result(LocalAgentProcessResult)
  case error(AdapterExecutionError)
  case cancellation
}

actor OutcomeRunnerStore {
  private var outcomes: [ProcessRunOutcome]
  private var recordedRuns: [RecordedRun] = []

  init(outcomes: [ProcessRunOutcome]) {
    self.outcomes = outcomes
  }

  func run(configuration: LocalAgentProcessConfiguration, stdin: String, deadline: Date?) throws -> LocalAgentProcessResult {
    recordedRuns.append(RecordedRun(configuration: configuration, stdin: stdin, deadline: deadline))
    guard !outcomes.isEmpty else {
      throw AdapterExecutionError(.providerError, "missing sequenced outcome")
    }
    switch outcomes.removeFirst() {
    case let .result(result):
      return result
    case let .error(error):
      throw error
    case .cancellation:
      throw CancellationError()
    }
  }

  func runs() -> [RecordedRun] {
    recordedRuns
  }
}

final class OutcomeRunner: LocalAgentProcessRunning, @unchecked Sendable {
  private let store: OutcomeRunnerStore

  init(_ outcomes: [ProcessRunOutcome]) {
    self.store = OutcomeRunnerStore(outcomes: outcomes)
  }

  func run(configuration: LocalAgentProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalAgentProcessResult {
    try await store.run(configuration: configuration, stdin: stdin, deadline: deadline)
  }

  func runs() async -> [RecordedRun] {
    await store.runs()
  }
}

struct MockCodexReadinessOperations: CodexAgentReadinessOperations {
  func getToolVersions(options _: AgentBackendProbeOptions) async -> CodexBackendToolVersions {
    CodexBackendToolVersions(
      codex: AgentBackendToolInfo(name: "codex", command: "codex", version: "codex-cli 0.135.0", status: .available),
      git: AgentBackendToolInfo(name: "git", command: "git", version: "git version 2.53.0", status: .available)
    )
  }

  func getLoginStatus(options _: AgentBackendProbeOptions) async -> CodexBackendLoginStatus {
    CodexBackendLoginStatus(ok: true, status: "Logged in using ChatGPT", exitCode: 0)
  }

  func checkModelAvailability(model: String, options _: AgentBackendProbeOptions) async -> CodexBackendModelAvailability {
    CodexBackendModelAvailability(
      ok: true,
      model: model,
      auth: CodexBackendLoginStatus(ok: true, status: "Logged in using ChatGPT", exitCode: 0),
      probe: CodexBackendModelProbe(ok: true, model: model, output: "OK", exitCode: 0)
    )
  }
}

struct MockClaudeReadinessOperations: ClaudeCodeAgentReadinessOperations {
  func getToolVersion(options _: AgentBackendProbeOptions) async -> AgentBackendToolInfo {
    AgentBackendToolInfo(name: "claude", command: "claude", version: "2.1.86", status: .available)
  }

  func verifyReadiness(model: String?, options _: AgentBackendProbeOptions) async -> ClaudeBackendReadiness {
    ClaudeBackendReadiness(
      ready: model != nil,
      auth: ClaudeBackendAuthReadiness(state: .configured, available: true, verified: model != nil),
      cli: ClaudeBackendCliReadiness(checked: model != nil, available: true, exitCode: model == nil ? nil : 0),
      model: ClaudeBackendModelReadiness(requested: model, checked: model != nil, available: model != nil, timedOut: false, exitCode: model == nil ? nil : 0)
    )
  }
}

struct MockCursorReadinessOperations: CursorCLIAgentReadinessOperations {
  func getToolVersions(options _: AgentBackendProbeOptions) async -> CursorBackendToolVersions {
    CursorBackendToolVersions(
      packageVersion: "0.1.0",
      tools: [
        AgentBackendToolInfo(name: "cursor-agent", command: "cursor-agent", version: "0.45.0", status: .available)
      ]
    )
  }

  func checkModelAvailability(model: String, options _: AgentBackendProbeOptions) async -> CursorBackendModelAvailability {
    CursorBackendModelAvailability(
      model: model,
      binary: AgentBackendToolInfo(name: "cursor-agent", command: "cursor-agent", version: "0.45.0", status: .available),
      auth: CursorBackendAuthAvailability(status: .available, detail: "cursor-agent authentication is usable"),
      modelReachability: CursorBackendModelReachability(status: .available, probed: true, output: "OK")
    )
  }
}

final class SignalRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedSignals: [(pid: pid_t, signal: Int32)] = []
  private var liveProbeResults: [Int32]

  init(liveProbeResults: [Int32] = [0]) {
    self.liveProbeResults = liveProbeResults
  }

  func record(pid: pid_t, signal: Int32) -> Int32 {
    lock.lock()
    if signal == 0 {
      let result = liveProbeResults.isEmpty ? 0 : liveProbeResults.removeFirst()
      lock.unlock()
      return result
    }
    recordedSignals.append((pid: pid, signal: signal))
    lock.unlock()
    return 0
  }

  func signals() -> [(pid: pid_t, signal: Int32)] {
    lock.lock()
    defer { lock.unlock() }
    return recordedSignals
  }
}
