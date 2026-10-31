import Foundation
import RielaAddonSupport
import RielaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// `riela/home-assistant-read` and `riela/home-assistant-write` over the Home
// Assistant REST API. Credentials come only from `addon.env`
// (HOME_ASSISTANT_URL, HOME_ASSISTANT_TOKEN); HTTP goes through the resolver's
// injectable `mediaPipelineHTTP` seam. Writes are default-deny: the service and
// every targeted entity must be on literal allowlists in the workflow file.
extension BuiltinWorkflowAddonResolver {
  static let homeAssistantReadRegistration = BuiltinAddonHandlerRegistration(
    name: "riela/home-assistant-read", bindsCLIVariablesAsInputs: false
  ) { resolver, input, context in
    try await resolver.executeHomeAssistantRead(input, context: context)
  }

  static let homeAssistantWriteRegistration = BuiltinAddonHandlerRegistration(
    name: "riela/home-assistant-write", bindsCLIVariablesAsInputs: false
  ) { resolver, input, context in
    try await resolver.executeHomeAssistantWrite(input, context: context)
  }

  func executeHomeAssistantRead(
    _ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    let request = try HomeAssistantAddonRequest(input: input, resolver: self)
    let options = request.options
    try HomeAssistantOptions.allowOnly(
      options, ["operation", "entityId", "entityIds", "domain", "limit", "timeoutSeconds"])
    let operation = try HomeAssistantOptions.string(options, "operation")
    var result: JSONObject = ["operation": .string(operation ?? "")]
    var when: [String: Bool] = ["always": true]
    switch operation {
    case "state":
      guard let entityId = try HomeAssistantOptions.string(options, "entityId"),
        HomeAssistantPolicy.isEntityId(entityId)
      else { throw HomeAssistantOptions.invalid("operation 'state' requires a valid options.entityId") }
      let state = try await request.send(method: "GET", path: "/api/states/\(entityId)", deadline: context.deadline)
      guard case let .object(stateObject) = state else {
        throw AdapterExecutionError(.providerError, "home-assistant returned a non-object state")
      }
      result["entityId"] = .string(entityId)
      result["state"] = state
      if case let .string(value)? = stateObject["state"], let label = HomeAssistantPolicy.stateLabel(value) {
        when[label] = true
      }
    case "states":
      let entityIds = try HomeAssistantOptions.stringArray(options, "entityIds", max: HomeAssistantPolicy.maxStates)
      if let entityIds, !entityIds.allSatisfy(HomeAssistantPolicy.isEntityId) {
        throw HomeAssistantOptions.invalid("options.entityIds must contain entity ids like 'light.kitchen'")
      }
      let domain = try HomeAssistantOptions.string(options, "domain")
      if let domain, !HomeAssistantPolicy.isIdentifier(domain) {
        throw HomeAssistantOptions.invalid("options.domain must match ^[a-z0-9_]+$")
      }
      let limit = try HomeAssistantOptions.integer(
        options, "limit", default: HomeAssistantPolicy.maxStates, range: 1...HomeAssistantPolicy.maxStates)
      guard case let .array(all) = try await request.send(method: "GET", path: "/api/states", deadline: context.deadline)
      else { throw AdapterExecutionError(.providerError, "home-assistant returned a non-array state list") }
      let wanted = entityIds.map(Set.init)
      let filtered = all.filter { entry in
        guard case let .object(object) = entry, case let .string(id)? = object["entity_id"] else { return false }
        if let wanted, !wanted.contains(id) { return false }
        if let domain, !id.hasPrefix(domain + ".") { return false }
        return true
      }
      result["states"] = .array(Array(filtered.prefix(limit)))
      result["count"] = .integer(Int64(min(filtered.count, limit)))
      result["matched"] = .integer(Int64(filtered.count))
      result["truncated"] = .bool(filtered.count > limit)
    case "config":
      result["config"] = try await request.send(method: "GET", path: "/api/config", deadline: context.deadline)
    default:
      throw HomeAssistantOptions.invalid("options.operation must be one of state, states, config")
    }
    return try request.output(result, when: when)
  }

