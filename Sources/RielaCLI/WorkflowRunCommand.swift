import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RielaAdapters
import RielaAddons
import RielaCore
import RielaObservability

public struct WorkflowRunCommand: Sendable {
  public var resolver: any WorkflowBundleResolving
  public var patchApplier: any WorkflowNodePatchApplying
  public var jsonLoader: JSONReferenceLoader
  public var graphQLTransport: any WorkflowGraphQLRunTransporting
  public var jsonlRecordWriter: WorkflowJSONLRecordWriting?

  public init(
    resolver: any WorkflowBundleResolving = FileSystemWorkflowBundleResolver(),
    patchApplier: any WorkflowNodePatchApplying = DefaultWorkflowNodePatchApplier(),
    jsonLoader: JSONReferenceLoader = JSONReferenceLoader(),
    graphQLTransport: any WorkflowGraphQLRunTransporting = URLSessionWorkflowGraphQLRunTransport(),
    jsonlRecordWriter: WorkflowJSONLRecordWriting? = nil
  ) {
    self.resolver = resolver
    self.patchApplier = patchApplier
    self.jsonLoader = jsonLoader
    self.graphQLTransport = graphQLTransport
    self.jsonlRecordWriter = jsonlRecordWriter
  }

  public func run(_ options: WorkflowRunOptions) async -> CLICommandResult {
    var livePersistenceState: WorkflowRunLivePersistenceState?
    do {
      try rejectUnsupportedRunOptions(options)
      if let endpoint = options.endpoint {
        return try await runRemote(endpoint: endpoint, options: options)
      }
      let resolution = options.resolution ?? WorkflowResolutionOptions(
        workflowName: options.target,
        workingDirectory: options.workingDirectory
      )
      var bundle = try resolveRunBundle(options: options, resolution: resolution)
      if let patch = options.nodePatch {
        bundle.nodePayloads = try patchApplier.applyNodePatch(
          jsonLoader.object(from: patch, workingDirectory: options.workingDirectory),
          to: bundle.nodePayloads
        )
      }
      let variables = try parseVariables(options.variables, workingDirectory: options.workingDirectory)
      let adapter = try makeScenarioBackedNodeAdapter(
        scenarioPath: options.mockScenarioPath,
        workingDirectory: options.workingDirectory,
        autoImprove: options.autoImprove
      )
      let stdioNodeExecutor = try makeScenarioBackedStdioNodeExecutor(
        scenarioPath: options.mockScenarioPath,
        workingDirectory: options.workingDirectory
      )
      let addonResolver = try makeScenarioBackedAddonResolver(
        scenarioPath: options.mockScenarioPath,
        workingDirectory: options.workingDirectory
      )
      let persistedResolution = CLIWorkflowSessionResolution.resolutionForPersistence(
        resolution: resolution,
        resolvedSourceScope: bundle.sourceScope
      )
      let storeRoot = CLIWorkflowSessionStore.resolveRootDirectory(
        sessionStore: options.sessionStore,
        scope: persistedResolution.scope,
        workingDirectory: options.workingDirectory
      )
      let runtimeStore = InMemoryWorkflowRuntimeStore()
      try await seedRuntimeStoreFromPersistedCLIState(runtimeStore, sessionStoreRoot: storeRoot)
      let telemetry = RielaTelemetryFactory.make(configuration: .fromEnvironment(
        CLIRuntimeEnvironment.mergedProcessEnvironment(),
        surface: .cli
      ))
      let runner = DeterministicWorkflowRunner(
        store: runtimeStore,
        adapter: adapter,
        addonResolver: addonResolver,
        stdioNodeExecutor: stdioNodeExecutor,
        telemetry: telemetry
      )
      let persistedIdentity = persistenceIdentity(
        requestedResolution: resolution,
        bundle: bundle,
        fromRegistry: options.fromRegistry
      )
      let jsonlRecorder = options.output == .jsonl ? WorkflowRunJSONLRecorder(writer: jsonlRecordWriter) : nil
      let persistenceState = WorkflowRunLivePersistenceState()
      await persistenceState.configure(storeRoot: storeRoot)
      livePersistenceState = persistenceState
      let persistenceBundle = bundle
      let runEventHandler: WorkflowRunEventHandler = { event in
        if workflowRunEventTriggersLiveSessionPersistence(event) {
          await persistLiveSessionRecordIfPresent(
            sessionId: event.sessionId,
            workflowName: persistedIdentity.workflowName,
            resolution: persistedIdentity.resolution,
            storeRoot: storeRoot,
            bundle: persistenceBundle,
            variables: variables,
            runtimeStore: runtimeStore,
            options: options,
            recorder: jsonlRecorder,
            state: persistenceState
          )
        }
        if let jsonlRecorder {
          await jsonlRecorder.append(event)
        }
      }
      let initialRequest = DeterministicWorkflowRunRequest(
        workflow: bundle.workflow,
        nodePayloads: bundle.nodePayloads,
        variables: variables,
        maxSteps: options.maxSteps,
        maxConcurrency: options.maxConcurrency,
        maxLoopIterations: options.maxLoopIterations,
        defaultTimeoutMs: options.defaultTimeoutMs,
        timeoutMs: options.timeoutMs,
        agentSilenceWarningMs: options.agentSilenceWarningMs,
        agentSilenceMonitorIntervalMs: options.agentSilenceMonitorIntervalMs,
        eventHandler: runEventHandler
      )
      if options.autoImprove {
        var finalResult = try await runWithAutoImprove(
          initialRequest: initialRequest,
          runner: runner,
          workflow: bundle.workflow,
          nodePayloads: bundle.nodePayloads,
          variables: variables,
          options: options,
          runtimeStore: runtimeStore
        )
        let workflowMessages = try await runtimeStore.listMessages(for: finalResult.session.sessionId, toStepId: nil)
        let loopEvidence = projectLoopEvidence(
          session: finalResult.session,
          workflowMessages: workflowMessages,
          bundle: bundle,
          variables: variables,
          recovery: finalResult.recovery
        )
        finalResult.loopEvidence = loopEvidence.map(LoopEvidenceSummary.init)
        applyRequiredLoopGateFailureIfNeeded(&finalResult, loopEvidence: loopEvidence, workflow: bundle.workflow)
        try persistSessionRecord(
          workflowName: persistedIdentity.workflowName,
          resolution: persistedIdentity.resolution,
          resolvedSourceScope: bundle.sourceScope,
          result: finalResult,
          workflowMessages: workflowMessages,
          bundle: bundle,
          variables: variables,
          options: options,
          loopEvidence: loopEvidence
        )
        await telemetry.flush(timeout: .seconds(2))
        return CLICommandResult(
          exitCode: CLIExitCode(rawValue: finalResult.exitCode) ?? .failure,
          stdout: try await renderRunResult(finalResult, output: options.output, jsonlRecorder: jsonlRecorder)
        )
      }
      var finalResult = try await runner.run(initialRequest)
      let workflowMessages = try await runtimeStore.listMessages(for: finalResult.session.sessionId, toStepId: nil)
      let loopEvidence = projectLoopEvidence(
        session: finalResult.session,
        workflowMessages: workflowMessages,
        bundle: bundle,
        variables: variables,
        recovery: finalResult.recovery
      )
      finalResult.loopEvidence = loopEvidence.map(LoopEvidenceSummary.init)
      applyRequiredLoopGateFailureIfNeeded(&finalResult, loopEvidence: loopEvidence, workflow: bundle.workflow)
      try persistSessionRecord(
        workflowName: persistedIdentity.workflowName,
        resolution: persistedIdentity.resolution,
        resolvedSourceScope: bundle.sourceScope,
        result: finalResult,
        workflowMessages: workflowMessages,
        bundle: bundle,
        variables: variables,
        options: options,
        loopEvidence: loopEvidence
      )
      await telemetry.flush(timeout: .seconds(2))
      return CLICommandResult(
        exitCode: CLIExitCode(rawValue: finalResult.exitCode) ?? .failure,
        stdout: try await renderRunResult(finalResult, output: options.output, jsonlRecorder: jsonlRecorder)
      )
    } catch let error as CLIUsageError {
      return await renderRunFailure(options: options, exitCode: .usage, error: error.message, state: livePersistenceState)
    } catch {
      return await renderRunFailure(options: options, exitCode: .failure, error: "\(error)", state: livePersistenceState)
    }
  }

