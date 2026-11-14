import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class CacheExchangeAddonTests: XCTestCase {
  func testCLIPipeDataIsLiteralAndExchangeNeedsNoPython() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage: JSONValue = .object(["cacheId": .string("bodies"), "scope": .string("account"), "cacheRoot": .string(root.path)])
    let entries: JSONValue = .array([.object(["key": .string("one"),
      "fetchedAt": .string(ISO8601DateFormatter().string(from: Date().addingTimeInterval(-5))),
      "payload": .object(["text": .string("{{literal}} 日本語")])])])
    let config: JSONObject = ["action": .string("put"), "storage": storage, "entries": .string("{{body}}")]
    let result = await RielaCLIApplication().run(["node", "run", "riela/cache-exchange", "--config",
      try JSONValue.object(config).compactJSONString(), "--variables", try JSONValue.object(["body": entries]).compactJSONString(),
      "--output", "json"], environment: ["HOME": root.path, "PATH": ""])
    XCTAssertEqual(result.exitCode, .success, result.stdout + result.stderr)
    let output = try JSONDecoder().decode(NodeRunCommandResult.self, from: Data(result.stdout.utf8))
    guard case let .object(refs)? = output.payload["references"], let ref = refs["one"] else { return XCTFail("missing reference") }
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])
    let read = try await resolver.execute(.init(workflowId: "fixture", stepId: "read", nodeId: "read",
      addon: .init(name: "riela/cache-exchange", version: "1", config: ["action": .string("get"), "storage": storage,
        "references": .string("{{refs}}")]), variables: ["refs": .array([ref])]), context: .init())
    XCTAssertEqual(read.payload["hits"], .object(["one": .object(["text": .string("{{literal}} 日本語")])]))
  }
}
