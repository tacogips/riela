import Foundation
import RielaCore

public enum WorkflowViewerNodeRuntimeState: String, Codable, Equatable, Hashable, Sendable {
  case idle
  case active
  case completed
  case failed
}

public enum WorkflowViewerMessageDirection: String, Codable, Equatable, Sendable {
  case inbox
  case outbox
}

public struct WorkflowViewerSessionSummary: Codable, Equatable, Sendable {
  public var sessionId: String
  public var workflowId: String
  public var status: WorkflowSessionStatus
  public var currentStepId: String?
  public var activeStepIds: [String]
  public var updatedAt: Date

  public init(
    sessionId: String,
    workflowId: String,
    status: WorkflowSessionStatus,
    currentStepId: String?,
    activeStepIds: [String],
    updatedAt: Date
  ) {
    self.sessionId = sessionId
    self.workflowId = workflowId
    self.status = status
    self.currentStepId = currentStepId
    self.activeStepIds = activeStepIds
    self.updatedAt = updatedAt
  }
}

public struct WorkflowViewerNode: Codable, Equatable, Hashable, Identifiable, Sendable {
  public var id: String
  public var nodeId: String
  public var title: String
  public var detail: String?
  public var configuration: WorkflowViewerNodeConfiguration?
  public var templateFiles: [WorkflowViewerTemplateFile]
  public var state: WorkflowViewerNodeRuntimeState
  public var depth: Int
  public var children: [WorkflowViewerNode]

  public init(
    id: String,
    nodeId: String,
    title: String,
    detail: String? = nil,
    configuration: WorkflowViewerNodeConfiguration? = nil,
    templateFiles: [WorkflowViewerTemplateFile] = [],
    state: WorkflowViewerNodeRuntimeState,
    depth: Int = 0,
    children: [WorkflowViewerNode] = []
  ) {
    self.id = id
    self.nodeId = nodeId
    self.title = title
    self.detail = detail
    self.configuration = configuration
    self.templateFiles = templateFiles
    self.state = state
    self.depth = depth
    self.children = children
  }

  enum CodingKeys: String, CodingKey {
    case id
    case nodeId
    case title
    case detail
    case configuration
    case templateFiles
    case state
    case depth
    case children
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    nodeId = try container.decode(String.self, forKey: .nodeId)
    title = try container.decode(String.self, forKey: .title)
    detail = try container.decodeIfPresent(String.self, forKey: .detail)
    configuration = try container.decodeIfPresent(WorkflowViewerNodeConfiguration.self, forKey: .configuration)
    templateFiles = try container.decodeIfPresent([WorkflowViewerTemplateFile].self, forKey: .templateFiles) ?? []
    state = try container.decode(WorkflowViewerNodeRuntimeState.self, forKey: .state)
    depth = try container.decode(Int.self, forKey: .depth)
    children = try container.decode([WorkflowViewerNode].self, forKey: .children)
  }
}

public struct WorkflowViewerNodeConfiguration: Codable, Equatable, Hashable, Sendable {
  public var nodeFile: String
  public var executionBackend: NodeExecutionBackend?
  public var model: String
  public var modelFreeze: Bool
  public var effort: NodeReasoningEffort?

  public init(
    nodeFile: String,
    executionBackend: NodeExecutionBackend? = nil,
    model: String,
    modelFreeze: Bool = false,
    effort: NodeReasoningEffort? = nil
  ) {
    self.nodeFile = nodeFile
    self.executionBackend = executionBackend
    self.model = model
    self.modelFreeze = modelFreeze
    self.effort = effort
  }
}

public enum WorkflowViewerTemplateRole: String, Codable, Equatable, Hashable, Sendable {
  case systemPrompt
  case prompt
  case sessionStart

  public var label: String {
    switch self {
    case .systemPrompt:
      "System prompt"
    case .prompt:
      "Prompt"
    case .sessionStart:
      "Session start"
    }
  }
}

