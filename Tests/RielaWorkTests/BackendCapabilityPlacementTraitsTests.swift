import Foundation
import RielaCore
import XCTest
@testable import RielaWork

final class BackendCapabilityPlacementTraitsTests: XCTestCase {
  func testRequiredTraitsFilterLocalAndWorkerPlacement() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let provenance = WorkflowRequirementProvenance(workflowId: "flow", stepId: "step", nodeId: "node")
    let requirement = WorkflowBackendRequirement(provenance: [provenance])
    let local = host("local", traits: [], now: now)
    let capableWorker = host("worker-b", traits: [.userReachable], now: now)
    let resolver = BackendCapabilityPlacementResolver()

    let unavailable = resolver.resolve(
      requirements: [requirement], local: local, workers: [], requiredTraits: [.userReachable], now: now
    )
    XCTAssertEqual(unavailable.failures.first?.reason, "host-traits-unavailable: userReachable")

    let localMatch = resolver.resolve(
      requirements: [requirement], local: host("local", traits: [.userReachable], now: now),
      workers: [], requiredTraits: [.userReachable], now: now
    )
    XCTAssertEqual(localMatch.choices.first?.hostId, "local")

    let workerMatch = resolver.resolve(
      requirements: [requirement], local: local,
      workers: [host("worker-a", traits: [], now: now), capableWorker],
      requiredTraits: [.userReachable], now: now
    )
    XCTAssertEqual(workerMatch.choices.first?.hostId, "worker-b")

    let unchanged = resolver.resolve(requirements: [requirement], local: local, workers: [], now: now)
    XCTAssertTrue(unchanged.complete)
    XCTAssertEqual(unchanged.choices.first?.hostId, "local")
  }

  private func host(_ id: String, traits: [HostTrait], now: Date) -> HostCapabilitySnapshot {
    HostCapabilitySnapshot(hostId: id, capacity: 1, backends: [], refreshedAt: now, traits: traits)
  }
}
