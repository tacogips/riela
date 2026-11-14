import Foundation
import RielaCore
import RielaAddonSupport

extension GmailMailboxCollector {
  /// One bounded scan per run. Frozen scans rotate separately from fresh
  /// discovery, so an unreadable message or cursor cannot block new arrivals.
  func collect(fetch: (String, JSONObject, [String]) async throws -> JSONObject) async throws -> JSONObject {
    try Task.checkCancellation()
    if let deadline, clock() >= deadline { throw AdapterExecutionError(.timeout, "Gmail collection execution budget exhausted") }
    var checkpoint = options.previous
    var scopes: JSONObject = [:]
    if case let .object(saved)? = checkpoint.removeValue(forKey: "collection_scopes") { scopes = saved }
    if let old = nonEmptyString(checkpoint["native_query_scope"]), old != options.scope {
      scopes[old] = .object(checkpoint)
      if case let .object(saved)? = scopes.removeValue(forKey: options.scope) {
        checkpoint = saved
      } else { checkpoint = [:] }
    }
    // Completed scopes are memoized history, not protected pending work.
    // Evict them before applying the global metadata bound.
    let completedScopes = scopes.keys.filter { key in
      guard case let .object(saved)? = scopes[key] else { return false }
      return saved["pending_collection"] == nil && saved["pending_scans"] == nil
    }.sorted { left, right in
      guard case let .object(a)? = scopes[left], case let .object(b)? = scopes[right] else { return left < right }
      return (nonEmptyString(a["checked_at"]) ?? "") < (nonEmptyString(b["checked_at"]) ?? "")
    }
    for key in completedScopes {
      if scopes.count <= 64, try JSONEncoder().encode(scopes).count < outputByteBudget / 2 { break }
      scopes.removeValue(forKey: key)
    }
    guard scopes.count <= 64 else { throw gmailCollectionInvalid() }
    let archiveBytes = try JSONEncoder().encode(scopes).count
    guard archiveBytes + 131_072 < outputByteBudget else { throw gmailCollectionInvalid() }
    let profile = try await fetch("profile", ["accountId": .string(options.account)], ["emailAddress", "historyId"])
    let version = try gmailVersion(profile["historyId"])
    if let email = nonEmptyString(profile["emailAddress"]), let oldHash = checkpoint["mailbox_hash"],
      oldHash != .string(String(JSONCanonical.sha256Hex(Data(email.utf8)).prefix(24))) {
      checkpoint = ["native_query_scope": .string(options.scope), "reset_records": .bool(true)]
    }
    var queue: [JSONValue] = []
    if case let .array(saved)? = checkpoint.removeValue(forKey: "pending_scans") { queue = saved }
    if let legacy = checkpoint.removeValue(forKey: "pending_collection") { queue.insert(legacy, at: 0) }
    guard queue.count <= 32, queue.allSatisfy({ if case .object = $0 { return true }; return false }) else { throw gmailCollectionInvalid() }
    let newProfile = version == nil || checkpoint["fresh_profile_version"] != version.map(JSONValue.string)
    let fresh = queue.isEmpty || (newProfile && checkpoint["prefer_fresh"] != .bool(false) && queue.count < 32)
    let previousActive = checkpoint["active_threads"]
    let previousVersions = checkpoint["thread_versions"]
    var scanCheckpoint = checkpoint
    let started = clock()
    var lower = options.receivedAfter
    if options.window == nil, lower == nil {
      var floor = started.addingTimeInterval(-Double(options.lookbackHours) * 3600)
      if let covered = nonEmptyString(checkpoint["discovery_covered_until"]) {
        floor = min(floor, try xInstant(covered).addingTimeInterval(-1))
      }
      // A frozen page cursor may have missed arrivals after its scan began.
      // Retain its older discovery floor until that scan is accounted for.
      for pending in queue {
        if case let .object(value) = pending, let after = nonEmptyString(value["received_after"]) {
          floor = min(floor, try xInstant(after))
        }
      }
      lower = ISO8601DateFormatter().string(from: floor)
    }
    var priorFound = Set<String>()
    if case let .array(values)? = checkpoint["found_body_ids"] {
      priorFound = Set(values.compactMap { nonEmptyString($0) })
      guard priorFound.count == values.count, priorFound.isSubset(of: options.bodyIDs) else { throw gmailCollectionInvalid() }
    }
    if !fresh {
      guard case var .object(pending) = queue.removeFirst(), case let .array(found)? = pending["found_bodies"] else {
        throw gmailCollectionInvalid()
      }
      pending["found_bodies"] = .array(priorFound.union(found.compactMap { nonEmptyString($0) }).sorted().map(JSONValue.string))
      scanCheckpoint["pending_collection"] = .object(pending)
    } else {
      if !queue.isEmpty { scanCheckpoint.removeValue(forKey: "mailbox_version") }
      checkpoint["fresh_profile_version"] = version.map(JSONValue.string) ?? .null
    }
    checkpoint["prefer_fresh"] = .bool(!fresh)
    var scanOptions = options; scanOptions.previous = scanCheckpoint
    let queueBytes = try JSONEncoder().encode(queue).count
    let scan = GmailMailboxCollector(options: scanOptions, deadline: deadline,
      outputByteBudget: outputByteBudget - archiveBytes - queueBytes - 65_536,
      scanReceivedAfter: lower, foundBodyIDs: priorFound, clock: clock, wait: wait)
    var usedProfile = false
    var result = try await scan.collectScan { operation, arguments, selection in
      if operation == "profile", !usedProfile { usedProfile = true; return profile }
      return try await fetch(operation, arguments, selection)
    }
    guard case var .object(next)? = result["checkpoint"] else { throw gmailCollectionInvalid() }
    for key in ["fresh_profile_version", "prefer_fresh", "discovery_covered_until"] {
      if let value = checkpoint[key] { next[key] = value }
    }
    if let pending = next.removeValue(forKey: "pending_collection") {
      queue.append(pending)
    } else if fresh, result["complete"] == .bool(true) {
      next["discovery_covered_until"] = .string(ISO8601DateFormatter().string(from: started))
    }
    let resolved: Set<String>
    if case let .array(values)? = result["invalidated"] {
      resolved = Set(values.compactMap { nonEmptyString($0) })
    } else { resolved = [] }
    var foundBodies = priorFound
    if case let .array(threads)? = result["threads"] {
      for thread in threads {
        guard case let .object(thread) = thread, case let .array(messages)? = thread["messages"] else { continue }
        for message in messages {
          if case let .object(message) = message, let id = nonEmptyString(message["id"]),
            options.bodyIDs.contains(id), message["_body_bytes"] != nil { foundBodies.insert(id) }
        }
      }
    }
    next["found_body_ids"] = .array(foundBodies.sorted().map(JSONValue.string))
    queue = try coalesceGmailRetryBacklog(queue, resolved: resolved, foundBodies: foundBodies)
    if queue.count == 32, newProfile, !fresh {
      if case var .array(failures)? = result["failures"] {
        failures.append(.object(["stage": .string("fresh-capacity"), "code": .string("pending-scan-bound")]))
        result["failures"] = .array(failures)
      }
    }
    if !queue.isEmpty {
      next["pending_scans"] = .array(queue)
      next.removeValue(forKey: "mailbox_version")
      result["complete"] = .bool(false)
    }
    if !queue.isEmpty || !fresh {
      var active: Set<String> = []
      for value in [previousActive, next["active_threads"]] {
        if case let .array(ids)? = value { active.formUnion(ids.compactMap { nonEmptyString($0) }) }
      }
      next["active_threads"] = .array(active.sorted().map(JSONValue.string))
      var versions: JSONObject = [:]
      if case let .object(old)? = previousVersions { versions = old }
      if case let .object(updated)? = next["thread_versions"] { versions.merge(updated) { _, new in new } }
      next["thread_versions"] = .object(versions)
    }
    if !fresh {
      // A resumed scan proves its frozen version only. A fresh pass will
      // acknowledge the current profile after all backlog has drained.
      next.removeValue(forKey: "mailbox_version")
    }
    if !scopes.isEmpty { next["collection_scopes"] = .object(scopes) }
    result["checkpoint"] = .object(next)
    guard try JSONEncoder().encode(result).count <= outputByteBudget else { throw gmailCollectionInvalid() }
    return result
  }
}