public struct WorkflowViewerTemplateFile: Codable, Equatable, Hashable, Identifiable, Sendable {
  public var id: String
  public var stepId: String
  public var nodeId: String
  public var nodeFile: String
  public var fieldPath: String
  public var role: WorkflowViewerTemplateRole
  public var variantName: String?
  public var relativePath: String
  public var resolvedPath: String
  public var isActiveForStep: Bool

  public init(
    id: String,
    stepId: String,
    nodeId: String,
    nodeFile: String,
    fieldPath: String,
    role: WorkflowViewerTemplateRole,
    variantName: String? = nil,
    relativePath: String,
    resolvedPath: String,
    isActiveForStep: Bool
  ) {
    self.id = id
    self.stepId = stepId
    self.nodeId = nodeId
    self.nodeFile = nodeFile
    self.fieldPath = fieldPath
    self.role = role
    self.variantName = variantName
    self.relativePath = relativePath
    self.resolvedPath = resolvedPath
    self.isActiveForStep = isActiveForStep
  }

  public var displayName: String {
    let variant = variantName.map { " / variant \($0)" } ?? ""
    let active = isActiveForStep ? " / active" : ""
    return "\(role.label)\(variant)\(active): \(relativePath)"
  }
}

public struct WorkflowViewerMessage: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var direction: WorkflowViewerMessageDirection
  public var fromStepId: String?
  public var toStepId: String?
  public var status: WorkflowMessageLifecycleStatus
  public var payloadPreview: String
  public var artifactRefs: [String]

  public init(
    id: String,
    direction: WorkflowViewerMessageDirection,
    fromStepId: String?,
    toStepId: String?,
    status: WorkflowMessageLifecycleStatus,
    payloadPreview: String,
    artifactRefs: [String] = []
  ) {
    self.id = id
    self.direction = direction
    self.fromStepId = fromStepId
    self.toStepId = toStepId
    self.status = status
    self.payloadPreview = payloadPreview
    self.artifactRefs = artifactRefs
  }
}

public struct WorkflowViewerNodeMessages: Codable, Equatable, Sendable {
  public var stepId: String
  public var inbox: [WorkflowViewerMessage]
  public var outbox: [WorkflowViewerMessage]

  public init(stepId: String, inbox: [WorkflowViewerMessage] = [], outbox: [WorkflowViewerMessage] = []) {
    self.stepId = stepId
    self.inbox = inbox
    self.outbox = outbox
  }
}

public struct WorkflowViewerTimelineEntry: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var stepId: String
  public var nodeId: String
  public var attempt: Int
  public var status: WorkflowStepExecutionStatus
  public var backend: NodeExecutionBackend?
  public var startedAt: Date
  public var endedAt: Date?
  public var lastBackendEventAt: Date?
  public var lastBackendEventType: String?
  public var failureReason: String?

  public init(
    id: String,
    stepId: String,
    nodeId: String,
    attempt: Int,
    status: WorkflowStepExecutionStatus,
    backend: NodeExecutionBackend? = nil,
    startedAt: Date,
    endedAt: Date? = nil,
    lastBackendEventAt: Date? = nil,
    lastBackendEventType: String? = nil,
    failureReason: String? = nil
  ) {
    self.id = id
    self.stepId = stepId
    self.nodeId = nodeId
    self.attempt = attempt
    self.status = status
    self.backend = backend
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.lastBackendEventAt = lastBackendEventAt
    self.lastBackendEventType = lastBackendEventType
    self.failureReason = failureReason
  }

  public var duration: TimeInterval? {
    endedAt.map { $0.timeIntervalSince(startedAt) }
  }
}

public struct WorkflowViewerState: Codable, Equatable, Sendable {
  public var workflow: WorkflowDefinition
  public var workflowDirectory: String
  public var sessionStoreRoot: String
  public var sessionStoreCandidates: [String]
  public var selectedSessionId: String?
  public var sessions: [WorkflowViewerSessionSummary]
  public var nodes: [WorkflowViewerNode]
  public var timeline: [WorkflowViewerTimelineEntry]
  public var diagnostics: [String]

