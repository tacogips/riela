import Foundation
import RielaCore
import RielaGraphQL
import RielaNote
import RielaObservability

public protocol WorkflowServeResolving: Sendable {
  func resolve(_ request: WorkflowServeStartRequest) async throws -> WorkflowServeResolvedWorkflow
}

public protocol WorkflowServeListenerHandle: Sendable {
  var endpoint: String { get }
  func shutdown() async throws
}

public protocol WorkflowServeListenerFactory: Sendable {
  func startListener(
    for resolvedWorkflow: WorkflowServeResolvedWorkflow,
    request: WorkflowServeStartRequest,
    generationId: String
  ) async throws -> any WorkflowServeListenerHandle
}

public protocol WorkflowServeEventSourceHandle: Sendable {
  var status: WorkflowServeEventSourceStatus { get }
  func shutdown() async throws
}

public protocol WorkflowServeEventSourceFactory: Sendable {
  func startEventSources(
    for resolvedWorkflow: WorkflowServeResolvedWorkflow,
    request: WorkflowServeStartRequest,
    generationId: String
  ) async throws -> [any WorkflowServeEventSourceHandle]
}

public protocol WorkflowServeGenerationIDGenerating: Sendable {
  func nextGenerationID() async -> String
}

public struct WorkflowServingDependencies: Sendable {
  public var resolver: any WorkflowServeResolving
  public var listenerFactory: any WorkflowServeListenerFactory
  public var eventSourceFactory: any WorkflowServeEventSourceFactory
  public var generationIDGenerator: any WorkflowServeGenerationIDGenerating
  public var telemetry: any RielaTelemetry

  public init(
    resolver: any WorkflowServeResolving = DefaultWorkflowServeResolver(),
    listenerFactory: any WorkflowServeListenerFactory = InProcessWorkflowServeListenerFactory(),
    eventSourceFactory: any WorkflowServeEventSourceFactory = InProcessWorkflowServeEventSourceFactory(),
    generationIDGenerator: any WorkflowServeGenerationIDGenerating = ServeGenerationIDGenerator(),
    telemetry: any RielaTelemetry = NoOpRielaTelemetry()
  ) {
    self.resolver = resolver
    self.listenerFactory = listenerFactory
    self.eventSourceFactory = eventSourceFactory
    self.generationIDGenerator = generationIDGenerator
    self.telemetry = telemetry
  }
}

