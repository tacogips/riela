import Foundation
import RielaCore

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

  public init(
    resolver: any WorkflowServeResolving = DefaultWorkflowServeResolver(),
    listenerFactory: any WorkflowServeListenerFactory = InProcessWorkflowServeListenerFactory(),
    eventSourceFactory: any WorkflowServeEventSourceFactory = InProcessWorkflowServeEventSourceFactory(),
    generationIDGenerator: any WorkflowServeGenerationIDGenerating = ServeGenerationIDGenerator()
  ) {
    self.resolver = resolver
    self.listenerFactory = listenerFactory
    self.eventSourceFactory = eventSourceFactory
    self.generationIDGenerator = generationIDGenerator
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
    state = WorkflowServeState(status: .starting)
    do {
      let generation = try await startGeneration(request)
      activeGeneration = generation
      lastAcceptedStartRequest = request
      state = WorkflowServeState(status: .running, generation: generation.stateGeneration)
      return state
    } catch {
      state = WorkflowServeState(status: .failed, diagnostics: [diagnostic(from: error, selection: request.selection)])
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
}

public struct InProcessWorkflowServeListenerFactory: WorkflowServeListenerFactory {
  public init() {}

  public func startListener(
    for resolvedWorkflow: WorkflowServeResolvedWorkflow,
    request: WorkflowServeStartRequest,
    generationId: String
  ) async throws -> any WorkflowServeListenerHandle {
    InProcessWorkflowServeListenerHandle(endpoint: "http://\(request.server.host):\(request.server.port)")
  }
}

public final class InProcessWorkflowServeListenerHandle: WorkflowServeListenerHandle, @unchecked Sendable {
  public let endpoint: String
  private let lock = NSLock()
  private var stopped = false

  public init(endpoint: String) {
    self.endpoint = endpoint
  }

  public func shutdown() async throws {
    lock.withLock {
      stopped = true
    }
  }
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
