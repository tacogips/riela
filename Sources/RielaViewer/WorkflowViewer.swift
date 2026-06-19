import Foundation
import RielaCore

public enum WorkflowViewerNodeRuntimeState: String, Codable, Equatable, Sendable {
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

public struct WorkflowViewerNode: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var nodeId: String
  public var title: String
  public var detail: String?
  public var state: WorkflowViewerNodeRuntimeState
  public var depth: Int
  public var children: [WorkflowViewerNode]

  public init(
    id: String,
    nodeId: String,
    title: String,
    detail: String? = nil,
    state: WorkflowViewerNodeRuntimeState,
    depth: Int = 0,
    children: [WorkflowViewerNode] = []
  ) {
    self.id = id
    self.nodeId = nodeId
    self.title = title
    self.detail = detail
    self.state = state
    self.depth = depth
    self.children = children
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

public struct WorkflowViewerState: Codable, Equatable, Sendable {
  public var workflow: WorkflowDefinition
  public var workflowDirectory: String
  public var sessionStoreRoot: String
  public var sessionStoreCandidates: [String]
  public var selectedSessionId: String?
  public var sessions: [WorkflowViewerSessionSummary]
  public var nodes: [WorkflowViewerNode]
  public var diagnostics: [String]

  public init(
    workflow: WorkflowDefinition,
    workflowDirectory: String,
    sessionStoreRoot: String,
    sessionStoreCandidates: [String] = [],
    selectedSessionId: String?,
    sessions: [WorkflowViewerSessionSummary],
    nodes: [WorkflowViewerNode],
    diagnostics: [String] = []
  ) {
    self.workflow = workflow
    self.workflowDirectory = workflowDirectory
    self.sessionStoreRoot = sessionStoreRoot
    self.sessionStoreCandidates = sessionStoreCandidates
    self.selectedSessionId = selectedSessionId
    self.sessions = sessions
    self.nodes = nodes
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

  public var description: String {
    switch self {
    case let .workflowNotFound(path):
      "workflow.json was not found at \(path)"
    case let .invalidWorkflow(diagnostics):
      "workflow is invalid: \(diagnostics.joined(separator: "; "))"
    case let .unsafeSessionId(sessionId):
      "unsafe session id: \(sessionId)"
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
      nodes: buildTree(workflow: workflow, selectedSession: selectedSnapshot?.session),
      diagnostics: diagnostics
    )
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
    let active = Set(
      snapshot.session.executions
        .filter { $0.status == .running }
        .map(\.stepId)
        + [snapshot.session.currentStepId].compactMap { $0 }
    )
    return WorkflowViewerSessionSummary(
      sessionId: snapshot.session.sessionId,
      workflowId: snapshot.session.workflowId,
      status: snapshot.session.status,
      currentStepId: snapshot.session.currentStepId,
      activeStepIds: active.sorted(),
      updatedAt: snapshot.session.updatedAt
    )
  }

  private func loadSnapshots(sessionStoreRoot: String) throws -> [WorkflowRuntimePersistenceSnapshot] {
    let runtimeRoot = runtimeStoreRoot(sessionStoreRoot: sessionStoreRoot)
    var snapshots = try FileWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot).loadAll()
    snapshots.append(contentsOf: try loadSessionOnlySnapshots(sessionStoreRoot: sessionStoreRoot))
    var seen: Set<String> = []
    return snapshots.filter { snapshot in
      seen.insert(snapshot.session.sessionId).inserted
    }
  }

  private func loadSnapshot(sessionId: String, sessionStoreRoot: String) throws -> WorkflowRuntimePersistenceSnapshot {
    guard isSafeSessionId(sessionId) else {
      throw WorkflowViewerLoadError.unsafeSessionId(sessionId)
    }
    do {
      return try FileWorkflowRuntimePersistenceStore(rootDirectory: runtimeStoreRoot(sessionStoreRoot: sessionStoreRoot)).load(sessionId: sessionId)
    } catch let error as WorkflowRuntimePersistenceStoreError {
      if case .notFound = error {
        if let sessionOnly = try loadSessionOnlySnapshots(sessionStoreRoot: sessionStoreRoot)
          .first(where: { $0.session.sessionId == sessionId }) {
          return sessionOnly
        }
      }
      throw error
    }
  }

  private func loadSessionOnlySnapshots(sessionStoreRoot: String) throws -> [WorkflowRuntimePersistenceSnapshot] {
    let root = URL(fileURLWithPath: sessionStoreRoot, isDirectory: true)
    guard FileManager.default.fileExists(atPath: root.path) else {
      return []
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .map { try decoder.decode(PersistedViewerSessionRecord.self, from: Data(contentsOf: $0)) }
      .map { WorkflowRuntimePersistenceSnapshot(session: $0.session) }
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

  private func buildTree(workflow: WorkflowDefinition, selectedSession: WorkflowSession?) -> [WorkflowViewerNode] {
    let stepsById = Dictionary(uniqueKeysWithValues: workflow.steps.map { ($0.id, $0) })
    var rendered: Set<String> = []
    var nodes: [WorkflowViewerNode] = []
    if stepsById[workflow.entryStepId] != nil {
      nodes.append(renderNode(stepId: workflow.entryStepId, workflow: workflow, stepsById: stepsById, selectedSession: selectedSession, path: [], rendered: &rendered, depth: 0))
    }
    for step in workflow.steps where !rendered.contains(step.id) {
      nodes.append(renderNode(stepId: step.id, workflow: workflow, stepsById: stepsById, selectedSession: selectedSession, path: [], rendered: &rendered, depth: 0))
    }
    return nodes
  }

  private func renderNode(
    stepId: String,
    workflow: WorkflowDefinition,
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
      state: runtimeState(stepId: step.id, selectedSession: selectedSession),
      depth: depth,
      children: children
    )
  }

  private func runtimeState(stepId: String, selectedSession: WorkflowSession?) -> WorkflowViewerNodeRuntimeState {
    guard let selectedSession else {
      return .idle
    }
    if selectedSession.currentStepId == stepId || selectedSession.executions.contains(where: { $0.stepId == stepId && $0.status == .running }) {
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

private struct PersistedViewerSessionRecord: Codable {
  var session: WorkflowSession
}

private struct WorkflowViewerSessionStoreResolution {
  var root: String
  var candidates: [String]
  var snapshots: [WorkflowRuntimePersistenceSnapshot]
  var diagnostics: [String]
}