public actor WorkflowServingController {
  private struct ActiveGeneration: Sendable {
    var request: WorkflowServeStartRequest
    var stateGeneration: WorkflowServeGeneration
    var listener: any WorkflowServeListenerHandle
    var eventSources: [any WorkflowServeEventSourceHandle]
  }

  private let dependencies: WorkflowServingDependencies
  private var state = WorkflowServeState()
  private var activeGeneration: ActiveGeneration?
  private var lastAcceptedStartRequest: WorkflowServeStartRequest?

  public init(dependencies: WorkflowServingDependencies = WorkflowServingDependencies()) {
    self.dependencies = dependencies
  }

  public func currentState() -> WorkflowServeState {
    guard let activeGeneration else {
      return state
    }
    return WorkflowServeState(
      status: state.status,
      generation: generationSnapshot(from: activeGeneration),
      diagnostics: state.diagnostics
    )
  }

  public func start(_ request: WorkflowServeStartRequest) async throws -> WorkflowServeState {
    guard activeGeneration == nil else {
      throw WorkflowServeError.alreadyRunning
    }
    let startedAt = Date()
    await dependencies.telemetry.recordLog(RielaTelemetryLog(
      name: "riela.serve.start",
      attributes: serveAttributes(selection: request.selection)
    ))
    state = WorkflowServeState(status: .starting)
    do {
      let generation = try await startGeneration(request)
      activeGeneration = generation
      lastAcceptedStartRequest = request
      state = WorkflowServeState(status: .running, generation: generation.stateGeneration)
      await recordServeSpan(name: "riela.serve.generation", status: .ok, startedAt: startedAt, generation: generation)
      return state
    } catch {
      state = WorkflowServeState(status: .failed, diagnostics: [diagnostic(from: error, selection: request.selection)])
      await dependencies.telemetry.recordSpan(RielaTelemetrySpan(
        name: "riela.serve.generation",
        status: .error,
        startedAt: startedAt,
        attributes: serveAttributes(selection: request.selection)
      ))
      throw error
    }
  }

  public func stop() async throws -> WorkflowServeState {
    guard let generation = activeGeneration else {
      state = WorkflowServeState(status: .stopped)
      return state
    }
    state = WorkflowServeState(status: .stopping, generation: generation.stateGeneration)
    try await shutdown(generation)
    activeGeneration = nil
    state = WorkflowServeState(status: .stopped)
    await dependencies.telemetry.recordLog(RielaTelemetryLog(
      name: "riela.serve.stop",
      attributes: serveAttributes(generation: generation)
    ))
    return state
  }

  public func restart() async throws -> WorkflowServeState {
    guard let request = lastAcceptedStartRequest else {
      throw WorkflowServeError.noAcceptedStartRequest
    }
    _ = try await stop()
    return try await start(request)
  }

  public func reload(_ request: WorkflowServeReloadRequest = WorkflowServeReloadRequest()) async throws -> WorkflowServeState {
    guard let current = activeGeneration else {
      throw WorkflowServeError.notRunning
    }
    var replacementRequest = current.request
    if let replacementSelection = request.replacementSelection {
      replacementRequest.selection = replacementSelection
    }
    state = WorkflowServeState(status: .reloading, generation: current.stateGeneration)
    do {
      let replacement = try await startGeneration(replacementRequest)
      activeGeneration = replacement
      lastAcceptedStartRequest = replacementRequest
      state = WorkflowServeState(status: .running, generation: replacement.stateGeneration)
      try await shutdown(current)
      await dependencies.telemetry.recordLog(RielaTelemetryLog(
        name: "riela.serve.reload",
        attributes: serveAttributes(generation: replacement)
      ))
      return state
    } catch {
      let diagnostics = [diagnostic(from: error, selection: replacementRequest.selection)]
      if request.restartPolicy == .failIfReplacementFails {
        try? await shutdown(current)
        activeGeneration = nil
        state = WorkflowServeState(status: .failed, diagnostics: diagnostics)
      } else {
        state = WorkflowServeState(status: .running, generation: current.stateGeneration, diagnostics: diagnostics)
      }
      throw error
    }
  }

  private func startGeneration(_ request: WorkflowServeStartRequest) async throws -> ActiveGeneration {
    let resolved = try await dependencies.resolver.resolve(request)
    let generationId = await dependencies.generationIDGenerator.nextGenerationID()
    let listener = try await dependencies.listenerFactory.startListener(
      for: resolved,
      request: request,
      generationId: generationId
    )
    do {
      let eventSources = request.startsEventSources
        ? try await dependencies.eventSourceFactory.startEventSources(
          for: resolved,
          request: request,
          generationId: generationId
        )
        : []
      let stateGeneration = WorkflowServeGeneration(
        generationId: generationId,
        workflowId: resolved.workflowId,
        selectedIdentity: resolved.selectedIdentity,
        endpoint: listener.endpoint,
        eventSources: eventSources.map(\.status),
        sessionStoreRoot: request.sessionStoreRoot,
        eventRoot: request.eventRoot,
        validationDiagnostics: resolved.diagnostics
      )
      return ActiveGeneration(
        request: request,
        stateGeneration: stateGeneration,
        listener: listener,
        eventSources: eventSources
      )
    } catch {
      try? await listener.shutdown()
      throw error
    }
  }

  private func recordServeSpan(
    name: String,
    status: RielaTelemetryStatus,
    startedAt: Date,
    generation: ActiveGeneration
  ) async {
    await dependencies.telemetry.recordSpan(RielaTelemetrySpan(
      name: name,
      status: status,
      startedAt: startedAt,
      attributes: serveAttributes(generation: generation)
    ))
    await dependencies.telemetry.recordMetric(RielaTelemetryMetric(
      name: "riela.serve.generation.count",
      value: 1,
      attributes: serveAttributes(generation: generation)
    ))
  }

  private func serveAttributes(selection: WorkflowServeSelection) -> [String: String] {
    [
      "runtime.surface": "serve",
      "workflow.id": selection.identifier
    ]
  }

  private func serveAttributes(generation: ActiveGeneration) -> [String: String] {
    [
      "runtime.surface": "serve",
      "serve.generation.id": generation.stateGeneration.generationId,
      "workflow.id": generation.stateGeneration.workflowId,
      "event.source.count": String(generation.eventSources.count),
      "status": state.status.rawValue
    ]
  }

  private func generationSnapshot(from generation: ActiveGeneration) -> WorkflowServeGeneration {
    WorkflowServeGeneration(
      generationId: generation.stateGeneration.generationId,
      workflowId: generation.stateGeneration.workflowId,
      selectedIdentity: generation.stateGeneration.selectedIdentity,
      endpoint: generation.stateGeneration.endpoint,
      eventSources: generation.eventSources.map(\.status),
      sessionStoreRoot: generation.stateGeneration.sessionStoreRoot,
      eventRoot: generation.stateGeneration.eventRoot,
      validationDiagnostics: generation.stateGeneration.validationDiagnostics
    )
  }

  private func shutdown(_ generation: ActiveGeneration) async throws {
    var diagnostics: [WorkflowServeDiagnostics] = []
    for handle in generation.eventSources.reversed() {
      do {
        try await handle.shutdown()
      } catch {
        diagnostics.append(diagnostic(from: error, selection: generation.request.selection))
      }
    }
    do {
      try await generation.listener.shutdown()
    } catch {
      diagnostics.append(diagnostic(from: error, selection: generation.request.selection))
    }
    if let first = diagnostics.first {
      throw WorkflowServeError.shutdownFailed(first)
    }
  }

  private func diagnostic(from error: Error, selection: WorkflowServeSelection?) -> WorkflowServeDiagnostics {
    if case let WorkflowServeError.validationFailed(diagnostic) = error {
      return diagnostic
    }
    if case let WorkflowServeError.startupFailed(diagnostic) = error {
      return diagnostic
    }
    if case let WorkflowServeError.shutdownFailed(diagnostic) = error {
      return diagnostic
    }
    return WorkflowServeDiagnostics(code: "workflow_serve_error", message: "\(error)", selection: selection)
  }
}