  private func applyRequiredLoopGateFailureIfNeeded(
    _ result: inout WorkflowRunResult,
    loopEvidence: LoopEvidenceManifest?,
    workflow: WorkflowDefinition
  ) {
    guard workflow.loop?.required == true,
          let loopEvidence,
          loopEvidence.gates.contains(where: { !$0.blockingFindings.isEmpty }) else {
      return
    }
    result.exitCode = 1
    result.status = .failed
    result.session.status = .failed
  }

  private func persistLiveSessionRecordIfPresent(
    sessionId: String,
    workflowName: String,
    resolution: WorkflowResolutionOptions,
    storeRoot: String,
    bundle: ResolvedWorkflowBundle,
    variables: JSONObject,
    runtimeStore: InMemoryWorkflowRuntimeStore,
    options: WorkflowRunOptions,
    recorder: WorkflowRunJSONLRecorder?,
    state: WorkflowRunLivePersistenceState
  ) async {
    do {
      guard let session = try await runtimeStore.loadSession(id: sessionId) else {
        return
      }
      let workflowMessages = try await runtimeStore.listMessages(for: sessionId, toStepId: nil)
      let snapshot = runtimeSnapshot(
        session: session,
        workflowMessages: workflowMessages,
        bundle: bundle,
        variables: variables
      )
      let artifactRoot = options.artifactRoot.map {
        absoluteURL(
          $0,
          relativeTo: URL(fileURLWithPath: options.workingDirectory, isDirectory: true)
        ).path
      }
      try await state.persistLiveSnapshot(
        WorkflowRunLivePersistenceSaveInput(
          persistedSession: PersistedCLIWorkflowSession(
            workflowName: workflowName,
            session: session,
            resolution: resolution,
            mockScenarioPath: options.mockScenarioPath
          ),
          runtimeSnapshot: snapshot,
          workflowMessages: workflowMessages,
          artifactRoot: artifactRoot
        )
      )
    } catch {
      await state.recordFailure(sessionId: sessionId, error: "\(error)")
      if let recorder {
        await recorder.append((try? jsonString(WorkflowRunPersistenceFailureRecord(sessionId: sessionId, error: "\(error)"))) ?? "")
      }
    }
  }

