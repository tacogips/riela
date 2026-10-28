import Foundation
import RielaAddonSupport
import RielaCore

/// Provider collection policy only. Callers inspect returned threads before
/// committing the metadata checkpoint or exporting any content.
struct GmailCollectionOptions {
  let account: String
  let queries: [String]
  let maximum: Int
  let receivedAfter: String?
  let window: [String]?
  let lookbackHours: Int
  let bodyIDs: Set<String>
  let providerBodyMetadata: Bool
  let interval: Double
  var previous: JSONObject
  let scope: String

  init(_ value: JSONObject) throws {
    guard Set(value.keys).isSubset(of: ["accountId", "queries", "maxThreads", "receivedAfter", "bodyMessageIds",
      "providerBodyMetadata", "minRequestIntervalSeconds", "previous", "window", "lookbackHours"]),
      case let .string(account)? = value["accountId"], !account.isEmpty, account.utf8.count <= 256,
      case let .array(queries)? = value["queries"], (1...64).contains(queries.count),
      queries.allSatisfy({ if case let .string(q) = $0 { return !q.isEmpty && q.utf8.count <= 8192 }; return false }),
      case let .integer(maximum) = value["maxThreads"] ?? .integer(100), (1...10_000).contains(maximum),
      case let .array(ids) = value["bodyMessageIds"] ?? .array([]), ids.count <= 32,
      ids.allSatisfy({ if case let .string(id) = $0 { return gmailIdentifier(id) }; return false }),
      case let .bool(metadata) = value["providerBodyMetadata"] ?? .bool(false),
      case let .object(previous) = value["previous"] ?? .object([:]),
      case let .integer(lookback) = value["lookbackHours"] ?? .integer(24), (1...168).contains(lookback)
    else { throw gmailCollectionInvalid() }
    let window: [String]?
    switch value["window"] {
    case nil, .null?: window = nil
    case let .array(bounds)?:
      guard bounds.count == 2, case let .string(start) = bounds[0], case let .string(end) = bounds[1],
        try xInstant(start) < xInstant(end) else { throw gmailCollectionInvalid() }
      window = [start, end]
    default: throw gmailCollectionInvalid()
    }
    let after: String?
    switch value["receivedAfter"] {
    case nil, .null?: after = nil
    case let .string(text)?: _ = try xInstant(text); after = text
    default: throw gmailCollectionInvalid()
    }
    let interval: Double
    switch value["minRequestIntervalSeconds"] ?? .number(2.5) {
    case let .integer(number): interval = Double(number)
    case let .number(number): interval = number
    default: throw gmailCollectionInvalid()
    }
    guard interval.isFinite, (0...60).contains(interval) else { throw gmailCollectionInvalid() }
    guard window == nil || after == nil else { throw gmailCollectionInvalid() }
    self.account = account; self.maximum = Int(maximum); self.window = window; self.lookbackHours = Int(lookback)
    let originals = queries.compactMap { nonEmptyString($0) }
    if let window {
      let first = Int64(floor(try xInstant(window[0]).timeIntervalSince1970)) - 1
      let last = Int64(ceil(try xInstant(window[1]).timeIntervalSince1970))
      self.queries = originals.map { query in
        query.replacingOccurrences(of: #"(?<!\S)(?:newer_than|older_than|after|before|newer|older):\S+"#,
          with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
          + " after:" + String(first) + " before:" + String(last)
      }
    } else { self.queries = originals }
    self.bodyIDs = Set(ids.compactMap { nonEmptyString($0) }); self.providerBodyMetadata = metadata
    guard bodyIDs.count == ids.count else { throw gmailCollectionInvalid() }
    self.receivedAfter = after; self.interval = interval; self.previous = previous
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var scopeContext: JSONObject = ["account": .string(account), "queries": .array(self.queries.map(JSONValue.string)),
      "window": window.map { .array($0.map(JSONValue.string)) } ?? .object(["lookback_hours": .integer(lookback)])]
    // Preserve legacy empty-body scope identities. Explicit body requests are
    // separate acquisition intents and must not reuse another request's cursor.
    if let after { scopeContext["received_after"] = .string(after) }
    if !bodyIDs.isEmpty { scopeContext["body_ids"] = .array(bodyIDs.sorted().map(JSONValue.string)) }
    self.scope = JSONCanonical.sha256Hex(try encoder.encode(scopeContext))
  }
}

struct GmailMailboxCollector {
  let options: GmailCollectionOptions
  var deadline: Date?
  var outputByteBudget = 8_000_000
  var scanReceivedAfter: String?
  var foundBodyIDs = Set<String>()
  var clock: @Sendable () -> Date = { Date() }
  var wait: @Sendable (Double) async throws -> Void = { if $0 > 0 { try await Task.sleep(for: .seconds($0)) } }

