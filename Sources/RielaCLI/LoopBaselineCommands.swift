import Foundation
import RielaCore

public struct LoopBaselineCommandResult: Codable, Equatable, Sendable {
  public var action: String
  public var workflowId: String
  public var sessionId: String?
  public var setAt: Date?
  public var note: String?
  public var existed: Bool?
  public var diagnostics: [String]

  public init(
    action: String,
    workflowId: String,
    sessionId: String? = nil,
    setAt: Date? = nil,
    note: String? = nil,
    existed: Bool? = nil,
    diagnostics: [String] = []
  ) {
    self.action = action
    self.workflowId = workflowId
    self.sessionId = sessionId
    self.setAt = setAt
    self.note = note
    self.existed = existed
    self.diagnostics = diagnostics
  }
}

/// `loop regress` output: the S10 verdict plus the pinned exit code
/// (0 no-regression / 3 regression / 4 missing baseline-or-evidence / 1
/// operational error).
public struct LoopRegressCommandResult: Codable, Equatable, Sendable {
  public var workflowId: String
  public var verdict: String
  public var baselineSessionId: String?
  public var targetSessionId: String?
  public var regressions: [LoopRegression]
  public var diff: LoopEvidenceDiff?
  public var diagnostics: [String]
  public var exitCode: Int32

  public init(
    workflowId: String,
    verdict: String,
    baselineSessionId: String? = nil,
    targetSessionId: String? = nil,
    regressions: [LoopRegression] = [],
    diff: LoopEvidenceDiff? = nil,
    diagnostics: [String] = [],
    exitCode: Int32
  ) {
    self.workflowId = workflowId
    self.verdict = verdict
    self.baselineSessionId = baselineSessionId
    self.targetSessionId = targetSessionId
    self.regressions = regressions
    self.diff = diff
    self.diagnostics = diagnostics
    self.exitCode = exitCode
  }
}

/// `loop baseline set/show/clear`, `loop regress`, and the
/// `loop diff --baseline` sugar (design S10). Baseline writes are the only
/// mutation; every other path stays read-only.
extension LoopCommandRunner {
  struct ParsedBaselineOptions {
    var sessionId: String?
    var note: String?
    var force = false
    var scope = WorkflowScope.auto
    var workingDirectory = FileManager.default.currentDirectoryPath
    var sessionStore: String?
  }

