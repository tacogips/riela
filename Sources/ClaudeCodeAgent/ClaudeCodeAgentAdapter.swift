import Foundation
import RielaAdapters
import RielaCore

private let defaultClaudeAuthPreflightTimeout: TimeInterval = 5

public enum ClaudeCodePermissionMode: String, Sendable {
  case `default`
  case acceptEdits
  case plan
  case bypassPermissions
}

public struct ClaudeCodeAgentCommandBuilder: LocalAgentCommandBuilding {
  public var executableName: String
  public var permissionMode: ClaudeCodePermissionMode?
  public var environment: [String: String]
  public var additionalArguments: [String]

  public var provider: String { CliAgentBackend.claudeCodeAgent.rawValue }

  public init(
    executableName: String = "claude",
    permissionMode: ClaudeCodePermissionMode? = nil,
    environment: [String: String] = [:],
    additionalArguments: [String] = []
  ) {
    self.executableName = executableName
    self.permissionMode = permissionMode
    self.environment = environment
    self.additionalArguments = additionalArguments
  }

  public func buildCommand(for input: AdapterExecutionInput) throws -> LocalAgentCommand {
    try validateAgentProviderRoutingForAdapter(input.node)
    var arguments = [executableName, "-p", "--output-format", "text", "--model", input.node.model]
    if let effort = input.node.effort {
      arguments.append(contentsOf: ["--effort", effort.rawValue])
    }

    let resolvedPermissionMode = permissionMode
      ?? claudePermissionMode(for: input.node.agentSandbox)
      ?? stringValue(input.node.variables["claudePermissionMode"]).flatMap(ClaudeCodePermissionMode.init(rawValue:))
    if let resolvedPermissionMode {
      arguments.append(contentsOf: ["--permission-mode", resolvedPermissionMode.rawValue])
    }

    let attachmentPaths = deduplicatedPaths(
      stringArray(input.node.variables["attachmentPaths"]) + resolveAdapterImagePaths(input)
    )
    for directory in uniqueSortedDirectories(containing: attachmentPaths) {
      arguments.append(contentsOf: ["--add-dir", directory])
    }

    arguments.append(contentsOf: additionalArguments)
    arguments.append(contentsOf: agentToolPolicyArguments(input.node.agentToolPolicy, backend: .claudeCodeAgent))
    arguments.append(contentsOf: stringArray(input.node.variables["claudeAdditionalArgs"]))

    let environment = mergedAgentProcessEnvironment(
      baseEnvironment: environment,
      input: input,
      providerEnvironment: try claudeProviderEnvironment(input: input, baseEnvironment: environment),
      provider: provider
    )
    let workingDirectoryURL = input.node.workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
    let sandboxPolicy = try resolveSeatbeltSandboxPolicy(
      builderEnvironment: environment,
      agentSandbox: input.node.agentSandbox,
      workingDirectory: workingDirectoryURL,
      stateRoots: claudeSeatbeltStateRoots
    )
    return LocalAgentCommand(
      provider: provider,
      metadata: providerMetadata(input.node.provider),
      configuration: LocalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: arguments,
        environment: environment,
        workingDirectoryURL: workingDirectoryURL,
        sandboxPolicy: sandboxPolicy
      ),
      stdin: buildClaudePrompt(
        prompt: input.promptText,
        systemPrompt: input.systemPromptText,
        attachmentPaths: attachmentPaths
      ),
      backendEventType: claudeBackendEventType
    )
  }
}

// Writable roots the claude CLI needs for session state and caches even under a
// read-only sandbox; kept conservative and expanded/canonicalized by the profile
// generator.
private let claudeSeatbeltStateRoots = [
  "~/.claude",
  "~/.claude.json",
  "~/Library/Caches/claude-cli-nodejs"
]

private func claudePermissionMode(for sandbox: AgentSandboxMode?) -> ClaudeCodePermissionMode? {
  switch sandbox {
  case .readOnly:
    .plan
  case .workspaceWrite:
    .acceptEdits
  case .dangerFullAccess:
    .bypassPermissions
  case nil:
    nil
  }
}

