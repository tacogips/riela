import Foundation
import RielaCore
import XCTest
import XGatewayCore
@testable import RielaCLI

final class CollectionGatewayWorkflowTests: XCTestCase {
  func testRealSDKAcceptsInitialNullAndProjectsEmptyTerminalPage() throws {
    // No credentials: successful parsing must reach the authentication guard,
    // never a provider request. This uses the real pinned SDK, not a mock.
    let result = XGatewayCLI(commandName: "x-gateway-reader", surface: .read).run(arguments: [
      "graphql", "query", #"{ searchPosts(query: "from:kenn", maxResults: 25, nextToken: null) { posts { id } pageInfo { nextToken } } }"#,
      "--json"
    ], environment: [:])
    let failure = try JSONDecoder().decode(JSONObject.self, from: Data(result.stderr.utf8))
    guard case let .object(error)? = failure["error"] else { return XCTFail("missing SDK error") }
    XCTAssertEqual(error["code"], .string("AUTH_MISSING"))
    XCTAssertEqual(error["requestAttempts"], .integer(0))
    let page = try XGatewayResponseProjector.postPage(["meta": ["result_count": 0]])
    XCTAssertTrue((page["pageInfo"] as? [String: Any])?["nextToken"] is NSNull)
  }

  func testEmptyWindowCompletesAndDoesNotRepeatRead() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let transport = CollectionPageTransport(empty: true)
    let bundle = try FileSystemWorkflowBundleResolver().resolve(.init(workflowName: "x-window-checkpoint",
      scope: .direct, workflowDefinitionDir: repository.appendingPathComponent("examples").path, workingDirectory: root.path))
    for _ in 0..<2 {
      let resolver = BuiltinWorkflowAddonResolver(environment: ["X_GW_TOKEN": "synthetic-token"],
        workingDirectory: root, localGatewayGraphQLRunner: transport.runner)
      let result = try await DeterministicWorkflowRunner(addonResolver: resolver).run(.init(workflow: bundle.workflow,
        variables: ["accountScope": .string("fixture-account"), "authorHandle": .string("kenn"), "windowStart": .string("2026-10-24T00:00:00Z"),
                    "windowEnd": .string("2026-10-24T01:00:00Z")], maxSteps: 5))
      let output = try XCTUnwrap(result.rootOutput)
      XCTAssertEqual(output["revision"], .integer(1))
      XCTAssertEqual(output["acquisitionComplete"], .bool(true))
      XCTAssertEqual(output["pendingCount"], .integer(0))
    }
    XCTAssertEqual(transport.documents.count, 1)
  }

  func testSpecifiedAuthorResumesNativePagesAndCompletedWindowDoesNotCallAPI() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let transport = CollectionPageTransport()
    let bundle = try FileSystemWorkflowBundleResolver().resolve(.init(workflowName: "x-window-checkpoint",
      scope: .direct, workflowDefinitionDir: repository.appendingPathComponent("examples").path, workingDirectory: root.path))
    let variables: JSONObject = ["accountScope": .string("fixture-account"), "authorHandle": .string("kenn"), "windowStart": .string("2026-10-24T00:00:00Z"),
      "windowEnd": .string("2026-10-24T01:00:00Z")]
    for expectedRevision in [1, 2, 2] {
      let resolver = BuiltinWorkflowAddonResolver(environment: [
        "X_GW_TOKEN": "synthetic-token", "RIELA_CACHE_ROOT": root.appendingPathComponent("cache").path
      ], workingDirectory: root, localGatewayGraphQLRunner: transport.runner)
      let result = try await DeterministicWorkflowRunner(addonResolver: resolver).run(.init(
        workflow: bundle.workflow, variables: variables, maxSteps: 5))
      XCTAssertEqual(result.status, .completed)
      let output = try XCTUnwrap(result.rootOutput)
      XCTAssertEqual(output["revision"], .integer(Int64(expectedRevision)))
      XCTAssertEqual(output["pendingCount"], .integer(Int64(expectedRevision)))
      XCTAssertEqual(output["acquisitionComplete"], .bool(expectedRevision == 2))
      XCTAssertEqual(output["processingComplete"], .bool(false))
    }
    let calls = transport.documents
    XCTAssertEqual(calls.count, 2, "the third execution must skip the paid API")
    XCTAssertTrue(calls.allSatisfy { $0.contains("searchPosts(") && $0.contains("from:kenn") })
    XCTAssertFalse(calls.contains { $0.contains("homeTimeline") || $0.contains("followingTimeline") })
    XCTAssertFalse(calls[0].contains("next-page"))
    XCTAssertTrue(calls[1].contains("next-page"))
  }
}

private final class CollectionPageTransport: @unchecked Sendable {
  private let lock = NSLock()
  private var calls: [String] = []
  private let empty: Bool
  init(empty: Bool = false) { self.empty = empty }
  var documents: [String] { lock.withLock { calls } }

  var runner: LocalGatewayGraphQLRunner {
    { [self] _, document, _, _ in
      let page = lock.withLock {
        calls.append(document)
        return calls.count
      }
      let id = page == 1 ? "100" : "99"
      var raw: [String: Any] = ["data": [["id": id, "text": "fixture", "created_at": "2026-10-24T00:30:00Z", "author_id": "7"]],
        "includes": ["users": [["id": "7", "username": "kenn", "name": "Kenn"]]]]
      if page == 1 { raw["meta"] = ["next_token": "next-page"] }
      if empty { raw = ["meta": ["result_count": 0]] }
      let projected = try XGatewayResponseProjector.postPage(raw)
      guard let response = String(data: try JSONSerialization.data(withJSONObject: ["data": ["searchPosts": projected]]), encoding: .utf8) else {
        throw AdapterExecutionError(.invalidOutput, "invalid fixture encoding")
      }
      return response
    }
  }
}
