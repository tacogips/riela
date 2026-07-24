import ArgumentParser
import Foundation
import RielaAdapters
import RielaCore

public struct SessionInspectionCommandResult: Codable, Equatable, Sendable {
  public var sessionId: String
  public var parentSessionId: String?
  public var rootSessionId: String
  public var workflowName: String
  public var status: WorkflowSessionStatus
  public var currentStepId: String?
  public var currentStage: String?
  public var lastCompletedStepId: String?
  public var failureReason: String?
  public var failureKind: WorkflowSessionFailureKind?
  public var stepBudgetDiagnostic: WorkflowStepBudgetDiagnostic?
  public var instanceIdentity: String?
  public var instanceKind: String?
  public var instanceBaseIdentity: String?
  public var instanceConfiguration: JSONObject?
  public var activeStepId: String?
  public var activeStage: String?
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
  public var progress: SessionProgressDigest?
  public var rollup: SessionRollupNode?
  public var backendActivity: SessionBackendActivity?

  public init(
    sessionId: String,
    parentSessionId: String? = nil,
    rootSessionId: String? = nil,
    workflowName: String,
    status: WorkflowSessionStatus,
    currentStepId: String?,
    currentStage: String? = nil,
    lastCompletedStepId: String? = nil,
    failureReason: String? = nil,
    failureKind: WorkflowSessionFailureKind? = nil,
    stepBudgetDiagnostic: WorkflowStepBudgetDiagnostic? = nil,
    instanceIdentity: String? = nil,
    instanceKind: String? = nil,
    instanceBaseIdentity: String? = nil,
    instanceConfiguration: JSONObject? = nil,
    activeStepId: String? = nil,
    activeStage: String? = nil,
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
    loopEvidence: LoopEvidenceSummary? = nil,
    progress: SessionProgressDigest? = nil,
    rollup: SessionRollupNode? = nil,
    backendActivity: SessionBackendActivity? = nil
  ) {
    self.sessionId = sessionId
    self.parentSessionId = parentSessionId
    self.rootSessionId = rootSessionId ?? sessionId
    self.workflowName = workflowName
    self.status = status
    self.currentStepId = currentStepId
    self.currentStage = currentStage
    self.lastCompletedStepId = lastCompletedStepId
    self.failureReason = failureReason
    self.failureKind = failureKind
    self.stepBudgetDiagnostic = stepBudgetDiagnostic
    self.instanceIdentity = instanceIdentity
    self.instanceKind = instanceKind
    self.instanceBaseIdentity = instanceBaseIdentity
    self.instanceConfiguration = instanceConfiguration
    self.activeStepId = activeStepId
    self.activeStage = activeStage
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
    self.progress = progress
    self.rollup = rollup
    self.backendActivity = backendActivity
  }
}

public struct SessionInspectionCommand: Sendable {
  public var clock: any WorkflowRuntimeClock
  public var sleeper: any SessionFollowSleeping
  public var followRecordWriter: (@Sendable (String) -> Void)?
  var observabilityServiceFactory:
    @Sendable (SQLiteWorkflowRuntimePersistenceStore, any WorkflowRuntimeClock) -> SessionObservabilityService

  public init(
    clock: any WorkflowRuntimeClock = SystemWorkflowRuntimeClock(),
    sleeper: any SessionFollowSleeping = SystemSessionFollowSleeper(),
    followRecordWriter: (@Sendable (String) -> Void)? = nil
  ) {
    self.clock = clock
    self.sleeper = sleeper
    self.followRecordWriter = followRecordWriter
    self.observabilityServiceFactory = { store, clock in
      SessionObservabilityComposition.makeService(store: store, clock: clock)
    }
  }

  init(
    clock: any WorkflowRuntimeClock,
    sleeper: any SessionFollowSleeping,
    followRecordWriter: (@Sendable (String) -> Void)?,
    observabilityServiceFactory:
      @escaping @Sendable (SQLiteWorkflowRuntimePersistenceStore, any WorkflowRuntimeClock)
      -> SessionObservabilityService
  ) {
    self.clock = clock
    self.sleeper = sleeper
    self.followRecordWriter = followRecordWriter
    self.observabilityServiceFactory = observabilityServiceFactory
  }