  func executeHomeAssistantWrite(
    _ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    let request = try HomeAssistantAddonRequest(input: input, resolver: self)
    let options = request.options
    try HomeAssistantOptions.allowOnly(
      options,
      ["operation", "domain", "service", "target", "data", "allowedServices", "allowedEntities", "timeoutSeconds"])
    guard try HomeAssistantOptions.string(options, "operation") == "service" else {
      throw HomeAssistantOptions.invalid("options.operation must be 'service'")
    }
    // Allowlists are policy: they must be literal in the workflow file, never
    // produced by a template that an upstream step (or model) could steer.
    let policy = try HomeAssistantPolicy(rawOptions: input.addon.config?["options"])
    guard let domain = try HomeAssistantOptions.string(options, "domain"), HomeAssistantPolicy.isIdentifier(domain),
      let service = try HomeAssistantOptions.string(options, "service"), HomeAssistantPolicy.isIdentifier(service)
    else { throw HomeAssistantOptions.invalid("options.domain and options.service must match ^[a-z0-9_]+$") }
    let target = try HomeAssistantOptions.object(options, "target")
    let data = try HomeAssistantOptions.object(options, "data")
    try policy.authorize(domain: domain, service: service, target: target, data: data)

    var body = data
    for (key, value) in target {
      guard body[key] == nil else {
        throw HomeAssistantOptions.invalid("options.target.\(key) duplicates options.data.\(key)")
      }
      body[key] = value
    }
    let response = try await request.send(
      method: "POST", path: "/api/services/\(domain)/\(service)", body: .object(body), deadline: context.deadline)
    var changed: [JSONValue] = []
    if case let .array(states) = response { changed = states }
    return try request.output([
      "operation": .string("service"),
      "request": .object([
        "domain": .string(domain), "service": .string(service), "body": .object(body)
      ]),
      "changedStates": .array(Array(changed.prefix(HomeAssistantPolicy.maxStates))),
      "changedCount": .integer(Int64(changed.count))
    ], when: ["always": true])
  }
}

struct HomeAssistantAddonRequest {
  let addonName: String
  let options: JSONObject
  let context: JSONValue?
  let baseURL: URL
  let token: String
  let timeout: Double
  let http: MediaPipelineHTTP
  let environment: [String: String]

  static let maxResponseBytes = 8_000_000

  init(input: WorkflowAddonExecutionInput, resolver: BuiltinWorkflowAddonResolver) throws {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }
    guard case let .object(config) = try renderAddonConfig(
      .object(input.addon.config ?? [:]), variables: addonVariables(for: input)),
      Set(config.keys).isSubset(of: ["options", "context"]),
      case let .object(options)? = config["options"]
    else {
      throw AdapterExecutionError(.invalidInput, "\(input.addon.name) config must be {\"options\": {...}, \"context\"?: ...}")
    }
    let bindings = input.addon.env ?? [:]
    guard Set(bindings.keys).isSubset(of: ["HOME_ASSISTANT_URL", "HOME_ASSISTANT_TOKEN"]) else {
      throw AdapterExecutionError(
        .policyBlocked, "\(input.addon.name) addon.env supports HOME_ASSISTANT_URL and HOME_ASSISTANT_TOKEN only")
    }
    let env = try resolveAddonEnvironment(bindings, runtimeEnvironment: resolver.environment)
    guard let rawURL = env["HOME_ASSISTANT_URL"], let token = env["HOME_ASSISTANT_TOKEN"], !token.isEmpty else {
      throw AdapterExecutionError(
        .policyBlocked, "\(input.addon.name) requires addon.env.HOME_ASSISTANT_URL and addon.env.HOME_ASSISTANT_TOKEN")
    }
    var trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
      url.host?.isEmpty == false, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
    else {
      throw AdapterExecutionError(.policyBlocked, "HOME_ASSISTANT_URL must be an http(s) base URL without credentials")
    }
    addonName = input.addon.name
    self.options = options
    context = config["context"]
    baseURL = url
    self.token = token
    timeout = Double(try HomeAssistantOptions.integer(options, "timeoutSeconds", default: 10, range: 1...120))
    http = resolver.mediaPipelineHTTP
    environment = resolver.environment
  }

  func send(method: String, path: String, body: JSONValue? = nil, deadline: Date?) async throws -> JSONValue {
    guard let url = URL(string: baseURL.absoluteString + path) else {
      throw AdapterExecutionError(.invalidInput, "\(addonName) could not build the request URL")
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    var effectiveTimeout = timeout
    if let deadline {
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { throw AdapterExecutionError(.timeout, "\(addonName) deadline elapsed") }
      effectiveTimeout = min(effectiveTimeout, remaining)
    }
    request.timeoutInterval = effectiveTimeout
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(body)
    }
    let response: MediaPipelineHTTPResponse
    do {
      response = try await http(request)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw AdapterExecutionError(
        .providerError, "\(addonName) could not reach Home Assistant: \(redacted(String(describing: error)))",
        isRetryable: true)
    }
    guard response.body.count <= Self.maxResponseBytes else {
      throw AdapterExecutionError(.providerError, "\(addonName) response exceeds \(Self.maxResponseBytes) bytes")
    }
    let decoded = try? JSONDecoder().decode(JSONValue.self, from: response.body)
    switch response.status {
    case 200..<300:
      guard let decoded else {
        throw AdapterExecutionError(.providerError, "\(addonName) received a non-JSON response (HTTP \(response.status))")
      }
      return decoded
    case 401, 403:
      throw AdapterExecutionError(
        .policyBlocked, "\(addonName) was rejected by Home Assistant (HTTP \(response.status)); check HOME_ASSISTANT_TOKEN")
    case 400, 404:
      throw AdapterExecutionError(
        .invalidInput, "\(addonName) \(method) \(path) failed with HTTP \(response.status)\(detail(decoded))")
    case 429, 500...599:
      throw AdapterExecutionError(
        .providerError, "\(addonName) \(method) \(path) failed with HTTP \(response.status)\(detail(decoded))",
        isRetryable: true,
        retryAfter: response.retryAfter.map { .milliseconds(Int64($0 * 1000)) })
    default:
      throw AdapterExecutionError(
        .providerError, "\(addonName) \(method) \(path) failed with HTTP \(response.status)\(detail(decoded))")
    }
  }

  func output(_ result: JSONObject, when: [String: Bool]) throws -> AdapterExecutionOutput {
    var payload: JSONObject = ["homeAssistant": .object(result)]
    if let context { payload["context"] = context }
    guard try JSONEncoder().encode(JSONValue.object(payload)).count <= Self.maxResponseBytes else {
      throw AdapterExecutionError(.invalidInput, "\(addonName) output exceeds 8 MB")
    }
    return AdapterExecutionOutput(
      provider: "riela-builtin-addon", model: addonName, promptText: "", completionPassed: true,
      when: when, payload: payload)
  }

  private func detail(_ decoded: JSONValue?) -> String {
    guard case let .object(object)? = decoded, case let .string(message)? = object["message"] else { return "" }
    return ": " + redacted(String(message.prefix(200)))
  }

  private func redacted(_ message: String) -> String {
    MediaPipelineRedaction.diagnostic(message.replacingOccurrences(of: token, with: "[REDACTED]"), environment: environment)
  }
}