public struct DefaultWorkflowServeResolver: WorkflowServeResolving {
  public init() {}

  public func resolve(_ request: WorkflowServeStartRequest) async throws -> WorkflowServeResolvedWorkflow {
    switch request.selection.kind {
    case .directDirectory:
      let directory = absolutePath(request.selection.path ?? request.selection.identifier, workingDirectory: request.workingDirectory)
      let workflowURL = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("workflow.json")
      guard FileManager.default.fileExists(atPath: workflowURL.path) else {
        throw WorkflowServeError.validationFailed(WorkflowServeDiagnostics(
          code: "workflow_not_found",
          message: "workflow.json was not found for selected workflow",
          selection: request.selection
        ))
      }
      let validation = validateAuthoredWorkflowData(try Data(contentsOf: workflowURL))
      guard let workflow = validation.workflow else {
        throw WorkflowServeError.validationFailed(WorkflowServeDiagnostics(
          code: "workflow_invalid",
          message: validation.diagnostics.map { "\($0.path): \($0.message)" }.joined(separator: "; "),
          selection: request.selection
        ))
      }
      let nodePayloads = try resolvedNodePayloads(
        request.nodePatch,
        workflow: workflow,
        workflowDirectory: URL(fileURLWithPath: directory, isDirectory: true),
        selection: request.selection
      )
      let diagnostics = DefaultWorkflowValidator().validate(workflow, nodePayloads: nodePayloads)
      if diagnostics.contains(where: { $0.severity == .error }) {
        throw WorkflowServeError.validationFailed(WorkflowServeDiagnostics(
          code: "workflow_invalid",
          message: diagnostics.map { "\($0.path): \($0.message)" }.joined(separator: "; "),
          selection: request.selection
        ))
      }
      return WorkflowServeResolvedWorkflow(
        workflowId: workflow.workflowId,
        selectedIdentity: workflow.workflowId,
        workflowDirectory: directory
      )
    case .scopedName, .package:
      guard isSafeIdentifier(request.selection.identifier) else {
        throw WorkflowServeError.validationFailed(WorkflowServeDiagnostics(
          code: "workflow_selection_unsafe",
          message: "workflow selection contains unsupported path characters",
          selection: request.selection
        ))
      }
      return WorkflowServeResolvedWorkflow(
        workflowId: request.selection.identifier,
        selectedIdentity: request.selection.identifier,
        workflowDirectory: nil,
        diagnostics: [WorkflowServeDiagnostics(
          code: "workflow_resolution_deferred",
          message: "selection is accepted for a client-provided runtime resolver",
          selection: request.selection
        )]
      )
    case .manifestEntry:
      guard let entryId = request.selection.manifestEntryId, isSafeIdentifier(entryId) else {
        throw WorkflowServeError.validationFailed(WorkflowServeDiagnostics(
          code: "manifest_entry_invalid",
          message: "manifest entry id is required and must be safe",
          selection: request.selection
        ))
      }
      return WorkflowServeResolvedWorkflow(
        workflowId: entryId,
        selectedIdentity: entryId,
        workflowDirectory: request.selection.path
      )
    }
  }