  public func run(_ options: CLICommandOptions) async -> CLICommandResult {
    guard let sessionId = options.target, !sessionId.isEmpty else {
      return CLICommandResult(exitCode: .usage, stderr: "scope, command, and target are required")
    }
    do {
      let parsed = try parseSessionInspectionOptions(options.arguments)
      let command = options.command ?? "status"
      try validateObservabilityOptions(parsed, command: command, output: options.output, arguments: options.arguments)
      let isObservabilityRead = command == "progress" || command == "health"
      let store = try runtimeStore(
        sessionId: sessionId,
        parsed: parsed,
        strictReadOnly: isObservabilityRead
      )
      let service = observabilityServiceFactory(store, clock)
      if command == "progress" {
        if parsed.follow {
          return try await follow(
            sessionId: sessionId,
            includeChildren: parsed.includeChildren,
            pollInterval: parsed.pollInterval,
            output: options.output,
            service: service
          )
        }
        let observation = try service.progressObservation(
          sessionId: sessionId,
          includeChildren: parsed.includeChildren
        )
        return try render(
          snapshot: observation.snapshot,
          command: command,
          output: options.output,
          observabilityView: observation.view
        )
      }
      if command == "health" {
        let observation = try service.healthObservation(sessionId: sessionId)
        return try render(
          snapshot: observation.snapshot,
          command: command,
          output: options.output,
          observabilityView: observation.view
        )
      }
      let snapshot = try store.load(sessionId: sessionId)
      return try render(snapshot: snapshot, command: command, output: options.output)
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

  private struct ParsedOptions: ParsableArguments {
    @Option var scope = WorkflowScope.auto
    @Option(name: [.customLong("working-dir"), .customLong("working-directory")])
    var workingDirectory = FileManager.default.currentDirectoryPath
    @Option var sessionStore: String?
    @Option private var output: String?
    @Flag var follow = false
    @Option(name: .customLong("poll-interval")) var pollInterval = 2.0
    @Flag(name: .customLong("include-children")) var includeChildren = false

    init() {}

    init(_ arguments: [String]) throws {
      do {
        self = try Self.parse(arguments)
      } catch {
        throw CLIUsageError(Self.message(for: error))
      }
      guard scope != .direct else {
        throw CLIUsageError("invalid --scope value; expected auto, project, or user")
      }
      guard pollInterval.isFinite, (0.1...3600).contains(pollInterval) else {
        throw CLIUsageError("--poll-interval requires a finite value between 0.1 and 3600 seconds")
      }
    }
  }

  private func parseSessionInspectionOptions(_ arguments: [String]) throws -> ParsedOptions {
    try ParsedOptions(arguments)
  }

  private func validateObservabilityOptions(
    _ parsed: ParsedOptions,
    command: String,
    output: WorkflowOutputFormat,
    arguments: [String]
  ) throws {
    let suppliedPollInterval = arguments.contains {
      $0 == "--poll-interval" || $0.hasPrefix("--poll-interval=")
    }
    if command != "progress", parsed.follow || parsed.includeChildren || suppliedPollInterval {
      throw CLIUsageError("--follow, --poll-interval, and --include-children are valid only for session progress")
    }
    if parsed.follow, output == .json {
      throw CLIUsageError("session progress --follow does not support --output json; use --output jsonl")
    }
  }

  private func follow(
    sessionId: String,
    includeChildren: Bool,
    pollInterval: Double,
    output: WorkflowOutputFormat,
    service: SessionObservabilityService
  ) async throws -> CLICommandResult {
    var previousStatuses: [String: WorkflowSessionStatus] = [:]
    var bufferedOutput = ""
    while true {
      try Task.checkCancellation()
      let view = try service.progress(
        sessionId: sessionId,
        includeChildren: includeChildren,
        previousStatuses: previousStatuses
      )
      let record: String
      switch output {
      case .jsonl:
        record = try jsonString(view)
      case .text, .table:
        var lines: [String] = []
        if let truncated = view.rollupTruncated {
          lines.append("rollupTruncated: \(truncated ? "true" : "false")")
        }
        if let limit = view.rollupSnapshotLimit {
          lines.append("rollupSnapshotLimit: \(limit)")
        }
        lines.append(contentsOf: progressTreeLines(view.root))
        record = lines.joined(separator: "\n") + "\n"
      case .json:
        throw CLIUsageError("session progress --follow does not support --output json; use --output jsonl")
      }
      if let followRecordWriter {
        followRecordWriter(record)
      } else {
        bufferedOutput += record
      }
      previousStatuses = statuses(in: view.root)
      if SessionObservabilityService.isTerminal(view.root) {
        if includeChildren, view.rollupTruncated == true {
          return CLICommandResult(
            exitCode: .failure,
            stdout: bufferedOutput,
            stderr: "session progress --follow cannot confirm terminal state because the child rollup is truncated"
          )
        }
        return CLICommandResult(exitCode: .success, stdout: bufferedOutput)
      }
      try await sleeper.sleep(seconds: pollInterval)
    }
  }

  private func statuses(in root: SessionRollupNode) -> [String: WorkflowSessionStatus] {
    var result = [root.digest.sessionId: root.digest.status]
    for child in root.children {
      result.merge(statuses(in: child)) { _, new in new }
    }
    return result
  }

  func progressTreeLines(_ root: SessionRollupNode, depth: Int = 0) -> [String] {
    let digest = root.digest
    let prefix = String(repeating: "  ", count: depth)
    var lines = [
      "\(prefix)sessionId: \(digest.sessionId)",
      "\(prefix)workflow: \(digest.workflowId)",
      "\(prefix)parentSessionId: \(digest.parentSessionId ?? "-")",
      "\(prefix)rootSessionId: \(digest.rootSessionId)",
      "\(prefix)status: \(digest.status.rawValue)",
      "\(prefix)failureKind: \(digest.failureKind?.rawValue ?? "-")",
      "\(prefix)previousStatus: \(digest.previousStatus?.rawValue ?? "-")",
      "\(prefix)currentStepId: \(digest.currentStepId ?? "-")",
      "\(prefix)currentStage: \(digest.currentStage ?? "-")",
      "\(prefix)executions: \(digest.executionCount)/\(digest.effectiveStepBudget.map(String.init) ?? "-")",
      "\(prefix)gateVisits: \(gateVisitDescription(digest.gateVisitCounts))",
      "\(prefix)lastBackendEventType: \(digest.lastBackendEventType ?? "-")",
      "\(prefix)lastBackendEventAgeMs: \(digest.lastBackendEventAgeMs.map(String.init) ?? "-")",
      "\(prefix)activeBackend: \(digest.activeBackend?.rawValue ?? "-")",
      "\(prefix)observedAt: \(iso8601String(digest.observedAt))"
    ]
    for child in root.children {
      lines.append("\(prefix)child:")
      lines.append(contentsOf: progressTreeLines(child, depth: depth + 1))
    }
    return lines
  }

  private func gateVisitDescription(_ counts: [String: Int]) -> String {
    guard !counts.isEmpty else {
      return "-"
    }
    return counts.keys.sorted().map { "\($0)=\(counts[$0] ?? 0)" }.joined(separator: ",")
  }

  func homeAbbreviatedPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    guard path == home || path.hasPrefix(home + "/") else {
      return path
    }
    return "~" + path.dropFirst(home.count)
  }

  private func runtimeStore(
    sessionId: String,
    parsed: ParsedOptions,
    strictReadOnly: Bool
  ) throws -> SQLiteWorkflowRuntimePersistenceStore {
    let loaded = try CLIWorkflowSessionResolution.loadPersistedSession(
      sessionId: sessionId,
      sessionStore: parsed.sessionStore,
      scope: parsed.scope,
      workingDirectory: parsed.workingDirectory,
      strictReadOnly: strictReadOnly
    )
    return SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: loaded.storeRoot)
    )
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
      // Rerun re-acquires the same advisory per-workflow lease as a fresh run
      // (design S11); the lease binds to the new session on its first save.
      var pendingLease: String?
      switch try loopConcurrencyPreflight(
        workflow: bundle.workflow,
        sessionStoreRoot: storeRoot,
        output: options.output
      ) {
      case let .busyFail(result):
        return result
      case let .busySkip(result):
        return result
      case let .proceed(leaseHolder, _):
        pendingLease = leaseHolder
      }
      defer {
        releasePendingLoopConcurrencyLease(
          workflow: bundle.workflow,
          sessionStoreRoot: storeRoot,
          leaseHolder: pendingLease
        )
      }
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
      let eventHandler = await makeSessionCommandLivePersistenceHandler(
        configuration: SessionLivePersistenceConfig(
          workflowName: persisted.workflowName,
          resolution: resolution,
          storeRoot: storeRoot,
          bundle: bundle,
          variables: variables,
          runtimeStore: runtimeStore,
          mockScenarioPath: options.mockScenarioPath ?? persisted.mockScenarioPath,
          workingDirectory: options.workingDirectory
        )
      )
      let result = try await runner.run(
        DeterministicWorkflowRunRequest(
          workflow: bundle.workflow,
          nodePayloads: bundle.nodePayloads,
          variables: variables,
          rerunFromSessionId: persisted.session.sessionId,
          rerunFromStepId: options.stepId,
          sourceRecoveryLineage: persistedRecoveryLineage(
            sessionId: persisted.session.sessionId,
            storeRoot: storeRoot
          ),
          effectiveInstance: instanceResolution.effectiveInstance,
          eventHandler: eventHandler
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
      // Resume re-acquires the same advisory per-workflow lease as a fresh
      // run (design S11); the lease binds to the resumed session on its
      // first save.
      var pendingLease: String?
      switch try loopConcurrencyPreflight(
        workflow: bundle.workflow,
        sessionStoreRoot: storeRoot,
        output: options.output
      ) {
      case let .busyFail(result):
        return result
      case let .busySkip(result):
        return result
      case let .proceed(leaseHolder, _):
        pendingLease = leaseHolder
      }
      defer {
        releasePendingLoopConcurrencyLease(
          workflow: bundle.workflow,
          sessionStoreRoot: storeRoot,
          leaseHolder: pendingLease
        )
      }
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
      let eventHandler = await makeSessionCommandLivePersistenceHandler(
        configuration: SessionLivePersistenceConfig(
          workflowName: persisted.workflowName,
          resolution: resolution,
          storeRoot: storeRoot,
          bundle: bundle,
          variables: variables,
          runtimeStore: runtimeStore,
          mockScenarioPath: effectiveMockScenarioPath,
          workingDirectory: options.workingDirectory
        )
      )
      let result: WorkflowRunResult
      do {
        result = try await runner.run(
          DeterministicWorkflowRunRequest(
            workflow: bundle.workflow,
            nodePayloads: bundle.nodePayloads,
            variables: variables,
            maxSteps: options.maxSteps,
            resumeSessionId: persisted.session.sessionId,
            sourceRecoveryLineage: persistedRecoveryLineage(
              sessionId: persisted.session.sessionId,
              storeRoot: storeRoot
            ),
            eventHandler: eventHandler
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

/// Reads the recovery lineage persisted on the source session's evidence
/// manifest so rerun/resume entries can thread `rootSessionId`/`attemptNumber`
/// (and the runner can enforce `budget.maxSessionAttempts`) without walking
/// session chains. Absent snapshots or manifests degrade to nil (attempt one).
private func persistedRecoveryLineage(
  sessionId: String,
  storeRoot: String
) -> LoopRecoveryLineage? {
  let store = SQLiteWorkflowRuntimePersistenceStore(
    rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: storeRoot)
  )
  return (try? store.load(sessionId: sessionId))?.loopEvidence?.recovery
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
    mutable: bundle.provenance == .mutable
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
