import Foundation
import RielaCore

public struct BackendCapabilityProbe: Sendable {
  public var runner: any LocalProcessRunning
  public var timeout: TimeInterval

  public init(runner: any LocalProcessRunning = FoundationLocalProcessRunner(), timeout: TimeInterval = 5) {
    self.runner = runner
    self.timeout = timeout
  }

  public func probeAll(
    environment: [String: String],
    now: Date = Date(),
    executableURLs: [NodeExecutionBackend: URL] = [:]
  ) async -> [BackendCapability] {
    var results: [BackendCapability] = []
    for backend in NodeExecutionBackend.allCases {
      results.append(await probe(
        backend,
        environment: environment,
        now: now,
        executableURL: executableURLs[backend] ?? resolveExecutable(for: backend, environment: environment)
      ))
    }
    return results
  }

  public func probe(
    _ backend: NodeExecutionBackend,
    environment: [String: String],
    now: Date = Date(),
    executableURL: URL? = nil
  ) async -> BackendCapability {
    if let credentials = sdkCredentialEnvironments(for: backend) {
      let presence = Dictionary(uniqueKeysWithValues: credentials.map { name in
        (name, environment[name].map { !$0.isEmpty } ?? false)
      })
      let present = presence.values.contains(true)
      return BackendCapability(
        backend: backend,
        source: .observed,
        observedAt: now,
        availability: present ? .available : .unavailable,
        authentication: present ? .available : .unknown,
        requiredEnvironment: presence,
        requiredEnvironmentAlternatives: [credentials],
        executableAvailable: nil,
        failures: present ? [] : ["required environment is not configured: \(credentials.joined(separator: " or "))"]
      )
    }

    guard let executableURL = executableURL ?? resolveExecutable(for: backend, environment: environment) else {
      return BackendCapability(
        backend: backend,
        source: .observed,
        observedAt: now,
        availability: .unavailable,
        executableAvailable: false,
        failures: ["backend executable is not installed"]
      )
    }

    do {
      let versionResult = try await run(executableURL, arguments: ["--version"], environment: environment)
      guard versionResult.terminationStatus == 0 else {
        return BackendCapability(
          backend: backend,
          source: .observed,
          observedAt: now,
          availability: .unavailable,
          failures: ["version probe failed (exit \(versionResult.terminationStatus))"]
        )
      }
      let auth = await authentication(
        backend,
        executableURL: executableURL,
        environment: environment
      )
      return BackendCapability(
        backend: backend,
        source: .observed,
        observedAt: now,
        availability: .available,
        authentication: auth.status,
        version: firstNonemptyLine(versionResult.stdout, fallback: versionResult.stderr),
        executableAvailable: true,
        failures: auth.failure.map { [$0] } ?? []
      )
    } catch {
      return BackendCapability(
        backend: backend,
        source: .observed,
        observedAt: now,
        availability: .unavailable,
        failures: ["backend probe could not execute"]
      )
    }
  }

  private func authentication(
    _ backend: NodeExecutionBackend,
    executableURL: URL,
    environment: [String: String]
  ) async -> (status: BackendCapability.Authentication, failure: String?) {
    let arguments: [String]?
    switch backend {
    case .codexAgent:
      arguments = ["login", "status"]
    case .claudeCodeAgent:
      arguments = ["auth", "status"]
    case .cursorCliAgent:
      arguments = nil
    case .officialOpenAISDK, .officialAnthropicSDK, .officialGeminiSDK, .officialCursorSDK:
      arguments = nil
    }
    guard let arguments else { return (.unknown, nil) }
    do {
      let result = try await run(executableURL, arguments: arguments, environment: environment)
      return result.terminationStatus == 0
        ? (.available, nil)
        : (.failed, "authentication probe failed (exit \(result.terminationStatus))")
    } catch {
      return (.unknown, "authentication probe could not execute")
    }
  }

  private func run(
    _ executableURL: URL,
    arguments: [String],
    environment: [String: String]
  ) async throws -> LocalProcessResult {
    try await runner.run(
      configuration: LocalProcessConfiguration(
        executableURL: executableURL,
        arguments: arguments,
        environment: environment
      ),
      stdin: "",
      deadline: Date().addingTimeInterval(timeout)
    )
  }

  private func resolveExecutable(
    for backend: NodeExecutionBackend,
    environment: [String: String]
  ) -> URL? {
    let command: String
    let overrideName: String
    switch backend {
    case .codexAgent:
      (command, overrideName) = ("codex", "RIELA_CODEX_AGENT_EXECUTABLE")
    case .claudeCodeAgent:
      (command, overrideName) = ("claude", "RIELA_CLAUDE_CODE_AGENT_EXECUTABLE")
    case .cursorCliAgent:
      (command, overrideName) = ("cursor-agent", "RIELA_CURSOR_CLI_AGENT_EXECUTABLE")
    case .officialOpenAISDK, .officialAnthropicSDK, .officialGeminiSDK, .officialCursorSDK:
      return nil
    }
    if let override = environment[overrideName], !override.isEmpty {
      return URL(fileURLWithPath: override)
    }
    for directory in (environment["PATH"] ?? "").split(separator: ":") {
      let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(command)
      if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    return nil
  }

  private func sdkCredentialEnvironments(for backend: NodeExecutionBackend) -> [String]? {
    switch backend {
    case .officialOpenAISDK: ["OPENAI_API_KEY"]
    case .officialAnthropicSDK: ["ANTHROPIC_API_KEY", "CLAUDE_API_KEY"]
    case .officialGeminiSDK: ["GOOGLE_API_KEY", "GEMINI_API_KEY"]
    case .officialCursorSDK: ["CURSOR_API_KEY"]
    case .codexAgent, .claudeCodeAgent, .cursorCliAgent: nil
    }
  }

  private func firstNonemptyLine(_ primary: String, fallback: String) -> String? {
    (primary + "\n" + fallback)
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }
  }
}
