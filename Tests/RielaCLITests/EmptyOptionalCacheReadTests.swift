import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class EmptyOptionalCacheReadTests: XCTestCase {
  func testImageOnlyOptionalContextCanReadZeroCitedStatusesThroughBuiltin() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])
    let storage: JSONObject = ["cacheId": .string("optional-context"), "scope": .string("x-analysis:123"), "cacheRoot": .string(root.path)]
    func input(_ name: String, _ fields: JSONObject) -> WorkflowAddonExecutionInput {
      .init(workflowId: "image-only-context", stepId: "read", nodeId: "read", addon: .init(name: name, version: "1",
        config: storage.merging(fields) { _, next in next }), variables: [:])
    }
    _ = try await resolver.execute(input("riela/cache-configure", ["ttlSeconds": .integer(3600), "maxBytes": .integer(10485760)]), context: .init())
    let result = try await resolver.execute(input("riela/cache-get", ["keys": .array([])]), context: .init())
    XCTAssertTrue(result.completionPassed)
    XCTAssertEqual(result.payload["results"], .array([]))
  }
}
