import SQLite3
import XCTest
@testable import RielaMemory

final class RielaKeyValueStoreTests: XCTestCase {
  func testSetGetRoundTripsJSONValuesPerScope() throws {
    let store = RielaKeyValueStore(rootDirectory: temporaryDirectory().path)

    try store.set(
      storeId: "x-gateway-cursor",
      scope: "x-digest-workflow",
      key: "lastFetched",
      value: .object(["sinceId": .string("190001"), "fetchedAt": .string("2026-08-19T09:00:00Z")]),
      updatedAt: "2026-08-19T09:00:00Z"
    )

    let entry = try XCTUnwrap(store.get(storeId: "x-gateway-cursor", scope: "x-digest-workflow", key: "lastFetched"))
    XCTAssertEqual(entry.value, .object(["sinceId": .string("190001"), "fetchedAt": .string("2026-08-19T09:00:00Z")]))
    XCTAssertEqual(entry.createdAt, "2026-08-19T09:00:00Z")
    XCTAssertEqual(entry.updatedAt, "2026-08-19T09:00:00Z")
    XCTAssertNil(try store.get(storeId: "x-gateway-cursor", scope: "another-workflow", key: "lastFetched"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: try store.databasePath(storeId: "x-gateway-cursor")))
  }

  func testSetOverwritesValueAndKeepsCreatedAt() throws {
    let store = RielaKeyValueStore(rootDirectory: temporaryDirectory().path)

    try store.set(storeId: "s", scope: "wf", key: "token", value: .string("first"), updatedAt: "2026-08-19T09:00:00Z")
    let updated = try store.set(storeId: "s", scope: "wf", key: "token", value: .string("second"), updatedAt: "2026-08-19T10:00:00Z")

    XCTAssertEqual(updated.value, .string("second"))
    XCTAssertEqual(updated.createdAt, "2026-08-19T09:00:00Z")
    XCTAssertEqual(updated.updatedAt, "2026-08-19T10:00:00Z")
    XCTAssertEqual(try store.list(storeId: "s", scope: "wf").count, 1)
  }

  func testDeleteRemovesOnlyTargetKeyAndReportsMissing() throws {
    let store = RielaKeyValueStore(rootDirectory: temporaryDirectory().path)

    try store.set(storeId: "s", scope: "wf", key: "a", value: .string("1"))
    try store.set(storeId: "s", scope: "wf", key: "b", value: .string("2"))

    XCTAssertTrue(try store.delete(storeId: "s", scope: "wf", key: "a"))
    XCTAssertFalse(try store.delete(storeId: "s", scope: "wf", key: "a"))
    XCTAssertNil(try store.get(storeId: "s", scope: "wf", key: "a"))
    XCTAssertEqual(try store.get(storeId: "s", scope: "wf", key: "b")?.value, .string("2"))
  }

  func testDeleteAndGetOnMissingDatabaseDoNotCreateFiles() throws {
    let root = temporaryDirectory()
    let store = RielaKeyValueStore(rootDirectory: root.path)

    XCTAssertNil(try store.get(storeId: "missing", scope: "wf", key: "k"))
    XCTAssertFalse(try store.delete(storeId: "missing", scope: "wf", key: "k"))
    XCTAssertEqual(try store.list(storeId: "missing", scope: "wf"), [])
    XCTAssertFalse(FileManager.default.fileExists(atPath: try store.databasePath(storeId: "missing")))
  }

  func testListFiltersByPrefixAndOrdersByKey() throws {
    let store = RielaKeyValueStore(rootDirectory: temporaryDirectory().path)

    try store.set(storeId: "s", scope: "wf", key: "cursor/x", value: .string("1"))
    try store.set(storeId: "s", scope: "wf", key: "cursor/mail", value: .string("2"))
    try store.set(storeId: "s", scope: "wf", key: "config", value: .string("3"))
    try store.set(storeId: "s", scope: "other", key: "cursor/x", value: .string("4"))

    XCTAssertEqual(
      try store.list(storeId: "s", scope: "wf", options: KeyValueListOptions(keyPrefix: "cursor/")).map(\.key),
      ["cursor/mail", "cursor/x"]
    )
    XCTAssertEqual(try store.list(storeId: "s", scope: "wf").map(\.key), ["config", "cursor/mail", "cursor/x"])
    XCTAssertEqual(
      try store.list(storeId: "s", scope: "wf", options: KeyValueListOptions(limit: 1, offset: 1)).map(\.key),
      ["cursor/mail"]
    )
  }

  func testInvalidIdentifiersAreRejected() throws {
    let store = RielaKeyValueStore(rootDirectory: temporaryDirectory().path)

    XCTAssertThrowsError(try store.set(storeId: "../escape", scope: "wf", key: "k", value: .null)) { error in
      XCTAssertEqual(error as? RielaMemoryError, .invalidStoreId("../escape"))
    }
    XCTAssertThrowsError(try store.set(storeId: "s", scope: " ", key: "k", value: .null)) { error in
      XCTAssertEqual(error as? RielaMemoryError, .invalidStoreScope(" "))
    }
    XCTAssertThrowsError(try store.set(storeId: "s", scope: "wf", key: "", value: .null)) { error in
      XCTAssertEqual(error as? RielaMemoryError, .invalidStoreKey(""))
    }
    XCTAssertThrowsError(try store.list(storeId: "s", scope: "wf", options: KeyValueListOptions(limit: 0))) { error in
      XCTAssertEqual(error as? RielaMemoryError, .invalidLimit(0))
    }
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-kv-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }
}
