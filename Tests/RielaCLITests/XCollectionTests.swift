import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class XCollectionTests: XCTestCase {
  func testLegacyCheckpointFixtureImportsExactTokensWithoutProviderCalls() async throws {
    guard let path = ProcessInfo.processInfo.environment["RIELA_TEST_X_COLLECTION_FIXTURE"] else {
      throw XCTSkip("optional metadata-only production cursor fixture")
    }
    let fixture = try JSONDecoder().decode(JSONObject.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let values = try object(fixture["options"]), opts = try XCollectionOptions(values)
    guard case let .string(account)? = fixture["account_id"] else { throw invalid() }
    let shards = try object(opts.previous["author_shards"])
    var expected: [String: JSONValue] = [:]
    for value in shards.values {
      let cp = try object(value)
      if case let .string(query)? = cp["author_query"], case let .object(scan)? = cp["pending_scan"] {
        expected[query] = scan["next_token"]
      }
    }
    XCTAssertFalse(expected.isEmpty)
    var witnessed = Set<String>()
    _ = try await XAuthorCollector(options: opts).collect { operation, arguments, _ in
      if operation == "accountMe" { return ["id": .string(account), "username": .string(opts.expected)] }
      guard case let .string(query)? = arguments["query"] else { throw self.invalid() }
      if let token = expected[query] { XCTAssertEqual(arguments["nextToken"], token); witnessed.insert(query) }
      return self.page([])
    }
    XCTAssertEqual(witnessed, Set(expected.keys))
  }

  func testClosedHeadReceiptReusesInspectedProbeAndStillContinuesBacklog() async throws {
    var values = options(); values["freshPage"] = .bool(true); values["end"] = .string("2026-10-22T02:00:00+00:00")
    values["requestedStart"] = .string("2026-10-21T23:00:00+00:00")
    values["earliest"] = values["start"]
    values["signatureContext"] = .object(["settings": .object(["author_handles": values["authorHandles"] ?? .null]), "fields": .object([:])])
    var old = previous(query: "from:kenn OR from:OpenAI", token: "old-token")
    let opts = try XCollectionOptions(values)
    let signature = try opts.headSignature(account: "7", checkpoint: old, probeStart: "2026-10-22T01:00:00+00:00")
    // Golden from the legacy Python json.dumps(sort_keys=True, separators=(',', ':')) signature.
    XCTAssertEqual(signature, "b51dd29d3b7f6410588ed452ec0a223b43fcb6e80d6fdf955f268b205e09b248")
    old["fresh_head_receipt"] = .object(["version": .integer(1), "signature": .string(signature), "status": .string("complete"), "returned_count": .integer(2)])
    values["previous"] = .object(old)
    var searches = 0
    let result = try await XAuthorCollector(options: .init(values)).collect { operation, arguments, _ in
      if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
      searches += 1; XCTAssertEqual(arguments["nextToken"], .string("old-token")); return self.page(["101"])
    }
    XCTAssertEqual(searches, 1)
    XCTAssertEqual(try object(object(result["checkpoint"])["fresh_head"])["reused"], .bool(true))
    XCTAssertFalse(try complete(result), "a completed older window does not cover the requested later interval")
  }

  func testSmallShardBudgetResumesLegacyFivePostCursorWithoutReset() async throws {
    var values = options()
    values["authorHandles"] = .array((0..<100).map { .string(String(format: "u%014d", $0)) })
    values["maxPosts"] = .integer(25)
    let opts = try XCollectionOptions(values)
    XCTAssertEqual(opts.groups.count, 5)
    var requests = 0
    let first = try await XAuthorCollector(options: opts).collect { operation, arguments, _ in
      if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
      requests += 1; XCTAssertEqual(arguments["maxResults"], .integer(10))
      return self.page([String(100 + requests)], token: "small-\(requests)")
    }
    XCTAssertEqual(requests, 5)
    let checkpoint = try object(first["checkpoint"]), shards = try object(checkpoint["author_shards"])
    for value in shards.values { XCTAssertEqual(try object(object(value)["pending_scan"])["page_size"], .integer(5)) }
    values["previous"] = .object(checkpoint)
    var tokens = Set<String>()
    let resumed = try await XAuthorCollector(options: .init(values)).collect { operation, arguments, _ in
      if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
      guard case let .string(token)? = arguments["nextToken"] else { throw self.invalid() }
      tokens.insert(token); XCTAssertEqual(arguments["maxResults"], .integer(10))
      return self.page([])
    }
    XCTAssertEqual(tokens, Set((1...5).map { "small-\($0)" }))
    XCTAssertTrue(try complete(resumed))
  }

  func testNativeSDKNodeContinuesExactCursorAndFiltersPreviouslySeenPosts() async throws {
    let transport = XCollectTransport { operation, document, index in
      if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
      XCTAssertTrue(document.contains("from:kenn OR from:OpenAI"))
      XCTAssertFalse(document.contains("homeTimeline"))
      if index == 2 { return self.page(["100"], token: "continue-exactly") }
      XCTAssertTrue(document.contains("continue-exactly"))
      return self.page(["100", "99"])
    }
    let resolver = BuiltinWorkflowAddonResolver(environment: [:], localGatewayGraphQLRunner: transport.runner)
    let first = try await resolver.execute(input(options()), context: .init())
    let checkpoint = try object(first.payload["checkpoint"])
    XCTAssertFalse(try complete(first.payload))
    var resumed = options(); resumed["previous"] = .object(checkpoint)
    let second = try await resolver.execute(input(resumed), context: .init())
    XCTAssertEqual(try ids(second.payload), ["99"])
    XCTAssertTrue(try complete(second.payload))
    XCTAssertEqual(try object(second.payload["checkpoint"])["since_id"], .string("100"))
    XCTAssertEqual(transport.documents.count, 4)
    XCTAssertEqual(second.payload["context"], .object(["literal": .string("{{not_a_program}}")]))
  }

  func testAccountMismatchStopsBeforeAnySearch() async throws {
    let transport = XCollectTransport { _, _, _ in ["id": .string("7"), "username": .string("someone_else")] }
    do {
      _ = try await BuiltinWorkflowAddonResolver(environment: [:], localGatewayGraphQLRunner: transport.runner)
        .execute(input(options()), context: .init())
      XCTFail("mismatched authenticated account accepted")
    } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked) }
    XCTAssertEqual(transport.documents.count, 1)
  }

  func testRepeatedTokenRejectsWholePageWithoutLosingItsAcceptedPrefix() async throws {
    var values = options(); values["maxPages"] = .integer(2)
    let collector = XAuthorCollector(options: try .init(values))
    var calls = 0
    let result = try await collector.collect { operation, _, _ in
      if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
      calls += 1
      return self.page([calls == 1 ? "100" : "99"], token: "same")
    }
    XCTAssertEqual(try ids(result), ["100"])
    let checkpoint = try object(result["checkpoint"]), scan = try object(checkpoint["pending_scan"])
    XCTAssertEqual(scan["next_token"], .string("same")); XCTAssertEqual(scan["page_count"], .integer(1))
    XCTAssertFalse(try complete(result))
    XCTAssertEqual(result["failures"], .array([.object(["shard": .integer(0), "stage": .string("page"), "code": .string("page-unavailable")])]))
  }

  func testPageFailureRetainsOnlyFiniteReaderDiagnostics() async throws {
    let result = try await XAuthorCollector(options: .init(options())).collect { operation, _, _ in
      if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
      throw AdapterExecutionError(.providerError, "private query token=secret (code=PERMISSION_DENIED, httpStatus=403, retryable=false, requestAttempts=1, retryAttempts=0, backoffMs=0, retryStopReason=non-retryable, private=secret)")
    }
    guard case let .array(failures)? = result["failures"], let failure = failures.first else { return XCTFail("missing partial failure") }
    let fields = try object(try object(failure)["diagnostics"])
    XCTAssertEqual(fields["code"], .string("PERMISSION_DENIED"))
    XCTAssertEqual(fields["httpStatus"], .integer(403))
    XCTAssertEqual(fields["retryAttempts"], .integer(0))
    XCTAssertEqual(fields["backoffMs"], .integer(0))
    XCTAssertNil(fields["private"])
    XCTAssertFalse(try JSONValue.object(result).compactJSONString().contains("secret"))
    XCTAssertFalse(try complete(result))
  }

  func testImportedShardsKeepIndependentTokensAndOneFailureDoesNotStopAnother() async throws {
    var values = options()
    values["authorHandles"] = .array((0..<36).map { .string(String(format: "u%014d", $0)) })
    let opts = try XCollectionOptions(values)
    var shards: JSONObject = [:]
    for (index, group) in opts.groups.enumerated() {
      let query = group.map { "from:" + $0 }.joined(separator: " OR ")
      shards[String(index)] = .object(previous(query: query, token: "cursor-\(index)"))
    }
    values["previous"] = .object(["author_scope": .string(opts.scope), "author_shards": .object(shards), "account_id": .string("7")])
    var tokens: [String] = []
    let result = try await XAuthorCollector(options: .init(values)).collect { operation, arguments, _ in
      if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
      guard case let .string(token)? = arguments["nextToken"] else { throw self.invalid() }
      tokens.append(token)
      if token == "cursor-0" { throw AdapterExecutionError(.providerError, "synthetic unavailable") }
      return self.page(["102"])
    }
    XCTAssertEqual(tokens, ["cursor-0", "cursor-1"])
    XCTAssertEqual(try ids(result), ["102"])
    let checkpoint = try object(result["checkpoint"]), imported = try object(checkpoint["author_shards"])
    let failed = try object(imported["0"]), failedScan = try object(failed["pending_scan"])
    XCTAssertEqual(failedScan["next_token"], .string("cursor-0")); XCTAssertEqual(failedScan["page_count"], .integer(1))
    XCTAssertFalse(try complete(result))
  }

  func testHeadFailureLeavesBacklogAcquisitionIndependent() async throws {
    var values = options(); values["freshPage"] = .bool(true); values["end"] = .string("2026-10-22T02:00:00+00:00")
    values["previous"] = .object(previous(query: "from:kenn OR from:OpenAI", token: "old-token"))
    var searched: [JSONObject] = []
    let result = try await XAuthorCollector(options: .init(values)).collect { operation, arguments, _ in
      if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
      searched.append(arguments)
      if arguments["nextToken"] == nil { throw AdapterExecutionError(.providerError, "head failed") }
      return self.page(["101"], token: "next-backlog")
    }
    XCTAssertEqual(searched.count, 2); XCTAssertEqual(try ids(result), ["101"])
    let checkpoint = try object(result["checkpoint"]), head = try object(checkpoint["fresh_head"])
    XCTAssertEqual(head["status"], .string("failed"))
    XCTAssertEqual(try object(checkpoint["pending_scan"])["next_token"], .string("next-backlog"))
  }

  func testMalformedImportedCursorFailsBeforeSearchAndCancellationIsNotPartialSuccess() async throws {
    var values = options(); var old = previous(query: "from:kenn OR from:OpenAI", token: "old-token")
    var scan = try object(old["pending_scan"]); scan["visited_tokens"] = .array([]); old["pending_scan"] = .object(scan)
    values["previous"] = .object(old)
    var searches = 0
    do {
      _ = try await XAuthorCollector(options: .init(values)).collect { operation, _, _ in
        if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
        searches += 1; return self.page([])
      }
      XCTFail("malformed continuation accepted")
    } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidInput) }
    XCTAssertEqual(searches, 0)
    do {
      _ = try await XAuthorCollector(options: .init(options())).collect { operation, _, _ in
        if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
        throw CancellationError()
      }
      XCTFail("cancellation became a partial result")
    } catch { XCTAssertTrue(error is CancellationError) }
  }

  private func options() -> JSONObject {
    ["expectedHandle": .string("owner"), "authorHandles": .array([.string("kenn"), .string("OpenAI")]),
      "start": .string("2026-10-22T00:00:00+00:00"), "end": .string("2026-10-22T01:00:00+00:00"),
      "earliest": .string("2026-10-14T15:00:00+00:00"), "pageSize": .integer(25), "maxPosts": .integer(100)]
  }
  private func previous(query: String, token: String) -> JSONObject {
    ["account_id": .string("7"), "author_query": .string(query), "since_id": .string("50"),
      "pending_scan": .object(["start": .string("2026-10-22T00:00:00+00:00"), "end": .string("2026-10-22T01:00:00+00:00"),
        "since_id": .string("50"), "max_id": .string("90"), "next_token": .string(token),
        "page_size": .integer(25), "page_count": .integer(1), "visited_tokens": .array([.string(String(repeating: "a", count: 64))]),
        "recent_ids": .array([.string("90")]), "wire_start": .string("2026-10-22T00:00:00Z"), "wire_end": .string("2026-10-22T01:00:00Z")])]
  }
  private func page(_ ids: [String], token: String? = nil) -> JSONObject {
    ["posts": .array(ids.map { .object(["id": .string($0), "text": .string("fixture"), "createdAt": .string("2026-10-22T00:30:00Z")]) }),
      "pageInfo": .object(["nextToken": token.map(JSONValue.string) ?? .null])]
  }
  private func input(_ options: JSONObject) -> WorkflowAddonExecutionInput {
    .init(workflowId: "x-collection", stepId: "collect", nodeId: "collect", addon: .init(name: "riela/x-collect", version: "1",
      config: ["options": .string("{{options}}"), "context": .string("{{context}}")]),
      variables: ["options": .object(options), "context": .object(["literal": .string("{{not_a_program}}")])])
  }
  private func object(_ value: JSONValue?) throws -> JSONObject {
    guard case let .object(value)? = value else { throw invalid() }; return value
  }
  private func ids(_ value: JSONObject) throws -> [String] {
    guard case let .array(posts)? = value["posts"] else { throw invalid() }
    return try posts.map { guard case let .object(p) = $0, case let .string(id)? = p["id"] else { throw invalid() }; return id }
  }
  private func complete(_ value: JSONObject) throws -> Bool {
    guard case let .bool(flag)? = value["complete"] else { throw invalid() }; return flag
  }
  private func invalid() -> AdapterExecutionError { .init(.invalidOutput, "invalid synthetic fixture") }
}

private final class XCollectTransport: @unchecked Sendable {
  let lock = NSLock()
  var calls: [String] = []
  let respond: (String, String, Int) throws -> JSONObject
  init(_ respond: @escaping (String, String, Int) throws -> JSONObject) { self.respond = respond }
  var documents: [String] { lock.withLock { calls } }
  var runner: LocalGatewayGraphQLRunner {
    { [self] _, document, _, _ in
      let count = lock.withLock { calls.append(document); return calls.count }
      let operation = document.contains("accountMe") ? "accountMe" : "searchPosts"
      let response = try respond(operation, document, count)
      return try JSONValue.object(["data": .object([operation: .object(response)])]).compactJSONString()
    }
  }
}
