import Foundation
import RielaAdapters
import RielaCore

public struct CodexBackendToolVersions: Equatable, Sendable {
  public var codex: AgentBackendToolInfo
  public var git: AgentBackendToolInfo

  public init(codex: AgentBackendToolInfo, git: AgentBackendToolInfo) {
    self.codex = codex
    self.git = git
  }
}

public struct CodexBackendLoginStatus: Equatable, Sendable {
  public var ok: Bool
  public var status: String?
  public var error: String?
  public var exitCode: Int?

  public init(ok: Bool, status: String? = nil, error: String? = nil, exitCode: Int? = nil) {
    self.ok = ok
    self.status = status
    self.error = error
    self.exitCode = exitCode
  }
}

public struct CodexBackendModelProbe: Equatable, Sendable {
  public var ok: Bool
  public var model: String
  public var output: String?
  public var error: String?
  public var exitCode: Int?

  public init(ok: Bool, model: String, output: String? = nil, error: String? = nil, exitCode: Int? = nil) {
    self.ok = ok
    self.model = model
    self.output = output
    self.error = error
    self.exitCode = exitCode
  }
}

public struct CodexBackendModelAvailability: Equatable, Sendable {
  public var ok: Bool
  public var model: String
  public var auth: CodexBackendLoginStatus
  public var probe: CodexBackendModelProbe

  public init(ok: Bool, model: String, auth: CodexBackendLoginStatus, probe: CodexBackendModelProbe) {
    self.ok = ok
    self.model = model
    self.auth = auth
    self.probe = probe
  }
}

public protocol CodexAgentReadinessOperations: Sendable {
  func getToolVersions(options: AgentBackendProbeOptions) async -> CodexBackendToolVersions
  func getLoginStatus(options: AgentBackendProbeOptions) async -> CodexBackendLoginStatus
  func checkModelAvailability(model: String, options: AgentBackendProbeOptions) async -> CodexBackendModelAvailability
}

public struct CodexAgentDefaultReadinessOperations: CodexAgentReadinessOperations {
  public var codexBinary: String
  public var gitBinary: String
  public var includeGit: Bool
  public var runner: any LocalAgentProcessRunning

  public init(
    codexBinary: String = "codex",
    gitBinary: String = "git",
    includeGit: Bool = true,
    runner: any LocalAgentProcessRunning = FoundationLocalAgentProcessRunner()
  ) {
    self.codexBinary = codexBinary
    self.gitBinary = gitBinary
    self.includeGit = includeGit
    self.runner = runner
  }

  public func getToolVersions(options: AgentBackendProbeOptions = AgentBackendProbeOptions()) async -> CodexBackendToolVersions {
    async let codex = toolVersion(name: "codex", command: codexBinary, options: options)
    async let git = includeGit
      ? toolVersion(name: "git", command: gitBinary, options: options)
      : AgentBackendToolInfo(name: "git", command: gitBinary, status: .notChecked)
    return await CodexBackendToolVersions(codex: codex, git: git)
  }

  public func getLoginStatus(options: AgentBackendProbeOptions = AgentBackendProbeOptions()) async -> CodexBackendLoginStatus {
    let result = await run(arguments: [codexBinary, "login", "status"], options: options)
    switch result {
    case let .success(output):
      let status = firstNonEmptyLine(output.stdout) ?? firstNonEmptyLine(output.stderr)
      let combined = [output.stderr, output.stdout].joined(separator: "\n")
      if output.terminationStatus == 0 && !codexReadinessHasAuthFailureText(combined) {
        return CodexBackendLoginStatus(ok: true, status: status, exitCode: Int(output.terminationStatus))
      }
      return CodexBackendLoginStatus(
        ok: false,
        status: status,
        error: compactAgentReadinessMessage(combined, fallback: status ?? "Not logged in"),
        exitCode: Int(output.terminationStatus)
      )
    case let .failure(error):
      return CodexBackendLoginStatus(ok: false, error: redactAdapterSensitiveText(error.localizedDescription), exitCode: nil)
    }
  }