  private func runRemote(endpoint: String, options: WorkflowRunOptions) async throws -> CLICommandResult {
    if options.fromRegistry {
      throw CLIUsageError("workflow run --from-registry is local-only and cannot be combined with --endpoint")
    }
    if options.mockScenarioPath != nil {
      throw CLIUsageError("--mock-scenario cannot be combined with --endpoint")
    }
    let variables = try parseVariables(options.variables, workingDirectory: options.workingDirectory)
    let nodePatch = try options.nodePatch.map { try jsonLoader.object(from: $0, workingDirectory: options.workingDirectory) }
    let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
    let configuredAuthTokenEnv = nonEmptyString(options.authTokenEnv)
    let authTokenEnv = configuredAuthTokenEnv ?? "RIELA_MANAGER_AUTH_TOKEN"
    let authToken = nonEmptyString(options.authToken)
      ?? nonEmptyString(environment[authTokenEnv])
    let managerSessionId = nonEmptyString(environment["RIELA_MANAGER_SESSION_ID"])
    let request = WorkflowRemoteRunRequest(
      workflowName: options.target,
      runtimeVariables: variables,
      nodePatch: nodePatch,
      autoImprove: options.autoImprove,
      autoImprovePolicy: options.autoImprovePolicy,
      maxSteps: options.maxSteps,
      maxConcurrency: options.maxConcurrency,
      maxLoopIterations: options.maxLoopIterations,
      defaultTimeoutMs: options.defaultTimeoutMs,
      timeoutMs: options.timeoutMs,
      authToken: authToken,
      authTokenEnv: authTokenEnv,
      managerSessionId: managerSessionId
    )
    let result = try await graphQLTransport.executeWorkflow(endpoint: endpoint, request: request)
    return CLICommandResult(
      exitCode: CLIExitCode(rawValue: result.exitCode) ?? .failure,
      stdout: try renderRemoteRunResult(result, output: options.output)
    )
  }

