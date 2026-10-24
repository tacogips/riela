import Foundation
import XCTest
@testable import RielaCore

final class TerminalRetentionPlanTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 100_000)
  private func row(_ id: String, hours: Double = 25, bytes: Int64 = 100,
                   status: Set<String> = ["completed"], parent: String? = nil,
                   root: String? = nil, protection: String? = nil,
                   messageBytes: Int64 = 0, workflow: String = "news") -> TerminalRetentionSession {
    .init(id: id, workflowId: workflow, parentId: parent, rootId: root, statuses: status,
          updatedAt: now.addingTimeInterval(-hours * 3600), payloadBytes: bytes,
          messageBytes: messageBytes, protection: protection)
  }
  private func plan(_ rows: [TerminalRetentionSession], cap: Int64 = 1000) throws -> TerminalRetentionPlan {
    try .make(sessions: rows, workflows: ["news"], now: now, retentionHours: 24, maxPayloadBytes: cap)
  }

  func testLegacyPayloadCapStillChargesMessageCopies() throws {
    let rows = [row("older", hours: 2, bytes: 1, messageBytes: 100), row("newer", hours: 1, bytes: 1)]
    let legacy = try plan(rows, cap: 50)
    XCTAssertEqual(legacy.beforeBytes, 102)
    XCTAssertEqual(legacy.selected.map(\.rootId), ["older"])
    XCTAssertEqual(legacy.projectedRemainingBytes, 1)
    let separate = try TerminalRetentionPlan.make(sessions: rows, scope: .workflows(["news"]), now: now,
      maxAge: nil, maxBytes: 50, bytes: .results)
    XCTAssertEqual(separate.beforeBytes, 2)
    XCTAssertTrue(separate.selected.isEmpty)
    XCTAssertThrowsError(try plan([row("overflow", bytes: Int64.max, messageBytes: 1)]))
  }

  func testExpiryAndCapSelectWholeOldestFamilies() throws {
    let result = try plan([row("old"), row("middle", hours: 2), row("new", hours: 1)], cap: 150)
    XCTAssertEqual(result.selected.map(\.rootId), ["old", "middle"])
    XCTAssertEqual(result.projectedRemainingBytes, 100)
    XCTAssertTrue(result.capAchieved)
  }

  func testPausedChildProtectsEntireFamilyEvenOverCap() throws {
    let result = try plan([row("root"), row("child", status: ["suspended"], parent: "root", root: "root")], cap: 1)
    XCTAssertTrue(result.selected.isEmpty)
    XCTAssertEqual(result.protected.first?.ids, ["child", "root"])
    XCTAssertEqual(result.projectedRemainingBytes, 200)
    XCTAssertFalse(result.capAchieved)
  }

  func testRecentChildPreventsAgeExpiryAndMissingParentIsProtected() throws {
    let result = try plan([row("root"), row("child", hours: 1, parent: "root", root: "root"),
                           row("orphan", parent: "missing", root: "missing")])
    XCTAssertTrue(result.selected.isEmpty)
    XCTAssertEqual(result.protected.map(\.rootId), ["orphan"])
  }

  func testConflictingProjectionAndLocksAreProtected() throws {
    let result = try plan([row("conflict", status: ["completed", "running"]),
                           row("lock", protection: "executionLocked"), row("empty", status: [])], cap: 1)
    XCTAssertTrue(result.selected.isEmpty)
    XCTAssertEqual(result.protected.count, 3)
  }

  func testOutsideScopeAndInvalidMetadata() throws {
    var other = row("other"); other.workflowId = "durable"
    XCTAssertEqual(try plan([other]).beforeBytes, 0)
    XCTAssertThrowsError(try plan([row("same"), row("same")]))
    XCTAssertThrowsError(try plan([row("negative", bytes: -1)]))
    XCTAssertThrowsError(try plan([row("a", bytes: Int64.max), row("b")]))
  }

  func testCancelledRootOlderThanRetentionCutoffIsSelected() throws {
    let result = try plan([row("cancelled-root", status: ["cancelled"])])
    XCTAssertEqual(result.selected.map(\.rootId), ["cancelled-root"])
    XCTAssertTrue(result.protected.isEmpty)
  }

  func testCancelledFamilyWithRunningMemberStaysProtected() throws {
    let result = try plan([row("root", status: ["cancelled"]),
                           row("child", hours: 1, status: ["running"], parent: "root", root: "root")], cap: 1)
    XCTAssertTrue(result.selected.isEmpty)
    XCTAssertEqual(result.protected.first?.protection, "nonterminalOrConflictingStatus")
    XCTAssertEqual(result.protected.first?.ids, ["child", "root"])
  }

  func testAllExceptProtectsAnyKeptWorkflowMember() throws {
    let rows = [row("root", workflow: "keep"), row("child", parent: "root", root: "root"), row("old")]
    let result = try TerminalRetentionPlan.make(sessions: rows, scope: .allExcept(["keep"]), now: now,
      maxAge: 24 * 3600, maxBytes: nil, bytes: .results)
    XCTAssertEqual(result.protected.first?.protection, "keptWorkflow")
    XCTAssertEqual(result.selected.map(\.rootId), ["old"])
  }

  func testAgeOnlyPlanSelectsOldFamiliesAndAchievesCap() throws {
    let result = try TerminalRetentionPlan.make(sessions: [row("old"), row("young", hours: 1)],
      scope: .allExcept([]), now: now, maxAge: 24 * 3600, maxBytes: nil, bytes: .results)
    XCTAssertEqual(result.selected.map(\.rootId), ["old"])
    XCTAssertTrue(result.capAchieved)
  }

  func testCapOnlyPlanSelectsOldestUntilUnderCap() throws {
    let result = try TerminalRetentionPlan.make(sessions: [row("a", bytes: 50), row("b", hours: 2, bytes: 40),
      row("c", hours: 1, bytes: 30)], scope: .allExcept([]), now: now, maxAge: nil,
      maxBytes: 30, bytes: .results)
    XCTAssertEqual(result.selected.map(\.rootId), ["a", "b"])
    XCTAssertEqual(result.projectedRemainingBytes, 30)
  }

  func testNonterminalAndUnresolvedFamiliesRemainProtectedUnderCap() throws {
    let result = try TerminalRetentionPlan.make(sessions: [row("running", status: ["running"]),
      row("suspended", status: ["suspended"]), row("created", status: ["created"]),
      row("orphan", parent: "missing", root: "missing")], scope: .allExcept([]), now: now,
      maxAge: nil, maxBytes: 1, bytes: .results)
    XCTAssertTrue(result.selected.isEmpty)
    XCTAssertEqual(result.protected.count, 4)
    XCTAssertFalse(result.capAchieved)
  }

  func testMessagesUseSeparateTotalsAndSkipZeroByteFamiliesForLimit() throws {
    let result = try TerminalRetentionPlan.make(sessions: [row("zero", hours: 30),
      row("one", hours: 20, messageBytes: 40), row("two", hours: 10, messageBytes: 60)],
      scope: .allExcept([]), now: now, maxAge: nil, maxBytes: 50, bytes: .messages, familyLimit: 1)
    XCTAssertEqual(result.beforeBytes, 100)
    XCTAssertEqual(result.selected.map(\.rootId), ["one"])
    XCTAssertEqual(result.eligible.map(\.rootId), ["one", "two"])
    XCTAssertTrue(result.workLimitReached)
  }

  func testFamilyLimitSignalsOnlyWhenAnotherFamilyWouldBeSelected() throws {
    let sessions = [row("a", hours: 30), row("b", hours: 29), row("c", hours: 28)]
    let result = try TerminalRetentionPlan.make(sessions: sessions, scope: .allExcept([]), now: now,
      maxAge: 24 * 3600, maxBytes: nil, bytes: .results, familyLimit: 1)
    XCTAssertEqual(result.selected.map(\.rootId), ["a"])
    XCTAssertTrue(result.workLimitReached)
  }

  func testEligibleIncludesUnselectedFamiliesInStableOrder() throws {
    let result = try TerminalRetentionPlan.make(sessions: [row("later", hours: 26), row("first", hours: 30),
      row("young", hours: 1)], scope: .allExcept([]), now: now, maxAge: 24 * 3600,
      maxBytes: nil, bytes: .results)
    XCTAssertEqual(result.eligible.map(\.rootId), ["first", "later", "young"])
    XCTAssertEqual(result.selected.map(\.rootId), ["first", "later"])
  }

  func testNewPlannerRejectsMissingLimits() {
    XCTAssertThrowsError(try TerminalRetentionPlan.make(sessions: [row("a")], scope: .allExcept([]),
      now: now, maxAge: nil, maxBytes: nil, bytes: .results))
  }

  func testLegacyWrapperMatchesMappedNewPlanner() throws {
    let sessions = [row("old"), row("young", hours: 1)]
    let legacy = try TerminalRetentionPlan.make(sessions: sessions, workflows: ["news"], now: now,
      retentionHours: 24, maxPayloadBytes: 150)
    let mapped = try TerminalRetentionPlan.make(sessions: sessions, scope: .workflows(["news"]), now: now,
      maxAge: 24 * 3600, maxBytes: 150, bytes: .results)
    XCTAssertEqual(legacy, mapped)
  }
}
