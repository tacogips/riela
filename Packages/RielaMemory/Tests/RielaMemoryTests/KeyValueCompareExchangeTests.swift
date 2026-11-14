import Foundation
import XCTest
@testable import RielaMemory

final class KeyValueCompareExchangeTests: XCTestCase {
  func testAbsentDiffersFromNullAndConflictsNeverOverwrite() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaKeyValueStore(rootDirectory: root.path)
    XCTAssertFalse(try store.compareExchange(storeId: "state", scope: "workflow", key: "cursor",
      expectedValue: .null, value: .string("wrong")))
    XCTAssertNil(try store.get(storeId: "state", scope: "workflow", key: "cursor"))
    XCTAssertTrue(try store.compareExchange(storeId: "state", scope: "workflow", key: "cursor",
      expectedValue: nil, value: .null))
    XCTAssertFalse(try store.compareExchange(storeId: "state", scope: "workflow", key: "cursor",
      expectedValue: nil, value: .string("wrong")))
    XCTAssertTrue(try store.compareExchange(storeId: "state", scope: "workflow", key: "cursor",
      expectedValue: .null, value: .object(["cursor": .string("next"), "pending": .array([.string("a")])])))
    XCTAssertFalse(try store.compareExchange(storeId: "state", scope: "workflow", key: "cursor",
      expectedValue: .null, value: .string("stale")))
    let restarted = RielaKeyValueStore(rootDirectory: root.path)
    XCTAssertEqual(try restarted.get(storeId: "state", scope: "workflow", key: "cursor")?.value,
      .object(["cursor": .string("next"), "pending": .array([.string("a")])]))
  }
}
