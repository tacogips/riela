import Foundation
import RielaCore

/// A bounded, exact-ID recovery turn. Missing roots remain pending; it never
/// searches a timeline, changes a cursor or acknowledges an inspected body.
struct XLookupCollection {
  let ids: [String]
  let expected: String
  let account: String
  let maximum: Int
  let start: Date?
  let end: Date?
  let selection: JSONObject

  init(_ values: JSONObject) throws {
    guard Set(values.keys).isSubset(of: ["mode", "ids", "expectedHandle", "expectedAccount", "maxPosts", "start", "end", "includeStatusLinks", "includeCoverageMetadata"]),
      case let .array(raw)? = values["ids"], raw.count <= 5000,
      case let .string(expected)? = values["expectedHandle"], xMatches(.string(expected), #"^[A-Za-z0-9_]{1,15}$"#),
      let account = try xOptionalID(values["expectedAccount"]),
      case let .integer(maximum) = values["maxPosts"] ?? .integer(100), (1...100).contains(maximum),
      case let .bool(links) = values["includeStatusLinks"] ?? .bool(false),
      case let .bool(coverage) = values["includeCoverageMetadata"] ?? .bool(false) else { throw xCollectionInvalid() }
    let ids = try raw.map { raw -> String in guard let id = try xOptionalID(raw) else { throw xCollectionInvalid() }; return id }
    guard Set(ids).count == ids.count else { throw xCollectionInvalid() }
    func date(_ key: String) throws -> Date? {
      guard let value = values[key] else { return nil }
      guard case let .string(text) = value else { throw xCollectionInvalid() }; return try xInstant(text)
    }
    self.start = try date("start"); self.end = try date("end")
    if let start, let end, start >= end { throw xCollectionInvalid() }
    self.ids = ids; self.expected = expected; self.account = account; self.maximum = Int(maximum)
    self.selection = ["posts": .object(XCollectionOptions.postFields(depth: 0, links: links, coverage: coverage))]
  }

  func collect(outputByteBudget: Int = 8_000_000, fetch: (String, JSONObject, JSONObject) async throws -> JSONObject) async throws -> JSONObject {
    try Task.checkCancellation()
    let requested = Array(ids.prefix(maximum)), deferred = Array(ids.dropFirst(maximum))
    var output: JSONObject = ["posts": .array([]), "requestedIds": .array(requested.map(JSONValue.string)),
      "returnedIds": .array([]), "deferredIds": .array(deferred.map(JSONValue.string)),
      "pendingIds": .array(ids.map(JSONValue.string)), "accountId": .string(account), "complete": .bool(ids.isEmpty), "failures": .array([])]
    let metadataBytes = try JSONEncoder().encode(output).count
    let bodyBudget = min(6_000_000, outputByteBudget - metadataBytes - 4096)
    guard (1...8_000_000).contains(outputByteBudget), metadataBytes + 4096 <= outputByteBudget,
      requested.isEmpty || bodyBudget >= 131_072 else { throw xCollectionInvalid() }
    var posts: [JSONValue] = [], returned: [String] = [], failures: [JSONValue] = []
    if !requested.isEmpty {
      let owner = try await fetch("accountMe", [:], ["id": .bool(true), "username": .bool(true)])
      guard try xOptionalID(owner["id"]) == account, case let .string(handle)? = owner["username"],
        handle.lowercased() == expected.lowercased() else {
        throw AdapterExecutionError(.policyBlocked, "X lookup authenticated account mismatch")
      }
      do {
        try Task.checkCancellation()
        let response = try await fetch("posts", ["ids": .array(requested.map(JSONValue.string))], selection)
        guard case let .array(values)? = response["posts"], values.count <= requested.count,
          response["errors"] == nil || response["errors"] == .array([]) else { throw xCollectionInvalid() }
        var seen = Set<String>(), accepted = Set<String>(), checked: [JSONValue] = []
        var bytes = 2, skipped = 0
        let fetched = ISO8601DateFormatter().string(from: Date())
        for value in values {
          guard case var .object(post) = value, let id = try xOptionalID(post["id"]), requested.contains(id),
            seen.insert(id).inserted, case .string? = post["text"], case let .string(created)? = post["createdAt"] else { throw xCollectionInvalid() }
          let instant = try xInstant(created)
          guard start.map({ instant >= $0 }) ?? true, end.map({ instant < $0 }) ?? true else { throw xCollectionInvalid() }
          post["_fetched_at"] = .string(fetched); post["_account_id"] = .string(account)
          let size = try JSONEncoder().encode(post).count + 1
          guard bytes + size <= bodyBudget else { skipped += 1; continue }
          checked.append(.object(post)); accepted.insert(id); bytes += size
        }
        posts = checked; returned = requested.filter { accepted.contains($0) }
        if skipped > 0 { failures = [.object(["stage": .string("lookup"), "code": .string("lookup-body-budget"), "count": .integer(Int64(skipped))])] }
      } catch is CancellationError { throw CancellationError() } catch {
        var failure: JSONObject = ["stage": .string("lookup"), "code": .string("lookup-unavailable")]
        if let error = error as? AdapterExecutionError {
          failure["diagnostics"] = .object(GatewayFailureDiagnostics.fields(readerMessage: error.message))
        }
        failures = [.object(failure)]
      }
    }
    let found = Set(returned)
    output["posts"] = .array(posts); output["returnedIds"] = .array(returned.map(JSONValue.string))
    output["pendingIds"] = .array(ids.filter { !found.contains($0) }.map(JSONValue.string))
    output["complete"] = .bool(returned.count == ids.count); output["failures"] = .array(failures)
    guard try JSONEncoder().encode(output).count <= outputByteBudget else { throw xCollectionInvalid() }
    return output
  }
}
