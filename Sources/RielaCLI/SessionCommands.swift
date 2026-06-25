import Foundation
import RielaAdapters
import RielaCore

public struct SessionRerunOptions: Equatable, Sendable {
  public var sessionId: String
  public var stepId: String
  public var output: WorkflowOutputFormat
  public var scope: WorkflowScope
  public var workflowDefinitionDir: String?
  public var workingDirectory: String
  public var mockScenarioPath: String?
  public var sessionStore: String?
  public var nestedSuperviser: Bool

  public init(
    sessionId: String,
    stepId: String,
    output: WorkflowOutputFormat = .jsonl,
    scope: WorkflowScope = .auto,
    workflowDefinitionDir: String? = nil,
    workingDirectory: String = FileManager.default.currentDirectoryPath,
    mockScenarioPath: String? = nil,
    sessionStore: String? = nil,
    nestedSuperviser: Bool = false
  ) {
    self.sessionId = sessionId
    self.stepId = stepId
    self.output = output
    self.scope = scope
    self.workflowDefinitionDir = workflowDefinitionDir
    self.workingDirectory = workingDirectory
    self.mockScenarioPath = mockScenarioPath
    self.sessionStore = sessionStore
    self.nestedSuperviser = nestedSuperviser
  }
}

public struct SessionResumeOptions: Equatable, Sendable {
  public var sessionId: String
  public var output: WorkflowOutputFormat
  public var scope: WorkflowScope
  public var workflowDefinitionDir: String?
  public var workingDirectory: String
  public var mockScenarioPath: String?
  public var sessionStore: String?

  public init(
    sessionId: String,
    output: WorkflowOutputFormat = .jsonl,
    scope: WorkflowScope = .auto,
    workflowDefinitionDir: String? = nil,
    workingDirectory: String = FileManager.default.currentDirectoryPath,
    mockScenarioPath: String? = nil,
    sessionStore: String? = nil
  ) {
    self.sessionId = sessionId
    self.output = output
    self.scope = scope
    self.workflowDefinitionDir = workflowDefinitionDir
    self.workingDirectory = workingDirectory
    self.mockScenarioPath = mockScenarioPath
    self.sessionStore = sessionStore
  }
}

public struct SessionRerunCommandResult: Codable, Equatable, Sendable {
  public var sourceSessionId: String
  public var sessionId: String
  public var status: WorkflowSessionStatus
  public var rerunFromStepId: String
  public var exitCode: Int32
  public var recovery: LoopRecoveryLineage?
}

public struct SessionResumeCommandResult: Codable, Equatable, Sendable {
  public var sourceSessionId: String?
  public var sessionId: String
  public var status: WorkflowSessionStatus
  public var exitCode: Int32
  public var recovery: LoopRecoveryLineage?
}

public struct SessionCommandFailureResult: Codable, Equatable, Sendable {
  public var sessionId: String
  public var error: String
  public var exitCode: Int32
}

public struct SessionInspectionCommandResult: Codable, Equatable, Sendable {
  public var sessionId: String
  public var workflowName: String
  public var status: WorkflowSessionStatus
  public var currentStepId: String?
  public var executionCount: Int
  public var executions: [WorkflowStepExecution]
  public var health: String?
  public var loopEvidenceRecorded: Bool
  public var loopEvidence: LoopEvidenceSummary?

  public init(
    sessionId: String,
    workflowName: String,
    status: WorkflowSessionStatus,
    currentStepId: String?,
    executionCount: Int,
    executions: [WorkflowStepExecution],
    health: String? = nil,
    loopEvidenceRecorded: Bool = false,
    loopEvidence: LoopEvidenceSummary? = nil
  ) {
    self.sessionId = sessionId
    self.workflowName = workflowName
    self.status = status
    self.currentStepId = currentStepId
    self.executionCount = executionCount
    self.executions = executions
    self.health = health
    self.loopEvidenceRecorded = loopEvidenceRecorded
    self.loopEvidence = loopEvidence
  }
}

public struct SessionInspectionCommand: Sendable {
  public init() {}