  func collectScan(
    prefetchedProfile: JSONObject? = nil,
    fetch: @escaping @Sendable (String, JSONObject, [String]) async throws -> JSONObject
  ) async throws -> JSONObject {
    let startedAt = clock()
    let limiter = GmailCollectionRequestLimiter(interval: options.interval, deadline: deadline, clock: clock, wait: wait)
    var deadlineRecorded = false
    func recordDeadline() {
      if !deadlineRecorded { recordFailure(failure("deadline")); deadlineRecorded = true }
    }
    var checkpoint = options.previous
    if checkpoint["native_query_scope"] != .string(options.scope) {
      checkpoint.removeValue(forKey: "mailbox_version"); checkpoint.removeValue(forKey: "thread_versions")
      checkpoint.removeValue(forKey: "pending_collection")
    }
    checkpoint["native_query_scope"] = .string(options.scope)
    let profile = try await loadProfile(prefetchedProfile, limiter: limiter, fetch: fetch)
    if let email = nonEmptyString(profile["emailAddress"]) {
      let hash = String(JSONCanonical.sha256Hex(Data(email.utf8)).prefix(24))
      if let old = checkpoint["mailbox_hash"], old != .string(hash) {
        checkpoint = ["native_query_scope": .string(options.scope), "reset_records": .bool(true)]
      }
      checkpoint["mailbox_hash"] = .string(hash)
    }
    let mailbox = try gmailVersion(profile["historyId"])
    let unchanged = mailbox != nil && checkpoint["mailbox_version"] == mailbox.map(JSONValue.string)
    var threads: [JSONObject] = [], invalidated: [String] = [], failures: [JSONValue] = []
    var failureCount = 0
    func recordFailure(_ value: JSONValue) {
      failureCount += 1
      if failures.count < 128 { failures.append(value) }
    }
    var complete = true
    if !unchanged || !options.bodyIDs.isEmpty || checkpoint["pending_collection"] != nil {
      var page = try advancePage(nil, response: nil)
      var completed = Set<String>(), deferred = Set<String>(), found = foundBodyIDs
      var retryAfter: String?
      var frozenMailbox = mailbox
      var frozenAfter = scanReceivedAfter ?? options.receivedAfter ?? (options.window == nil
        ? ISO8601DateFormatter().string(from: startedAt.addingTimeInterval(-Double(options.lookbackHours) * 3600)) : nil)
      if let saved = checkpoint["pending_collection"] {
        guard case let .object(pending) = saved,
          Set(pending.keys).isSubset(of: ["listing", "completed", "deferred", "found_bodies", "body_ids", "mailbox_version", "received_after", "retry_after"]),
          pending["body_ids"] == .array(options.bodyIDs.sorted().map(JSONValue.string)),
          case let .object(listing)? = pending["listing"], listing["queries"] == .array(options.queries.map(JSONValue.string)),
          listing["maximum"] == .integer(10_000) else { throw gmailCollectionInvalid() }
        page = try advancePage(.object(listing), response: nil)
        completed = try gmailIDSet(pending["completed"]); deferred = try gmailIDSet(pending["deferred"])
        found = try gmailIDSet(pending["found_bodies"])
        switch pending["retry_after"] {
        case nil, .null?: retryAfter = nil
        case let .string(id)?: guard gmailIdentifier(id) else { throw gmailCollectionInvalid() }; retryAfter = id
        default: throw gmailCollectionInvalid()
        }
        let selected = try gmailIDSet(page["items"])
        guard completed.isSubset(of: selected), deferred.isSubset(of: selected), completed.isDisjoint(with: deferred),
          found.isSubset(of: options.bodyIDs) else { throw gmailCollectionInvalid() }
        frozenMailbox = try gmailVersion(pending["mailbox_version"])
        switch pending["received_after"] {
        case .null?: frozenAfter = nil
        case let .string(value)?: _ = try xInstant(value); frozenAfter = value
        default: throw gmailCollectionInvalid()
        }
      }
      let listingResult = try await listPages(startingAt: page, receivedAfter: frozenAfter, limiter: limiter, fetch: fetch)
      page = listingResult.page
      if listingResult.failureStage == "deadline" { recordDeadline() } else if let failureStage = listingResult.failureStage {
        recordFailure(failure(failureStage))
      }
      guard case let .array(ids)? = page["items"] else { throw gmailCollectionInvalid() }
      let listing = ids.compactMap { nonEmptyString($0) }
      var versions: JSONObject
      if case let .object(saved)? = checkpoint["thread_versions"] { versions = saved } else { versions = [:] }
      // Failed items return after never-attempted items, including when a run's
      // item budget is one. A poison item cannot monopolize every subsequent run.
      let retryIDs = listing.filter { !completed.contains($0) && deferred.contains($0) }.sorted()
      let rotated = retryAfter.map { last in retryIDs.filter { $0 > last } + retryIDs.filter { $0 <= last } } ?? retryIDs
      let queue = listing.filter { !completed.contains($0) && !deferred.contains($0) } + rotated
      let concurrency = min(options.maximum, 16)
      let versionsSnapshot = versions
      var launched = 0, acceptCursor = 0, stopScheduling = false
      var buffered: [Int: GmailThreadReadOutcome] = [:]
      var processing = GmailThreadProcessingState(checkpoint: checkpoint, page: page, listing: listing,
        frozenMailbox: frozenMailbox, frozenAfter: frozenAfter, outputByteBudget: outputByteBudget,
        completed: completed, deferred: deferred, found: found, retryAfter: retryAfter, versions: versions)
      processing.prepareOutputBudget(options: options)
      try await withThrowingTaskGroup(of: (Int, GmailThreadReadOutcome).self) { group in
        func launchAvailable() {
          while launched < queue.count, launched - acceptCursor < concurrency, !stopScheduling {
            let index = launched
            let id = queue[index]
            let previous = versionsSnapshot[id]
            launched += 1
            group.addTask {
              (index, try await readThread(id: id, previousVersion: previous, limiter: limiter, fetch: fetch))
            }
          }
        }
        launchAvailable()
        while let (index, outcome) = try await group.next() {
          buffered[index] = outcome
          if outcome.isDeadlineRefusal { stopScheduling = true }
          while let next = buffered.removeValue(forKey: acceptCursor) {
            let id = queue[acceptCursor]
            _ = acceptThreadOutcome(next, id: id, state: &processing)
            if processing.stopScheduling { stopScheduling = true }
            if processing.deadlineRefused { recordDeadline() }
            acceptCursor += 1
          }
          launchAvailable()
        }
      }
      try Task.checkCancellation()
      threads = processing.threads; invalidated = processing.invalidated
      completed = processing.completed; deferred = processing.deferred; found = processing.found
      retryAfter = processing.retryAfter; versions = processing.versions
      failureCount += processing.failureCount
      failures.append(contentsOf: processing.failures)
      if failures.count > 128 { failures = Array(failures.prefix(128)) }
      complete = page["complete"] == .bool(true) && Set(listing).isSubset(of: completed) && options.bodyIDs.isSubset(of: found)
      if complete {
        versions = versions.filter { listing.contains($0.key) }
        checkpoint["active_threads"] = .array(listing.sorted().map(JSONValue.string))
        checkpoint["mailbox_version"] = frozenMailbox.map(JSONValue.string) ?? .null
        checkpoint.removeValue(forKey: "pending_collection")
      } else {
        let prior: [String]
        if case let .array(values)? = checkpoint["active_threads"] { prior = values.compactMap { nonEmptyString($0) } } else { prior = [] }
        checkpoint["active_threads"] = .array(Set(prior + listing).sorted().map(JSONValue.string))
        checkpoint["pending_collection"] = .object(["listing": page["state"] ?? .null,
          "completed": .array(completed.sorted().map(JSONValue.string)), "deferred": .array(deferred.sorted().map(JSONValue.string)),
          "found_bodies": .array(found.sorted().map(JSONValue.string)), "body_ids": .array(options.bodyIDs.sorted().map(JSONValue.string)),
          "mailbox_version": frozenMailbox.map(JSONValue.string) ?? .null, "received_after": frozenAfter.map(JSONValue.string) ?? .null,
            "retry_after": retryAfter.map(JSONValue.string) ?? .null])
        if page["complete"] == .bool(true), Set(listing).isSubset(of: completed), !options.bodyIDs.isSubset(of: found) {
          recordFailure(failure("requested-body"))
        }
      }
      checkpoint["thread_versions"] = .object(versions)
    }
    checkpoint["checked_at"] = .string(ISO8601DateFormatter().string(from: clock()))
    checkpoint["unchanged_mailbox"] = .bool(unchanged)
    if failureCount > failures.count {
      failures.append(.object(["stage": .string("additional-failures"), "count": .integer(Int64(failureCount - failures.count))]))
    }
    let result: JSONObject = ["threads": .array(threads.map(JSONValue.object)), "checkpoint": .object(checkpoint),
      "invalidated": .array(invalidated.map(JSONValue.string)), "complete": .bool(complete),
      "failures": .array(failures), "requestCount": .integer(Int64(await limiter.grantedCount))]
    guard try JSONEncoder().encode(result).count <= outputByteBudget else { throw gmailCollectionInvalid() }
    return result
  }

