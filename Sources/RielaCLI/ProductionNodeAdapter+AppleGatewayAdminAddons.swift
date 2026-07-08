import Foundation
import RielaCore

enum BuiltinAppleGatewayAdminAddon: String, CaseIterable {
  case graphql = "riela/apple-gateway-graphql"
  case schema = "riela/apple-gateway-schema"
  case permissionsStatus = "riela/apple-gateway-permissions-status"
  case permissionsRequest = "riela/apple-gateway-permissions-request"
  case configValidate = "riela/apple-gateway-config-validate"
  case fileDownload = "riela/apple-gateway-file-download"
  case cachePrune = "riela/apple-gateway-cache-prune"
}

extension BuiltinWorkflowAddonResolver {
  func executeAppleGatewayAdmin(
    _ input: WorkflowAddonExecutionInput,
    operation: BuiltinAppleGatewayAdminAddon,
    context: AdapterExecutionContext
  ) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }
    guard input.addon.env?.isEmpty != false else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) does not support addon.env")
    }

    let adminContext = AppleGatewayAdminContext(
      input: input,
      currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    )
    let resolvedBinary = try AppleGatewayBinaryResolver(
      addonName: input.addon.name,
      config: input.addon.config ?? [:],
      environment: environment
    ).resolvedBinary()
    let output = try AppleGatewayProcessRunner(runtimeEnvironment: environment).run(
      executablePath: resolvedBinary.path,
      arguments: try adminContext.arguments(for: operation),
      deadline: context.deadline
    )
    return try adminContext.adapterOutput(
      operation: operation,
      resolvedBinary: resolvedBinary,
      processOutput: output
    )
  }
}

private struct AppleGatewayAdminContext {
  private static let allowedSchemaRoles = Set(["full", "reader"])
  private static let allowedPermissionDomains = Set(["calendar", "reminders", "notes", "notifications"])

  var input: WorkflowAddonExecutionInput
  var config: JSONObject
  var baseVariables: JSONObject
  var renderedInputs: JSONObject
  var variables: JSONObject
  var currentDirectory: URL

  init(input: WorkflowAddonExecutionInput, currentDirectory: URL) {
    self.input = input
    self.currentDirectory = currentDirectory
    self.config = input.addon.config ?? [:]
    var base = input.variables
    for (key, value) in input.resolvedInputPayload {
      base[key] = value
    }
    base["input"] = .object(input.resolvedInputPayload)
    base["workflowId"] = .string(input.workflowId)
    base["stepId"] = .string(input.stepId)
    base["nodeId"] = .string(input.nodeId)
    base["addonName"] = .string(input.addon.name)
    self.baseVariables = base
    let inputs = renderAddonInputs(input.addon.inputs, variables: base)
    self.renderedInputs = inputs
    for (key, value) in inputs {
      base[key] = value
    }
    self.variables = base
  }

  func arguments(for operation: BuiltinAppleGatewayAdminAddon) throws -> [String] {
    switch operation {
    case .graphql:
      return try graphqlArguments()
    case .schema:
      return try schemaArguments()
    case .permissionsStatus:
      return ["permissions", "status", "--json"]
    case .permissionsRequest:
      return try permissionsRequestArguments()
    case .configValidate:
      return configValidateArguments()
    case .fileDownload:
      return try fileDownloadArguments()
    case .cachePrune:
      return try cachePruneArguments()
    }
  }