  public func run(_ options: CLICommandOptions) -> CLICommandResult {
    guard let sessionId = options.target, !sessionId.isEmpty else {
      return CLICommandResult(exitCode: .usage, stderr: "scope, command, and target are required")
    }
    do {
      let parsed = try parseSessionInspectionOptions(options.arguments)
      let snapshot = try loadRuntimeSnapshot(sessionId: sessionId, parsed: parsed)
      return try render(snapshot: snapshot, command: options.command ?? "status", output: options.output)
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch {
      if options.output.isStructured {
        let payload = SessionCommandFailureResult(sessionId: sessionId, error: "\(error)", exitCode: CLIExitCode.failure.rawValue)
        return CLICommandResult(exitCode: .failure, stdout: (try? jsonString(payload)) ?? "")
      }
      return CLICommandResult(exitCode: .failure, stderr: "\(error)")
    }
  }

  private struct ParsedOptions {
    var scope: WorkflowScope
    var workingDirectory: String
    var sessionStore: String?
  }

  private func parseSessionInspectionOptions(_ arguments: [String]) throws -> ParsedOptions {
    var scope = WorkflowScope.auto
    var workingDirectory = FileManager.default.currentDirectoryPath
    var sessionStore: String?
    var index = 0
    while index < arguments.count {
      let token = arguments[index]
      switch token {
      case "--scope":
        guard index + 1 < arguments.count, let value = WorkflowScope(rawValue: arguments[index + 1]), value != .direct else {
          throw CLIUsageError("invalid --scope value; expected auto, project, or user")
        }
        scope = value
        index += 2
      case "--working-dir", "--working-directory":
        guard index + 1 < arguments.count else {
          throw CLIUsageError("\(token) requires a value")
        }
        workingDirectory = arguments[index + 1]
        index += 2
      case "--session-store":
        guard index + 1 < arguments.count else {
          throw CLIUsageError("--session-store requires a value")
        }
        sessionStore = arguments[index + 1]
        index += 2
      case "--output":
        index += 2
      default:
        if token.hasPrefix("--output=") {
          index += 1
        } else {
          throw CLIUsageError("unsupported session \(token) option")
        }
      }
    }
    return ParsedOptions(scope: scope, workingDirectory: workingDirectory, sessionStore: sessionStore)
  }

  private func loadRuntimeSnapshot(sessionId: String, parsed: ParsedOptions) throws -> WorkflowRuntimePersistenceSnapshot {
    let loaded = try CLIWorkflowSessionResolution.loadPersistedSession(
      sessionId: sessionId,
      sessionStore: parsed.sessionStore,
      scope: parsed.scope,
      workingDirectory: parsed.workingDirectory
    )
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: loaded.storeRoot))
    return try store.load(sessionId: sessionId)
  }

  private func render(snapshot: WorkflowRuntimePersistenceSnapshot, command: String, output: WorkflowOutputFormat) throws -> CLICommandResult {
    let health = command == "health" ? (snapshot.session.status == .failed ? "failed" : "ok") : nil
    let loopEvidence = snapshot.loopEvidence.map(LoopEvidenceSummary.init)
    let result = SessionInspectionCommandResult(
      sessionId: snapshot.session.sessionId,
      workflowName: snapshot.session.workflowId,
      status: snapshot.session.status,
      currentStepId: snapshot.session.currentStepId,
      executionCount: snapshot.session.executions.count,
      executions: command == "status" || command == "export" || command == "step-runs" ? snapshot.session.executions : [],
      health: health,
      loopEvidenceRecorded: snapshot.loopEvidence != nil,
      loopEvidence: loopEvidence
    )
    switch output {
    case .json, .jsonl:
      return CLICommandResult(exitCode: .success, stdout: try jsonString(result))
    case .text, .table:
      var lines = [
        "sessionId: \(result.sessionId)",
        "workflow: \(result.workflowName)",
        "status: \(result.status.rawValue)",
        "currentStepId: \(result.currentStepId ?? "-")",
        "executionCount: \(result.executionCount)",
        "loopEvidenceRecorded: \(result.loopEvidenceRecorded ? "true" : "false")"
      ]
      if let health {
        lines.append("health: \(health)")
      }
      if let loopEvidence {
        lines.append(
          "loopEvidence: gates=\(loopEvidence.gateCount) accepted=\(loopEvidence.acceptedGateCount) rejected=\(loopEvidence.rejectedGateCount) blockingFindings=\(loopEvidence.blockingFindingCount)"
        )
      }
      if command == "logs" {
        lines.append(contentsOf: snapshot.session.executions.compactMap { execution in
          execution.failureReason.map { "\(execution.executionId)\t\(execution.stepId)\t\($0)" }
        })
      }
      return CLICommandResult(exitCode: .success, stdout: lines.joined(separator: "\n") + "\n")
    }
  }
}

