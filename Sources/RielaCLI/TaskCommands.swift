import ArgumentParser
import Foundation
import RielaCore
import RielaWork

extension TaskCommandKind: ExpressibleByArgument {}

struct ParsedTaskFamily: RielaClientFamilyArguments {
  @Argument var subcommand: TaskCommandKind
  @Argument(parsing: .captureForPassthrough) var remainder: [String] = []
}

/// `riela task show` and `riela task list`: read-only projections of the Work
/// Runtime store (P0-6).
///
/// The store lives beside the runtime snapshots, so the options and the store
/// resolution are `LoopCommandRunner`'s: `--scope`, `--working-dir`,
/// `--session-store`, `--output`, resolved through
/// `canonicalRuntimeStoreRoot`. P2 reuses this parsing when the loop
/// inspections become task reads.
public struct TaskCommandRunner: Sendable {
  public init() {}

  public func run(_ command: TaskCommand) -> CLICommandResult {
    do {
      switch command.kind {
      case .show:
        return try runShow(command)
      case .list:
        return try runList(command)
      }
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch {
      if command.options.output.isStructured {
        let payload = TaskCommandFailureResult(
          taskId: command.options.target ?? "",
          command: command.kind.rawValue,
          error: "\(error)",
          exitCode: CLIExitCode.failure.rawValue
        )
        return CLICommandResult(exitCode: .failure, stdout: (try? jsonString(payload)) ?? "")
      }
      return CLICommandResult(exitCode: .failure, stderr: "\(error)")
    }
  }

  // MARK: - show

  private func runShow(_ command: TaskCommand) throws -> CLICommandResult {
    guard let taskId = command.options.target, !taskId.isEmpty else {
      throw CLIUsageError("task show requires a task id")
    }
    let parsed = try ParsedTaskShowOptions.resolve(command.options.arguments)
    let identifier = TaskID(taskId)
    guard let located = try locateTask(identifier, in: parsed) else {
      throw CLIUsageError("task '\(taskId)' was not found in \(storeRootSummary(parsed))")
    }
    let store = located.store
    let task = located.task
    let attempts = try store.listAttempts(taskId: identifier)
    let findings = try store.listFindings(taskId: identifier)
    let evidence = try store.listEvidence(taskId: identifier)
    let latest = attempts.last

    let result = TaskShowCommandResult(
      taskId: taskId,
      task: task,
      attempts: attempts,
      decisions: try store.listDecisions(taskId: identifier),
      findings: findings,
      evidence: EvidenceKind.allCases.compactMap { kind in
        let count = evidence.filter { $0.kind == kind }.count
        return count == 0 ? nil : TaskEvidenceCount(kind: kind, count: count)
      },
      completion: CompletionEvaluator.evaluate(
        contract: task.completion,
        attemptOutcome: latest?.outcome ?? AttemptOutcome(sessionStatus: .created),
        ledger: CompletionLedger(
          verification: verificationOutcomes(in: evidence),
          findings: findings,
          acceptance: acceptance(for: task, attempt: latest, storeRoot: located.root)
        )
      )
    )

    switch command.options.output {
    case .json, .jsonl:
      return CLICommandResult(exitCode: .success, stdout: try jsonString(result))
    case .text, .table:
      return CLICommandResult(exitCode: .success, stdout: Self.showTextLines(result).joined(separator: "\n") + "\n")
    }
  }

  /// A verification requirement is satisfied by the ledger record whose
  /// payload `id` equals the requirement name — the identity
  /// `LoopVerificationEvidence` already uses. `outcome: "passed"` is the only
  /// passing value; anything else, including an unrecognized one, fails.
  private func verificationOutcomes(in evidence: [Evidence]) -> [VerificationOutcome] {
    evidence.filter { $0.kind == .verification }.compactMap { record in
      guard let payload = record.payloadRef.inlinePayload,
            case let .string(name)? = payload["id"] else {
        return nil
      }
      var outcome = ""
      if case let .string(value)? = payload["outcome"] {
        outcome = value
      }
      return VerificationOutcome(name: name, passed: outcome == "passed", evidenceId: record.id)
    }
  }

  /// The acceptance judgement lives in the attempt's gate payload, so it is
  /// read from the persisted session snapshot. A snapshot that is gone (a
  /// garbage-collected run) reads as absent, which is not met.
  private func acceptance(for task: WorkTask, attempt: Attempt?, storeRoot: String) -> GateAcceptance? {
    guard !task.completion.acceptance.isEmpty, let attempt else {
      return nil
    }
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: storeRoot)
    guard let snapshot = try? store.load(sessionId: attempt.sessionId) else {
      return nil
    }
    return GateAcceptanceParser.acceptance(requiredGates: task.completion.gates, session: snapshot.session)
  }

