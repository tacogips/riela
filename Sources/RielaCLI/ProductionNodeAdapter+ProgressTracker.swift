import Foundation
import RielaAddonSupport
import RielaCore

extension BuiltinWorkflowAddonResolver {
  static let progressTrackerRegistration = BuiltinAddonHandlerRegistration(name: "riela/progress-tracker", bindsCLIVariablesAsInputs: false) { _, input, context in
    try snapshotWorkResult {
      try checkSnapshotWork(context)
      guard input.addon.version == nil || input.addon.version == "1",
        case let .object(config) = try renderAddonConfig(.object(input.addon.config ?? [:]), variables: addonVariables(for: input)) else { throw trackerInvalid() }
      let payload = try ProgressTracker.run(config)
      try checkSnapshotWork(context)
      return .init(provider: "riela-builtin-addon", model: input.addon.name, promptText: "", completionPassed: true, payload: payload)
    }
  }
}

/// Bounded metadata observations only. This never fetches, publishes or ACKs work.
enum ProgressTracker {
  static func run(_ config: JSONObject) throws -> JSONObject {
    guard Set(config.keys).isSubset(of: ["mode", "state", "event", "baseline", "maximumTurns", "items", "budgetAvailable"]),
      case let .string(mode)? = config["mode"],
      case let .integer(maximum) = config["maximumTurns"] ?? .integer(64), (1...64).contains(maximum),
      try JSONEncoder().encode(config).count <= 1_000_000 else { throw trackerInvalid() }
    let prior = try trackerObject(config["state"])
    let event = try trackerObject(config["event"])
    let output: JSONObject
    if mode != "round-robin", config["items"] != nil || config["budgetAvailable"] != nil { throw trackerInvalid() }
    switch mode {
    case "round-robin":
      guard event == nil, config["baseline"] == nil else { throw trackerInvalid() }
      output = try RoundRobinProgress.next(config, maximum: Int(maximum))
    case "identity-sweep":
      guard config["baseline"] == nil else { throw trackerInvalid() }
      var tracker = try IdentityProgress(prior, maximum: Int(maximum))
      if let event { try tracker.observe(event) }
      output = tracker.output()
    case "decreasing-counters":
      guard prior == nil || config["baseline"] == nil else { throw trackerInvalid() }
      var tracker = try CounterProgress(prior, baseline: config["baseline"], maximum: Int(maximum))
      if let event { try tracker.observe(event) }
      output = tracker.output()
    default: throw trackerInvalid()
    }
    guard try JSONEncoder().encode(output).count <= 1_000_000 else { throw trackerInvalid() }
    return output
  }
}

private struct IdentityProgress {
  var count = 0
  var done = false
  var known: [Data] = []
  var excluded = Set<Data>()
  var eligible = Set<Data>()
  var seen: [Data: Set<Data>] = [:]
  let maximum: Int

  init(_ state: JSONObject?, maximum: Int) throws {
    self.maximum = maximum
    guard let state else { return }
    guard Set(state.keys) == ["version", "mode", "maximumTurns", "count", "done", "known", "excluded", "eligible", "seen"],
      state["version"] == .integer(1), state["mode"] == .string("identity-sweep"), state["maximumTurns"] == .integer(Int64(maximum)) else { throw trackerInvalid() }
    count = try trackerCount(state["count"], maximum: maximum); done = try trackerBool(state, "done")
    known = try trackerIDs(state["known"], maximum: count * 5)
    excluded = Set(try trackerIDs(state["excluded"], maximum: known.count))
    eligible = Set(try trackerIDs(state["eligible"], maximum: known.count))
    let identities = Set(known)
    guard excluded.isSubset(of: identities), eligible.isSubset(of: identities),
      case let .array(rows)? = state["seen"], rows.count == known.count else { throw trackerInvalid() }
    for row in rows {
      guard case let .object(row) = row, Set(row.keys) == ["identity", "tokens"], let identity = try trackerID(row["identity"]),
        identities.contains(identity), seen[identity] == nil else { throw trackerInvalid() }
      seen[identity] = Set(try trackerIDs(row["tokens"], maximum: maximum * 2))
    }
    guard seen.values.reduce(0, { $0 + $1.count }) <= count * 5 else { throw trackerInvalid() }
  }

  mutating func observe(_ event: JSONObject) throws {
    guard Set(event.keys).isSubset(of: ["identity", "token", "advanced", "accepted", "idle", "published", "boundary", "proofs"]) else { throw trackerInvalid() }
    let identity = try trackerID(event["identity"]), token = try trackerID(event["token"])
    let accepted = try trackerBool(event, "accepted"), published = try trackerBool(event, "published")
    let advanced = try trackerBool(event, "advanced"), idle = try trackerBool(event, "idle"), boundary = try trackerBool(event, "boundary")
    guard case let .array(raw) = event["proofs"] ?? .array([]), raw.count <= 4 else { throw trackerInvalid() }
    var proofs: [(Data, Data)] = [], identities = Set<Data>()
    for proof in raw {
      guard case let .object(row) = proof, Set(row.keys) == ["identity", "token"],
        let key = try trackerID(row["identity"]), let value = try trackerID(row["token"]), identities.insert(key).inserted else { throw trackerInvalid() }
      proofs.append((key, value))
    }
    let reported = accepted && published ? proofs : []
    let fresh = reported.filter { !(seen[$0.0] ?? []).contains($0.1) }
    guard count < maximum, !done else { return }
    count += 1
    if boundary { done = true; return }
    if let identity {
      if excluded.contains(identity) { done = true
      } else {
        remember(identity); excluded.insert(identity)
        if accepted && advanced, let token, !(seen[identity] ?? []).contains(token) { eligible.insert(identity)
        } else { eligible.remove(identity) }
        if let token { seen[identity, default: []].insert(token) }
      }
    } else if !published {
      if idle && accepted && !eligible.isEmpty { excluded = Set(known).subtracting(eligible); eligible = []
      } else { done = true }
    }
    if !reported.isEmpty && fresh.isEmpty && identity == nil { done = true }
    for (identity, token) in fresh {
      remember(identity); excluded.insert(identity); eligible.insert(identity); seen[identity, default: []].insert(token)
    }
  }