  public init(
    workflow: WorkflowDefinition,
    workflowDirectory: String,
    sessionStoreRoot: String,
    sessionStoreCandidates: [String] = [],
    selectedSessionId: String?,
    sessions: [WorkflowViewerSessionSummary],
    nodes: [WorkflowViewerNode],
    timeline: [WorkflowViewerTimelineEntry] = [],
    diagnostics: [String] = []
  ) {
    self.workflow = workflow
    self.workflowDirectory = workflowDirectory
    self.sessionStoreRoot = sessionStoreRoot
    self.sessionStoreCandidates = sessionStoreCandidates
    self.selectedSessionId = selectedSessionId
    self.sessions = sessions
    self.nodes = nodes
    self.timeline = timeline
    self.diagnostics = diagnostics
  }

  enum CodingKeys: String, CodingKey {
    case workflow
    case workflowDirectory
    case sessionStoreRoot
    case sessionStoreCandidates
    case selectedSessionId
    case sessions
    case nodes
    case timeline
    case diagnostics
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    workflow = try container.decode(WorkflowDefinition.self, forKey: .workflow)
    workflowDirectory = try container.decode(String.self, forKey: .workflowDirectory)
    sessionStoreRoot = try container.decode(String.self, forKey: .sessionStoreRoot)
    sessionStoreCandidates = try container.decodeIfPresent([String].self, forKey: .sessionStoreCandidates) ?? []
    selectedSessionId = try container.decodeIfPresent(String.self, forKey: .selectedSessionId)
    sessions = try container.decode([WorkflowViewerSessionSummary].self, forKey: .sessions)
    nodes = try container.decode([WorkflowViewerNode].self, forKey: .nodes)
    timeline = try container.decode([WorkflowViewerTimelineEntry].self, forKey: .timeline)
    diagnostics = try container.decodeIfPresent([String].self, forKey: .diagnostics) ?? []
  }
}

public struct WorkflowViewerLoadRequest: Equatable, Sendable {
  public var workflowDirectory: String
  public var sessionStoreRoot: String?
  public var selectedSessionId: String?

  public init(workflowDirectory: String, sessionStoreRoot: String? = nil, selectedSessionId: String? = nil) {
    self.workflowDirectory = workflowDirectory
    self.sessionStoreRoot = sessionStoreRoot
    self.selectedSessionId = selectedSessionId
  }
}

public enum WorkflowViewerLoadError: Error, Equatable, Sendable, CustomStringConvertible {
  case workflowNotFound(String)
  case invalidWorkflow([String])
  case unsafeSessionId(String)
  case templateFileNotFound(String)

  public var description: String {
    switch self {
    case let .workflowNotFound(path):
      "workflow.json was not found at \(path)"
    case let .invalidWorkflow(diagnostics):
      "workflow is invalid: \(diagnostics.joined(separator: "; "))"
    case let .unsafeSessionId(sessionId):
      "unsafe session id: \(sessionId)"
    case let .templateFileNotFound(path):
      "template file was not found at \(path)"
    }
  }
}

public struct WorkflowViewerLoader: Sendable {
  public init() {}