  static func showTextLines(_ result: TaskShowCommandResult) -> [String] {
    var lines = [
      "taskId: \(result.taskId)",
      "title: \(result.task.title)",
      "state: \(result.task.state.rawValue)",
      "intentId: \(result.task.intentId.rawValue)",
      "workflow: \(result.task.plan?.workflowName ?? "none")",
      "version: \(result.task.version)",
      "attempts: \(result.attempts.count)",
      "decisions: \(result.decisions.count)",
      "openBlockingFindings: \(result.findings.filter(\.blocksCompletion).count)",
      "completion: \(completionCell(result.completion))"
    ]
    if let latest = result.attempts.last {
      lines.append("latestAttempt: \(latest.id.rawValue)")
      lines.append("latestSession: \(latest.sessionId)")
      lines.append("latestAttemptState: \(latest.state.rawValue)")
    }
    lines.append(contentsOf: result.evidence.map { "evidence.\($0.kind.rawValue): \($0.count)" })
    return lines
  }

  /// `satisfied`, or the unmet requirements named. Never a bare count: the
  /// point of the verdict is which requirement is missing.
  static func completionCell(_ verdict: CompletionVerdict) -> String {
    guard case let .unmet(requirements) = verdict else {
      return "satisfied"
    }
    return "unmet(" + requirements.map(describe).joined(separator: ", ") + ")"
  }

  private static func describe(_ requirement: UnmetRequirement) -> String {
    switch requirement {
    case let .gateNotAccepted(gateId): return "gate:\(gateId)"
    case let .verificationMissing(name): return "verification-missing:\(name)"
    case let .verificationFailed(name): return "verification-failed:\(name)"
    case let .openBlockingFinding(fingerprint): return "finding:\(fingerprint)"
    case .acceptanceNotMet: return "acceptance-not-met"
    case .acceptanceAbsent: return "acceptance-absent"
    case .humanAcceptRequired: return "human-accept-required"
    }
  }

  // MARK: - list

  private func runList(_ command: TaskCommand) throws -> CLICommandResult {
    let parsed = try ParsedTaskListOptions.resolve(command.options.arguments)
    // The store orders by `updated_at`, the merged output by task id, and
    // `--scope auto` reads two roots. Trimming per root against the store's
    // order would drop rows the merged order keeps, so the limit is applied
    // once, after the merge, against the order the caller actually sees.
    var storeFilter = parsed.filter
    storeFilter.limit = nil
    var summaries: [TaskSummary] = []
    var seen: Set<String> = []
    for root in storeRoots(parsed.shared) {
      let store = WorkStore(rootDirectory: root)
      for task in try store.listTasks(filter: storeFilter) where seen.insert(task.id.rawValue).inserted {
        let attempts = try store.listAttempts(taskId: task.id)
        summaries.append(TaskSummary(
          taskId: task.id.rawValue,
          intentId: task.intentId.rawValue,
          title: task.title,
          state: task.state,
          workflowId: task.plan?.workflowName,
          version: task.version,
          attemptCount: attempts.count,
          latestSessionId: attempts.last?.sessionId,
          openBlockingFindingCount: try store.listFindings(taskId: task.id).filter(\.blocksCompletion).count
        ))
      }
    }
    summaries.sort { lhs, rhs in
      lhs.taskId < rhs.taskId
    }
    if let limit = parsed.filter.limit {
      summaries = Array(summaries.prefix(limit))
    }

    switch command.options.output {
    case .json:
      return CLICommandResult(exitCode: .success, stdout: try jsonString(TaskListCommandResult(tasks: summaries)))
    case .jsonl:
      return CLICommandResult(exitCode: .success, stdout: try summaries.map(jsonString).joined())
    case .text, .table:
      let blocks = summaries.map { summary in
        [
          "taskId: \(summary.taskId)",
          "title: \(summary.title)",
          "state: \(summary.state.rawValue)",
          "workflow: \(summary.workflowId ?? "none")",
          "attempts: \(summary.attemptCount)",
          "openBlockingFindings: \(summary.openBlockingFindingCount)"
        ].joined(separator: "\n")
      }
      return CLICommandResult(
        exitCode: .success,
        stdout: blocks.joined(separator: "\n\n") + (blocks.isEmpty ? "" : "\n")
      )
    }
  }

  // MARK: - Store resolution

  private struct LocatedTask {
    var task: WorkTask
    var store: WorkStore
    var root: String
  }

