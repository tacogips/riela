import Foundation

#if os(macOS)
import Darwin

final class RielaWorkflowProcessBox: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  private var processGroupID: pid_t?
  private var cancelled = false

  func set(_ process: Process, processGroupID: pid_t? = nil) {
    lock.lock()
    self.process = process
    self.processGroupID = processGroupID
    lock.unlock()
  }

  func setProcessGroup(_ processGroupID: pid_t) {
    lock.lock()
    self.processGroupID = processGroupID
    let cancelled = self.cancelled
    lock.unlock()
    if cancelled {
      rielaWorkflowTerminateProcessGroup(processGroupID)
    }
  }

  func clearProcessGroup(_ processGroupID: pid_t) {
    lock.lock()
    if self.processGroupID == processGroupID {
      self.processGroupID = nil
    }
    lock.unlock()
  }

  func clear(_ process: Process) {
    lock.lock()
    if self.process === process {
      self.process = nil
      self.processGroupID = nil
    }
    lock.unlock()
  }

  /// True once `onCancel` has fired. Checked before launching the process and in
  /// the poll loop so a cancellation that races `process.run()` still surfaces as
  /// `CancellationError` and never orphans a workflow child.
  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func terminate() {
    lock.lock()
    cancelled = true
    let process = self.process
    let processGroupID = self.processGroupID
    lock.unlock()
    if let processGroupID {
      rielaWorkflowTerminateProcessGroup(processGroupID)
    } else {
      process?.terminateWithEscalation()
    }
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

/// A JSON variables payload written to a private scratch temp file, passed to
/// `riela workflow run --variables-file`. Note bodies can exceed `ARG_MAX`, so
/// they are never placed on argv; the file is deleted when this value is
/// discarded.
struct RielaWorkflowVariablesFile: Sendable {
  let path: String
  private let cleanup: RielaWorkflowFileCleanup

  init(variables: [String: Any], directory: URL? = nil) throws {
    let data = try JSONSerialization.data(withJSONObject: variables, options: [.sortedKeys])
    let directory = directory ?? FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-note-workflow", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("variables-\(UUID().uuidString).json")
    try data.write(to: fileURL, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    path = fileURL.path
    cleanup = RielaWorkflowFileCleanup(path: fileURL.path)
  }
}

/// Owns the complete per-run working directory, including Riela's session
/// database. Removing it at the end of every outcome prevents source note
/// bodies from surviving in workflow runtime records.
struct RielaWorkflowInvocationDirectory: Sendable {
  let rootURL: URL
  let sessionStorePath: String
  private let cleanup: RielaWorkflowFileCleanup

  init() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-note-workflow-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
    self.rootURL = rootURL
    self.sessionStorePath = rootURL.appendingPathComponent("sessions", isDirectory: true).path
    self.cleanup = RielaWorkflowFileCleanup(path: rootURL.path)
  }
}

/// Deletes a scratch file when the last reference is released, so the variables
/// temp file does not outlive the `riela workflow run` invocation.
private final class RielaWorkflowFileCleanup: @unchecked Sendable {
  private let path: String

  init(path: String) {
    self.path = path
  }

  deinit {
    try? FileManager.default.removeItem(atPath: path)
  }
}

/// Argv for `riela workflow run <workflow>` that reads its variables from
/// `variablesFilePath`. No note content is placed on argv.
func rielaWorkflowRunArguments(
  workflowName: String,
  workflowDefinitionDirectory: String,
  variablesFilePath: String,
  sessionStorePath: String? = nil
) -> [String] {
  var arguments = [
    "workflow",
    "run",
    workflowName,
    "--workflow-definition-dir",
    workflowDefinitionDirectory
  ]
  if let sessionStorePath {
    arguments.append(contentsOf: ["--session-store", sessionStorePath])
  }
  arguments.append(contentsOf: [
    "--variables-file",
    variablesFilePath,
    "--output",
    "jsonl"
  ])
  return arguments
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

func rielaWorkflowTerminateProcessGroup(
  _ processGroupID: pid_t,
  graceSeconds: TimeInterval = 1
) {
  _ = kill(-processGroupID, SIGTERM)
  let deadline = Date().addingTimeInterval(graceSeconds)
  while rielaWorkflowProcessGroupIsRunning(processGroupID) && Date() < deadline {
    Thread.sleep(forTimeInterval: 0.02)
  }
  if rielaWorkflowProcessGroupIsRunning(processGroupID) {
    _ = kill(-processGroupID, SIGKILL)
  }
}

func rielaWorkflowProcessGroupIsRunning(_ processGroupID: pid_t) -> Bool {
  if kill(-processGroupID, 0) == 0 {
    return true
  }
  return errno == EPERM
}
#endif