public struct SessionRerunCommand: Sendable {
  public var resolver: any WorkflowBundleResolving
  public var jsonLoader: JSONReferenceLoader

  public init(
    resolver: any WorkflowBundleResolving = FileSystemWorkflowBundleResolver(),
    jsonLoader: JSONReferenceLoader = JSONReferenceLoader()
  ) {
    self.resolver = resolver
    self.jsonLoader = jsonLoader
  }

  public func run(_ options: SessionRerunOptions) async -> CLICommandResult {
    if options.nestedSuperviser {
      return failure(
        options: options,
        exitCode: .usage,
        error: "--nested-supervisor / --nested-superviser is not supported for session rerun; use workflow run or session resume with --auto-improve instead"
      )
    }
    do {
      let loaded = try CLIWorkflowSessionResolution.loadPersistedSession(
        sessionId: options.sessionId,
        sessionStore: options.sessionStore,
        scope: options.scope,
        workingDirectory: options.workingDirectory
      )
      let persisted = loaded.record
      let storeRoot = CLIWorkflowSessionResolution.saveStoreRoot(
        sessionStore: options.sessionStore,
        scope: options.scope,
        workingDirectory: options.workingDirectory,
        loadedFromStoreRoot: loaded.storeRoot
      )
      let resolution = mergedResolution(persisted: persisted, options: options)
      let bundle = try resolver.resolve(resolution)
      let adapter = try makeAdapter(
        mockScenarioPath: options.mockScenarioPath ?? persisted.mockScenarioPath,
        workingDirectory: options.workingDirectory
      )
      let runtimeStore = InMemoryWorkflowRuntimeStore()
      try await seedRuntimeStoreFromPersistedCLIState(runtimeStore, sessionStoreRoot: storeRoot)
      let runner = DeterministicWorkflowRunner(store: runtimeStore, adapter: adapter, stdioNodeExecutor: LocalWorkflowStdioNodeExecutor())
      let result = try await runner.run(
        DeterministicWorkflowRunRequest(
          workflow: bundle.workflow,
          nodePayloads: bundle.nodePayloads,
          rerunFromSessionId: persisted.session.sessionId,
          rerunFromStepId: options.stepId
        )
      )
      let workflowMessages = try await runtimeStore.listMessages(for: result.session.sessionId, toStepId: nil)
      let loopEvidence = projectLoopEvidence(
        session: result.session,
        workflowMessages: workflowMessages,
        bundle: bundle,
        recovery: result.recovery
      )
      try CLIWorkflowSessionStore(rootDirectory: storeRoot).save(
        PersistedCLIWorkflowSession(
          workflowName: persisted.workflowName,
          session: result.session,
          resolution: resolution,
          mockScenarioPath: options.mockScenarioPath ?? persisted.mockScenarioPath
        ),
        runtimeSnapshot: WorkflowRuntimePersistenceProjector.snapshot(
          session: result.session,
          workflowMessages: workflowMessages,
          loopEvidence: loopEvidence
        )
      )
      return renderRerunSuccess(options: options, result: result)
    } catch let error as CLIWorkflowSessionStoreError {
      return failure(options: options, exitCode: .failure, error: "\(error)")
    } catch let error as DeterministicWorkflowRunnerError {
      return failure(options: options, exitCode: .failure, error: "\(error)")
    } catch {
      return failure(options: options, exitCode: .failure, error: "\(error)")
    }
  }

