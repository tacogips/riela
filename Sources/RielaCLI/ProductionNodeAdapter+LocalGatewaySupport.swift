import Foundation
import GatewaySDKKit
#if canImport(GmailGatewayCore)
import GmailGatewayCore
#endif
import RielaAddonSupport
import RielaCore

/// Runs one GraphQL document against the gateway library backing an add-on
/// tier and returns the JSON envelope that gateway's CLI would have printed on
/// stdout. The gateway runs inside the riela process; `environment` is the
/// only environment it can observe.
typealias LocalGatewayGraphQLRunner = @Sendable (
  _ tier: String,
  _ document: String,
  _ variablesJSON: String?,
  _ environment: [String: String]
) async throws -> String

/// Static description of one local gateway tier.
///
/// The tier is pinned per add-on, so a workflow cannot widen it through inputs
/// or payload data. The gateways are linked as libraries rather than launched
/// as executables, so the boundary is the role and capability list this
/// descriptor hands the gateway's own capability registry — which refuses a
/// document naming a capability outside the tier — instead of which binary was
/// on `PATH`.
struct LocalGatewayGraphQLDescriptor {
  var providerName: String
  var payloadNamespaceKey: String
  /// Reported in the add-on payload so a run records which tier answered.
  var tier: String
  /// Whether the legacy document mode accepts variablesTemplate. Gmail keeps
  /// its CLI-compatible restriction; its SDK operation mode accepts variables.
  var acceptsVariables: Bool
  /// addon.env may only populate target names this predicate accepts, so the
  /// binding mechanism cannot inject arbitrary variables into the gateway.
  var isAllowedEnvironmentTarget: (String) -> Bool
  var catalog: (() throws -> GatewaySchemaCatalog)?
  /// Optional provider-owned, normalized operational observations, separate from selected source data.
  var observationMetadata: ((String) -> JSONObject)?
  var run: LocalGatewayGraphQLRunner
}

/// Shared engine for built-in add-ons that call a sibling gateway package's
/// GraphQL runtime and read its JSON envelope.
struct LocalGatewayGraphQLEngine {
  var environment: [String: String]
  var descriptor: LocalGatewayGraphQLDescriptor
  var workingDirectory: URL

  init(
    environment: [String: String],
    descriptor: LocalGatewayGraphQLDescriptor,
    runnerOverride: LocalGatewayGraphQLRunner? = nil,
    workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
  ) {
    self.environment = environment
    self.descriptor = descriptor
    self.workingDirectory = workingDirectory
    if let runnerOverride {
      self.descriptor.run = runnerOverride
    }
  }

