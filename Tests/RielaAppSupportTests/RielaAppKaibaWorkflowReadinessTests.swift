#if os(macOS)
import Foundation
import RielaCore
@testable import RielaAppSupport
@testable import RielaKaibaSupport
import XCTest

final class RielaAppKaibaWorkflowReadinessTests: XCTestCase {
  func testWorkflowEffectiveEnvironmentDoesNotInheritProcessCredential() async {
    let name = "RIELA_APP_KAIBA_PROCESS_ONLY_TOKEN"
    setenv(name, "process-only-secret", 1)
    defer { unsetenv(name) }
    let instance = KaibaInstance(
      name: "Credentialed",
      endpoint: "https://kaiba.example.test",
      authentication: .bearer(environmentVariable: name),
      isDefault: true
    )

    let result = await RielaAppKaibaWorkflowReadiness.evaluate(
      workflow: kaibaWorkflow(),
      preference: RielaAppDaemonWorkflowPreference(identity: "kaiba-readiness"),
      catalog: KaibaInstanceCatalog(instances: [instance]),
      environment: [:]
    )

    XCTAssertEqual(result, .blocked(.configureWorkflowEnvironment))
    XCTAssertFalse(result.statusText?.contains("process-only-secret") == true)
  }

  func testLegacyConnectionMismatchBlocksBeforeAppReadinessTransport() async {
    let instance = KaibaInstance(
      name: "Configured instance",
      endpoint: "https://kaiba.example.test/graphql",
      authentication: .unauthenticated,
      isDefault: true,
      allowRemoteUnauthenticated: true
    )
    let workflow = WorkflowDefinition(
      workflowId: "legacy-mismatch",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "search",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "search")],
      steps: [WorkflowStepRef(id: "search", nodeId: "search")],
      nodes: [WorkflowNodeRef(
        id: "search",
        addon: WorkflowNodeAddonRef(
          name: "kaiba/note-search",
          config: ["endpoint": .string("https://untrusted.example.test/graphql")]
        )
      )]
    )

    let result = await RielaAppKaibaWorkflowReadiness.evaluate(
      workflow: workflow,
      preference: RielaAppDaemonWorkflowPreference(identity: "legacy-mismatch"),
      catalog: KaibaInstanceCatalog(instances: [instance]),
      environment: [:]
    )

    XCTAssertEqual(result, .blocked(.repairLegacyConnectionConfiguration))
    XCTAssertFalse(result.isStartAllowed)
    XCTAssertEqual(
      result.statusText,
      "Kaiba is not ready. Bind the intended named instance and remove legacy fields."
    )
    XCTAssertFalse(result.statusText?.contains("untrusted.example.test") == true)
  }

  private func kaibaWorkflow() -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "kaiba-readiness",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 3),
      entryStepId: "search",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "search")],
      steps: [WorkflowStepRef(id: "search", nodeId: "search")],
      nodes: [WorkflowNodeRef(id: "search", addon: WorkflowNodeAddonRef(name: "kaiba/note-search"))]
    )
  }
}
#endif
