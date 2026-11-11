import Foundation
import RielaAddonSupport
import RielaCore

extension BuiltinWorkflowAddonResolver {
  static let xCollectionRegistration = BuiltinAddonHandlerRegistration(name: "riela/x-collect") { resolver, input, context in
    try await resolver.executeXCollect(input, context: context)
  }

  /// All reads stay in this SDK process, so a private workflow can inspect the
  /// result before exporting it. No scripts, subprocesses or nested containers.
  func executeXCollect(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1",
      case let .object(config) = try renderAddonConfig(.object(input.addon.config ?? [:]), variables: addonVariables(for: input)),
      Set(config.keys).isSubset(of: ["options", "context", "userCache", "usageCache", "usageScope"]),
      case let .object(values)? = config["options"], try JSONEncoder().encode(config).count <= 8_000_000 else { throw xCollectionInvalid() }
    var cache = config.filter { ["userCache", "usageCache", "usageScope"].contains($0.key) }
    for name in ["userCache", "usageCache"] where cache[name] == nil { cache[name] = .bool(false) }
    func fetch(_ operation: String, _ arguments: JSONObject, _ selection: JSONObject) async throws -> JSONObject {
      var request = cache
      request.merge(["operation": .string(operation), "arguments": .string("{{collectorArguments}}"),
        "select": .object(selection), "postprocess": .array([.object(["pick": .string("/data/" + operation)])])]) { _, new in new }
      let child = WorkflowAddonExecutionInput(workflowId: input.workflowId, stepId: input.stepId, nodeId: input.nodeId,
        addon: .init(name: "riela/x-gateway-reader", version: "1", config: request, env: input.addon.env),
        variables: ["collectorArguments": .object(arguments)], executionIdentity: input.executionIdentity)
      let output = try await execute(child, context: context)
      guard case let .object(response)? = output.payload["processed"] else { throw xCollectionInvalid() }
      return response
    }
    var payload: JSONObject
    switch values["mode"] {
    case .string("lookup")?:
      let budget = 8_000_000 - (try JSONEncoder().encode(config["context"] ?? .null).count) - 64
      payload = try await XLookupCollection(values).collect(outputByteBudget: budget, fetch: fetch)
    case nil: payload = try await XAuthorCollector(options: .init(values)).collect(fetch: fetch)
    default: throw xCollectionInvalid()
    }
    payload["context"] = config["context"] ?? .null
    guard try JSONEncoder().encode(payload).count <= 8_000_000 else { throw xCollectionInvalid() }
    return .init(provider: "riela-builtin-addon", model: input.addon.name, promptText: "", completionPassed: true,
      when: ["always": true], payload: payload)
  }
}

struct XAuthorCollector {
  let options: XCollectionOptions
  var clock: () -> Date = { Date() }
  var sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
  /// X search rejects an end_time less than 10 seconds before the request; 1s covers clock skew.
  static let searchEndLag: TimeInterval = 11