  private func absolutePath(_ path: String, workingDirectory: String) -> String {
    let url = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true))
    return url.standardizedFileURL.path
  }

  private func isSafeIdentifier(_ value: String) -> Bool {
    !value.isEmpty && !value.contains("..") && !value.contains("/") && !value.contains("\\")
  }

  private func resolvedNodePayloads(
    _ nodePatch: JSONObject?,
    workflow: WorkflowDefinition,
    workflowDirectory: URL,
    selection: WorkflowServeSelection
  ) throws -> [String: AgentNodePayload] {
    let nodePayloads = try loadNodePayloads(workflow: workflow, workflowDirectory: workflowDirectory, selection: selection)
    guard let nodePatch, !nodePatch.isEmpty else {
      return nodePayloads
    }
    do {
      let patches = try WorkflowInstanceResolver.nodePatches(from: nodePatch)
      return try WorkflowInstanceResolver.resolve(
        workflowId: workflow.workflowId,
        base: nil,
        runNodePatch: patches,
        nodePayloads: nodePayloads
      ).nodePayloads
    } catch {
      throw WorkflowServeError.validationFailed(WorkflowServeDiagnostics(
        code: "workflow_instance_patch_invalid",
        message: "\(error)",
        selection: selection
      ))
    }
  }

  private func loadNodePayloads(
    workflow: WorkflowDefinition,
    workflowDirectory: URL,
    selection: WorkflowServeSelection
  ) throws -> [String: AgentNodePayload] {
    var payloads: [String: AgentNodePayload] = [:]
    for node in workflow.nodeRegistry {
      guard let nodeFile = node.nodeFile else {
        continue
      }
      let payloadURL = workflowDirectory.appendingPathComponent(nodeFile)
      guard FileManager.default.fileExists(atPath: payloadURL.path) else {
        continue
      }
      do {
        payloads[node.id] = try JSONDecoder().decode(AgentNodePayload.self, from: Data(contentsOf: payloadURL))
      } catch {
        throw WorkflowServeError.validationFailed(WorkflowServeDiagnostics(
          code: "workflow_node_payload_invalid",
          message: "failed to decode node payload '\(nodeFile)': \(error)",
          selection: selection
        ))
      }
    }
    return payloads
  }
}

public struct InProcessWorkflowServeListenerFactory: WorkflowServeListenerFactory {
  public var s3HTTPClient: any S3HTTPClient

  public init(s3HTTPClient: any S3HTTPClient = URLSessionS3HTTPClient()) {
    self.s3HTTPClient = s3HTTPClient
  }

  public func startListener(
    for resolvedWorkflow: WorkflowServeResolvedWorkflow,
    request: WorkflowServeStartRequest,
    generationId: String
  ) async throws -> any WorkflowServeListenerHandle {
    let endpoint = "http://\(request.server.host):\(request.server.port)"
    let routeConfiguration = try await routeConfiguration(for: request, endpoint: endpoint)
    return InProcessWorkflowServeListenerHandle(
      endpoint: endpoint,
      routeHandler: routeConfiguration.routeHandler,
      registrationChallenge: routeConfiguration.registrationChallenge
    )
  }