  func execute(
    _ input: WorkflowAddonExecutionInput,
    context: AdapterExecutionContext,
    documentOverride: String? = nil
  ) async throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }
    let config = input.addon.config ?? [:]
    let nowVariables = try localGatewayNowVariables(config: config, addonName: input.addon.name)
      .mapValues(JSONValue.string)
    let variables = try addonVariables(for: input, additionalVariables: nowVariables)
    var childEnvironment = try resolvedChildEnvironment(input)
    if descriptor.providerName == "notion-gateway", descriptor.tier == "writer",
       config["operation"] == .string("uploadLocalFile") {
      return try await executeNotionLocalFileUpload(
        input: input, config: config, runner: descriptor.run, variables: variables,
        childEnvironment: childEnvironment, runtimeEnvironment: environment, workingDirectory: workingDirectory, context: context
      )
    }
    if descriptor.providerName == "gmail-gateway" {
      childEnvironment.merge(try gatewayWriteRetryEnvironment(input, prefix: "GMAIL_GATEWAY_")) { _, configured in configured }
    }
    let document: String
    let variablesJSON: String?
    if config["operation"] != nil && documentOverride == nil {
      guard let catalog = descriptor.catalog else {
        throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) does not support JSON operations")
      }
      let built = try BuiltinGatewayJSONRequest.document(
        config: config, variables: variables, catalog: catalog(), addonName: input.addon.name
      )
      document = built.document
      variablesJSON = String(bytes: try JSONEncoder().encode(built.variables), encoding: .utf8)
    } else {
      document = try documentOverride ?? renderedDocument(config: config, variables: variables, addonName: input.addon.name)
      if descriptor.acceptsVariables {
        variablesJSON = try renderedVariablesJSON(config: config, variables: variables, addonName: input.addon.name)
      } else {
        guard config["variablesTemplate"] == nil else {
          throw AdapterExecutionError(
            .policyBlocked,
            "\(input.addon.name) config.variablesTemplate is not supported; use config.operation with config.arguments"
          )
        }
        variablesJSON = nil
      }
    }
    let gatewayEnvironment = sanitizedGatewayEnvironment(
      runtimeEnvironment: environment,
      bindings: childEnvironment
    )
    let run = descriptor.run
    let tier = descriptor.tier
    let providerName = descriptor.providerName
    let stdout = try await localGatewayRunWithDeadline(
      deadline: context.deadline,
      addonName: input.addon.name,
      providerName: descriptor.providerName
    ) {
      #if canImport(GmailGatewayCore)
      if providerName == "gmail-gateway" {
        return try await GmailWriteExecutionContext.withDeadline(context.deadline) {
          try await run(tier, document, variablesJSON, gatewayEnvironment)
        }
      }
      #endif
      return try await run(tier, document, variablesJSON, gatewayEnvironment)
    }
    let envelope = try envelope(from: stdout, addonName: input.addon.name)
    guard envelope.errors.isEmpty else {
      let detail = appleGatewayCompactText(envelope.errors.joined(separator: "; "))
      throw AdapterExecutionError(.providerError, "\(input.addon.name) GraphQL errors: \(detail)")
    }
    var payloadRoot: JSONObject = ["data": .object(envelope.data)]
    if let selected = try localGatewaySelectedValue(
      config: config,
      variables: variables,
      payloadRoot: payloadRoot,
      addonName: input.addon.name
    ) {
      payloadRoot["selected"] = selected
    }
    let when = try localGatewayWhenFlags(config: config, payloadRoot: payloadRoot, addonName: input.addon.name)
    var payload: JSONObject = [
      "status": .string("ok"),
      "addon": .string(input.addon.name),
      "stepId": .string(input.stepId),
      "data": .object(envelope.data),
      "requestId": .string(envelope.requestId ?? ""),
      "replyText": .string("\(descriptor.providerName) \(descriptor.tier) query succeeded."),
      descriptor.payloadNamespaceKey: .object([
        // The gateway is linked into this process, so there is no resolved
        // binary to report; the tier that answered is the useful fact.
        "runtime": .object([
          "mode": .string("in-process"),
          "tier": .string(descriptor.tier)
        ]),
        "requestId": .string(envelope.requestId ?? "")
      ])
    ]
    if let observations = descriptor.observationMetadata?(stdout), !observations.isEmpty,
       case var .object(namespace)? = payload[descriptor.payloadNamespaceKey] {
      namespace["observations"] = .object(observations)
      payload[descriptor.payloadNamespaceKey] = .object(namespace)
    }
    if let selected = payloadRoot["selected"] {
      payload["selected"] = selected
    }
    for (key, value) in try localGatewayPayloadExtras(config: config, variables: variables, addonName: input.addon.name) {
      payload[key] = value
    }
    return AdapterExecutionOutput(
      provider: descriptor.providerName,
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      when: when,
      payload: payload
    )
  }

  private func resolvedChildEnvironment(_ input: WorkflowAddonExecutionInput) throws -> [String: String] {
    if let env = input.addon.env {
      for targetName in env.keys where !descriptor.isAllowedEnvironmentTarget(targetName) {
        throw AdapterExecutionError(
          .policyBlocked,
          "\(input.addon.name) addon.env target '\(targetName)' is not a \(descriptor.providerName) environment variable"
        )
      }
    }
    return try resolveAddonEnvironment(input.addon.env, runtimeEnvironment: environment)
  }

  private func renderedDocument(config: JSONObject, variables: JSONObject, addonName: String) throws -> String {
    guard let template = nonEmptyString(config["queryTemplate"]) else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.queryTemplate is required")
    }
    let document = renderPromptTemplate(template, variables: variables).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !document.isEmpty else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.queryTemplate rendered to an empty document")
    }
    return document
  }

  private func renderedVariablesJSON(
    config: JSONObject,
    variables: JSONObject,
    addonName: String
  ) throws -> String? {
    guard let value = config["variablesTemplate"] else {
      return nil
    }
    guard case let .object(template) = value else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.variablesTemplate must be an object")
    }
    let rendered = try template.mapValues { try renderAddonConfig($0, variables: variables) }
    do {
      return try JSONValue.object(rendered).compactJSONString()
    } catch {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.variablesTemplate failed to encode: \(error.localizedDescription)")
    }
  }

  private func envelope(
    from stdout: String,
    addonName: String
  ) throws -> AppleGatewayGraphQLEnvelope {
    try AppleGatewayGraphQLEnvelope(stdout: stdout, addonName: addonName)
  }
}

