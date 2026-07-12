import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RielaCore

/// Injectable webhook transport so dispatch behavior (timeout, retry,
/// failure isolation) is testable without a live server.
protocol LoopNotificationTransporting: Sendable {
  func post(url: URL, bearerToken: String?, body: Data, timeoutSeconds: TimeInterval) async throws
}

struct URLSessionLoopNotificationTransport: LoopNotificationTransporting {
  func post(url: URL, bearerToken: String?, body: Data, timeoutSeconds: TimeInterval) async throws {
    var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let bearerToken {
      request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    }
    let (_, response) = try await URLSession.shared.data(for: request)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      throw CLIUsageError("webhook responded with status \(http.statusCode)")
    }
  }
}

/// Best-effort terminal-outcome notification dispatch (design S12). Runs
/// after terminal persistence from the process that owns the run; bounded
/// timeout with one retry per channel; every attempt/delivery/skip/failure
/// becomes a diagnostic string. Dispatch failure never changes the session
/// outcome or the command exit code, and nothing is written into the
/// evidence manifest.
struct LoopNotificationDispatcher: Sendable {
  var transport: any LoopNotificationTransporting
  var environment: [String: String]
  var timeoutSeconds: TimeInterval
  /// Runs a command channel; injectable for tests. Returns the exit status.
  var commandRunner: @Sendable (_ argv: [String], _ stdin: Data, _ workingDirectory: String, _ timeoutSeconds: TimeInterval) async throws -> Int32

  init(
    transport: any LoopNotificationTransporting = URLSessionLoopNotificationTransport(),
    environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment(),
    timeoutSeconds: TimeInterval = 5,
    commandRunner: @escaping @Sendable (_ argv: [String], _ stdin: Data, _ workingDirectory: String, _ timeoutSeconds: TimeInterval) async throws -> Int32
      = LoopNotificationDispatcher.runProcessChannel
  ) {
    self.transport = transport
    self.environment = environment
    self.timeoutSeconds = timeoutSeconds
    self.commandRunner = commandRunner
  }

  /// Classifies the outcome and dispatches to every declared channel when
  /// the outcome is in the declared `on` set. Returns diagnostics; never
  /// throws.
  func dispatchIfDeclared(
    workflow: WorkflowDefinition,
    session: WorkflowSession,
    manifest: LoopEvidenceManifest?,
    workflowDirectory: String,
    workingDirectory: String
  ) async -> [String] {
    guard let notifications = workflow.loop?.notifications, !notifications.channels.isEmpty else {
      return []
    }
    let requiredGateIds = (workflow.loop?.gates ?? []).filter(\.required).map(\.id)
    guard let outcome = LoopOutcomeClassifier.outcome(
      session: session,
      manifest: manifest,
      requiredGateIds: requiredGateIds
    ) else {
      return []
    }
    guard notifications.on.contains(outcome.rawValue) else {
      return []
    }
    let payload = LoopOutcomeNotification.make(session: session, manifest: manifest, outcome: outcome)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    guard let body = try? encoder.encode(payload) else {
      return ["loop notification: failed to encode payload; nothing dispatched"]
    }
    var diagnostics: [String] = []
    for (index, channel) in notifications.channels.enumerated() {
      diagnostics += await dispatch(
        channel: channel,
        index: index,
        outcome: outcome,
        body: body,
        workflowDirectory: workflowDirectory,
        workingDirectory: workingDirectory
      )
    }
    return diagnostics
  }

  private func dispatch(
    channel: LoopNotificationChannelDeclaration,
    index: Int,
    outcome: LoopOutcome,
    body: Data,
    workflowDirectory: String,
    workingDirectory: String
  ) async -> [String] {
    let label = "loop notification channel[\(index)] (\(channel.type), outcome \(outcome.rawValue))"
    switch channel.type {
    case "webhook":
      guard let urlEnv = channel.urlEnv, let urlValue = environment[urlEnv], !urlValue.isEmpty else {
        return ["\(label): skipped — environment variable '\(channel.urlEnv ?? "?")' is not set"]
      }
      guard let url = URL(string: urlValue) else {
        return ["\(label): skipped — environment variable '\(urlEnv)' is not a valid URL"]
      }
      let bearer = channel.bearerTokenEnv.flatMap { environment[$0] }
      return await attemptWithRetry(label: label) {
        try await transport.post(url: url, bearerToken: bearer, body: body, timeoutSeconds: timeoutSeconds)
      }
    case "command":
      guard let executable = channel.argv.first, !executable.isEmpty else {
        return ["\(label): skipped — empty argv"]
      }
      // Workflow-relative resolution first; fall back to the argv as given
      // (absolute paths and PATH lookups).
      let workflowRelative = URL(fileURLWithPath: workflowDirectory, isDirectory: true)
        .appendingPathComponent(executable).path
      let resolved = FileManager.default.isExecutableFile(atPath: workflowRelative) ? workflowRelative : executable
      let argv = [resolved] + channel.argv.dropFirst()
      return await attemptWithRetry(label: label) {
        let status = try await commandRunner(argv, body, workingDirectory, timeoutSeconds)
        if status != 0 {
          throw CLIUsageError("notification command exited with status \(status)")
        }
      }
    default:
      return ["\(label): skipped — unknown channel type"]
    }
  }

  /// One retry, best-effort; failures become diagnostics.
  private func attemptWithRetry(label: String, _ body: () async throws -> Void) async -> [String] {
    var diagnostics = ["\(label): attempted"]
    for attempt in 1...2 {
      do {
        try await body()
        diagnostics.append("\(label): delivered on attempt \(attempt)")
        return diagnostics
      } catch {
        diagnostics.append("\(label): attempt \(attempt) failed — \(boundedWorkflowRunDiagnostic("\(error)", limit: 300))")
      }
    }
    return diagnostics
  }

  /// Executes a command channel with the payload on stdin and a bounded
  /// timeout; output beyond the exit status is discarded.
  @Sendable static func runProcessChannel(
    argv: [String],
    stdin: Data,
    workingDirectory: String,
    timeoutSeconds: TimeInterval
  ) async throws -> Int32 {
    let process = Process()
    if argv[0].contains("/") {
      process.executableURL = URL(fileURLWithPath: argv[0])
      process.arguments = Array(argv.dropFirst())
    } else {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = argv
    }
    process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
    let stdinPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    stdinPipe.fileHandleForWriting.write(stdin)
    stdinPipe.fileHandleForWriting.closeFile()

    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while process.isRunning {
      if Date() > deadline {
        process.terminate()
        throw CLIUsageError("notification command timed out after \(Int(timeoutSeconds))s")
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    return process.terminationStatus
  }
}