  func adapterOutput(
    operation: BuiltinAppleGatewayAdminAddon,
    resolvedBinary: AppleGatewayResolvedBinary,
    processOutput: AppleGatewayProcessOutput
  ) throws -> AdapterExecutionOutput {
    var appleGateway = baseAppleGatewayPayload(resolvedBinary)
    var payload: JSONObject = [
      "status": .string("ok"),
      "addon": .string(input.addon.name),
      "stepId": .string(input.stepId)
    ]

    switch operation {
    case .graphql:
      let envelope = try AppleGatewayGraphQLEnvelope(stdout: processOutput.stdout, addonName: input.addon.name)
      if !envelope.errors.isEmpty {
        throw AdapterExecutionError(
          .providerError,
          "\(input.addon.name) GraphQL errors: \(appleGatewayCompactText(envelope.errors.joined(separator: "; ")))"
        )
      }
      appleGateway["data"] = .object(envelope.data)
      appleGateway["extensions"] = .object(envelope.extensions)
      appleGateway["requestId"] = .string(envelope.requestId ?? "")
      payload["replyText"] = .string("Apple Gateway GraphQL query completed.")
    case .schema:
      let schemaSDL = processOutput.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !schemaSDL.isEmpty else {
        throw AdapterExecutionError(.invalidOutput, "\(input.addon.name) schema stdout was empty")
      }
      appleGateway["role"] = .string(try schemaRole() ?? "default")
      appleGateway["schemaSDL"] = .string(schemaSDL)
      appleGateway["byteCount"] = .integer(Int64(processOutput.stdout.utf8.count))
      payload["replyText"] = .string("Printed Apple Gateway schema.")
    case .permissionsStatus:
      appleGateway["permissions"] = .object(try requiredJSONObject(from: processOutput.stdout, label: "permissions status"))
      payload["replyText"] = .string("Read Apple Gateway permission status.")
    case .permissionsRequest:
      appleGateway["domain"] = .string(try requiredPermissionDomain())
      appleGateway["result"] = decodedJSONOrText(processOutput.stdout)
      payload["replyText"] = .string("Requested Apple Gateway permissions.")
    case .configValidate:
      appleGateway["valid"] = .bool(true)
      if let configPath = configPath() {
        appleGateway["configPath"] = .string(configPath)
      }
      appleGateway["output"] = .string(appleGatewayCompactText(processOutput.stdout))
      payload["replyText"] = .string("Validated Apple Gateway config.")
    case .fileDownload:
      appleGateway["keys"] = .array(try fileDownloadKeys().map(JSONValue.string))
      if let outputDir = stringValue("outputDir") {
        appleGateway["outputDir"] = .string(outputDir)
      }
      appleGateway["result"] = decodedJSONOrText(processOutput.stdout)
      payload["replyText"] = .string("Downloaded Apple Gateway file content.")
    case .cachePrune:
      appleGateway["all"] = .bool(try boolValueForKey("all", defaultValue: false))
      appleGateway["result"] = decodedJSONOrText(processOutput.stdout)
      payload["replyText"] = .string("Pruned Apple Gateway cache.")
    }

    payload["appleGateway"] = .object(appleGateway)
    return AdapterExecutionOutput(
      provider: "apple-gateway",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      when: ["always": true],
      payload: payload
    )
  }