  private func readThread(
    id: String,
    previousVersion: JSONValue?,
    limiter: GmailCollectionRequestLimiter,
    fetch: @escaping @Sendable (String, JSONObject, [String]) async throws -> JSONObject
  ) async throws -> GmailThreadReadOutcome {
    var started = false
    func request(_ operation: String, _ arguments: JSONObject, _ selection: [String]) async throws -> JSONObject {
      try await limiter.acquire()
      started = true
      return try await fetch(operation, arguments, selection)
    }
    do {
      let arguments: JSONObject = ["accountId": .string(options.account), "threadId": .string(id)]
      if let previous = try gmailVersion(previousVersion), options.bodyIDs.isEmpty {
        let metadata = try await request("thread", arguments, ["id", "providerMetadata.gmail.historyId"])
        guard metadata["id"] == .string(id) else { throw gmailCollectionInvalid() }
        if try threadVersion(metadata) == previous { return .unchanged }
      }
      var thread = try await request("thread", arguments, Self.threadSelection)
      guard thread["id"] == .string(id), case let .array(rawMessages)? = thread["messages"] else { throw gmailCollectionInvalid() }
      let stamp = try threadVersion(thread)
      var messages: [JSONValue] = [], threadBodies = Set<String>()
      for value in rawMessages {
        guard case var .object(message) = value, let messageID = nonEmptyString(message["id"]), gmailIdentifier(messageID),
          message["accountId"] == .string(options.account), message["threadId"] == .string(id) else { throw gmailCollectionInvalid() }
        if options.bodyIDs.contains(messageID) {
          let body = try await request("messageBodyBytes", ["accountId": .string(options.account), "messageId": .string(messageID),
            "maxBytes": .integer(2_097_152)], bodySelection)
          guard body["accountId"] == .string(options.account), body["messageId"] == .string(messageID), body["complete"] == .bool(true) else {
            throw gmailCollectionInvalid()
          }
          message["_body_bytes"] = .object(body); threadBodies.insert(messageID)
        }
        messages.append(.object(message))
      }
      thread["messages"] = .array(messages); thread["_fetched_at"] = .string(ISO8601DateFormatter().string(from: clock()))
      return .fetched(thread: thread, stamp: stamp, bodies: threadBodies)
    } catch is CancellationError { throw CancellationError() } catch is GmailCollectionDeadlineRefusal {
      return started ? .refusedAfterStart : .refusedBeforeStart
    } catch {
      if Task.isCancelled { throw CancellationError() }
      return .failed
    }
  }

