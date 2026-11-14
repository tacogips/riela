import Foundation
import GatewaySDKKit
import RielaCore
import XCTest
@testable import RielaCLI

// The verification plan pins this test class name.
// swiftlint:disable:next type_name
final class NotionGatewayAddonRetryClassificationTests: XCTestCase {
  private func envelope(_ status: Int, _ code: String, _ diagnostic: String = "") -> String {
    let suffix = diagnostic.isEmpty ? "" : " [notionDiagnostics \(diagnostic)]"
    return #"{"data":null,"errors":[{"message":"failure\#(suffix)","code":"\#(code)","extensions":{"httpStatus":\#(status)}}]}"#
  }

  private func input(_ name: String = "riela/notion-gateway-write", operation: String,
                     arguments: JSONObject) -> WorkflowAddonExecutionInput {
    WorkflowAddonExecutionInput(workflowId: "test", stepId: "step", nodeId: "node",
      addon: WorkflowNodeAddonRef(name: name, version: "1", config: ["operation": .string(operation),
        "arguments": .object(arguments)]), resolvedInputPayload: [:])
  }

  private func execute(_ input: WorkflowAddonExecutionInput, responses: [String]) async throws -> AdapterExecutionError {
    let recorder = RecordingGatewayGraphQLRunner(responses: responses)
    do {
      _ = try await BuiltinWorkflowAddonResolver(localGatewayGraphQLRunner: recorder.runner).execute(input, context: .init())
      XCTFail("expected gateway failure")
      return AdapterExecutionError(.invalidOutput, "missing failure")
    } catch let error as AdapterExecutionError { return error }
  }

  func testMutationClassificationPrecedenceAndPermanentFailures() {
    for status in [429, 409, 500] {
      let error = NotionGatewayFailureClassifier.classify(stdout: envelope(status, "rate_limited", "mutationOutcome=unknown"),
        isMutation: true, message: "unchanged")
      XCTAssertEqual(error.effectOutcome, .unknown)
      XCTAssertEqual(error.isRetryable, false)
      XCTAssertEqual(error.message, "unchanged")
    }
    let transport = NotionGatewayFailureClassifier.classify(stdout: envelope(502, "TRANSPORT", "mutationOutcome=unknown"),
      isMutation: true, message: "transport")
    XCTAssertEqual(transport.effectOutcome, .unknown)
    for text in [envelope(429, "rate_limited"), "not json"] {
      let error = NotionGatewayFailureClassifier.classify(stdout: text, isMutation: true, message: "same")
      XCTAssertEqual(error.effectOutcome, .unknown)
      XCTAssertEqual(error.isRetryable, false)
    }
    for (status, code, outcome) in [(400, "validation_error", "rejected"), (401, "unauthorized", "rejected"),
                                     (401, "AUTHENTICATION_REQUIRED", "notDispatched")] {
      let error = NotionGatewayFailureClassifier.classify(stdout: envelope(status, code, "mutationOutcome=\(outcome)"),
        isMutation: true, message: "same")
      XCTAssertEqual(error.effectOutcome?.rawValue, outcome)
      XCTAssertEqual(error.isRetryable, false)
    }
    for seconds in [3, 120] {
      let error = NotionGatewayFailureClassifier.classify(stdout: envelope(429, "rate_limited",
        "mutationOutcome=rejected retryAfterSeconds=\(seconds)"), isMutation: true, message: "same")
      XCTAssertEqual(error.effectOutcome, .rejected)
      XCTAssertEqual(error.isRetryable, true)
      XCTAssertEqual(error.retryAfter, .seconds(seconds))
    }
    let conflict = NotionGatewayFailureClassifier.classify(stdout: envelope(409, "conflict_error", "mutationOutcome=rejected"),
      isMutation: true, message: "same")
    XCTAssertEqual(conflict.isRetryable, true)
  }

  func testReadsAndExplicitUnknownAcrossMultipleErrors() {
    for (status, retryable) in [(503, true), (404, false)] {
      let error = NotionGatewayFailureClassifier.classify(stdout: envelope(status, "error"), isMutation: false, message: "read")
      XCTAssertEqual(error.isRetryable, retryable)
      XCTAssertNil(error.effectOutcome)
      XCTAssertEqual(error.message, "read")
    }
    let stdout = #"{"errors":[{"message":"first","extensions":{"httpStatus":503}},{"message":"later [notionDiagnostics mutationOutcome=unknown]"}]}"#
    let error = NotionGatewayFailureClassifier.classify(stdout: stdout, isMutation: false, message: "read")
    XCTAssertEqual(error.effectOutcome, .unknown)
    XCTAssertEqual(error.isRetryable, false)
  }