  private func graphqlArguments() throws -> [String] {
    var arguments: [String] = []
    if let configPath = configPath() {
      arguments += ["--config", configPath]
    }
    arguments.append("graphql")
    if let queryFile = stringValue("queryFile") {
      arguments += ["--query-file", queryFile]
    } else if let query = stringValue("query") {
      arguments += ["--query", query]
    } else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) requires query or queryFile")
    }
    if let variablesFile = stringValue("variablesFile") {
      arguments += ["--variables-file", variablesFile]
    } else if let variables = try variablesArgument() {
      arguments += ["--variables", variables]
    }
    return arguments
  }

  private func schemaArguments() throws -> [String] {
    var arguments = ["schema", "print"]
    if let role = try schemaRole() {
      arguments += ["--role", role]
    }
    return arguments
  }

  private func permissionsRequestArguments() throws -> [String] {
    ["permissions", "request", "--domain", try requiredPermissionDomain()]
  }

  private func configValidateArguments() -> [String] {
    var arguments = ["config", "validate"]
    if let configPath = configPath() {
      arguments += ["--config", configPath]
    }
    return arguments
  }

  private func fileDownloadArguments() throws -> [String] {
    var arguments = ["file", "download"]
    for key in try fileDownloadKeys() {
      arguments += ["--key", key]
    }
    if let outputDir = stringValue("outputDir") {
      let validator = AppleGatewayFileDownloader(
        runner: AppleGatewayProcessRunner(runtimeEnvironment: [:]),
        resolvedBinary: AppleGatewayResolvedBinary(path: "", source: .config),
        currentDirectory: currentDirectory
      )
      let validatedOutputDir = try validator.validatedOutputRootPath(outputDir, label: "outputDir")
      arguments += ["--output-dir", validatedOutputDir]
    }
    return arguments
  }

  private func cachePruneArguments() throws -> [String] {
    var arguments = ["cache", "prune"]
    if try boolValueForKey("all", defaultValue: false) {
      arguments.append("--all")
    }
    return arguments
  }

  private func baseAppleGatewayPayload(_ resolvedBinary: AppleGatewayResolvedBinary) -> JSONObject {
    [
      "binary": .object([
        "path": .string(resolvedBinary.path),
        "source": .string(resolvedBinary.source.rawValue)
      ])
    ]
  }

  private func configPath() -> String? {
    stringValue("configPath") ?? stringValue("config")
  }

  private func schemaRole() throws -> String? {
    guard let role = stringValue("role") else {
      return nil
    }
    guard Self.allowedSchemaRoles.contains(role) else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) role must be full or reader")
    }
    return role
  }

  private func requiredPermissionDomain() throws -> String {
    guard let domain = stringValue("domain") else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) requires domain")
    }
    guard Self.allowedPermissionDomains.contains(domain) else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) domain is unsupported: \(domain)")
    }
    return domain
  }

  private func fileDownloadKeys() throws -> [String] {
    guard let value = value(for: "keys") else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) requires at least one key")
    }
    let keys: [String]
    switch value {
    case let .array(values):
      keys = try values.enumerated().map { index, value in
        guard let key = trimmedString(value) else {
          throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) keys[\(index)] must be a non-empty string")
        }
        return key
      }
    case .string:
      keys = [try requiredString(value, label: "keys")]
    case .null, .bool, .integer, .number, .object:
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) keys must be a string array")
    }
    guard !keys.isEmpty else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) requires at least one key")
    }
    return keys
  }

  private func variablesArgument() throws -> String? {
    guard let value = value(for: "variables") else {
      return nil
    }
    switch value {
    case let .string(text):
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    case .object:
      return try value.compactJSONString()
    case .null:
      return nil
    case .bool, .integer, .number, .array:
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) variables must be a JSON object or string")
    }
  }

  private func stringValue(_ key: String) -> String? {
    guard let value = value(for: key) else {
      return nil
    }
    return trimmedString(value)
  }

  private func value(for key: String) -> JSONValue? {
    if let inputValue = renderedInputs[key] {
      return inputValue
    }
    guard let configValue = config[key] else {
      return nil
    }
    guard key != "binaryPath" else {
      return configValue
    }
    return renderJSONTemplates(configValue, variables: variables)
  }

  private func boolValueForKey(_ key: String, defaultValue: Bool) throws -> Bool {
    guard let value = value(for: key) else {
      return defaultValue
    }
    guard let bool = boolValue(value) else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(key) must be a boolean")
    }
    return bool
  }

  private func requiredString(_ value: JSONValue, label: String) throws -> String {
    guard let string = trimmedString(value) else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(label) must be a non-empty string")
    }
    return string
  }

  private func trimmedString(_ value: JSONValue) -> String? {
    guard let string = nonEmptyString(value) else {
      return nil
    }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func requiredJSONObject(from stdout: String, label: String) throws -> JSONObject {
    guard let data = stdout.data(using: .utf8) else {
      throw AdapterExecutionError(.invalidOutput, "\(input.addon.name) \(label) stdout was not UTF-8")
    }
    let decoded: JSONValue
    do {
      decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
      throw AdapterExecutionError(.invalidOutput, "\(input.addon.name) \(label) stdout was not valid JSON: \(error.localizedDescription)")
    }
    guard let object = objectValue(decoded) else {
      throw AdapterExecutionError(.invalidOutput, "\(input.addon.name) \(label) stdout must be a JSON object")
    }
    return object
  }

  private func decodedJSONOrText(_ stdout: String) -> JSONValue {
    guard let data = stdout.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
    else {
      return .string(appleGatewayCompactText(stdout))
    }
    return decoded
  }
}