  private func renderRerunSuccess(options: SessionRerunOptions, result: WorkflowRunResult) -> CLICommandResult {
    let exitCode = CLIExitCode(rawValue: result.exitCode) ?? .failure
    switch options.output {
    case .json, .jsonl:
      let payload = SessionRerunCommandResult(
        sourceSessionId: options.sessionId,
        sessionId: result.session.sessionId,
        status: result.session.status,
        rerunFromStepId: options.stepId,
        exitCode: result.exitCode,
        recovery: result.recovery
      )
      let stdout = (try? jsonString(payload)) ?? ""
      return CLICommandResult(exitCode: exitCode, stdout: stdout + (stdout.hasSuffix("\n") ? "" : "\n"))
    case .text, .table:
      return CLICommandResult(
        exitCode: exitCode,
        stdout: """
        sourceSessionId: \(options.sessionId)
        rerun session: \(result.session.sessionId)
        rerunFromStepId: \(options.stepId)
        recovery: \(result.recovery?.entryMode.rawValue ?? "none")
        status: \(result.session.status.rawValue)

        """
      )
    }
  }

  private func failure(options: SessionRerunOptions, exitCode: CLIExitCode, error: String) -> CLICommandResult {
    guard options.output.isStructured else {
      return CLICommandResult(exitCode: exitCode, stderr: error)
    }
    let payload = SessionCommandFailureResult(sessionId: options.sessionId, error: error, exitCode: exitCode.rawValue)
    let stdout = (try? jsonString(payload)) ?? ""
    return CLICommandResult(exitCode: exitCode, stdout: stdout + (stdout.hasSuffix("\n") ? "" : "\n"))
  }

  private func mergedResolution(persisted: PersistedCLIWorkflowSession, options: SessionRerunOptions) -> WorkflowResolutionOptions {
    CLIWorkflowSessionResolution.effectiveResolution(
      persisted: persisted,
      scope: options.scope,
      workflowDefinitionDir: options.workflowDefinitionDir,
      workingDirectory: options.workingDirectory
    )
  }

  private func makeAdapter(mockScenarioPath: String?, workingDirectory: String) throws -> any NodeAdapter {
    try makeSessionNodeAdapter(mockScenarioPath: mockScenarioPath, workingDirectory: workingDirectory)
  }
}

public struct SessionResumeCommand: Sendable {
  public var resolver: any WorkflowBundleResolving

  public init(resolver: any WorkflowBundleResolving = FileSystemWorkflowBundleResolver()) {
    self.resolver = resolver
  }

  public func run(_ options: SessionResumeOptions) async -> CLICommandResult {
    do {
      let loaded = try CLIWorkflowSessionResolution.loadPersistedSession(
        sessionId: options.sessionId,
        sessionStore: options.sessionStore,
        scope: options.scope,
        workingDirectory: options.workingDirectory
      )
      let persisted = loaded.record
      let storeRoot = CLIWorkflowSessionResolution.saveStoreRoot(
        sessionStore: options.sessionStore,
        scope: options.scope,
        workingDirectory: options.workingDirectory,
        loadedFromStoreRoot: loaded.storeRoot
      )
      let resolution = CLIWorkflowSessionResolution.effectiveResolution(
        persisted: persisted,
        scope: options.scope,
        workflowDefinitionDir: options.workflowDefinitionDir,
        workingDirectory: options.workingDirectory
      )
      let bundle = try resolver.resolve(resolution)
      let adapter = try makeSessionNodeAdapter(
        mockScenarioPath: options.mockScenarioPath ?? persisted.mockScenarioPath,
        workingDirectory: options.workingDirectory
      )
      let runtimeStore = InMemoryWorkflowRuntimeStore()
      try await seedRuntimeStoreFromPersistedCLIState(runtimeStore, sessionStoreRoot: storeRoot)
      let runner = DeterministicWorkflowRunner(store: runtimeStore, adapter: adapter, stdioNodeExecutor: LocalWorkflowStdioNodeExecutor())
      let result = try await runner.run(
        DeterministicWorkflowRunRequest(
          workflow: bundle.workflow,
          nodePayloads: bundle.nodePayloads,
          resumeSessionId: persisted.session.sessionId
        )
      )
      let workflowMessages = try await runtimeStore.listMessages(for: result.session.sessionId, toStepId: nil)
      let loopEvidence = projectLoopEvidence(
        session: result.session,
        workflowMessages: workflowMessages,
        bundle: bundle,
        recovery: result.recovery
      )
      try CLIWorkflowSessionStore(rootDirectory: storeRoot).save(
        PersistedCLIWorkflowSession(
          workflowName: persisted.workflowName,
          session: result.session,
          resolution: resolution,
          mockScenarioPath: options.mockScenarioPath ?? persisted.mockScenarioPath
        ),
        runtimeSnapshot: WorkflowRuntimePersistenceProjector.snapshot(
          session: result.session,
          workflowMessages: workflowMessages,
          loopEvidence: loopEvidence
        )
      )
      return renderResumeSuccess(options: options, result: result)
    } catch let error as CLIWorkflowSessionStoreError {
      return resumeFailure(options: options, exitCode: .failure, error: "\(error)")
    } catch let error as DeterministicWorkflowRunnerError {
      return resumeFailure(options: options, exitCode: .failure, error: "\(error)")
    } catch {
      return resumeFailure(options: options, exitCode: .failure, error: "\(error)")
    }
  }

