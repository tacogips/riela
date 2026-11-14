import Foundation
import RielaAddonSupport
import RielaCore

extension BuiltinWorkflowAddonResolver {
  static let publicWebRegistration = BuiltinAddonHandlerRegistration(name: "riela/public-web", bindsCLIVariablesAsInputs: false) { resolver, input, context in
    try await resolver.executePublicWeb(input, context: context)
  }

  func executePublicWeb(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1",
      case let .object(config) = try renderAddonConfig(.object(input.addon.config ?? [:]), variables: addonVariables(for: input)),
      Set(config.keys).isSubset(of: ["action", "url", "options", "blockedHosts", "metadataOnly", "includeRaw", "linkPattern", "headers", "maximumBytes", "timeoutMs", "bodyBase64", "allowedURLPattern", "failureMode"]),
      let url = nonEmptyString(config["url"]), try JSONEncoder().encode(config).count <= 4_000_000 else { throw publicWebInvalid() }
    func boolean(_ key: String) throws -> Bool {
      guard let value = config[key] else { return false }; guard case let .bool(value) = value else { throw publicWebInvalid() }; return value
    }
    func integer(_ raw: JSONValue?, fallback: Int, range: ClosedRange<Int>) throws -> Int {
      guard let raw else { return fallback }
      guard case let .integer(value) = raw, let result = Int(exactly: value), range.contains(result) else { throw publicWebInvalid() }; return result
    }
    let action = try publicWebString(config["action"], fallback: "page")
    let actionFields: Set<String>
    switch action {
    case "page": actionFields = ["options", "metadataOnly", "includeRaw", "linkPattern"]
    case "response": actionFields = ["headers", "maximumBytes", "timeoutMs", "allowedURLPattern", "failureMode"]
    case "parse": actionFields = ["options", "metadataOnly", "bodyBase64"]
    default: throw publicWebInvalid()
    }
    guard Set(config.keys).subtracting(["action", "url", "blockedHosts"]).isSubset(of: actionFields) else { throw publicWebInvalid() }
    let blocked = try config["blockedHosts"].map { try JSONDecoder().decode([String].self, from: JSONEncoder().encode($0)) } ?? []
    let failureMode = try publicWebString(config["failureMode"], fallback: "throw")
    guard ["throw", "result"].contains(failureMode) else { throw publicWebInvalid() }
    let allowedURLPattern = try config["allowedURLPattern"].map { try publicWebString($0) }
    do { _ = try PublicWebHTTP.urlPattern(allowedURLPattern) } catch { throw publicWebInvalid() }
    let rawOptions: JSONObject
    switch config["options"] {
    case nil: rawOptions = [:]
    case let .object(value)?: rawOptions = value
    default: throw publicWebInvalid()
    }
    guard Set(rawOptions.keys).isSubset(of: ["mode", "minTextChars", "waitMs", "timeoutMs", "maxTextChars"]) else { throw publicWebInvalid() }
    var options = PublicWebPageOptions()
    options.mode = try publicWebString(rawOptions["mode"], fallback: "auto")
    guard ["auto", "http", "browser"].contains(options.mode) else { throw publicWebInvalid() }
    options.minimumTextCharacters = try integer(rawOptions["minTextChars"], fallback: 400, range: 0...20_000)
    options.waitMs = try integer(rawOptions["waitMs"], fallback: 1500, range: 0...5000)
    options.timeoutMs = try integer(rawOptions["timeoutMs"], fallback: 20_000, range: 1000...30_000)
    options.maximumTextCharacters = try integer(rawOptions["maxTextChars"], fallback: 20_000, range: 1...50_000)
    let transport = PublicWebExecutionContext.transport ?? PublicWebHTTP.native
    var payload: JSONObject
    do {
      _ = try PublicWebHTTP.destination(url, blockedHosts: blocked)
      switch action {
      case "page":
        let browser = PublicWebExecutionContext.browser ?? { url, options, blocked, deadline in
          try await self.publicWebBrowser(url: url, options: options, blockedHosts: blocked, deadline: deadline)
        }
        let pattern = try config["linkPattern"].map { try publicWebString($0) }
        payload = try await PublicWebReader(transport: transport, browser: browser).page(url: url, options: options,
          blockedHosts: blocked, metadataOnly: boolean("metadataOnly"), includeRaw: boolean("includeRaw"), linkPattern: pattern, deadline: context.deadline)
      case "response":
        let headers = try config["headers"].map { try JSONDecoder().decode([String: String].self, from: JSONEncoder().encode($0)) } ?? [:]
        let response = try await PublicWebHTTP.read(url, headers: headers, blockedHosts: blocked,
          maximumBytes: integer(config["maximumBytes"], fallback: 2_000_000, range: 1...5_000_000),
          timeoutMs: integer(config["timeoutMs"], fallback: 25_000, range: 1...120_000), deadline: context.deadline,
          allowedURLPattern: allowedURLPattern, transport: transport)
        payload = ["url": .string(response.url), "status": .integer(Int64(response.status)),
          "headers": .object(response.headers.mapValues(JSONValue.string)), "bodyBase64": .string(response.body.base64EncodedString()),
          "notModified": .bool(response.status == 304)]
      case "parse":
        guard let raw = nonEmptyString(config["bodyBase64"]), let body = Data(base64Encoded: raw), body.count <= 2_000_000 else { throw publicWebInvalid() }
        payload = try PublicWebDocument.parse(body, url: url, options: options, metadataOnly: boolean("metadataOnly")).payload()
      default: throw publicWebInvalid()
      }
    } catch is CancellationError { throw CancellationError() } catch {
      try Task.checkCancellation()
      let reason = publicWebFailureReason(error)
      if failureMode == "result" { payload = ["ok": .bool(false), "failure": .string(reason)]
      } else { throw AdapterExecutionError(.providerError, "public-web failed: \(reason)") }
    }
    try Task.checkCancellation()
    if failureMode == "result", payload["ok"] == nil { payload["ok"] = .bool(true) }
    if try JSONEncoder().encode(payload).count > (action == "response" ? 7_000_000 : 4_000_000) {
      guard failureMode == "result" else { throw publicWebInvalid() }
      payload = ["ok": .bool(false), "failure": .string("response-budget")]
    }
    return .init(provider: "riela-builtin-addon", model: input.addon.name, promptText: "", completionPassed: true, payload: payload)
  }
}

private func publicWebString(_ value: JSONValue?, fallback: String? = nil) throws -> String {
  if value == nil, let fallback { return fallback }
  guard let result = nonEmptyString(value) else { throw publicWebInvalid() }; return result
}

private func publicWebInvalid() -> AdapterExecutionError { .init(.invalidInput, "invalid public-web configuration") }

private func publicWebFailureReason(_ error: Error) -> String {
  switch error {
  case PublicWebError.blockedDestination: return "blocked-destination"
  case PublicWebError.urlPolicy: return "url-policy"
  case PublicWebError.oversized: return "response-budget"
  case PublicWebError.timeout: return "deadline"
  case PublicWebError.httpStatus(let status) where (100...599).contains(status): return "http-\(status)"
  case PublicWebError.invalidInput, PublicWebError.invalidDocument: return "invalid-input-or-document"
  default: return "transport-or-browser"
  }
}