  func testMutationDetectionFailSafe() {
    XCTAssertFalse(NotionGatewayFailureClassifier.isMutation(tier: "reader", operationKind: nil, isJSONOperationMode: false, document: "mutation{x}"))
    XCTAssertFalse(NotionGatewayFailureClassifier.isMutation(tier: "writer", operationKind: nil, isJSONOperationMode: false, document: "  # c\n# d\n{ x }"))
    XCTAssertFalse(NotionGatewayFailureClassifier.isMutation(tier: "writer", operationKind: nil, isJSONOperationMode: false, document: "query{findChildPage}") )
    for document in ["", "subscription{x}", "# save\nmutation{createPage}"] {
      XCTAssertTrue(NotionGatewayFailureClassifier.isMutation(tier: "writer", operationKind: nil, isJSONOperationMode: false, document: document))
    }
    XCTAssertTrue(NotionGatewayFailureClassifier.isMutation(tier: "writer", operationKind: nil, isJSONOperationMode: true, document: "query{x}"))
    XCTAssertTrue(NotionGatewayFailureClassifier.isMutation(tier: "writer", operationKind: .command, isJSONOperationMode: true, document: ""))
    XCTAssertFalse(NotionGatewayFailureClassifier.isMutation(tier: "writer", operationKind: .query, isJSONOperationMode: true, document: ""))
  }

  func testGatewayOperationClassification() async throws {
    let parent: JSONObject = ["parentId": .string("p"), "title": .string("t")]
    for status in [429, 409] {
      let error = try await execute(input(operation: "ensurePagePath", arguments: ["parentId": .string("p"), "titles": .array([.string("a")])]),
        responses: [envelope(status, "rate_limited", "mutationOutcome=unknown")])
      XCTAssertEqual(error.effectOutcome, .unknown)
      XCTAssertEqual(error.isRetryable, false)
      let rejected = try await execute(input(operation: "createPage", arguments: parent),
        responses: [envelope(status, status == 429 ? "rate_limited" : "conflict_error", "mutationOutcome=rejected retryAfterSeconds=3")])
      XCTAssertEqual(rejected.effectOutcome, .rejected)
      XCTAssertEqual(rejected.isRetryable, true)
      XCTAssertEqual(rejected.retryAfter, .seconds(3))
      XCTAssertEqual(rejected.message, "riela/notion-gateway-write GraphQL errors: failure [notionDiagnostics mutationOutcome=rejected retryAfterSeconds=3] extensions={\"httpStatus\":\(status)}")
    }
    let read = try await execute(input("riela/notion-gateway-read", operation: "findChildPage", arguments: parent),
      responses: [envelope(503, "error")])
    XCTAssertEqual(read.isRetryable, true)
    XCTAssertNil(read.effectOutcome)
    XCTAssertEqual(read.message, "riela/notion-gateway-read GraphQL errors: failure extensions={\"httpStatus\":503}")
  }

  func testRawDocumentModes() async throws {
    for (document, response, expectedOutcome, expectedRetry) in [
      ("# save\nmutation{createPage}", envelope(502, "TRANSPORT", "mutationOutcome=unknown"),
       AdapterEffectOutcome.unknown as AdapterEffectOutcome?, false),
      ("query{findChildPage}", envelope(503, "error"), nil, true)
    ] {
      let addon = WorkflowNodeAddonRef(name: "riela/notion-gateway-write", version: "1",
        config: ["queryTemplate": .string(document)])
      let request = WorkflowAddonExecutionInput(workflowId: "test", stepId: "step", nodeId: "node",
        addon: addon, resolvedInputPayload: [:])
      let error = try await execute(request, responses: [response])
      XCTAssertEqual(error.effectOutcome, expectedOutcome)
      XCTAssertEqual(error.isRetryable, expectedRetry)
    }
    let error = try await execute(input("riela/notion-gateway-read", operation: "findChildPage",
      arguments: ["parentId": .string("p"), "title": .string("t")]), responses: [envelope(404, "error")])
    XCTAssertEqual(error.isRetryable, false)
    XCTAssertNil(error.effectOutcome)
  }

