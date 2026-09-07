import XCTest
@testable import RielaCore

final class SpecialistRequestRoutingBoundaryTests: XCTestCase {
  func testMixedStatusAndClaimIsOrderIndependentAndHasNoOwner() {
    let decisions = [
      SpecialistDecision(specialistId: "work", kind: .claim),
      SpecialistDecision(specialistId: "status", kind: .status)
    ]
    for sequence in [decisions, decisions.reversed().map { $0 }] {
      let result = settle(sequence)
      XCTAssertEqual(result.outcome, .routingClarification)
      XCTAssertNil(result.selectedSpecialistId)
    }
  }

  func testExplicitStatusAndCancelNeverAcceptAClaim() {
    for route in [SpecialistRequestRoute.status, .cancel] {
      let result = SpecialistRequestRouter.settle(
        route: route, decisions: [SpecialistDecision(specialistId: "work", kind: .claim)],
        eligibleSpecialistIDs: ["work"], priority: ["work"]
      )
      XCTAssertEqual(result.outcome, .status)
      XCTAssertNil(result.selectedSpecialistId)
      XCTAssertTrue(result.claimants.isEmpty)
    }
  }

  func testUnknownSpecialistCannotClaimOrRouteToStatus() {
    for decision in [SpecialistDecisionKind.claim, .status] {
      let result = settle([SpecialistDecision(specialistId: "injected", kind: decision)])
      XCTAssertEqual(result.outcome, .unclaimed)
      XCTAssertNil(result.selectedSpecialistId)
    }
  }

  func testPriorityIsStableAndDuplicatePriorityDoesNotTrap() {
    let decisions = [
      SpecialistDecision(specialistId: "work", kind: .claim),
      SpecialistDecision(specialistId: "status", kind: .claim)
    ]
    for sequence in [decisions, decisions.reversed().map { $0 }] {
      let result = SpecialistRequestRouter.settle(
        route: .work, decisions: sequence, eligibleSpecialistIDs: ["work", "status"],
        priority: ["status", "work", "status"]
      )
      XCTAssertEqual(result.outcome, .newWork)
      XCTAssertEqual(result.selectedSpecialistId, "status")
      XCTAssertEqual(result.claimants, ["status", "work"])
    }
  }

  private func settle(_ decisions: [SpecialistDecision]) -> SpecialistRoutingSettlement {
    SpecialistRequestRouter.settle(
      route: .work, decisions: decisions, eligibleSpecialistIDs: ["work", "status"], priority: ["work", "status"]
    )
  }
}