  public func checkModelAvailability(model: String, options: AgentBackendProbeOptions = AgentBackendProbeOptions()) async -> CodexBackendModelAvailability {
    async let auth = getLoginStatus(options: options)
    async let probe = probeModel(model: model, options: options)
    let resolvedAuth = await auth
    let resolvedProbe = await probe
    return CodexBackendModelAvailability(ok: resolvedAuth.ok && resolvedProbe.ok, model: model, auth: resolvedAuth, probe: resolvedProbe)
  }

  private func toolVersion(name: String, command: String, options: AgentBackendProbeOptions) async -> AgentBackendToolInfo {
    let result = await run(arguments: [command, "--version"], options: options)
    switch result {
    case let .success(output):
      guard output.terminationStatus == 0 else {
        return AgentBackendToolInfo(
          name: name,
          command: command,
          status: .unavailable,
          error: "version command failed (exit code \(output.terminationStatus)): \(compactAgentReadinessMessage(output.stderr, fallback: output.stdout))"
        )
      }
      guard let version = firstNonEmptyLine(output.stdout) ?? firstNonEmptyLine(output.stderr) else {
        return AgentBackendToolInfo(name: name, command: command, status: .unavailable, error: "version command returned no output")
      }
      return AgentBackendToolInfo(name: name, command: command, version: version, status: .available)
    case let .failure(error):
      return AgentBackendToolInfo(name: name, command: command, status: .unavailable, error: redactAdapterSensitiveText(error.localizedDescription))
    }
  }

  private func probeModel(model: String, options: AgentBackendProbeOptions) async -> CodexBackendModelProbe {
    let result = await run(
      arguments: [codexBinary, "exec", "--skip-git-repo-check", "--ephemeral", "--model", model, "--", "Reply with exactly OK."],
      options: options
    )
    switch result {
    case let .success(output):
      if output.terminationStatus == 0 {
        return CodexBackendModelProbe(ok: true, model: model, output: firstNonEmptyLine(output.stdout) ?? output.stdout.trimmingCharacters(in: .whitespacesAndNewlines), exitCode: Int(output.terminationStatus))
      }
      let detail = codexStructuredErrorMessage(from: output.stderr) ?? compactAgentReadinessMessage([output.stderr, output.stdout].joined(separator: "\n"), fallback: "model check failed")
      return CodexBackendModelProbe(ok: false, model: model, error: "command failed (exit code \(output.terminationStatus)): \(detail)", exitCode: Int(output.terminationStatus))
    case let .failure(error):
      return CodexBackendModelProbe(ok: false, model: model, error: redactAdapterSensitiveText(error.localizedDescription), exitCode: nil)
    }
  }

  private func run(arguments: [String], options: AgentBackendProbeOptions) async -> Result<LocalAgentProcessResult, Error> {
    do {
      let timeout = options.timeoutMilliseconds.map { TimeInterval($0) / 1000 }
      let result = try await runner.run(
        configuration: LocalAgentProcessConfiguration(
          executableURL: URL(fileURLWithPath: "/usr/bin/env"),
          arguments: arguments,
          environment: options.environment,
          workingDirectoryURL: options.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ),
        stdin: "",
        deadline: timeout.map { Date(timeIntervalSinceNow: $0) }
      )
      return .success(result)
    } catch {
      return .failure(error)
    }
  }
}

public enum CodexAgentReadiness {
  public static func runtimeRequirement(
    candidate: AgentBackendRequirementCandidate,
    operations: any CodexAgentReadinessOperations,
    options: AgentBackendProbeOptions = AgentBackendProbeOptions()
  ) async -> AgentBackendRuntimeRequirement {
    await runtimeRequirement(
      candidate: candidate,
      toolVersions: operations.getToolVersions(options: options)
    )
  }

  public static func authValidation(
    candidate: AgentBackendPreflightCandidate,
    operations: any CodexAgentReadinessOperations,
    options: AgentBackendProbeOptions = AgentBackendProbeOptions()
  ) async -> AgentBackendValidationResult {
    await authValidation(candidate: candidate, status: operations.getLoginStatus(options: options))
  }