private func executeNotionLocalFileUpload(
  input: WorkflowAddonExecutionInput,
  config: JSONObject,
  runner: @escaping LocalGatewayGraphQLRunner,
  variables: JSONObject,
  childEnvironment: [String: String],
  runtimeEnvironment: [String: String],
  workingDirectory: URL,
  context: AdapterExecutionContext
) async throws -> AdapterExecutionOutput {
  let addonName = input.addon.name
  guard config["queryTemplate"] == nil, config["variablesTemplate"] == nil, config["selection"] == nil,
        config["select"] == nil, config["command"] == nil, config["argsTemplate"] == nil else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) uploadLocalFile cannot be mixed with a GraphQL document or selection")
  }
  let arguments = try BuiltinGatewayJSONRequest.renderedArguments(config: config, variables: variables, addonName: addonName)
  let supportedArguments: Set<String> = ["path", "filename", "contentType", "kind", "caption"]
  guard arguments.keys.allSatisfy(supportedArguments.contains) else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) uploadLocalFile contains an unsupported argument")
  }
  for key in supportedArguments where arguments[key] != nil {
    guard case .string? = arguments[key] else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) uploadLocalFile argument \(key) must be a string")
    }
  }
  guard let path = nonEmptyString(arguments["path"]) else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) uploadLocalFile requires arguments.path")
  }
  let root = workingDirectory.standardizedFileURL
  let resolved = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
  var permittedRoots = [root.resolvingSymlinksInPath().standardizedFileURL]
  if let artifactPath = runtimeEnvironment["RIELA_ARTIFACT_DIR"], !artifactPath.isEmpty {
    permittedRoots.append(URL(fileURLWithPath: artifactPath, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL)
  }
  guard permittedRoots.contains(where: { resolved.path == $0.path || resolved.path.hasPrefix($0.path + "/") }) else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) uploadLocalFile path is outside the working and artifact directories")
  }
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), !isDirectory.boolValue,
        let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
        let size = attributes[.size] as? NSNumber else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) uploadLocalFile path must be an existing file")
  }
  let sizeBytes = size.int64Value
  guard sizeBytes <= 20 * 1_024 * 1_024 else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) uploadLocalFile file exceeds 20 MiB")
  }
  let data: Data
  do { data = try Data(contentsOf: resolved) } catch {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) uploadLocalFile file could not be read")
  }
  let filename = nonEmptyString(arguments["filename"]) ?? resolved.lastPathComponent
  let contentType = nonEmptyString(arguments["contentType"]) ?? notionUploadContentType(filename: filename)
  let kind = nonEmptyString(arguments["kind"]) ?? (contentType.lowercased().hasPrefix("image/") ? "image" : "file")
  guard kind == "image" || kind == "file" else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) uploadLocalFile kind must be image or file")
  }
  guard kind != "image" || contentType.lowercased().hasPrefix("image/") else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) image upload requires an image contentType")
  }
  let createField = kind == "image" ? "createFileUpload" : "createAttachmentUpload"
  let sendField = kind == "image" ? "sendFileUpload" : "sendAttachmentUpload"
  let createDocument = "mutation($filename:String!,$contentType:String!){\(createField)(filename:$filename,contentType:$contentType){id}}"
  let createVariables = try notionUploadVariables(["filename": .string(filename), "contentType": .string(contentType)])
  let gatewayEnvironment = sanitizedGatewayEnvironment(runtimeEnvironment: runtimeEnvironment, bindings: childEnvironment)
  let created = try await notionUploadCall(runner: runner, document: createDocument, variables: createVariables,
    environment: gatewayEnvironment, context: context, addonName: addonName)
  let createdField = try created.mutationField(createField, addonName: addonName)
  guard let uploadId = nonEmptyString(createdField["id"]) else {
    throw AdapterExecutionError(.invalidOutput, "\(addonName) upload create response is missing an id")
  }
  let sendDocument = "mutation($id:ID!,$filename:String!,$contentType:String!,$dataBase64:String!){\(sendField)(id:$id,filename:$filename,contentType:$contentType,dataBase64:$dataBase64){id status}}"
  let sendVariables = try notionUploadVariables([
    "id": .string(uploadId), "filename": .string(filename), "contentType": .string(contentType),
    "dataBase64": .string(data.base64EncodedString())
  ])
  let sent = try await notionUploadCall(runner: runner, document: sendDocument, variables: sendVariables,
    environment: gatewayEnvironment, context: context, addonName: addonName)
  let sentField = try sent.mutationField(sendField, addonName: addonName)
  guard let uploadStatus = nonEmptyString(sentField["status"]) else {
    throw AdapterExecutionError(.invalidOutput, "\(addonName) upload send response is missing a status")
  }
  let caption = nonEmptyString(arguments["caption"]).map { [
    JSONValue.object(["type": .string("text"), "text": .object(["content": .string($0)])])
  ] } ?? []
  let blockType = kind == "image" ? "image" : "file"
  let inner: JSONObject = ["type": .string("file_upload"), "file_upload": .object(["id": .string(uploadId)])]
  var blockBody: JSONObject = ["type": .string(blockType), blockType: .object(inner)]
  if !caption.isEmpty { blockBody[blockType] = .object(inner.merging(["caption": .array(caption)]) { _, rhs in rhs }) }
  let block = JSONValue.object(["object": .string("block")].merging(blockBody) { _, rhs in rhs })
  let payload: JSONObject = [
    "status": .string("ok"), "addon": .string(addonName), "stepId": .string(input.stepId),
    "data": .object([sendField: .object(sentField)]), "requestId": .string(sent.requestId ?? ""),
    "replyText": .string("notion-gateway writer upload succeeded."),
    "block": block,
    "notionGateway": .object([
      "runtime": .object(["mode": .string("in-process"), "tier": .string("writer")]),
      "requestId": .string(sent.requestId ?? ""), "fileUploadId": .string(uploadId),
      "filename": .string(filename), "contentType": .string(contentType), "sizeBytes": .integer(sizeBytes),
      "status": .string(uploadStatus), "block": block
    ])
  ]
  return AdapterExecutionOutput(provider: "notion-gateway", model: addonName, promptText: "", completionPassed: true,
    when: ["success": true], payload: payload)
}