  private func listPages(
    startingAt initialPage: JSONObject,
    receivedAfter: String?,
    limiter: GmailCollectionRequestLimiter,
    fetch: @escaping @Sendable (String, JSONObject, [String]) async throws -> JSONObject
  ) async throws -> (page: JSONObject, failureStage: String?) {
    guard case let .object(initialState)? = initialPage["state"], case let .array(rawItems)? = initialPage["items"] else {
      throw gmailCollectionInvalid()
    }
    var state = initialState
    var items = rawItems.compactMap { nonEmptyString($0) }
    guard items.count == rawItems.count else { throw gmailCollectionInvalid() }
    var itemSet = Set(items)
    var requestValue = initialPage["request"] ?? .null
    var complete = initialPage["complete"] == .bool(true)
    func pageSnapshot() -> JSONObject {
      var snapshotState = state
      snapshotState["items"] = .array(items.map(JSONValue.string))
      let stateValue = JSONValue.object(snapshotState)
      return ["state": stateValue, "items": .array(items.map(JSONValue.string)), "request": requestValue,
        "complete": .bool(complete), "context": initialPage["context"] ?? .null]
    }
    while !complete {
      let remaining = 10_000 - items.count
      guard remaining > 0 else { return (pageSnapshot(), "listing-limit") }
      do {
        guard case let .object(request) = requestValue, let query = request["query"] else { throw gmailCollectionInvalid() }
        var input: JSONObject = ["accountId": .string(options.account), "query": query, "first": .integer(Int64(min(50, remaining)))]
        if let receivedAfter { input["receivedAfter"] = .string(receivedAfter) }
        if let cursor = request["cursor"], cursor != .null { input["after"] = cursor }
        try await limiter.acquire()
        let response = try await fetch("threads", ["input": .object(input)], ["edges.node.id", "pageInfo.hasNextPage", "pageInfo.endCursor"])
        (requestValue, complete) = try acceptListingResponse(response, state: &state, items: &items, itemSet: &itemSet)
      } catch is CancellationError { throw CancellationError() } catch is GmailCollectionDeadlineRefusal {
        return (pageSnapshot(), "deadline")
      } catch is GmailListingLimitError {
        return (pageSnapshot(), "listing-limit")
      } catch {
        if Task.isCancelled { throw CancellationError() }
        return (pageSnapshot(), "listing")
      }
    }
    return (pageSnapshot(), nil)
  }

