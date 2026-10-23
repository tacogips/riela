import Foundation
import KaibaClient
import RielaCore
import XCTest
@testable import RielaCLI
@testable import RielaKaibaAddons

final class KaibaGatewayPostprocessTests: XCTestCase {
  func testStructuredArgumentsAndPostprocessShareResolverWithoutRepeatingRequest() async throws {
    let transport = KaibaPostprocessTransport()
    let client = try KaibaClient(endpoint: URL(string: "http://127.0.0.1:8787/graphql")!,
      authentication: .unauthenticated, transport: transport)
    let input = WorkflowAddonExecutionInput(workflowId: "fixture", stepId: "fetch", nodeId: "fetch",
      addon: .init(name: "kaiba/note-graphql-document", config: [
        "arguments": .object(["query": .string("query Fixture { items { id text } cursor }")]),
        "postprocess": .array([
          .object(["pick": .string("/body/data/items")]),
          .object(["map": .object(["id": .string("/id"), "text": .string("/text")])])
        ])
      ]))
    let output = try await KaibaAddonExecutionContext.withMockExecutionForTesting(client: client) {
      try await BuiltinWorkflowAddonResolver(environment: [:]).execute(input, context: .init())
    }
    XCTAssertEqual(output.when["postprocessPassed"], true)
    XCTAssertEqual(output.payload["processed"], .array([.object(["id": .string("1"), "text": .string("{{secret}}")])]))
    guard case let .object(body)? = output.payload["body"], case let .object(data)? = body["data"] else {
      return XCTFail("original provider result must remain available")
    }
    XCTAssertEqual(data["cursor"], .string("page2"))
    XCTAssertEqual(transport.requestCount, 1)
  }
}

private final class KaibaPostprocessTransport: KaibaHTTPTransporting, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var requestCount: Int { lock.withLock { count } }

  func send(_ request: KaibaHTTPRequest, maximumResponseBytes: Int) async throws -> KaibaHTTPResponse {
    lock.withLock { count += 1 }
    return .init(statusCode: 200, body: Data(#"{"data":{"items":[{"id":"1","text":"{{secret}}"}],"cursor":"page2"}}"#.utf8))
  }
}
