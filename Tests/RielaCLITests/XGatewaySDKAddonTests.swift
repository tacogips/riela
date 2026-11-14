import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class XGatewaySDKAddonTests: XCTestCase {
  func testOperationalUsageSurvivesJSONPostprocessing() async throws {
    let usage = #"""
    {
      "version": 1,
      "basis": "upstream-response",
      "billingStatus": "not-reported",
      "httpResponses": 1,
      "successfulResponses": 1,
      "unclassifiedResources": 0,
      "resources": [
        {
          "kind": "post",
          "idHash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "utcDay": "2026-10-24"
        }
      ]
    }
    """#
    let gateway = RecordingGatewayGraphQLRunner(response:
      "{\"data\":{\"homeTimeline\":{\"posts\":[{\"id\":\"1\"}]}},\"extensions\":{\"resourceUsage\":"
      + usage + ",\"usageCacheStatus\":\"stored\"}}")
    let output = try await BuiltinWorkflowAddonResolver(environment: [:], localGatewayGraphQLRunner: gateway.runner)
      .execute(.init(workflowId: "fixture", stepId: "read", nodeId: "read", addon: .init(name: "riela/x-gateway-reader", config: [
        "operation": .string("homeTimeline"), "selection": .array([.string("posts.id")]),
        "postprocess": .array([.object(["pick": .string("/data/homeTimeline/posts")])])])), context: .init())
    guard case let .object(namespace)? = output.payload["xGateway"],
          case let .object(observations)? = namespace["observations"] else { return XCTFail("usage metadata lost") }
    XCTAssertEqual(observations["usageCacheStatus"], .string("stored"))
    XCTAssertNotNil(observations["resourceUsage"])
    XCTAssertEqual(output.payload["processed"], .array([.object(["id": .string("1")])]))
  }
  func testSharedSelectionPathsBuildNestedXFields() throws {
    let document = try builtinGatewayXJSONDocument(.init(workflowId: "fixture", stepId: "read", nodeId: "read",
      addon: .init(name: "riela/x-gateway-reader", config: ["operation": .string("homeTimeline"),
        "arguments": .object(["maxResults": .integer(25)]),
        "selection": .array([.string("posts.id"), .string("posts.author.username"), .string("pageInfo.nextToken")])
      ])))
    XCTAssertEqual(document, "query { homeTimeline(maxResults: 25) { pageInfo { nextToken } posts { author { username } id } } }")
  }

  func testJSONOperationEscapesArgumentsOnceAndPostprocessesTypedRows() async throws {
    let gateway = RecordingGatewayGraphQLRunner(response:
      #"{"data":{"homeTimeline":{"posts":[{"id":"1","author":{"username":"alice"},"text":"{{secret}}"}],"pageInfo":{"nextToken":"cursor-2"}}}}"#)
    let cursor = "\" }) { deletePost } # {{secret}}"
    let output = try await BuiltinWorkflowAddonResolver(environment: [:], localGatewayGraphQLRunner: gateway.runner)
      .execute(.init(workflowId: "fixture", stepId: "read", nodeId: "read",
        addon: .init(name: "riela/x-gateway-reader", version: "1", config: [
          "operation": .string("homeTimeline"),
          "arguments": .object(["maxResults": .integer(25), "paginationToken": .string("{{input.cursor}}")]),
          "select": .object(["posts": .object(["id": .bool(true), "text": .bool(true),
            "author": .object(["username": .bool(true)])]), "pageInfo": .object(["nextToken": .bool(true)])]),
          "postprocess": .array([.object(["pick": .string("/data/homeTimeline/posts")]),
            .object(["map": .object(["id": .string("/id"), "speaker": .string("/author/username"),
              "text": .string("/text")])])])]),
        variables: ["secret": .string("must-not-expand")], resolvedInputPayload: ["cursor": .string(cursor)]),
        context: .init())
    let document = try XCTUnwrap(gateway.lastCall()?.document)
    XCTAssertTrue(document.contains(try JSONValue.string(cursor).compactJSONString()))
    XCTAssertTrue(document.contains("maxResults: 25"))
    XCTAssertFalse(document.contains("must-not-expand"))
    XCTAssertEqual(output.payload["processed"], .array([.object([
      "id": .string("1"), "speaker": .string("alice"), "text": .string("{{secret}}")])]))
    guard case let .object(data)? = output.payload["data"], case let .object(page)? = data["homeTimeline"] else {
      return XCTFail("pagination metadata must remain available")
    }
    XCTAssertEqual(page["pageInfo"], .object(["nextToken": .string("cursor-2")]))
  }

  func testJSONOperationRejectsAmbiguousOrExecutableNamesBeforeProvider() async throws {
    let valid: JSONObject = ["operation": .string("accountMe"), "select": .object(["id": .bool(true)])]
    let invalid: [JSONObject] = [
      valid.merging(["queryTemplate": .string("query { accountMe { id } }")]) { _, new in new },
      valid.merging(["operation": .string("accountMe { id } } mutation {")]) { _, new in new },
      valid.merging(["select": .object(["id @skip(if:true)": .bool(true)])]) { _, new in new },
      valid.merging(["select": .object(["id": .string("code")])]) { _, new in new },
      ["arguments": .object([:])],
      ["queryTemplate": .string("{ accountMe { id } }"), "selection": .array([.string("id")])]
    ]
    for config in invalid {
      let gateway = RecordingGatewayGraphQLRunner()
      do {
        _ = try await BuiltinWorkflowAddonResolver(environment: [:], localGatewayGraphQLRunner: gateway.runner)
          .execute(.init(workflowId: "fixture", stepId: "read", nodeId: "read",
            addon: .init(name: "riela/x-gateway-reader", config: config)), context: .init())
        XCTFail("invalid JSON mode accepted")
      } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidInput) }
      XCTAssertNil(gateway.lastCall())
    }
  }

  func testEmbeddedReaderUsesOnlyBoundCredentialsAndReturnsGraphQLData() async throws {
    let gateway = RecordingGatewayGraphQLRunner(response: #"{"data":{"accountMe":{"id":"42"}}}"#)
    let output = try await BuiltinWorkflowAddonResolver(environment: [
      "SYNTHETIC_X_TOKEN": "token-canary", "UNRELATED_PRIVATE": "must-not-forward"
    ], localGatewayGraphQLRunner: gateway.runner).execute(.init(workflowId: "fixture", stepId: "read", nodeId: "read",
      addon: .init(name: "riela/x-gateway-reader", version: "1",
        config: ["queryTemplate": .string("query { accountMe { {{field}} } }")],
        env: ["X_GW_TOKEN": .object(["fromEnv": .string("SYNTHETIC_X_TOKEN")])]),
      variables: ["field": .string("id")], resolvedInputPayload: [:]), context: .init())
    let call = try XCTUnwrap(gateway.lastCall())
    XCTAssertEqual(call.tier, "x-gateway-reader")
    XCTAssertEqual(call.document, "query { accountMe { id } }")
    XCTAssertNil(call.variablesJSON)
    XCTAssertEqual(call.environment["X_GW_TOKEN"], "token-canary")
    XCTAssertNil(call.environment["UNRELATED_PRIVATE"])
    XCTAssertEqual(output.payload["data"], .object(["accountMe": .object(["id": .string("42")])]))
    XCTAssertFalse(output.promptText.contains("token-canary"))
  }

  func testReaderRefusesMutationAndExpiredDeadlineBeforeCallingProvider() throws {
    XCTAssertThrowsError(try xGatewayReaderQuery(document: "mutation { deletePost(id: \"1\") { id } }",
      environment: [:], deadline: nil)) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
    }
    XCTAssertThrowsError(try xGatewayReaderQuery(document: "query { accountMe { id } }",
      environment: [:], deadline: Date().addingTimeInterval(-1))) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .timeout)
    }
  }

  func testReaderRefusesEnvironmentInjectionBeforeSDKInvocation() async throws {
    let gateway = RecordingGatewayGraphQLRunner()
    do {
      _ = try await BuiltinWorkflowAddonResolver(environment: [:], localGatewayGraphQLRunner: gateway.runner)
        .execute(.init(workflowId: "fixture", stepId: "read", nodeId: "read",
          addon: .init(name: "riela/x-gateway-reader", version: "1",
            config: ["queryTemplate": .string("query { accountMe { id } }")],
            env: ["PATH": .string("/untrusted")]), variables: [:], resolvedInputPayload: [:]), context: .init())
      XCTFail("environment injection must fail")
    } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked) }
    XCTAssertNil(gateway.lastCall())
  }
}