  func collect(fetch: (String, JSONObject, JSONObject) async throws -> JSONObject) async throws -> JSONObject {
    var samplingState = try options.authorDailyPostThreshold == nil ? nil : XSamplingState(options: options)
    let samplingEnabled = options.authorSampling != nil || options.authorDailyPostThreshold != nil
    let samplingDay = try samplingEnabled ? XSamplingState.day(end: options.end, timezone: options.timezone) : ""
    var probabilities = options.authorSampling ?? [:]
    if let state = samplingState {
      for (handle, entry) in state.auto where probabilities[handle] == nil { probabilities[handle] = entry.probability }
    }
    let sampledHandles = options.handles.filter { probabilities[$0.lowercased()] != nil }
    var regularOptions = options
    regularOptions.handles = options.handles.filter { probabilities[$0.lowercased()] == nil }
    var previous = options.previous
    previous.removeValue(forKey: "author_sampling")
    let now = clock()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    let billingDayStart = calendar.startOfDay(for: now)
    guard try xInstant(options.end) <= now else { throw xCollectionInvalid() }
    let account = try await fetch("accountMe", [:], ["id": .bool(true), "username": .bool(true)])
    guard let identity = try xOptionalID(account["id"]),
      case let .string(handle)? = account["username"], handle.lowercased() == options.expected.lowercased() else {
      throw AdapterExecutionError(.policyBlocked, "X collection authenticated account mismatch")
    }
    let groups = regularOptions.handles.isEmpty ? [] : regularOptions.groups
    samplingState?.retainPending(queries: groups.map { $0.map { "from:" + $0 }.joined(separator: " OR ") })
    let previousShards: JSONObject
    if previous["author_scope"] == .string(regularOptions.scope), case let .object(shards)? = previous["author_shards"] {
      previousShards = shards
    } else { previousShards = [:] }
    var checkpoints: JSONObject = [:], posts: [JSONObject] = [], failures: [JSONValue] = []
    // Validate every imported cursor before the first paid search request.
    var windows: [XCollectionWindow] = []
    for (index, handles) in groups.enumerated() {
      var child = options; child.billingDayStart = billingDayStart; child.handles = handles; child.maximum = options.maximum / groups.count
      if case var .object(settings)? = child.signatureContext["settings"] {
        settings["author_handles"] = .array(handles.map(JSONValue.string))
        if groups.count > 1 { settings["max_posts"] = .integer(Int64(child.maximum)) }
        child.signatureContext["settings"] = .object(settings)
      }
      guard child.maximum >= 5, !child.fresh || child.maximum >= 2 * child.pageSize else { throw xCollectionInvalid() }
      let childPrevious = groups.count == 1 ? previous : {
        if case let .object(value)? = previousShards[String(index)] { return value }; return [:]
      }()
      let window = try XCollectionWindow(options: child, query: handles.map { "from:" + $0 }.joined(separator: " OR "), account: identity, previous: childPrevious)
      if child.fresh, window.checkpoint["pending_scan"] != nil, try xInstant(window.end) < xInstant(child.end) {
        guard child.maximum >= window.size + child.pageSize else { throw xCollectionInvalid() }
      }
      windows.append(window)
    }
    for index in windows.indices {
      var window = windows[index]
      if options.fresh, window.checkpoint["pending_scan"] != nil, try xInstant(window.end) < xInstant(options.end) {
        let signature = try window.options.headSignature(account: identity, checkpoint: window.checkpoint, probeStart: window.end)
        let receipt: JSONObject
        if case let .object(value)? = window.checkpoint["fresh_head_receipt"] { receipt = value } else { receipt = [:] }
        if options.closed(at: clock()), receipt["version"] == .integer(1), receipt["signature"] == .string(signature),
          [JSONValue.string("complete"), .string("partial")].contains(receipt["status"] ?? .null),
          let returned = xInt(receipt["returned_count"]), (0...100).contains(returned) {
          window.checkpoint["fresh_head"] = .object(["status": receipt["status"] ?? .null, "page_count": .integer(0),
            "accepted_count": .integer(0), "reused": .bool(true), "prior_accepted_count": .integer(returned)])
        } else {
          var headOptions = window.options; headOptions.start = window.end; headOptions.fresh = false
          headOptions.maximum = headOptions.pageSize; headOptions.maxPages = 1
          var headPrevious: JSONObject = ["account_id": .string(identity), "author_query": .string(window.query),
            "since_id": window.checkpoint["since_id"] ?? .null]
          if let depth = headOptions.depthIdentity { headPrevious["reference_depth"] = .integer(Int64(depth)) }
          var head = try XCollectionWindow(options: headOptions, query: window.query, account: identity, previous: headPrevious)
          let success = try await read(&head, shard: index, label: "head", failures: &failures, fetch: fetch)
          posts += head.posts
          let status = success ? (head.cursor == nil ? "complete" : "partial") : "failed"
          window.checkpoint["fresh_head"] = .object(["status": .string(status), "page_count": .integer(Int64(head.pages)),
            "accepted_count": .integer(Int64(head.posts.count))])
          if options.closed(at: clock()), success {
            window.checkpoint["fresh_head_receipt"] = .object(["version": .integer(1), "signature": .string(signature),
              "status": .string(status), "returned_count": .integer(Int64(head.posts.count))])
          }
        }
      }
      _ = try await read(&window, shard: index, label: "page", failures: &failures, fetch: fetch)
      posts += window.posts
      try samplingState?.apply(window: window, handles: groups[index], sampled: false, success: !window.failed)
      checkpoints[String(index)] = .object(try window.result(at: ISO8601DateFormatter().string(from: clock())))
    }
    let (metadata, sampledGroupCount) = try await collectSampled(handles: sampledHandles, probabilities: probabilities,
      identity: identity, state: &samplingState, posts: &posts, failures: &failures, fetch: fetch)
    var seen = Set<String>()
    posts = posts.filter { value in value["id"].flatMap { nonEmptyString($0) }.map { seen.insert($0).inserted } ?? false }
    guard posts.count <= options.maximum + options.pageSize * sampledGroupCount, try JSONEncoder().encode(posts).count <= 6_000_000 else { throw xCollectionInvalid() }
    var checkpoint: JSONObject
    if groups.isEmpty {
      checkpoint = ["account_id": .string(identity), "expected_handle": .string(options.expected),
        "checked_at": .string(ISO8601DateFormatter().string(from: clock())), "author_query": .string(""),
        "coverage": .object(["version": .integer(1), "account_id": .string(identity),
          "expected_handle": .string(options.expected.lowercased()), "start": .string(options.start),
          "end": .string(options.end), "complete": .bool(true)])]
    } else if groups.count == 1, case let .object(single)? = checkpoints["0"] { checkpoint = single } else {
      let children = checkpoints.values.compactMap { if case let .object(value) = $0 { return value }; return nil }
      let complete = children.allSatisfy { if case let .object(coverage)? = $0["coverage"] { return coverage["complete"] == .bool(true) }; return false }
      var combined: JSONObject = ["author_scope": .string(regularOptions.scope), "author_shards": .object(checkpoints),
        "account_id": .string(identity), "expected_handle": .string(options.expected),
        "checked_at": .string(ISO8601DateFormatter().string(from: clock())),
        "page_count": .integer(children.reduce(0) { $0 + (xInt($1["page_count"]) ?? 0) }),
        "scan_page_count": .integer(children.reduce(0) { $0 + (xInt($1["scan_page_count"]) ?? 0) })]
      let bounds = try children.map { value -> (String, String) in
        guard case let .object(c)? = value["coverage"], case let .string(first)? = c["start"], case let .string(last)? = c["end"] else { throw xCollectionInvalid() }
        return (first, last)
      }
      let first = try bounds.map(\.0).sorted { try xInstant($0) < xInstant($1) }.last ?? options.start
      let last = try bounds.map(\.1).sorted { try xInstant($0) < xInstant($1) }.first ?? options.end
      combined["coverage"] = .object(["version": .integer(1), "account_id": .string(identity), "expected_handle": .string(options.expected.lowercased()),
        "start": .string(first), "end": .string(last), "complete": .bool(complete)])
      if !complete { combined["pending_scan"] = .object(["author_shards": .bool(true)]); combined["scan_stop_reason"] = .string("author-shard-pending") }
      if let key = previous["config_key"] { combined["config_key"] = key }
      checkpoint = combined
    }
    if let samplingState { checkpoint["author_sampling"] = .object(samplingState.json) }
    let complete: Bool
    if case let .object(coverage)? = checkpoint["coverage"] { complete = coverage["complete"] == .bool(true) } else { complete = false }
    var output: JSONObject = ["posts": .array(posts.map(JSONValue.object)), "checkpoint": .object(checkpoint),
      "complete": .bool(complete), "failures": .array(failures)]
    if samplingEnabled {
      output["sampling"] = .object(["version": .integer(1),
        "threshold": options.authorDailyPostThreshold.map { .integer(Int64($0)) } ?? .null,
        "day": .string(samplingDay), "handles": .array(metadata.keys.sorted().compactMap { metadata[$0].map(JSONValue.object) })])
    }
    return output
  }