  private func parseVariables(_ reference: String?, workingDirectory: String) throws -> JSONObject {
    guard let reference else {
      return [:]
    }
    return try jsonLoader.object(from: reference, workingDirectory: workingDirectory)
  }

  private func rejectUnsupportedRunOptions(_ options: WorkflowRunOptions) throws {
    if options.fromRegistry && isTemporaryWorkflowRunTarget(options.target, workingDirectory: options.workingDirectory) {
      throw CLIUsageError("temporary workflow JSON cannot be combined with --from-registry")
    }
  }

  private func persistSessionRecord(
    workflowName: String,
    resolution: WorkflowResolutionOptions,
    resolvedSourceScope: WorkflowScope,
    result: WorkflowRunResult,
    workflowMessages: [WorkflowMessageRecord],
    bundle: ResolvedWorkflowBundle,
    variables: JSONObject,
    options: WorkflowRunOptions,
    loopEvidence: LoopEvidenceManifest? = nil
  ) throws {
    let persistedResolution = CLIWorkflowSessionResolution.resolutionForPersistence(
      resolution: resolution,
      resolvedSourceScope: resolvedSourceScope
    )
    let storeRoot = CLIWorkflowSessionStore.resolveRootDirectory(
      sessionStore: options.sessionStore,
      scope: persistedResolution.scope,
      workingDirectory: options.workingDirectory
    )
    let snapshot = runtimeSnapshot(
      session: result.session,
      workflowMessages: workflowMessages,
      bundle: bundle,
      variables: variables,
      recovery: result.recovery,
      loopEvidence: loopEvidence
    )
    try CLIWorkflowSessionStore(rootDirectory: storeRoot).save(
      PersistedCLIWorkflowSession(
        workflowName: workflowName,
        session: result.session,
        resolution: persistedResolution,
        mockScenarioPath: options.mockScenarioPath
      ),
      runtimeSnapshot: snapshot
    )
    if let artifactRoot = options.artifactRoot {
      let artifactURL = absoluteURL(artifactRoot, relativeTo: URL(fileURLWithPath: options.workingDirectory, isDirectory: true))
      try FileWorkflowRuntimePersistenceStore(rootDirectory: artifactURL.path).save(snapshot)
    }
    if options.autoImprove, let supervision = result.supervision {
      try persistSupervisionRecord(
        sessionId: result.session.sessionId,
        storeRoot: storeRoot,
        workflowName: workflowName,
        supervision: supervision
      )
    }
  }

  private func runtimeSnapshot(
    session: WorkflowSession,
    workflowMessages: [WorkflowMessageRecord],
    bundle: ResolvedWorkflowBundle,
    variables: JSONObject,
    recovery: LoopRecoveryLineage? = nil,
    loopEvidence: LoopEvidenceManifest? = nil
  ) -> WorkflowRuntimePersistenceSnapshot {
    let projectedLoopEvidence = loopEvidence ?? projectLoopEvidence(
      session: session,
      workflowMessages: workflowMessages,
      bundle: bundle,
      variables: variables,
      recovery: recovery
    )
    return WorkflowRuntimePersistenceProjector.snapshot(
      session: session,
      workflowMessages: workflowMessages,
      loopEvidence: projectedLoopEvidence
    )
  }

