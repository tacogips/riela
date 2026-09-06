#if os(macOS)
import RielaCore
@testable import RielaAppSupport
import RielaKaibaSupport
import XCTest

final class RielaAppKaibaBindingControllerTests: XCTestCase {
  func testRowsResolveAuthoredPatchDefaultDisabledAndMissingBindings() {
    let defaultInstance = instance(id: "00000000-0000-0000-0000-000000000001", name: "Default", isDefault: true)
    let disabled = instance(id: "00000000-0000-0000-0000-000000000002", name: "Disabled", enabled: false)
    let preference = RielaAppDaemonWorkflowPreference(
      identity: "workflow",
      nodePatches: [
        "default": .init(clearsKaibaInstanceId: true),
        "disabled": .init(kaibaInstanceId: disabled.id),
        "missing": .init(kaibaInstanceId: "missing")
      ]
    )

    let rows = RielaAppKaibaBindingController.rows(
      workflow: workflow(), preference: preference, instances: [defaultInstance, disabled]
    )

    XCTAssertEqual(rows.map(\.nodeID), ["authored", "default", "disabled", "missing", "memory"])
    XCTAssertEqual(rows[0].effectiveInstanceID, defaultInstance.id)
    XCTAssertTrue(rows[0].usesAuthoredBinding)
    XCTAssertEqual(rows[1].effectiveInstanceID, nil)
    XCTAssertEqual(rows[1].detail, "Uses default instance Default.")
    XCTAssertEqual(rows[2].detail, "Unavailable: Disabled is disabled. Select an enabled instance.")
    XCTAssertEqual(rows[3].detail, "Unavailable: configured instance missing is missing. Select an enabled instance.")
    XCTAssertEqual(rows[0].choices.map(\.availability), [.default, .enabled, .disabled])
    XCTAssertEqual(rows[2].choices.last?.isEnabled, false)
    XCTAssertEqual(rows[3].choices.last, .init(
      instanceID: "missing",
      title: "Missing instance: missing",
      isEnabled: false,
      availability: .missing
    ))
  }

  func testBindingRequestsPreserveDefaultResetAndLongTermMemoryRequirement() {
    let preference = RielaAppDaemonWorkflowPreference(
      identity: "workflow",
      nodePatches: [
        "default": .init(clearsKaibaInstanceId: true),
        "missing": .init(kaibaInstanceId: "missing")
      ]
    )

    let requests = RielaAppKaibaBindingController.bindingRequests(workflow: workflow(), preference: preference)

    XCTAssertEqual(requests.map(\.instanceID), ["00000000-0000-0000-0000-000000000001", nil, nil, "missing", nil])
    XCTAssertFalse(requests[0].requiresLongTermMemory)
    XCTAssertTrue(requests[4].requiresLongTermMemory)
  }

  func testStartApprovalRejectsPreferenceCandidateAndCatalogChanges() {
    let catalog = KaibaInstanceCatalog(instances: [instance(
      id: "00000000-0000-0000-0000-000000000001",
      name: "Default",
      isDefault: true
    )])
    let preference = RielaAppDaemonWorkflowPreference(identity: "workflow")
    let candidate = RielaAppDaemonWorkflowCandidate(
      id: "workflow",
      workflowId: "workflow",
      displayName: "Workflow",
      sourceDescription: "test",
      workflowDirectory: "/tmp/workflow",
      workingDirectory: "/tmp",
      eventRoot: nil,
      eventSources: []
    )
    let approval = RielaAppKaibaStartApproval(
      preference: preference,
      candidate: candidate,
      catalog: catalog
    )

    XCTAssertTrue(approval.matches(preference: preference, candidate: candidate, catalog: catalog))
    XCTAssertFalse(approval.matches(
      preference: .init(identity: "workflow", environmentVariables: ["KAIBA_TOKEN": "changed"]),
      candidate: candidate,
      catalog: catalog
    ))
    XCTAssertFalse(approval.matches(
      preference: preference,
      candidate: candidate.managedInstance(identity: "changed"),
      catalog: catalog
    ))
    XCTAssertFalse(approval.matches(
      preference: preference,
      candidate: candidate,
      catalog: KaibaInstanceCatalog()
    ))
  }

  private func instance(id: String, name: String, enabled: Bool = true, isDefault: Bool = false) -> KaibaInstance {
    KaibaInstance(
      id: id,
      name: name,
      endpoint: "https://kaiba.example.test",
      authentication: .unauthenticated,
      enabled: enabled,
      isDefault: isDefault
    )
  }

  private func workflow() -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "bindings",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 3),
      entryStepId: "authored",
      nodeRegistry: [
        .init(id: "authored"), .init(id: "default"), .init(id: "disabled"), .init(id: "missing"), .init(id: "memory")
      ],
      steps: [
        .init(id: "authored", nodeId: "authored"), .init(id: "default", nodeId: "default"),
        .init(id: "disabled", nodeId: "disabled"), .init(id: "missing", nodeId: "missing"), .init(id: "memory", nodeId: "memory")
      ],
      nodes: [
        .init(id: "authored", addon: .init(name: "kaiba/note-search", config: ["kaibaInstanceId": .string("00000000-0000-0000-0000-000000000001")])),
        .init(id: "default", addon: .init(name: "kaiba/note-search")),
        .init(id: "disabled", addon: .init(name: "kaiba/note-search")),
        .init(id: "missing", addon: .init(name: "kaiba/note-search")),
        .init(id: "memory", addon: .init(name: "kaiba/memory-recall"))
      ]
    )
  }
}
#endif
