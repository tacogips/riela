import Foundation
import XCTest
@testable import RielaCore

final class WorkflowPreservedHistoryTests: XCTestCase {
  private var workflow: WorkflowDefinition {
    let ids = ["first", "second", "final"]
    return WorkflowDefinition(workflowId: "history", defaults: WorkflowDefaults(nodeTimeoutMs: 120000, maxLoopIterations: 2),
      entryStepId: "first", nodeRegistry: ids.map { WorkflowNodeRegistryRef(id: $0, nodeFile: "\($0).json") },
      steps: ids.enumerated().map { index, id in WorkflowStepRef(id: id, nodeId: id,
        transitions: index < 2 ? [WorkflowStepTransition(toStepId: ids[index + 1])] : nil) },
      nodes: ids.map { WorkflowNodeRef(id: $0, nodeFile: "\($0).json") })
  }
  private var nodes: [String: AgentNodePayload] {
    Dictionary(uniqueKeysWithValues: ["first", "second", "final"].map { id in
      (id, AgentNodePayload(id: id, model: "fixture", output: NodeOutputContract(
        jsonSchema: ["type": .string("object"), "required": .array([.string("answer")])], maxValidationAttempts: 2)))
    })
  }
  private func failedSource(_ store: InMemoryWorkflowRuntimeStore) async throws -> WorkflowSession {
    do {
      _ = try await DeterministicWorkflowRunner(store: store, adapter: HistoryAdapter(failFinal: true)).run(
        DeterministicWorkflowRunRequest(workflow: workflow, nodePayloads: nodes))
      XCTFail("expected failure")
    } catch {}
    let source = await store.latestSession(workflowId: "history")
    return try XCTUnwrap(source)
  }

