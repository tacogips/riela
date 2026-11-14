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

  func collect(fetch: (String, JSONObject, JSONObject) async throws -> JSONObject) async throws -> JSONObject {
    guard try xInstant(options.end) <= clock() else { throw xCollectionInvalid() }
    let account = try await fetch("accountMe", [:], ["id": .bool(true), "username": .bool(true)])
    guard let identity = try xOptionalID(account["id"]),
      case let .string(handle)? = account["username"], handle.lowercased() == options.expected.lowercased() else {
      throw AdapterExecutionError(.policyBlocked, "X collection authenticated account mismatch")
    }
    let groups = options.groups
    let previousShards: JSONObject
    if options.previous["author_scope"] == .string(options.scope), case let .object(shards)? = options.previous["author_shards"] {
      previousShards = shards
    } else { previousShards = [:] }
    var checkpoints: JSONObject = [:], posts: [JSONObject] = [], failures: [JSONValue] = []
    // Validate every imported cursor before the first paid search request.
    var windows: [XCollectionWindow] = []
    for (index, handles) in groups.enumerated() {
      var child = options; child.handles = handles; child.maximum = options.maximum / groups.count
      if case var .object(settings)? = child.signatureContext["settings"] {
        settings["author_handles"] = .array(handles.map(JSONValue.string))
        if groups.count > 1 { settings["max_posts"] = .integer(Int64(child.maximum)) }
        child.signatureContext["settings"] = .object(settings)
      }
      guard child.maximum >= 5, !child.fresh || child.maximum >= 2 * child.pageSize else { throw xCollectionInvalid() }
      let previous = groups.count == 1 ? options.previous : {
        if case let .object(value)? = previousShards[String(index)] { return value }; return [:]
      }()
      let window = try XCollectionWindow(options: child, query: handles.map { "from:" + $0 }.joined(separator: " OR "), account: identity, previous: previous)
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
          var head = try XCollectionWindow(options: headOptions, query: window.query, account: identity,
            previous: ["account_id": .string(identity), "author_query": .string(window.query), "since_id": window.checkpoint["since_id"] ?? .null])
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
      checkpoints[String(index)] = .object(try window.result(at: ISO8601DateFormatter().string(from: clock())))
    }
    var seen = Set<String>()
    posts = posts.filter { value in value["id"].flatMap { nonEmptyString($0) }.map { seen.insert($0).inserted } ?? false }
    guard posts.count <= options.maximum, try JSONEncoder().encode(posts).count <= 6_000_000 else { throw xCollectionInvalid() }
    let checkpoint: JSONObject
    if groups.count == 1, case let .object(single)? = checkpoints["0"] { checkpoint = single } else {
      let children = checkpoints.values.compactMap { if case let .object(value) = $0 { return value }; return nil }
      let complete = children.allSatisfy { if case let .object(coverage)? = $0["coverage"] { return coverage["complete"] == .bool(true) }; return false }
      var combined: JSONObject = ["author_scope": .string(options.scope), "author_shards": .object(checkpoints),
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
      if let key = options.previous["config_key"] { combined["config_key"] = key }
      checkpoint = combined
    }
    let complete: Bool
    if case let .object(coverage)? = checkpoint["coverage"] { complete = coverage["complete"] == .bool(true) } else { complete = false }
    return ["posts": .array(posts.map(JSONValue.object)), "checkpoint": .object(checkpoint),
      "complete": .bool(complete), "failures": .array(failures)]
  }

  private func read(_ window: inout XCollectionWindow, shard: Int, label: String, failures: inout [JSONValue],
                    fetch: (String, JSONObject, JSONObject) async throws -> JSONObject) async throws -> Bool {
    while window.pages < window.options.maxPages, window.pages == 0 || window.cursor != nil {
      guard window.options.maximum - window.fetched >= window.size else { break }
      do {
        try Task.checkCancellation()
        let arguments = try window.arguments()
        let future = try xInstant(xWire(window.end, upper: true)).timeIntervalSince(clock())
        guard future <= 1 else { throw xCollectionInvalid() }
        if future > 0 { try await Task.sleep(for: .seconds(future)) }
        let response = try await fetch("searchPosts", arguments, options.selection)
        try window.accept(response, at: ISO8601DateFormatter().string(from: clock()))
      } catch is CancellationError { throw CancellationError() } catch {
        window.failed = true
        failures.append(.object(["shard": .integer(Int64(shard)), "stage": .string(label), "code": .string("page-unavailable")]))
        return false
      }
    }
    return true
  }
}