public struct ClaudeCodeAgentAdapter: NodeAdapter {
  private let adapter: LocalAgentCommandAdapter
  private let executableName: String
  private let runner: any LocalAgentProcessRunning
  private let environment: [String: String]
  private let authPreflight: Bool
  private let checkAuthPreflight: (@Sendable (AdapterExecutionInput) async throws -> Void)?

  public init(
    executableName: String = "claude",
    runner: any LocalAgentProcessRunning = FoundationLocalAgentProcessRunner(),
    permissionMode: ClaudeCodePermissionMode? = nil,
    environment: [String: String] = [:],
    additionalArguments: [String] = [],
    authPreflight: Bool = true,
    checkAuthPreflight: (@Sendable (AdapterExecutionInput) async throws -> Void)? = nil
  ) {
    self.executableName = executableName
    self.runner = runner
    self.environment = environment
    self.authPreflight = authPreflight
    self.adapter = LocalAgentCommandAdapter(
      commandBuilder: ClaudeCodeAgentCommandBuilder(
        executableName: executableName,
        permissionMode: permissionMode,
        environment: environment,
        additionalArguments: additionalArguments
      ),
      runner: runner
    )
    self.checkAuthPreflight = checkAuthPreflight
  }

  public func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    if authPreflight {
      if let checkAuthPreflight {
        let sensitiveValues = claudePreflightSensitiveValues(input: input, baseEnvironment: environment)
        do {
          try await checkAuthPreflight(input)
        } catch let error as CancellationError {
          throw error
        } catch let error as AdapterExecutionError {
          throw AdapterExecutionError(
            error.code,
            redactAdapterSensitiveText(error.message, additionalSensitiveValues: sensitiveValues),
            isRetryable: error.isRetryable,
            retryAfter: error.retryAfter
          )
        } catch {
          throw AdapterExecutionError(
            .policyBlocked,
            "claude-code-agent authentication is unavailable: \(redactAdapterSensitiveText(error.localizedDescription, additionalSensitiveValues: sensitiveValues))"
          )
        }
      } else {
        try await runClaudeDefaultAuthPreflight(
          input: input,
          executableName: executableName,
          environment: environment,
          runner: runner,
          deadline: context.deadline
        )
      }
    }
    return try await adapter.execute(input, context: context)
  }
}

private func claudePreflightSensitiveValues(
  input: AdapterExecutionInput,
  baseEnvironment: [String: String]
) -> [String] {
  let processEnvironment = mergedAgentProcessEnvironment(
    baseEnvironment: baseEnvironment,
    input: input,
    provider: CliAgentBackend.claudeCodeAgent.rawValue
  )
  return sensitiveAdapterEnvironmentValues(processEnvironment)
    + providerCredentialSensitiveValues(input.node.provider, processEnvironment: processEnvironment)
}

private func runClaudeDefaultAuthPreflight(
  input: AdapterExecutionInput,
  executableName: String,
  environment: [String: String],
  runner: any LocalAgentProcessRunning,
  deadline: Date?
) async throws {
  let preflightEnvironment = mergedAgentProcessEnvironment(
    baseEnvironment: environment,
    input: input,
    providerEnvironment: try claudeProviderEnvironment(input: input, baseEnvironment: environment),
    provider: CliAgentBackend.claudeCodeAgent.rawValue
  )
  let sensitiveValues = sensitiveAdapterEnvironmentValues(preflightEnvironment)
  let versionDeadline = defaultAgentPreflightDeadline(existingDeadline: deadline, timeout: defaultClaudeAuthPreflightTimeout)
  let version: LocalAgentProcessResult
  do {
    version = try await runner.run(
      configuration: LocalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: [executableName, "--version"],
        environment: preflightEnvironment,
        workingDirectoryURL: input.node.workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
      ),
      stdin: "",
      deadline: versionDeadline
    )
  } catch let error as CancellationError {
    throw error
  } catch {
    throw AdapterExecutionError(
      .policyBlocked,
      "claude-code-agent CLI is unavailable: \(agentPreflightErrorDetail(error, fallback: "claude command timed out", additionalSensitiveValues: sensitiveValues))"
    )
  }
  guard version.terminationStatus == 0 else {
    throw AdapterExecutionError(
      .policyBlocked,
      "claude-code-agent CLI is unavailable: \(preflightFailureDetail(version, fallback: "claude command is unavailable", additionalSensitiveValues: sensitiveValues))"
    )
  }

  let authDeadline = defaultAgentPreflightDeadline(existingDeadline: deadline, timeout: defaultClaudeAuthPreflightTimeout)
  let auth: LocalAgentProcessResult
  do {
    auth = try await runner.run(
      configuration: LocalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: [executableName, "auth", "status"],
        environment: preflightEnvironment,
        workingDirectoryURL: input.node.workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
      ),
      stdin: "",
      deadline: authDeadline
    )
  } catch let error as CancellationError {
    throw error
  } catch {
    throw AdapterExecutionError(
      .policyBlocked,
      "claude-code-agent authentication is unavailable: \(agentPreflightErrorDetail(error, fallback: "auth verify timed out", additionalSensitiveValues: sensitiveValues))"
    )
  }
  let combined = [auth.stderr, auth.stdout].joined(separator: "\n")
  if auth.terminationStatus != 0 || combined.range(of: #""loggedIn"\s*:\s*false"#, options: [.regularExpression]) != nil {
    throw AdapterExecutionError(
      .policyBlocked,
      "claude-code-agent authentication is unavailable: \(preflightFailureDetail(auth, fallback: "auth verify failed", additionalSensitiveValues: sensitiveValues))"
    )
  }
}