struct HomeAssistantPolicy {
  static let maxStates = 500
  static let maxAllowlistEntries = 256
  /// Target keys HA resolves to entities indirectly; they would bypass an
  /// entity allowlist, so they are refused whenever one is configured.
  static let indirectTargetKeys = ["device_id", "area_id", "floor_id", "label_id"]

  let allowedServices: [String]
  let allowedEntities: [String]?

  init(rawOptions: JSONValue?) throws {
    guard case let .object(options)? = rawOptions else {
      throw AdapterExecutionError(.policyBlocked, "riela/home-assistant-write requires options.allowedServices")
    }
    guard case let .array(services)? = options["allowedServices"], !services.isEmpty,
      services.count <= Self.maxAllowlistEntries
    else {
      throw AdapterExecutionError(
        .policyBlocked, "riela/home-assistant-write requires a non-empty literal options.allowedServices array")
    }
    allowedServices = try services.map { value in
      guard case let .string(entry) = value, Self.isAllowlistEntry(entry) else {
        throw AdapterExecutionError(
          .policyBlocked, "options.allowedServices entries must be literal 'domain.service' or 'domain.*'")
      }
      return entry
    }
    switch options["allowedEntities"] {
    case nil:
      allowedEntities = nil
    case let .array(entities)? where !entities.isEmpty && entities.count <= Self.maxAllowlistEntries:
      allowedEntities = try entities.map { value in
        guard case let .string(entry) = value, Self.isAllowlistEntry(entry) else {
          throw AdapterExecutionError(
            .policyBlocked, "options.allowedEntities entries must be literal entity ids or 'domain.*'")
        }
        return entry
      }
    default:
      throw AdapterExecutionError(.policyBlocked, "options.allowedEntities must be a non-empty literal array")
    }
  }

