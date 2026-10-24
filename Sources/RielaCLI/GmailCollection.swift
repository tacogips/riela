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
  var clock: () -> Date = { Date() }
  var wait: (Double) async throws -> Void = { if $0 > 0 { try await Task.sleep(for: .seconds($0)) } }

  func collectScan(fetch: (String, JSONObject, [String]) async throws -> JSONObject) async throws -> JSONObject {
    let startedAt = clock()
    var requests = 0
    func read(_ operation: String, _ arguments: JSONObject, _ selection: [String]) async throws -> JSONObject {
      try Task.checkCancellation()
      if let deadline, deadline.timeIntervalSince(clock()) <= (requests > 0 ? options.interval : 0) {
        throw AdapterExecutionError(.timeout, "Gmail collection execution budget exhausted")
      }
      if requests > 0 { try await wait(options.interval) }
      requests += 1
      return try await fetch(operation, arguments, selection)
    }
    var checkpoint = options.previous
    if checkpoint["native_query_scope"] != .string(options.scope) {
      checkpoint.removeValue(forKey: "mailbox_version"); checkpoint.removeValue(forKey: "thread_versions")
      checkpoint.removeValue(forKey: "pending_collection")
    }
    checkpoint["native_query_scope"] = .string(options.scope)
    let profile = try await read("profile", ["accountId": .string(options.account)], ["emailAddress", "historyId"])
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
      let beforeCount = try gmailIDSet(page["items"]).count
      while page["complete"] != .bool(true) {
        let selected = try gmailIDSet(page["items"]).count
        let remaining = min(options.maximum - (selected - beforeCount), 10_000 - selected)
        if remaining <= 0 { break }
        do {
          guard case let .object(request)? = page["request"], let query = request["query"] else { throw gmailCollectionInvalid() }
          var input: JSONObject = ["accountId": .string(options.account), "query": query, "first": .integer(Int64(min(50, remaining)))]
          if let after = frozenAfter { input["receivedAfter"] = .string(after) }
          if let cursor = request["cursor"], cursor != .null { input["after"] = cursor }
          let response = try await read("threads", ["input": .object(input)], ["edges.node.id", "pageInfo.hasNextPage", "pageInfo.endCursor"])
          page = try advancePage(page["state"], response: response)
        } catch is CancellationError { throw CancellationError() }
        catch { recordFailure(failure("listing")); break }
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
      for id in queue.prefix(options.maximum) {
        if let deadline, deadline.timeIntervalSince(clock()) <= options.interval { break }
        retryAfter = id
        do {
          let arguments: JSONObject = ["accountId": .string(options.account), "threadId": .string(id)]
          if let previous = try gmailVersion(versions[id]), options.bodyIDs.isEmpty {
            let metadata = try await read("thread", arguments, ["id", "providerMetadata.gmail.historyId"])
            guard metadata["id"] == .string(id) else { throw gmailCollectionInvalid() }
            if try threadVersion(metadata) == previous { completed.insert(id); deferred.remove(id); continue }
          }
          var thread = try await read("thread", arguments, Self.threadSelection)
          guard thread["id"] == .string(id), case let .array(rawMessages)? = thread["messages"] else { throw gmailCollectionInvalid() }
          let stamp = try threadVersion(thread)
          var messages: [JSONValue] = [], threadBodies = Set<String>()
          for value in rawMessages {
            guard case var .object(message) = value, let messageID = nonEmptyString(message["id"]), gmailIdentifier(messageID),
              message["accountId"] == .string(options.account), message["threadId"] == .string(id) else { throw gmailCollectionInvalid() }
            if options.bodyIDs.contains(messageID) {
              let body = try await read("messageBodyBytes", ["accountId": .string(options.account), "messageId": .string(messageID), "maxBytes": .integer(2_097_152)], bodySelection)
              guard body["accountId"] == .string(options.account), body["messageId"] == .string(messageID),
                body["complete"] == .bool(true) else { throw gmailCollectionInvalid() }
              message["_body_bytes"] = .object(body); threadBodies.insert(messageID)
            }
            messages.append(.object(message))
          }
          thread["messages"] = .array(messages); thread["_fetched_at"] = .string(ISO8601DateFormatter().string(from: clock()))
          // Reserve the complete continuation metadata before accepting a body.
          // A large item must not discard the prefix already acquired this run.
          var proposed = checkpoint
          var nextVersions = versions
          if let stamp { nextVersions[id] = .string(stamp) } else { nextVersions.removeValue(forKey: id) }
          proposed["thread_versions"] = .object(nextVersions)
          proposed["active_threads"] = .array(Set((try? gmailIDSet(checkpoint["active_threads"])) ?? []).union(listing).sorted().map(JSONValue.string))
          proposed["pending_collection"] = .object(["listing": page["state"] ?? .null,
            "completed": .array(completed.union([id]).sorted().map(JSONValue.string)),
            "deferred": .array(deferred.sorted().map(JSONValue.string)),
            "found_bodies": .array(found.union(threadBodies).sorted().map(JSONValue.string)),
            "body_ids": .array(options.bodyIDs.sorted().map(JSONValue.string)),
            "mailbox_version": frozenMailbox.map(JSONValue.string) ?? .null,
            "received_after": frozenAfter.map(JSONValue.string) ?? .null,
            "retry_after": retryAfter.map(JSONValue.string) ?? .null])
          let projected: JSONObject = ["threads": .array((threads + [thread]).map(JSONValue.object)),
            "checkpoint": .object(proposed), "invalidated": .array((invalidated + [id]).map(JSONValue.string))]
          guard try JSONEncoder().encode(projected).count + 65_536 <= outputByteBudget else { throw gmailCollectionInvalid() }
          threads.append(thread); invalidated.append(id); found.formUnion(threadBodies)
          completed.insert(id); deferred.remove(id)
          if let stamp { versions[id] = .string(stamp) } else { versions.removeValue(forKey: id) }
        } catch is CancellationError { throw CancellationError() }
        catch {
          recordFailure(failure("thread", id: id)); deferred.insert(id)
          if let deadline, deadline.timeIntervalSince(clock()) <= options.interval { break }
        }
      }
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
        if failures.isEmpty { recordFailure(failure("budget")) }
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
      "failures": .array(failures), "requestCount": .integer(Int64(requests))]
    guard try JSONEncoder().encode(result).count <= outputByteBudget else { throw gmailCollectionInvalid() }
    return result
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

private func gmailIdentifier(_ value: String) -> Bool {
  !value.isEmpty && value.utf8.count <= 256 && value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
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
