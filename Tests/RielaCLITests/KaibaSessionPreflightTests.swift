import Foundation
import RielaCore
import RielaKaibaAddons
import RielaKaibaSupport
import XCTest
@testable import RielaCLI

final class KaibaSessionPreflightTests: XCTestCase {
  func testSessionPreflightProjectsBindingAndFailsClosedBeforeDispatch() async throws {
    let home = try makeRielaCLITestTemporaryDirectory("kaiba-session-preflight")
    defer { try? FileManager.default.removeItem(at: home) }
    var bundle = fixtureBundle()
    let instance = EffectiveWorkflowInstance(
      identity: "test",
      kind: .ephemeral,
      configuration: WorkflowInstanceConfiguration(
        nodePatches: ["kaiba-node": .init(kaibaInstanceId: "missing-instance")]
      )
    )

    do {
      _ = try await prepareSessionKaibaPreflight(
        bundle: &bundle,
        instance: instance,
        workingDirectory: home.path,
        mockScenarioPath: nil,
        calleeResolver: EmptyCalleeResolver(),
        baseEnvironment: ["HOME": home.path]
      )
      XCTFail("expected the projected missing binding to fail before session dispatch")
    } catch {
      let message = (error as? CLIUsageError)?.message
        ?? CLIUsageError.kaibaPreflight(error)?.message
        ?? String(describing: error)
      XCTAssertEqual(
        message,
        "kaiba preflight failed: unknown_kaiba_instance. Select an existing named Kaiba instance."
      )
    }
  }

  func testMockSessionScopeIsTheOnlyNilSnapshotCompatibilityPath() async throws {
    let context = SessionKaibaPreflightContext(
      workingDirectory: FileManager.default.currentDirectoryPath,
      environment: [:],
      snapshot: nil
    )
    let client = try await withSessionKaibaSnapshot(context, mockScenarioPath: "fixture.json") {
      try KaibaAddonExecutionContext.resolvedClient(for: WorkflowAddonExecutionInput(
        workflowId: "session-test",
        stepId: "step",
        nodeId: "node",
        addon: WorkflowNodeAddonRef(name: "kaiba/note-search")
      ))
    }
    XCTAssertNil(client)
  }

  func testSessionSnapshotScopePropagatesResolvedClient() async throws {
    let instance = KaibaInstance(
      id: "11111111-1111-4111-8111-111111111111",
      name: "Session Instance",
      endpoint: "http://127.0.0.1:8080/graphql",
      authentication: .unauthenticated,
      isDefault: true,
      allowInsecureHTTP: true
    )
    let snapshot = try KaibaExecutionSnapshot(
      requests: [.init(instanceID: instance.id)],
      catalog: KaibaInstanceCatalog(instances: [instance]),
      environment: [:]
    )
    let context = SessionKaibaPreflightContext(
      workingDirectory: FileManager.default.currentDirectoryPath,
      environment: [:],
      snapshot: snapshot
    )

    let client = try await withSessionKaibaSnapshot(context, mockScenarioPath: nil) {
      try KaibaAddonExecutionContext.resolvedClient(for: WorkflowAddonExecutionInput(
        workflowId: "session-test",
        stepId: "step",
        nodeId: "node",
        addon: WorkflowNodeAddonRef(name: "kaiba/note-search")
      ))
    }
    XCTAssertEqual(client?.instance.id, instance.id)
  }

  private func fixtureBundle() -> ResolvedWorkflowBundle {
    let workflow = WorkflowDefinition(
      workflowId: "session-test",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "start",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "kaiba-node", nodeFile: "nodes/kaiba.json")],
      steps: [WorkflowStepRef(id: "start", nodeId: "kaiba-node")],
      nodes: [WorkflowNodeRef(
        id: "kaiba-node",
        addon: WorkflowNodeAddonRef(name: "kaiba/note-search")
      )]
    )
    return ResolvedWorkflowBundle(
      workflow: workflow,
      nodePayloads: [:],
      sourceScope: .project,
      workflowDirectory: FileManager.default.currentDirectoryPath
    )
  }
}

private struct EmptyCalleeResolver: WorkflowCalleeResolving {
  func resolveCallee(workflowId: String) async throws -> ResolvedWorkflowCallee {
    throw AdapterExecutionError(.invalidInput, "unexpected callee")
  }
}
