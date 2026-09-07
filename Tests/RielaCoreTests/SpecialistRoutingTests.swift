import XCTest
@testable import RielaCore

final class SpecialistRoutingTests: XCTestCase {
  func testStatusAndMixedDecisionsCannotSelectAnOwner() {
    let eligible: Set<String> = ["alpha", "beta"]
    let status = SpecialistRequestRouter.settle(route: .work, decisions: [
      SpecialistDecision(specialistId: "alpha", kind: .status),
      SpecialistDecision(specialistId: "beta", kind: .decline)
    ], eligibleSpecialistIDs: eligible, priority: ["alpha", "beta"])
    XCTAssertEqual(status.outcome, .status)
    XCTAssertNil(status.selectedSpecialistId)
    let mixed = SpecialistRequestRouter.settle(route: .work, decisions: [
      SpecialistDecision(specialistId: "alpha", kind: .status),
      SpecialistDecision(specialistId: "beta", kind: .claim)
    ], eligibleSpecialistIDs: eligible, priority: ["alpha", "beta"])
    XCTAssertEqual(mixed.outcome, .routingClarification)
    XCTAssertNil(mixed.selectedSpecialistId)
  }

  func testClaimSelectionIsIndependentOfDecisionArrivalOrder() {
    let decisions = [
      SpecialistDecision(specialistId: "beta", kind: .claim),
      SpecialistDecision(specialistId: "alpha", kind: .claim)
    ]
    let settlement = SpecialistRequestRouter.settle(route: .work, decisions: decisions.reversed(),
                                                     eligibleSpecialistIDs: ["alpha", "beta"], priority: ["alpha", "beta"])
    XCTAssertEqual(settlement.outcome, .newWork)
    XCTAssertEqual(settlement.selectedSpecialistId, "alpha")
    XCTAssertEqual(settlement.claimants, ["alpha", "beta"])
  }
}
