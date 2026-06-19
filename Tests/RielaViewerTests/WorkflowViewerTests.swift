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
    try FileWorkflowRuntimePersistenceStore(
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
    let store = FileWorkflowRuntimePersistenceStore(
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
}