  private func locateTask(_ id: TaskID, in options: TaskStoreOptions) throws -> LocatedTask? {
    for root in storeRoots(options) {
      let store = WorkStore(rootDirectory: root)
      if let task = try store.loadTask(id: id) {
        return LocatedTask(task: task, store: store, root: root)
      }
    }
    return nil
  }

  /// The same roots `riela loop list` reads: an explicit `--session-store` or
  /// `RIELA_SESSION_STORE` pins one root, and `--scope auto` reads the
  /// project store then the user store.
  private func storeRoots(_ options: TaskStoreOptions) -> [String] {
    sessionStoreRoots(options).map { canonicalRuntimeStoreRoot(sessionStoreRoot: $0) }
  }

  private func sessionStoreRoots(_ options: TaskStoreOptions) -> [String] {
    let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
    if options.sessionStore != nil || environment["RIELA_SESSION_STORE"]?.isEmpty == false {
      return [
        CLIWorkflowSessionStore.resolveRootDirectory(
          sessionStore: options.sessionStore,
          scope: options.scope,
          workingDirectory: options.workingDirectory,
          environment: environment
        )
      ]
    }
    let scopes: [WorkflowScope]
    switch options.scope {
    case .auto:
      scopes = [.project, .user]
    case .project, .direct:
      scopes = [.project]
    case .user:
      scopes = [.user]
    }
    var seen: Set<String> = []
    return scopes.compactMap { scope in
      let root = CLIWorkflowSessionStore.resolveRootDirectory(
        sessionStore: nil,
        scope: scope,
        workingDirectory: options.workingDirectory,
        environment: environment
      )
      return seen.insert(root).inserted ? root : nil
    }
  }

  private func storeRootSummary(_ options: TaskStoreOptions) -> String {
    storeRoots(options).joined(separator: ", ")
  }
}

private extension RielaClientFamilyArguments {
  static func resolveScope(_ raw: String) throws -> WorkflowScope {
    guard let scope = WorkflowScope(rawValue: raw), scope != .direct else {
      throw CLIUsageError("invalid --scope value '\(raw)'; expected auto, project, or user")
    }
    return scope
  }
}

/// Where a task read looks for its store.
struct TaskStoreOptions {
  var scope: WorkflowScope
  var workingDirectory: String
  var sessionStore: String?
}

/// `riela task show` flags. Declared at file scope, not nested, so
/// `CLISurfaceEnumerator.optionNames()` can render them: the catalog may only
/// document a flag some parser actually accepts.
struct ParsedTaskShowOptions: RielaClientFamilyArguments {
  @Option var scope = "auto"
  @Option(name: [.customLong("working-dir"), .customLong("working-directory")])
  var workingDirectory = FileManager.default.currentDirectoryPath
  @Option var sessionStore: String?
  @Option var output: String?

  static func resolve(_ arguments: [String]) throws -> TaskStoreOptions {
    let parsed = try parseCLI(arguments)
    return TaskStoreOptions(
      scope: try resolveScope(parsed.scope),
      workingDirectory: parsed.workingDirectory,
      sessionStore: parsed.sessionStore
    )
  }
}

/// `riela task list` flags: the shared read flags plus the store filters.
struct ParsedTaskListOptions: RielaClientFamilyArguments {
  @Option var scope = "auto"
  @Option(name: [.customLong("working-dir"), .customLong("working-directory")])
  var workingDirectory = FileManager.default.currentDirectoryPath
  @Option var sessionStore: String?
  @Option var state: String?
  @Option var intent: String?
  @Option var workflow: String?
  @Option var limit: Int?
  @Option var output: String?

  static func resolve(_ arguments: [String]) throws -> (shared: TaskStoreOptions, filter: TaskListFilter) {
    let parsed = try parseCLI(arguments)
    var state: TaskState?
    if let raw = parsed.state {
      guard let resolved = TaskState(rawValue: raw) else {
        throw CLIUsageError(
          "invalid --state value '\(raw)'; expected one of "
            + TaskState.allCases.map(\.rawValue).joined(separator: ", ")
        )
      }
      state = resolved
    }
    if let limit = parsed.limit, !(1...WorkStore.maximumListLimit).contains(limit) {
      throw CLIUsageError("--limit must be between 1 and \(WorkStore.maximumListLimit)")
    }
    return (
      TaskStoreOptions(
        scope: try resolveScope(parsed.scope),
        workingDirectory: parsed.workingDirectory,
        sessionStore: parsed.sessionStore
      ),
      TaskListFilter(
        state: state,
        intentId: parsed.intent.map(IntentID.init),
        workflowId: parsed.workflow,
        limit: parsed.limit
      )
    )
  }
}