private func claudeProviderEnvironment(
  input: AdapterExecutionInput,
  baseEnvironment: [String: String]
) throws -> [String: String] {
  guard let provider = input.node.provider else {
    return [:]
  }
  var environment = ["ANTHROPIC_BASE_URL": provider.baseUrl]
  if let apiKeyEnv = provider.apiKeyEnv {
    let runtimeValue = input.agentEnvironment[apiKeyEnv]
      ?? baseEnvironment[apiKeyEnv]
      ?? ProcessInfo.processInfo.environment[apiKeyEnv]
    guard let runtimeValue, !runtimeValue.isEmpty else {
      throw AdapterExecutionError(
        .policyBlocked,
        "provider.apiKeyEnv requires runtime environment '\(apiKeyEnv)'"
      )
    }
    environment["ANTHROPIC_AUTH_TOKEN"] = runtimeValue
  }
  return environment
}

private func providerMetadata(_ configuration: AgentProviderConfiguration?) -> JSONObject {
  configuration.map { ["provider_name": .string($0.name)] } ?? [:]
}

private func preflightFailureDetail(
  _ result: LocalAgentProcessResult,
  fallback: String,
  additionalSensitiveValues: [String]
) -> String {
  compactAgentReadinessMessage(
    [result.stderr, result.stdout].joined(separator: "\n"),
    fallback: fallback,
    additionalSensitiveValues: additionalSensitiveValues
  )
}

private func buildClaudePrompt(prompt: String, systemPrompt: String?, attachmentPaths: [String]) -> String {
  var parts: [String]
  if let systemPrompt, !systemPrompt.isEmpty {
    parts = ["System instruction:", systemPrompt, "", "User instruction:", prompt]
  } else {
    parts = [prompt]
  }
  if !attachmentPaths.isEmpty {
    parts.append(contentsOf: ["", "Attached files:"])
    parts.append(contentsOf: attachmentPaths.map { "- \($0)" })
  }
  return parts.joined(separator: "\n")
}

private func claudeBackendEventType(_ line: String) -> String? {
  guard
    let data = line.data(using: .utf8),
    let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
    case let .object(object) = decoded
  else {
    return nil
  }
  return stringValue(object["type"]) ?? stringValue(object["event"]) ?? "json-event"
}

private func uniqueSortedDirectories(containing paths: [String]) -> [String] {
  let directories = Set(paths.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
  return directories.sorted()
}

private func deduplicatedPaths(_ paths: [String]) -> [String] {
  var seen = Set<String>()
  return paths.filter { path in
    guard !path.isEmpty, !seen.contains(path) else {
      return false
    }
    seen.insert(path)
    return true
  }
}

private func stringArray(_ value: JSONValue?) -> [String] {
  guard case let .array(entries) = value else {
    return []
  }
  return entries.compactMap { entry in
    guard case let .string(text) = entry else {
      return nil
    }
    return text
  }
}

private func stringValue(_ value: JSONValue?) -> String? {
  guard case let .string(text) = value else {
    return nil
  }
  return text
}
