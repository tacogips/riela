import Foundation
import XCTest
@testable import RielaCore

final class TerminalRetentionPlanTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 100_000)
  private func row(_ id: String, hours: Double = 25, bytes: Int64 = 100,
                   status: Set<String> = ["completed"], parent: String? = nil,
                   root: String? = nil, protection: String? = nil) -> TerminalRetentionSession {
    .init(id: id, workflowId: "news", parentId: parent, rootId: root, statuses: status,
          updatedAt: now.addingTimeInterval(-hours * 3600), payloadBytes: bytes, protection: protection)
  }
  private func plan(_ rows: [TerminalRetentionSession], cap: Int64 = 1000) throws -> TerminalRetentionPlan {
    try .make(sessions: rows, workflows: ["news"], now: now, retentionHours: 24, maxPayloadBytes: cap)
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
}