  public func load(_ request: WorkflowViewerLoadRequest) throws -> WorkflowViewerState {
    let workflowDirectory = URL(fileURLWithPath: request.workflowDirectory, isDirectory: true).standardizedFileURL.path
    let workflowURL = URL(fileURLWithPath: workflowDirectory, isDirectory: true).appendingPathComponent("workflow.json")
    guard FileManager.default.fileExists(atPath: workflowURL.path) else {
      throw WorkflowViewerLoadError.workflowNotFound(workflowURL.path)
    }
    let authoredData = try Data(contentsOf: workflowURL)
    let validation = validateAuthoredWorkflowData(authoredData)
    guard let workflow = validation.workflow else {
      throw WorkflowViewerLoadError.invalidWorkflow(validation.diagnostics.map { "\($0.path): \($0.message)" })
    }
    let sessionStoreResolution = try resolveSessionStore(
      explicitRoot: request.sessionStoreRoot,
      workflowDirectory: workflowDirectory,
      workflowId: workflow.workflowId
    )
    let sessionStoreRoot = sessionStoreResolution.root
    let snapshots = sessionStoreResolution.snapshots
      .filter { $0.session.workflowId == workflow.workflowId }
      .sorted { $0.session.updatedAt > $1.session.updatedAt }
    let selectedSnapshot = request.selectedSessionId.flatMap { selectedSessionId in
      snapshots.first { $0.session.sessionId == selectedSessionId }
    } ?? snapshots.first
    let summaries = snapshots.map(summary)
    let diagnostics = sessionStoreResolution.diagnostics + (selectedSnapshot?.diagnostics ?? [])
    return WorkflowViewerState(
      workflow: workflow,
      workflowDirectory: workflowDirectory,
      sessionStoreRoot: sessionStoreRoot,
      sessionStoreCandidates: sessionStoreResolution.candidates,
      selectedSessionId: selectedSnapshot?.session.sessionId,
      sessions: summaries,
      nodes: buildTree(workflow: workflow, workflowDirectory: workflowDirectory, selectedSession: selectedSnapshot?.session),
      timeline: selectedSnapshot.map { timelineEntries(from: $0.session) } ?? [],
      diagnostics: diagnostics
    )
  }

  public func templateFileContent(_ templateFile: WorkflowViewerTemplateFile, workflowDirectory: String) throws -> String {
    let resolved = try resolveTemplateFile(templateFile, workflowDirectory: workflowDirectory)
    guard FileManager.default.fileExists(atPath: resolved.path) else {
      throw WorkflowViewerLoadError.templateFileNotFound(resolved.path)
    }
    return try String(contentsOf: resolved, encoding: .utf8)
  }

  public func saveTemplateFile(
    _ content: String,
    templateFile: WorkflowViewerTemplateFile,
    workflowDirectory: String
  ) throws {
    let resolved = try resolveTemplateFile(templateFile, workflowDirectory: workflowDirectory)
    guard FileManager.default.fileExists(atPath: resolved.path) else {
      throw WorkflowViewerLoadError.templateFileNotFound(resolved.path)
    }
    try content.write(to: resolved, atomically: true, encoding: .utf8)
  }

  public func nodeMessages(
    stepId: String,
    sessionId: String,
    sessionStoreRoot: String
  ) throws -> WorkflowViewerNodeMessages {
    let snapshot = try loadSnapshot(sessionId: sessionId, sessionStoreRoot: sessionStoreRoot)
    let messages = snapshot.workflowMessages.sorted { $0.createdOrder < $1.createdOrder }
    let inbox = messages
      .filter { $0.toStepId == stepId }
      .map { viewerMessage($0, direction: .inbox) }
    let outbox = messages
      .filter { $0.fromStepId == stepId }
      .map { viewerMessage($0, direction: .outbox) }
    return WorkflowViewerNodeMessages(stepId: stepId, inbox: inbox, outbox: outbox)
  }

  private func summary(_ snapshot: WorkflowRuntimePersistenceSnapshot) -> WorkflowViewerSessionSummary {
    var active = Set(snapshot.session.executions.filter { $0.status == .running }.map(\.stepId))
    if snapshot.session.status == .running, let currentStepId = snapshot.session.currentStepId {
      active.insert(currentStepId)
    }
    return WorkflowViewerSessionSummary(
      sessionId: snapshot.session.sessionId,
      workflowId: snapshot.session.workflowId,
      status: snapshot.session.status,
      currentStepId: snapshot.session.currentStepId,
      activeStepIds: active.sorted(),
      updatedAt: snapshot.session.updatedAt
    )
  }