  private func acceptListingResponse(
    _ response: JSONObject,
    state: inout JSONObject,
    items: inout [String],
    itemSet: inout Set<String>
  ) throws -> (request: JSONValue, complete: Bool) {
    guard
      case let .array(queries)? = state["queries"],
      case let .integer(rawIndex)? = state["index"],
      case let .integer(rawMaximum)? = state["maximum"],
      case let .array(edges)? = response["edges"], edges.count <= 10_000,
      case let .object(pageInfo)? = response["pageInfo"],
      case let .bool(hasMore)? = pageInfo["hasNextPage"] else { throw gmailCollectionInvalid() }
    let index = Int(rawIndex), maximum = Int(rawMaximum)
    guard queries.indices.contains(index), (1...10_000).contains(maximum), items.count <= maximum else {
      throw gmailCollectionInvalid()
    }
    var proposedItems = items
    var proposedItemSet = itemSet
    for edge in edges {
      guard case let .object(edgeObject) = edge,
        case let .object(node)? = edgeObject["node"],
        case let .string(id)? = node["id"], gmailIdentifier(id) else { throw gmailCollectionInvalid() }
      if proposedItemSet.insert(id).inserted { proposedItems.append(id) }
    }
    guard proposedItems.count <= maximum else { throw GmailListingLimitError() }
    let nextCursor: String?
    switch pageInfo["endCursor"] {
    case nil, .null?: nextCursor = nil
    case let .string(value)?: nextCursor = value.isEmpty ? nil : value
    default: throw gmailCollectionInvalid()
    }
    var visited: [String]
    switch state["visited"] {
    case nil, .null?: visited = []
    case let .array(values)?:
      guard values.count <= 1_000 else { throw gmailCollectionInvalid() }
      visited = try values.map {
        guard case let .string(value) = $0, !value.isEmpty, value.utf8.count <= 8_192 else { throw gmailCollectionInvalid() }
        return value
      }
    default: throw gmailCollectionInvalid()
    }
    let priorCursor = nonEmptyString(state["cursor"])
    var nextIndex = index
    var cursor: String?
    if hasMore {
      guard let nextCursor, nextCursor.utf8.count <= 8_192, nextCursor != priorCursor,
        !visited.contains(nextCursor), visited.count < 1_000 else { throw gmailCollectionInvalid() }
      visited.append(nextCursor); cursor = nextCursor
    } else {
      nextIndex += 1; cursor = nil; visited = []
    }
    let pageCount: Int
    if case let .integer(value)? = state["pageCount"] { pageCount = Int(value) } else { throw gmailCollectionInvalid() }
    guard pageCount < 64_000 else { throw gmailCollectionInvalid() }
    var proposedState = state
    proposedState["items"] = .array(proposedItems.map(JSONValue.string))
    proposedState["index"] = .integer(Int64(nextIndex))
    if let cursor { proposedState["cursor"] = .string(cursor) } else { proposedState.removeValue(forKey: "cursor") }
    proposedState["visited"] = .array(visited.map(JSONValue.string))
    proposedState["pageCount"] = .integer(Int64(pageCount + 1))
    guard let encodedState = try? JSONEncoder().encode(proposedState), encodedState.count <= 7_000_000 else {
      throw GmailListingLimitError()
    }
    state = proposedState
    items = proposedItems
    itemSet = proposedItemSet
    let complete = nextIndex == queries.count
    let request: JSONValue = complete ? .null : .object([
      "query": queries[nextIndex], "cursor": cursor.map(JSONValue.string) ?? .null
    ])
    return (request, complete)
  }

