import Foundation
import RielaAdapters
import RielaCore

public struct SessionDiscoveryCommand: Sendable {
  public init() {}

  public func run(_ options: CLICommandOptions) -> CLICommandResult {
    do {
      let parsed = try parseOptions(options.arguments)
      if options.command == "latest", parsed.workflowName == nil {
        throw CLIUsageError("session latest requires --workflow <name>")
      }
      let storeRoot = CLIWorkflowSessionStore.resolveRootDirectory(
        sessionStore: parsed.sessionStore,
        scope: parsed.scope,
        workingDirectory: parsed.workingDirectory
      )
      let limit = options.command == "latest" ? 1 : parsed.limit
      let rows = try CLIWorkflowSessionStore(rootDirectory: storeRoot)
        .list(workflowName: parsed.workflowName, status: parsed.status, limit: limit)
        .map { SessionDiscoveryRow(record: $0, sessionStore: storeRoot) }
      if options.command == "latest" {
        guard let latest = rows.first else {
          return failure(output: options.output, error: "session not found", exitCode: .failure)
        }
        return renderLatest(latest, output: options.output)
      }
      return renderList(rows, output: options.output)
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch {
      return failure(output: options.output, error: "\(error)", exitCode: .failure)
    }
  }

  private struct ParsedOptions {
    var workflowName: String?
    var status: WorkflowSessionStatus?
    var limit: Int = 10
    var scope: WorkflowScope = .auto
    var workingDirectory: String = FileManager.default.currentDirectoryPath
    var sessionStore: String?
  }

  private func parseOptions(_ arguments: [String]) throws -> ParsedOptions {
    var parsed = ParsedOptions()
    var index = 0
    while index < arguments.count {
      let token = arguments[index]
      switch token {
      case "--workflow":
        parsed.workflowName = try value(after: token, at: index, in: arguments)
        index += 2
      case "--status":
        let raw = try value(after: token, at: index, in: arguments)
        guard let status = WorkflowSessionStatus(rawValue: raw) else {
          throw CLIUsageError("invalid --status value; expected created, running, completed, or failed")
        }
        parsed.status = status
        index += 2
      case "--limit":
        let raw = try value(after: token, at: index, in: arguments)
        guard let limit = Int(raw), limit > 0 else {
          throw CLIUsageError("--limit requires a positive integer")
        }
        parsed.limit = min(limit, 100)
        index += 2
      case "--scope":
        let raw = try value(after: token, at: index, in: arguments)
        guard let scope = WorkflowScope(rawValue: raw), scope != .direct else {
          throw CLIUsageError("invalid --scope value; expected auto, project, or user")
        }
        parsed.scope = scope
        index += 2
      case "--working-dir", "--working-directory":
        parsed.workingDirectory = try value(after: token, at: index, in: arguments)
        index += 2
      case "--session-store":
        parsed.sessionStore = try value(after: token, at: index, in: arguments)
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
    return parsed
  }

  private func value(after option: String, at index: Int, in arguments: [String]) throws -> String {
    guard index + 1 < arguments.count else {
      throw CLIUsageError("\(option) requires a value")
    }
    return arguments[index + 1]
  }

  private func renderList(_ rows: [SessionDiscoveryRow], output: WorkflowOutputFormat) -> CLICommandResult {
    switch output {
    case .json, .jsonl:
      return CLICommandResult(exitCode: .success, stdout: (try? jsonString(rows)) ?? "[]\n")
    case .text, .table:
      let lines = rows.map { row in
        [
          row.sessionId,
          row.workflowName,
          row.status.rawValue,
          row.failureKind?.rawValue ?? "-",
          row.currentStepId ?? "-",
          String(row.executionCount),
          iso8601String(row.updatedAt),
          row.sessionStore
        ].joined(separator: "\t")
      }
      return CLICommandResult(exitCode: .success, stdout: lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
    }
  }

  private func renderLatest(_ row: SessionDiscoveryRow, output: WorkflowOutputFormat) -> CLICommandResult {
    switch output {
    case .json, .jsonl:
      return CLICommandResult(exitCode: .success, stdout: (try? jsonString(row)) ?? "{}\n")
    case .text, .table:
      return CLICommandResult(
        exitCode: .success,
        stdout: """
        sessionId: \(row.sessionId)
        workflow: \(row.workflowName)
        status: \(row.status.rawValue)
        failureKind: \(row.failureKind?.rawValue ?? "-")
        currentStepId: \(row.currentStepId ?? "-")
        executionCount: \(row.executionCount)
        updatedAt: \(iso8601String(row.updatedAt))
        sessionStore: \(row.sessionStore)

        """
      )
    }
  }

  private func failure(output: WorkflowOutputFormat, error: String, exitCode: CLIExitCode) -> CLICommandResult {
    guard output.isStructured else {
      return CLICommandResult(exitCode: exitCode, stderr: error)
    }
    let payload = SessionCommandFailureResult(sessionId: "", error: error, exitCode: exitCode.rawValue)
    return CLICommandResult(exitCode: exitCode, stdout: (try? jsonString(payload)) ?? "")
  }
}

public struct SessionInspectionCommandResult: Codable, Equatable, Sendable {
  public var sessionId: String
  public var workflowName: String
  public var status: WorkflowSessionStatus
  public var currentStepId: String?
  public var lastCompletedStepId: String?
  public var failureReason: String?
  public var failureKind: WorkflowSessionFailureKind?
  public var stepBudgetDiagnostic: WorkflowStepBudgetDiagnostic?
  public var instanceIdentity: String?
  public var instanceKind: String?
  public var instanceBaseIdentity: String?
  public var instanceConfiguration: JSONObject?
  public var activeStepId: String?
  public var activeExecutionId: String?
  public var activeBackend: NodeExecutionBackend?
  public var activeExecutionUpdatedAt: Date?
  public var activeBackendEventAt: Date?
  public var activeBackendEventType: String?
  public var backendSilentForMs: Int?
  public var activeSilentForMs: Int?
  public var executionCount: Int
  public var executions: [WorkflowStepExecution]
  public var reviewFindingCount: Int
  public var reviewFindings: [WorkflowReviewFinding]
  public var health: String?
  public var loopEvidenceRecorded: Bool
  public var loopEvidence: LoopEvidenceSummary?

  public init(
    sessionId: String,
    workflowName: String,
    status: WorkflowSessionStatus,
    currentStepId: String?,
    lastCompletedStepId: String? = nil,
    failureReason: String? = nil,
    failureKind: WorkflowSessionFailureKind? = nil,
    stepBudgetDiagnostic: WorkflowStepBudgetDiagnostic? = nil,
    instanceIdentity: String? = nil,
    instanceKind: String? = nil,
    instanceBaseIdentity: String? = nil,
    instanceConfiguration: JSONObject? = nil,
    activeStepId: String? = nil,
    activeExecutionId: String? = nil,
    activeBackend: NodeExecutionBackend? = nil,
    activeExecutionUpdatedAt: Date? = nil,
    activeBackendEventAt: Date? = nil,
    activeBackendEventType: String? = nil,
    backendSilentForMs: Int? = nil,
    activeSilentForMs: Int? = nil,
    executionCount: Int,
    executions: [WorkflowStepExecution],
    reviewFindingCount: Int = 0,
    reviewFindings: [WorkflowReviewFinding] = [],
    health: String? = nil,
    loopEvidenceRecorded: Bool = false,
    loopEvidence: LoopEvidenceSummary? = nil
  ) {
    self.sessionId = sessionId
    self.workflowName = workflowName
    self.status = status
    self.currentStepId = currentStepId
    self.lastCompletedStepId = lastCompletedStepId
    self.failureReason = failureReason
    self.failureKind = failureKind
    self.stepBudgetDiagnostic = stepBudgetDiagnostic
    self.instanceIdentity = instanceIdentity
    self.instanceKind = instanceKind
    self.instanceBaseIdentity = instanceBaseIdentity
    self.instanceConfiguration = instanceConfiguration
    self.activeStepId = activeStepId
    self.activeExecutionId = activeExecutionId
    self.activeBackend = activeBackend
    self.activeExecutionUpdatedAt = activeExecutionUpdatedAt
    self.activeBackendEventAt = activeBackendEventAt
    self.activeBackendEventType = activeBackendEventType
    self.backendSilentForMs = backendSilentForMs
    self.activeSilentForMs = activeSilentForMs
    self.executionCount = executionCount
    self.executions = executions
    self.reviewFindingCount = reviewFindingCount
    self.reviewFindings = reviewFindings
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
    let runningExecutions = snapshot.session.executions.filter { $0.status == .running }
    let activeExecution = runningExecutions.last
    let lastCompletedStepId = snapshot.session.executions.last { $0.status == .completed || $0.status == .skipped }?.stepId
    let result = SessionInspectionCommandResult(
      sessionId: snapshot.session.sessionId,
      workflowName: snapshot.session.workflowId,
      status: snapshot.session.status,
      currentStepId: snapshot.session.currentStepId,
      lastCompletedStepId: lastCompletedStepId,
      failureReason: snapshot.session.failureReason,
      failureKind: snapshot.session.failureKind,
      stepBudgetDiagnostic: snapshot.session.stepBudgetDiagnostic,
      instanceIdentity: snapshot.session.instanceIdentity,
      instanceKind: snapshot.session.instanceKind,
      instanceBaseIdentity: snapshot.session.instanceBaseIdentity,
      instanceConfiguration: snapshot.session.instanceConfiguration,
      activeStepId: activeExecution?.stepId,
      activeExecutionId: activeExecution?.executionId,
      activeBackend: activeExecution?.backend,
      activeExecutionUpdatedAt: activeExecution?.updatedAt,
      activeBackendEventAt: activeExecution?.lastBackendEventAt,
      activeBackendEventType: activeExecution?.lastBackendEventType,
      backendSilentForMs: activeExecution.flatMap(backendSilentForMs),
      activeSilentForMs: activeExecution.flatMap(activeSilentForMs),
      executionCount: snapshot.session.executions.count,
      executions: executionRows(for: command, allExecutions: snapshot.session.executions, runningExecutions: runningExecutions),
      reviewFindingCount: snapshot.session.reviewFindings.count,
      reviewFindings: snapshot.session.reviewFindings,
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
        "lastCompletedStepId: \(result.lastCompletedStepId ?? "-")",
        "failureKind: \(result.failureKind?.rawValue ?? "-")",
        "failureReason: \(result.failureReason ?? "-")",
        "instanceIdentity: \(result.instanceIdentity ?? "-")",
        "instanceKind: \(result.instanceKind ?? "-")",
        "instanceBaseIdentity: \(result.instanceBaseIdentity ?? "-")",
        "activeStepId: \(result.activeStepId ?? "-")",
        "activeExecutionId: \(result.activeExecutionId ?? "-")",
        "activeBackend: \(result.activeBackend?.rawValue ?? "-")",
        "activeExecutionUpdatedAt: \(result.activeExecutionUpdatedAt.map(iso8601String) ?? "-")",
        "activeBackendEventAt: \(result.activeBackendEventAt.map(iso8601String) ?? "-")",
        "activeBackendEventType: \(result.activeBackendEventType ?? "-")",
        "backendSilentForMs: \(result.backendSilentForMs.map(String.init) ?? "-")",
        "activeSilentForMs: \(result.activeSilentForMs.map(String.init) ?? "-")",
        "executionCount: \(result.executionCount)",
        "reviewFindingCount: \(result.reviewFindingCount)",
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
      if let diagnostic = result.stepBudgetDiagnostic {
        lines.append("stepBudget: \(diagnostic.stepBudget)")
        if let cycleStepIds = diagnostic.dominantCycleStepIds, let repeatCount = diagnostic.dominantCycleRepeatCount {
          lines.append("dominantCycle: \(cycleStepIds.joined(separator: " -> ")) (x\(repeatCount))")
        }
        if let perStepRevisitCap = diagnostic.perStepRevisitCap {
          lines.append("perStepRevisitCap: \(perStepRevisitCap)")
        }
        if let exceededStepIds = diagnostic.projectedCapExceededStepIds, !exceededStepIds.isEmpty {
          lines.append("projectedCapExceededStepIds: \(exceededStepIds.joined(separator: ","))")
        }
        lines.append("unscheduledStepId: \(diagnostic.unscheduledStepId ?? "-")")
        lines.append("suggestedRemediation: \(diagnostic.suggestedRemediation ?? "-")")
      }
      if command == "logs" {
        lines.append(contentsOf: snapshot.session.executions.compactMap { execution in
          execution.failureReason.map { "\(execution.executionId)\t\(execution.stepId)\t\($0)" }
        })
      }
      return CLICommandResult(exitCode: .success, stdout: lines.joined(separator: "\n") + "\n")
    }
  }

  private func executionRows(
    for command: String,
    allExecutions: [WorkflowStepExecution],
    runningExecutions: [WorkflowStepExecution]
  ) -> [WorkflowStepExecution] {
    switch command {
    case "status", "export", "step-runs":
      return allExecutions
    case "progress":
      return runningExecutions
    default:
      return []
    }
  }

  private func activeSilentForMs(_ execution: WorkflowStepExecution) -> Int? {
    guard execution.status == .running else {
      return nil
    }
    let lastSignalAt = execution.lastBackendEventAt ?? execution.updatedAt
    return max(0, Int(Date().timeIntervalSince(lastSignalAt) * 1_000))
  }

  private func backendSilentForMs(_ execution: WorkflowStepExecution) -> Int? {
    guard execution.status == .running, let lastSignalAt = execution.lastBackendEventAt else {
      return nil
    }
    return max(0, Int(Date().timeIntervalSince(lastSignalAt) * 1_000))
  }
}

private func iso8601String(_ date: Date) -> String {
  ISO8601DateFormatter().string(from: date)
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
      var bundle = try resolver.resolve(resolution)
      let instanceResolution = try resolveRerunInstance(
        persisted: persisted,
        workflowId: bundle.workflow.workflowId,
        workingDirectory: options.workingDirectory,
        nodePayloads: bundle.nodePayloads
      )
      bundle.nodePayloads = instanceResolution.nodePayloads
      let adapter = try makeAdapter(
        mockScenarioPath: options.mockScenarioPath ?? persisted.mockScenarioPath,
        workingDirectory: options.workingDirectory
      )
      let runtimeStore = InMemoryWorkflowRuntimeStore()
      try await seedRuntimeStoreFromPersistedCLIState(runtimeStore, sessionStoreRoot: storeRoot)
      let runner = DeterministicWorkflowRunner(
        store: runtimeStore,
        adapter: adapter,
        stdioNodeExecutor: LocalWorkflowStdioNodeExecutor(),
        simulatesCrossWorkflowDispatch: (options.mockScenarioPath ?? persisted.mockScenarioPath) != nil,
        calleeResolver: FileSystemWorkflowCalleeResolver(resolver: resolver, baseResolution: resolution)
      )
      let variables = instanceResolution.effectiveInstance?.configuration.defaultVariables
        ?? persisted.runtimeVariables
        ?? [:]
      let result = try await runner.run(
        DeterministicWorkflowRunRequest(
          workflow: bundle.workflow,
          nodePayloads: bundle.nodePayloads,
          variables: variables,
          rerunFromSessionId: persisted.session.sessionId,
          rerunFromStepId: options.stepId,
          effectiveInstance: instanceResolution.effectiveInstance
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
          mockScenarioPath: options.mockScenarioPath ?? persisted.mockScenarioPath,
          runtimeVariables: variables
        ),
        runtimeSnapshot: WorkflowRuntimePersistenceProjector.snapshot(
          session: result.session,
          workflowMessages: workflowMessages,
          loopEvidence: loopEvidence,
          loopMetadata: bundle.workflow.loop
        )
      )
      return renderRerunSuccess(options: options, result: result, warning: instanceResolution.warning)
    } catch let error as CLIWorkflowSessionStoreError {
      return failure(options: options, exitCode: .failure, error: "\(error)")
    } catch let error as DeterministicWorkflowRunnerError {
      return failure(options: options, exitCode: .failure, error: "\(error)")
    } catch {
      return failure(options: options, exitCode: .failure, error: "\(error)")
    }
  }

  private func renderRerunSuccess(
    options: SessionRerunOptions,
    result: WorkflowRunResult,
    warning: String?
  ) -> CLICommandResult {
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
      return CLICommandResult(
        exitCode: exitCode,
        stdout: stdout + (stdout.hasSuffix("\n") ? "" : "\n"),
        stderr: warning.map { "\($0)\n" } ?? ""
      )
    case .text, .table:
      let warningLine = warning.map { "warning: \($0)\n" } ?? ""
      return CLICommandResult(
        exitCode: exitCode,
        stdout: """
        \(warningLine)\
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

  private func resolveRerunInstance(
    persisted: PersistedCLIWorkflowSession,
    workflowId: String,
    workingDirectory: String,
    nodePayloads: [String: AgentNodePayload]
  ) throws -> SessionInstanceResolution {
    try resolvePersistedSessionInstance(
      persisted: persisted,
      workflowId: workflowId,
      workingDirectory: workingDirectory,
      nodePayloads: nodePayloads,
      commandName: "rerun"
    )
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
      if blocksResume(persisted.session) {
        return resumeFailure(
          options: options,
          exitCode: .failure,
          error: nonBudgetFailureResumeMessage(session: persisted.session)
        )
      }
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
      var bundle = try resolver.resolve(resolution)
      let instanceResolution = try resolvePersistedSessionInstance(
        persisted: persisted,
        workflowId: bundle.workflow.workflowId,
        workingDirectory: options.workingDirectory,
        nodePayloads: bundle.nodePayloads,
        commandName: "resume"
      )
      bundle.nodePayloads = instanceResolution.nodePayloads
      let adapter = try makeSessionNodeAdapter(
        mockScenarioPath: options.mockScenarioPath ?? persisted.mockScenarioPath,
        workingDirectory: options.workingDirectory
      )
      let runtimeStore = InMemoryWorkflowRuntimeStore()
      try await seedRuntimeStoreFromPersistedCLIState(runtimeStore, sessionStoreRoot: storeRoot)
      let runner = DeterministicWorkflowRunner(
        store: runtimeStore,
        adapter: adapter,
        stdioNodeExecutor: LocalWorkflowStdioNodeExecutor(),
        simulatesCrossWorkflowDispatch: (options.mockScenarioPath ?? persisted.mockScenarioPath) != nil,
        calleeResolver: FileSystemWorkflowCalleeResolver(resolver: resolver, baseResolution: resolution)
      )
      let effectiveMockScenarioPath = options.mockScenarioPath ?? persisted.mockScenarioPath
      let variables = try resumeRuntimeVariables(options: options, persisted: persisted)
      let result: WorkflowRunResult
      do {
        result = try await runner.run(
          DeterministicWorkflowRunRequest(
            workflow: bundle.workflow,
            nodePayloads: bundle.nodePayloads,
            variables: variables,
            maxSteps: options.maxSteps,
            resumeSessionId: persisted.session.sessionId
          )
        )
      } catch {
        do {
          try await persistFailedResumeSnapshot(
            persisted: persisted,
            resolution: resolution,
            mockScenarioPath: effectiveMockScenarioPath,
            storeRoot: storeRoot,
            runtimeStore: runtimeStore,
            bundle: bundle,
            runtimeVariables: variables
          )
        } catch let persistenceError {
          return resumeFailure(
            options: options,
            exitCode: .failure,
            error: "\(error); failed to persist failed resume snapshot: \(persistenceError)"
          )
        }
        throw error
      }
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
          mockScenarioPath: effectiveMockScenarioPath,
          runtimeVariables: variables
        ),
        runtimeSnapshot: WorkflowRuntimePersistenceProjector.snapshot(
          session: result.session,
          workflowMessages: workflowMessages,
          loopEvidence: loopEvidence,
          loopMetadata: bundle.workflow.loop
        )
      )
      return renderResumeSuccess(options: options, result: result, warning: instanceResolution.warning)
    } catch let error as CLIWorkflowSessionStoreError {
      return resumeFailure(options: options, exitCode: .failure, error: "\(error)")
    } catch let error as DeterministicWorkflowRunnerError {
      return resumeFailure(options: options, exitCode: .failure, error: "\(error)")
    } catch {
      return resumeFailure(options: options, exitCode: .failure, error: "\(error)")
    }
  }

  private func persistFailedResumeSnapshot(
    persisted: PersistedCLIWorkflowSession,
    resolution: WorkflowResolutionOptions,
    mockScenarioPath: String?,
    storeRoot: String,
    runtimeStore: InMemoryWorkflowRuntimeStore,
    bundle: ResolvedWorkflowBundle,
    runtimeVariables: JSONObject
  ) async throws {
    guard let session = try await runtimeStore.loadSession(id: persisted.session.sessionId) else {
      return
    }
    let workflowMessages = try await runtimeStore.listMessages(for: session.sessionId, toStepId: nil)
    let recovery = LoopRecoveryLineage(
      entryMode: .resume,
      sourceSessionId: persisted.session.sessionId,
      parentSessionId: persisted.session.sessionId,
      reason: "resume existing session",
      inputReusePolicy: "existing-session"
    )
    let loopEvidence = projectLoopEvidence(
      session: session,
      workflowMessages: workflowMessages,
      bundle: bundle,
      recovery: recovery
    )
    try CLIWorkflowSessionStore(rootDirectory: storeRoot).save(
      PersistedCLIWorkflowSession(
        workflowName: persisted.workflowName,
        session: session,
        resolution: resolution,
        mockScenarioPath: mockScenarioPath,
        runtimeVariables: runtimeVariables
      ),
      runtimeSnapshot: WorkflowRuntimePersistenceProjector.snapshot(
        session: session,
        workflowMessages: workflowMessages,
        loopEvidence: loopEvidence,
        loopMetadata: bundle.workflow.loop
      )
    )
  }

  private func renderResumeSuccess(
    options: SessionResumeOptions,
    result: WorkflowRunResult,
    warning: String?
  ) -> CLICommandResult {
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
      return CLICommandResult(
        exitCode: exitCode,
        stdout: stdout + (stdout.hasSuffix("\n") ? "" : "\n"),
        stderr: warning.map { "\($0)\n" } ?? ""
      )
    case .text, .table:
      let warningLine = warning.map { "warning: \($0)\n" } ?? ""
      return CLICommandResult(
        exitCode: exitCode,
        stdout: """
        \(warningLine)\
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

  private func blocksResume(_ session: WorkflowSession) -> Bool {
    session.status == .failed && session.failureKind != .maxStepsExceeded
  }

  private func nonBudgetFailureResumeMessage(session: WorkflowSession) -> String {
    let failureKind = session.failureKind?.rawValue ?? "unknown"
    let rerunStepId = session.currentStepId ?? session.entryStepId
    return """
    session \(session.sessionId) failed with failureKind \(failureKind) and cannot be resumed; use \
    `riela session rerun \(session.sessionId) \(rerunStepId)` to rerun from a step, or inspect with \
    `riela session progress \(session.sessionId)`.
    """
  }

  private func resumeRuntimeVariables(
    options: SessionResumeOptions,
    persisted: PersistedCLIWorkflowSession
  ) throws -> JSONObject {
    if let variablesReference = options.variables {
      return try JSONReferenceLoader().object(from: variablesReference, workingDirectory: options.workingDirectory)
    }
    return persisted.runtimeVariables ?? [:]
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
