import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class RecordManifestAdmissionTests: XCTestCase {
  func testMissingPrefixReturnsAvailableTwoWithoutWaitingOrAcknowledging() throws {
    let entries = (0..<44).map { entry(String($0)) }
    let output = try admit(entries, bodies: [body("42"), body("43")])
    XCTAssertEqual(output["records"], .array([.string("42"), .string("43")]))
    XCTAssertEqual(output["admitted"], .array(Array(entries[42...])))
    XCTAssertEqual(output["deferred"], .array(Array(entries[..<42])))
    XCTAssertEqual(output["handled"], .array([]))
  }

  func testAcknowledgementMatchesExactVersionAndDoesNotHandleChangedBody() throws {
    let entries = [entry("done"), entry("changed", version: "two")]
    let output = try admit(entries, bodies: [body("changed", version: "two")], extra: ["acknowledged": .array([
      .object(["key": .string("done"), "version": .string("one")]),
      .object(["key": .string("changed"), "version": .string("one")])])])
    XCTAssertEqual(output["handled"], .array([entries[0]]))
    XCTAssertEqual(output["admitted"], .array([entries[1]]))
  }

  func testFrozenPrioritySurvivesAdditionsAndChangedVersionDropsStalePriority() throws {
    let old = entry("pending")
    var output = try admit([entry("fresh"), old], bodies: [body("fresh"), body("pending")],
      extra: ["priority": .array([old]), "maximumItems": .integer(1)])
    XCTAssertEqual(output["admitted"], .array([old]))
    output = try admit([entry("fresh"), entry("pending", version: "two")],
      bodies: [body("fresh"), body("pending", version: "two")],
      extra: ["priority": .array([old]), "maximumItems": .integer(1)])
    XCTAssertEqual(output["admitted"], .array([entry("fresh")]))
  }

  func testByteLimitSeparatesOversizedFromDeferredAndCanFitLaterShortBody() throws {
    let entries = [entry("large"), entry("first"), entry("deferred"), entry("small")]
    let output = try admit(entries, bodies: [body("large", payload: String(repeating: "x", count: 200)),
      body("first", payload: String(repeating: "x", count: 60)), body("deferred", payload: String(repeating: "x", count: 60)),
      body("small", payload: "y")], extra: ["maximumBytes": .integer(100)])
    XCTAssertEqual(output["admitted"], .array([entries[1], entries[3]]))
    XCTAssertEqual(output["oversizedKeys"], .array([.string("large")]))
    XCTAssertEqual(output["deferred"], .array([entries[0], entries[2]]))
  }

  func testUnexaminedReferencesAreDeferredWithoutClaimingMissingOrHandled() throws {
    let entries = [entry("missing"), entry("unread")]
    let output = try admit(entries, bodies: [], extra: ["examinedKeys": .array([.string("missing")])])
    XCTAssertEqual(output["unavailableKeys"], .array([.string("missing")]))
    XCTAssertEqual(output["deferred"], .array(entries));XCTAssertEqual(output["handled"], .array([]))
  }

  func testMalformedOrForeignAvailableTailIsRejectedEvenAfterLimitWouldFill() throws {
    for invalid in [body("unknown"), body("two", version: "different"), body("one")] {
      XCTAssertThrowsError(try admit([entry("one"), entry("two")], bodies: [body("one"), invalid],
        extra: ["maximumItems": .integer(1)]))
    }
    XCTAssertThrowsError(try admit([entry("one")], bodies: [], extra: ["examinedKeys": .array([.string("unknown")])]))
    XCTAssertThrowsError(try admit([entry("one")], bodies: [], extra: ["maximumBytes": .integer(1)]))
  }

  private func admit(_ entries: [JSONValue], bodies: [JSONValue], extra: JSONObject = [:]) throws -> JSONObject {
    var config: JSONObject = ["entries": .array(entries), "available": .array(bodies)]
    config.merge(extra) { _, value in value }
    return try RecordManifest.execute(action: "admit", value: config)
  }
  private func entry(_ key: String, version: String = "one") -> JSONValue {
    .object(["key": .string(key), "version": .string(version), "value": .object(["id": .string(key)])])
  }
  private func body(_ key: String, version: String = "one", payload: String? = nil) -> JSONValue {
    .object(["key": .string(key), "version": .string(version), "payload": .string(payload ?? key)])
  }
}