  private func loadProfile(
    _ prefetchedProfile: JSONObject?,
    limiter: GmailCollectionRequestLimiter,
    fetch: @escaping @Sendable (String, JSONObject, [String]) async throws -> JSONObject
  ) async throws -> JSONObject {
    if let prefetchedProfile {
      await limiter.recordPrefetchedGrant()
      return prefetchedProfile
    }
    do {
      try await limiter.acquire()
      return try await fetch("profile", ["accountId": .string(options.account)], ["emailAddress", "historyId"])
    } catch is GmailCollectionDeadlineRefusal {
      throw AdapterExecutionError(.timeout, "Gmail collection execution budget exhausted")
    }
  }

  private func acceptThreadOutcome(
    _ outcome: GmailThreadReadOutcome,
    id: String,
    state: inout GmailThreadProcessingState
  ) -> Bool {
    switch outcome {
    case .unchanged:
      guard state.reserveOutcome(id: id, thread: nil, stamp: nil) else {
        state.recordFailure(failure("output-budget", id: id)); state.deferred.insert(id); state.stopScheduling = true
        return false
      }
      state.retryAfter = id; state.completed.insert(id); state.deferred.remove(id)
    case let .fetched(thread, stamp, threadBodies):
      state.retryAfter = id
      guard state.reserveOutcome(id: id, thread: thread, stamp: stamp) else {
        state.recordFailure(failure("output-budget", id: id)); state.deferred.insert(id); state.stopScheduling = true
        return false
      }
      state.threads.append(thread); state.invalidated.append(id); state.found.formUnion(threadBodies)
      state.completed.insert(id); state.deferred.remove(id)
      if let stamp { state.versions[id] = .string(stamp) } else { state.versions.removeValue(forKey: id) }
    case .failed:
      guard state.reserveOutcome(id: id, thread: nil, stamp: nil) else {
        state.recordFailure(failure("output-budget", id: id)); state.deferred.insert(id); state.stopScheduling = true
        return false
      }
      state.retryAfter = id; state.recordFailure(failure("thread", id: id)); state.deferred.insert(id)
    case .refusedAfterStart:
      guard state.reserveOutcome(id: id, thread: nil, stamp: nil) else {
        state.recordFailure(failure("output-budget", id: id)); state.deferred.insert(id); state.stopScheduling = true
        return false
      }
      state.retryAfter = id; state.deferred.insert(id); state.deadlineRefused = true; return true
    case .refusedBeforeStart:
      state.deadlineRefused = true; return true
    }
    return false
  }

