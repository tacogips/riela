import Foundation
import RielaCore
import XCTest
@testable import RielaWork

final class BackendCapabilityPlacementTests: XCTestCase {
  func testPlacementPrefersLocalAndHonorsExplicitWorkerWithoutFallback() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let provenance = WorkflowRequirementProvenance(workflowId: "flow", stepId: "step", nodeId: "node")
    let requirement = WorkflowBackendRequirement(
      policy: WorkflowBackendPolicy(
        allowed: [.claudeCodeAgent, .codexAgent],
        preferred: [.codexAgent]
      ),
      provenance: [provenance]
    )
    let local = host("local", backend: .codexAgent, now: now)
    let worker = host("worker-b", backend: .claudeCodeAgent, groups: ["gpu"], capacity: 1, now: now)
    let resolver = BackendCapabilityPlacementResolver(maximumAge: 60)

    let localResult = resolver.resolve(requirements: [requirement], local: local, workers: [worker], now: now)
    XCTAssertEqual(localResult.choices.first?.hostId, "local")
    XCTAssertEqual(localResult.choices.first?.backend, .codexAgent)

    let assigned = resolver.resolve(
      requirements: [requirement],
      local: local,
      workers: [worker],
      assignments: [provenance: DistributedWorkerTarget(group: "gpu")],
      now: now
    )
    XCTAssertEqual(assigned.choices.first?.hostId, "worker-b")
    XCTAssertEqual(assigned.choices.first?.backend, .claudeCodeAgent)
  }

  func testSequentialWorkflowNodesShareOneWorkerCapacityAdmission() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let first = WorkflowRequirementProvenance(workflowId: "flow", stepId: "first", nodeId: "first")
    let second = WorkflowRequirementProvenance(workflowId: "flow", stepId: "second", nodeId: "second")
    let requirements = [
      WorkflowBackendRequirement(pin: .codexAgent, provenance: [first]),
      WorkflowBackendRequirement(pin: .claudeCodeAgent, provenance: [second])
    ]
    let worker = HostCapabilitySnapshot(
      hostId: "worker-a",
      groups: ["builders"],
      capacity: 1,
      backends: [capability(.codexAgent, now: now), capability(.claudeCodeAgent, now: now)],
      refreshedAt: now
    )

    let result = BackendCapabilityPlacementResolver(maximumAge: 60).resolve(
      requirements: requirements,
      local: HostCapabilitySnapshot(hostId: "local", backends: [], refreshedAt: now),
      workers: [worker],
      assignments: [
        first: DistributedWorkerTarget(workerId: "worker-a"),
        second: DistributedWorkerTarget(workerId: "worker-a")
      ],
      now: now
    )

    XCTAssertTrue(result.complete)
    XCTAssertEqual(result.choices.map(\.provenance), [first, second])
    XCTAssertEqual(result.choices.map(\.hostId), ["worker-a", "worker-a"])
    XCTAssertTrue(result.failures.isEmpty)
  }

  func testDuplicateWorkerIdentitiesCannotPlaceOrCollideWithLocal() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let provenance = WorkflowRequirementProvenance(workflowId: "flow", stepId: "step", nodeId: "node")
    let requirement = WorkflowBackendRequirement(pin: .codexAgent, provenance: [provenance])
    let local = HostCapabilitySnapshot(hostId: "local", backends: [], refreshedAt: now)
    let collision = host("local", backend: .codexAgent, capacity: 1, now: now)
    let duplicate = host("worker-a", backend: .codexAgent, capacity: 1, now: now)

    for workers in [[collision], [duplicate, duplicate]] {
      let result = BackendCapabilityPlacementResolver().resolve(
        requirements: [requirement],
        local: local,
        workers: workers,
        now: now
      )
      XCTAssertFalse(result.complete)
      XCTAssertTrue(result.choices.isEmpty)
    }
  }

  func testDeclarationMergeAndFreshnessFailClosedWithoutLosingFailedAuthEvidence() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let observed = BackendCapability(
      backend: .codexAgent,
      source: .observed,
      observedAt: now.addingTimeInterval(-60),
      availability: .available,
      authentication: .failed,
      failures: ["authentication probe failed"]
    )
    let enabled = BackendCapabilityMerger.merge(
      observations: [observed],
      declarations: [.codexAgent: .init(enabled: true)]
    )
    XCTAssertEqual(enabled.first?.source, .merged)
    XCTAssertEqual(enabled.first?.authentication, .failed)
    XCTAssertTrue(enabled.first?.failures.contains("authentication probe failed") == true)

    let requirement = WorkflowBackendRequirement(
      pin: .codexAgent,
      provenance: [.init(workflowId: "flow", stepId: "step", nodeId: "node")]
    )
    let declaredHost = HostCapabilitySnapshot(
      hostId: "local",
      backends: enabled,
      refreshedAt: now
    )
    XCTAssertTrue(BackendCapabilityPlacementResolver(maximumAge: 30).resolve(
      requirements: [requirement], local: declaredHost, workers: [], now: now
    ).complete)

    let observedHost = HostCapabilitySnapshot(hostId: "local", backends: [observed], refreshedAt: now)
    XCTAssertFalse(BackendCapabilityPlacementResolver(maximumAge: 30).resolve(
      requirements: [requirement], local: observedHost, workers: [], now: now
    ).complete)

    let disabled = BackendCapabilityMerger.merge(
      observations: [observed],
      declarations: [.codexAgent: .init(enabled: false)]
    )
    let disabledHost = HostCapabilitySnapshot(hostId: "local", backends: disabled, refreshedAt: now)
    XCTAssertFalse(BackendCapabilityPlacementResolver(maximumAge: 30).resolve(
      requirements: [requirement], local: disabledHost, workers: [], now: now
    ).complete, "A disabled declaration must win over an observed availability")
  }

  func testBackendEnvironmentEvidenceRequiresFreshHostFacts() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let provenance = WorkflowRequirementProvenance(workflowId: "flow", stepId: "step", nodeId: "node")
    let requirement = WorkflowBackendRequirement(
      pin: .codexAgent,
      provenance: [provenance]
    )
    let explicitlyEnabled = BackendCapability(
      backend: .codexAgent,
      source: .merged,
      observedAt: now,
      availability: .available,
      requiredEnvironment: ["CODEX_TOKEN": true]
    )
    let staleHost = HostCapabilitySnapshot(
      hostId: "worker",
      backends: [explicitlyEnabled],
      environment: ["CODEX_TOKEN": true],
      capabilitiesObservedAt: now.addingTimeInterval(-60),
      refreshedAt: now
    )

    let result = BackendCapabilityPlacementResolver(maximumAge: 60).resolve(
      requirements: [requirement], local: staleHost, workers: [], now: now
    )

    XCTAssertFalse(result.complete, "Backend credential checks cannot reuse stale host environment facts")
  }

  func testFutureBackendObservationIsNotFreshOrPlaceable() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let provenance = WorkflowRequirementProvenance(workflowId: "flow", stepId: "step", nodeId: "node")
    let futureObservation = capability(.codexAgent, now: now.addingTimeInterval(1))
    let host = HostCapabilitySnapshot(
      hostId: "local",
      backends: [futureObservation],
      refreshedAt: now
    )

    XCTAssertFalse(futureObservation.isFresh(at: now, maximumAge: 60))
    XCTAssertFalse(BackendCapabilityPlacementResolver(maximumAge: 60).resolve(
      requirements: [WorkflowBackendRequirement(pin: .codexAgent, provenance: [provenance])],
      local: host,
      workers: [],
      now: now
    ).complete, "A future-dated probe must not be usable for placement")
  }

  func testHostSnapshotPersistsAndLoadsInStableOrder() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkStore(rootDirectory: root.path)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    try store.saveHostSnapshot(host("worker-b", backend: .codexAgent, capacity: 1, now: now))
    try store.saveHostSnapshot(host("local", backend: .claudeCodeAgent, now: now))
    XCTAssertEqual(try store.loadHostSnapshots().map(\.hostId), ["local", "worker-b"])
  }

  func testPlacementDoesNotWaiveEnvironmentOrAddonExecutableRequirements() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let requirement = WorkflowBackendRequirement(
      pin: .codexAgent,
      addonExecutable: "tool-cli",
      requiredEnvironment: ["TOOL_TOKEN"],
      provenance: [.init(workflowId: "flow", stepId: "step", nodeId: "node")]
    )
    let missing = host("local", backend: .codexAgent, now: now)
    let resolver = BackendCapabilityPlacementResolver(maximumAge: 60)
    XCTAssertFalse(resolver.resolve(
      requirements: [requirement], local: missing, workers: [], now: now
    ).complete)

    var configured = missing
    configured.environment = ["TOOL_TOKEN": true]
    configured.addonExecutables = ["tool-cli": true]
    XCTAssertTrue(resolver.resolve(
      requirements: [requirement], local: configured, workers: [], now: now
    ).complete)

    let probeFailure = BackendCapability(
      backend: .codexAgent,
      source: .merged,
      observedAt: now,
      availability: .available,
      requiredEnvironment: ["CODEX_TOKEN": false],
      executableAvailable: false
    )
    let explicitlyEnabled = HostCapabilitySnapshot(
      hostId: "local",
      backends: [probeFailure],
      addonExecutables: ["tool-cli": true],
      environment: ["TOOL_TOKEN": true],
      refreshedAt: now
    )
    XCTAssertFalse(resolver.resolve(
      requirements: [requirement], local: explicitlyEnabled, workers: [], now: now
    ).complete, "Explicit enable must not waive failed probe requirements")

    let partiallyConfiguredProbe = BackendCapability(
      backend: .codexAgent,
      source: .merged,
      observedAt: now,
      availability: .available,
      requiredEnvironment: ["CODEX_TOKEN": true, "CODEX_HOME": false]
    )
    let partiallyConfiguredHost = HostCapabilitySnapshot(
      hostId: "local",
      backends: [partiallyConfiguredProbe],
      addonExecutables: ["tool-cli": true],
      environment: ["TOOL_TOKEN": true],
      refreshedAt: now
    )
    XCTAssertFalse(resolver.resolve(
      requirements: [requirement], local: partiallyConfiguredHost, workers: [], now: now
    ).complete, "Every backend probe environment requirement must be present")
  }

  func testPlacementRejectsExplicitModelWhenCapabilityListIsKnownEmpty() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let requirement = WorkflowBackendRequirement(
      pin: .codexAgent,
      explicitModel: "gpt-test",
      provenance: [.init(workflowId: "flow", stepId: "step", nodeId: "node")]
    )
    let capability = BackendCapability(
      backend: .codexAgent,
      source: .observed,
      observedAt: now,
      availability: .available,
      authentication: .available,
      models: []
    )
    let host = HostCapabilitySnapshot(hostId: "local", backends: [capability], refreshedAt: now)
    XCTAssertFalse(BackendCapabilityPlacementResolver().resolve(
      requirements: [requirement], local: host, workers: [], now: now
    ).complete)
  }

  func testAddonOnlyRequirementSelectsHostWithoutInventingBackend() throws {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let requirement = WorkflowBackendRequirement(
      addonExecutable: "tool-cli",
      provenance: [.init(workflowId: "flow", stepId: "tool", nodeId: "tool")]
    )
    var local = HostCapabilitySnapshot(hostId: "local", backends: [], refreshedAt: now)
    let resolver = BackendCapabilityPlacementResolver(maximumAge: 60)
    XCTAssertEqual(resolver.resolve(
      requirements: [requirement], local: local, workers: [], now: now
    ).failures.first?.reason, "addon-executable-unavailable: tool-cli")

    local.addonExecutables = ["tool-cli": true]
    let placed = resolver.resolve(requirements: [requirement], local: local, workers: [], now: now)
    XCTAssertTrue(placed.complete)
    XCTAssertEqual(placed.choices.first?.hostId, "local")
    XCTAssertNil(try XCTUnwrap(placed.choices.first).backend)
  }

  private func host(
    _ id: String,
    backend: NodeExecutionBackend,
    groups: Set<String> = [],
    capacity: Int? = nil,
    now: Date
  ) -> HostCapabilitySnapshot {
    HostCapabilitySnapshot(
      hostId: id,
      groups: groups,
      capacity: capacity,
      backends: [BackendCapability(
        backend: backend,
        source: .observed,
        observedAt: now,
        availability: .available,
        authentication: .available
      )],
      refreshedAt: now
    )
  }

  private func capability(_ backend: NodeExecutionBackend, now: Date) -> BackendCapability {
    BackendCapability(
      backend: backend,
      source: .observed,
      observedAt: now,
      availability: .available,
      authentication: .available
    )
  }
}
