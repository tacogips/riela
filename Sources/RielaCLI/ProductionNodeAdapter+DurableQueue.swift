import Foundation
import RielaAddonSupport
import RielaCore

extension BuiltinWorkflowAddonResolver {
  static let durableQueueRegistration = BuiltinAddonHandlerRegistration(name: "riela/durable-queue", bindsCLIVariablesAsInputs: false) { resolver, input, context in
    try snapshotWorkResult { try resolver.executeDurableQueue(input, context: context) }
  }

  func executeDurableQueue(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) throws -> AdapterExecutionOutput {
    try checkSnapshotWork(context)
    guard input.addon.version == nil || input.addon.version == "1",
      case let .object(config) = try renderAddonConfig(.object(input.addon.config ?? [:]), variables: addonVariables(for: input)),
      Set(config.keys).isSubset(of: ["storage", "action", "identity", "request", "complete", "status", "completionField", "limit", "maxAttempts"]),
      case let .object(storage)? = config["storage"], Set(storage.keys) == ["directory", "name"],
      case let .string(directory)? = storage["directory"], !directory.isEmpty, directory.utf8.count <= 4096,
      case let .string(name)? = storage["name"], name.range(of: #"\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}\z"#, options: .regularExpression) != nil,
      try JSONEncoder().encode(config).count <= DurableQueueJournal.maximumBytes else { throw durableQueueInvalid() }
    try DurableQueue.validateOperation(config)
    let root = URL(fileURLWithPath: directory, relativeTo: workingDirectory)
    let payload = try DurableQueueJournal.transaction(directory: root, name: name, readOnly: config["action"] == .string("pending"), context: context) {
      try DurableQueue.apply(config, state: $0, date: Date())
    }
    return .init(provider: "riela-builtin-addon", model: input.addon.name, promptText: "", completionPassed: true, payload: payload)
  }
}

enum DurableQueue {
  private struct Candidate {
    var identity: String
    var row: JSONObject
    var attempted: Date
    var registered: Date
  }

  static func validateOperation(_ config: JSONObject) throws {
    guard case let .string(action)? = config["action"] else { throw durableQueueInvalid() }
    let fields: Set<String>
    switch action {
    case "pending": fields = ["storage", "action"]
    case "admit":
      fields = ["storage", "action", "identity", "request"]
      guard case .object? = config["request"], try JSONEncoder().encode(config["request"]).count <= 262_144 else { throw durableQueueInvalid() }
    case "attempted": fields = ["storage", "action", "identity"]
    case "finish":
      fields = ["storage", "action", "identity", "complete", "status"]
      guard case .bool? = config["complete"], case let .string(status)? = config["status"],
        !status.isEmpty, status.utf8.count <= 64, status.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }) else { throw durableQueueInvalid() }
    default: throw durableQueueInvalid()
    }
    let optional: Set<String> = action == "finish" ? ["completionField"] : (action == "pending" ? ["limit", "maxAttempts"] : [])
    guard fields.isSubset(of: Set(config.keys)), Set(config.keys).isSubset(of: fields.union(optional)) else { throw durableQueueInvalid() }
    for (key, maximum) in [("limit", Int64(100)), ("maxAttempts", Int64(1_000_000_000))] {
      if let value = config[key] {
        guard case let .integer(number) = value, (1...maximum).contains(number) else { throw durableQueueInvalid() }
      }
    }
    if let field = config["completionField"] {
      guard case let .string(key) = field,
        key.range(of: #"\A[a-zA-Z_][a-zA-Z0-9_]{0,127}\z"#, options: .regularExpression) != nil,
        !["request", "status", "registered_at", "attempts", "last_attempt_at", "last_result", "updated_at"].contains(key) else { throw durableQueueInvalid() }
    }
    if action != "pending" { try identity(config["identity"]) }
  }