  private func advancePage(_ saved: JSONValue?, response: JSONObject?) throws -> JSONObject {
    var config: JSONObject
    if let saved, let response {
      config = ["action": .string("accept"), "state": saved, "response": .object(response)]
    } else if let saved {
      config = ["action": .string("resume"), "state": saved]
    } else {
      config = ["action": .string("start"), "queries": .array(options.queries.map(JSONValue.string)),
        "maxItems": .integer(10_000), "itemsPath": .string("/edges"), "identityPath": .string("/node/id"),
        "cursorPath": .string("/pageInfo/endCursor"), "hasMorePath": .string("/pageInfo/hasNextPage"), "identitySyntax": .string("identifier")]
    }
    return try BuiltinWorkflowAddonResolver(environment: [:]).executePageState(.init(workflowId: "gmail-collection", stepId: "page", nodeId: "page",
      addon: .init(name: "riela/page-state", version: "1", config: config), variables: [:])).payload
  }

  private func threadVersion(_ value: JSONObject) throws -> String? {
    guard case let .object(metadata)? = value["providerMetadata"], case let .object(gmail)? = metadata["gmail"] else { return nil }
    return try gmailVersion(gmail["historyId"])
  }

  private func failure(_ stage: String, id: String? = nil) -> JSONValue {
    var value: JSONObject = ["stage": .string(stage), "code": .string("acquisition-unavailable")]
    if let id { value["threadId"] = .string(id) }; return .object(value)
  }

  private static let threadSelection = ["id", "providerMetadata.gmail.historyId", "subject", "messages.id", "messages.accountId", "messages.threadId",
    "messages.subject", "messages.sentAt", "messages.receivedAt", "messages.textBody", "messages.htmlBody", "messages.snippet", "messages.labels", "messages.from.address"]

  private var bodySelection: [String] {
    let base = ["accountId", "messageId", "complete", "byteCount", "parts.partId", "parts.mimeType", "parts.charset", "parts.dataBase64", "parts.byteCount", "parts.sha256"]
    return base + (options.providerBodyMetadata ? ["representationScope", "parts.providerDeclaredByteCount", "parts.sizeStatus"] : [])
  }
}

private struct GmailListingLimitError: Error {}

private enum GmailThreadReadOutcome: Sendable {
  case unchanged
  case fetched(thread: JSONObject, stamp: String?, bodies: Set<String>)
  case failed
  case refusedBeforeStart
  case refusedAfterStart

  var isDeadlineRefusal: Bool {
    switch self {
    case .refusedBeforeStart, .refusedAfterStart: true
    case .unchanged, .fetched, .failed: false
    }
  }
}

private struct GmailThreadProcessingState {
  let checkpoint: JSONObject
  let page: JSONObject
  let listing: [String]
  let frozenMailbox: String?
  let frozenAfter: String?
  let outputByteBudget: Int
  var completed: Set<String>
  var deferred: Set<String>
  var found: Set<String>
  var retryAfter: String?
  var versions: JSONObject
  var threads: [JSONObject] = []
  var invalidated: [String] = []
  var failures: [JSONValue] = []
  var failureCount = 0
  var stopScheduling = false
  var deadlineRefused = false
  private(set) var reservedOutputBytes = 0
  private(set) var acceptedThreadBytes = 2
  private var activeThreadIDs = Set<String>()

