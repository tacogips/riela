import Foundation
import RielaCore
import XCTest
@testable import RielaWork

final class TaskAdoptionTests: XCTestCase {
  func testCompletedSessionCannotBeAdopted() throws {
    let store = WorkStore(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path)
    let now = Date(timeIntervalSince1970: 10)
    let session = WorkflowSession(workflowId: "flow", sessionId: "session-1", status: .completed, entryStepId: "start", createdAt: now, updatedAt: now)
    XCTAssertThrowsError(try TaskAdoption(store: store).adopt(session: session, workflow: WorkflowReference(name: "flow"),
      workingDirectory: "/tmp", principal: "operator", now: now)) { error in
      XCTAssertTrue(String(describing: error).contains("completed sessions"))
    }
  }

  func testWorkflowMismatchIsRefused() throws {
    let now = Date(timeIntervalSince1970: 10)
    let session = WorkflowSession(workflowId: "source", sessionId: "session-1", status: .suspended,
      entryStepId: "start", createdAt: now, updatedAt: now)
    let store = WorkStore(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path)
    XCTAssertThrowsError(try TaskAdoption(store: store).adopt(session: session, workflow: WorkflowReference(name: "other"),
      workingDirectory: "/workspace", principal: "operator", now: now))
  }

  func testSessionAdoptionCreatesTaskAttemptAndEvidenceAndRejectsDuplicate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkStore(rootDirectory: root.path)
    let now = Date(timeIntervalSince1970: 10)
    let session = WorkflowSession(workflowId: "flow", sessionId: "session-1", status: .suspended, entryStepId: "start", createdAt: now, updatedAt: now)
    let adoption = TaskAdoption(store: store)
    let result = try adoption.adopt(session: session, workflow: WorkflowReference(name: "flow"), workingDirectory: "/workspace",
      repositoryRoot: "/repo", principal: "operator", now: now)
    XCTAssertEqual(result.intent?.origin, .cli)
    XCTAssertEqual(result.attempt.generation, 1)
    XCTAssertEqual(try store.loadAttempt(id: result.attempt.id)?.generation, 1)
    XCTAssertEqual(try store.loadTask(id: result.task.id)?.state, .running)
    XCTAssertEqual(try store.loadAttempt(id: result.attempt.id)?.state, .terminal)
    XCTAssertEqual(try store.listEvidence(taskId: result.task.id).first?.payloadRef.inlinePayload?["adoptedFromSession"], .string("session-1"))
    XCTAssertThrowsError(try adoption.adopt(session: session, workflow: WorkflowReference(name: "flow"),
      workingDirectory: "/workspace", principal: "operator", now: now)) { error in
      XCTAssertTrue(String(describing: error).contains("already adopted"), "unexpected error: \(error)")
    }
  }

  func testExistingIdleTaskIsAdoptedWithoutCreatingIntent() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(id: TaskID("task-existing"), intentId: IntentID("intent-existing"), title: "Existing", instruction: "Continue",
      plan: .workflow(WorkflowReference(name: "flow")), state: .waiting, version: 4)
    try store.saveTask(task)
    let now = Date(timeIntervalSince1970: 10)
    let session = WorkflowSession(workflowId: "flow", sessionId: "session-existing", status: .suspended,
      entryStepId: "start", createdAt: now, updatedAt: now)
    let result = try TaskAdoption(store: store).adopt(session: session, workflow: WorkflowReference(name: "flow"),
      workingDirectory: "/workspace", principal: "operator", existingTaskId: task.id, now: now)
    XCTAssertNil(result.intent)
    XCTAssertEqual(result.task.state, .running)
    XCTAssertEqual(result.task.version, 5)
    XCTAssertEqual(try store.loadTask(id: task.id)?.version, 5)
    XCTAssertEqual(try store.listAttempts(taskId: task.id).map(\.id), [result.attempt.id])
  }

  func testExistingTaskWithLiveAttemptIsRefusedAndNothingPersisted() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(id: TaskID("task-live"), intentId: IntentID("intent-live"), title: "Live", instruction: "Continue",
      plan: .workflow(WorkflowReference(name: "flow")), state: .running, version: 4)
    try store.saveTask(task)
    let liveAttempt = Attempt(id: AttemptID("attempt-live"), taskId: task.id, generation: 1, sessionId: "session-live",
      entry: .start, state: .running)
    try store.saveAttempt(liveAttempt)
    let now = Date(timeIntervalSince1970: 10)
    let session = WorkflowSession(workflowId: "flow", sessionId: "session-new", status: .suspended,
      entryStepId: "start", createdAt: now, updatedAt: now)
    XCTAssertThrowsError(try TaskAdoption(store: store).adopt(session: session, workflow: WorkflowReference(name: "flow"),
      workingDirectory: "/workspace", principal: "operator", existingTaskId: task.id, now: now)) { error in
      XCTAssertTrue(String(describing: error).contains("live attempt"), "unexpected error: \(error)")
    }
    let reloaded = try store.loadTask(id: task.id)
    XCTAssertEqual(reloaded?.version, 4)
    XCTAssertEqual(reloaded?.state, .running)
    XCTAssertEqual(try store.listAttempts(taskId: task.id).map(\.id), [liveAttempt.id])
    XCTAssertTrue(try store.listEvidence(taskId: task.id).isEmpty)
  }

  func testExistingTaskAdoptionUsesNextGeneration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(id: TaskID("task-generations"), intentId: IntentID("intent-generations"), title: "Generations",
      instruction: "Continue", plan: .workflow(WorkflowReference(name: "flow")), state: .waiting, version: 4)
    try store.saveTask(task)
    for generation in 1...2 {
      try store.saveAttempt(Attempt(id: AttemptID("attempt-prior-\(generation)"), taskId: task.id, generation: generation,
        sessionId: "session-prior-\(generation)", entry: .start, state: .reconciled))
    }
    let now = Date(timeIntervalSince1970: 10)
    let session = WorkflowSession(workflowId: "flow", sessionId: "session-next", status: .suspended,
      entryStepId: "start", createdAt: now, updatedAt: now)
    let result = try TaskAdoption(store: store).adopt(session: session, workflow: WorkflowReference(name: "flow"),
      workingDirectory: "/workspace", principal: "operator", existingTaskId: task.id, now: now)
    XCTAssertEqual(result.attempt.generation, 3)
    XCTAssertEqual(try store.loadAttempt(id: result.attempt.id)?.generation, 3)
    XCTAssertEqual(try store.listAttempts(taskId: task.id).map(\.generation).sorted(), [1, 2, 3])
  }

  func testExistingTaskWithTerminalAttemptIsRefused() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(id: TaskID("task-unreconciled"), intentId: IntentID("intent-unreconciled"), title: "Unreconciled",
      instruction: "Continue", plan: .workflow(WorkflowReference(name: "flow")), state: .waiting, version: 4)
    try store.saveTask(task)
    let terminalAttempt = Attempt(id: AttemptID("attempt-terminal"), taskId: task.id, generation: 1, sessionId: "session-terminal",
      entry: .start, state: .terminal)
    try store.saveAttempt(terminalAttempt)
    let now = Date(timeIntervalSince1970: 10)
    let session = WorkflowSession(workflowId: "flow", sessionId: "session-new", status: .suspended,
      entryStepId: "start", createdAt: now, updatedAt: now)
    XCTAssertThrowsError(try TaskAdoption(store: store).adopt(session: session, workflow: WorkflowReference(name: "flow"),
      workingDirectory: "/workspace", principal: "operator", existingTaskId: task.id, now: now)) { error in
      XCTAssertTrue(String(describing: error).contains("live attempt"), "unexpected error: \(error)")
    }
    XCTAssertEqual(try store.loadTask(id: task.id)?.version, 4)
    XCTAssertEqual(try store.listAttempts(taskId: task.id).map(\.id), [terminalAttempt.id])
    XCTAssertTrue(try store.listEvidence(taskId: task.id).isEmpty)
  }

  func testExistingTaskWithDifferentWorkflowIsRefused() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(id: TaskID("task-other"), intentId: IntentID("intent-other"), title: "Other", instruction: "Continue",
      plan: .workflow(WorkflowReference(name: "other")), state: .waiting, version: 2)
    try store.saveTask(task)
    let now = Date(timeIntervalSince1970: 10)
    let session = WorkflowSession(workflowId: "flow", sessionId: "session-flow", status: .suspended,
      entryStepId: "start", createdAt: now, updatedAt: now)
    XCTAssertThrowsError(try TaskAdoption(store: store).adopt(session: session, workflow: WorkflowReference(name: "flow"),
      workingDirectory: "/workspace", principal: "operator", existingTaskId: task.id, now: now)) { error in
      XCTAssertTrue(String(describing: error).contains("task workflow does not match"), "unexpected error: \(error)")
    }
    let reloaded = try store.loadTask(id: task.id)
    XCTAssertEqual(reloaded?.version, 2)
    XCTAssertEqual(reloaded?.state, .waiting)
    XCTAssertTrue(try store.listAttempts(taskId: task.id).isEmpty)
    XCTAssertTrue(try store.listEvidence(taskId: task.id).isEmpty)
  }

  func testTerminalExistingTaskIsRefused() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(id: TaskID("task-done"), intentId: IntentID("intent-done"), title: "Done", instruction: "Continue",
      plan: .workflow(WorkflowReference(name: "flow")), state: .succeeded, version: 7)
    try store.saveTask(task)
    let now = Date(timeIntervalSince1970: 10)
    let session = WorkflowSession(workflowId: "flow", sessionId: "session-done", status: .suspended,
      entryStepId: "start", createdAt: now, updatedAt: now)
    XCTAssertThrowsError(try TaskAdoption(store: store).adopt(session: session, workflow: WorkflowReference(name: "flow"),
      workingDirectory: "/workspace", principal: "operator", existingTaskId: task.id, now: now)) { error in
      XCTAssertTrue(String(describing: error).contains("terminal"), "unexpected error: \(error)")
    }
    XCTAssertEqual(try store.loadTask(id: task.id)?.version, 7)
    XCTAssertEqual(try store.loadTask(id: task.id)?.state, .succeeded)
    XCTAssertTrue(try store.listAttempts(taskId: task.id).isEmpty)
  }
}
