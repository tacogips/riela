import Foundation
import XCTest
@testable import RielaCore

final class RielaLogRetentionPlanTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 100_000)

  private func entry(_ name: String, hours: Double, size: Int64 = 10,
                     kind: RielaLogFileEntry.Kind = .regular) -> RielaLogFileEntry {
    .init(name: name, kind: kind, size: size, modifiedAt: now.addingTimeInterval(-hours * 3600),
      device: 1, inode: UInt64(name.utf8.count))
  }

  func testAgeSelectsOldFilesFirst() throws {
    let plan = try RielaLogRetentionPlan.make(entries: [entry("new", hours: 30), entry("old", hours: 50)],
      now: now, maxAge: 40 * 3600, maxBytes: nil)
    XCTAssertEqual(plan.selected.map(\.name), ["old"])
    XCTAssertTrue(plan.capAchieved)
  }

  func testCapSelectsOldestUntilUnderLimit() throws {
    let plan = try RielaLogRetentionPlan.make(entries: [entry("a", hours: 50, size: 30),
      entry("b", hours: 40, size: 20), entry("c", hours: 30, size: 10)], now: now,
      maxAge: nil, maxBytes: 20)
    XCTAssertEqual(plan.selected.map(\.name), ["a", "b"])
    XCTAssertEqual(plan.projectedRemainingBytes, 10)
  }

  func testGraceFilesCountTowardCapButCannotBeSelected() throws {
    let plan = try RielaLogRetentionPlan.make(entries: [entry("active", hours: 1, size: 50)],
      now: now, maxAge: nil, maxBytes: 10)
    XCTAssertTrue(plan.selected.isEmpty)
    XCTAssertEqual(plan.protected["withinGraceWindow"], 1)
    XCTAssertEqual(plan.beforeBytes, 50)
    XCTAssertFalse(plan.capAchieved)
  }

  func testSymlinksNonRegularAndHiddenFilesAreProtectedOutsideTotals() throws {
    let entries = [entry("link", hours: 100, kind: .symlink), entry("folder", hours: 100, kind: .directory),
      entry("socket", hours: 100, kind: .other), entry(".hidden", hours: 100)]
    let plan = try RielaLogRetentionPlan.make(entries: entries, now: now, maxAge: 1, maxBytes: nil)
    XCTAssertEqual(plan.protected["symlink"], 1)
    XCTAssertEqual(plan.protected["notRegularFile"], 2)
    XCTAssertEqual(plan.protected["hidden"], 1)
    XCTAssertEqual(plan.beforeBytes, 0)
    XCTAssertTrue(plan.selected.isEmpty)
  }

  func testRemovalLimitAndEqualMtimeUseNameOrder() throws {
    let tied = [entry("c", hours: 50), entry("a", hours: 50), entry("b", hours: 50)]
    let plan = try RielaLogRetentionPlan.make(entries: tied, now: now, maxAge: 1, maxBytes: nil,
      removalLimit: 2)
    XCTAssertEqual(plan.selected.map(\.name), ["a", "b"])
    XCTAssertTrue(plan.workLimitReached)
  }

  func testInvalidPolicyAndNegativeSizeAreRejected() {
    XCTAssertThrowsError(try RielaLogRetentionPlan.make(entries: [], now: now, maxAge: nil, maxBytes: nil))
    XCTAssertThrowsError(try RielaLogRetentionPlan.make(entries: [entry("bad", hours: 50, size: -1)],
      now: now, maxAge: 1, maxBytes: nil))
  }
}
