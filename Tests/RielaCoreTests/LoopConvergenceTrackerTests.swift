import XCTest
@testable import RielaCore

final class LoopConvergenceTrackerTests: XCTestCase {
  func testRepeatedFindingRoundsStallOnSecondIdenticalRejectedVisit() {
    var tracker = LoopConvergenceTracker(declaration: LoopConvergenceDeclaration(maxRepeatedFindingRounds: 2))

    XCTAssertNil(tracker.recordGateVisit(gateId: "review", decision: .rejected, findings: [finding("a")]).violation)
    let check = tracker.recordGateVisit(gateId: "review", decision: .rejected, findings: [finding("a")])

    XCTAssertEqual(check.repeatedRounds, 2)
    XCTAssertEqual(check.violation?.kind, .repeatedFindingsStall)
  }

  func testAcceptedVisitResetsRepeatedFindingRounds() {
    var tracker = LoopConvergenceTracker(declaration: LoopConvergenceDeclaration(maxRepeatedFindingRounds: 2))

    _ = tracker.recordGateVisit(gateId: "review", decision: .rejected, findings: [finding("a")])
    _ = tracker.recordGateVisit(gateId: "review", decision: .accepted, findings: [])
    let check = tracker.recordGateVisit(gateId: "review", decision: .rejected, findings: [finding("a")])

    XCTAssertNil(check.violation)
    XCTAssertEqual(check.repeatedRounds, 1)
  }

  func testSkippedVisitResetsRepeatedFindingRounds() {
    var tracker = LoopConvergenceTracker(declaration: LoopConvergenceDeclaration(maxRepeatedFindingRounds: 2))

    _ = tracker.recordGateVisit(gateId: "review", decision: .rejected, findings: [finding("a")])
    _ = tracker.recordGateVisit(gateId: "review", decision: .skipped, findings: [])
    let check = tracker.recordGateVisit(gateId: "review", decision: .rejected, findings: [finding("a")])

    XCTAssertNil(check.violation)
    XCTAssertEqual(check.repeatedRounds, 1)
  }

  func testChangedFindingsResetRepeatedFindingRounds() {
    var tracker = LoopConvergenceTracker(declaration: LoopConvergenceDeclaration(maxRepeatedFindingRounds: 2))

    _ = tracker.recordGateVisit(gateId: "review", decision: .needsWork, findings: [finding("a")])
    let check = tracker.recordGateVisit(gateId: "review", decision: .needsWork, findings: [finding("b")])

    XCTAssertNil(check.violation)
    XCTAssertEqual(check.repeatedRounds, 1)
  }

  func testMaxGateVisitsFailsRegardlessOfFindingIdentity() {
    var tracker = LoopConvergenceTracker(declaration: LoopConvergenceDeclaration(maxGateVisits: 2))

    XCTAssertNil(tracker.recordGateVisit(gateId: "review", decision: .rejected, findings: [finding("a")]).violation)
    XCTAssertNil(tracker.recordGateVisit(gateId: "review", decision: .rejected, findings: [finding("b")]).violation)
    let check = tracker.recordGateVisit(gateId: "review", decision: .rejected, findings: [finding("c")])

    XCTAssertEqual(check.violation?.kind, .gateVisitsExceeded)
  }

  func testWarnStyleTrackingReportsOnlyFirstViolationForGate() {
    var tracker = LoopConvergenceTracker(declaration: LoopConvergenceDeclaration(maxRepeatedFindingRounds: 2))

    _ = tracker.recordGateVisit(gateId: "review", decision: .rejected, findings: [finding("a")])
    let firstStall = tracker.recordGateVisit(gateId: "review", decision: .rejected, findings: [finding("a")])
    let continuedStall = tracker.recordGateVisit(gateId: "review", decision: .rejected, findings: [finding("a")])

    XCTAssertNotNil(firstStall.violation)
    XCTAssertNil(continuedStall.violation)
    XCTAssertEqual(continuedStall.repeatedRounds, 3)
  }

  private func finding(_ id: String) -> LoopBlockingFinding {
    LoopBlockingFinding(id: id, severity: "high", filePath: "Sources/A.swift", message: "message \(id)")
  }
}