  func runBaseline(_ command: LoopCommand) -> CLICommandResult {
    guard let workflowId = command.options.target, !workflowId.isEmpty else {
      return CLICommandResult(exitCode: .usage, stderr: "loop baseline requires a workflow id")
    }
    guard let action = command.options.arguments.first, ["set", "show", "clear"].contains(action) else {
      return CLICommandResult(
        exitCode: .usage,
        stderr: "usage: riela loop baseline set|show|clear <workflow> [<session-id>] [--note <text>] [--force]"
      )
    }
    do {
      let parsed = try parseBaselineOptions(Array(command.options.arguments.dropFirst()))
      switch action {
      case "set":
        return try runBaselineSet(workflowId: workflowId, parsed: parsed, output: command.options.output)
      case "show":
        return try runBaselineShow(workflowId: workflowId, parsed: parsed, output: command.options.output)
      default:
        return try runBaselineClear(workflowId: workflowId, parsed: parsed, output: command.options.output)
      }
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch {
      return baselineFailure(workflowId: workflowId, command: "baseline", error: error, output: command.options.output)
    }
  }

  func runRegress(_ command: LoopCommand) -> CLICommandResult {
    guard let workflowId = command.options.target, !workflowId.isEmpty else {
      return CLICommandResult(exitCode: .usage, stderr: "loop regress requires a workflow id")
    }
    do {
      let parsed = try parseBaselineOptions(command.options.arguments, sessionViaFlagOnly: true)
      let resolution = try resolveBaselinePair(workflowId: workflowId, parsed: parsed)
      switch resolution {
      case let .missing(verdict, diagnostics):
        let result = LoopRegressCommandResult(
          workflowId: workflowId,
          verdict: verdict,
          regressions: [],
          diagnostics: diagnostics,
          exitCode: CLIExitCode.noLoopEvidence.rawValue
        )
        return try renderRegress(result, output: command.options.output)
      case let .resolved(pair):
        let verdict = LoopRegressionClassifier.verdict(
          base: pair.baseManifest,
          target: pair.targetManifest,
          requiredGateIds: pair.requiredGateIds
        )
        let exitCode: CLIExitCode = verdict.hasRegression ? .gateCheckFailed : .success
        let result = LoopRegressCommandResult(
          workflowId: workflowId,
          verdict: verdict.hasRegression ? "regressed" : "no-regression",
          baselineSessionId: verdict.baselineSessionId,
          targetSessionId: verdict.targetSessionId,
          regressions: verdict.regressions,
          diff: verdict.diff,
          diagnostics: verdict.diagnostics,
          exitCode: exitCode.rawValue
        )
        return try renderRegress(result, output: command.options.output)
      }
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch {
      return baselineFailure(workflowId: workflowId, command: "regress", error: error, output: command.options.output)
    }
  }

  /// `loop diff --baseline <workflow> [--session <id>]`: resolves the same
  /// baseline/target pair as `loop regress` and delegates to the ordinary
  /// diff rendering.
  func runBaselineDiff(_ command: LoopCommand) throws -> CLICommandResult {
    guard let workflowId = command.options.target, !workflowId.isEmpty else {
      throw CLIUsageError("loop diff --baseline requires a workflow id")
    }
    let arguments = Array(command.options.arguments.dropFirst()) // drop the --baseline marker
    let parsed = try parseBaselineOptions(arguments, sessionViaFlagOnly: true)
    switch try resolveBaselinePair(workflowId: workflowId, parsed: parsed) {
    case let .missing(verdict, diagnostics):
      throw CLIUsageError("loop diff --baseline: \(verdict): \(diagnostics.joined(separator: "; "))")
    case let .resolved(pair):
      let diff = LoopEvidenceDiffer.diff(base: pair.baseManifest, target: pair.targetManifest)
      switch command.options.output {
      case .json, .jsonl:
        return CLICommandResult(exitCode: .success, stdout: try jsonString(diff))
      case .text, .table:
        return CLICommandResult(exitCode: .success, stdout: Self.diffTextLines(diff).joined(separator: "\n") + "\n")
      }
    }
  }

  // MARK: - Baseline actions

  private func runBaselineSet(
    workflowId: String,
    parsed: ParsedBaselineOptions,
    output: WorkflowOutputFormat
  ) throws -> CLICommandResult {
    guard let sessionId = parsed.sessionId else {
      throw CLIUsageError("loop baseline set requires a session id: loop baseline set <workflow> <session-id>")
    }
    let inspection = ParsedOptions(
      scope: parsed.scope,
      workingDirectory: parsed.workingDirectory,
      sessionStore: parsed.sessionStore
    )
    let rendered = try snapshotForRendering(kind: .evidence, sessionId: sessionId, parsed: inspection)
    let snapshot = rendered.snapshot
    guard snapshot.session.workflowId == workflowId else {
      throw CLIUsageError(
        "session '\(sessionId)' belongs to workflow '\(snapshot.session.workflowId)', not '\(workflowId)'"
      )
    }
    guard let manifest = snapshot.loopEvidence else {
      throw CLIUsageError("session '\(sessionId)' has no loop evidence; cannot set it as a baseline")
    }
    var diagnostics: [String] = []
    let requiredGateIds = try requiredGateIds(forSessionId: sessionId, parsed: parsed)
    let evaluation = Self.evaluateRequiredGates(requiredGateIds: requiredGateIds, gates: manifest.gates)
    var note = parsed.note
    if !evaluation.allAccepted {
      guard parsed.force else {
        throw CLIUsageError(
          "session '\(sessionId)' has required gates not accepted (\(evaluation.failing.joined(separator: ", "))); use --force to record it anyway"
        )
      }
      let override = "forced baseline: required gates not accepted (\(evaluation.failing.joined(separator: ", ")))"
      diagnostics.append(override)
      note = [override, note].compactMap { $0 }.joined(separator: "; ")
    }
    let storeRoot = try baselineStoreRoot(forSessionId: sessionId, parsed: parsed)
    let baseline = LoopBaseline(workflowId: workflowId, sessionId: sessionId, setAt: Date(), note: note)
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: storeRoot).setLoopBaseline(baseline)
    return try renderBaseline(
      LoopBaselineCommandResult(
        action: "set",
        workflowId: workflowId,
        sessionId: sessionId,
        setAt: baseline.setAt,
        note: note,
        diagnostics: diagnostics
      ),
      output: output
    )
  }

  private func runBaselineShow(
    workflowId: String,
    parsed: ParsedBaselineOptions,
    output: WorkflowOutputFormat
  ) throws -> CLICommandResult {
    guard let (baseline, _) = try loadBaseline(workflowId: workflowId, parsed: parsed) else {
      let result = LoopBaselineCommandResult(
        action: "show",
        workflowId: workflowId,
        existed: false,
        diagnostics: ["no baseline recorded for workflow '\(workflowId)'"]
      )
      return try renderBaseline(result, output: output, exitCode: .noLoopEvidence)
    }
    return try renderBaseline(
      LoopBaselineCommandResult(
        action: "show",
        workflowId: workflowId,
        sessionId: baseline.sessionId,
        setAt: baseline.setAt,
        note: baseline.note,
        existed: true
      ),
      output: output
    )
  }

  private func runBaselineClear(
    workflowId: String,
    parsed: ParsedBaselineOptions,
    output: WorkflowOutputFormat
  ) throws -> CLICommandResult {
    var existed = false
    for root in baselineStoreRoots(parsed)
    where try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root).clearLoopBaseline(workflowId: workflowId) {
      existed = true
    }
    return try renderBaseline(
      LoopBaselineCommandResult(action: "clear", workflowId: workflowId, existed: existed),
      output: output
    )
  }