  func testRecoveryImportsPrefixWithoutBackendCallsAndPersistsLineage() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let source = try await failedSource(store)
    XCTAssertEqual(source.executions.filter { $0.stepId == "final" }.count, 2)
    let adapter = HistoryAdapter(failFinal: false)
    var repaired = nodes
    repaired["final"]?.promptTemplate = "Repaired target prompt"
    let result = try await DeterministicWorkflowRunner(store: store, adapter: adapter).run(
      DeterministicWorkflowRunRequest(workflow: workflow, nodePayloads: repaired,
        rerunFromSessionId: source.sessionId, rerunFromStepId: "final", preserveHistory: true))
    let calls = await adapter.inputs
    XCTAssertEqual(calls.map { $0.node.id }, ["final"])
    let originalFinal = try XCTUnwrap(source.executions.first { $0.stepId == "final" })
    guard case let .object(originalVariables)? = originalFinal.inputSnapshot?["mergedVariables"],
          case let .object(originalInbox)? = originalVariables["_rielaInput"],
          case let .object(newInbox)? = calls.first?.mergedVariables["_rielaInput"],
          case let .object(originalLatest)? = originalInbox["latest"],
          case let .object(newLatest)? = newInbox["latest"] else { return XCTFail("missing inbox") }
    XCTAssertEqual(originalLatest["payload"], newLatest["payload"])
    XCTAssertNotEqual(originalInbox["workflowExecutionId"], newInbox["workflowExecutionId"])
    XCTAssertEqual(result.nodeExecutions, 1)
    XCTAssertEqual(result.session.executions.count, 3)
    XCTAssertEqual(result.session.executions.filter { $0.importedFrom != nil }.count, 2)
    let unchanged = try await store.loadSession(id: source.sessionId)
    XCTAssertEqual(unchanged, source)
    let messages = try await store.listMessages(for: result.session.sessionId, toStepId: nil)
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/history-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    try persistence.save(WorkflowRuntimePersistenceSnapshot(session: result.session, workflowMessages: messages))
    let loaded = try XCTUnwrap(persistence.load(sessionId: result.session.sessionId))
    XCTAssertEqual(loaded.session.executions.map(\.importedFrom), result.session.executions.map(\.importedFrom))
    XCTAssertEqual(loaded.session.newExecutionCount, 1)
    XCTAssertTrue(loaded.session.executions.filter { $0.importedFrom != nil }.allSatisfy {
      $0.usage == nil && $0.backendEventCount == nil && $0.backend == nil && $0.acceptedOutput?.runtimeFinalizationToken == nil
    })
    XCTAssertEqual(loaded.workflowMessages.count, messages.count)
    for (restored, original) in zip(loaded.workflowMessages, messages) {
      XCTAssertEqual(restored.createdAt.timeIntervalSince1970, original.createdAt.timeIntervalSince1970, accuracy: 0.001)
      var normalized = original
      normalized.createdAt = restored.createdAt
      XCTAssertEqual(restored, normalized)
    }
  }

  func testRecoveryOfFailedRecoveryKeepsPrefixAndRunsOnlyTarget() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let source = try await failedSource(store)
    do {
      _ = try await DeterministicWorkflowRunner(store: store, adapter: HistoryAdapter(failFinal: true)).run(
        DeterministicWorkflowRunRequest(workflow: workflow, nodePayloads: nodes,
          rerunFromSessionId: source.sessionId, rerunFromStepId: "final", preserveHistory: true))
      XCTFail("expected failed recovery")
    } catch {}
    let secondValue = await store.latestSession(workflowId: "history")
    let second = try XCTUnwrap(secondValue)
    let adapter = HistoryAdapter(failFinal: false)
    let third = try await DeterministicWorkflowRunner(store: store, adapter: adapter).run(
      DeterministicWorkflowRunRequest(workflow: workflow, nodePayloads: nodes,
        rerunFromSessionId: second.sessionId, rerunFromStepId: "final", preserveHistory: true))
    XCTAssertEqual(third.session.executions.first?.importedFrom?.sessionId, second.sessionId)
    XCTAssertEqual(third.session.rootSessionId, source.sessionId)
    XCTAssertEqual(third.nodeExecutions, 1)
    let calls = await adapter.inputs
    XCTAssertEqual(calls.count, 1)
  }

  func testPublicImportRejectsTamperedExecutionIdentityAndInput() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let source = try await failedSource(store)
    for mode in ["step", "input"] {
      var candidate = try XCTUnwrap(source.executions.first)
      if mode == "step" { candidate.stepId = "forged" }
      else { candidate.inputSnapshot = ["forged": .bool(true)] }
      let destination = try await store.createSession(WorkflowSessionCreateInput(workflowId: "history", entryStepId: "final"))
      do {
        _ = try await store.importAcceptedHistory(WorkflowHistoryImportInput(
          sessionId: destination.sessionId, sourceSessionId: source.sessionId,
          executions: [candidate], messages: []))
        XCTFail("must reject tampered \(mode)")
      } catch {
        XCTAssertTrue(String(describing: error).contains("metadata differs from canonical source"), String(describing: error))
      }
      let unchanged = try await store.loadSession(id: destination.sessionId)
      XCTAssertEqual(unchanged, destination)
    }
  }

  func testPublicImportRejectsDuplicateCommunicationsWithoutMutation() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let source = try await failedSource(store)
    let messages = try await store.listMessages(for: source.sessionId, toStepId: nil)
    let message = try XCTUnwrap(messages.first)
    let destination = try await store.createSession(WorkflowSessionCreateInput(workflowId: "history", entryStepId: "final"))
    do {
      _ = try await store.importAcceptedHistory(WorkflowHistoryImportInput(sessionId: destination.sessionId,
        sourceSessionId: source.sessionId, executions: source.executions.filter { $0.status == .completed },
        messages: [message, message]))
      XCTFail("duplicate source communications must be rejected")
    } catch {}
    let unchanged = try await store.loadSession(id: destination.sessionId)
    let unchangedMessages = try await store.listMessages(for: destination.sessionId, toStepId: nil)
    XCTAssertEqual(unchanged, destination)
    XCTAssertTrue(unchangedMessages.isEmpty)
  }

  func testPreservationRejectsResumeEntryBeforeAdapterInvocation() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let source = try await failedSource(store)
    let adapter = HistoryAdapter(failFinal: false)
    do {
      _ = try await DeterministicWorkflowRunner(store: store, adapter: adapter).run(
        DeterministicWorkflowRunRequest(workflow: workflow, nodePayloads: nodes,
          rerunFromSessionId: source.sessionId, rerunFromStepId: "final", preserveHistory: true,
          resumeSessionId: source.sessionId))
      XCTFail("mixed entry modes must reject")
    } catch {
      XCTAssertTrue(String(describing: error).contains("cannot be combined with resumeSessionId"))
    }
    let inputs = await adapter.inputs
    XCTAssertTrue(inputs.isEmpty)
    let unchanged = try await store.loadSession(id: source.sessionId)
    XCTAssertEqual(unchanged, source)
  }

  func testRejectsMissingEvidenceChangedPrefixAndIncompleteMessages() async throws {
    for mode in ["evidence", "prefix", "messages", "ambiguous", "target-input", "running", "payload"] {
      let store = InMemoryWorkflowRuntimeStore()
      var source = try await failedSource(store)
      var changed = nodes
      switch mode {
      case "evidence": source.executions[0].inputSnapshot = nil
      case "prefix": changed["first"]?.promptTemplate = "changed"
      case "messages": break
      case "target-input": changed["final"]?.input = NodeInputContract(description: "changed contract")
      case "running": source.executions[0].status = .running
      case "payload": await store.changeHistoryMessageForTest(source.sessionId)
      default: source.executions.insert(source.executions[0], at: 1)
      }
      await store.seedSession(source)
      if mode == "messages" { await store.removeHistoryMessagesForTest(source.sessionId) }
      do {
        _ = try await DeterministicWorkflowRunner(store: store, adapter: HistoryAdapter(failFinal: false)).run(
          DeterministicWorkflowRunRequest(workflow: workflow, nodePayloads: changed,
            rerunFromSessionId: source.sessionId, rerunFromStepId: "final", preserveHistory: true))
        XCTFail("must reject \(mode)")
      } catch { XCTAssertTrue(String(describing: error).contains("cannot preserve history")) }
    }
  }
}

private actor HistoryAdapter: NodeAdapter {
  let failFinal: Bool
  var inputs: [AdapterExecutionInput] = []
  init(failFinal: Bool) { self.failFinal = failFinal }
  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    inputs.append(input)
    return AdapterExecutionOutput(provider: "deterministic-test", model: "fixture", promptText: input.promptText,
      completionPassed: true, payload: failFinal && input.node.id == "final" ? [:] : ["answer": .string(input.node.id)])
  }
}

private extension InMemoryWorkflowRuntimeStore {
  func removeHistoryMessagesForTest(_ sessionId: String) { messagesBySession[sessionId] = [] }
  func changeHistoryMessageForTest(_ sessionId: String) { messagesBySession[sessionId]?[0].payload = ["changed": .bool(true)] }
}
