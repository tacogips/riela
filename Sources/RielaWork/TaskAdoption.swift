import Foundation
import RielaCore

public struct AdoptionResult: Sendable {
  public var intent: Intent?
  public var task: WorkTask
  public var attempt: Attempt
  public init(intent: Intent?, task: WorkTask, attempt: Attempt) { self.intent = intent; self.task = task; self.attempt = attempt }
}

public struct TaskAdoption: Sendable {
  private let store: WorkStore
  public init(store: WorkStore) { self.store = store }

  public func adopt(session: WorkflowSession, workflow: WorkflowReference, workingDirectory: String,
                    repositoryRoot: String? = nil, principal: String, existingTaskId: TaskID? = nil,
                    now: Date) throws -> AdoptionResult {
    guard session.status != .completed else { throw WorkStoreError("completed sessions cannot be adopted") }
    guard session.workflowId == workflow.name else { throw WorkStoreError("workflow does not match adopted session") }
    let sessionSuffix = session.sessionId.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
    let intentId = IntentID("intent-adopted-\(sessionSuffix)")
    let taskId = existingTaskId ?? TaskID("task-adopted-\(sessionSuffix)")
    let proposed = Attempt(id: AttemptID("attempt-adopted-\(sessionSuffix)"), taskId: taskId, generation: 1,
      sessionId: session.sessionId, entry: .start, state: .terminal)
    let intent: Intent? = existingTaskId == nil ? Intent(id: intentId, title: workflow.name, instruction: "Adopted session \(session.sessionId)", origin: .cli) : nil
    var task: WorkTask
    if let existingTaskId {
      guard let existing = try store.loadTask(id: existingTaskId) else { throw WorkStoreError("task '\(existingTaskId.rawValue)' was not found") }
      guard !existing.state.isTerminal else { throw WorkStoreError("terminal tasks cannot adopt a session") }
      guard case let .workflow(reference)? = existing.plan, reference.name == workflow.name else {
        throw WorkStoreError("task workflow does not match adopted session")
      }
      guard try store.listAttempts(taskId: existing.id).allSatisfy({ $0.state != .prepared && $0.state != .running && $0.state != .terminal }) else {
        throw WorkStoreError("task has a live attempt")
      }
      task = existing
    } else {
      task = WorkTask(id: taskId, intentId: intentId, title: workflow.name, instruction: "Adopted session \(session.sessionId)",
        plan: .workflow(workflow), context: repositoryRoot.map { .repository(RepositoryContext(root: $0)) }, state: .running)
    }
    let evidence = Evidence(id: EvidenceID("evidence-adopted-\(sessionSuffix)"), taskId: task.id, attemptId: proposed.id,
      kind: .contextSnapshot, producedBy: .contextAdapter("session-adoption"),
      payloadRef: .inline(["adoptedFromSession": .string(session.sessionId), "workingDirectory": .string(workingDirectory),
                           "principal": .string(principal)]), createdAt: now)
    let attempt = try store.adoptSession(intent: intent, task: task, attempt: proposed, evidence: evidence, existingTaskVersion: existingTaskId == nil ? nil : task.version, now: now)
    if existingTaskId != nil {
      task.state = .running
      task.version += 1
    }
    return AdoptionResult(intent: intent, task: task, attempt: attempt)
  }
}