  public static func modelValidation(
    candidate: AgentBackendPreflightCandidate,
    model: String,
    operations: any CodexAgentReadinessOperations,
    options: AgentBackendProbeOptions = AgentBackendProbeOptions()
  ) async -> AgentBackendValidationResult {
    await modelValidation(
      candidate: candidate,
      availability: operations.checkModelAvailability(model: model, options: options)
    )
  }

  public static func runtimeRequirement(
    candidate: AgentBackendRequirementCandidate,
    toolVersions: CodexBackendToolVersions
  ) -> AgentBackendRuntimeRequirement {
    let commandSummary = [formatAgentToolInfo(toolVersions.codex), formatAgentToolInfo(toolVersions.git)].joined(separator: ", ")
    return AgentBackendRuntimeRequirement(
      id: "agent-backend:\(candidate.backend.rawValue)",
      label: "\(candidate.backend.rawValue) backend",
      status: agentToolIsAvailable(toolVersions.codex) && agentToolIsAvailable(toolVersions.git) ? .available : .unavailable,
      detail: "local SDK execution; bundled sdk=codex-agent; models=\(sortedAgentModelList(candidate.models)); local tools: \(commandSummary)",
      sourceStepIds: candidate.sourceStepIds
    )
  }

  public static func authValidation(
    candidate: AgentBackendPreflightCandidate,
    status: CodexBackendLoginStatus
  ) -> AgentBackendValidationResult {
    AgentBackendValidationResult(
      status: status.ok ? .valid : .invalid,
      message: status.ok
        ? "codex-agent authentication status is valid"
        : "codex-agent authentication is unavailable: \(compactAgentReadinessMessage(status.error ?? status.status, fallback: "codex login status failed"))",
      candidate: candidate
    )
  }

  public static func accountReadinessValidation(
    candidate: AgentBackendPreflightCandidate,
    availability: CodexBackendModelAvailability?
  ) -> AgentBackendValidationResult {
    guard let availability else {
      return agentUnknownResult(candidate, "codex-agent account readiness could not be verified because no model is authored")
    }
    guard availability.ok else {
      return AgentBackendValidationResult(
        status: .invalid,
        message: "codex-agent account is not usable for model '\(availability.model)': \(compactAgentReadinessMessage(availability.probe.error ?? availability.auth.error ?? availability.probe.output, fallback: "model check failed"))",
        candidate: candidate
      )
    }
    return AgentBackendValidationResult(
      status: .valid,
      message: "codex-agent account readiness is valid for model '\(availability.model)'",
      candidate: candidate
    )
  }

  public static func modelValidation(
    candidate: AgentBackendPreflightCandidate,
    availability: CodexBackendModelAvailability
  ) -> AgentBackendValidationResult {
    guard availability.ok else {
      return AgentBackendValidationResult(
        status: .invalid,
        message: "codex-agent model '\(availability.model)' is not reachable: \(compactAgentReadinessMessage(availability.probe.error ?? availability.auth.error ?? availability.probe.output, fallback: "model check failed"))",
        candidate: candidate
      )
    }
    return AgentBackendValidationResult(
      status: .valid,
      message: "codex-agent model '\(availability.model)' is reachable",
      candidate: candidate
    )
  }
}

private func firstNonEmptyLine(_ text: String) -> String? {
  text.split(whereSeparator: \.isNewline)
    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    .first { !$0.isEmpty }
}

private func codexReadinessHasAuthFailureText(_ text: String) -> Bool {
  text.range(of: #"not logged|login required|unauthorized|credential|expired|permission denied"#, options: [.regularExpression, .caseInsensitive]) != nil
}

private func codexStructuredErrorMessage(from stderr: String) -> String? {
  for line in stderr.split(whereSeparator: \.isNewline).map(String.init) {
    guard let range = line.range(of: "ERROR:") else {
      continue
    }
    let suffix = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = suffix.data(using: .utf8),
          let value = try? JSONDecoder().decode(JSONValue.self, from: data),
          case let .object(root) = value
    else {
      continue
    }
    if case let .object(error)? = root["error"], case let .string(message)? = error["message"], !message.isEmpty {
      return message
    }
    if case let .string(message)? = root["message"], !message.isEmpty {
      return message
    }
  }
  return nil
}
