import ArgumentParser
import Foundation
import RielaCore
import RielaSQLite
#if os(macOS)
import RielaAppSupport
#endif

struct ParsedSessionMonitorArguments: ParsableArguments {
  @Option(help: "Workflow id whose root executions are monitored.")
  var workflow: String
  @Option(help: "Unhealthy when the newest completed root execution is older than this.")
  var maxOutputAgeSeconds: Int
  @Option var scope = "project"
  @Option var sessionStore: String?
  @Option var workingDir: String?
  @Option(help: "Event root whose receipts prove the scheduler is ticking.")
  var eventRoot: String?
  @Option(help: "Unhealthy when the newest receipt in --event-root is older than this.")
  var schedulerMaxSilenceSeconds: Int?
  @Option(help: "Only count receipts of this event source id.")
  var eventSource: String?
  @Flag(help: "Report app_unavailable when RielaApp is not running or does not answer (macOS).")
  var requireApp = false
  @Option var appProfile: String?
  @Option(help: "Upper bound for each store, receipt and App probe.")
  var timeoutSeconds = 10
  @Option var output = "json"
}

/// The verdict of one bounded, read-only monitoring check.
enum SessionMonitorVerdict: String, Codable, Sendable {
  /// Fresh completed output, and every requested dependency is up.
  case healthy
  /// Output is older than the limit but a live root execution is in progress.
  case running
  /// Output is older than the limit and nothing is running.
  case staleOutput = "stale_output"
  /// The scheduler wrote no receipt within the allowed silence.
  case schedulerUnavailable = "scheduler_unavailable"
  /// `--require-app` and RielaApp is not running or does not answer.
  case appUnavailable = "app_unavailable"
  /// The check itself could not complete (store or receipts unreadable or stalled).
  case checkFailed = "check_failed"

  var exitCode: CLIExitCode {
    switch self {
    case .healthy, .running: .success
    case .checkFailed: .failure
    case .staleOutput, .schedulerUnavailable, .appUnavailable: .gateCheckFailed
    }
  }
}

struct SessionMonitorReport: Codable, Equatable, Sendable {
  struct Execution: Codable, Equatable, Sendable {
    var sessionId: String
    var status: String
    var updatedAt: Date
  }

  struct Store: Codable, Equatable, Sendable {
    var path: String
    var lastCompleted: Execution?
    var latestTerminal: Execution?
    var outputAgeSeconds: Int?
    var liveSessionIds: [String]
    /// `running`/`created` records whose runner is gone (no execution lock);
    /// reconcile them with `riela session reconcile --apply`.
    var orphanedSessionIds: [String]
  }

  struct Scheduler: Codable, Equatable, Sendable {
    var eventRoot: String
    var lastReceiptAt: Date?
    var lastReceiptStatus: String?
    var silenceSeconds: Int?
  }

  struct App: Codable, Equatable, Sendable {
    /// `running`, `not_running`, `unresponsive`, `busy`, or `unsupported`.
    var state: String
    var detail: String?
  }

  var verdict: SessionMonitorVerdict
  var reasons: [String]
  var workflowId: String
  var checkedAt: Date
  var maxOutputAgeSeconds: Int
  var store: Store?
  var scheduler: Scheduler?
  var app: App?
}

/// `riela session monitor`: an App-independent, bounded, read-only health
/// check meant to run from an external scheduler (launchd, systemd, cron).
/// It never launches, cancels or restarts anything.
struct SessionMonitorCommandRunner {
  var now: @Sendable () -> Date = { Date() }
  var appProbe: (@Sendable (_ profile: String?, _ timeout: TimeInterval, _ environment: [String: String]) async
    -> SessionMonitorReport.App)?

  func run(_ arguments: [String]) async -> CLICommandResult {
    if arguments.contains("--help") || arguments.contains("-h") {
      return CLICommandResult(exitCode: .success, stdout: Self.helpText + "\n")
    }
    let parsed: ParsedSessionMonitorArguments
    do {
      do {
        parsed = try ParsedSessionMonitorArguments.parse(arguments)
      } catch {
        throw CLIUsageError(ParsedSessionMonitorArguments.message(for: error))
      }
      try validate(parsed)
    } catch {
      let message = (error as? CLIUsageError)?.message ?? String(describing: error)
      return CLICommandResult(exitCode: .usage, stdout: "", stderr: message)
    }
    let report = await check(parsed)
    return render(report, output: parsed.output)
  }

