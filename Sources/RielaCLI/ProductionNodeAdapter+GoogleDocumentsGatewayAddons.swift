import Foundation
#if canImport(GoogleDocumentsGatewayCore)
import GoogleDocumentsGatewayCore
#endif
import RielaAddonSupport
import RielaCore

/// Built-in add-ons that run the sibling google-documents-gateway package
/// inside this process (Docs / Sheets / Drive, split into reader and writer
/// roles with disjoint OAuth scopes). The gateway's surface is not GraphQL:
/// each call is `<command> --flag=value ...` returning one `{"ok":bool,...}`
/// JSON envelope, so these add-ons take a fixed command plus a validated flag
/// map instead of a query template. Each add-on pins one role, which the
/// gateway's own command runner enforces by refusing commands outside it, so a
/// workflow cannot escalate from reader to writer scopes through inputs or
/// payload data.
enum BuiltinGoogleDocumentsGatewayAddon: String {
  case docsRead = "riela/google-docs-gateway-read"
  case docsWrite = "riela/google-docs-gateway-write"
  case sheetRead = "riela/google-sheet-gateway-read"
  case sheetWrite = "riela/google-sheet-gateway-write"
  case driveRead = "riela/google-drive-gateway-read"
  case driveWrite = "riela/google-drive-gateway-write"

  /// The role name reported in the add-on payload, matching the executable
  /// this add-on used to launch.
  var tier: String {
    switch self {
    case .docsRead:
      "google-docs-gateway-reader"
    case .docsWrite:
      "google-docs-gateway-writer"
    case .sheetRead:
      "google-sheet-gateway-reader"
    case .sheetWrite:
      "google-sheet-gateway-writer"
    case .driveRead:
      "google-drive-gateway-reader"
    case .driveWrite:
      "google-drive-gateway-writer"
    }
  }

  #if canImport(GoogleDocumentsGatewayCore)
  var role: GatewayRole {
    switch self {
    case .docsRead:
      GatewayRole(service: .docs, accessMode: .read)
    case .docsWrite:
      GatewayRole(service: .docs, accessMode: .write)
    case .sheetRead:
      GatewayRole(service: .sheets, accessMode: .read)
    case .sheetWrite:
      GatewayRole(service: .sheets, accessMode: .write)
    case .driveRead:
      GatewayRole(service: .drive, accessMode: .read)
    case .driveWrite:
      GatewayRole(service: .drive, accessMode: .write)
    }
  }
  #endif

  /// The credential-variable suffix the gateway derives from its default
  /// credential id for this role (note: sheet binaries use the SHEETS suffix).
  var credentialEnvironmentSuffix: String {
    switch self {
    case .docsRead:
      "DOCS_READER"
    case .docsWrite:
      "DOCS_WRITER"
    case .sheetRead:
      "SHEETS_READER"
    case .sheetWrite:
      "SHEETS_WRITER"
    case .driveRead:
      "DRIVE_READER"
    case .driveWrite:
      "DRIVE_WRITER"
    }
  }

  /// Exactly the five credential variables of this add-on's own role plus
  /// the role-neutral credential-directory relocation variable. A reader
  /// add-on cannot receive writer credentials through addon.env.
  var allowedTargetEnvironmentNames: Set<String> {
    let prefix = "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_\(credentialEnvironmentSuffix)"
    return [
      "\(prefix)_OAUTH_CLIENT_ID",
      "\(prefix)_OAUTH_CLIENT_SECRET_JSON",
      "\(prefix)_OAUTH_CLIENT_SECRET_PATH",
      "\(prefix)_TOKEN_STORE_JSON",
      "\(prefix)_TOKEN_STORE_PATH",
      "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DIR"
    ]
  }
}

/// Runs one google-documents-gateway command for a pinned role and returns the
/// JSON envelope that gateway's CLI would have printed.
typealias GoogleDocumentsGatewayRunner = @Sendable (
  _ tier: String,
  _ arguments: [String],
  _ environment: [String: String]
) async throws -> String

extension BuiltinGoogleDocumentsGatewayAddon {
  #if canImport(GoogleDocumentsGatewayCore)
  var runner: GoogleDocumentsGatewayRunner {
    let role = role
    return { tier, arguments, environment in
      let result = GatewayCommandRunner(role: role, environment: environment).run(arguments: arguments)
      guard !result.stdout.isEmpty else {
        throw AdapterExecutionError(.providerError, "\(tier) failed with exit code \(result.exitCode)")
      }
      return result.stdout
    }
  }
  #else
  var runner: GoogleDocumentsGatewayRunner {
    { tier, _, _ in
      throw AdapterExecutionError(.policyBlocked, "\(tier) requires macOS")
    }
  }
  #endif
}

