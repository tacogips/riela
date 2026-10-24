import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class GmailCollectionTests: XCTestCase {
  func testWindowRewritesRelativeFiltersAndPreservesLegacyScopeIdentity() async throws {
    var values = options()
    values["queries"] = .array([.string("in:inbox newer_than:2d")])
    values["window"] = .array([.string("2026-10-22T09:00:00.125000+00:00"), .string("2026-10-22T10:00:00.250000+00:00")])
    let opts = try GmailCollectionOptions(values)
    XCTAssertEqual(opts.queries, ["in:inbox after:1792659599 before:1792663201"])
    XCTAssertEqual(opts.scope, "29b7344761d871430fb3c8ec5da711be7062aaf0b8189452cc7708f420ca3f00")
    _ = try await GmailMailboxCollector(options: opts).collectScan { operation, args, _ in
      if operation == "profile" { return self.profile("10") }
      let input = try self.object(args["input"])
      XCTAssertNil(input["receivedAfter"])
      XCTAssertEqual(input["query"], .string(opts.queries[0]))
      return self.page([])
    }
    var targeted = values; targeted["bodyMessageIds"] = .array([.string("message-a")])
    XCTAssertNotEqual(try GmailCollectionOptions(targeted).scope, opts.scope)
  }

  func testSmallRunResumesExactListingCursorAndKeepsPreScanMailboxVersion() async throws {
    var values = options(); values["maxThreads"] = .integer(1)
    let first = try await GmailMailboxCollector(options: .init(values)).collectScan { operation, args, _ in
      if operation == "profile" { return self.profile("10") }
      if operation == "threads" {
        XCTAssertEqual(try self.object(args["input"])["first"], .integer(1))
        return self.page(["a"], cursor: "continue-exactly")
      }
      return self.thread("a", version: "8")
    }
    XCTAssertEqual(first["complete"], .bool(false))
    values["previous"] = first["checkpoint"]
    var seen: [String] = []
    let resumed = try await GmailMailboxCollector(options: .init(values)).collectScan { operation, args, _ in
      seen.append(operation)
      if operation == "profile" { return self.profile("11") }
      if operation == "threads" {
        XCTAssertEqual(try self.object(args["input"])["after"], .string("continue-exactly"))
        return self.page(["b"])
      }
      XCTAssertEqual(args["threadId"], .string("b"))
      return self.thread("b", version: "9")
    }
    XCTAssertEqual(seen, ["profile", "threads", "thread"])
    XCTAssertEqual(resumed["complete"], .bool(true))
    let cp = try object(resumed["checkpoint"])
    XCTAssertEqual(cp["mailbox_version"], .string("10"), "the newer profile cannot acknowledge a scan it did not precede")
    XCTAssertEqual(cp["thread_versions"], .object(["a": .string("8"), "b": .string("9")]))
    XCTAssertNil(cp["pending_collection"])
  }

  func testFailedItemCannotMonopolizeOneItemRuns() async throws {
    var values = options(); values["maxThreads"] = .integer(1)
    let first = try await GmailMailboxCollector(options: .init(values)).collectScan { operation, _, _ in
      if operation == "profile" { return self.profile("10") }
      if operation == "threads" { return self.page(["a"], cursor: "next-page") }
      throw self.invalid()
    }
    values["previous"] = first["checkpoint"]
    let second = try await GmailMailboxCollector(options: .init(values)).collectScan { operation, args, _ in
      if operation == "profile" { return self.profile("11") }
      if operation == "threads" { return self.page(["b"]) }
      XCTAssertEqual(args["threadId"], .string("b"))
      return self.thread("b", version: "8")
    }
    XCTAssertEqual(second["invalidated"], .array([.string("b")]))
    XCTAssertEqual(second["complete"], .bool(false))
    let pending = try object(object(second["checkpoint"])["pending_collection"])
    XCTAssertEqual(pending["completed"], .array([.string("b")]))
    XCTAssertEqual(pending["deferred"], .array([.string("a")]))
  }

  func testDeadlineContinuationDoesNotReadAlreadyCompletedThreadsAgain() async throws {
    var instant = Date(timeIntervalSince1970: 1000)
    let first = try await GmailMailboxCollector(options: .init(options()), deadline: instant.addingTimeInterval(1), clock: { instant })
      .collectScan { operation, _, _ in
        if operation == "profile" { return self.profile("10") }
        if operation == "threads" { return self.page(["a", "b"]) }
        instant = instant.addingTimeInterval(2); return self.thread("a", version: "8")
      }
    var values = options(); values["previous"] = first["checkpoint"]
    var reads: [String] = []
    let resumed = try await GmailMailboxCollector(options: .init(values)).collectScan { operation, args, _ in
      reads.append(operation)
      if operation == "profile" { return self.profile("11") }
      XCTAssertEqual(args["threadId"], .string("b"))
      return self.thread("b", version: "8")
    }
    XCTAssertEqual(reads, ["profile", "thread"])
    XCTAssertEqual(resumed["complete"], .bool(true))
    XCTAssertEqual(resumed["invalidated"], .array([.string("b")]))
  }

  func testNativeSDKCollectorStoresVersionAndUnchangedMailboxSkipsAllHydration() async throws {
    let transport = GmailCollectTransport { operation, _ in
      switch operation {
      case "profile": return self.profile("10")
      case "threads": return self.page(["a"])
      default: return self.thread("a", version: "8")
      }
    }
    let resolver = BuiltinWorkflowAddonResolver(environment: [:], localGatewayGraphQLRunner: transport.runner)
    let first = try await resolver.execute(input(options()), context: .init())
    XCTAssertEqual(first.payload["complete"], .bool(true))
    let cp = try object(first.payload["checkpoint"])
    XCTAssertEqual(cp["mailbox_version"], .string("10"))
    XCTAssertEqual(try object(cp["thread_versions"])["a"], .string("8"))
    var resumed = options(); resumed["previous"] = .object(cp)
    let second = try await resolver.execute(input(resumed), context: .init())
    XCTAssertEqual(second.payload["threads"], .array([]))
    XCTAssertEqual(second.payload["context"], .string("{{literal_content}}"))
    XCTAssertEqual(transport.operations, ["profile", "threads", "thread", "profile"])
  }

  func testChangedMailboxOnlyHydratesChangedThreadsAndRemovesUnselectedVersions() async throws {
    var values = options(); let opts = try GmailCollectionOptions(values)
    values["previous"] = .object(["native_query_scope": .string(opts.scope), "mailbox_version": .string("10"),
      "thread_versions": .object(["a": .string("8"), "orphan": .string("1")])])
    var fullReads: [String] = []
    let result = try await GmailMailboxCollector(options: .init(values)).collectScan { operation, args, selection in
      if operation == "profile" { return self.profile("11") }
      if operation == "threads" { return self.page(["a", "b"]) }
      guard case let .string(id)? = args["threadId"] else { throw self.invalid() }
      if selection.contains("messages.id") { fullReads.append(id) }
      return self.thread(id, version: id == "a" ? "8" : "9")
    }
    XCTAssertEqual(fullReads, ["b"])
    XCTAssertEqual(result["invalidated"], .array([.string("b")]))
    let cp = try object(result["checkpoint"])
    XCTAssertEqual(cp["mailbox_version"], .string("11"))
    XCTAssertEqual(cp["thread_versions"], .object(["a": .string("8"), "b": .string("9")]))
  }

  func testThreadFailureDoesNotAdvanceItsVersionOrPreventOtherThreads() async throws {
    var values = options(); let opts = try GmailCollectionOptions(values)
    values["previous"] = .object(["native_query_scope": .string(opts.scope), "mailbox_version": .string("9"),
      "thread_versions": .object(["a": .string("7")])])
    let result = try await GmailMailboxCollector(options: .init(values)).collectScan { operation, args, _ in
      if operation == "profile" { return self.profile("10") }
      if operation == "threads" { return self.page(["a", "b"]) }
      if args["threadId"] == .string("a") { throw AdapterExecutionError(.providerError, "synthetic private provider detail") }
      return self.thread("b", version: "8")
    }
    XCTAssertEqual(result["complete"], .bool(false))
    XCTAssertEqual(result["invalidated"], .array([.string("b")]))
    let cp = try object(result["checkpoint"])
    XCTAssertEqual(cp["mailbox_version"], .string("9"))
    XCTAssertEqual(try object(cp["thread_versions"])["a"], .string("7"))
    XCTAssertEqual(try object(cp["thread_versions"])["b"], .string("8"))
    XCTAssertFalse(try JSONValue.object(result).compactJSONString().contains("synthetic private provider detail"))
  }

  func testRepeatedListingCursorRejectsBadPageButProcessesAcceptedPrefix() async throws {
    var pages = 0
    let result = try await GmailMailboxCollector(options: .init(options())).collectScan { operation, _, _ in
      if operation == "profile" { return self.profile("10") }
      if operation == "threads" { pages += 1; return self.page([pages == 1 ? "a" : "bad-page"], cursor: "same") }
      return self.thread("a", version: "8")
    }
    XCTAssertEqual(pages, 2)
    XCTAssertEqual(result["complete"], .bool(false))
    XCTAssertEqual(result["invalidated"], .array([.string("a")]))
    XCTAssertNil(try object(result["checkpoint"])["mailbox_version"])
  }

  func testIncompleteRequestedBodyCannotAcknowledgeMailboxOrStopSibling() async throws {
    var values = options(); values["bodyMessageIds"] = .array([.string("message-a")])
    let result = try await GmailMailboxCollector(options: .init(values)).collectScan { operation, args, _ in
      if operation == "profile" { return self.profile("10") }
      if operation == "threads" { return self.page(["a", "b"]) }
      if operation == "messageBodyBytes" {
        XCTAssertEqual(args["messageId"], .string("message-a"))
        return ["accountId": .string("personal"), "messageId": .string("message-a"), "complete": .bool(false)]
      }
      guard case let .string(id)? = args["threadId"] else { throw self.invalid() }
      return self.thread(id, version: "8")
    }
    XCTAssertEqual(result["invalidated"], .array([.string("b")]))
    XCTAssertEqual(result["complete"], .bool(false))
    let cp = try object(result["checkpoint"])
    XCTAssertNil(cp["mailbox_version"])
    XCTAssertNil(try object(cp["thread_versions"])["a"])
  }

  func testBudgetStopsBeforeAnotherProviderCallAndCancellationPropagates() async throws {
    var instant = Date(timeIntervalSince1970: 1000), calls = 0
    let collector = GmailMailboxCollector(options: try .init(options()), deadline: instant.addingTimeInterval(1), clock: { instant })
    let result = try await collector.collectScan { _, _, _ in
      calls += 1; instant = instant.addingTimeInterval(2); return self.profile("10")
    }
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(result["complete"], .bool(false))
    do {
      _ = try await GmailMailboxCollector(options: .init(options())).collectScan { _, _, _ in throw CancellationError() }
      XCTFail("cancellation became a successful or partial result")
    } catch { XCTAssertTrue(error is CancellationError) }
  }

  func testScopeMatchesLegacyCanonicalJSONAndCannotCrossAccountsOrQueries() throws {
    var values = options()
    let queries: JSONValue = .array([.string("in:inbox"), .string("件名:更新")])
    values["queries"] = queries
    XCTAssertEqual(try GmailCollectionOptions(values).scope, "c4ee206a2ab85491e2d01f5b517e8bd8153d904d46c784f926cbf25e0e9a89c5")
    values["accountId"] = .string("other")
    XCTAssertNotEqual(try GmailCollectionOptions(values).scope, "c4ee206a2ab85491e2d01f5b517e8bd8153d904d46c784f926cbf25e0e9a89c5")
  }

  func testOpaqueAccountIDsMatchSDKConfiguration() throws {
    var values = options()
    for account in ["work.mail", "仕事用"] {
      values["accountId"] = .string(account)
      XCTAssertEqual(try GmailCollectionOptions(values).account, account)
    }
  }

  func testBodyBudgetRetainsAcceptedPrefixAndDoesNotAcknowledgeOversizedItem() async throws {
    let result = try await GmailMailboxCollector(options: .init(options()), outputByteBudget: 100_000)
      .collectScan { operation, args, _ in
        if operation == "profile" { return self.profile("10") }
        if operation == "threads" { return self.page(["a", "b"]) }
        let id = args["threadId"] == .string("a") ? "a" : "b"
        var thread = self.thread(id, version: "8")
        if id == "b" { thread["oversized"] = .string(String(repeating: "x", count: 100_000)) }
        return thread
      }
    XCTAssertEqual(result["invalidated"], .array([.string("a")]))
    XCTAssertEqual(result["complete"], .bool(false))
    let checkpoint = try object(result["checkpoint"])
    XCTAssertNil(try object(checkpoint["thread_versions"])["b"])
    XCTAssertLessThan(try JSONEncoder().encode(result).count, 100_000)
  }

  func testAllFailedItemsReceiveFairRetryTurnsAtOneItemBudget() async throws {
    var values = options(); values["maxThreads"] = .integer(1)
    var attempts: [String] = []
    for turn in 0..<6 {
      let result = try await GmailMailboxCollector(options: .init(values)).collectScan { operation, args, _ in
        if operation == "profile" { return self.profile("10") }
        if operation == "threads" { return turn == 0 ? self.page(["a"], cursor: "next") : self.page(["b"]) }
        if case let .string(id)? = args["threadId"] { attempts.append(id) }
        throw self.invalid()
      }
      values["previous"] = result["checkpoint"]
    }
    XCTAssertEqual(attempts, ["a", "b", "a", "b", "a", "b"])
  }

  func testPoisonBacklogDoesNotBlockFreshMailAndPreservesExactOldCursor() async throws {
    var values = options(); values["maxThreads"] = .integer(1)
    var attempt = 0
    for turn in 0..<3 {
      let result = try await GmailMailboxCollector(options: .init(values)).collect { operation, args, _ in
        if operation == "profile" { return self.profile(turn == 0 ? "10" : "11") }
        if operation == "threads" {
          let input = try self.object(args["input"])
          if turn == 1 {
            XCTAssertEqual(input["after"], .string("poison-cursor"))
            throw self.invalid()
          }
          XCTAssertNil(input["after"])
          return turn == 0 ? self.page(["a"], cursor: "poison-cursor") : self.page(["new"])
        }
        if args["threadId"] == .string("a") { throw self.invalid() }
        attempt += 1; return self.thread("new", version: "9")
      }
      values["previous"] = result["checkpoint"]
      XCTAssertEqual(result["complete"], .bool(false))
      if turn == 2 {
        XCTAssertEqual(result["invalidated"], .array([.string("new")]))
        let cp = try object(result["checkpoint"])
        XCTAssertNil(cp["mailbox_version"])
        guard case let .array(queue)? = cp["pending_scans"] else { return XCTFail("lost unresolved scan") }
        let pending = try object(queue[0]); let listing = try object(pending["listing"])
        XCTAssertEqual(listing["cursor"], .string("poison-cursor"))
      }
    }
    XCTAssertEqual(attempt, 1)
  }

  func testLongRunningScanKeepsDiscoveryFloorAndScopesSurviveBodyIntentSwitch() async throws {
    var values = options(); values["maxThreads"] = .integer(1)
    let firstTime = Date(timeIntervalSince1970: 1_000_000)
    let first = try await GmailMailboxCollector(options: .init(values), clock: { firstTime }).collect { operation, _, _ in
      if operation == "profile" { return self.profile("10") }
      if operation == "threads" { return self.page(["a"], cursor: "literal-old-cursor") }
      throw self.invalid()
    }
    let original = try object(first["checkpoint"])
    var switched = values; switched["bodyMessageIds"] = .array([.string("message-b")]); switched["previous"] = .object(original)
    let body = try await GmailMailboxCollector(options: .init(switched)).collect { operation, _, _ in
      if operation == "profile" { return self.profile("11") }
      return self.page([])
    }
    let bodyCP = try object(body["checkpoint"])
    let scopes = try object(bodyCP["collection_scopes"])
    XCTAssertEqual(scopes[try GmailCollectionOptions(values).scope], .object(original))
    values["previous"] = body["checkpoint"]
    // Resume the original literal cursor, then allow fresh discovery with a
    // two-day jump. Neither the body intent nor time passage drops the floor.
    let resumed = try await GmailMailboxCollector(options: .init(values), clock: { firstTime.addingTimeInterval(172_800) })
      .collect { operation, args, _ in
        if operation == "profile" { return self.profile("12") }
        if operation == "threads" {
          XCTAssertEqual(try self.object(args["input"])["after"], .string("literal-old-cursor"))
          throw self.invalid()
        }
        throw self.invalid()
      }
    values["previous"] = resumed["checkpoint"]
    _ = try await GmailMailboxCollector(options: .init(values), clock: { firstTime.addingTimeInterval(172_800) })
      .collect { operation, args, _ in
        if operation == "profile" { return self.profile("12") }
        let input = try self.object(args["input"])
        guard case let .string(after)? = input["receivedAfter"] else { throw self.invalid() }
        XCTAssertLessThanOrEqual(try xInstant(after), firstTime.addingTimeInterval(-86_400))
        XCTAssertNil(input["after"])
        return self.page([])
      }
  }

  func testDrainingOldCursorCannotRemoveAlreadyAcquiredFreshThreadVersions() async throws {
    var values = options(); values["maxThreads"] = .integer(1)
    for turn in 0..<4 {
      let result = try await GmailMailboxCollector(options: .init(values)).collect { operation, args, _ in
        if operation == "profile" { return self.profile(turn == 0 ? "10" : "11") }
        if operation == "threads" {
          if turn == 0 { return self.page(["a"], cursor: "old") }
          if turn == 1 { throw self.invalid() }
          return self.page(turn == 2 ? ["b"] : [])
        }
        if turn < 3, args["threadId"] == .string("a") { throw self.invalid() }
        return self.thread(turn == 2 ? "b" : "a", version: "8")
      }
      values["previous"] = result["checkpoint"]
      if turn == 3 {
        let cp = try object(result["checkpoint"])
        XCTAssertEqual(cp["active_threads"], .array([.string("a"), .string("b")]))
        XCTAssertEqual(cp["thread_versions"], .object(["a": .string("8"), "b": .string("8")]))
        XCTAssertNil(cp["mailbox_version"])
      }
    }
  }

  func testCompletedScopeHistoryIsEvictableWhilePendingScopeIsRetained() async throws {
    var scopes: JSONObject = [:]
    for index in 0..<70 { scopes[String(index)] = .object(["checked_at": .string(String(format: "%03d", index))]) }
    scopes["pending"] = .object(["pending_scans": .array([.object(["opaque": .string("exact-cursor")])])])
    var values = options(); values["previous"] = .object(["collection_scopes": .object(scopes)])
    let result = try await GmailMailboxCollector(options: .init(values)).collect { operation, _, _ in
      operation == "profile" ? self.profile("10") : self.page([])
    }
    let kept = try object(object(result["checkpoint"])["collection_scopes"])
    XCTAssertEqual(kept.count, 64)
    XCTAssertEqual(kept["pending"], scopes["pending"])
    XCTAssertNil(kept["0"])
  }

  func testPermanentPoisonDoesNotAccumulateOneScanPerFreshProfile() async throws {
    var values = options(); values["maxThreads"] = .integer(2)
    var freshReads = 0
    for turn in 0..<70 {
      let result = try await GmailMailboxCollector(options: .init(values)).collect { operation, args, _ in
        if operation == "profile" { return self.profile(String(10 + turn)) }
        if operation == "threads" { return self.page(["new-" + String(turn), "poison"]) }
        guard case let .string(id)? = args["threadId"] else { throw self.invalid() }
        if id == "poison" { throw self.invalid() }
        freshReads += 1; return self.thread(id, version: String(10 + turn))
      }
      values["previous"] = result["checkpoint"]
      let cp = try object(result["checkpoint"])
      guard case let .array(scans)? = cp["pending_scans"] else { return XCTFail("poison was acknowledged") }
      XCTAssertEqual(scans.count, 1, "exhausted listings share one unresolved-ID backlog")
      XCTAssertNil(cp["mailbox_version"])
    }
    XCTAssertEqual(freshReads, 35)
  }

  func testRequestedBodyFoundByFreshScanRemainsKnownWhenOldCursorDrains() async throws {
    var values = options(); values["maxThreads"] = .integer(1)
    values["bodyMessageIds"] = .array([.string("message-b")])
    for turn in 0..<4 {
      let result = try await GmailMailboxCollector(options: .init(values)).collect { operation, args, _ in
        if operation == "profile" { return self.profile(turn == 0 ? "10" : "11") }
        if operation == "threads" {
          if turn == 0 { return self.page(["a"], cursor: "old") }
          if turn == 1 { throw self.invalid() }
          return self.page(turn == 2 ? ["b"] : [])
        }
        if operation == "messageBodyBytes" {
          return ["accountId": .string("personal"), "messageId": .string("message-b"), "complete": .bool(true)]
        }
        if turn < 3, args["threadId"] == .string("a") { throw self.invalid() }
        return self.thread(turn == 2 ? "b" : "a", version: "8")
      }
      values["previous"] = result["checkpoint"]
      if turn == 3 {
        let cp = try object(result["checkpoint"])
        XCTAssertEqual(cp["found_body_ids"], .array([.string("message-b")]))
        XCTAssertNil(cp["pending_scans"])
        XCTAssertEqual(result["complete"], .bool(true))
      }
    }
    let fresh = try await GmailMailboxCollector(options: .init(values)).collect { operation, _, _ in
      operation == "profile" ? self.profile("12") : self.page([])
    }
    XCTAssertEqual(fresh["complete"], .bool(true), "a fulfilled body intent does not become missing on a later empty fresh listing")
    XCTAssertNil(try object(fresh["checkpoint"])["pending_scans"])
  }

  private func options() -> JSONObject {
    ["accountId": .string("personal"), "queries": .array([.string("in:inbox")]), "minRequestIntervalSeconds": .integer(0),
      "lookbackHours": .integer(24)]
  }
  private func input(_ options: JSONObject) -> WorkflowAddonExecutionInput {
    .init(workflowId: "gmail-collection", stepId: "collect", nodeId: "collect", addon: .init(name: "riela/gmail-collect", version: "1",
      config: ["options": .string("{{options}}"), "context": .string("{{opaqueContext}}")]),
      variables: ["options": .object(options), "opaqueContext": .string("{{literal_content}}")])
  }
  private func profile(_ version: String) -> JSONObject { ["emailAddress": .string("owner@example.test"), "historyId": .string(version)] }
  private func page(_ ids: [String], cursor: String? = nil) -> JSONObject {
    ["edges": .array(ids.map { .object(["node": .object(["id": .string($0)])]) }),
      "pageInfo": .object(["hasNextPage": .bool(cursor != nil), "endCursor": cursor.map(JSONValue.string) ?? .null])]
  }
  private func thread(_ id: String, version: String) -> JSONObject {
    ["id": .string(id), "providerMetadata": .object(["gmail": .object(["historyId": .string(version)])]),
      "messages": .array([.object(["id": .string("message-" + id), "accountId": .string("personal"), "threadId": .string(id),
        "textBody": .string("private fixture"), "subject": .string("Business request")])])]
  }
  private func object(_ value: JSONValue?) throws -> JSONObject {
    guard case let .object(value)? = value else { throw invalid() }; return value
  }
  private func invalid() -> AdapterExecutionError { .init(.invalidOutput, "invalid synthetic Gmail fixture") }
}

private final class GmailCollectTransport: @unchecked Sendable {
  private let lock = NSLock()
  private var calls: [String] = []
  let respond: (String, String) throws -> JSONObject
  init(_ respond: @escaping (String, String) throws -> JSONObject) { self.respond = respond }
  var operations: [String] { lock.withLock { calls } }
  var runner: LocalGatewayGraphQLRunner {
    { [self] _, document, _, _ in
      let operation = document.contains("profile(") ? "profile" : (document.contains("threads(") ? "threads" : "thread")
      lock.withLock { calls.append(operation) }
      let value = try respond(operation, document)
      return try JSONValue.object(["data": .object([operation: .object(value)])]).compactJSONString()
    }
  }
}