  private func validate(_ parsed: ParsedSessionMonitorArguments) throws {
    guard !parsed.workflow.isEmpty, parsed.workflow.utf8.count <= 256 else {
      throw CLIUsageError("session monitor --workflow must be 1-256 bytes")
    }
    guard (1...31_536_000).contains(parsed.maxOutputAgeSeconds) else {
      throw CLIUsageError("--max-output-age-seconds must be between 1 and 31536000")
    }
    guard (1...300).contains(parsed.timeoutSeconds) else {
      throw CLIUsageError("--timeout-seconds must be between 1 and 300")
    }
    guard ["project", "user"].contains(parsed.scope) else {
      throw CLIUsageError("session monitor --scope must be project or user")
    }
    guard ["json", "text"].contains(parsed.output) else {
      throw CLIUsageError("session monitor --output must be json or text")
    }
    if parsed.schedulerMaxSilenceSeconds != nil, parsed.eventRoot == nil {
      throw CLIUsageError("--scheduler-max-silence-seconds requires --event-root")
    }
    if parsed.eventRoot != nil, parsed.schedulerMaxSilenceSeconds == nil {
      throw CLIUsageError("--event-root requires --scheduler-max-silence-seconds")
    }
    if let silence = parsed.schedulerMaxSilenceSeconds, !(1...31_536_000).contains(silence) {
      throw CLIUsageError("--scheduler-max-silence-seconds must be between 1 and 31536000")
    }
  }

  func check(_ parsed: ParsedSessionMonitorArguments) async -> SessionMonitorReport {
    let checkedAt = now()
    let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
    let workingDirectory = parsed.workingDir ?? FileManager.default.currentDirectoryPath
    let root = CLIWorkflowSessionStore.resolveRootDirectory(
      sessionStore: parsed.sessionStore,
      scope: WorkflowScope(rawValue: parsed.scope) ?? .project,
      workingDirectory: workingDirectory,
      environment: environment
    )
    let timeout = TimeInterval(parsed.timeoutSeconds)
    var report = SessionMonitorReport(verdict: .healthy, reasons: [], workflowId: parsed.workflow, checkedAt: checkedAt,
      maxOutputAgeSeconds: parsed.maxOutputAgeSeconds)
    var checkFailures: [String] = []

    let workflowId = parsed.workflow
    switch await BoundedSessionStoreIO.run(key: BoundedSessionStoreIO.key(sessionStoreRoot: root), timeout: timeout, {
      try Self.inspectStore(root: root, workflowId: workflowId)
    }) {
    case var .completed(.success(store)):
      if let completed = store.lastCompleted {
        store.outputAgeSeconds = max(0, Int(checkedAt.timeIntervalSince(completed.updatedAt)))
      }
      report.store = store
    case let .completed(.failure(error)):
      checkFailures.append("session store unreadable: \(error)")
    case .timedOut:
      checkFailures.append("session store did not respond within \(parsed.timeoutSeconds)s (volume unavailable or stalled?)")
    case .storeBusy:
      checkFailures.append("an earlier session store probe is still blocked (volume unavailable or stalled?)")
    }

    if let eventRoot = parsed.eventRoot, let maxSilence = parsed.schedulerMaxSilenceSeconds {
      let eventRootURL = URL(fileURLWithPath: eventRoot, relativeTo: URL(fileURLWithPath: workingDirectory)).standardizedFileURL
      let source = parsed.eventSource
      switch await BoundedSessionStoreIO.run(key: "receipts:" + eventRootURL.path, timeout: timeout, {
        EventReceiptStore(eventRoot: eventRootURL).listSkippingUnreadable()
          .filter { source == nil || $0.sourceId == source }
          .max { $0.updatedAt < $1.updatedAt }
      }) {
      case let .completed(.success(latest)):
        var scheduler = SessionMonitorReport.Scheduler(eventRoot: eventRootURL.path, lastReceiptAt: latest?.updatedAt,
          lastReceiptStatus: latest?.status, silenceSeconds: nil)
        if let at = latest?.updatedAt { scheduler.silenceSeconds = max(0, Int(checkedAt.timeIntervalSince(at))) }
        report.scheduler = scheduler
        if (scheduler.silenceSeconds ?? Int.max) > maxSilence {
          report.reasons.append(scheduler.silenceSeconds.map { "no scheduler receipt for \($0)s (limit \(maxSilence)s)" }
            ?? "no scheduler receipt recorded")
        }
      case let .completed(.failure(error)):
        checkFailures.append("event receipts unreadable: \(error)")
      case .timedOut, .storeBusy:
        checkFailures.append("event receipts did not respond within \(parsed.timeoutSeconds)s")
      }
    }

    if parsed.requireApp {
      let probe = appProbe ?? Self.probeApp
      let app = await probe(parsed.appProfile, timeout, environment)
      report.app = app
      if app.state != "running" {
        report.reasons.append("RielaApp \(app.state.replacingOccurrences(of: "_", with: " "))" + (app.detail.map { ": \($0)" } ?? ""))
      }
    }

    let outputStale: Bool
    if let store = report.store {
      outputStale = (store.outputAgeSeconds ?? Int.max) > parsed.maxOutputAgeSeconds
      if outputStale {
        report.reasons.append(store.outputAgeSeconds.map {
          "newest completed execution is \($0)s old (limit \(parsed.maxOutputAgeSeconds)s)"
        } ?? "no completed execution recorded")
      }
      if !store.orphanedSessionIds.isEmpty {
        report.reasons.append("\(store.orphanedSessionIds.count) running record(s) without a live runner; " +
          "reconcile with `riela session reconcile --apply`")
      }
    } else {
      outputStale = false
    }

    report.verdict = Self.verdict(
      checkFailed: !checkFailures.isEmpty,
      appDown: parsed.requireApp && report.app?.state != "running",
      schedulerSilent: report.scheduler.map { ($0.silenceSeconds ?? Int.max) > (parsed.schedulerMaxSilenceSeconds ?? Int.max) } ?? false,
      outputStale: outputStale,
      live: !(report.store?.liveSessionIds.isEmpty ?? true)
    )
    report.reasons = checkFailures + report.reasons
    return report
  }