private func notionUploadVariables(_ variables: JSONObject) throws -> String {
  let data = try JSONEncoder().encode(JSONValue.object(variables))
  guard let string = String(data: data, encoding: .utf8) else {
    throw AdapterExecutionError(.invalidOutput, "notion-gateway upload variables could not be encoded")
  }
  return string
}

private func notionUploadCall(
  runner: @escaping LocalGatewayGraphQLRunner, document: String, variables: String, environment: [String: String],
  context: AdapterExecutionContext, addonName: String
) async throws -> AppleGatewayGraphQLEnvelope {
  let stdout = try await localGatewayRunWithDeadline(deadline: context.deadline, addonName: addonName, providerName: "notion-gateway") {
    try await runner("writer", document, variables, environment)
  }
  let envelope = try AppleGatewayGraphQLEnvelope(stdout: stdout, addonName: addonName)
  guard envelope.errors.isEmpty else {
    throw AdapterExecutionError(.providerError, "\(addonName) GraphQL errors: \(appleGatewayCompactText(envelope.errors.joined(separator: "; ")))")
  }
  return envelope
}

private func notionUploadContentType(filename: String) -> String {
  switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
  case "jpg", "jpeg": "image/jpeg"
  case "png": "image/png"
  case "gif": "image/gif"
  case "webp": "image/webp"
  default: "application/octet-stream"
  }
}

