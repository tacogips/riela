import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class GmailCollectionTests: XCTestCase {
  func testWindowRewritesRelativeFiltersAndPreservesLegacyScopeIdentity() async throws {
    var values = GmailFixture.options()
    values["queries"] = .array([.string("in:inbox newer_than:2d")])
    values["window"] = .array([.string("2026-10-22T09:00:00.125000+00:00"), .string("2026-10-22T10:00:00.250000+00:00")])
    let opts = try GmailCollectionOptions(values)
    XCTAssertEqual(opts.queries, ["in:inbox after:1792659599 before:1792663201"])
    XCTAssertEqual(opts.scope, "29b7344761d871430fb3c8ec5da711be7062aaf0b8189452cc7708f420ca3f00")
    _ = try await GmailMailboxCollector(options: opts).collectScan { operation, args, _ in
      if operation == "profile" { return GmailFixture.profile("10") }
      let input = try GmailFixture.object(args["input"])
      XCTAssertNil(input["receivedAfter"])
      XCTAssertEqual(input["query"], .string(opts.queries[0]))
      return GmailFixture.page([])
    }
    var targeted = values; targeted["bodyMessageIds"] = .array([.string("message-a")])
    XCTAssertNotEqual(try GmailCollectionOptions(targeted).scope, opts.scope)
  }

  func testSmallRunResumesExactListingCursorAndKeepsPreScanMailboxVersion() async throws {
    var values = GmailFixture.options(); values["maxThreads"] = .integer(1)
    let instant = GmailLocked(Date(timeIntervalSince1970: 1000))
    let first = try await GmailMailboxCollector(options: .init(values), deadline: instant.value.addingTimeInterval(5), clock: { instant.value })
      .collectScan { operation, args, _ in
      if operation == "profile" { return GmailFixture.profile("10") }
      if operation == "threads" {
        XCTAssertEqual(try GmailFixture.object(args["input"])["first"], .integer(50))
        instant.withLock { $0 = $0.addingTimeInterval(2) }
        return GmailFixture.page(["a"], cursor: "continue-exactly")
      }
      return GmailFixture.thread("a", version: "8")
    }
    XCTAssertEqual(first["complete"], .bool(false))
    XCTAssertTrue((try first["failures"]?.compactJSONString() ?? "").contains("deadline"))
    XCTAssertEqual(try GmailFixture.object(GmailFixture.object(first["checkpoint"])["pending_collection"])["completed"], .array([]))
    values["previous"] = first["checkpoint"]
    let seen = GmailLocked<[String]>([])
    let seenThreadIDs = GmailLocked<[String]>([])
    let resumed = try await GmailMailboxCollector(options: .init(values)).collectScan { operation, args, _ in
      seen.withLock { $0.append(operation) }
      if operation == "profile" { return GmailFixture.profile("11") }
      if operation == "threads" {
        XCTAssertEqual(try GmailFixture.object(args["input"])["after"], .string("continue-exactly"))
        return GmailFixture.page(["b"])
      }
      let id = try GmailFixture.threadID(args)
      seenThreadIDs.withLock { $0.append(id) }
      return GmailFixture.thread(id, version: id == "a" ? "8" : "9")
    }
    XCTAssertEqual(seen.value.filter { $0 == "thread" }.count, 2)
    XCTAssertEqual(Set(seenThreadIDs.value), Set(["a", "b"]))
    XCTAssertEqual(Set(seen.value), Set(["profile", "threads", "thread"]))
    XCTAssertEqual(resumed["complete"], .bool(true))
    let cp = try GmailFixture.object(resumed["checkpoint"])
    XCTAssertEqual(cp["mailbox_version"], .string("10"), "the newer profile cannot acknowledge a scan it did not precede")
    XCTAssertEqual(cp["thread_versions"], .object(["a": .string("8"), "b": .string("9")]))
    XCTAssertNil(cp["pending_collection"])
  }

  func testFailedItemCannotMonopolizeOneItemRuns() async throws {
    var values = GmailFixture.options(); values["maxThreads"] = .integer(1)
    let first = try await GmailMailboxCollector(options: .init(values)).collectScan { operation, _, _ in
      if operation == "profile" { return GmailFixture.profile("10") }
      if operation == "threads" { return GmailFixture.page(["a"], cursor: "next-page") }
      throw GmailFixture.invalid()
    }
    values["previous"] = first["checkpoint"]
    values["maxThreads"] = .integer(1)
    let attempts = GmailLocked<[String]>([])
    let second = try await GmailMailboxCollector(options: .init(values)).collectScan { operation, args, _ in
      if operation == "profile" { return GmailFixture.profile("11") }
      if operation == "threads" { return GmailFixture.page(["b"]) }
      let id = try GmailFixture.threadID(args)
      attempts.withLock { $0.append(id) }
      guard id == "b" else { throw GmailFixture.invalid() }
      return GmailFixture.thread(id, version: "8")
    }
    XCTAssertEqual(second["invalidated"], .array([.string("b")]))
    XCTAssertEqual(attempts.value, ["b", "a"])
    XCTAssertEqual(second["complete"], .bool(false))
    let pending = try GmailFixture.object(GmailFixture.object(second["checkpoint"])["pending_collection"])
    XCTAssertEqual(pending["completed"], .array([.string("b")]))
    XCTAssertEqual(pending["deferred"], .array([.string("a")]))
  }

  func testDeadlineContinuationDoesNotReadAlreadyCompletedThreadsAgain() async throws {
    var values = GmailFixture.options(); values["maxThreads"] = .integer(1)
    let instant = GmailLocked(Date(timeIntervalSince1970: 1000))
    let first = try await GmailMailboxCollector(options: .init(values), deadline: instant.value.addingTimeInterval(5), clock: { instant.value })
      .collectScan { operation, _, _ in
        if operation == "profile" { return GmailFixture.profile("10") }
        if operation == "threads" { return GmailFixture.page(["a", "b"]) }
        instant.withLock { $0 = $0.addingTimeInterval(2) }; return GmailFixture.thread("a", version: "8")
      }
    values["previous"] = first["checkpoint"]
    let reads = GmailLocked<[String]>([])
    let resumed = try await GmailMailboxCollector(options: .init(values)).collectScan { operation, args, _ in
      reads.withLock { $0.append(operation) }
      if operation == "profile" { return GmailFixture.profile("11") }
      XCTAssertEqual(args["threadId"], .string("b"))
      return GmailFixture.thread("b", version: "8")
    }
    XCTAssertEqual(reads.value, ["profile", "thread"])
    XCTAssertEqual(first["failures"], .array([.object(["stage": .string("deadline"), "code": .string("acquisition-unavailable")])]))
    XCTAssertEqual(try GmailFixture.object(GmailFixture.object(first["checkpoint"])["pending_collection"])["deferred"], .array([]))
    XCTAssertEqual(resumed["complete"], .bool(true))
    XCTAssertEqual(resumed["invalidated"], .array([.string("b")]))
  }

  func testNativeSDKCollectorStoresVersionAndUnchangedMailboxSkipsAllHydration() async throws {
    let transport = GmailCollectTransport { operation, _ in
      switch operation {
      case "profile": return GmailFixture.profile("10")
      case "threads": return GmailFixture.page(["a"])
      default: return GmailFixture.thread("a", version: "8")
      }
    }
    let resolver = BuiltinWorkflowAddonResolver(environment: [:], localGatewayGraphQLRunner: transport.runner)
    let first = try await resolver.execute(GmailFixture.input(GmailFixture.options()), context: .init())
    XCTAssertEqual(first.payload["complete"], .bool(true))
    let cp = try GmailFixture.object(first.payload["checkpoint"])
    XCTAssertEqual(cp["mailbox_version"], .string("10"))
    XCTAssertEqual(try GmailFixture.object(cp["thread_versions"])["a"], .string("8"))
    var resumed = GmailFixture.options(); resumed["previous"] = .object(cp)
    let second = try await resolver.execute(GmailFixture.input(resumed), context: .init())
    XCTAssertEqual(second.payload["threads"], .array([]))
    XCTAssertEqual(second.payload["context"], .string("{{literal_content}}"))
    XCTAssertEqual(transport.operations, ["profile", "threads", "thread", "profile"])
  }

  func testChangedMailboxOnlyHydratesChangedThreadsAndRemovesUnselectedVersions() async throws {
    var values = GmailFixture.options(); let opts = try GmailCollectionOptions(values)
    values["previous"] = .object(["native_query_scope": .string(opts.scope), "mailbox_version": .string("10"),
      "thread_versions": .object(["a": .string("8"), "orphan": .string("1")])])
    let fullReads = GmailLocked<[String]>([])
    let result = try await GmailMailboxCollector(options: .init(values)).collectScan { operation, args, selection in
      if operation == "profile" { return GmailFixture.profile("11") }
      if operation == "threads" { return GmailFixture.page(["a", "b"]) }
      guard case let .string(id)? = args["threadId"] else { throw GmailFixture.invalid() }
      if selection.contains("messages.id") { fullReads.withLock { $0.append(id) } }
      return GmailFixture.thread(id, version: id == "a" ? "8" : "9")
    }
    XCTAssertEqual(fullReads.value, ["b"])
    XCTAssertEqual(result["invalidated"], .array([.string("b")]))
    let cp = try GmailFixture.object(result["checkpoint"])
    XCTAssertEqual(cp["mailbox_version"], .string("11"))
    XCTAssertEqual(cp["thread_versions"], .object(["a": .string("8"), "b": .string("9")]))
  }

  func testThreadFailureDoesNotAdvanceItsVersionOrPreventOtherThreads() async throws {
    var values = GmailFixture.options(); let opts = try GmailCollectionOptions(values)
    values["previous"] = .object(["native_query_scope": .string(opts.scope), "mailbox_version": .string("9"),
      "thread_versions": .object(["a": .string("7")])])
    let result = try await GmailMailboxCollector(options: .init(values)).collectScan { operation, args, _ in
      if operation == "profile" { return GmailFixture.profile("10") }
      if operation == "threads" { return GmailFixture.page(["a", "b"]) }
      if args["threadId"] == .string("a") { throw AdapterExecutionError(.providerError, "synthetic private provider detail") }
      return GmailFixture.thread("b", version: "8")
    }
    XCTAssertEqual(result["complete"], .bool(false))
    XCTAssertEqual(result["invalidated"], .array([.string("b")]))
    let cp = try GmailFixture.object(result["checkpoint"])
    XCTAssertEqual(cp["mailbox_version"], .string("9"))
    XCTAssertEqual(try GmailFixture.object(cp["thread_versions"])["a"], .string("7"))
    XCTAssertEqual(try GmailFixture.object(cp["thread_versions"])["b"], .string("8"))
    XCTAssertFalse(try JSONValue.object(result).compactJSONString().contains("synthetic private provider detail"))
  }

  func testRepeatedListingCursorRejectsBadPageButProcessesAcceptedPrefix() async throws {
    let pages = GmailLocked(0)
    let reads = GmailLocked<[String]>([])
    let result = try await GmailMailboxCollector(options: .init(GmailFixture.options())).collectScan { operation, args, _ in
      if operation == "profile" { return GmailFixture.profile("10") }
      if operation == "threads" {
        let pageNumber = pages.withLock { value -> Int in value += 1; return value }
        return GmailFixture.page([pageNumber == 1 ? "a" : "new-bad-page-id"], cursor: "same")
      }
      let id = try GmailFixture.threadID(args)
      reads.withLock { $0.append(id) }
      return GmailFixture.thread(id, version: "8")
    }
    XCTAssertEqual(pages.value, 2)
    XCTAssertEqual(result["complete"], .bool(false))
    XCTAssertEqual(result["invalidated"], .array([.string("a")]))
    XCTAssertEqual(reads.value, ["a"])
    let pending = try GmailFixture.object(GmailFixture.object(result["checkpoint"])["pending_collection"])
    XCTAssertEqual(try GmailFixture.object(pending["listing"])["items"], .array([.string("a")]))
    XCTAssertFalse(reads.value.contains("new-bad-page-id"))
    XCTAssertNil(try GmailFixture.object(result["checkpoint"])["mailbox_version"])
  }

  func testIncompleteRequestedBodyCannotAcknowledgeMailboxOrStopSibling() async throws {
    var values = GmailFixture.options(); values["bodyMessageIds"] = .array([.string("message-a")])
    let result = try await GmailMailboxCollector(options: .init(values)).collectScan { operation, args, _ in
      if operation == "profile" { return GmailFixture.profile("10") }
      if operation == "threads" { return GmailFixture.page(["a", "b"]) }
      if operation == "messageBodyBytes" {
        XCTAssertEqual(args["messageId"], .string("message-a"))
        return ["accountId": .string("personal"), "messageId": .string("message-a"), "complete": .bool(false)]
      }
      guard case let .string(id)? = args["threadId"] else { throw GmailFixture.invalid() }
      return GmailFixture.thread(id, version: "8")
    }
    XCTAssertEqual(result["invalidated"], .array([.string("b")]))
    XCTAssertEqual(result["complete"], .bool(false))
    let cp = try GmailFixture.object(result["checkpoint"])
    XCTAssertNil(cp["mailbox_version"])
    XCTAssertNil(try GmailFixture.object(cp["thread_versions"])["a"])
  }

  func testBudgetStopsBeforeAnotherProviderCallAndCancellationPropagates() async throws {
    let state = GmailLocked((instant: Date(timeIntervalSince1970: 1000), calls: 0))
    let collector = GmailMailboxCollector(options: try .init(GmailFixture.options()), deadline: state.value.instant.addingTimeInterval(5), clock: { state.value.instant })
    let result = try await collector.collectScan { _, _, _ in
      state.withLock { $0.calls += 1; $0.instant = $0.instant.addingTimeInterval(2) }
      return GmailFixture.profile("10")
    }
    XCTAssertEqual(state.value.calls, 1)
    XCTAssertEqual(result["complete"], .bool(false))
    XCTAssertTrue((try result["failures"]?.compactJSONString() ?? "").contains("deadline"))
    do {
      _ = try await GmailMailboxCollector(options: .init(GmailFixture.options())).collectScan { _, _, _ in throw CancellationError() }
      XCTFail("cancellation became a successful or partial result")
    } catch { XCTAssertTrue(error is CancellationError) }
  }

  func testCancellationThrownByConcurrentThreadFetchPropagates() async throws {
    var values = GmailFixture.options(); values["maxThreads"] = .integer(4)
    do {
      _ = try await GmailMailboxCollector(options: .init(values)).collectScan { operation, _, _ in
        if operation == "profile" { return GmailFixture.profile("10") }
        if operation == "threads" { return GmailFixture.page(["a", "b", "c", "d"]) }
        throw CancellationError()
      }
      XCTFail("Expected cancellation instead of a partial collection result")
    } catch is CancellationError {
      // Expected: cancellation is not converted into a deferred thread result.
    }
  }

  func testParentCancellationWhileWorkerWaitsForLimiterPropagates() async throws {
    var values = GmailFixture.options(); values["maxThreads"] = .integer(4); values["minRequestIntervalSeconds"] = .integer(5)
    let waits = GmailLocked(0)
    let workerWaiting = expectation(description: "worker entered limiter wait")
    let collector = GmailMailboxCollector(options: try .init(values), wait: { _ in
      let count = waits.withLock { value -> Int in value += 1; return value }
      if count == 2 { workerWaiting.fulfill(); try await Task.sleep(for: .seconds(30)) }
    })
    let task = Task {
      try await collector.collectScan(prefetchedProfile: GmailFixture.profile("10")) { operation, _, _ in
        if operation == "threads" { return GmailFixture.page(["a", "b"]) }
        try await Task.sleep(for: .seconds(30))
        return GmailFixture.thread("a", version: "8")
      }
    }
    await fulfillment(of: [workerWaiting], timeout: 2)
    XCTAssertGreaterThanOrEqual(waits.value, 2, "a worker should be suspended in the limiter")
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected parent cancellation instead of a partial collection result")
    } catch is CancellationError {
      // Expected: the cancelled limiter wait is propagated through the group.
    }
  }

  func testOutputBudgetStopsUnchangedOutcomesAndResumes() async throws {
    var values = GmailFixture.options(); values["maxThreads"] = .integer(100)
    let ids = (0..<500).map { String(format: "unchanged-%03d", $0) }
    let listing = ["fetched-near-budget"] + ids
    let previous: JSONObject = ["native_query_scope": .string(try GmailCollectionOptions(values).scope),
      "mailbox_version": .string("9"), "thread_versions": .object(Dictionary(uniqueKeysWithValues: ids.map { ($0, .string("8")) }))]
    values["previous"] = .object(previous)
    let first = try await GmailMailboxCollector(options: .init(values), outputByteBudget: 300_000).collectScan { operation, args, _ in
      if operation == "profile" { return GmailFixture.profile("10") }
      if operation == "threads" { return GmailFixture.page(listing) }
      let id = try GmailFixture.threadID(args)
      if id == "fetched-near-budget" {
        var thread = GmailFixture.thread(id, version: "8")
        thread["large"] = .string(String(repeating: "x", count: 150_000))
        return thread
      }
      return ["id": .string(id), "providerMetadata": .object(["gmail": .object(["historyId": .string("8")])])]
    }
    XCTAssertEqual(first["complete"], .bool(false))
    XCTAssertTrue((try first["failures"]?.compactJSONString() ?? "").contains("output-budget"))
    values["previous"] = first["checkpoint"]
    let second = try await GmailMailboxCollector(options: .init(values), outputByteBudget: 300_000).collectScan { operation, args, _ in
      if operation == "profile" { return GmailFixture.profile("10") }
      if operation == "threads" { return GmailFixture.page(listing) }
      guard case let .string(id)? = args["threadId"] else { throw GmailFixture.invalid() }
      return ["id": .string(id), "providerMetadata": .object(["gmail": .object(["historyId": .string("8")])])]
    }
    XCTAssertEqual(second["complete"], .bool(true), "the next run should finish the saved listing")
  }

  func testGrantedVersionCheckCanHaveFullReadRefusedAndCheckpointRetriesIt() async throws {
    var values = GmailFixture.options(); values["maxThreads"] = .integer(1); values["minRequestIntervalSeconds"] = .number(2.5)
    let options = try GmailCollectionOptions(values)
    values["previous"] = .object(["native_query_scope": .string(options.scope), "mailbox_version": .string("9"),
      "thread_versions": .object(["a": .string("7")])])
    let now = Date(timeIntervalSince1970: 1_000)
    let result = try await GmailMailboxCollector(options: .init(values), deadline: now.addingTimeInterval(11.5), clock: { now }, wait: { _ in })
      .collectScan { operation, _, selection in
        if operation == "profile" { return GmailFixture.profile("10") }
        if operation == "threads" { return GmailFixture.page(["a"]) }
        XCTAssertFalse(selection.contains("messages.id"), "full read must be refused after metadata grant")
        return ["id": .string("a"), "providerMetadata": .object(["gmail": .object(["historyId": .string("8")])])]
      }
    let pending = try GmailFixture.object(GmailFixture.object(result["checkpoint"])["pending_collection"])
    XCTAssertEqual(pending["deferred"], .array([.string("a")]))
    XCTAssertEqual(pending["retry_after"], .string("a"))
    XCTAssertTrue((try result["failures"]?.compactJSONString() ?? "").contains("deadline"))
  }

  func testPreviousReleasePendingCollectionFormatResumesPartiallyConsumedListing() async throws {
    var values = GmailFixture.options()
    let scope = try GmailCollectionOptions(values).scope
    let oldListing: JSONObject = ["format": .integer(1), "queries": .array([.string("in:inbox")]),
      "maximum": .integer(10_000), "itemsPath": .string("/edges"), "identityPath": .string("/node/id"),
      "cursorPath": .string("/pageInfo/endCursor"), "hasMorePath": .string("/pageInfo/hasNextPage"),
      "identitySyntax": .string("identifier"), "index": .integer(0), "cursor": .string("live-cursor"),
      "visited": .array([.string("live-cursor")]), "items": .array([.string("a"), .string("b")]),
      "pageCount": .integer(2)]
    let oldPending: JSONObject = ["listing": .object(oldListing),
      "completed": .array([.string("a")]), "deferred": .array([]), "found_bodies": .array([]),
      "body_ids": .array([]), "mailbox_version": .string("10"), "received_after": .null, "retry_after": .string("a")]
    XCTAssertEqual(Set(oldPending.keys), Set(["listing", "completed", "deferred", "found_bodies", "body_ids",
      "mailbox_version", "received_after", "retry_after"]))
    XCTAssertEqual(try GmailFixture.object(oldPending["listing"]), oldListing)
    let checkpoint: JSONObject = ["native_query_scope": .string(scope), "mailbox_version": .string("9"),
      "active_threads": .array([.string("a"), .string("b")]), "thread_versions": .object(["a": .string("8")]),
      "pending_collection": .object(oldPending)]
    values["previous"] = .object(checkpoint)
    let readIDs = GmailLocked<[String]>([])
    let resumed = try await GmailMailboxCollector(options: .init(values)).collectScan { operation, args, _ in
      if operation == "profile" { return GmailFixture.profile("11") }
      if operation == "threads" {
        let input = try GmailFixture.object(args["input"])
        XCTAssertEqual(input["after"], .string("live-cursor"))
        return GmailFixture.page([])
      }
      if operation == "thread" {
        let id = try GmailFixture.threadID(args); readIDs.withLock { $0.append(id) }
        throw GmailFixture.invalid()
      }
      throw GmailFixture.invalid()
    }
    XCTAssertEqual(readIDs.value, ["b"])
    XCTAssertEqual(resumed["complete"], .bool(false))
    let savedPending = try GmailFixture.object(GmailFixture.object(resumed["checkpoint"])["pending_collection"])
    let savedListing = try GmailFixture.object(savedPending["listing"])
    XCTAssertNil(savedListing["cursor"], "nil cursors must be omitted from the persisted wire format")

    values["previous"] = resumed["checkpoint"]
    let completed = try await GmailMailboxCollector(options: .init(values)).collectScan { operation, args, _ in
      if operation == "profile" { return GmailFixture.profile("12") }
      guard operation == "thread" else { throw GmailFixture.invalid() }
      let id = try GmailFixture.threadID(args); readIDs.withLock { $0.append(id) }
      return GmailFixture.thread(id, version: "9")
    }
    XCTAssertEqual(readIDs.value, ["b", "b"])
    XCTAssertEqual(completed["complete"], .bool(true))
    XCTAssertNil(try GmailFixture.object(completed["checkpoint"])["pending_collection"])
    XCTAssertEqual(try GmailFixture.object(GmailFixture.object(completed["checkpoint"])["thread_versions"]),
      ["a": .string("8"), "b": .string("9")])
  }

  func testScopeMatchesLegacyCanonicalJSONAndCannotCrossAccountsOrQueries() throws {
    var values = GmailFixture.options()
    let queries: JSONValue = .array([.string("in:inbox"), .string("件名:更新")])
    values["queries"] = queries
    XCTAssertEqual(try GmailCollectionOptions(values).scope, "c4ee206a2ab85491e2d01f5b517e8bd8153d904d46c784f926cbf25e0e9a89c5")
    values["accountId"] = .string("other")
    XCTAssertNotEqual(try GmailCollectionOptions(values).scope, "c4ee206a2ab85491e2d01f5b517e8bd8153d904d46c784f926cbf25e0e9a89c5")
  }

  func testOpaqueAccountIDsMatchSDKConfiguration() throws {
    var values = GmailFixture.options()
    for account in ["work.mail", "仕事用"] {
      values["accountId"] = .string(account)
      XCTAssertEqual(try GmailCollectionOptions(values).account, account)
    }
  }

  func testBodyBudgetRetainsAcceptedPrefixAndDoesNotAcknowledgeOversizedItem() async throws {
    let result = try await GmailMailboxCollector(options: .init(GmailFixture.options()), outputByteBudget: 100_000)
      .collectScan { operation, args, _ in
        if operation == "profile" { return GmailFixture.profile("10") }
        if operation == "threads" { return GmailFixture.page(["a", "b"]) }
        let id = args["threadId"] == .string("a") ? "a" : "b"
        var thread = GmailFixture.thread(id, version: "8")
        if id == "b" { thread["oversized"] = .string(String(repeating: "x", count: 100_000)) }
        return thread
      }
    XCTAssertEqual(result["invalidated"], .array([.string("a")]))
    XCTAssertEqual(result["complete"], .bool(false))
    XCTAssertTrue((try result["failures"]?.compactJSONString() ?? "").contains("output-budget"))
    XCTAssertTrue((try result["failures"]?.compactJSONString() ?? "").contains("\"threadId\":\"b\""))
    let checkpoint = try GmailFixture.object(result["checkpoint"])
    XCTAssertNil(try GmailFixture.object(checkpoint["thread_versions"])["b"])
    XCTAssertLessThan(try JSONEncoder().encode(result).count, 100_000)
  }

  func testAllFailedItemsReceiveFairRetryTurnsAtOneItemBudget() async throws {
    var values = GmailFixture.options(); values["maxThreads"] = .integer(1)
    let attempts = GmailLocked<[String]>([])
    for _ in 0..<6 {
      let instant = GmailLocked(Date(timeIntervalSince1970: 1000))
      let result = try await GmailMailboxCollector(options: .init(values), deadline: instant.value.addingTimeInterval(5), clock: { instant.value }).collectScan { operation, args, _ in
        if operation == "profile" { return GmailFixture.profile("10") }
        if operation == "threads" { return GmailFixture.page(["a", "b"]) }
        if case let .string(id)? = args["threadId"] {
          attempts.withLock { $0.append(id) }
          instant.withLock { $0 = $0.addingTimeInterval(2) }
        }
        throw GmailFixture.invalid()
      }
      values["previous"] = result["checkpoint"]
    }
    XCTAssertEqual(attempts.value, ["a", "b", "a", "b", "a", "b"])
  }

  func testPoisonBacklogDoesNotBlockFreshMailAndPreservesExactOldCursor() async throws {
    var values = GmailFixture.options(); values["maxThreads"] = .integer(1)
    let attempt = GmailLocked(0)
    for turn in 0..<3 {
      let result = try await GmailMailboxCollector(options: .init(values)).collect { operation, args, _ in
        if operation == "profile" { return GmailFixture.profile(turn == 0 ? "10" : "11") }
        if operation == "threads" {
          let input = try GmailFixture.object(args["input"])
          if input["after"] == .string("poison-cursor") {
            XCTAssertEqual(input["after"], .string("poison-cursor"))
            throw GmailFixture.invalid()
          }
          XCTAssertNil(input["after"])
          return turn == 0 ? GmailFixture.page(["a"], cursor: "poison-cursor") : GmailFixture.page(["new"])
        }
        if args["threadId"] == .string("a") { throw GmailFixture.invalid() }
        attempt.withLock { $0 += 1 }; return GmailFixture.thread("new", version: "9")
      }
      values["previous"] = result["checkpoint"]
      XCTAssertEqual(result["complete"], .bool(false))
      if turn == 2 {
        XCTAssertEqual(result["invalidated"], .array([.string("new")]))
        let cp = try GmailFixture.object(result["checkpoint"])
        XCTAssertNil(cp["mailbox_version"])
        guard case let .array(queue)? = cp["pending_scans"] else { return XCTFail("lost unresolved scan") }
        let pending = try GmailFixture.object(queue[0]); let listing = try GmailFixture.object(pending["listing"])
        XCTAssertEqual(listing["cursor"], .string("poison-cursor"))
      }
    }
    XCTAssertEqual(attempt.value, 1)
  }

  func testLongRunningScanKeepsDiscoveryFloorAndScopesSurviveBodyIntentSwitch() async throws {
    var values = GmailFixture.options(); values["maxThreads"] = .integer(1)
    let firstTime = Date(timeIntervalSince1970: 1_000_000)
    let first = try await GmailMailboxCollector(options: .init(values), clock: { firstTime }).collect { operation, args, _ in
      if operation == "profile" { return GmailFixture.profile("10") }
      if operation == "threads" {
        if try GmailFixture.object(args["input"])["after"] == .string("literal-old-cursor") { throw GmailFixture.invalid() }
        return GmailFixture.page(["a"], cursor: "literal-old-cursor")
      }
      throw GmailFixture.invalid()
    }
    let original = try GmailFixture.object(first["checkpoint"])
    var switched = values; switched["bodyMessageIds"] = .array([.string("message-b")]); switched["previous"] = .object(original)
    let body = try await GmailMailboxCollector(options: .init(switched)).collect { operation, _, _ in
      if operation == "profile" { return GmailFixture.profile("11") }
      return GmailFixture.page([])
    }
    let bodyCP = try GmailFixture.object(body["checkpoint"])
    let scopes = try GmailFixture.object(bodyCP["collection_scopes"])
    XCTAssertEqual(scopes[try GmailCollectionOptions(values).scope], .object(original))
    values["previous"] = body["checkpoint"]
    // Resume the original literal cursor, then allow fresh discovery with a
    // two-day jump. Neither the body intent nor time passage drops the floor.
    let resumed = try await GmailMailboxCollector(options: .init(values), clock: { firstTime.addingTimeInterval(172_800) })
      .collect { operation, args, _ in
        if operation == "profile" { return GmailFixture.profile("12") }
        if operation == "threads" {
          XCTAssertEqual(try GmailFixture.object(args["input"])["after"], .string("literal-old-cursor"))
          throw GmailFixture.invalid()
        }
        throw GmailFixture.invalid()
      }
    values["previous"] = resumed["checkpoint"]
    _ = try await GmailMailboxCollector(options: .init(values), clock: { firstTime.addingTimeInterval(172_800) })
      .collect { operation, args, _ in
        if operation == "profile" { return GmailFixture.profile("12") }
        let input = try GmailFixture.object(args["input"])
        guard case let .string(after)? = input["receivedAfter"] else { throw GmailFixture.invalid() }
        XCTAssertLessThanOrEqual(try xInstant(after), firstTime.addingTimeInterval(-86_400))
        XCTAssertNil(input["after"])
        return GmailFixture.page([])
      }
  }

  func testDrainingOldCursorCannotRemoveAlreadyAcquiredFreshThreadVersions() async throws {
    var values = GmailFixture.options(); values["maxThreads"] = .integer(1)
    for turn in 0..<4 {
      let result = try await GmailMailboxCollector(options: .init(values)).collect { operation, args, _ in
        if operation == "profile" { return GmailFixture.profile(turn == 0 ? "10" : "11") }
        if operation == "threads" {
        if turn == 0 {
          let input = try GmailFixture.object(args["input"])
          if input["after"] == .string("old") { throw GmailFixture.invalid() }
          return GmailFixture.page(["a"], cursor: "old")
        }
          if turn == 1 { throw GmailFixture.invalid() }
          return GmailFixture.page(turn == 2 ? ["b"] : [])
        }
        if turn < 3, args["threadId"] == .string("a") { throw GmailFixture.invalid() }
        return GmailFixture.thread(turn == 2 ? "b" : "a", version: "8")
      }
      values["previous"] = result["checkpoint"]
      if turn == 3 {
        let cp = try GmailFixture.object(result["checkpoint"])
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
    var values = GmailFixture.options(); values["previous"] = .object(["collection_scopes": .object(scopes)])
    let result = try await GmailMailboxCollector(options: .init(values)).collect { operation, _, _ in
      operation == "profile" ? GmailFixture.profile("10") : GmailFixture.page([])
    }
    let kept = try GmailFixture.object(GmailFixture.object(result["checkpoint"])["collection_scopes"])
    XCTAssertEqual(kept.count, 64)
    XCTAssertEqual(kept["pending"], scopes["pending"])
    XCTAssertNil(kept["0"])
  }

  func testPermanentPoisonDoesNotAccumulateOneScanPerFreshProfile() async throws {
    var values = GmailFixture.options(); values["maxThreads"] = .integer(2)
    let freshReads = GmailLocked(0)
    for turn in 0..<70 {
      let result = try await GmailMailboxCollector(options: .init(values)).collect { operation, args, _ in
        if operation == "profile" { return GmailFixture.profile(String(10 + turn)) }
        if operation == "threads" { return GmailFixture.page(["new-" + String(turn), "poison"]) }
        guard case let .string(id)? = args["threadId"] else { throw GmailFixture.invalid() }
        if id == "poison" { throw GmailFixture.invalid() }
        freshReads.withLock { $0 += 1 }; return GmailFixture.thread(id, version: String(10 + turn))
      }
      values["previous"] = result["checkpoint"]
      let cp = try GmailFixture.object(result["checkpoint"])
      guard case let .array(scans)? = cp["pending_scans"] else { return XCTFail("poison was acknowledged") }
      XCTAssertEqual(scans.count, 1, "exhausted listings share one unresolved-ID backlog")
      XCTAssertNil(cp["mailbox_version"])
    }
    XCTAssertEqual(freshReads.value, 35)
  }

  func testRequestedBodyFoundByFreshScanRemainsKnownWhenOldCursorDrains() async throws {
    var values = GmailFixture.options(); values["maxThreads"] = .integer(1)
    values["bodyMessageIds"] = .array([.string("message-b")])
    for turn in 0..<4 {
      let result = try await GmailMailboxCollector(options: .init(values)).collect { operation, args, _ in
        if operation == "profile" { return GmailFixture.profile(turn == 0 ? "10" : "11") }
        if operation == "threads" {
          if turn == 0 {
            let input = try GmailFixture.object(args["input"])
            if input["after"] == .string("old") { throw GmailFixture.invalid() }
            return GmailFixture.page(["a"], cursor: "old")
          }
          if turn == 1 { throw GmailFixture.invalid() }
          return GmailFixture.page(turn == 2 ? ["b"] : [])
        }
        if operation == "messageBodyBytes" {
          return ["accountId": .string("personal"), "messageId": .string("message-b"), "complete": .bool(true)]
        }
        if turn < 3, args["threadId"] == .string("a") { throw GmailFixture.invalid() }
        return GmailFixture.thread(turn == 2 ? "b" : "a", version: "8")
      }
      values["previous"] = result["checkpoint"]
      if turn == 3 {
        let cp = try GmailFixture.object(result["checkpoint"])
        XCTAssertEqual(cp["found_body_ids"], .array([.string("message-b")]))
        XCTAssertNil(cp["pending_scans"])
        XCTAssertEqual(result["complete"], .bool(true))
      }
    }
    let fresh = try await GmailMailboxCollector(options: .init(values)).collect { operation, _, _ in
      operation == "profile" ? GmailFixture.profile("12") : GmailFixture.page([])
    }
    XCTAssertEqual(fresh["complete"], .bool(true), "a fulfilled body intent does not become missing on a later empty fresh listing")
    XCTAssertNil(try GmailFixture.object(fresh["checkpoint"])["pending_scans"])
  }

  func testOneRunListsEveryPageAtPageSizeFiftyWithOneThreadConcurrency() async throws {
    var values = GmailFixture.options(); values["maxThreads"] = .integer(1)
    let pageNumber = GmailLocked(0)
    let pageSizes = GmailLocked<[Int]>([])
    let result = try await GmailMailboxCollector(options: .init(values)).collectScan { operation, args, _ in
      if operation == "profile" { return GmailFixture.profile("10") }
      if operation == "threads" {
        let input = try GmailFixture.object(args["input"])
        pageSizes.withLock { $0.append(GmailFixture.integer(input["first"]) ?? -1) }
        let number = pageNumber.withLock { value -> Int in value += 1; return value }
        switch number {
        case 1: return GmailFixture.page(["a", "b"], cursor: "p1")
        case 2: return GmailFixture.page(["c", "d"], cursor: "p2")
        default: return GmailFixture.page(["e"])
        }
      }
      return GmailFixture.thread(try GmailFixture.threadID(args), version: "8")
    }
    XCTAssertEqual(pageNumber.value, 3)
    XCTAssertEqual(pageSizes.value, [50, 50, 50])
    XCTAssertEqual(result["complete"], .bool(true))
    XCTAssertNil(try GmailFixture.object(result["checkpoint"])["pending_collection"])
    XCTAssertEqual(result["invalidated"], .array(["a", "b", "c", "d", "e"].map(JSONValue.string)))
    XCTAssertEqual(result["failures"], .array([]))
  }

  func testThreadReadConcurrencyIsBoundedAndResultsStayInListingOrder() async throws {
    var values = GmailFixture.options(); values["maxThreads"] = .integer(4)
    let state = GmailLocked((active: 0, high: 0))
    let ids = (0..<12).map { String(format: "t%02d", $0) }
    let result = try await GmailMailboxCollector(options: .init(values)).collectScan { operation, args, _ in
      if operation == "profile" { return GmailFixture.profile("10") }
      if operation == "threads" { return GmailFixture.page(ids) }
      let id = try GmailFixture.threadID(args)
      let high = state.withLock { value -> Int in
        value.active += 1; value.high = max(value.high, value.active); return value.high
      }
      _ = high
      defer { state.withLock { $0.active -= 1 } }
      let delay = id == "t00" ? 40 : (id == "t01" ? 30 : 2)
      try await Task.sleep(for: .milliseconds(delay))
      return GmailFixture.thread(id, version: "8")
    }
    XCTAssertGreaterThanOrEqual(state.value.high, 2)
    XCTAssertLessThanOrEqual(state.value.high, 4)
    XCTAssertEqual(result["invalidated"], .array(ids.map(JSONValue.string)))
    let threads = try GmailFixture.objects(result["threads"])
    XCTAssertEqual(threads.compactMap { if case let .string(id)? = $0["id"] { return id }; return nil }, ids)
    XCTAssertEqual(result["complete"], .bool(true))
  }

  func testThreadReadConcurrencyClampsAtSixteen() async throws {
    var values = GmailFixture.options(); values["maxThreads"] = .integer(10_000)
    let state = GmailLocked((active: 0, high: 0))
    let ids = (0..<40).map { String(format: "c%02d", $0) }
    let result = try await GmailMailboxCollector(options: .init(values)).collectScan { operation, args, _ in
      if operation == "profile" { return GmailFixture.profile("10") }
      if operation == "threads" { return GmailFixture.page(ids) }
      let id = try GmailFixture.threadID(args)
      state.withLock { value in value.active += 1; value.high = max(value.high, value.active) }
      defer { state.withLock { $0.active -= 1 } }
      try await Task.sleep(for: .milliseconds(3))
      return GmailFixture.thread(id, version: "8")
    }
    XCTAssertGreaterThan(state.value.high, 4)
    XCTAssertLessThanOrEqual(state.value.high, 16)
    XCTAssertEqual(result["complete"], .bool(true))
  }

  func testRequestStartsShareOneLimiterAcrossWorkers() async throws {
    var values = GmailFixture.options()
    values["maxThreads"] = .integer(4); values["minRequestIntervalSeconds"] = .number(2.5)
    let waits = GmailLocked<[Double]>([])
    let result = try await GmailMailboxCollector(options: .init(values), clock: { Date(timeIntervalSince1970: 1000) },
      wait: { duration in waits.withLock { $0.append(duration) } }).collectScan { operation, args, _ in
      if operation == "profile" { return GmailFixture.profile("10") }
      if operation == "threads" { return GmailFixture.page(["a", "b", "c", "d"]) }
      return GmailFixture.thread(try GmailFixture.threadID(args), version: "8")
    }
    XCTAssertEqual(result["requestCount"], .integer(6))
    XCTAssertEqual(waits.value.sorted(), [2.5, 5.0, 7.5, 10.0, 12.5])
  }

  func testListingLimitRecordsListingLimitStage() async throws {
    let pages = GmailLocked(0)
    let result = try await GmailMailboxCollector(options: .init(GmailFixture.options())).collectScan { operation, args, _ in
      if operation == "profile" { return GmailFixture.profile("10") }
      if operation == "threads" {
        let number = pages.withLock { value -> Int in value += 1; return value }
        let first = try XCTUnwrap(GmailFixture.integer(GmailFixture.object(args["input"])["first"]))
        XCTAssertEqual(first, 50)
        let ids = (0..<Int(first)).map { String(format: "t%05d", (number - 1) * 50 + $0) }
        return GmailFixture.page(ids, cursor: "p\(number)")
      }
      throw GmailFixture.invalid()
    }
    XCTAssertEqual(pages.value, 200)
    XCTAssertEqual(result["complete"], .bool(false))
    XCTAssertTrue((try result["failures"]?.compactJSONString() ?? "").contains("listing-limit"))
    let pending = try GmailFixture.object(GmailFixture.object(result["checkpoint"])["pending_collection"])
    XCTAssertEqual(try GmailFixture.object(pending["listing"])["maximum"], .integer(10_000))
  }

  func testOversizedPageAtItemLimitKeepsResumableListingCheckpoint() async throws {
    var values = GmailFixture.options(); values["maxThreads"] = .integer(1)
    let scope = try GmailCollectionOptions(values).scope
    let ids = (0..<9_999).map { "t\($0)" }
    let listingState: JSONObject = ["format": .integer(1), "queries": .array([.string("in:inbox")]),
      "maximum": .integer(10_000), "itemsPath": .string("/edges"), "identityPath": .string("/node/id"),
      "cursorPath": .string("/pageInfo/endCursor"), "hasMorePath": .string("/pageInfo/hasNextPage"),
      "identitySyntax": .string("identifier"), "index": .integer(0), "cursor": .string("at-limit"),
      "visited": .array([.string("at-limit")]), "items": .array(ids.map(JSONValue.string)), "pageCount": .integer(200)]
    let pending: JSONObject = ["listing": .object(listingState), "completed": .array([]), "deferred": .array([]),
      "found_bodies": .array([]), "body_ids": .array([]), "mailbox_version": .string("10"),
      "received_after": .null, "retry_after": .null]
    values["previous"] = .object(["native_query_scope": .string(scope), "mailbox_version": .string("9"),
      "pending_collection": .object(pending)])
    let first = try await GmailMailboxCollector(options: .init(values)).collectScan { operation, args, _ in
      if operation == "profile" { return GmailFixture.profile("11") }
      if operation == "threads" {
        let input = try GmailFixture.object(args["input"])
        XCTAssertEqual(input["first"], .integer(1))
        XCTAssertEqual(input["after"], .string("at-limit"))
        return GmailFixture.page(["overflow-one", "overflow-two"], cursor: "overflow-cursor")
      }
      return GmailFixture.thread(try GmailFixture.threadID(args), version: "8")
    }
    XCTAssertTrue((try first["failures"]?.compactJSONString() ?? "").contains("listing-limit"))
    XCTAssertEqual(first["complete"], .bool(false))
    let firstCheckpoint = try GmailFixture.object(first["checkpoint"])
    let savedPending = try GmailFixture.object(try XCTUnwrap(firstCheckpoint["pending_collection"], "first run should save pending state"))
    let savedListing = try GmailFixture.object(try XCTUnwrap(savedPending["listing"], "first run should save listing"))
    XCTAssertEqual(savedListing["cursor"], .string("at-limit"))
    XCTAssertEqual(try GmailFixture.array(savedListing["items"]).count, 9_999)
    XCTAssertFalse(try GmailFixture.array(savedListing["items"]).contains(.string("overflow-one")))

    values["previous"] = first["checkpoint"]
    let next = try await GmailMailboxCollector(options: .init(values)).collectScan { operation, args, _ in
      if operation == "profile" { return GmailFixture.profile("12") }
      if operation == "threads" {
        let input = try GmailFixture.object(args["input"])
        XCTAssertEqual(input["after"], .string("at-limit"))
        XCTAssertEqual(input["first"], .integer(1))
        return GmailFixture.page(["last-id"])
      }
      return GmailFixture.thread(try GmailFixture.threadID(args), version: "8")
    }
    XCTAssertEqual(next["complete"], .bool(true), "the next run should accept the saved prefix and finish the listing")
    XCTAssertNil(try GmailFixture.object(next["checkpoint"])["pending_collection"])
  }

  func testCoordinatorPrefetchedProfileKeepsRequestCount() async throws {
    let profiles = GmailLocked(0)
    let result = try await GmailMailboxCollector(options: .init(GmailFixture.options())).collect { operation, _, _ in
      if operation == "profile" { profiles.withLock { $0 += 1 }; return GmailFixture.profile("10") }
      if operation == "threads" { return GmailFixture.page(["a"]) }
      return GmailFixture.thread("a", version: "8")
    }
    XCTAssertEqual(profiles.value, 1)
    XCTAssertEqual(result["requestCount"], .integer(3))
  }

}

private enum GmailFixture {
  static func options() -> JSONObject {
    ["accountId": .string("personal"), "queries": .array([.string("in:inbox")]), "minRequestIntervalSeconds": .integer(0),
      "lookbackHours": .integer(24)]
  }

  static func input(_ options: JSONObject) -> WorkflowAddonExecutionInput {
    .init(workflowId: "gmail-collection", stepId: "collect", nodeId: "collect", addon: .init(name: "riela/gmail-collect", version: "1",
      config: ["options": .string("{{options}}"), "context": .string("{{opaqueContext}}")]),
      variables: ["options": .object(options), "opaqueContext": .string("{{literal_content}}")])
  }

  static func profile(_ version: String) -> JSONObject {
    ["emailAddress": .string("owner@example.test"), "historyId": .string(version)]
  }

  static func page(_ ids: [String], cursor: String? = nil) -> JSONObject {
    ["edges": .array(ids.map { .object(["node": .object(["id": .string($0)])]) }),
      "pageInfo": .object(["hasNextPage": .bool(cursor != nil), "endCursor": cursor.map(JSONValue.string) ?? .null])]
  }

  static func thread(_ id: String, version: String) -> JSONObject {
    ["id": .string(id), "providerMetadata": .object(["gmail": .object(["historyId": .string(version)])]),
      "messages": .array([.object(["id": .string("message-" + id), "accountId": .string("personal"), "threadId": .string(id),
        "textBody": .string("private fixture"), "subject": .string("Business request")])])]
  }

  static func object(_ value: JSONValue?) throws -> JSONObject {
    guard case let .object(value)? = value else { throw invalid() }
    return value
  }

  static func threadID(_ arguments: JSONObject) throws -> String {
    guard case let .string(id)? = arguments["threadId"] else { throw invalid() }
    return id
  }

  static func integer(_ value: JSONValue?) -> Int? {
    guard case let .integer(number)? = value else { return nil }
    return Int(number)
  }

  static func objects(_ value: JSONValue?) throws -> [JSONObject] {
    guard case let .array(values)? = value else { throw invalid() }
    return try values.map { try object($0) }
  }

  static func array(_ value: JSONValue?) throws -> [JSONValue] {
    guard case let .array(values)? = value else { throw invalid() }
    return values
  }

  static func invalid() -> AdapterExecutionError { .init(.invalidOutput, "invalid synthetic Gmail fixture") }
}

private final class GmailLocked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value

  init(_ value: Value) { stored = value }

  var value: Value { lock.withLock { stored } }

  func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
    try lock.withLock { try body(&stored) }
  }

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
