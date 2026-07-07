import Foundation

#if os(macOS)
import Darwin

final class RielaWorkflowProcessBox: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?

  func set(_ process: Process) {
    lock.lock()
    self.process = process
    lock.unlock()
  }

  func clear(_ process: Process) {
    lock.lock()
    if self.process === process {
      self.process = nil
    }
    lock.unlock()
  }

  func terminate() {
    lock.lock()
    let process = self.process
    lock.unlock()
    process?.terminateWithEscalation()
  }
}

final class RielaWorkflowPipeDrain: @unchecked Sendable {
  private let pipe: Pipe
  private let queue: DispatchQueue
  private let lock = NSLock()
  private var data = Data()

  init(pipe: Pipe, label: String) {
    self.pipe = pipe
    queue = DispatchQueue(label: label)
  }

  func start(group: DispatchGroup) {
    group.enter()
    queue.async { [self] in
      let drained = pipe.fileHandleForReading.readDataToEndOfFile()
      lock.lock()
      data = drained
      lock.unlock()
      group.leave()
    }
  }

  func stringValue() -> String {
    lock.lock()
    let data = data
    lock.unlock()
    return String(data: data, encoding: .utf8) ?? ""
  }

  func closeReading() {
    try? pipe.fileHandleForReading.close()
  }
}

struct RielaWorkflowRunResultEnvelope<RootOutput: Decodable>: Decodable {
  var result: RielaWorkflowRunResult<RootOutput>
}

struct RielaWorkflowRunResult<RootOutput: Decodable>: Decodable {
  var rootOutput: RootOutput?
}

func rielaWorkflowRunRootOutput<RootOutput: Decodable>(
  from output: String,
  as rootOutputType: RootOutput.Type
) -> RootOutput? {
  let decoder = JSONDecoder()
  for line in output.split(separator: "\n").reversed() {
    guard let data = line.data(using: .utf8),
          let envelope = try? decoder.decode(
            RielaWorkflowRunResultEnvelope<RootOutput>.self,
            from: data
          ),
          let rootOutput = envelope.result.rootOutput else {
      continue
    }
    return rootOutput
  }
  return nil
}

func resolvedRielaExecutablePath(
  _ configuredPath: String?,
  environment: [String: String],
  allowEnvironmentOverrides: Bool = false
) -> String? {
  if let configuredPath,
     rielaWorkflowExecutablePathIsTrusted(configuredPath) {
    return URL(fileURLWithPath: configuredPath).standardized.path
  }
  if allowEnvironmentOverrides,
     let environmentPath = environment["RIELA_APP_RIELA_EXECUTABLE"],
     rielaWorkflowExecutablePathIsTrusted(environmentPath) {
    return URL(fileURLWithPath: environmentPath).standardized.path
  }
  if let sibling = Bundle.main.executableURL?
    .deletingLastPathComponent()
    .appendingPathComponent("riela")
    .path,
    rielaWorkflowExecutablePathIsTrusted(sibling) {
    return sibling
  }
  return nil
}

func defaultWorkflowDirectoryCandidates(
  environment: [String: String],
  workflowDirectoryEnvironmentName: String,
  allowEnvironmentOverrides: Bool = false
) -> [String] {
  var candidates: [String] = []
  if allowEnvironmentOverrides,
     let configured = environment[workflowDirectoryEnvironmentName]?.trimmingCharacters(in: .whitespacesAndNewlines),
     !configured.isEmpty,
     configured.hasPrefix("/") {
    let standardized = URL(fileURLWithPath: configured, isDirectory: true).standardized.path
    candidates.append(standardized)
  }
  if let resource = Bundle.main.resourceURL?.appendingPathComponent("examples", isDirectory: true).path {
    candidates.append(resource)
  }
  return candidates
}

func rielaWorkflowSanitizedEnvironment(from environment: [String: String]) -> [String: String] {
  var sanitized: [String: String] = [:]
  let exactKeys: Set<String> = [
    "HOME",
    "LANG",
    "LOGNAME",
    "PATH",
    "SHELL",
    "TMPDIR",
    "USER",
    "XPC_SERVICE_NAME"
  ]
  // Model-auth / agent-discovery variables that the spawned `riela workflow
  // run` forwards to its executionBackend:codex-agent node. The inner codex
  // process derives its environment from this scrubbed parent, and env-based
  // auth (OPENAI_API_KEY, ANTHROPIC_API_KEY/CLAUDE_API_KEY, CURSOR_API_KEY,
  // custom CODEX_HOME, …) is a first-class supported path. Dropping these
  // breaks real rewrites/link-proposals for env-key users, so they must
  // survive sanitization while genuinely unrelated/sensitive vars are still
  // dropped.
  let modelAuthKeys: Set<String> = [
    "OPENAI_API_KEY",
    "OPENAI_BASE_URL",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_BASE_URL",
    "CLAUDE_API_KEY",
    "CLAUDE_CONFIG_DIR",
    "CURSOR_API_KEY",
    "CURSOR_AUTH_TOKEN",
    "CURSOR_BASE_URL",
    "CURSOR_CONFIG_DIR",
    "GEMINI_API_KEY",
    "GEMINI_BASE_URL",
    "GOOGLE_API_KEY",
    "CODEX_HOME",
    "RIELA_CODEX_AGENT_EXECUTABLE",
    "RIELA_CLAUDE_CODE_AGENT_EXECUTABLE",
    "RIELA_CURSOR_CLI_AGENT_EXECUTABLE"
  ]
  for (key, value) in environment {
    if exactKeys.contains(key) || modelAuthKeys.contains(key) || key.hasPrefix("LC_") {
      sanitized[key] = value
    }
  }
  return sanitized
}

func rielaWorkflowWaitForDrain(
  _ drainGroup: DispatchGroup,
  drains: [RielaWorkflowPipeDrain],
  timeoutSeconds: TimeInterval = 2
) {
  guard drainGroup.wait(timeout: .now() + timeoutSeconds) == .timedOut else {
    return
  }
  drains.forEach { $0.closeReading() }
}

private func rielaWorkflowExecutablePathIsTrusted(_ path: String) -> Bool {
  let url = URL(fileURLWithPath: path).standardized
  return url.path.hasPrefix("/")
    && url.lastPathComponent == "riela"
    && FileManager.default.isExecutableFile(atPath: url.path)
}

extension Process {
  func terminateWithEscalation(graceSeconds: TimeInterval = 1) {
    guard isRunning else {
      return
    }
    terminate()
    let deadline = Date().addingTimeInterval(graceSeconds)
    while isRunning && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    if isRunning {
      kill(processIdentifier, SIGKILL)
    }
  }
}
#endif
