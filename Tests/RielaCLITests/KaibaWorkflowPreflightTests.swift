import Foundation
import RielaCore
import RielaKaibaSupport
import XCTest
@testable import RielaCLI

final class KaibaWorkflowPreflightTests: XCTestCase {
  func testWorkflowKaibaBindingFailsClosedBeforeSchedulingWithoutDefaultInstance() async throws {
    let home = try makeRielaCLITestTemporaryDirectory("kaiba-workflow-preflight")
    defer { try? FileManager.default.removeItem(at: home) }
    let node = WorkflowNodeRef(
      id: "search",
      addon: WorkflowNodeAddonRef(name: "kaiba/note-search")
    )

    do {
      _ = try await KaibaExecutionPreflight.workflow(nodes: [node], environment: ["HOME": home.path])
      XCTFail("expected a missing default instance failure")
    } catch {
      let usage = CLIUsageError.kaibaPreflight(error)
      XCTAssertEqual(
        usage?.message,
        "kaiba preflight failed: missing_kaiba_instance. Configure a default named Kaiba instance."
      )
    }
  }

  func testCalleeKaibaBindingFailsClosedBeforeCallerScheduling() async throws {
    let home = try makeRielaCLITestTemporaryDirectory("kaiba-callee-preflight")
    defer { try? FileManager.default.removeItem(at: home) }
    let caller = WorkflowDefinition(
      workflowId: "caller",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "dispatch",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "dispatch-node", nodeFile: "nodes/dispatch.json")],
      steps: [WorkflowStepRef(
        id: "dispatch",
        nodeId: "dispatch-node",
        transitions: [WorkflowStepTransition(
          toStepId: "callee-entry",
          toWorkflowId: "callee",
          resumeStepId: "dispatch"
        )]
      )],
      nodes: [WorkflowNodeRef(id: "dispatch-node", nodeFile: "nodes/dispatch.json")]
    )
    let callee = ResolvedWorkflowCallee(
      workflow: WorkflowDefinition(
        workflowId: "callee",
        defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
        entryStepId: "callee-entry",
        nodeRegistry: [WorkflowNodeRegistryRef(id: "kaiba-node", nodeFile: "nodes/kaiba.json")],
        steps: [WorkflowStepRef(id: "callee-entry", nodeId: "kaiba-node")],
        nodes: [WorkflowNodeRef(
          id: "kaiba-node",
          addon: WorkflowNodeAddonRef(name: "kaiba/note-search")
        )]
      )
    )

    do {
      _ = try await KaibaExecutionPreflight.workflow(
        nodes: caller.nodes,
        environment: ["HOME": home.path],
        workflow: caller,
        calleeResolver: StaticCalleeResolver(callee: callee)
      )
      XCTFail("expected the callee binding to fail before the caller schedules")
    } catch {
      XCTAssertEqual(
        CLIUsageError.kaibaPreflight(error)?.message,
        "kaiba preflight failed: missing_kaiba_instance. Configure a default named Kaiba instance."
      )
    }
  }

  func testLegacyConnectionMismatchFailsBeforeCLIReadiness() async throws {
    let home = try makeRielaCLITestTemporaryDirectory("kaiba-legacy-preflight")
    defer { try? FileManager.default.removeItem(at: home) }
    let instance = KaibaInstance(
      name: "Configured instance",
      endpoint: "http://127.0.0.1:8787/graphql",
      authentication: .unauthenticated,
      isDefault: true,
      allowInsecureHTTP: true
    )
    try KaibaInstanceStore(homeURL: home).save(.init(instances: [instance]))
    let node = WorkflowNodeRef(
      id: "search",
      addon: WorkflowNodeAddonRef(
        name: "kaiba/note-search",
        config: ["endpoint": .string("https://untrusted.example.test/graphql")]
      )
    )

    do {
      _ = try await KaibaExecutionPreflight.workflow(
        nodes: [node],
        environment: ["HOME": home.path]
      )
      XCTFail("expected legacy connection mismatch before readiness")
    } catch {
      XCTAssertEqual(
        CLIUsageError.kaibaPreflight(error)?.message,
        "kaiba preflight failed: legacy_kaiba_connection_mismatch. Bind the intended named instance and remove legacy fields."
      )
    }
  }
}

private struct StaticCalleeResolver: WorkflowCalleeResolving {
  let callee: ResolvedWorkflowCallee

  func resolveCallee(workflowId: String) async throws -> ResolvedWorkflowCallee {
    guard workflowId == callee.workflow.workflowId else {
      throw AdapterExecutionError(.invalidInput, "unexpected callee")
    }
    return callee
  }
}
