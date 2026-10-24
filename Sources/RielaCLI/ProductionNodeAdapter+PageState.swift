import Foundation
import RielaAddonSupport
import RielaCore

/// Provider-neutral pagination. Only IDs/cursors persist in the state; opaque
/// workflow context is carried separately and never interpreted as a program.
extension BuiltinWorkflowAddonResolver {
  func executePageState(_ input: WorkflowAddonExecutionInput) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1",
      case let .object(config) = try renderAddonConfig(.object(input.addon.config ?? [:]), variables: addonVariables(for: input)),
      let action = nonEmptyString(config["action"]), ["start", "accept"].contains(action)
    else { throw pageStateError() }
    var state: PageCollectionState
    if action == "start" {
      guard Set(config.keys).isSubset(of: ["action", "queries", "maxItems", "itemsPath", "identityPath",
                                          "cursorPath", "hasMorePath", "identitySyntax", "context"]),
        case let .array(queries)? = config["queries"], (1...64).contains(queries.count),
        case let .integer(maximum) = config["maxItems"] ?? .integer(10_000), (1...10_000).contains(maximum)
      else { throw pageStateError() }
      func pointer(_ key: String, fallback: String) throws -> String {
        guard case let .string(path) = config[key] ?? .string(fallback) else { throw pageStateError() }
        _ = try JSONDataTransform.lookup(.null, pointer: .string(path))
        return path
      }
      let more: String?
      switch config["hasMorePath"] {
      case nil: more = nil
      case let .string(path)?:
        _ = try JSONDataTransform.lookup(.null, pointer: .string(path)); more = path
      default: throw pageStateError()
      }
      guard case let .string(syntax) = config["identitySyntax"] ?? .string("opaque"),
        ["opaque", "identifier", "decimal"].contains(syntax) else { throw pageStateError() }
      state = PageCollectionState(queries: queries, maximum: Int(maximum),
        itemsPath: try pointer("itemsPath", fallback: "/items"),
        identityPath: try pointer("identityPath", fallback: "/id"),
        cursorPath: try pointer("cursorPath", fallback: "/nextCursor"), hasMorePath: more, identitySyntax: syntax)
    } else {
      guard Set(config.keys).isSubset(of: ["action", "state", "response", "context"]),
        let saved = config["state"], let response = config["response"] else { throw pageStateError() }
      do { state = try JSONDecoder().decode(PageCollectionState.self, from: JSONEncoder().encode(saved)) } catch {
        throw pageStateError()
      }
      try state.validate()
      guard !state.complete,
        case let .array(items)? = try JSONDataTransform.lookup(response, pointer: .string(state.itemsPath)),
        items.count <= 10_000 else { throw pageStateError() }
      var seen = Set(state.items)
      for item in items {
        guard case let .string(identity)? = try JSONDataTransform.lookup(item, pointer: .string(state.identityPath)),
          state.validIdentity(identity) else { throw pageStateError() }
        if seen.insert(identity).inserted { state.items.append(identity) }
      }
      let rawCursor = try JSONDataTransform.lookup(response, pointer: .string(state.cursorPath))
      let cursor: String?
      switch rawCursor {
      case nil, .null?: cursor = nil
      case let .string(value)?: cursor = value.isEmpty ? nil : value
      default: throw pageStateError()
      }
      let more: Bool
      if let path = state.hasMorePath {
        guard case let .bool(value)? = try JSONDataTransform.lookup(response, pointer: .string(path)) else { throw pageStateError() }
        more = value
      } else { more = cursor != nil }
      if more {
        guard let cursor, cursor.utf8.count <= 8192, cursor != state.cursor,
          !state.visited.contains(cursor), state.visited.count < 1000 else {
          throw AdapterExecutionError(.invalidOutput, "page-state cursor is missing, repeated or outside its bounds")
        }
        state.visited.append(cursor); state.cursor = cursor
      } else {
        state.index += 1; state.cursor = nil; state.visited = []
      }
      state.pageCount += 1
    }
    try state.validate()
    let encoded = try JSONEncoder().encode(state)
    let saved = try JSONDecoder().decode(JSONValue.self, from: encoded)
    let request: JSONValue = state.complete ? .null : .object([
      "query": state.queries[state.index], "cursor": state.cursor.map(JSONValue.string) ?? .null])
    let payload: JSONObject = ["state": saved, "items": .array(state.items.map(JSONValue.string)),
      "request": request, "complete": .bool(state.complete), "context": config["context"] ?? .null]
    guard try JSONEncoder().encode(payload).count <= 8_000_000 else { throw pageStateError() }
    return AdapterExecutionOutput(provider: "riela-builtin-addon", model: input.addon.name,
      promptText: "", completionPassed: true, when: ["always": true, "more": !state.complete, "done": state.complete], payload: payload)
  }
}

private func pageStateError() -> AdapterExecutionError {
  AdapterExecutionError(.invalidInput, "invalid page-state configuration, state or response")
}

private struct PageCollectionState: Codable {
  var format = 1
  var queries: [JSONValue]
  var maximum: Int
  var itemsPath: String
  var identityPath: String
  var cursorPath: String
  var hasMorePath: String?
  var identitySyntax: String
  var index = 0
  var cursor: String?
  var visited: [String] = []
  var items: [String] = []
  var pageCount = 0
  var complete: Bool { index == queries.count }

  func validIdentity(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 1024 else { return false }
    switch identitySyntax {
    case "opaque": return true
    case "identifier": return value.utf8.count <= 256 && value.utf8.allSatisfy {
      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45
    }
    case "decimal": return value.utf8.count <= 32 && value.utf8.allSatisfy { (48...57).contains($0) }
    default: return false
    }
  }

  func validate() throws {
    guard format == 1, (1...64).contains(queries.count), (0...queries.count).contains(index),
      (1...10_000).contains(maximum), items.count <= maximum, Set(items).count == items.count,
      ["opaque", "identifier", "decimal"].contains(identitySyntax),
      items.allSatisfy(validIdentity), (0...64_000).contains(pageCount), visited.count <= 1000,
      Set(visited).count == visited.count, visited.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8192 }),
      (cursor == nil && visited.isEmpty) || (cursor != nil && !complete && cursor == visited.last),
      !complete || (cursor == nil && visited.isEmpty),
      try JSONEncoder().encode(self).count <= 7_000_000 else { throw pageStateError() }
    for path in [itemsPath, identityPath, cursorPath] + (hasMorePath.map { [$0] } ?? []) {
      _ = try JSONDataTransform.lookup(.null, pointer: .string(path))
    }
  }
}
