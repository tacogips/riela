import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class RecordManifestTests: XCTestCase {
  func testMissingBodiesUseExactAcknowledgedVersionAndNeverDiscardPendingReferences() throws {
    let entries = [entry("ready"), entry("pending"), entry("exported"), entry("changed", version: "two")]
    let output = try RecordManifest.execute(action: "partition", value: ["entries": .array(entries),
      "availableKeys": strings(["ready"]), "acknowledged": acks([("exported", "one"), ("changed", "one")])])
    XCTAssertEqual(output["available"], .array([entries[0]]))
    XCTAssertEqual(output["pending"], .array([entries[1], entries[3]]))
    XCTAssertEqual(output["acknowledgedMissing"], .array([entries[2]]))
    XCTAssertEqual(output["needsRecovery"], .bool(true))
    XCTAssertEqual(entries[1], entry("pending"))
  }

  func testSelectedReadKeepsVerifiedUnavailableMetadataOutsideSliceAndSeparatesOversized() throws {
    let entries = [entry("ready"), entry("wide"), entry("omitted"), entry("not-exported")]
    let output = try RecordManifest.execute(action: "partition", value: ["entries": .array(entries),
      "selectedKeys": strings(["ready", "wide"]), "availableKeys": strings(["ready"]),
      "oversizedKeys": strings(["wide"]), "unavailableAcknowledgedKeys": strings(["omitted", "not-exported"]),
      "acknowledged": acks([("omitted", "one")])])
    XCTAssertEqual(output["acknowledgedMissing"], .array([entries[2]]))
    XCTAssertEqual(output["pending"], .array([]))
    XCTAssertEqual(output["oversized"], .array([entries[1]]))
    XCTAssertNil(output["processingComplete"])
  }

  func testFreshPollKeepsOldMissingWorkWhileAnExplicitNewVersionSupersedesOldBody() throws {
    let old = [entry("missing"), entry("updated"), entry("irrelevant")]
    let current = [entry("fresh"), entry("updated", version: "two")]
    let output = try RecordManifest.execute(action: "merge", value: ["entries": .array(old), "current": .array(current),
      "retainKeys": strings(["missing", "updated"])])
    XCTAssertEqual(output["entries"], .array(current + [old[0]]))
    XCTAssertEqual(output["retainedKeys"], strings(["missing"]))
  }

  func testRecovery131ShapePreservesPendingAndExportedUnavailableRefsAndFrozenContext() throws {
    let entries = (0..<131).map { entry(String($0)) }
    var value = recovery(entries)
    let output = try RecordManifest.execute(action: "recover", value: value)
    XCTAssertEqual(output["retainedPending"], .array(Array(entries[104...])))
    XCTAssertEqual(output["retainedAcknowledged"], .array(Array(entries[77..<89])))
    XCTAssertEqual(output["hasProgress"], .bool(true))
    value["context"] = .object(["cursor": .string("advanced-without-permission")])
    XCTAssertThrowsError(try RecordManifest.execute(action: "recover", value: value))
  }

  func testRecoveryRejectsForgedPartitionsUnattemptedReturnsAndWrongExportVersions() throws {
    let entries = (0..<131).map { entry(String($0)) }
    for (key, replacement) in [
      ("returnedKeys", strings(["90", "90"])), ("pendingKeys", strings(["90"])),
      ("availableKeys", strings((0..<104).map(String.init))),
      ("attemptedKeys", strings((104..<131).map(String.init))),
      ("acknowledged", acks([("77", "another-version")]))
    ] as [(String, JSONValue)] {
      var value = recovery(entries); value[key] = replacement
      XCTAssertThrowsError(try RecordManifest.execute(action: "recover", value: value), key)
    }
  }

  func testNoInspectedReturnsDoNotPretendThatRecoveryMadeProgress() throws {
    let entries = [entry("waiting")]
    let output = try RecordManifest.execute(action: "recover", value: ["entries": .array(entries),
      "requestedKeys": strings(["waiting"]), "returnedKeys": strings([]), "pendingKeys": strings(["waiting"]),
      "availableKeys": strings([]), "context": .string("{{original-cursor}}"), "expectedContext": .string("{{original-cursor}}")])
    XCTAssertEqual(output["hasProgress"], .bool(false))
    XCTAssertEqual(output["retainedPending"], .array(entries))
  }

  func testCrossProviderKeysAndAccountsRemainOpaqueDistinctIdentities() throws {
    let entries = [entry("gmail/account/thread"), entry("web/site/url"), entry("x/account-a/post"), entry("x/account-b/post")]
    let output = try RecordManifest.execute(action: "partition", value: ["entries": .array(entries),
      "availableKeys": strings(["gmail/account/thread", "web/site/url"]),
      "acknowledged": acks([("x/account-a/post", "one")])])
    XCTAssertEqual(output["pending"], .array([entries[3]]))
    XCTAssertEqual(output["acknowledgedMissing"], .array([entries[2]]))
    XCTAssertThrowsError(try RecordManifest.execute(action: "merge", value: ["entries": .array(entries),
      "current": .array([]), "retainKeys": strings(["unknown"])]))
  }

  func testCLIKeepsOpaqueDataLiteralAndSupportsCommonPostprocess() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let data: JSONObject = ["entries": .array([entry("{{literal}}")]), "availableKeys": strings([])]
    let config: JSONObject = ["action": .string("partition"), "value": .string("{{request}}"),
      "postprocess": .array([.object(["pick": .string("/pending")])])]
    let result = await RielaCLIApplication().run(["node", "run", "riela/record-manifest", "--config",
      try JSONValue.object(config).compactJSONString(), "--variables", try JSONValue.object(["request": .object(data)]).compactJSONString(),
      "--output", "json"], environment: ["HOME": root.path, "PATH": ""])
    XCTAssertEqual(result.exitCode, .success, result.stdout + result.stderr)
    let output = try JSONDecoder().decode(NodeRunCommandResult.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(output.payload["pending"], data["entries"])
    XCTAssertEqual(output.payload["processed"], data["entries"])
  }

  func testOpaqueUnicodeIdentitiesVersionsAndContextCompareUTF8Bytes() throws {
    let composed = "\u{00E9}"
    let decomposed = "e\u{0301}"
    let entries = [entry(composed, version: composed), entry(decomposed, version: decomposed)]
    let output = try RecordManifest.execute(action: "partition", value: ["entries": .array(entries),
      "availableKeys": strings([]), "acknowledged": acks([(composed, decomposed)])])
    XCTAssertEqual(output["pending"], .array(entries))
    XCTAssertEqual(output["acknowledgedMissing"], .array([]))
    var value: JSONObject = ["entries": .array([entry("one")]), "requestedKeys": strings(["one"]),
      "returnedKeys": strings([]), "pendingKeys": strings(["one"]), "availableKeys": strings([]),
      "context": .string(composed), "expectedContext": .string(decomposed)]
    XCTAssertThrowsError(try RecordManifest.execute(action: "recover", value: value))
    value["context"] = .string(decomposed)
    XCTAssertNoThrow(try RecordManifest.execute(action: "recover", value: value))
  }

  private func acks(_ values: [(String, String)]) -> JSONValue {
    .array(values.map { .object(["key": .string($0.0), "version": .string($0.1)]) })
  }

  private func entry(_ key: String, version: String = "one") -> JSONValue {
    .object(["key": .string(key), "version": .string(version), "value": .object([
      "reference": .object(["key": .string("body:" + key), "revision": .string("original-version")]),
      "cursor": .string("{{opaque-frozen-cursor}}")])])
  }

  private func strings(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }

  private func recovery(_ entries: [JSONValue]) -> JSONObject {
    ["entries": .array(entries), "requestedKeys": strings((89..<131).map(String.init)),
      "returnedKeys": strings((89..<104).map(String.init)), "pendingKeys": strings((104..<131).map(String.init)),
      "attemptedKeys": strings((89..<104).map(String.init)), "deferredKeys": strings((104..<131).map(String.init)),
      "availableKeys": strings(((0..<77).map(String.init) + (89..<104).map(String.init))),
      "unavailableAcknowledgedKeys": strings((77..<89).map(String.init)),
      "acknowledged": acks((77..<89).map { (String($0), "one") }),
      "context": .object(["cursor": .string("{{opaque-original}}"), "window": .string("frozen")]),
      "expectedContext": .object(["cursor": .string("{{opaque-original}}"), "window": .string("frozen")])]
  }
}
