import Foundation
import RielaCore
import RielaAddons
import XCTest
@testable import RielaCLI

final class ArrayGatherTests: XCTestCase {
  private func execute(_ name: String, _ config: JSONObject, input: JSONObject = [:]) async throws -> JSONObject {
    try await BuiltinWorkflowAddonResolver(environment: [:]).execute(.init(workflowId: "gather-test", stepId: "gather", nodeId: "gather",
      addon: .init(name: name, version: "1", config: config), resolvedInputPayload: input), context: .init(deadline: Date().addingTimeInterval(30))).payload
  }
  private func fixture(_ count: Int) async throws -> JSONObject {
    let rows = (0..<count).map { JSONValue.object(["id": .string(String($0)), "text": .string("{{literal}}-" + String($0))]) }
    let batch = try await execute("riela/array-batch", ["items": .string("{{input.rows}}"), "size": .integer(2),
      "uniqueBy": .string("id"), "bindItems": .bool(true), "context": .string("{{input.context}}")],
      input: ["rows": .array(rows), "context": .object(["checkpoint": .integer(9), "text": .string("{{opaque}}")])])
    XCTAssertNil(batch["context"], "bound context must be carried only once")
    guard case let .array(batches)? = batch["items"] else { throw NSError(domain: "fixture", code: 1) }
    let branches = batches.enumerated().map { index, values -> JSONValue in
      guard case let .array(items) = values else { return .null }
      let ids = items.compactMap { value -> JSONValue? in
        guard case let .object(row) = value else { return nil }; return row["id"]
      }
      return .object(["index": .integer(Int64(index)), "status": .string("completed"), "item": values,
        "output": .object(["safe_ids": .array(Array(ids.prefix(1)))])])
    }
    return ["groupId": .string("inspection"), "allBranchesCompleted": .bool(true), "context": batch["receipt"] ?? .null,
      "branches": .array(branches)]
  }
  private func gather(_ join: JSONObject, filter: Bool = true) async throws -> JSONObject {
    var config: JSONObject = ["join": .string("{{input.join}}"), "groupId": .string("inspection")]
    if filter { config["selectedIdsFrom"] = .string("/safe_ids") }
    return try await execute("riela/array-gather", config, input: ["join": .object(join)])
  }

  func testRegisteredGatherAssemblesOriginalItemsInSourceOrderAndPreservesLiteralContext() async throws {
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/array-gather", version: "1"))
    var join = try await fixture(5)
    if case let .array(branches)? = join["branches"] { join["branches"] = .array(branches.reversed()) }
    let result = try await gather(join)
    XCTAssertEqual(result["itemCount"], .integer(5)); XCTAssertEqual(result["selectedCount"], .integer(3))
    XCTAssertEqual(result["items"], .array([0, 2, 4].map { .object(["id": .string(String($0)), "text": .string("{{literal}}-" + String($0))]) }))
    XCTAssertEqual(result["context"], .object(["checkpoint": .integer(9), "text": .string("{{opaque}}")]))
    let all = try await gather(join, filter: false)
    XCTAssertEqual(all["selectedCount"], .integer(5))
  }

  func testEmptyAndShortBatchesReturnImmediatelyWithOriginalCheckpoint() async throws {
    for count in [0, 1, 3] {
      let result = try await gather(fixture(count))
      XCTAssertEqual(result["itemCount"], .integer(Int64(count)))
      XCTAssertNotNil(result["context"])
    }
  }

  func testModifiedMissingDuplicateFailedOrWrongGroupBranchesCannotReturnItems() async throws {
    for mutation in ["modified", "missing", "duplicate", "failed", "group", "partial", "index"] {
      var join = try await fixture(3)
      guard case var .array(branches)? = join["branches"], case var .object(first) = branches[0] else { return XCTFail("fixture") }
      switch mutation {
      case "modified": first["item"] = .array([.object(["id": .string("0"), "text": .string("changed")])]); branches[0] = .object(first)
      case "missing": branches.removeLast()
      case "duplicate": branches[1] = branches[0]
      case "failed": first["status"] = .string("failed"); branches[0] = .object(first)
      case "group": join["groupId"] = .string("other")
      case "partial": join["allBranchesCompleted"] = .bool(false)
      default: first["index"] = .integer(-1); branches[0] = .object(first)
      }
      join["branches"] = .array(branches)
      do { _ = try await gather(join); XCTFail(mutation) } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidInput) }
    }
  }

  func testUnknownCrossBatchDuplicateAndMalformedSelectedIDsFailClosed() async throws {
    for ids: JSONValue in [.array([.string("unknown")]), .array([.string("2")]), .null, .array([.integer(0)])] {
      var join = try await fixture(3)
      guard case var .array(branches)? = join["branches"], case var .object(first) = branches[0] else { return XCTFail("fixture") }
      first["output"] = .object(["safe_ids": ids]); branches[0] = .object(first); join["branches"] = .array(branches)
      do { _ = try await gather(join); XCTFail("invalid selection") } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidInput) }
    }
  }

  func testRepeatedSelectedIDsAreHarmlessAndDoNotDuplicateOriginalItems() async throws {
    var join = try await fixture(1)
    guard case var .array(branches)? = join["branches"], case var .object(first) = branches[0] else { return XCTFail("fixture") }
    first["output"] = .object(["safe_ids": .array([.string("0"), .string("0")])]); branches[0] = .object(first); join["branches"] = .array(branches)
    let result = try await gather(join)
    XCTAssertEqual(result["selectedCount"], .integer(1))
  }

  func testOpaqueIdentitiesCompareExactUTF8RatherThanUnicodeEquivalence() async throws {
    let nfc = "\u{00e9}", nfd = "e\u{0301}"
    let rows: [JSONValue] = [.object(["id": .string(nfc), "text": .string("NFC")]),
      .object(["id": .string(nfd), "text": .string("NFD")])]
    let batch = try await execute("riela/array-batch", ["items": .array(rows), "size": .integer(2), "uniqueBy": .string("id"), "bindItems": .bool(true)])
    let join: JSONObject = ["groupId": .string("inspection"), "allBranchesCompleted": .bool(true), "context": batch["receipt"] ?? .null,
      "branches": .array([.object(["index": .integer(0), "status": .string("completed"), "item": .array(rows),
        "output": .object(["safe_ids": .array([.string(nfd)])])])])]
    let result = try await gather(join)
    XCTAssertEqual(result["items"], .array([rows[1]]))
    let single = try await execute("riela/array-batch", ["items": .array([rows[1]]), "uniqueBy": .string("id"), "bindItems": .bool(true)])
    let unknown: JSONObject = ["groupId": .string("inspection"), "allBranchesCompleted": .bool(true), "context": single["receipt"] ?? .null,
      "branches": .array([.object(["index": .integer(0), "status": .string("completed"), "item": .array([rows[1]]),
        "output": .object(["safe_ids": .array([.string(nfc)])])])])]
    do { _ = try await gather(unknown); XCTFail("Unicode-equivalent unknown ID accepted") } catch {
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidInput)
    }
  }

  func testBindingRequiresExplicitUniqueObjectIdentities() async throws {
    for config: JSONObject in [["items": .array([]), "bindItems": .bool(true)],
      ["items": .array([]), "uniqueBy": .string("id"), "bindItems": .string("true")],
      ["items": .array([.object(["id": .string("a")]), .object(["id": .string("a")])]), "uniqueBy": .string("id"), "bindItems": .bool(true)]] {
      do { _ = try await execute("riela/array-batch", config); XCTFail("invalid binding") } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidInput) }
    }
  }
}