  init(
    checkpoint: JSONObject,
    page: JSONObject,
    listing: [String],
    frozenMailbox: String?,
    frozenAfter: String?,
    outputByteBudget: Int,
    completed: Set<String>,
    deferred: Set<String>,
    found: Set<String>,
    retryAfter: String?,
    versions: JSONObject
  ) {
    self.checkpoint = checkpoint
    self.page = page
    self.listing = listing
    self.frozenMailbox = frozenMailbox
    self.frozenAfter = frozenAfter
    self.outputByteBudget = outputByteBudget
    self.completed = completed
    self.deferred = deferred
    self.found = found
    self.retryAfter = retryAfter
    self.versions = versions
  }

  mutating func prepareOutputBudget(options: GmailCollectionOptions) {
    if case let .array(ids)? = checkpoint["active_threads"] {
      activeThreadIDs = Set(ids.compactMap { nonEmptyString($0) })
    }
    activeThreadIDs.formUnion(listing)
    var baseline = checkpoint
    baseline["active_threads"] = .array(activeThreadIDs.sorted().map(JSONValue.string))
    baseline["pending_collection"] = .object([
      "listing": page["state"] ?? .null,
      "completed": .array(completed.sorted().map(JSONValue.string)),
      "deferred": .array(deferred.sorted().map(JSONValue.string)),
      "found_bodies": .array(found.sorted().map(JSONValue.string)),
      "body_ids": .array(options.bodyIDs.sorted().map(JSONValue.string)),
      "mailbox_version": frozenMailbox.map(JSONValue.string) ?? .null,
      "received_after": frozenAfter.map(JSONValue.string) ?? .null,
      "retry_after": retryAfter.map(JSONValue.string) ?? .null
    ])
    let envelope: JSONObject = ["threads": .array([]), "checkpoint": .object(baseline), "invalidated": .array([]),
      "complete": .bool(false), "failures": .array([]), "requestCount": .integer(Int64.max)]
    reservedOutputBytes = ((try? JSONEncoder().encode(envelope).count) ?? outputByteBudget) + 65_536
    // Any requested body can be discovered and added to found_bodies.
    reservedOutputBytes += options.bodyIDs.reduce(0) { $0 + conservativeJSONCost(for: $1) }
  }

  mutating func reserveOutcome(id: String, thread: JSONObject?, stamp: String?) -> Bool {
    let nextThreadBytes: Int
    if let thread {
      guard let encoded = try? JSONEncoder().encode(thread) else { return false }
      nextThreadBytes = acceptedThreadBytes + encoded.count + (acceptedThreadBytes > 2 ? 1 : 0)
    } else {
      nextThreadBytes = acceptedThreadBytes
    }
    let metadataBytes = conservativeJSONCost(for: id) * 5 + 64 + (stamp == nil ? 0 : 6 * 128 + 16)
    guard reservedOutputBytes + metadataBytes + nextThreadBytes <= outputByteBudget else { return false }
    reservedOutputBytes += metadataBytes
    acceptedThreadBytes = nextThreadBytes
    return true
  }

  private func conservativeJSONCost(for value: String) -> Int { value.utf8.count * 6 + 8 }

  mutating func recordFailure(_ value: JSONValue) {
    failureCount += 1
    if failures.count < 128 { failures.append(value) }
  }
}

private func gmailIdentifier(_ value: String) -> Bool {
  !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy {
    (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
  }
}

func gmailVersion(_ value: JSONValue?) throws -> String? {
  guard let value, value != .null else { return nil }
  guard case let .string(text) = value, text.range(of: #"^[0-9]{1,128}$"#, options: .regularExpression) != nil else { throw gmailCollectionInvalid() }
  return text
}

func gmailCollectionInvalid() -> AdapterExecutionError { .init(.invalidInput, "invalid Gmail collection configuration or response") }

private func gmailIDSet(_ value: JSONValue?) throws -> Set<String> {
  guard case let .array(values)? = value, values.count <= 10_000 else { throw gmailCollectionInvalid() }
  let ids = values.compactMap { nonEmptyString($0) }
  guard ids.count == values.count, ids.allSatisfy(gmailIdentifier), Set(ids).count == ids.count else { throw gmailCollectionInvalid() }
  return Set(ids)
}