  private func projectLoopEvidence(
    session: WorkflowSession,
    workflowMessages: [WorkflowMessageRecord],
    bundle: ResolvedWorkflowBundle,
    variables: JSONObject,
    recovery: LoopRecoveryLineage? = nil
  ) -> LoopEvidenceManifest? {
    try? DefaultLoopEvidenceProjector().project(
      LoopEvidenceProjectionInput(
        workflow: bundle.workflow,
        session: session,
        workflowMessages: workflowMessages,
        workflowSource: loopWorkflowSource(from: bundle),
        variables: variables,
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

  private func persistenceIdentity(
    requestedResolution: WorkflowResolutionOptions,
    bundle: ResolvedWorkflowBundle,
    fromRegistry: Bool
  ) -> (workflowName: String, resolution: WorkflowResolutionOptions) {
    guard fromRegistry else {
      return (requestedResolution.workflowName, requestedResolution)
    }
    return (
      bundle.workflow.workflowId,
      WorkflowResolutionOptions(
        workflowName: bundle.workflow.workflowId,
        scope: bundle.sourceScope,
        workflowDefinitionDir: bundle.workflowDirectory,
        workingDirectory: requestedResolution.workingDirectory
      )
    )
  }

  private func persistSupervisionRecord(
    sessionId: String,
    storeRoot: String,
    workflowName: String,
    supervision: JSONObject
  ) throws {
    let directory = URL(fileURLWithPath: canonicalRuntimeStoreRoot(sessionStoreRoot: storeRoot), isDirectory: true)
      .appendingPathComponent(sessionId, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var record = supervision
    record["sessionId"] = .string(sessionId)
    record["workflowName"] = .string(workflowName)
    try jsonString(record).write(to: directory.appendingPathComponent("supervision-record.json"), atomically: true, encoding: .utf8)
  }

  private func resolveRunBundle(options: WorkflowRunOptions, resolution: WorkflowResolutionOptions) throws -> ResolvedWorkflowBundle {
    if let temporary = try loadTemporaryWorkflowIfPresent(options.target, workingDirectory: options.workingDirectory) {
      return temporary
    }
    if options.fromRegistry {
      return try resolveRegistryRunBundle(options: options)
    }
    return try resolver.resolve(resolution)
  }

  private func resolveRegistryRunBundle(options: WorkflowRunOptions) throws -> ResolvedWorkflowBundle {
    guard WorkflowPackageManifestValidator.isSafePackageName(options.target) else {
      throw CLIUsageError("invalid package name '\(options.target)'")
    }
    let workingDirectory = URL(fileURLWithPath: options.workingDirectory, isDirectory: true)
    let roots: [(scope: WorkflowScope, root: URL)]
    switch options.resolution?.scope ?? .auto {
    case .project:
      roots = [(.project, workflowRunPackageRoot(scope: .project, workingDirectory: workingDirectory))]
    case .user:
      roots = [(.user, workflowRunPackageRoot(scope: .user, workingDirectory: workingDirectory))]
    case .auto, .direct:
      roots = [
        (.project, workflowRunPackageRoot(scope: .project, workingDirectory: workingDirectory)),
        (.user, workflowRunPackageRoot(scope: .user, workingDirectory: workingDirectory))
      ]
    }
    var errors: [String] = []
    for (scope, root) in roots {
      let packageDirectory = root.appendingPathComponent(options.target, isDirectory: true).standardizedFileURL
      let manifestURL = packageDirectory.appendingPathComponent("riela-package.json")
      guard FileManager.default.fileExists(atPath: manifestURL.path) else {
        errors.append("\(manifestURL.path) not found")
        continue
      }
      let manifest = try JSONDecoder().decode(WorkflowPackageManifest.self, from: Data(contentsOf: manifestURL))
      let issues = WorkflowPackageManifestValidator.validate(manifest)
        + WorkflowPackageManifestValidator.validateWorkflowBundle(manifest, packageRoot: packageDirectory)
      guard issues.isEmpty else {
        throw CLIUsageError("package source validation failed: \(issues.map { "\($0.path): \($0.message)" }.joined(separator: "; "))")
      }
      guard let normalizedWorkflowDirectory = WorkflowPackageManifestValidator.normalizePackageRelativePath(manifest.workflowDirectory ?? ".") else {
        throw CLIUsageError("package workflowDirectory must be package-relative")
      }
      let workflowDirectory = packageDirectory
        .appendingPathComponent(normalizedWorkflowDirectory, isDirectory: true)
        .standardizedFileURL
      guard workflowRunPath(workflowDirectory.resolvingSymlinksInPath(), isContainedIn: packageDirectory.resolvingSymlinksInPath()) else {
        throw CLIUsageError("package workflowDirectory escapes package root: \(manifest.workflowDirectory ?? ".")")
      }
      var bundle = try resolver.resolve(WorkflowResolutionOptions(
        workflowName: workflowDirectory.lastPathComponent,
        scope: .direct,
        workflowDefinitionDir: workflowDirectory.path,
        workingDirectory: options.workingDirectory
      ))
      bundle.sourceScope = scope
      return bundle
    }
    throw WorkflowResolutionError.notFound(options.target, errors)
  }

  private func loadTemporaryWorkflowIfPresent(_ target: String, workingDirectory: String) throws -> ResolvedWorkflowBundle? {
    let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
    let data: Data
    let directory: URL
    if trimmed.hasPrefix("{") {
      guard let inlineData = trimmed.data(using: .utf8) else {
        throw CLIUsageError("temporary workflow JSON target must be UTF-8")
      }
      data = inlineData
      directory = URL(fileURLWithPath: workingDirectory)
    } else {
      let url = absoluteURL(target, relativeTo: URL(fileURLWithPath: workingDirectory))
      guard FileManager.default.fileExists(atPath: url.path), url.pathExtension == "json" else {
        return nil
      }
      data = try Data(contentsOf: url)
      directory = url.deletingLastPathComponent()
    }

    if let payload = try? JSONDecoder().decode(TemporaryWorkflowPayload.self, from: data) {
      let authoredData = try JSONEncoder().encode(payload.workflow)
      let validation = validateAuthoredWorkflowData(authoredData)
      guard let workflow = validation.workflow else {
        throw WorkflowResolutionError.invalidWorkflow(validation.diagnostics)
      }
      return ResolvedWorkflowBundle(
        workflow: workflow,
        nodePayloads: nodePayloads(from: payload, workflow: workflow),
        sourceScope: .direct,
        workflowDirectory: directory.path,
        diagnostics: validation.diagnostics
      )
    }

    let validation = validateAuthoredWorkflowData(data)
    guard let workflow = validation.workflow else {
      throw WorkflowResolutionError.invalidWorkflow(validation.diagnostics)
    }
    return ResolvedWorkflowBundle(
      workflow: workflow,
      nodePayloads: [:],
      sourceScope: .direct,
      workflowDirectory: directory.path,
      diagnostics: validation.diagnostics
    )
  }

  private func nodePayloads(from payload: TemporaryWorkflowPayload, workflow: WorkflowDefinition) -> [String: AgentNodePayload] {
    var byNodeId: [String: AgentNodePayload] = [:]
    for registryNode in workflow.nodeRegistry {
      if let nodeFile = registryNode.nodeFile, let nodePayload = payload.nodePayloads[nodeFile] {
        byNodeId[registryNode.id] = nodePayload
      } else if let nodePayload = payload.nodePayloads[registryNode.id] {
        byNodeId[registryNode.id] = nodePayload
      }
    }
    return byNodeId
  }

  private func renderRunResult(
    _ result: WorkflowRunResult,
    output: WorkflowOutputFormat,
    jsonlRecorder: WorkflowRunJSONLRecorder?
  ) async throws -> String {
    switch output {
    case .json:
      return try jsonString(result)
    case .jsonl:
      let record = try jsonString(WorkflowRunResultRecord(result: result))
      if let jsonlRecorder {
        await jsonlRecorder.append(record)
        return await jsonlRecorder.bufferedOutput()
      }
      return record
    case .text, .table:
      var lines = [
        "status: \(result.session.status.rawValue)",
        "workflowId: \(result.workflowId)",
        "nodeExecutions: \(result.session.executions.count)"
      ]
      if let loopEvidence = result.loopEvidence {
        lines.append(
          "loopEvidence: gates=\(loopEvidence.gateCount) accepted=\(loopEvidence.acceptedGateCount) " +
            "rejected=\(loopEvidence.rejectedGateCount) blockingFindings=\(loopEvidence.blockingFindingCount)"
        )
      }
      return lines.joined(separator: "\n") + "\n"
    }
  }

  private func renderRemoteRunResult(_ result: WorkflowRemoteRunResult, output: WorkflowOutputFormat) throws -> String {
    switch output {
    case .json:
      return try jsonString(result)
    case .jsonl:
      return try jsonString(WorkflowRemoteRunResultRecord(result: result))
    case .text, .table:
      return "run session: \(result.sessionId)\nstatus: \(result.status)\nnodeExecutions: \(result.nodeExecutions)\n"
    }
  }

  private func renderRunFailure(
    options: WorkflowRunOptions,
    exitCode: CLIExitCode,
    error: String,
    state: WorkflowRunLivePersistenceState?
  ) async -> CLICommandResult {
    guard options.output.isStructured else {
      return CLICommandResult(exitCode: exitCode, stderr: error)
    }
    let persistence = await state?.snapshot()
    let termination = workflowRunTerminationDiagnostic(from: error)
    let result = WorkflowRunFailureResult(
      target: options.target,
      exitCode: exitCode.rawValue,
      error: boundedWorkflowRunDiagnostic(error),
      sessionId: persistence?.latestSessionId,
      sessionStore: persistence?.storeRoot,
      persistedSession: persistence?.persistedSession,
      diagnostics: persistence?.diagnostics.isEmpty == false ? persistence?.diagnostics : nil,
      childExitCode: termination.childExitCode,
      terminationSignal: termination.terminationSignal
    )
    let stdout = (try? jsonString(result)) ?? #"{"error":"failed to encode run failure","exitCode":1,"status":"failed","target":"workflow run"}"# + "\n"
    return CLICommandResult(exitCode: exitCode, stdout: stdout)
  }
}

private struct TemporaryWorkflowPayload: Codable {
  var workflow: AuthoredWorkflowJSON
  var nodePayloads: [String: AgentNodePayload]
}

private func isTemporaryWorkflowRunTarget(_ target: String, workingDirectory: String) -> Bool {
  if target.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
    return true
  }
  let url = absoluteURL(target, relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true))
  return FileManager.default.fileExists(atPath: url.path) && url.pathExtension == "json"
}

private func workflowRunPackageRoot(scope: WorkflowScope, workingDirectory: URL) -> URL {
  switch scope {
  case .user:
    return URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory()).appendingPathComponent(".riela/packages", isDirectory: true)
  case .auto, .project, .direct:
    return workingDirectory.appendingPathComponent(".riela/packages", isDirectory: true)
  }
}

private func workflowRunPath(_ child: URL, isContainedIn parent: URL) -> Bool {
  let parentPath = parent.standardizedFileURL.path
  let childPath = child.standardizedFileURL.path
  return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
}
