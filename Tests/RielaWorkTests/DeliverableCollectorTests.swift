import Foundation
import RielaCore
import XCTest
@testable import RielaWork

final class DeliverableCollectorTests: XCTestCase {
  func testCollectsKaibaNoteAndNotebookIdsWithInstance() {
    let workflow = makeWorkflow(nodes: [addonNode("notes", "kaiba/note-create", config: ["kaibaInstanceId": .string("docs")])], steps: ["create": "notes"])
    let snapshot = makeSnapshot([
      execution("create", nodeId: "notes", payload: ["noteId": .string("n-1"), "notebookId": .string("b-1")])
    ])

    XCTAssertEqual(collect(workflow: workflow, snapshot: snapshot), [
      .document(DocumentDeliverable(store: "kaiba", instance: "docs", ids: ["b-1", "n-1"], producedByStepIds: ["create"]))
    ])
  }

  func testMergesKaibaStepsOnSameInstance() {
    let workflow = makeWorkflow(nodes: [addonNode("notes", "kaiba/note-create", config: ["kaibaInstanceId": .string("docs")])],
                                steps: ["create-a": "notes", "create-b": "notes"])
    let snapshot = makeSnapshot([
      execution("create-b", nodeId: "notes", payload: ["noteId": .string("n-2")]),
      execution("create-a", nodeId: "notes", payload: ["noteId": .string("n-1")])
    ])

    XCTAssertEqual(collect(workflow: workflow, snapshot: snapshot), [
      .document(DocumentDeliverable(store: "kaiba", instance: "docs", ids: ["n-1", "n-2"], producedByStepIds: ["create-a", "create-b"]))
    ])
  }

  func testCollectsDeclaredProjectionStringAndArrayIds() {
    let workflow = makeWorkflow(
      nodes: [WorkflowNodeRef(id: "command", nodeFile: "nodes/command.json")],
      steps: ["create": "command"]
    )
    let projection = WorkflowDeliverableProjection(store: "monja", instanceField: "baseUrl", idFields: ["taskId", "commentIds"])
    let payload = AgentNodePayload(
      id: "command",
      nodeType: .command,
      model: "command",
      output: NodeOutputContract(deliverables: projection)
    )
    let snapshot = makeSnapshot([
      execution("create", nodeId: "command", payload: [
        "baseUrl": .string("https://monja.example"),
        "taskId": .string("task-1"),
        "commentIds": .array([.string("comment-2"), .string("comment-1")])
      ])
    ])

    XCTAssertEqual(collect(workflow: workflow, payloads: ["command": payload], snapshot: snapshot), [
      .document(DocumentDeliverable(store: "monja", instance: "https://monja.example", ids: ["comment-1", "comment-2", "task-1"], producedByStepIds: ["create"]))
    ])
  }

  func testCollectsKVAsLocalOnlyUsingDatabasePath() {
    let workflow = makeWorkflow(nodes: [addonNode("kv", "riela/kv-set", config: ["kvRoot": .string("configured-root")])], steps: ["save": "kv"])
    let snapshot = makeSnapshot([
      execution("save", nodeId: "kv", payload: ["databasePath": .string("/tmp/workflow-kv.sqlite")])
    ])

    XCTAssertEqual(collect(workflow: workflow, snapshot: snapshot), [
      .localOnly(LocalOnlyDeliverable(kind: "kv", path: "/tmp/workflow-kv.sqlite"))
    ])
  }

  func testIgnoresFailedAndUnacceptedExecutions() {
    let workflow = makeWorkflow(nodes: [addonNode("notes", "kaiba/note-create")], steps: ["failed": "notes", "unaccepted": "notes"])
    let snapshot = makeSnapshot([
      execution("failed", nodeId: "notes", status: .failed, payload: ["noteId": .string("n-failed")]),
      execution("unaccepted", nodeId: "notes", payload: nil)
    ])

    XCTAssertEqual(collect(workflow: workflow, snapshot: snapshot), [])
  }