  func authorize(domain: String, service: String, target: JSONObject, data: JSONObject) throws {
    guard Self.matches("\(domain).\(service)", allowedServices) else {
      throw AdapterExecutionError(.policyBlocked, "service '\(domain).\(service)' is not in options.allowedServices")
    }
    var entities: [String] = []
    for object in [target, data] {
      if let value = object["entity_id"] { entities += try Self.entityIds(value) }
    }
    for entity in entities {
      guard Self.isEntityId(entity) else {
        throw AdapterExecutionError(.policyBlocked, "entity_id '\(entity)' is not a concrete entity id")
      }
    }
    guard let allowedEntities else { return }
    for object in [target, data] {
      for key in Self.indirectTargetKeys where object[key] != nil {
        throw AdapterExecutionError(
          .policyBlocked, "\(key) cannot be used when options.allowedEntities is configured")
      }
    }
    guard !entities.isEmpty else {
      throw AdapterExecutionError(
        .policyBlocked, "an entity_id is required when options.allowedEntities is configured")
    }
    for entity in entities where !Self.matches(entity, allowedEntities) {
      throw AdapterExecutionError(.policyBlocked, "entity '\(entity)' is not in options.allowedEntities")
    }
  }

  static func entityIds(_ value: JSONValue) throws -> [String] {
    switch value {
    case let .string(raw):
      // HA accepts a comma-separated string; check every element.
      return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    case let .array(values):
      return try values.map { item in
        guard case let .string(id) = item else {
          throw AdapterExecutionError(.policyBlocked, "entity_id arrays must contain strings")
        }
        return id.trimmingCharacters(in: .whitespaces)
      }
    default:
      throw AdapterExecutionError(.policyBlocked, "entity_id must be a string or an array of strings")
    }
  }

  static func matches(_ value: String, _ allowlist: [String]) -> Bool {
    allowlist.contains { entry in
      entry.hasSuffix(".*") ? value.hasPrefix(String(entry.dropLast())) : entry == value
    }
  }

  static func isIdentifier(_ value: String) -> Bool {
    value.range(of: #"^[a-z0-9_]{1,64}$"#, options: .regularExpression) != nil
  }

  static func isEntityId(_ value: String) -> Bool {
    value.range(of: #"^[a-z0-9_]{1,64}\.[a-z0-9_]{1,255}$"#, options: .regularExpression) != nil
  }

  static func isAllowlistEntry(_ value: String) -> Bool {
    value.range(of: #"^[a-z0-9_]{1,64}\.([a-z0-9_]{1,255}|\*)$"#, options: .regularExpression) != nil
  }

  /// `state_<state>` with the state lowercased, non `[a-z0-9_]` replaced by
  /// `_`, truncated to 64 characters.
  static func stateLabel(_ state: String) -> String? {
    let sanitized = String(state.lowercased().unicodeScalars.prefix(64).map { scalar -> Character in
      switch scalar {
      case "a"..."z", "0"..."9", "_": return Character(scalar)
      default: return "_"
      }
    })
    return sanitized.isEmpty ? nil : "state_\(sanitized)"
  }
}

enum HomeAssistantOptions {
  static func invalid(_ message: String) -> AdapterExecutionError {
    AdapterExecutionError(.invalidInput, "home-assistant \(message)")
  }

  static func allowOnly(_ options: JSONObject, _ keys: Set<String>) throws {
    let unknown = Set(options.keys).subtracting(keys)
    guard unknown.isEmpty else { throw invalid("unknown option(s): \(unknown.sorted().joined(separator: ", "))") }
  }

  static func string(_ options: JSONObject, _ name: String) throws -> String? {
    switch options[name] {
    case nil, .null?: return nil
    case let .string(value)?:
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    default: throw invalid("options.\(name) must be a string")
    }
  }

  static func stringArray(_ options: JSONObject, _ name: String, max: Int) throws -> [String]? {
    switch options[name] {
    case nil, .null?: return nil
    case let .array(values)? where values.count <= max:
      return try values.map { value in
        guard case let .string(string) = value else { throw invalid("options.\(name) must contain strings") }
        return string
      }
    default: throw invalid("options.\(name) must be an array of at most \(max) strings")
    }
  }

  static func object(_ options: JSONObject, _ name: String) throws -> JSONObject {
    switch options[name] {
    case nil, .null?: return [:]
    case let .object(value)?: return value
    default: throw invalid("options.\(name) must be an object")
    }
  }

  static func integer(_ options: JSONObject, _ name: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
    let value: Int?
    switch options[name] {
    case nil: return fallback
    case let .integer(number)?: value = Int(exactly: number)
    case let .number(number)?: value = Int(exactly: number)
    default: value = nil
    }
    guard let value, range.contains(value) else {
      throw invalid("options.\(name) must be an integer in \(range.lowerBound)...\(range.upperBound)")
    }
    return value
  }
}