  private func routeConfiguration(
    for request: WorkflowServeStartRequest,
    endpoint: String
  ) async throws -> InProcessWorkflowServeRouteConfiguration {
    guard request.server.noteAPIEnabled else {
      return InProcessWorkflowServeRouteConfiguration(routeHandler: DeterministicServerRouteHandler())
    }
    guard let noteRoot = request.server.noteRoot?.trimmingCharacters(in: .whitespacesAndNewlines),
          !noteRoot.isEmpty else {
      throw WorkflowServeError.startupFailed(WorkflowServeDiagnostics(
        code: "note_api_root_missing",
        message: "note API serving requires server.noteRoot"
      ))
    }
    let service = try NoteService(
      driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot),
      autoActionDispatcher: ServedNoteAPIAutoActionDispatcher()
    )
    let authenticator = QRClientRegistrationAuthenticator(
      service: service,
      registrationScope: URL(fileURLWithPath: noteRoot, isDirectory: true).standardizedFileURL.path
    )
    let routeHandler = DeterministicServerRouteHandler(
      graphQLExecutor: NoteGraphQLDocumentExecutor(
        service: GraphQLNoteGraphQLService(service: service),
        s3HTTPClient: s3HTTPClient,
        s3Profiles: try noteS3Profiles(for: request)
      ),
      noteAPIAuthenticator: authenticator
    )
    let challenge = try await authenticator.createRegistrationChallenge(publicBaseURL: endpoint)
    return InProcessWorkflowServeRouteConfiguration(
      routeHandler: routeHandler,
      registrationChallenge: challenge
    )
  }

  private func noteS3Profiles(for request: WorkflowServeStartRequest) throws -> [S3StorageProfile] {
    var environment = ProcessInfo.processInfo.environment
    for (name, value) in request.configuration.inheritedEnvironment {
      environment[name] = value
    }
    return try request.server.noteS3Profiles.map { profile in
      let endpointRaw = profile.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
      let region = profile.region.trimmingCharacters(in: .whitespacesAndNewlines)
      let bucket = profile.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let endpoint = URL(string: endpointRaw), !region.isEmpty, !bucket.isEmpty else {
        throw WorkflowServeError.startupFailed(WorkflowServeDiagnostics(
          code: "note_api_s3_profile_invalid",
          message: "note API S3 profile \(profile.name) requires endpoint, region, and bucket"
        ))
      }
      return try S3StorageProfile.environmentBacked(
        name: profile.name.isEmpty ? "default-s3" : profile.name,
        endpoint: endpoint,
        region: region,
        bucket: bucket,
        accessKeyIdEnv: profile.accessKeyIdEnv,
        secretAccessKeyEnv: profile.secretAccessKeyEnv,
        sessionTokenEnv: profile.sessionTokenEnv,
        keyPrefix: profile.keyPrefix,
        environment: environment
      )
    }
  }
}

private struct ServedNoteAPIAutoActionDispatcher: AutoActionDispatching {
  func dispatch(_ record: AutoActionDispatchRecord) async throws -> AutoActionDispatchOutcome {
    .failed("served note API does not launch auto-action workflows; retry with a workflow dispatcher")
  }
}

public final class InProcessWorkflowServeListenerHandle: WorkflowServeListenerHandle, @unchecked Sendable {
  public let endpoint: String
  public let routeHandler: any ServerRouteHandling
  public let registrationChallenge: NoteAPIRegistrationChallenge?
  private let lock = NSLock()
  private var stopped = false

  public init(
    endpoint: String,
    routeHandler: any ServerRouteHandling = DeterministicServerRouteHandler(),
    registrationChallenge: NoteAPIRegistrationChallenge? = nil
  ) {
    self.endpoint = endpoint
    self.routeHandler = routeHandler
    self.registrationChallenge = registrationChallenge
  }

  public func shutdown() async throws {
    lock.withLock {
      stopped = true
    }
  }
}

private struct InProcessWorkflowServeRouteConfiguration {
  var routeHandler: any ServerRouteHandling
  var registrationChallenge: NoteAPIRegistrationChallenge?
}

public struct InProcessWorkflowServeEventSourceFactory: WorkflowServeEventSourceFactory {
  public init() {}

  public func startEventSources(
    for resolvedWorkflow: WorkflowServeResolvedWorkflow,
    request: WorkflowServeStartRequest,
    generationId: String
  ) async throws -> [any WorkflowServeEventSourceHandle] {
    guard request.startsEventSources else {
      return []
    }
    return [
      InProcessWorkflowServeEventSourceHandle(status: WorkflowServeEventSourceStatus(
        sourceId: "configured-event-sources",
        status: "running",
        generationId: generationId
      ))
    ]
  }
}

public final class InProcessWorkflowServeEventSourceHandle: WorkflowServeEventSourceHandle, @unchecked Sendable {
  public let status: WorkflowServeEventSourceStatus
  private let lock = NSLock()
  private var stopped = false

  public init(status: WorkflowServeEventSourceStatus) {
    self.status = status
  }

  public func shutdown() async throws {
    lock.withLock {
      stopped = true
    }
  }
}

public actor ServeGenerationIDGenerator: WorkflowServeGenerationIDGenerating {
  private var counter = 0

  public init() {}

  public func nextGenerationID() -> String {
    counter += 1
    return "serve-generation-\(counter)"
  }
}