  private func renderResumeSuccess(options: SessionResumeOptions, result: WorkflowRunResult) -> CLICommandResult {
    let exitCode = CLIExitCode(rawValue: result.exitCode) ?? .failure
    switch options.output {
    case .json, .jsonl:
      let payload = SessionResumeCommandResult(
        sourceSessionId: options.sessionId,
        sessionId: result.session.sessionId,
        status: result.session.status,
        exitCode: result.exitCode,
        recovery: result.recovery
      )
      let stdout = (try? jsonString(payload)) ?? ""
      return CLICommandResult(exitCode: exitCode, stdout: stdout + (stdout.hasSuffix("\n") ? "" : "\n"))
    case .text, .table:
      return CLICommandResult(
        exitCode: exitCode,
        stdout: """
        sourceSessionId: \(options.sessionId)
        session resumed: \(result.session.sessionId)
        recovery: \(result.recovery?.entryMode.rawValue ?? "none")
        status: \(result.session.status.rawValue)

        """
      )
    }
  }

  private func resumeFailure(options: SessionResumeOptions, exitCode: CLIExitCode, error: String) -> CLICommandResult {
    guard options.output.isStructured else {
      return CLICommandResult(exitCode: exitCode, stderr: error)
    }
    let payload = SessionCommandFailureResult(sessionId: options.sessionId, error: error, exitCode: exitCode.rawValue)
    let stdout = (try? jsonString(payload)) ?? ""
    return CLICommandResult(exitCode: exitCode, stdout: stdout + (stdout.hasSuffix("\n") ? "" : "\n"))
  }
}

private func projectLoopEvidence(
  session: WorkflowSession,
  workflowMessages: [WorkflowMessageRecord],
  bundle: ResolvedWorkflowBundle,
  recovery: LoopRecoveryLineage?
) -> LoopEvidenceManifest? {
  try? DefaultLoopEvidenceProjector().project(
    LoopEvidenceProjectionInput(
      workflow: bundle.workflow,
      session: session,
      workflowMessages: workflowMessages,
      workflowSource: loopWorkflowSource(from: bundle),
      recovery: recovery
    )
  )
}

private func loopWorkflowSource(from bundle: ResolvedWorkflowBundle) -> LoopWorkflowSource {
  LoopWorkflowSource(
    scope: bundle.sourceScope.rawValue,
    kind: bundle.packageManifest == nil ? "workflow-directory" : "package",
    workflowDirectory: bundle.workflowDirectory,
    packageName: bundle.packageManifest?.name,
    packageVersion: bundle.packageManifest?.version,
    packageDirectory: bundle.packageDirectory,
    mutable: bundle.packageManifest == nil
  )
}

private func makeSessionNodeAdapter(mockScenarioPath: String?, workingDirectory: String) throws -> any NodeAdapter {
  try makeScenarioBackedNodeAdapter(
    scenarioPath: mockScenarioPath,
    workingDirectory: workingDirectory
  )
}

private func loadExistingWorkflowMessages(
  sessionId: String,
  persistenceStore: SQLiteWorkflowRuntimePersistenceStore
) throws -> [WorkflowMessageRecord] {
  do {
    return try persistenceStore.load(sessionId: sessionId).workflowMessages
  } catch WorkflowRuntimePersistenceStoreError.notFound(_) {
    return []
  }
}
