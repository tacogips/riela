import Foundation
import RielaCore

/// An exhausted listing has no cursor left to preserve. Its unresolved thread
/// IDs share one retry backlog instead of multiplying with every fresh poll.
func coalesceGmailRetryBacklog(_ scans: [JSONValue], resolved: Set<String>, foundBodies: Set<String> = []) throws -> [JSONValue] {
  var output: [JSONValue] = [], backlog: JSONObject?
  var ids = Set<String>(), deferred = Set<String>(), found = foundBodies
  for scan in scans {
    guard case let .object(pending) = scan, case let .object(listing)? = pending["listing"],
      case let .array(queries)? = listing["queries"], case let .integer(index)? = listing["index"] else {
      throw gmailCollectionInvalid()
    }
    guard index == Int64(queries.count) else { output.append(scan); continue }
    guard case let .array(items)? = listing["items"], case let .array(done)? = pending["completed"],
      case let .array(failed)? = pending["deferred"], case let .array(bodies)? = pending["found_bodies"] else {
      throw gmailCollectionInvalid()
    }
    func strings(_ values: [JSONValue]) throws -> Set<String> {
      let values = try values.map { value -> String in
        guard case let .string(text) = value else { throw gmailCollectionInvalid() }; return text
      }
      return Set(values)
    }
    let completed = try strings(done).union(resolved)
    ids.formUnion(try strings(items).subtracting(completed))
    deferred.formUnion(try strings(failed).subtracting(completed))
    found.formUnion(try strings(bodies))
    if backlog == nil { backlog = pending }
  }
  if var pending = backlog, case var .object(listing)? = pending["listing"] {
    guard ids.count <= 10_000 else { throw gmailCollectionInvalid() }
    listing["items"] = .array(ids.sorted().map(JSONValue.string))
    pending["listing"] = .object(listing)
    pending["completed"] = .array([])
    pending["deferred"] = .array(deferred.intersection(ids).sorted().map(JSONValue.string))
    pending["found_bodies"] = .array(found.sorted().map(JSONValue.string))
    let bodies: Set<String>
    if case let .array(values)? = pending["body_ids"] { bodies = Set(values.compactMap { value in
      if case let .string(text) = value { return text }; return nil
    }) } else { throw gmailCollectionInvalid() }
    if !ids.isEmpty || !bodies.isSubset(of: found) { output.append(.object(pending)) }
  }
  return output
}