  private func collectSampled(handles: [String], probabilities: [String: Double], identity: String,
                              state: inout XSamplingState?, posts: inout [JSONObject], failures: inout [JSONValue],
                              fetch: (String, JSONObject, JSONObject) async throws -> JSONObject) async throws -> ([String: JSONObject], Int) {
    var drawn: [String] = []
    var metadata: [String: JSONObject] = [:]
    for handle in handles {
      let key = handle.lowercased()
      guard let probability = probabilities[key] else { continue }
      let isDrawn = XCollectionSampling.drawn(probability: probability,
        value: try XCollectionSampling.drawValue(handle: key, end: options.end))
      if isDrawn { drawn.append(handle) }
      let volume = state?.volume(key)
      metadata[key] = ["handle": .string(key), "source": .string(options.authorSampling?[key] == nil ? "auto" : "explicit"),
        "probability": .number(probability), "observedDailyVolume": volume.map(JSONValue.number) ?? .null,
        "status": .string(isDrawn ? "drawn" : "skipped"), "fetchedCount": .integer(0), "truncated": .bool(false)]
    }
    var sampledOptions = options
    sampledOptions.handles = drawn
    sampledOptions.fresh = false
    sampledOptions.maximum = options.pageSize
    sampledOptions.maxPages = 1
    let sampledGroups = drawn.isEmpty ? [] : sampledOptions.groups
    for (index, handles) in sampledGroups.enumerated() {
      var child = sampledOptions; child.handles = handles
      var window = try XCollectionWindow(options: child, query: handles.map { "from:" + $0 }.joined(separator: " OR "),
        account: identity, previous: [:])
      let success = try await read(&window, shard: index, label: "sampled", failures: &failures, fetch: fetch)
      try state?.apply(window: window, handles: handles, sampled: true, success: success)
      posts += window.posts
      for handle in handles {
        let key = handle.lowercased()
        let count = window.posts.filter { post in
          guard case let .object(author)? = post["author"], case let .string(name)? = author["username"] else { return false }
          return name.lowercased() == key
        }.count
        metadata[key]?["fetchedCount"] = .integer(Int64(count))
        metadata[key]?["truncated"] = .bool(window.cursor != nil)
      }
    }
    return (metadata, sampledGroups.count)
  }

