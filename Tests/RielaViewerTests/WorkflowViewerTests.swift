import Foundation
import RielaCore
import RielaViewer
import XCTest

final class WorkflowViewerTests: XCTestCase {
  func testViewerLoadsWorkflowTreeRunningStateAndNodeMessages() throws {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("riela-viewer-\(UUID().uuidString)", isDirectory: true)
    let workflowDirectory = temp.appendingPathComponent("workflows/demo", isDirectory: true)
    let sessionStoreRoot = temp.appendingPathComponent(".riela/sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sessionStoreRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let workflow = WorkflowDefinition(
      workflowId: "viewer-demo",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 3),
      entryStepId: "input",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "input"),
        WorkflowNodeRegistryRef(id: "worker"),
        WorkflowNodeRegistryRef(id: "output")
      ],
      steps: [
        WorkflowStepRef(id: "input", nodeId: "input", role: .worker, transitions: [
          WorkflowStepTransition(toStepId: "worker")
        ]),
        WorkflowStepRef(id: "worker", nodeId: "worker", role: .worker, transitions: [
          WorkflowStepTransition(toStepId: "output")
        ]),
        WorkflowStepRef(id: "output", nodeId: "output", role: .worker)
      ],
      nodes: [
        WorkflowNodeRef(id: "input", nodeFile: "nodes/input.json"),
        WorkflowNodeRef(id: "worker", nodeFile: "nodes/worker.json"),
        WorkflowNodeRef(id: "output", nodeFile: "nodes/output.json")
      ]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(workflow).write(to: workflowDirectory.appendingPathComponent("workflow.json"))

    let now = Date(timeIntervalSince1970: 10)
    let session = WorkflowSession(
      workflowId: "viewer-demo",
      sessionId: "viewer-demo-session-1",
      status: .running,
      entryStepId: "input",
      currentStepId: "worker",
      createdAt: now,
      updatedAt: now,
      executions: [
        WorkflowStepExecution(
          executionId: "exec-input",
          stepId: "input",
          nodeId: "input",
          attempt: 1,
          status: .completed,
          createdAt: now,
          updatedAt: now
        ),
        WorkflowStepExecution(
          executionId: "exec-worker",
          stepId: "worker",
          nodeId: "worker",
          attempt: 1,
          status: .running,
          createdAt: now,
          updatedAt: now
        )
      ]
    )
    let messages = [
      WorkflowMessageRecord(
        communicationId: "comm-1",
        workflowExecutionId: "viewer-demo-session-1",
        fromStepId: "input",
        toStepId: "worker",
        sourceStepExecutionId: "exec-input",
        payload: ["answer": .string("hello")],
        createdOrder: 1,
        createdAt: now
      ),
      WorkflowMessageRecord(
        communicationId: "comm-2",
        workflowExecutionId: "viewer-demo-session-1",
        fromStepId: "worker",
        toStepId: "output",
        sourceStepExecutionId: "exec-worker",
        payload: ["result": .string("done")],
        createdOrder: 2,
        createdAt: now
      )
    ]
    try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: sessionStoreRoot.appendingPathComponent("runtime-records", isDirectory: true).path
    ).save(WorkflowRuntimePersistenceSnapshot(session: session, workflowMessages: messages))

    let loader = WorkflowViewerLoader()
    let state = try loader.load(WorkflowViewerLoadRequest(
      workflowDirectory: workflowDirectory.path,
      sessionStoreRoot: sessionStoreRoot.path
    ))

    XCTAssertEqual(state.workflow.workflowId, "viewer-demo")
    XCTAssertEqual(state.selectedSessionId, "viewer-demo-session-1")
    XCTAssertEqual(state.sessions.first?.status, .running)
    XCTAssertEqual(state.nodes.first?.id, "input")
    XCTAssertEqual(state.nodes.first?.state, .completed)
    XCTAssertEqual(state.nodes.first?.children.first?.id, "worker")
    XCTAssertEqual(state.nodes.first?.children.first?.state, .active)

    let workerMessages = try loader.nodeMessages(
      stepId: "worker",
      sessionId: "viewer-demo-session-1",
      sessionStoreRoot: sessionStoreRoot.path
    )
    XCTAssertEqual(workerMessages.inbox.map(\.id), ["comm-1"])
    XCTAssertEqual(workerMessages.outbox.map(\.id), ["comm-2"])
    XCTAssertTrue(workerMessages.inbox.first?.payloadPreview.contains("hello") == true)
  }

  func testViewerCanSelectSpecificPersistedSession() throws {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("riela-viewer-selection-\(UUID().uuidString)", isDirectory: true)
    let workflowDirectory = temp.appendingPathComponent("workflows/demo", isDirectory: true)
    let sessionStoreRoot = temp.appendingPathComponent(".riela/sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sessionStoreRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let workflow = WorkflowDefinition(
      workflowId: "viewer-select",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 3),
      entryStepId: "first",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "first"), WorkflowNodeRegistryRef(id: "second")],
      steps: [
        WorkflowStepRef(id: "first", nodeId: "first", transitions: [WorkflowStepTransition(toStepId: "second")]),
        WorkflowStepRef(id: "second", nodeId: "second")
      ],
      nodes: [
        WorkflowNodeRef(id: "first", nodeFile: "nodes/first.json"),
        WorkflowNodeRef(id: "second", nodeFile: "nodes/second.json")
      ]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(workflow).write(to: workflowDirectory.appendingPathComponent("workflow.json"))

    let older = Date(timeIntervalSince1970: 1)
    let newer = Date(timeIntervalSince1970: 2)
    let store = SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: sessionStoreRoot.appendingPathComponent("runtime-records", isDirectory: true).path
    )
    try store.save(WorkflowRuntimePersistenceSnapshot(session: WorkflowSession(
      workflowId: "viewer-select",
      sessionId: "newer",
      status: .running,
      entryStepId: "first",
      currentStepId: "second",
      createdAt: newer,
      updatedAt: newer,
      executions: [WorkflowStepExecution(
        executionId: "exec-new",
        stepId: "second",
        nodeId: "second",
        attempt: 1,
        status: .running,
        createdAt: newer,
        updatedAt: newer
      )]
    )))
    try store.save(WorkflowRuntimePersistenceSnapshot(session: WorkflowSession(
      workflowId: "viewer-select",
      sessionId: "older",
      status: .running,
      entryStepId: "first",
      currentStepId: "first",
      createdAt: older,
      updatedAt: older,
      executions: [WorkflowStepExecution(
        executionId: "exec-old",
        stepId: "first",
        nodeId: "first",
        attempt: 1,
        status: .running,
        createdAt: older,
        updatedAt: older
      )]
    )))

    let state = try WorkflowViewerLoader().load(WorkflowViewerLoadRequest(
      workflowDirectory: workflowDirectory.path,
      sessionStoreRoot: sessionStoreRoot.path,
      selectedSessionId: "older"
    ))

    XCTAssertEqual(state.selectedSessionId, "older")
    XCTAssertEqual(state.nodes.first?.state, .active)
    XCTAssertEqual(state.nodes.first?.children.first?.state, .idle)
  }

  func testCompletedSessionCurrentStepIsNotRenderedActive() throws {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("riela-viewer-completed-\(UUID().uuidString)", isDirectory: true)
    let workflowDirectory = temp.appendingPathComponent("workflows/demo", isDirectory: true)
    let sessionStoreRoot = temp.appendingPathComponent(".riela/sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sessionStoreRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let workflow = WorkflowDefinition(
      workflowId: "viewer-completed",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 3),
      entryStepId: "first",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "first"), WorkflowNodeRegistryRef(id: "second")],
      steps: [
        WorkflowStepRef(id: "first", nodeId: "first", transitions: [WorkflowStepTransition(toStepId: "second")]),
        WorkflowStepRef(id: "second", nodeId: "second")
      ],
      nodes: [
        WorkflowNodeRef(id: "first", nodeFile: "nodes/first.json"),
        WorkflowNodeRef(id: "second", nodeFile: "nodes/second.json")
      ]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(workflow).write(to: workflowDirectory.appendingPathComponent("workflow.json"))

    let now = Date(timeIntervalSince1970: 20)
    let session = WorkflowSession(
      workflowId: "viewer-completed",
      sessionId: "viewer-completed-session-1",
      status: .completed,
      entryStepId: "first",
      currentStepId: "second",
      createdAt: now,
      updatedAt: now,
      executions: [
        WorkflowStepExecution(
          executionId: "exec-first",
          stepId: "first",
          nodeId: "first",
          attempt: 1,
          status: .completed,
          createdAt: now,
          updatedAt: now
        ),
        WorkflowStepExecution(
          executionId: "exec-second",
          stepId: "second",
          nodeId: "second",
          attempt: 1,
          status: .completed,
          createdAt: now,
          updatedAt: now
        )
      ]
    )
    try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: sessionStoreRoot.appendingPathComponent("runtime-records", isDirectory: true).path
    ).save(WorkflowRuntimePersistenceSnapshot(session: session))

    let state = try WorkflowViewerLoader().load(WorkflowViewerLoadRequest(
      workflowDirectory: workflowDirectory.path,
      sessionStoreRoot: sessionStoreRoot.path
    ))

    XCTAssertEqual(state.sessions.first?.status, .completed)
    XCTAssertEqual(state.sessions.first?.activeStepIds, [])
    XCTAssertEqual(state.nodes.first?.state, .completed)
    XCTAssertEqual(state.nodes.first?.children.first?.state, .completed)
  }

  func testViewerDiscoversAncestorSessionStoreWhenRequestDoesNotPinRoot() throws {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("riela-viewer-discovery-\(UUID().uuidString)", isDirectory: true)
    let workflowDirectory = temp.appendingPathComponent("examples/demo", isDirectory: true)
    let projectSessionStoreRoot = temp.appendingPathComponent(".riela/sessions", isDirectory: true)
    let nearerButEmptyRoot = temp.appendingPathComponent("examples/.riela/sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: projectSessionStoreRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nearerButEmptyRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let workflow = WorkflowDefinition(
      workflowId: "viewer-discovery",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 3),
      entryStepId: "first",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "first")],
      steps: [WorkflowStepRef(id: "first", nodeId: "first")],
      nodes: [WorkflowNodeRef(id: "first", nodeFile: "nodes/first.json")]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(workflow).write(to: workflowDirectory.appendingPathComponent("workflow.json"))

    let now = Date(timeIntervalSince1970: 3)
    try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: projectSessionStoreRoot.appendingPathComponent("runtime-records", isDirectory: true).path
    ).save(WorkflowRuntimePersistenceSnapshot(session: WorkflowSession(
      workflowId: "viewer-discovery",
      sessionId: "discovered",
      status: .running,
      entryStepId: "first",
      currentStepId: "first",
      createdAt: now,
      updatedAt: now,
      executions: [WorkflowStepExecution(
        executionId: "exec-discovered",
        stepId: "first",
        nodeId: "first",
        attempt: 1,
        status: .running,
        createdAt: now,
        updatedAt: now
      )]
    )))

    let state = try WorkflowViewerLoader().load(WorkflowViewerLoadRequest(workflowDirectory: workflowDirectory.path))

    XCTAssertEqual(state.sessionStoreRoot, projectSessionStoreRoot.path)
    XCTAssertTrue(state.sessionStoreCandidates.contains(nearerButEmptyRoot.path))
    XCTAssertEqual(state.selectedSessionId, "discovered")
    XCTAssertEqual(state.sessions.map(\.sessionId), ["discovered"])
    XCTAssertEqual(state.nodes.first?.state, .active)
  }

  func testViewerSkipsUnreadableImplicitSessionStoreAndKeepsSearchingAncestors() throws {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("riela-viewer-corrupt-discovery-\(UUID().uuidString)", isDirectory: true)
    let workflowDirectory = temp.appendingPathComponent("examples/demo", isDirectory: true)
    let projectSessionStoreRoot = temp.appendingPathComponent(".riela/sessions", isDirectory: true)
    let corruptRuntimeRoot = temp.appendingPathComponent("examples/.riela/sessions/runtime-records", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: projectSessionStoreRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: corruptRuntimeRoot.appendingPathComponent("bad-session", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data("{".utf8).write(to: corruptRuntimeRoot.appendingPathComponent("runtime-message-log.sqlite"))
    defer { try? FileManager.default.removeItem(at: temp) }

    let workflow = WorkflowDefinition(
      workflowId: "viewer-corrupt-discovery",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 3),
      entryStepId: "first",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "first")],
      steps: [WorkflowStepRef(id: "first", nodeId: "first")],
      nodes: [WorkflowNodeRef(id: "first", nodeFile: "nodes/first.json")]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(workflow).write(to: workflowDirectory.appendingPathComponent("workflow.json"))

    let now = Date(timeIntervalSince1970: 4)
    try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: projectSessionStoreRoot.appendingPathComponent("runtime-records", isDirectory: true).path
    ).save(WorkflowRuntimePersistenceSnapshot(session: WorkflowSession(
      workflowId: "viewer-corrupt-discovery",
      sessionId: "discovered-after-corrupt",
      status: .running,
      entryStepId: "first",
      currentStepId: "first",
      createdAt: now,
      updatedAt: now,
      executions: [WorkflowStepExecution(
        executionId: "exec-discovered",
        stepId: "first",
        nodeId: "first",
        attempt: 1,
        status: .running,
        createdAt: now,
        updatedAt: now
      )]
    )))

    let state = try WorkflowViewerLoader().load(WorkflowViewerLoadRequest(workflowDirectory: workflowDirectory.path))

    XCTAssertEqual(state.sessionStoreRoot, projectSessionStoreRoot.path)
    XCTAssertEqual(state.selectedSessionId, "discovered-after-corrupt")
    XCTAssertTrue(state.diagnostics.contains { $0.contains("Skipped unreadable session store") })
  }

  func testViewerReportsSearchedSessionStoresWhenNoSessionsExist() throws {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("riela-viewer-empty-\(UUID().uuidString)", isDirectory: true)
    let workflowDirectory = temp.appendingPathComponent("examples/demo", isDirectory: true)
    let nearerRoot = temp.appendingPathComponent("examples/.riela/sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let workflow = WorkflowDefinition(
      workflowId: "viewer-empty",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 3),
      entryStepId: "first",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "first")],
      steps: [WorkflowStepRef(id: "first", nodeId: "first")],
      nodes: [WorkflowNodeRef(id: "first", nodeFile: "nodes/first.json")]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(workflow).write(to: workflowDirectory.appendingPathComponent("workflow.json"))

    let state = try WorkflowViewerLoader().load(WorkflowViewerLoadRequest(workflowDirectory: workflowDirectory.path))

    XCTAssertEqual(state.sessionStoreRoot, nearerRoot.path)
    XCTAssertTrue(state.sessions.isEmpty)
    XCTAssertTrue(state.sessionStoreCandidates.contains(nearerRoot.path))
    XCTAssertEqual(state.diagnostics, ["No persisted sessions found for workflow 'viewer-empty' in searched session stores."])
  }

  func testViewerStateDecodesLegacyPayloadWithoutSessionStoreCandidates() throws {
    let workflow = WorkflowDefinition(
      workflowId: "viewer-legacy-state",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 3),
      entryStepId: "first",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "first")],
      steps: [WorkflowStepRef(id: "first", nodeId: "first")],
      nodes: [WorkflowNodeRef(id: "first", nodeFile: "nodes/first.json")]
    )
    let state = WorkflowViewerState(
      workflow: workflow,
      workflowDirectory: "/workflow",
      sessionStoreRoot: "/sessions",
      sessionStoreCandidates: ["/sessions"],
      selectedSessionId: nil,
      sessions: [],
      nodes: [WorkflowViewerNode(id: "first", nodeId: "first", title: "first", state: .idle)]
    )

    let data = try JSONEncoder().encode(state)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "sessionStoreCandidates")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(WorkflowViewerState.self, from: legacyData)

    XCTAssertEqual(decoded.workflow.workflowId, "viewer-legacy-state")
    XCTAssertEqual(decoded.sessionStoreCandidates, [])
    XCTAssertEqual(decoded.diagnostics, [])
  }
}