  // MARK: - Pair resolution

  struct BaselinePair {
    var baseManifest: LoopEvidenceManifest
    var targetManifest: LoopEvidenceManifest
    var requiredGateIds: Set<String>
  }

  enum BaselinePairResolution {
    case resolved(BaselinePair)
    case missing(verdict: String, diagnostics: [String])
  }

  func resolveBaselinePair(
    workflowId: String,
    parsed: ParsedBaselineOptions
  ) throws -> BaselinePairResolution {
    guard let (baseline, _) = try loadBaseline(workflowId: workflowId, parsed: parsed) else {
      return .missing(
        verdict: "no-baseline",
        diagnostics: ["no baseline recorded for workflow '\(workflowId)'; set one with `riela loop baseline set \(workflowId) <session-id>`"]
      )
    }
    let inspection = ParsedOptions(
      scope: parsed.scope,
      workingDirectory: parsed.workingDirectory,
      sessionStore: parsed.sessionStore
    )
    let baseSnapshot = try snapshotForRendering(kind: .evidence, sessionId: baseline.sessionId, parsed: inspection)
    guard let baseManifest = baseSnapshot.snapshot.loopEvidence else {
      return .missing(
        verdict: "no-baseline-evidence",
        diagnostics: ["baseline session '\(baseline.sessionId)' has no loop evidence"]
      )
    }
    let targetSessionId: String
    if let explicit = parsed.sessionId {
      targetSessionId = explicit
    } else {
      guard let newest = try newestCompletedSessionWithEvidence(workflowId: workflowId, parsed: parsed) else {
        return .missing(
          verdict: "no-target-evidence",
          diagnostics: ["no completed session with loop evidence found for workflow '\(workflowId)'"]
        )
      }
      targetSessionId = newest
    }
    let targetSnapshot = try snapshotForRendering(kind: .evidence, sessionId: targetSessionId, parsed: inspection)
    guard let targetManifest = targetSnapshot.snapshot.loopEvidence else {
      return .missing(
        verdict: "no-target-evidence",
        diagnostics: ["target session '\(targetSessionId)' has no loop evidence"]
      )
    }
    let requiredGateIds = Set(try requiredGateIds(forSessionId: targetSessionId, parsed: parsed))
    return .resolved(BaselinePair(
      baseManifest: baseManifest,
      targetManifest: targetManifest,
      requiredGateIds: requiredGateIds
    ))
  }