  private func timelineEntries(from session: WorkflowSession) -> [WorkflowViewerTimelineEntry] {
    session.executions
      .sorted { lhs, rhs in
        if lhs.createdAt == rhs.createdAt {
          return lhs.executionId < rhs.executionId
        }
        return lhs.createdAt < rhs.createdAt
      }
      .map { execution in
        WorkflowViewerTimelineEntry(
          id: execution.executionId,
          stepId: execution.stepId,
          nodeId: execution.nodeId,
          attempt: execution.attempt,
          status: execution.status,
          backend: execution.backend,
          startedAt: execution.createdAt,
          endedAt: execution.status == .running ? nil : execution.updatedAt,
          lastBackendEventAt: execution.lastBackendEventAt,
          lastBackendEventType: execution.lastBackendEventType,
          failureReason: execution.failureReason
        )
      }
  }

  private func loadSnapshots(sessionStoreRoot: String) throws -> [WorkflowRuntimePersistenceSnapshot] {
    let runtimeRoot = runtimeStoreRoot(sessionStoreRoot: sessionStoreRoot)
    let snapshots = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot).loadAll()
    var seen: Set<String> = []
    return snapshots.filter { snapshot in
      seen.insert(snapshot.session.sessionId).inserted
    }
  }

  private func loadSnapshot(sessionId: String, sessionStoreRoot: String) throws -> WorkflowRuntimePersistenceSnapshot {
    guard isSafeSessionId(sessionId) else {
      throw WorkflowViewerLoadError.unsafeSessionId(sessionId)
    }
    return try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeStoreRoot(sessionStoreRoot: sessionStoreRoot)).load(sessionId: sessionId)
  }

  private func resolveSessionStore(
    explicitRoot: String?,
    workflowDirectory: String,
    workflowId: String
  ) throws -> WorkflowViewerSessionStoreResolution {
    if let explicitRoot {
      let root = URL(fileURLWithPath: explicitRoot, isDirectory: true).standardizedFileURL.path
      return WorkflowViewerSessionStoreResolution(
        root: root,
        candidates: [root],
        snapshots: try loadSnapshots(sessionStoreRoot: root),
        diagnostics: []
      )
    }

    let candidates = sessionStoreCandidates(workflowDirectory: workflowDirectory)
    var firstSnapshots: [WorkflowRuntimePersistenceSnapshot]?
    var diagnostics: [String] = []
    for candidate in candidates {
      let snapshots: [WorkflowRuntimePersistenceSnapshot]
      do {
        snapshots = try loadSnapshots(sessionStoreRoot: candidate)
      } catch {
        diagnostics.append("Skipped unreadable session store '\(candidate)': \(error)")
        continue
      }
      if firstSnapshots == nil {
        firstSnapshots = snapshots
      }
      if snapshots.contains(where: { $0.session.workflowId == workflowId }) {
        return WorkflowViewerSessionStoreResolution(
          root: candidate,
          candidates: candidates,
          snapshots: snapshots,
          diagnostics: diagnostics
        )
      }
    }

    let fallbackRoot = candidates.first ?? defaultSessionStoreRoot(workflowDirectory: workflowDirectory)
    return WorkflowViewerSessionStoreResolution(
      root: fallbackRoot,
      candidates: candidates,
      snapshots: firstSnapshots ?? [],
      diagnostics: diagnostics + ["No persisted sessions found for workflow '\(workflowId)' in searched session stores."]
    )
  }

  private func buildTree(
    workflow: WorkflowDefinition,
    workflowDirectory: String,
    selectedSession: WorkflowSession?
  ) -> [WorkflowViewerNode] {
    let stepsById = Dictionary(uniqueKeysWithValues: workflow.steps.map { ($0.id, $0) })
    var rendered: Set<String> = []
    var nodes: [WorkflowViewerNode] = []
    if stepsById[workflow.entryStepId] != nil {
      nodes.append(renderNode(
        stepId: workflow.entryStepId,
        workflow: workflow,
        workflowDirectory: workflowDirectory,
        stepsById: stepsById,
        selectedSession: selectedSession,
        path: [],
        rendered: &rendered,
        depth: 0
      ))
    }
    for step in workflow.steps where !rendered.contains(step.id) {
      nodes.append(renderNode(
        stepId: step.id,
        workflow: workflow,
        workflowDirectory: workflowDirectory,
        stepsById: stepsById,
        selectedSession: selectedSession,
        path: [],
        rendered: &rendered,
        depth: 0
      ))
    }
    return nodes
  }

  private func renderNode(
    stepId: String,
    workflow: WorkflowDefinition,
    workflowDirectory: String,
    stepsById: [String: WorkflowStepRef],
    selectedSession: WorkflowSession?,
    path: Set<String>,
    rendered: inout Set<String>,
    depth: Int
  ) -> WorkflowViewerNode {
    guard let step = stepsById[stepId] else {
      return WorkflowViewerNode(id: stepId, nodeId: stepId, title: stepId, detail: "missing step", state: .failed, depth: depth)
    }
    rendered.insert(stepId)
    let children = (step.transitions ?? [])
      .filter { $0.toWorkflowId == nil }
      .filter { !path.contains($0.toStepId) }
      .map { transition in
        renderNode(
          stepId: transition.toStepId,
          workflow: workflow,
          workflowDirectory: workflowDirectory,
          stepsById: stepsById,
          selectedSession: selectedSession,
          path: path.union([stepId]),
          rendered: &rendered,
          depth: depth + 1
        )
      }
    let detailParts = [
      step.role?.rawValue,
      step.promptVariant.map { "variant: \($0)" },
      step.description
    ].compactMap { $0 }
    return WorkflowViewerNode(
      id: step.id,
      nodeId: step.nodeId,
      title: step.id,
      detail: detailParts.isEmpty ? nil : detailParts.joined(separator: " - "),
      configuration: nodeConfiguration(for: step, workflow: workflow, workflowDirectory: workflowDirectory),
      templateFiles: templateFiles(for: step, workflow: workflow, workflowDirectory: workflowDirectory),
      state: runtimeState(stepId: step.id, selectedSession: selectedSession),
      depth: depth,
      children: children
    )
  }

  private func nodeConfiguration(
    for step: WorkflowStepRef,
    workflow: WorkflowDefinition,
    workflowDirectory: String
  ) -> WorkflowViewerNodeConfiguration? {
    guard let nodePayload = nodePayload(for: step, workflow: workflow, workflowDirectory: workflowDirectory) else {
      return nil
    }
    return WorkflowViewerNodeConfiguration(
      nodeFile: nodePayload.nodeFile,
      executionBackend: nodePayload.payload.executionBackend,
      model: nodePayload.payload.model,
      modelFreeze: nodePayload.payload.modelFreeze,
      effort: nodePayload.payload.effort
    )
  }

  private func templateFiles(
    for step: WorkflowStepRef,
    workflow: WorkflowDefinition,
    workflowDirectory: String
  ) -> [WorkflowViewerTemplateFile] {
    guard let nodePayload = nodePayload(for: step, workflow: workflow, workflowDirectory: workflowDirectory) else {
      return []
    }

    return templateFiles(
      payload: nodePayload.payload,
      step: step,
      nodeFile: nodePayload.nodeFile,
      workflowDirectory: workflowDirectory
    )
  }

  private func nodePayload(
    for step: WorkflowStepRef,
    workflow: WorkflowDefinition,
    workflowDirectory: String
  ) -> (nodeFile: String, payload: AgentNodePayload)? {
    guard let registryNode = workflow.nodeRegistry.first(where: { $0.id == step.nodeId }),
      let nodeFile = nodeFile(for: registryNode),
      let nodeURL = try? resolveWorkflowRelativeFilePath(nodeFile, workflowDirectory: workflowDirectory),
      FileManager.default.fileExists(atPath: nodeURL.path),
      let data = try? Data(contentsOf: nodeURL),
      let payload = try? JSONDecoder().decode(AgentNodePayload.self, from: data)
    else {
      return nil
    }
    return (nodeFile, payload)
  }

  private func templateFiles(
    payload: AgentNodePayload,
    step: WorkflowStepRef,
    nodeFile: String,
    workflowDirectory: String
  ) -> [WorkflowViewerTemplateFile] {
    let variant = step.promptVariant.flatMap { payload.promptVariants?[$0] }
    var files: [WorkflowViewerTemplateFile] = []

    appendTemplateFile(
      payload.systemPromptTemplateFile,
      fieldPath: "systemPromptTemplateFile",
      role: .systemPrompt,
      step: step,
      nodeFile: nodeFile,
      workflowDirectory: workflowDirectory,
      isActiveForStep: variant == nil || variant?.systemPromptTemplate == nil && variant?.systemPromptTemplateFile == nil,
      to: &files
    )
    appendTemplateFile(
      payload.promptTemplateFile,
      fieldPath: "promptTemplateFile",
      role: .prompt,
      step: step,
      nodeFile: nodeFile,
      workflowDirectory: workflowDirectory,
      isActiveForStep: variant == nil || variant?.promptTemplate == nil && variant?.promptTemplateFile == nil,
      to: &files
    )
    appendTemplateFile(
      payload.sessionStartPromptTemplateFile,
      fieldPath: "sessionStartPromptTemplateFile",
      role: .sessionStart,
      step: step,
      nodeFile: nodeFile,
      workflowDirectory: workflowDirectory,
      isActiveForStep: variant == nil || variant?.sessionStartPromptTemplate == nil && variant?.sessionStartPromptTemplateFile == nil,
      to: &files
    )

    for variantName in (payload.promptVariants ?? [:]).keys.sorted() {
      guard let promptVariant = payload.promptVariants?[variantName] else {
        continue
      }
      appendTemplateFile(
        promptVariant.systemPromptTemplateFile,
        fieldPath: "promptVariants.\(variantName).systemPromptTemplateFile",
        role: .systemPrompt,
        variantName: variantName,
        step: step,
        nodeFile: nodeFile,
        workflowDirectory: workflowDirectory,
        isActiveForStep: step.promptVariant == variantName,
        to: &files
      )
      appendTemplateFile(
        promptVariant.promptTemplateFile,
        fieldPath: "promptVariants.\(variantName).promptTemplateFile",
        role: .prompt,
        variantName: variantName,
        step: step,
        nodeFile: nodeFile,
        workflowDirectory: workflowDirectory,
        isActiveForStep: step.promptVariant == variantName,
        to: &files
      )
      appendTemplateFile(
        promptVariant.sessionStartPromptTemplateFile,
        fieldPath: "promptVariants.\(variantName).sessionStartPromptTemplateFile",
        role: .sessionStart,
        variantName: variantName,
        step: step,
        nodeFile: nodeFile,
        workflowDirectory: workflowDirectory,
        isActiveForStep: step.promptVariant == variantName,
        to: &files
      )
    }

    return files
  }

  private func appendTemplateFile(
    _ relativePath: String?,
    fieldPath: String,
    role: WorkflowViewerTemplateRole,
    variantName: String? = nil,
    step: WorkflowStepRef,
    nodeFile: String,
    workflowDirectory: String,
    isActiveForStep: Bool,
    to files: inout [WorkflowViewerTemplateFile]
  ) {
    guard let relativePath,
      let resolved = try? resolvePromptTemplatePath(
        relativePath,
        fieldName: fieldPath,
        workflowDirectory: URL(fileURLWithPath: workflowDirectory, isDirectory: true)
      )
    else {
      return
    }
    files.append(WorkflowViewerTemplateFile(
      id: [step.id, step.nodeId, fieldPath, relativePath].joined(separator: "|"),
      stepId: step.id,
      nodeId: step.nodeId,
      nodeFile: nodeFile,
      fieldPath: fieldPath,
      role: role,
      variantName: variantName,
      relativePath: relativePath,
      resolvedPath: resolved.path,
      isActiveForStep: isActiveForStep
    ))
  }

  private func nodeFile(for registryNode: WorkflowNodeRegistryRef) -> String? {
    if let nodeFile = registryNode.nodeFile {
      return nodeFile
    }
    if registryNode.addon == nil && registryNode.nodeRef == nil {
      return "nodes/\(registryNode.id).json"
    }
    return nil
  }

  private func resolveTemplateFile(_ templateFile: WorkflowViewerTemplateFile, workflowDirectory: String) throws -> URL {
    try resolvePromptTemplatePath(
      templateFile.relativePath,
      fieldName: templateFile.fieldPath,
      workflowDirectory: URL(fileURLWithPath: workflowDirectory, isDirectory: true)
    )
  }

  private func resolveWorkflowRelativeFilePath(_ relativePath: String, workflowDirectory: String) throws -> URL {
    let root = URL(fileURLWithPath: workflowDirectory, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    let resolved = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
    let rootPath = root.path
    guard resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/") else {
      throw WorkflowViewerLoadError.workflowNotFound(resolved.path)
    }
    return resolved
  }

  private func runtimeState(stepId: String, selectedSession: WorkflowSession?) -> WorkflowViewerNodeRuntimeState {
    guard let selectedSession else {
      return .idle
    }
    let isActive = selectedSession.executions.contains { $0.stepId == stepId && $0.status == .running }
      || (selectedSession.status == .running && selectedSession.currentStepId == stepId)
    if isActive {
      return .active
    }
    if selectedSession.executions.contains(where: { $0.stepId == stepId && $0.status == .failed }) {
      return .failed
    }
    if selectedSession.executions.contains(where: { $0.stepId == stepId && $0.status == .completed }) {
      return .completed
    }
    return .idle
  }

  private func viewerMessage(_ message: WorkflowMessageRecord, direction: WorkflowViewerMessageDirection) -> WorkflowViewerMessage {
    WorkflowViewerMessage(
      id: message.communicationId,
      direction: direction,
      fromStepId: message.fromStepId,
      toStepId: message.toStepId,
      status: message.lifecycleStatus,
      payloadPreview: preview(message.payload),
      artifactRefs: message.artifactRefs
    )
  }

  private func preview(_ object: JSONObject) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(JSONValue.object(object)),
      let rendered = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    if rendered.count > 1_200 {
      return String(rendered.prefix(1_200)) + "..."
    }
    return rendered
  }

  private func defaultSessionStoreRoot(workflowDirectory: String) -> String {
    URL(fileURLWithPath: workflowDirectory, isDirectory: true)
      .deletingLastPathComponent()
      .appendingPathComponent(".riela/sessions", isDirectory: true)
      .path
  }

  private func sessionStoreCandidates(workflowDirectory: String) -> [String] {
    var candidates: [String] = []
    var seen: Set<String> = []
    var current = URL(fileURLWithPath: workflowDirectory, isDirectory: true)
      .standardizedFileURL
      .deletingLastPathComponent()

    while true {
      let candidate = current
        .appendingPathComponent(".riela/sessions", isDirectory: true)
        .standardizedFileURL
        .path
      if seen.insert(candidate).inserted {
        candidates.append(candidate)
      }
      let parent = current.deletingLastPathComponent()
      if parent.path == current.path {
        break
      }
      current = parent
    }
    return candidates
  }

  private func runtimeStoreRoot(sessionStoreRoot: String) -> String {
    URL(fileURLWithPath: sessionStoreRoot, isDirectory: true)
      .appendingPathComponent("runtime-records", isDirectory: true)
      .path
  }

  private func isSafeSessionId(_ value: String) -> Bool {
    guard !value.isEmpty, !value.contains("/"), !value.contains("..") else {
      return false
    }
    return value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
  }
}

private struct WorkflowViewerSessionStoreResolution {
  var root: String
  var candidates: [String]
  var snapshots: [WorkflowRuntimePersistenceSnapshot]
  var diagnostics: [String]
}
