import Foundation
import RielaCore
import RielaMemory
import XCTest
@testable import RielaCLI

final class PrivateWorkflowCacheSpaceTests: XCTestCase {
  func testWireSeedPreservesFetchTimeAndTTL() throws {
    let root = try makeRielaCLITestTemporaryDirectory("private-cache-seed")
    defer { try? FileManager.default.removeItem(at: root) }
    let fetched = Date(timeIntervalSince1970: 1_790_000_000)
    let host = XUserPrivateCacheSpace(environment: ["RIELA_CACHE_ROOT": root.appendingPathComponent("host").path], clock: { fetched })
    XCTAssertEqual(host.consume(.array([.object(["id": .string("1"), "username": .string("known")])])), "stored")
    let expected = try XCTUnwrap(host.snapshot())
    let wire = try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(expected))
    let guest = XUserPrivateCacheSpace(environment: ["RIELA_CACHE_ROOT": root.appendingPathComponent("guest").path], clock: { fetched.addingTimeInterval(86_400) })
    guest.seed(wire)
    XCTAssertEqual(guest.snapshot(), expected)
    XCTAssertTrue(try guest.exchange.bindings().values.contains { $0.contains("known") })
    let expired = XUserPrivateCacheSpace(environment: ["RIELA_CACHE_ROOT": root.appendingPathComponent("guest").path], clock: { fetched.addingTimeInterval(31 * 86_400) })
    XCTAssertEqual(expired.snapshot()?["entries"], .array([]))
  }

  func testMalformedExportsAndRecordLimitStayClosed() throws {
    let root = try makeRielaCLITestTemporaryDirectory("private-cache-exports")
    defer { try? FileManager.default.removeItem(at: root) }
    let spaces = PrivateWorkflowCacheSpaces(names: ["x-gateway-users"], environment: ["RIELA_CACHE_ROOT": root.path])
    let collector = PrivateWorkflowCacheExportCollector(spaces: spaces, seeds: [:], maximumRecords: 2)
    let invalid: JSONValue = .array([.object(["id": .string("1"), "username": .string("known"), "body": .string("PRIVATE_CANARY")])])
    collector.accept(try XCTUnwrap(PrivateWorkflowCacheTransport.line(cache: "x-gateway-users", payload: invalid)))
    let valid: JSONValue = .array([.object(["id": .string("2"), "username": .string("valid")])])
    collector.accept(try XCTUnwrap(PrivateWorkflowCacheTransport.line(cache: "x-gateway-users", payload: valid)))
    collector.accept(PrivateWorkflowCacheTransport.prefix + "{}");collector.accept("unrelated PRIVATE_CANARY")
    XCTAssertEqual(collector.metadata["receivedRecords"], .integer(2))
    XCTAssertEqual(collector.metadata["droppedRecords"], .integer(1))
    let stored = try JSONValue.object(spaces.snapshot()["x-gateway-users"] ?? [:]).compactJSONString()
    XCTAssertTrue(stored.contains("valid"));XCTAssertFalse(stored.contains("PRIVATE_CANARY"));XCTAssertFalse(stored.contains("known"))
  }

  func testDisabledSpacesDoNotCreateStore() throws {
    let root = try makeRielaCLITestTemporaryDirectory("private-cache-disabled")
    defer { try? FileManager.default.removeItem(at: root) }
    let absent = root.appendingPathComponent("absent")
    let spaces = PrivateWorkflowCacheSpaces(names: [], environment: ["RIELA_CACHE_ROOT": absent.path])
    let collector = PrivateWorkflowCacheExportCollector(spaces: spaces, seeds: [:])
    collector.accept(PrivateWorkflowCacheTransport.prefix + "{}")
    XCTAssertTrue(spaces.snapshot().isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
    XCTAssertEqual(collector.metadata["receivedRecords"], .integer(0))
  }

  func testAggregateBytesAndOversizeLinesCannotKeepWriting() throws {
    let root = try makeRielaCLITestTemporaryDirectory("private-cache-budget")
    defer { try? FileManager.default.removeItem(at: root) }
    let spaces = PrivateWorkflowCacheSpaces(names: ["x-gateway-users"], environment: ["RIELA_CACHE_ROOT": root.path])
    let line = try XCTUnwrap(PrivateWorkflowCacheTransport.line(cache: "x-gateway-users", payload:
      .array([.object(["id": .string("1"), "username": .string("first")])])))
    let collector = PrivateWorkflowCacheExportCollector(spaces: spaces, seeds: [:], maximumBytes: line.utf8.count)
    collector.accept(line);collector.accept(line)
    collector.accept(PrivateWorkflowCacheTransport.prefix + String(repeating: "x", count: 1_000_001))
    XCTAssertEqual(collector.metadata["receivedRecords"], .integer(1))
    XCTAssertEqual(collector.metadata["receivedBytes"], .integer(Int64(line.utf8.count)))
    XCTAssertEqual(collector.metadata["droppedRecords"], .integer(2))
  }
}
