import ArgumentParser
import Foundation
import RielaCore
import RielaSQLite

struct ParsedSessionReconcileArguments: ParsableArguments {
  @Option var scope = "project"
  @Option var sessionStore: String?
  @Option var workingDir: String?
  @Option(name: .customLong("session")) var sessionIds: [String] = []
  @Flag var apply = false
  @Option var abandonedAfterHours = 24
  @Option var output = "json"
}

private struct SessionReconcileEntry: Encodable {
  var sessionId: String
  var workflowId: String
  var verdict: String
  var applied: Bool
  var reason: String?
}

private struct SessionReconcileResult: Encodable {
  var dryRun: Bool
  var sessionStore: String
  var sessions: [SessionReconcileEntry]
  var nestedInvocations: [SessionNestedInvocationVerdict]
}

struct SessionReconcileCommandRunner {
  private static let cancellationReason = "runner process lost; reconciled by riela session reconcile"

  func run(_ arguments: [String]) -> CLICommandResult {
    if arguments.contains("--help") || arguments.contains("-h") {
      return CLICommandResult(exitCode: .success, stdout: helpText + "\n")
    }
    do {
      let parsed: ParsedSessionReconcileArguments
      do {
        parsed = try ParsedSessionReconcileArguments.parse(arguments)
      } catch {
        throw CLIUsageError(ParsedSessionReconcileArguments.message(for: error))
      }
      guard ["project", "user"].contains(parsed.scope) else {
        throw CLIUsageError("session reconcile --scope must be project or user")
      }
      guard (1...8760).contains(parsed.abandonedAfterHours) else {
        throw CLIUsageError("--abandoned-after-hours must be between 1 and 8760")
      }
      guard ["json", "text"].contains(parsed.output) else {
        throw CLIUsageError("session reconcile --output must be json or text")
      }
      let workingDirectory = parsed.workingDir ?? FileManager.default.currentDirectoryPath
      let root = CLIWorkflowSessionStore.resolveRootDirectory(
        sessionStore: parsed.sessionStore,
        scope: WorkflowScope(rawValue: parsed.scope) ?? .project,
        workingDirectory: workingDirectory
      )
      let runningActivity = try runningParentActivity(root: root)
      let sessions = try reconcile(root: root, selectedIds: parsed.sessionIds, apply: parsed.apply)
      let activityOverrides = Dictionary(uniqueKeysWithValues: sessions.compactMap { entry -> (String, Date)? in
        guard entry.verdict == "orphaned", entry.applied || !parsed.apply,
              let updatedAt = runningActivity[entry.sessionId] else { return nil }
        return (entry.sessionId, updatedAt)
      })
      let registry = SessionExecutionLockRegistry(sessionStoreRoot: root)
      let nested = try SessionAbandonedInvocationReconciler(registry: registry).run(
        sessionStoreRoot: root, abandonedAfter: TimeInterval(parsed.abandonedAfterHours * 3600), apply: parsed.apply,
        parentActivityOverrides: activityOverrides)
      return render(sessions: sessions, nested: nested, root: root, apply: parsed.apply, output: parsed.output)
    } catch {
      let message = (error as? CLIUsageError)?.message ?? String(describing: error)
      let data = (try? JSONEncoder().encode(["error": message])) ?? Data()
      return CLICommandResult(exitCode: error is CLIUsageError ? .usage : .failure,
        stdout: (String(data: data, encoding: .utf8) ?? "{}") + "\n")
    }
  }

  private func reconcile(root: String, selectedIds: [String], apply: Bool) throws -> [SessionReconcileEntry] {
    let candidates = try runningCandidates(root: root)
    let requested = Set(selectedIds)
    let candidateIds = selectedIds.isEmpty ? Set(candidates.keys) : Set(candidates.keys).intersection(requested)
    let registry = SessionExecutionLockRegistry(sessionStoreRoot: root)
    var entries = candidateIds.sorted().compactMap { sessionId -> SessionReconcileEntry? in
      guard let candidate = candidates[sessionId] else { return nil }
      return reconcile(sessionId: sessionId, workflowId: candidate, root: root, apply: apply, registry: registry)
    }
    for sessionId in requested.subtracting(candidateIds).sorted() {
      entries.append(SessionReconcileEntry(
        sessionId: sessionId, workflowId: "", verdict: "notRunning", applied: false, reason: nil
      ))
    }
    return entries.sorted { $0.sessionId < $1.sessionId }
  }

