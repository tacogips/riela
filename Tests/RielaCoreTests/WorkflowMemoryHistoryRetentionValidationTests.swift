import Foundation
import RielaMemory
import XCTest
@testable import RielaCore

// Keep the suite name aligned with the implementation-plan filter.
// swiftlint:disable:next type_name
final class WorkflowMemoryHistoryRetentionValidationTests: XCTestCase {
  func testAbsentHistoryRetentionRemainsCodableCompatible() throws {
    let legacy = try JSONDecoder().decode(WorkflowMemoryDeclaration.self, from: Data(#"{"id":"legacy-memory"}"#.utf8))
    XCTAssertNil(legacy.historyRetention)
    let encoded = try JSONEncoder().encode(legacy)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertNil(object["historyRetention"])
  }

  func testDeclarationRetentionRangeAndUnknownKeyValidation() throws {
    let accepted = validateAuthoredWorkflowJSON(authoredWorkflow(retention: 3))
    XCTAssertFalse(accepted.diagnostics.contains { $0.severity == .error })

    for invalidRetention in [0, 1_001] {
      let diagnostics = validateAuthoredWorkflowJSON(authoredWorkflow(retention: invalidRetention)).diagnostics
      XCTAssertTrue(diagnostics.contains {
        $0.path == "workflow.memories[0].historyRetention" && $0.message.contains("bounded-memory")
      }, "\(diagnostics)")
    }

    var rawDiagnostics: [WorkflowValidationDiagnostic] = []
    validateRawMemoryDeclarations([
      ["id": "bounded-memory", "historyRetention": 3, "unexpected": true]
    ], path: "workflow.memories", diagnostics: &rawDiagnostics)
    XCTAssertTrue(rawDiagnostics.contains { $0.path == "workflow.memories[0].unexpected" })
  }

  func testWorkflowRunPassesNodeAndWorkflowDeclaredRetentionIntoMemoryAddonWrites() async throws {
    for nodeDeclaresRetention in [false, true] {
      let root = temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let workflowMemory = WorkflowMemoryDeclaration(id: "bounded-memory", historyRetention: nodeDeclaresRetention ? nil : 3)
      let nodeMemory = WorkflowMemoryDeclaration(id: "bounded-memory", historyRetention: nodeDeclaresRetention ? 3 : nil)
      let addonResolver = RetentionWritingAddonResolver(root: root)
      let runner = DeterministicWorkflowRunner(
        addonResolver: addonResolver,
        inputResolver: RetentionInputResolver()
      )
      let workflow = WorkflowDefinition(
        workflowId: "mock-workflow",
        defaults: WorkflowDefaults(nodeTimeoutMs: 30_000, maxLoopIterations: 3),
        memories: [workflowMemory],
        entryStepId: "save",
        nodeRegistry: [WorkflowNodeRegistryRef(
          id: "save-node", addon: WorkflowNodeAddonRef(name: "test/memory-save"), memories: [nodeMemory]
        )],
        steps: [WorkflowStepRef(id: "save", nodeId: "save-node", role: .worker)],
        nodes: [WorkflowNodeRef(
          id: "save", addon: WorkflowNodeAddonRef(name: "test/memory-save"), role: .worker, memories: [nodeMemory]
        )]
      )

      _ = try await runner.run(DeterministicWorkflowRunRequest(workflow: workflow, memoryRootDirectory: root.path))
      let maybeRecordId = await addonResolver.recordId()
      let recordId = try XCTUnwrap(maybeRecordId)
      let history = try RielaMemoryStore(rootDirectory: root.path).evolutionHistory(memoryId: "bounded-memory", recordId: recordId)
      XCTAssertEqual(history.map(\.version), [5, 4, 3])
      XCTAssertEqual(history.filter { $0.isHead == false }.count, 2)

      let store = RielaMemoryStore(rootDirectory: root.path)
      let automaticRecord = try XCTUnwrap(store.search(
        memoryId: "bounded-memory", options: MemorySearchOptions(workflowId: "mock-workflow", limit: 20)
      ).first { record in
        guard case let .object(payload) = record.payload else { return false }
        return payload["direction"] == .string("inbox")
      })
      for write in 3...6 {
        _ = try store.update(memoryId: "bounded-memory", recordId: automaticRecord.recordId,
          workflowId: "mock-workflow", payload: .string("runner-write-\(write)"))
      }
      XCTAssertEqual(try store.evolutionHistory(memoryId: "bounded-memory", recordId: automaticRecord.recordId).map(\.version), [5, 4, 3])
    }
  }

  private func authoredWorkflow(retention: Int) -> AuthoredWorkflowJSON {
    AuthoredWorkflowJSON(
      workflowId: "memory-retention-validation",
      defaults: WorkflowDefaults(nodeTimeoutMs: 30_000, maxLoopIterations: 3),
      memories: [WorkflowMemoryDeclaration(id: "bounded-memory", historyRetention: retention)],
      entryStepId: "step",
      nodes: [WorkflowNodeRegistryRef(id: "step", nodeFile: "nodes/step.json")]
    )
  }

  private func temporaryRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("tmp/workflow-memory-retention-\(UUID().uuidString)")
  }
}

private actor RetentionWritingAddonResolver: WorkflowAddonResolving {
  private let root: URL
  private var writtenRecordId: Int64?

  init(root: URL) { self.root = root }

  func execute(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    let store = RielaMemoryStore(rootDirectory: root.path)
    let retention = input.memoryHistoryRetentions?["bounded-memory"]
    let record = try store.save(memoryId: "bounded-memory", workflowId: input.workflowId, payload: .string("write-1"),
      historyRetention: retention)
    for write in 2...5 {
      _ = try store.update(memoryId: "bounded-memory", recordId: record.recordId, workflowId: input.workflowId,
        payload: .string("write-\(write)"), historyRetention: retention)
    }
    writtenRecordId = record.recordId
    return AdapterExecutionOutput(provider: "test", model: "test", promptText: "", completionPassed: true, payload: [:])
  }

  func recordId() -> Int64? { writtenRecordId }
}

private struct RetentionInputResolver: WorkflowMessageInputResolving {
  func resolveInput(for sessionId: String, stepId: String, store: any WorkflowRuntimeStore) async throws -> WorkflowResolvedMessageInput {
    WorkflowResolvedMessageInput(workflowExecutionId: sessionId, stepId: stepId, messages: [], payload: [:],
      communicationIds: [], sourceStepIds: [])
  }
}