/// Applies the step deadline to an in-process gateway call. A linked gateway
/// has no process to terminate, so the call is cancelled and the same timeout
/// error a spawned gateway would have produced is raised. The task group waits
/// for the cancelled operation, so an operation that blocks a thread must be
/// cancellation-aware (see `xGatewayRunOffCooperativePool`).
func localGatewayRunWithDeadline(
  deadline: Date?,
  addonName: String,
  providerName: String,
  operation: @escaping @Sendable () async throws -> String
) async throws -> String {
  guard let deadline else { return try await operation() }
  let remaining = deadline.timeIntervalSinceNow
  guard remaining > 0 else {
    throw AdapterExecutionError(.timeout, "\(addonName) exceeded its deadline before \(providerName) was called")
  }
  return try await withThrowingTaskGroup(of: String.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: .seconds(remaining))
      throw AdapterExecutionError(.timeout, "\(addonName) exceeded its deadline while calling \(providerName)")
    }
    defer { group.cancelAll() }
    guard let first = try await group.next() else {
      throw AdapterExecutionError(.invalidOutput, "\(addonName) produced no \(providerName) response")
    }
    return first
  }
}

func localGatewayNowVariables(config: JSONObject, addonName: String) throws -> [String: String] {
  guard let value = config["nowVariables"] else {
    return [:]
  }
  guard case let .object(offsets) = value else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) config.nowVariables must be an object")
  }
  let now = Date()
  var resolved: [String: String] = [:]
  for (name, offsetValue) in offsets {
    guard let offsetSeconds = intValue(offsetValue) else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.nowVariables.\(name) must be an integer second offset")
    }
    resolved[name] = localGatewayInstantString(now.addingTimeInterval(TimeInterval(offsetSeconds)))
  }
  return resolved
}

func localGatewaySelectedValue(
  config: JSONObject,
  variables: JSONObject,
  payloadRoot: JSONObject,
  addonName: String
) throws -> JSONValue? {
  guard let value = config["selectFirst"] else {
    return nil
  }
  guard case let .object(selector) = value else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) config.selectFirst must be an object")
  }
  guard let path = nonEmptyString(selector["path"]) else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) config.selectFirst.path is required")
  }
  guard case let .array(candidates)? = localGatewayLookupPath(path, in: payloadRoot) else {
    throw AdapterExecutionError(.invalidOutput, "\(addonName) config.selectFirst.path '\(path)' did not resolve to an array")
  }
  var conditions: JSONObject = [:]
  if let whereValue = selector["where"] {
    guard case let .object(rendered) = try renderAddonConfig(whereValue, variables: variables) else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.selectFirst.where must be an object")
    }
    conditions = rendered
  }
  let position = nonEmptyString(selector["position"]) ?? "first"
  guard position == "first" || position == "last" else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) config.selectFirst.position must be 'first' or 'last'")
  }
  let ordered: [JSONValue] = position == "last" ? candidates.reversed() : candidates
  let match = ordered.first { candidate in
    guard case let .object(entry) = candidate else {
      return false
    }
    return conditions.allSatisfy { key, expected in
      localGatewayConditionMatches(entry[key], expected)
    }
  }
  return match ?? JSONValue.null
}