extension BuiltinWorkflowAddonResolver {
  func executeGoogleDocumentsGatewayAddon(
    _ input: WorkflowAddonExecutionInput,
    operation: BuiltinGoogleDocumentsGatewayAddon,
    context: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    try await GoogleDocumentsGatewayAddonEngine(
      environment: environment,
      runnerOverride: googleDocumentsGatewayRunner
    ).execute(input, operation: operation, context: context)
  }
}

private struct GoogleDocumentsGatewayAddonEngine {
  /// `auth login` opens a browser and blocks on a loopback OAuth callback;
  /// `auth revoke` destroys stored credentials. Neither belongs in a workflow
  /// node, so both are refused before the gateway is called.
  private static let forbiddenCommands: Set<String> = ["auth login", "auth revoke"]

  var environment: [String: String]
  var runnerOverride: GoogleDocumentsGatewayRunner?

  func execute(
    _ input: WorkflowAddonExecutionInput,
    operation: BuiltinGoogleDocumentsGatewayAddon,
    context: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }
    let config = input.addon.config ?? [:]
    var variables = addonVariables(for: input)
    for (name, value) in try localGatewayNowVariables(config: config, addonName: input.addon.name) {
      variables[name] = .string(value)
    }
    let childEnvironment = try resolvedChildEnvironment(input, operation: operation)
    let commandTokens = try commandTokens(config: config, addonName: input.addon.name)
    let arguments = commandTokens + (try renderedFlagArguments(
      config: config,
      variables: variables,
      addonName: input.addon.name
    ))
    let gatewayEnvironment = sanitizedGatewayEnvironment(
      runtimeEnvironment: environment,
      bindings: childEnvironment
    )
    let tier = operation.tier
    let run: GoogleDocumentsGatewayRunner = runnerOverride ?? operation.runner
    let stdout = try await localGatewayRunWithDeadline(
      deadline: context.deadline,
      addonName: input.addon.name,
      providerName: "google-documents-gateway"
    ) {
      try await run(tier, arguments, gatewayEnvironment)
    }
    let data = try successData(from: stdout, addonName: input.addon.name)
    var payloadRoot: JSONObject = ["data": .object(data)]
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
      "command": .string(commandTokens.joined(separator: " ")),
      "data": .object(data),
      "replyText": .string("google-documents-gateway \(operation.tier) command succeeded."),
      "googleDocumentsGateway": .object([
        // The gateway is linked into this process, so there is no resolved
        // binary to report; the role that answered is the useful fact.
        "runtime": .object([
          "mode": .string("in-process"),
          "tier": .string(operation.tier)
        ])
      ])
    ]
    if let selected = payloadRoot["selected"] {
      payload["selected"] = selected
    }
    for (key, value) in try localGatewayPayloadExtras(config: config, variables: variables, addonName: input.addon.name) {
      payload[key] = value
    }
    return AdapterExecutionOutput(
      provider: "google-documents-gateway",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      when: when,
      payload: payload
    )
  }

  private func resolvedChildEnvironment(
    _ input: WorkflowAddonExecutionInput,
    operation: BuiltinGoogleDocumentsGatewayAddon
  ) throws -> [String: String] {
    if let env = input.addon.env {
      let allowed = operation.allowedTargetEnvironmentNames
      for targetName in env.keys where !allowed.contains(targetName) {
        throw AdapterExecutionError(
          .policyBlocked,
          "\(input.addon.name) addon.env target '\(targetName)' is not a \(operation.credentialEnvironmentSuffix) google-documents-gateway environment variable"
        )
      }
    }
    return try resolveAddonEnvironment(input.addon.env, runtimeEnvironment: environment)
  }

  /// The command is a literal config value (never rendered from workflow
  /// input), one or two lowercase words matching the gateway CLI grammar.
  private func commandTokens(config: JSONObject, addonName: String) throws -> [String] {
    guard let command = nonEmptyString(config["command"]) else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.command is required")
    }
    let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
    guard (1...2).contains(tokens.count),
          tokens.allSatisfy({ isCommandWord($0) }) else {
      throw AdapterExecutionError(
        .policyBlocked,
        "\(addonName) config.command must be one or two lowercase command words, got '\(command)'"
      )
    }
    let normalized = tokens.joined(separator: " ")
    guard !Self.forbiddenCommands.contains(normalized) else {
      throw AdapterExecutionError(
        .policyBlocked,
        "\(addonName) refuses '\(normalized)'; run interactive credential commands outside workflows"
      )
    }
    return tokens
  }

  private func isCommandWord(_ token: String) -> Bool {
    guard let first = token.first, first.isLetter else {
      return false
    }
    return token.allSatisfy { $0 == "-" || ($0.isLetter && $0.isLowercase) }
  }

  /// argsTemplate maps flag names to rendered values. Values bind as
  /// `--flag=value` (a single argv element, so rendered text can never be
  /// parsed as an extra flag); `true` emits a bare boolean `--flag`; `false`
  /// and `null` omit the flag; arrays repeat the flag per element.
  private func renderedFlagArguments(
    config: JSONObject,
    variables: JSONObject,
    addonName: String
  ) throws -> [String] {
    guard let value = config["argsTemplate"] else {
      return []
    }
    guard case let .object(template) = value else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.argsTemplate must be an object")
    }
    var arguments: [String] = []
    for flagName in template.keys.sorted() {
      guard isFlagName(flagName) else {
        throw AdapterExecutionError(
          .policyBlocked,
          "\(addonName) config.argsTemplate flag '\(flagName)' must be lowercase words separated by dashes"
        )
      }
      let rendered = renderJSONTemplates(template[flagName] ?? .null, variables: variables)
      arguments.append(contentsOf: try flagArguments(flagName, value: rendered, addonName: addonName))
    }
    return arguments
  }

  private func isFlagName(_ name: String) -> Bool {
    guard let first = name.first, first.isLetter, first.isLowercase else {
      return false
    }
    return name.allSatisfy { $0 == "-" || $0.isNumber || ($0.isLetter && $0.isLowercase) }
  }

  private func flagArguments(_ flagName: String, value: JSONValue, addonName: String) throws -> [String] {
    switch value {
    case .null, .bool(false):
      return []
    case .bool(true):
      return ["--\(flagName)"]
    case let .string(text):
      guard !text.isEmpty else {
        throw AdapterExecutionError(.invalidInput, "\(addonName) config.argsTemplate.\(flagName) rendered to an empty string")
      }
      return ["--\(flagName)=\(text)"]
    case let .integer(number):
      return ["--\(flagName)=\(number)"]
    case let .number(number):
      return ["--\(flagName)=\(number)"]
    case let .array(items):
      return try items.flatMap { item -> [String] in
        switch item {
        case .string, .integer, .number:
          return try flagArguments(flagName, value: item, addonName: addonName)
        default:
          throw AdapterExecutionError(
            .invalidInput,
            "\(addonName) config.argsTemplate.\(flagName) array elements must be strings or numbers"
          )
        }
      }
    case .object:
      throw AdapterExecutionError(.invalidInput, "\(addonName) config.argsTemplate.\(flagName) must not be an object")
    }
  }

  /// Parses the gateway's `{"ok":bool,...}` envelope. `ok:false` carries a
  /// stable `error.code`; argument-shaped codes map to invalidInput and
  /// everything else (auth, transport, provider) to providerError.
  private func successData(
    from stdout: String,
    addonName: String
  ) throws -> JSONObject {
    guard let bytes = stdout.data(using: .utf8),
          let decoded = try? JSONDecoder().decode(JSONValue.self, from: bytes),
          case let .object(envelope) = decoded,
          case let .bool(ok)? = envelope["ok"] else {
      throw AdapterExecutionError(
        .invalidOutput,
        "\(addonName) output was not a google-documents-gateway JSON envelope: \(appleGatewayCompactText(stdout))"
      )
    }
    guard ok else {
      let error = objectValue(envelope["error"]) ?? [:]
      let code = nonEmptyString(error["code"]) ?? "UNKNOWN_ERROR"
      let message = appleGatewayCompactText(nonEmptyString(error["message"]) ?? "no error message")
      let argumentCodes: Set<String> = ["INVALID_ARGUMENT", "FORBIDDEN_COMMAND", "INPUT_TOO_LARGE"]
      throw AdapterExecutionError(
        argumentCodes.contains(code) ? .invalidInput : .providerError,
        "\(addonName) \(code): \(message)"
      )
    }
    guard case let .object(data)? = envelope["data"] else {
      throw AdapterExecutionError(.invalidOutput, "\(addonName) envelope data is missing")
    }
    return data
  }
}