  private func runningCandidates(root: String) throws -> [String: String] {
    let databasePath = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root)
    guard FileManager.default.fileExists(atPath: databasePath) else { return [:] }
    let db = try SQLiteDatabase.open(path: databasePath, mode: .strictReadOnly, options: .readOnlyDefault)
    var candidates: [String: String] = [:]
    if try db.tableExists("cli_workflow_sessions") {
      for row in try db.query("SELECT session_id, workflow_id FROM cli_workflow_sessions WHERE status='running'") {
        guard let sessionId = row["session_id"] else { continue }
        candidates[sessionId] = row["workflow_id"] ?? ""
      }
    }
    if try db.tableExists("workflow_runtime_snapshots") {
      for row in try db.query("SELECT workflow_execution_id, workflow_id FROM workflow_runtime_snapshots WHERE session_status='running'") {
        guard let sessionId = row["workflow_execution_id"] else { continue }
        candidates[sessionId] = candidates[sessionId] ?? row["workflow_id"] ?? ""
      }
    }
    return candidates
  }

  private func runningParentActivity(root: String) throws -> [String: Date] {
    let candidates = try runningCandidates(root: root)
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root))
    var values: [String: Date] = [:]
    for id in candidates.keys {
      if let snapshot = try? store.load(sessionId: id) { values[id] = snapshot.session.updatedAt }
    }
    return values
  }

  private func reconcile(
    sessionId: String,
    workflowId: String,
    root: String,
    apply: Bool,
    registry: SessionExecutionLockRegistry
  ) -> SessionReconcileEntry {
    do {
      try registry.acquire(sessionId: sessionId)
    } catch SessionExecutionLockError.alreadyRunning {
      return SessionReconcileEntry(sessionId: sessionId, workflowId: workflowId, verdict: "live", applied: false, reason: nil)
    } catch SessionExecutionLockError.retiredSession {
      return SessionReconcileEntry(sessionId: sessionId, workflowId: workflowId, verdict: "retired", applied: false, reason: nil)
    } catch {
      return SessionReconcileEntry(sessionId: sessionId, workflowId: workflowId, verdict: "skipped", applied: false, reason: String(describing: error))
    }
    defer { registry.release(sessionId: sessionId) }
    guard apply else {
      return SessionReconcileEntry(sessionId: sessionId, workflowId: workflowId, verdict: "orphaned", applied: false, reason: nil)
    }
    do {
      let store = CLIWorkflowSessionStore(rootDirectory: root)
      let runtimeStore = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root))
      let cliRecord = try loadCLIRecord(sessionId: sessionId, store: store)
      let snapshot = try loadCanonicalSnapshot(sessionId: sessionId, store: runtimeStore)
      guard cliRecord != nil || snapshot != nil else {
        return SessionReconcileEntry(sessionId: sessionId, workflowId: workflowId, verdict: "skipped", applied: false, reason: "session changed during reconcile")
      }
      guard cliRecord.map({ $0.session.status == .running }) ?? true,
            snapshot.map({ $0.session.status == .running }) ?? true else {
        return SessionReconcileEntry(sessionId: sessionId, workflowId: workflowId, verdict: "skipped", applied: false, reason: "session changed during reconcile")
      }
      let now = Date()
      var updatedRecord = cliRecord
      var updatedSnapshot = snapshot
      if var record = updatedRecord {
        markCancelled(&record.session, at: now)
        updatedRecord = record
      }
      if var runtime = updatedSnapshot {
        markCancelled(&runtime.session, at: now)
        updatedSnapshot = runtime
      }
      if let updatedRecord, let updatedSnapshot {
        try store.save(updatedRecord, runtimeSnapshot: updatedSnapshot)
      } else if let updatedRecord {
        try store.save(updatedRecord)
      } else if let updatedSnapshot {
        try runtimeStore.save(updatedSnapshot)
      }
      return SessionReconcileEntry(sessionId: sessionId, workflowId: workflowId, verdict: "orphaned", applied: true, reason: Self.cancellationReason)
    } catch {
      return SessionReconcileEntry(sessionId: sessionId, workflowId: workflowId, verdict: "skipped", applied: false, reason: String(describing: error))
    }
  }

  private func loadCLIRecord(sessionId: String, store: CLIWorkflowSessionStore) throws -> PersistedCLIWorkflowSession? {
    do {
      return try store.load(sessionId: sessionId)
    } catch CLIWorkflowSessionStoreError.notFound {
      return nil
    }
  }

  private func loadCanonicalSnapshot(
    sessionId: String,
    store: SQLiteWorkflowRuntimePersistenceStore
  ) throws -> WorkflowRuntimePersistenceSnapshot? {
    do {
      return try store.load(sessionId: sessionId)
    } catch WorkflowRuntimePersistenceStoreError.notFound {
      return nil
    }
  }

  private func markCancelled(_ session: inout WorkflowSession, at date: Date) {
    session.status = .cancelled
    session.failureKind = .cancelled
    session.failureReason = Self.cancellationReason
    session.failedAt = date
    session.updatedAt = date
    for index in session.executions.indices where session.executions[index].status == .running {
      session.executions[index].status = .cancelled
      session.executions[index].failureReason = Self.cancellationReason
      session.executions[index].updatedAt = date
    }
  }

  private func render(sessions: [SessionReconcileEntry], nested: [SessionNestedInvocationVerdict], root: String,
                      apply: Bool, output: String) -> CLICommandResult {
    if output == "text" {
      let sessionLines = sessions.map { "\($0.sessionId) \($0.verdict)\($0.applied ? " applied" : "")\($0.reason.map { " (\($0))" } ?? "")" }
      let nestedLines = nested.map { "\($0.invocationKey) \($0.verdict)\($0.applied ? " applied" : "")\($0.reason.map { " (\($0))" } ?? "")" }
      let lines = sessionLines + nestedLines
      return CLICommandResult(exitCode: .success, stdout: lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
    }
    let result = SessionReconcileResult(dryRun: !apply, sessionStore: root, sessions: sessions, nestedInvocations: nested)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return CLICommandResult(exitCode: .success, stdout: (String(data: (try? encoder.encode(result)) ?? Data(), encoding: .utf8) ?? "{}") + "\n")
  }

  private var helpText: String {
    ParsedSessionReconcileArguments.helpMessage()
      .replacingOccurrences(of: "parsed-session-reconcile-arguments", with: "riela session reconcile")
      .replacingOccurrences(of: "parsed_session_reconcile_arguments", with: "riela session reconcile")
  }
}