func localGatewayWhenFlags(
  config: JSONObject,
  payloadRoot: JSONObject,
  addonName: String
) throws -> [String: Bool] {
  var flags: [String: Bool] = ["always": true, "ok": true]
  guard let value = config["whenFlags"] else {
    return flags
  }
  guard case let .object(flagPaths) = value else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) config.whenFlags must be an object")
  }
  for (flagName, pathValue) in flagPaths {
    guard case let .string(path) = pathValue, !path.isEmpty else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.whenFlags.\(flagName) must be a non-empty path string")
    }
    flags[flagName] = localGatewayTruthy(localGatewayLookupPath(path, in: payloadRoot))
  }
  return flags
}

func localGatewayPayloadExtras(
  config: JSONObject,
  variables: JSONObject,
  addonName: String
) throws -> JSONObject {
  guard let value = config["payloadExtras"] else {
    return [:]
  }
  guard case let .object(template) = value else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) config.payloadExtras must be an object")
  }
  return try template.mapValues { try renderAddonConfig($0, variables: variables) }
}

/// Dot-path lookup over a JSON object that also understands numeric array
/// indexes, so paths like `data.tasks.nodes.0.id` address the first node.
func localGatewayLookupPath(_ path: String, in root: JSONObject) -> JSONValue? {
  let keys = path.split(separator: ".").map(String.init).filter { !$0.isEmpty }
  guard !keys.isEmpty else {
    return nil
  }
  var current: JSONValue? = .object(root)
  for key in keys {
    switch current {
    case let .object(object):
      current = object[key]
    case let .array(values):
      guard let index = Int(key), values.indices.contains(index) else {
        return nil
      }
      current = values[index]
    default:
      return nil
    }
  }
  return current
}

func localGatewayTruthy(_ value: JSONValue?) -> Bool {
  switch value {
  case nil, .null:
    return false
  case let .bool(flag):
    return flag
  case let .string(text):
    return !text.isEmpty
  case let .integer(number):
    return number != 0
  case let .number(number):
    return number != 0
  case let .array(values):
    return !values.isEmpty
  case let .object(object):
    return !object.isEmpty
  }
}

private func localGatewayValuesMatch(_ actual: JSONValue?, _ expected: JSONValue) -> Bool {
  guard let actual else {
    return expected == .null
  }
  if actual == expected {
    return true
  }
  if case let .string(expectedText) = expected, case let .integer(number) = actual {
    return String(number) == expectedText
  }
  return false
}

/// A where condition is either a plain value (equality) or an operator object
/// combining `contains`, `notContains`, and `ne`, all of which must hold.
private func localGatewayConditionMatches(_ actual: JSONValue?, _ condition: JSONValue) -> Bool {
  guard case let .object(operators) = condition,
        !operators.isEmpty,
        operators.keys.allSatisfy({ ["contains", "notContains", "ne"].contains($0) }) else {
    return localGatewayValuesMatch(actual, condition)
  }
  for (name, operand) in operators {
    switch name {
    case "contains", "notContains":
      guard case let .string(needle) = operand, case let .string(haystack)? = actual else {
        return false
      }
      let contains = haystack.contains(needle)
      if (name == "contains") != contains {
        return false
      }
    case "ne":
      if localGatewayValuesMatch(actual, operand) {
        return false
      }
    default:
      return false
    }
  }
  return true
}

private func localGatewayInstantString(_ date: Date) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.string(from: date)
}
