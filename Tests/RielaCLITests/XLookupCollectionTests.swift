import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class XLookupCollectionTests: XCTestCase {
  func testSDKLookupKeepsMissingAndDeferredIDsWithoutSearching() async throws {
    var documents: [String] = []
    let transport = XLookupTransport { document in
      documents.append(document)
      if document.contains("accountMe") { return ["data": .object(["accountMe": .object(["id": .string("7"), "username": .string("owner")])])] }
      XCTAssertTrue(document.contains("posts(ids:")); XCTAssertFalse(document.contains("searchPosts")); XCTAssertFalse(document.contains("homeTimeline"))
      XCTAssertFalse(document.contains("103")); XCTAssertTrue(document.contains("quote")); XCTAssertTrue(document.contains("urlEntities"))
      return ["data": .object(["posts": .object(["posts": .array([.object(self.post("101"))])])])]
    }
    var values = options(); values["ids"] = .array(["101", "102", "103"].map(JSONValue.string)); values["maxPosts"] = .integer(2)
    values["includeStatusLinks"] = .bool(true)
    let output = try await BuiltinWorkflowAddonResolver(environment: [:], localGatewayGraphQLRunner: transport.runner)
      .execute(input(values), context: .init()).payload
    XCTAssertEqual(documents.count, 2)
    XCTAssertEqual(output["returnedIds"], .array([.string("101")]))
    XCTAssertEqual(output["requestedIds"], .array([.string("101"), .string("102")]))
    XCTAssertEqual(output["pendingIds"], .array([.string("102"), .string("103")]))
    XCTAssertEqual(output["deferredIds"], .array([.string("103")]))
    XCTAssertEqual(output["complete"], .bool(false))
    XCTAssertEqual(output["context"], .object(["literal": .string("{{data}}")]))
    XCTAssertNil(output["checkpoint"])
  }

  func testAccountMismatchStopsBeforePaidLookupAndEmptySetMakesNoCalls() async throws {
    var calls = 0
    do { _ = try await XLookupCollection(options()).collect { _, _, _ in calls += 1; return ["id": .string("8"), "username": .string("owner")] }
      XCTFail("wrong account accepted")
    } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked) }
    XCTAssertEqual(calls, 1)
    var values = options(); values["ids"] = .array([])
    let output = try await XLookupCollection(values).collect { _, _, _ in XCTFail("empty set called provider"); return [:] }
    XCTAssertEqual(output["complete"], .bool(true)); XCTAssertEqual(output["pendingIds"], .array([]))
  }

  func testInvalidOrUnavailableBatchRetainsAllIDsAndCancellationPropagates() async throws {
    for value in [post("unrelated"), post("101", date: "2026-10-20T00:00:00Z")] {
      let output = try await XLookupCollection(options()).collect { operation, _, _ in
        if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
        return ["posts": .array([.object(value)])]
      }
      XCTAssertEqual(output["posts"], .array([])); XCTAssertEqual(output["pendingIds"], .array([.string("101")]))
      XCTAssertNotEqual(output["failures"], .array([]))
    }
    do { _ = try await XLookupCollection(options()).collect { operation, _, _ in
      if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
      throw CancellationError()
    }; XCTFail("cancelled lookup accepted") } catch { XCTAssertTrue(error is CancellationError) }
  }

  func testContextBudgetFailsBeforePaymentAndLargeBodyDoesNotHoldSmallPeer() async throws {
    do { _ = try await XLookupCollection(options()).collect(outputByteBudget: 100) { _, _, _ in
      XCTFail("unusable output budget called provider"); return [:]
    }; XCTFail("unusable budget accepted") } catch {}
    var values = options(); values["ids"] = .array([.string("101"), .string("102")])
    var large = post("101"); large["text"] = .string(String(repeating: "X", count: 300_000))
    let output = try await XLookupCollection(values).collect(outputByteBudget: 200_000) { operation, _, _ in
      if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
      return ["posts": .array([.object(large), .object(self.post("102"))])]
    }
    XCTAssertEqual(output["returnedIds"], .array([.string("102")]))
    XCTAssertEqual(output["pendingIds"], .array([.string("101")]))
    XCTAssertLessThan(try JSONEncoder().encode(output).count, 200_000)
  }

  func testInvalidEntireRequestIsRejectedBeforeProviderWork() throws {
    for ids: [JSONValue] in [[.string("101"), .string("101")], [.string("bad")], [.null]] {
      var values = options(); values["ids"] = .array(ids)
      XCTAssertThrowsError(try XLookupCollection(values))
    }
    var values = options(); values["maxPosts"] = .integer(101)
    XCTAssertThrowsError(try XLookupCollection(values))
  }

  func testPartialFailureKeepsFiniteSDKDiagnosticsAndNeverProviderText() async throws {
    let output = try await XLookupCollection(options()).collect { operation, _, _ in
      if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
      let message = "PRIVATE source text (code=PERMISSION_DENIED, classification=permission, httpStatus=403, retryable=false, "
        + "requestAttempts=1, retryAttempts=0, backoffMs=0, retryStopReason=non-retryable, private=CANARY)"
      throw AdapterExecutionError(.providerError, message)
    }
    guard case let .array(failures)? = output["failures"], case let .object(failure)? = failures.first,
      case let .object(diagnostics)? = failure["diagnostics"] else { return XCTFail("missing diagnostics") }
    XCTAssertEqual(diagnostics["code"], .string("PERMISSION_DENIED")); XCTAssertEqual(diagnostics["httpStatus"], .integer(403))
    XCTAssertEqual(diagnostics["backoffMs"], .integer(0)); XCTAssertEqual(diagnostics["retryable"], .bool(false))
    XCTAssertFalse(try JSONValue.object(output).compactJSONString().contains("PRIVATE"))
    XCTAssertNil(diagnostics["private"])
    let parameter = GatewayFailureDiagnostics.fields(readerMessage: "reader (code=UPSTREAM_FAILURE, httpStatus=400, xInvalidRequestParameter=since_id)")
    XCTAssertEqual(parameter["xInvalidRequestParameter"], .string("since_id"))
    let unknown = GatewayFailureDiagnostics.fields(readerMessage: "reader (code=UPSTREAM_FAILURE, httpStatus=400, xInvalidRequestParameter=PRIVATE)")
    XCTAssertNil(unknown["xInvalidRequestParameter"])
  }

  private func options() -> JSONObject {
    ["mode": .string("lookup"), "ids": .array([.string("101")]), "expectedHandle": .string("owner"), "expectedAccount": .string("7"),
      "start": .string("2026-10-22T00:00:00Z"), "end": .string("2026-10-22T01:00:00Z")]
  }
  private func post(_ id: String, date: String = "2026-10-22T00:30:00Z") -> JSONObject {
    ["id": .string(id), "text": .string("inspected later"), "createdAt": .string(date)]
  }
  private func input(_ values: JSONObject) -> WorkflowAddonExecutionInput {
    .init(workflowId: "fixture", stepId: "lookup", nodeId: "lookup", addon: .init(name: "riela/x-collect", version: "1",
      config: ["options": .string("{{options}}"), "context": .string("{{context}}")]),
      variables: ["options": .object(values), "context": .object(["literal": .string("{{data}}")])])
  }
}

private final class XLookupTransport: @unchecked Sendable {
  let respond: (String) throws -> JSONObject
  init(_ respond: @escaping (String) throws -> JSONObject) { self.respond = respond }
  var runner: LocalGatewayGraphQLRunner {
    { [self] _, document, _, _ in try JSONValue.object(respond(document)).compactJSONString() }
  }
}