  private mutating func remember(_ identity: Data) {
    if !known.contains(identity) { known.append(identity); seen[identity] = [] }
  }
  func output() -> JSONObject {
    let state: JSONObject = ["version": .integer(1), "mode": .string("identity-sweep"), "maximumTurns": .integer(Int64(maximum)),
      "count": .integer(Int64(count)), "done": .bool(done), "known": trackerArray(known),
      "excluded": trackerArray(known.filter { excluded.contains($0) }), "eligible": trackerArray(known.filter { eligible.contains($0) }),
      "seen": .array(known.map { .object(["identity": trackerString($0), "tokens": trackerArray((seen[$0] ?? []).sorted { $0.lexicographicallyPrecedes($1) })]) })]
    return ["state": .object(state), "count": .integer(Int64(count)), "canContinue": .bool(!done && count < maximum),
      "excludedIds": trackerArray(known.filter { excluded.contains($0) })]
  }
}

private struct CounterProgress {
  var count = 0
  var observed = false
  var eligible = false
  var minimums: [String: Int] = [:]
  let maximum: Int
  init(_ state: JSONObject?, baseline: JSONValue?, maximum: Int) throws {
    self.maximum = maximum
    if let state {
      guard Set(state.keys) == ["version", "mode", "maximumTurns", "count", "observed", "eligible", "minimums"],
        state["version"] == .integer(1), state["mode"] == .string("decreasing-counters"), state["maximumTurns"] == .integer(Int64(maximum)) else { throw trackerInvalid() }
      count = try trackerCount(state["count"], maximum: maximum)
      observed = try trackerBool(state, "observed"); eligible = try trackerBool(state, "eligible")
      minimums = try trackerCounters(state["minimums"])
    } else { minimums = try trackerCounters(baseline ?? .object([:])) }
  }
  mutating func observe(_ event: JSONObject) throws {
    guard Set(event.keys).isSubset(of: ["counts", "pending", "accepted", "verified"]) else { throw trackerInvalid() }
    let current = try trackerCounters(event["counts"] ?? .object([:]))
    let pending = try trackerBool(event, "pending"), accepted = try trackerBool(event, "accepted"), verified = try trackerBool(event, "verified")
    guard count < maximum else { eligible = false; return }
    guard Set(current.keys).union(minimums.keys).count <= 16 else { throw trackerInvalid() }
    let comparable = Set(current.keys).intersection(minimums.keys)
    let decreased = comparable.contains { current[$0]! < minimums[$0]! }
    eligible = accepted && (pending || current.values.contains { $0 > 0 }) && (decreased || (!observed && comparable.isEmpty && verified))
    for (key, value) in current { minimums[key] = min(value, minimums[key] ?? value) }
    observed = true; count += 1
  }
  func output() -> JSONObject {
    ["state": .object(["version": .integer(1), "mode": .string("decreasing-counters"), "maximumTurns": .integer(Int64(maximum)),
      "count": .integer(Int64(count)), "observed": .bool(observed), "eligible": .bool(eligible),
      "minimums": .object(minimums.mapValues { .integer(Int64($0)) })]),
      "count": .integer(Int64(count)), "canContinue": .bool(eligible && count < maximum)]
  }
}

private func trackerObject(_ value: JSONValue?) throws -> JSONObject? {
  if value == nil || value == .null { return nil }
  guard case let .object(object)? = value else { throw trackerInvalid() }; return object
}
private func trackerID(_ value: JSONValue?) throws -> Data? {
  if value == nil || value == .null { return nil }
  guard case let .string(text)? = value, !text.isEmpty, text.utf8.count <= 256 else { throw trackerInvalid() }; return Data(text.utf8)
}
private func trackerIDs(_ value: JSONValue?, maximum: Int) throws -> [Data] {
  guard case let .array(rows)? = value, rows.count <= maximum else { throw trackerInvalid() }
  let values = try rows.map { guard let value = try trackerID($0) else { throw trackerInvalid() }; return value }
  guard Set(values).count == values.count else { throw trackerInvalid() }; return values
}
private func trackerCount(_ value: JSONValue?, maximum: Int = 100_000) throws -> Int {
  guard case let .integer(number)? = value, (0...Int64(maximum)).contains(number) else { throw trackerInvalid() }; return Int(number)
}
private func trackerBool(_ value: JSONObject, _ key: String) throws -> Bool {
  guard case let .bool(flag) = value[key] ?? .bool(false) else { throw trackerInvalid() }; return flag
}
private func trackerCounters(_ value: JSONValue?) throws -> [String: Int] {
  guard case let .object(rows)? = value, rows.count <= 16,
    rows.keys.allSatisfy({ $0.range(of: #"^[A-Za-z0-9_.-]{1,128}$"#, options: .regularExpression) != nil }) else { throw trackerInvalid() }
  return try rows.mapValues { try trackerCount($0) }
}
private func trackerArray(_ values: [Data]) -> JSONValue { .array(values.map(trackerString)) }
private func trackerString(_ value: Data) -> JSONValue { .string(String(data: value, encoding: .utf8)!) }
private func trackerInvalid() -> AdapterExecutionError { .init(.invalidInput, "invalid bounded progress state or observation") }