  static func apply(_ config: JSONObject, state: JSONObject, date: Date) throws -> (JSONObject, JSONObject) {
    try validateOperation(config)
    guard Set(state.keys) == ["version", "requests"], state["version"] == .integer(1),
      case var .object(rows)? = state["requests"], rows.count <= 10_000 else { throw durableQueueInvalid() }
    var candidates: [Candidate] = []
    for (key, value) in rows {
      try identity(.string(key))
      guard case let .object(row) = value, case .object? = row["request"],
        [.string("pending"), .string("acquired"), .string("completed")].contains(row["status"]),
        case let .integer(attempts)? = row["attempts"], (0...1_000_000_000).contains(attempts),
        let registered = timestamp(row["registered_at"]),
        row["last_attempt_at"] == nil || timestamp(row["last_attempt_at"]) != nil else { throw durableQueueInvalid() }
      if row["status"] == .string("pending") {
        candidates.append(.init(identity: key, row: row, attempted: timestamp(row["last_attempt_at"]) ?? .distantPast, registered: registered))
      }
    }
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let now = JSONValue.string(formatter.string(from: date))
    var result: JSONObject = [:]
    switch config["action"] {
    case .string("pending"):
      let ordered = candidates.sorted(by: precedes)
      let maximum: Int64?
      if case let .integer(value)? = config["maxAttempts"] { maximum = value } else { maximum = nil }
      let eligible = ordered.filter { candidate in
        guard let maximum, case let .integer(attempts)? = candidate.row["attempts"] else { return true }
        return attempts < maximum
      }
      let pending = eligible.first
      result = ["found": .bool(pending != nil), "identity": pending.map { .string($0.identity) } ?? .null, "request": pending?.row["request"] ?? .null]
      if let maximum {
        let exhausted = candidates.filter { candidate in
          guard case let .integer(attempts)? = candidate.row["attempts"] else { return false }
          return attempts >= maximum
        }.sorted { Data($0.identity.utf8).lexicographicallyPrecedes(Data($1.identity.utf8)) }
        result["exhausted"] = .array(exhausted.map { .object(["identity": .string($0.identity), "attempts": $0.row["attempts"] ?? .null]) })
        result["exhaustedCount"] = .integer(Int64(exhausted.count))
      }
      if case let .integer(limit)? = config["limit"] {
        var items: [JSONValue] = []
        result["items"] = .array(items); result["itemsTruncated"] = .bool(false)
        for candidate in eligible.prefix(Int(limit)) {
          let item: JSONValue = .object(["identity": .string(candidate.identity), "request": candidate.row["request"] ?? .null,
            "attempts": candidate.row["attempts"] ?? .null])
          result["items"] = .array(items + [item])
          if try JSONEncoder().encode(result).count > DurableQueueJournal.maximumBytes {
            result["items"] = .array(items); result["itemsTruncated"] = .bool(true)
            break
          }
          items.append(item)
        }
      }
    case .string("admit"):
      guard case let .string(key)? = config["identity"], let request = config["request"] else { throw durableQueueInvalid() }
      var row: JSONObject
      if case let .object(old)? = rows[key] {
        guard try JSONEncoder().encode(old["request"]).count <= 262_144, try exactRequest(old["request"], request) else { throw durableQueueInvalid() }
        row = old; row["status"] = .string("pending")
      } else {
        guard rows.count < 10_000 else { throw durableQueueInvalid() }
        row = ["request": request, "status": .string("pending"), "registered_at": now, "attempts": .integer(0)]
      }
      rows[key] = .object(row); result = ["identity": .string(key)]
    case .string("attempted"), .string("finish"):
      guard case let .string(key)? = config["identity"], case var .object(row)? = rows[key] else { throw durableQueueInvalid() }
      if config["action"] == .string("attempted") {
        guard case let .integer(attempts)? = row["attempts"], attempts < 1_000_000_000 else { throw durableQueueInvalid() }
        row["attempts"] = .integer(attempts + 1); row["last_attempt_at"] = now
      } else {
        let field: String
        if case let .string(key)? = config["completionField"] { field = key } else { field = "complete" }
        row[field] = config["complete"]; row["last_result"] = config["status"]; row["updated_at"] = now
        if config["complete"] == .bool(true) { row["status"] = .string("completed") }
      }
      rows[key] = .object(row); result = ["identity": .string(key)]
    default: throw durableQueueInvalid()
    }
    return (["version": .integer(1), "requests": .object(rows)], result)
  }

  private static func precedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
    if lhs.attempted != rhs.attempted { return lhs.attempted < rhs.attempted }
    if lhs.registered != rhs.registered { return lhs.registered < rhs.registered }
    return Data(lhs.identity.utf8).lexicographicallyPrecedes(Data(rhs.identity.utf8))
  }

  private static func exactRequest(_ lhs: JSONValue?, _ rhs: JSONValue) throws -> Bool {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(lhs) == encoder.encode(rhs)
  }

  private static func identity(_ value: JSONValue?) throws {
    guard case let .string(text)? = value,
      text.range(of: #"\A[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,255}\z"#, options: .regularExpression) != nil else { throw durableQueueInvalid() }
  }

  private static func timestamp(_ value: JSONValue?) -> Date? {
    guard case let .string(text)? = value, text.utf8.count <= 64 else { return nil }
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
  }
}