  private func newestCompletedSessionWithEvidence(
    workflowId: String,
    parsed: ParsedBaselineOptions
  ) throws -> String? {
    let overviews = try loadOverviews(ParsedOverviewOptions(
      scope: parsed.scope,
      workingDirectory: parsed.workingDirectory,
      sessionStore: parsed.sessionStore,
      workflowId: workflowId,
      status: "completed",
      gateDecision: nil,
      limit: 50
    ))
    return overviews.first(where: \.loopEvidenceRecorded)?.sessionId
  }

  /// Resolves the authored required gate ids for the session's workflow, the
  /// same way `loop gates --check` does (persisted resolution → workflow
  /// bundle). SQLite snapshots do not rehydrate `loopMetadata`, so authored
  /// metadata is the requiredness source of truth here.
  private func requiredGateIds(
    forSessionId sessionId: String,
    parsed: ParsedBaselineOptions
  ) throws -> [String] {
    let loaded = try CLIWorkflowSessionResolution.loadPersistedSession(
      sessionId: sessionId,
      sessionStore: parsed.sessionStore,
      scope: parsed.scope,
      workingDirectory: parsed.workingDirectory
    )
    let resolution = CLIWorkflowSessionResolution.effectiveResolution(
      persisted: loaded.record,
      scope: parsed.scope,
      workflowDefinitionDir: nil,
      workingDirectory: parsed.workingDirectory
    )
    let bundle = try FileSystemWorkflowBundleResolver().resolve(resolution)
    return (bundle.workflow.loop?.gates ?? [])
      .filter(\.required)
      .map(\.id)
      .sorted()
  }

