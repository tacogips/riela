import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class XDigestAddonTests: XCTestCase {
  func testXDigestAddonNormalizesValidatesAndPersistsCursorState() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-x-digest-addon-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let stateFile = root.appendingPathComponent("state.json").path
    try Data(#"{"lastPostId":"100"}"#.utf8).write(to: URL(fileURLWithPath: stateFile))

    let resolver = BuiltinWorkflowAddonResolver(environment: [:])
    let readOutput = try await resolver.execute(
      xDigestInput(
        operation: "read-state",
        variables: [
          "nowIso": .string("2026-06-23T04:00:00Z"),
          "workflowInput": .object([
            "stateFile": .string(stateFile),
            "accountUsername": .string("@source_bot")
          ])
        ]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(readOutput.payload["sinceId"], .string("100"))
    XCTAssertEqual(readOutput.payload["accountUsernameBare"], .string("source_bot"))
    XCTAssertEqual(readOutput.payload["windowStartIso"], .string("2026-06-23T03:00:00Z"))

    let gatewayPayload: JSONObject = [
      "xGateway": .object([
        "data": .object([
          "data": .object([
            "followingTimeline": .object([
              "posts": .array([
                .object(post(id: "102", text: "AI product launch", username: "alice", views: 42)),
                .object(post(id: "101", text: "AI market update", username: "carol", views: nil)),
                .object(post(id: "99", text: "old post", username: "bob", views: 100))
              ]),
              "pageInfo": .object(["resultCount": .number(3)])
            ])
          ])
        ])
      ])
    ]
    let normalizeOutput = try await resolver.execute(
      xDigestInput(
        operation: "normalize-fetched-posts",
        resolvedInputPayload: upstreamPayloads([
          readOutput.payload,
          gatewayPayload
        ]),
        variables: ["nowIso": .string("2026-06-23T04:00:00Z")]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(normalizeOutput.payload["fetchedPostCount"], .number(3))
    XCTAssertEqual(normalizeOutput.payload["selectedPostCount"], .number(2))
    XCTAssertEqual(normalizeOutput.payload["maxFetchedPostId"], .string("102"))

    let summaryPayload: JSONObject = [
      "shouldSendTelegram": .bool(true),
      "topicDigests": .array([
        .object([
          "topic": .string("AI launch"),
          "summary": .string("A launch gained traction."),
          "reason": .string("AI/business relevant"),
          "sourcePostIds": .array([.string("102"), .string("missing")])
        ])
      ])
    ]
    let validateOutput = try await resolver.execute(
      xDigestInput(
        operation: "validate-summary-output",
        resolvedInputPayload: upstreamPayloads([
          normalizeOutput.payload,
          summaryPayload
        ])
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(validateOutput.when["should_send_telegram"], true)
    XCTAssertEqual(validateOutput.payload["maxFetchedPostId"], .string("102"))
    XCTAssertEqual(validateOutput.payload["droppedInvalidSourcePostIdCount"], .number(1))
    XCTAssertTrue((string(validateOutput.payload["replyText"]) ?? "").contains("https://x.com/alice/status/102"))

    let persistOutput = try await resolver.execute(
      xDigestInput(
        operation: "persist-state",
        resolvedInputPayload: upstreamPayloads([validateOutput.payload]),
        variables: [
          "nowIso": .string("2026-06-23T04:05:00Z"),
          "workflowInput": .object(["stateFile": .string(stateFile)])
        ]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(persistOutput.when["should_send_telegram"], true)
    XCTAssertEqual(persistOutput.payload["persisted"], .bool(true))
    let persisted = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: stateFile)))
    guard case let .object(state) = persisted else {
      return XCTFail("persisted state was not an object")
    }
    XCTAssertEqual(state["lastPostId"], .string("102"))
    XCTAssertEqual(state["updatedAt"], .string("2026-06-23T04:05:00Z"))
    XCTAssertEqual(state["retainedTopicCount"], .number(1))
  }

  func testXDigestAddonRejectsPublicStateFilePath() async throws {
    do {
      _ = try await BuiltinWorkflowAddonResolver(environment: [:]).execute(
        xDigestInput(
          operation: "read-state",
          variables: [
            "workflowInput": .object(["stateFile": .string("state.json")])
          ]
        ),
        context: AdapterExecutionContext()
      )
      XCTFail("expected public state path to be rejected")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("ignored/private runtime path"))
    }
  }

  private func xDigestInput(
    operation: String,
    resolvedInputPayload: JSONObject = [:],
    variables: JSONObject = [:]
  ) -> WorkflowAddonExecutionInput {
    WorkflowAddonExecutionInput(
      workflowId: "x-follower-ai-business-digest",
      stepId: operation,
      nodeId: operation,
      addon: WorkflowNodeAddonRef(
        name: "riela/x-digest",
        version: "1",
        config: ["operation": .string(operation)]
      ),
      variables: variables,
      resolvedInputPayload: resolvedInputPayload
    )
  }

  private func upstreamPayloads(_ payloads: [JSONObject]) -> JSONObject {
    [
      "upstream": .array(payloads.map { payload in
        .object([
          "output": .object([
            "payload": .object(payload)
          ])
        ])
      })
    ]
  }

  private func post(id: String, text: String, username: String, views: Double?) -> JSONObject {
    [
      "id": .string(id),
      "text": .string(text),
      "createdAt": .string("2026-06-23T03:30:00Z"),
      "author": .object([
        "username": .string(username),
        "name": .string(username.capitalized)
      ]),
      "metrics": .object([
        "impressionCount": views.map(JSONValue.number) ?? .null,
        "likeCount": .number(1),
        "replyCount": .number(0),
        "repostCount": .number(0),
        "quoteCount": .number(0),
        "bookmarkCount": .number(0)
      ]),
      "referencedPosts": .array([])
    ]
  }

  private func string(_ value: JSONValue?) -> String? {
    guard case let .string(value)? = value else {
      return nil
    }
    return value
  }
}