  func testOutputOrderingIsDeterministicAcrossExecutionOrder() {
    let workflow = makeWorkflow(nodes: [
      addonNode("kaiba-z", "kaiba/note-create", config: ["kaibaInstanceId": .string("z")]),
      addonNode("kaiba-a", "kaiba/note-create", config: ["kaibaInstanceId": .string("a")]),
      addonNode("kv", "riela/kv-set", config: ["kvRoot": .string("fallback-kv")]),
      addonNode("memory", "riela/memory-save", config: ["memoryRoot": .string("fallback-memory")])
    ], steps: ["z": "kaiba-z", "a": "kaiba-a", "kv": "kv", "memory": "memory"])
    let first = makeSnapshot([
      execution("z", nodeId: "kaiba-z", payload: ["noteId": .string("z-note")]),
      execution("a", nodeId: "kaiba-a", payload: ["noteId": .string("a-note")]),
      execution("memory", nodeId: "memory", payload: [:]),
      execution("kv", nodeId: "kv", payload: [:])
    ])
    let shuffled = makeSnapshot([
      execution("kv", nodeId: "kv", payload: [:]),
      execution("memory", nodeId: "memory", payload: [:]),
      execution("a", nodeId: "kaiba-a", payload: ["noteId": .string("a-note")]),
      execution("z", nodeId: "kaiba-z", payload: ["noteId": .string("z-note")])
    ])

    let expected = [
      DeliverableRef.document(DocumentDeliverable(store: "kaiba", instance: "a", ids: ["a-note"], producedByStepIds: ["a"])),
      .document(DocumentDeliverable(store: "kaiba", instance: "z", ids: ["z-note"], producedByStepIds: ["z"])),
      .localOnly(LocalOnlyDeliverable(kind: "kv", path: "fallback-kv")),
      .localOnly(LocalOnlyDeliverable(kind: "memory", path: "fallback-memory"))
    ]
    XCTAssertEqual(collect(workflow: workflow, snapshot: first), expected)
    XCTAssertEqual(collect(workflow: workflow, snapshot: shuffled), expected)
  }

  private func collect(
    workflow: WorkflowDefinition,
    payloads: [String: AgentNodePayload] = [:],
    snapshot: WorkflowRuntimePersistenceSnapshot
  ) -> [DeliverableRef] {
    DeliverableCollector(workflow: workflow, nodePayloads: payloads).collect(snapshot: snapshot)
  }

  private func makeWorkflow(nodes: [WorkflowNodeRef], steps: [String: String]) -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "deliverables",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: steps.keys.sorted().first ?? "entry",
      nodeRegistry: [],
      steps: steps.keys.sorted().map { WorkflowStepRef(id: $0, nodeId: steps[$0] ?? "") },
      nodes: nodes
    )
  }

  private func addonNode(_ id: String, _ name: String, config: JSONObject? = nil) -> WorkflowNodeRef {
    WorkflowNodeRef(id: id, addon: WorkflowNodeAddonRef(name: name, config: config))
  }

  private func makeSnapshot(_ executions: [WorkflowStepExecution]) -> WorkflowRuntimePersistenceSnapshot {
    let date = Date(timeIntervalSince1970: 1)
    let session = WorkflowSession(
      workflowId: "deliverables",
      sessionId: "session-1",
      entryStepId: executions.first?.stepId ?? "entry",
      createdAt: date,
      updatedAt: date,
      executions: executions
    )
    return WorkflowRuntimePersistenceSnapshot(session: session)
  }

  private func execution(
    _ stepId: String,
    nodeId: String,
    status: WorkflowStepExecutionStatus = .completed,
    payload: JSONObject?
  ) -> WorkflowStepExecution {
    let date = Date(timeIntervalSince1970: 1)
    let accepted = payload.map {
      WorkflowAcceptedOutputMetadata(payload: $0, when: [:], acceptedAt: date)
    }
    return WorkflowStepExecution(
      executionId: "exec-\(stepId)",
      stepId: stepId,
      nodeId: nodeId,
      attempt: 1,
      status: status,
      acceptedOutput: accepted,
      createdAt: date,
      updatedAt: date
    )
  }
}