  func testPublishTaintAndExemptions() async throws {
    let rejected = envelope(429, "rate_limited", "mutationOutcome=rejected retryAfterSeconds=3")
    let blocks: [JSONValue] = (0..<101).map { .object(["type": .string("paragraph"), "paragraph": .object(["n": .integer(Int64($0))])]) }
    let create = #"{"data":{"createPage":{"id":"page-1","url":"u"}}}"#
    let tainted = try await execute(input(operation: "publishPage", arguments: ["parentId": .string("p"), "title": .string("t"), "children": .array(blocks)]), responses: [create, rejected])
    XCTAssertTrue(tainted.message.hasPrefix("publishPage incomplete:"))
    XCTAssertTrue(tainted.message.contains("\"pageId\":\"page-1\""))
    XCTAssertEqual(tainted.effectOutcome, .unknown)
    XCTAssertEqual(tainted.isRetryable, false)
    let existing = try await execute(input(operation: "publishPage", arguments: ["pageId": .string("page-1"), "children": .array([blocks[0]])]), responses: [rejected])
    XCTAssertTrue(existing.message.hasPrefix("publishPage incomplete:"))
    XCTAssertEqual(existing.effectOutcome, .rejected)
    XCTAssertEqual(existing.isRetryable, true)
    let pathInput = input(operation: "publishPage", arguments: ["parentId": .string("p"), "title": .string("t"),
      "path": .array([.string("a")]), "children": .array([])])
    let path = try await execute(pathInput, responses: [#"{"data":{"ensurePagePath":{"id":"folder"}}}"#, rejected])
    XCTAssertEqual(path.effectOutcome, .rejected)
    XCTAssertEqual(path.isRetryable, true)
    XCTAssertFalse(path.message.hasPrefix("publishPage incomplete:"))
  }

  func testMalformedGatewayMutationRetainsMessageAndUnknownOutcome() async throws {
    let request = input(operation: "createPage", arguments: ["parentId": .string("p"), "title": .string("t")])
    let error = try await execute(request, responses: ["not json"])
    let original: AdapterExecutionError
    do {
      _ = try AppleGatewayGraphQLEnvelope(stdout: "not json", addonName: "riela/notion-gateway-write")
      throw AdapterExecutionError(.invalidOutput, "unexpected success")
    } catch let parsing as AdapterExecutionError { original = parsing }
    XCTAssertEqual(error.message, original.message)
    XCTAssertEqual(error.code, original.code)
    XCTAssertEqual(error.effectOutcome, .unknown)
    XCTAssertEqual(error.isRetryable, false)
    let publish = input(operation: "publishPage", arguments: ["parentId": .string("p"), "title": .string("t"),
      "children": .array([])])
    let publishError = try await execute(publish, responses: ["not json"])
    XCTAssertEqual(publishError.effectOutcome, .unknown)
    XCTAssertEqual(publishError.isRetryable, false)
  }

  func testContextDeadlineBeforeAndAfterDispatch() async throws {
    let request = input(operation: "createPage", arguments: ["parentId": .string("p"), "title": .string("t")])
    let recorder = RecordingGatewayGraphQLRunner(response: "not used")
    let resolver = BuiltinWorkflowAddonResolver(localGatewayGraphQLRunner: recorder.runner)
    do {
      _ = try await resolver.execute(request, context: .init(deadline: Date().addingTimeInterval(-1)))
      XCTFail("expected timeout")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .timeout)
      XCTAssertEqual(error.effectOutcome, .notDispatched)
      XCTAssertEqual(error.isRetryable, true)
      XCTAssertTrue(recorder.allCalls().isEmpty)
    }
    let blocking: LocalGatewayGraphQLRunner = { _, _, _, _ in
      for await _ in AsyncStream<Void>(Void.self, bufferingPolicy: .bufferingNewest(1), { _ in }) {}
      return ""
    }
    do {
      _ = try await BuiltinWorkflowAddonResolver(localGatewayGraphQLRunner: blocking)
        .execute(request, context: .init(deadline: Date().addingTimeInterval(0.15)))
      XCTFail("expected timeout")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .timeout)
      XCTAssertEqual(error.effectOutcome, .unknown)
      XCTAssertEqual(error.isRetryable, false)
    }
  }

  func testDeadlineBeforeAndAfterDispatch() async throws {
    do {
      _ = try await notionRunWithDeadline(deadline: Date().addingTimeInterval(-1), addonName: "test", isMutation: true) {
        XCTFail("operation must not start")
        return ""
      }
      XCTFail("expected timeout")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .timeout)
      XCTAssertEqual(error.effectOutcome, .notDispatched)
      XCTAssertEqual(error.isRetryable, true)
    }
    do {
      _ = try await notionRunWithDeadline(deadline: Date().addingTimeInterval(0.1), addonName: "test", isMutation: true) {
        for await _ in AsyncStream<Void>(Void.self, bufferingPolicy: .bufferingNewest(1), { _ in }) {}
        return ""
      }
      XCTFail("expected timeout")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .timeout)
      XCTAssertEqual(error.effectOutcome, .unknown)
      XCTAssertEqual(error.isRetryable, false)
    }
  }
}