  private func loadBaseline(
    workflowId: String,
    parsed: ParsedBaselineOptions
  ) throws -> (LoopBaseline, storeRoot: String)? {
    for root in baselineStoreRoots(parsed) {
      if let baseline = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root)
        .loadLoopBaseline(workflowId: workflowId) {
        return (baseline, root)
      }
    }
    return nil
  }

  private func baselineStoreRoot(forSessionId sessionId: String, parsed: ParsedBaselineOptions) throws -> String {
    let loaded = try CLIWorkflowSessionResolution.loadPersistedSession(
      sessionId: sessionId,
      sessionStore: parsed.sessionStore,
      scope: parsed.scope,
      workingDirectory: parsed.workingDirectory
    )
    return canonicalRuntimeStoreRoot(sessionStoreRoot: loaded.storeRoot)
  }

  private func baselineStoreRoots(_ parsed: ParsedBaselineOptions) -> [String] {
    let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
    let scopes: [WorkflowScope]
    if parsed.sessionStore != nil || environment["RIELA_SESSION_STORE"]?.isEmpty == false {
      scopes = [parsed.scope]
    } else {
      switch parsed.scope {
      case .auto:
        scopes = [.project, .user]
      case .project, .direct:
        scopes = [.project]
      case .user:
        scopes = [.user]
      }
    }
    var seen: Set<String> = []
    return scopes.compactMap { scope in
      let root = CLIWorkflowSessionStore.resolveRootDirectory(
        sessionStore: parsed.sessionStore,
        scope: scope,
        workingDirectory: parsed.workingDirectory,
        environment: environment
      )
      let canonical = canonicalRuntimeStoreRoot(sessionStoreRoot: root)
      guard seen.insert(canonical).inserted else {
        return nil
      }
      return canonical
    }
  }

  // MARK: - Parsing and rendering

  func parseBaselineOptions(
    _ arguments: [String],
    sessionViaFlagOnly: Bool = false
  ) throws -> ParsedBaselineOptions {
    var parsed = ParsedBaselineOptions()
    var index = 0
    while index < arguments.count {
      let token = arguments[index]
      switch token {
      case "--session":
        parsed.sessionId = try readRequiredOption(token, arguments: arguments, index: &index)
      case "--note":
        parsed.note = try readRequiredOption(token, arguments: arguments, index: &index)
      case "--force":
        parsed.force = true
        index += 1
      case "--scope":
        let raw = try readRequiredOption(token, arguments: arguments, index: &index)
        guard let value = WorkflowScope(rawValue: raw), value != .direct else {
          throw CLIUsageError("invalid --scope value '\(raw)'; expected auto, project, or user")
        }
        parsed.scope = value
      case "--working-dir", "--working-directory":
        parsed.workingDirectory = try readRequiredOption(token, arguments: arguments, index: &index)
      case "--session-store":
        parsed.sessionStore = try readRequiredOption(token, arguments: arguments, index: &index)
      case "--output":
        _ = try readRequiredOption(token, arguments: arguments, index: &index)
      default:
        if token.hasPrefix("--output=") {
          index += 1
        } else if !token.hasPrefix("--"), parsed.sessionId == nil, !sessionViaFlagOnly {
          parsed.sessionId = token
          index += 1
        } else {
          throw CLIUsageError("unsupported loop baseline option '\(token)'")
        }
      }
    }
    return parsed
  }

  private func renderBaseline(
    _ result: LoopBaselineCommandResult,
    output: WorkflowOutputFormat,
    exitCode: CLIExitCode = .success
  ) throws -> CLICommandResult {
    switch output {
    case .json, .jsonl:
      return CLICommandResult(exitCode: exitCode, stdout: try jsonString(result))
    case .text, .table:
      var lines = [
        "action: \(result.action)",
        "workflow: \(result.workflowId)"
      ]
      if let sessionId = result.sessionId {
        lines.append("session: \(sessionId)")
      }
      if let note = result.note {
        lines.append("note: \(note)")
      }
      if let existed = result.existed {
        lines.append("existed: \(existed)")
      }
      lines += result.diagnostics.map { "diagnostic: \($0)" }
      return CLICommandResult(exitCode: exitCode, stdout: lines.joined(separator: "\n") + "\n")
    }
  }

  private func renderRegress(
    _ result: LoopRegressCommandResult,
    output: WorkflowOutputFormat
  ) throws -> CLICommandResult {
    let exitCode = CLIExitCode(rawValue: result.exitCode) ?? .failure
    switch output {
    case .json, .jsonl:
      return CLICommandResult(exitCode: exitCode, stdout: try jsonString(result))
    case .text, .table:
      var lines = [
        "workflow: \(result.workflowId)",
        "verdict: \(result.verdict)"
      ]
      if let baseline = result.baselineSessionId {
        lines.append("baseline: \(baseline)")
      }
      if let target = result.targetSessionId {
        lines.append("target: \(target)")
      }
      for regression in result.regressions {
        let gate = regression.gateId.map { " [\($0)]" } ?? ""
        lines.append("regression: \(regression.kind)\(gate): \(regression.detail)")
      }
      lines += result.diagnostics.map { "diagnostic: \($0)" }
      return CLICommandResult(exitCode: exitCode, stdout: lines.joined(separator: "\n") + "\n")
    }
  }

  private func baselineFailure(
    workflowId: String,
    command: String,
    error: any Error,
    output: WorkflowOutputFormat
  ) -> CLICommandResult {
    guard output.isStructured else {
      return CLICommandResult(exitCode: .failure, stderr: "\(error)")
    }
    let payload = LoopCommandFailureResult(
      sessionId: workflowId,
      command: command,
      error: "\(error)",
      exitCode: CLIExitCode.failure.rawValue
    )
    return CLICommandResult(exitCode: .failure, stdout: (try? jsonString(payload)) ?? "")
  }
}