  /// Priority: a check that could not run beats every other verdict; then the
  /// host, then the scheduler, then the output itself.
  static func verdict(checkFailed: Bool, appDown: Bool, schedulerSilent: Bool, outputStale: Bool,
                      live: Bool) -> SessionMonitorVerdict {
    if checkFailed { return .checkFailed }
    if appDown { return .appUnavailable }
    if schedulerSilent { return .schedulerUnavailable }
    if outputStale { return live ? .running : .staleOutput }
    return .healthy
  }

  /// Blocking: strict read-only store access. Call through `BoundedSessionStoreIO`.
  static func inspectStore(root: String, workflowId: String) throws -> SessionMonitorReport.Store {
    let runtimeRoot = canonicalRuntimeStoreRoot(sessionStoreRoot: root)
    let databasePath = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: runtimeRoot)
    var store = SessionMonitorReport.Store(path: root, lastCompleted: nil, latestTerminal: nil, outputAgeSeconds: nil,
      liveSessionIds: [], orphanedSessionIds: [])
    guard FileManager.default.fileExists(atPath: databasePath) else { return store }
    let db = try SQLiteDatabase.open(path: databasePath, mode: .strictReadOnly, options: .readOnlyDefault)
    guard try db.tableExists("workflow_runtime_snapshots") else { return store }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    func execution(_ row: SQLiteRow) -> SessionMonitorReport.Execution? {
      guard let id = row["workflow_execution_id"], let status = row["session_status"], let raw = row["updated_at"],
            let date = formatter.date(from: raw) ?? plain.date(from: raw) else { return nil }
      return .init(sessionId: id, status: status, updatedAt: date)
    }
    let base = "SELECT workflow_execution_id, session_status, updated_at FROM workflow_runtime_snapshots " +
      "WHERE workflow_id = ? AND parent_session_id IS NULL"
    store.lastCompleted = try db.query(base + " AND session_status = 'completed' ORDER BY updated_at DESC LIMIT 1",
      bindings: [.text(workflowId)]).first.flatMap(execution)
    store.latestTerminal = try db.query(base + " AND session_status IN ('completed', 'failed', 'cancelled') " +
      "ORDER BY updated_at DESC LIMIT 1", bindings: [.text(workflowId)]).first.flatMap(execution)
    let open = try db.query(base + " AND session_status IN ('created', 'running') ORDER BY updated_at DESC LIMIT 200",
      bindings: [.text(workflowId)]).compactMap { $0["workflow_execution_id"] }
    let live = Set(try LiveRootSessionProbe.liveRootSessions(workflowId: workflowId, sessionStoreRoot: root).map(\.sessionId))
    store.liveSessionIds = open.filter(live.contains).sorted()
    store.orphanedSessionIds = open.filter { !live.contains($0) }.sorted()
    return store
  }

  static func probeApp(profile: String?, timeout: TimeInterval, environment: [String: String]) async -> SessionMonitorReport.App {
    #if os(macOS)
    let appRoot = RielaAppAPIClient.appRoot(environment: environment)
    let expected: String
    do { expected = try RielaAppAPIClient.expectedProfile(explicit: profile, appRoot: appRoot) } catch {
      return .init(state: "not_running", detail: "invalid profile")
    }
    let outcome: RielaAppLocalControlProbe.Outcome
    do {
      outcome = try RielaAppLocalControlProbe.resolve(appRoot: appRoot)
    } catch let RielaAppControlChannelError.code(code) {
      return .init(state: code == .appChannelUnavailable ? "busy" : "unresponsive", detail: code.rawValue)
    } catch {
      return .init(state: "unresponsive", detail: String(describing: error))
    }
    switch outcome {
    case let .notRunning(lock):
      lock.release()
      return .init(state: "not_running", detail: nil)
    case .channel:
      // A bootstrap round trip proves the App's control queue answers, not
      // just that its socket accepts connections.
      let client = RielaAppControlChannelClient(socketURL: RielaAppRunDirectory(appRoot: appRoot).socketURL,
        connectTimeoutSeconds: min(2, timeout), responseTimeoutSeconds: timeout)
      do {
        let result = try await client.send(.bootstrap, profile: expected)
        guard (200..<300).contains(result.status) else {
          return .init(state: "unresponsive", detail: "bootstrap status \(result.status)")
        }
        return .init(state: "running", detail: nil)
      } catch let RielaAppControlChannelError.code(code) {
        return .init(state: "unresponsive", detail: code.rawValue)
      } catch {
        return .init(state: "unresponsive", detail: String(describing: error))
      }
    }
    #else
    return .init(state: "unsupported", detail: "RielaApp checks are macOS-only")
    #endif
  }

  private func render(_ report: SessionMonitorReport, output: String) -> CLICommandResult {
    if output == "text" {
      var lines = ["\(report.workflowId) \(report.verdict.rawValue)"]
      lines += report.reasons.map { "- \($0)" }
      return CLICommandResult(exitCode: report.verdict.exitCode, stdout: lines.joined(separator: "\n") + "\n")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let body = (try? encoder.encode(report)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    return CLICommandResult(exitCode: report.verdict.exitCode, stdout: body + "\n")
  }

  static var helpText: String {
    ParsedSessionMonitorArguments.helpMessage()
      .replacingOccurrences(of: "parsed-session-monitor-arguments", with: "riela session monitor")
      .replacingOccurrences(of: "parsed_session_monitor_arguments", with: "riela session monitor") + """


    Bounded, read-only health check for a scheduled workflow. Safe to run from
    launchd/systemd/cron independently of RielaApp: it never launches, cancels
    or restarts anything.

    Verdicts (exit code): healthy (0), running (0: output is stale but a live
    execution is in progress), stale_output (3), scheduler_unavailable (3),
    app_unavailable (3, only with --require-app), check_failed (1: the store or
    receipts could not be read within --timeout-seconds).
    """
  }
}
