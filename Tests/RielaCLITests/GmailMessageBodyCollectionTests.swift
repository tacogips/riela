import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class GmailMessageBodyCollectionTests: XCTestCase {
  func testExactLookupUsesNativeGatewayAndNeverListsThreads() async throws {
    let calls = GmailBodyCalls()
    let profile = self.profile; let original = body("message-a")
    let resolver = BuiltinWorkflowAddonResolver(environment: [:], localGatewayGraphQLRunner: { _, document, variablesJSON, _ in
      let operation = document.contains("profile(") ? "profile" : "messageBodyBytes"
      calls.append(operation)
      if operation == "messageBodyBytes" {
        let arguments = try JSONDecoder().decode(JSONObject.self, from: Data((variablesJSON ?? "{}").utf8))
        XCTAssertEqual(arguments["messageId"], .string("message-a"))
        XCTAssertTrue(document.contains("providerDeclaredByteCount"))
        XCTAssertFalse(document.contains("threads("))
      }
      let result = operation == "profile" ? profile : original
      return try JSONValue.object(["data": .object([operation: .object(result)])]).compactJSONString()
    })
    var values = options(["message-a"]); values["providerBodyMetadata"] = .bool(true)
    let input = WorkflowAddonExecutionInput(workflowId: "body-lookup", stepId: "collect", nodeId: "collect",
      addon: .init(name: "riela/gmail-collect", version: "1", config: ["options": .object(values),
        "context": .string("{{opaque}}")]), variables: ["opaque": .string("{{literal}}")])
    let output = try await resolver.execute(input, context: .init())
    XCTAssertEqual(calls.values, ["profile", "messageBodyBytes"])
    XCTAssertEqual(output.payload["bodies"], .array([.object(body("message-a"))]))
    XCTAssertEqual(output.payload["context"], .string("{{literal}}"))
    XCTAssertEqual(output.payload["complete"], .bool(true))
    XCTAssertNil(output.payload["checkpoint"], "body lookup must not advance the normal mailbox cursor")
  }

  func testOneFailureDoesNotBlockOtherBodiesAndMaximumRetainsExactPendingIDs() async throws {
    var values = options(["bad", "good", "later"]); values["maxMessages"] = .integer(2)
    let result = try await GmailMessageBodyCollector(options: .init(values)).collect { operation, args, _ in
      if operation == "profile" { return self.profile }
      if args["messageId"] == .string("bad") { throw gmailCollectionInvalid() }
      return self.body("good")
    }
    XCTAssertEqual(result["bodies"], .array([.object(body("good"))]))
    XCTAssertEqual(result["failures"], .array([.object(["messageId": .string("bad"), "code": .string("acquisition-unavailable")])]))
    XCTAssertEqual(result["pendingMessageIds"], .array([.string("later")]))
    XCTAssertEqual(result["requestCount"], .integer(3))
    XCTAssertEqual(result["complete"], .bool(false))
  }

  func testWrongMailboxStopsBeforeAnyBodyRead() async throws {
    var calls = 0
    do {
      _ = try await GmailMessageBodyCollector(options: .init(options(["a"]))).collect { operation, _, _ in
        calls += 1; XCTAssertEqual(operation, "profile")
        return ["emailAddress": .string("other@example.test")]
      }
      XCTFail("accepted a different mailbox")
    } catch { XCTAssertEqual(calls, 1) }
  }

  func testBindingAndIncompleteResponsesFailIndividually() async throws {
    let result = try await GmailMessageBodyCollector(options: .init(options(["wrong", "incomplete", "good"])))
      .collect { operation, args, _ in
        if operation == "profile" { return self.profile }
        var value = self.body("good")
        if args["messageId"] == .string("incomplete") { value["complete"] = .bool(false) }
        return value
      }
    XCTAssertEqual(result["bodies"], .array([.object(body("good"))]))
    guard case let .array(failures)? = result["failures"] else { return XCTFail("missing failures") }
    XCTAssertEqual(failures.count, 2)
    XCTAssertEqual(result["complete"], .bool(true), "complete means every ID attempted, not all bodies succeeded")
  }

  func testByteBudgetReturnsAcceptedPrefixAndLeavesOverflowPending() async throws {
    let result = try await GmailMessageBodyCollector(options: .init(options(["a", "b", "c"])), outputByteBudget: 70_000)
      .collect { operation, args, _ in
        if operation == "profile" { return self.profile }
        if args["messageId"] == .string("a") { return self.body("a") }
        var value = self.body("b"); value["parts"] = .array([.object(["dataBase64": .string(String(repeating: "x", count: 10_000))])])
        return value
      }
    XCTAssertEqual(result["bodies"], .array([.object(body("a"))]))
    XCTAssertEqual(result["pendingMessageIds"], .array([.string("b"), .string("c")]))
    XCTAssertEqual(result["failures"], .array([]))
    XCTAssertEqual(result["attemptCount"], .integer(2))
  }

  func testDeadlineAndCancellationDoNotAcknowledgeUnattemptedBodies() async throws {
    var instant = Date(timeIntervalSince1970: 1_000)
    let result = try await GmailMessageBodyCollector(options: .init(options(["a", "b"])),
      deadline: instant.addingTimeInterval(1), clock: { instant }).collect { operation, _, _ in
        if operation == "profile" { return self.profile }
        instant = instant.addingTimeInterval(2); return self.body("a")
      }
    XCTAssertEqual(result["pendingMessageIds"], .array([.string("b")]))
    do {
      _ = try await GmailMessageBodyCollector(options: .init(options(["a"]))).collect { operation, _, _ in
        if operation == "profile" { return self.profile }
        throw CancellationError()
      }
      XCTFail("cancellation became a terminal body failure")
    } catch is CancellationError {} catch { XCTFail("unexpected error") }
  }

  func testInvalidLookupOptionsFailBeforeProviderDispatch() throws {
    for key in ["queries", "previous", "window"] {
      var values = options(["a"]); values[key] = .string("unsupported")
      XCTAssertThrowsError(try GmailMessageBodyOptions(values))
    }
    for ids in [[], ["a", "a"], ["bad/id"], Array(repeating: "a", count: 129)] {
      XCTAssertThrowsError(try GmailMessageBodyOptions(options(ids)))
    }
    var values = options(["a"]); values["expectedMailboxHash"] = .string("invalid")
    XCTAssertThrowsError(try GmailMessageBodyOptions(values))
  }

  func testIntervalWaitExhaustionLeavesUndispatchedIDPending() async throws {
    var instant = Date(timeIntervalSince1970: 1_000)
    var values = options(["a"]); values["minRequestIntervalSeconds"] = .integer(1)
    let result = try await GmailMessageBodyCollector(options: .init(values),
      deadline: instant.addingTimeInterval(2), clock: { instant }, wait: { _ in
        instant = instant.addingTimeInterval(3)
      }).collect { operation, _, _ in
        XCTAssertEqual(operation, "profile", "no body read is dispatched after the interval exhausts the budget")
        return self.profile
      }
    XCTAssertEqual(result["attemptCount"], .integer(0))
    XCTAssertEqual(result["pendingMessageIds"], .array([.string("a")]))
    XCTAssertEqual(result["failures"], .array([]))
  }

  func testCancellationAfterSDKReturnOrNormalizedErrorAlwaysPropagates() async throws {
    let values = options(["a"]); let profile = self.profile; let original = body("a")
    for normalizedError in [false, true] {
      let cancelled = try await Task {
        do {
          _ = try await GmailMessageBodyCollector(options: .init(values)).collect { operation, _, _ in
            if operation == "profile" { return profile }
            withUnsafeCurrentTask { $0?.cancel() }
            if normalizedError { throw AdapterExecutionError(.timeout, "synthetic cancelled SDK") }
            return original
          }
          return false
        } catch is CancellationError { return true }
      }.value
      XCTAssertTrue(cancelled)
    }
  }

  func testBodyTooLargeForEmptyFrameDoesNotBlockSmallPeer() async throws {
    let result = try await GmailMessageBodyCollector(options: .init(options(["large", "small"])), outputByteBudget: 70_000)
      .collect { operation, args, _ in
        if operation == "profile" { return self.profile }
        if args["messageId"] == .string("small") { return self.body("small") }
        var value = self.body("large")
        value["parts"] = .array([.object(["dataBase64": .string(String(repeating: "x", count: 10_000))])])
        return value
      }
    XCTAssertEqual(result["bodies"], .array([.object(body("small"))]))
    XCTAssertEqual(result["failures"], .array([.object(["messageId": .string("large"), "code": .string("body-frame-too-large")])]))
    XCTAssertEqual(result["pendingMessageIds"], .array([]))
    XCTAssertEqual(result["complete"], .bool(true))
  }

  private var profile: JSONObject { ["emailAddress": .string("owner@example.test")] }
  private func options(_ ids: [String]) -> JSONObject {
    ["mode": .string("message-bodies"), "accountId": .string("personal"),
      "expectedMailboxHash": .string(String(JSONCanonical.sha256Hex(Data("owner@example.test".utf8)).prefix(24))),
      "messageIds": .array(ids.map(JSONValue.string)), "minRequestIntervalSeconds": .integer(0)]
  }
  private func body(_ id: String) -> JSONObject {
    ["accountId": .string("personal"), "messageId": .string(id), "complete": .bool(true), "byteCount": .integer(0), "parts": .array([])]
  }
}

private final class GmailBodyCalls: @unchecked Sendable {
  private let lock = NSLock()
  private var calls: [String] = []
  var values: [String] { lock.withLock { calls } }
  func append(_ operation: String) { lock.withLock { calls.append(operation) } }
}