  private func read(_ window: inout XCollectionWindow, shard: Int, label: String, failures: inout [JSONValue],
                    fetch: (String, JSONObject, JSONObject) async throws -> JSONObject) async throws -> Bool {
    while window.pages < window.options.maxPages, window.needsRequest {
      guard window.options.maximum - window.fetched >= window.size else { break }
      do {
        try Task.checkCancellation()
        let arguments = try window.arguments()
        let future = try xInstant(xWire(window.end, upper: true)).timeIntervalSince(clock())
        guard future <= 1 else { throw xCollectionInvalid() }
        let wait = future + Self.searchEndLag
        if wait > 0 { try await sleep(wait) }
        let response = try await fetch("searchPosts", arguments, options.selection)
        try window.accept(response, at: ISO8601DateFormatter().string(from: clock()))
      } catch is CancellationError { throw CancellationError() } catch {
        window.failed = true
        var failure: JSONObject = ["shard": .integer(Int64(shard)), "stage": .string(label), "code": .string("page-unavailable")]
        if let error = error as? AdapterExecutionError {
          let diagnostics = GatewayFailureDiagnostics.fields(readerMessage: error.message)
          if !diagnostics.isEmpty { failure["diagnostics"] = .object(diagnostics) }
        }
        failures.append(.object(failure))
        return false
      }
    }
    return true
  }
}
