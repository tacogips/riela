import Foundation
import RielaCore

public struct LoopStatusCommandResult: Codable, Equatable, Sendable {
  public var sessionId: String
  public var workflowName: String
  public var sessionStatus: WorkflowSessionStatus
  public var loopEvidenceRecorded: Bool
  public var loopEvidence: LoopEvidenceSummary?
}

public struct LoopEvidenceCommandResult: Codable, Equatable, Sendable {
  public var sessionId: String
  public var workflowName: String
  public var loopEvidenceRecorded: Bool
  public var loopEvidence: LoopEvidenceManifest?
}

public struct LoopGatesCommandResult: Codable, Equatable, Sendable {
  public var sessionId: String
  public var workflowName: String
  public var loopEvidenceRecorded: Bool
  public var gates: [LoopGateResult]
}

public struct LoopSessionOverviewCommandResult: Codable, Equatable, Sendable {
  public var sessions: [LoopSessionOverview]
}

public struct LoopCommandFailureResult: Codable, Equatable, Sendable {
  public var sessionId: String
  public var command: String
  public var error: String
  public var exitCode: Int32
}

public struct LoopGatesCheckResult: Codable, Equatable, Sendable {
  public var sessionId: String
  public var verdict: String
  public var requiredGates: [String]
  public var failingGates: [String]
  public var exitCode: Int32
}

public struct LoopCommandRunner: Sendable {
  public var sessionRerunCommand: SessionRerunCommand

  public init(sessionRerunCommand: SessionRerunCommand = SessionRerunCommand()) {
    self.sessionRerunCommand = sessionRerunCommand
  }

  public func run(_ command: LoopCommand) async -> CLICommandResult {
    if command.kind == .start {
      return await LoopStartCommand().run(command.options)
    }
    if command.kind == .promote {
      return await LoopPromoteCommand().run(command.options)
    }
    if command.kind == .baseline {
      return runBaseline(command)
    }
    if command.kind == .regress {
      return runRegress(command)
    }
    if command.kind == .list || command.kind == .history || command.kind == .stats {
      do {
        let parsed = try parseOverviewOptions(command)
        let overviews = try loadOverviews(parsed)
        if command.kind == .stats {
          let stats = LoopWorkflowStats.aggregate(
            workflowId: parsed.workflowId ?? "",
            overviews: overviews,
            limit: parsed.limit
          )
          return try renderStats(stats, output: command.options.output)
        }
        return try renderOverviews(overviews, output: command.options.output)
      } catch let error as CLIUsageError {
        return CLICommandResult(exitCode: .usage, stderr: error.message)
      } catch {
        if command.options.output.isStructured {
          let payload = LoopCommandFailureResult(
            sessionId: command.options.target ?? "",
            command: command.kind.rawValue,
            error: "\(error)",
            exitCode: CLIExitCode.failure.rawValue
          )
          return CLICommandResult(exitCode: .failure, stdout: (try? jsonString(payload)) ?? "")
        }
        return CLICommandResult(exitCode: .failure, stderr: "\(error)")
      }
    }
    if command.kind == .gates, command.options.arguments.contains("--check") {
      guard let sessionId = command.options.target, !sessionId.isEmpty else {
        return CLICommandResult(exitCode: .usage, stderr: "loop gates --check requires a session id")
      }
      do {
        return try runGatesCheck(command, sessionId: sessionId)
      } catch let error as CLIUsageError {
        return CLICommandResult(exitCode: .usage, stderr: error.message)
      } catch {
        // Operational error is exit 1, distinct from the gate-check verdict codes.
        let payload = LoopGatesCheckResult(
          sessionId: sessionId,
          verdict: "error",
          requiredGates: [],
          failingGates: [],
          exitCode: CLIExitCode.failure.rawValue
        )
        return CLICommandResult(exitCode: .failure, stdout: (try? jsonString(payload)) ?? "", stderr: "\(error)")
      }
    }
    if command.kind == .diff || command.kind == .findings {
      do {
        if command.kind == .diff, command.options.arguments.first == "--baseline" {
          return try runBaselineDiff(command)
        }
        return command.kind == .diff ? try runDiff(command) : try runFindings(command)
      } catch let error as CLIUsageError {
        return CLICommandResult(exitCode: .usage, stderr: error.message)
      } catch {
        if command.options.output.isStructured {
          let payload = LoopCommandFailureResult(
            sessionId: command.options.target ?? "",
            command: command.kind.rawValue,
            error: "\(error)",
            exitCode: CLIExitCode.failure.rawValue
          )
          return CLICommandResult(exitCode: .failure, stdout: (try? jsonString(payload)) ?? "")
        }
        return CLICommandResult(exitCode: .failure, stderr: "\(error)")
      }
    }
    guard let sessionId = command.options.target, !sessionId.isEmpty else {
      return CLICommandResult(exitCode: .usage, stderr: "loop \(command.kind.rawValue) requires a session id")
    }
    do {
      if command.kind == .recover {
        return await sessionRerunCommand.run(try parseRecoverOptions(command.options, sessionId: sessionId))
      }
      let parsed = try parseInspectionOptions(command.options.arguments)
      let renderSnapshot = try snapshotForRendering(kind: command.kind, sessionId: sessionId, parsed: parsed)
      return try render(command.kind, snapshot: renderSnapshot.snapshot, loopEvidenceRecorded: renderSnapshot.loopEvidenceRecorded, output: command.options.output)
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch {
      if command.options.output.isStructured {
        let payload = LoopCommandFailureResult(
          sessionId: sessionId,
          command: command.kind.rawValue,
          error: "\(error)",
          exitCode: CLIExitCode.failure.rawValue
        )
        return CLICommandResult(exitCode: .failure, stdout: (try? jsonString(payload)) ?? "")
      }
      return CLICommandResult(exitCode: .failure, stderr: "\(error)")
    }
  }

  struct ParsedOptions {
    var scope: WorkflowScope
    var workingDirectory: String
    var sessionStore: String?
  }

  struct ParsedOverviewOptions {
    var scope: WorkflowScope
    var workingDirectory: String
    var sessionStore: String?
    var workflowId: String?
    var status: String?
    var gateDecision: String?
    var limit: Int
  }

  struct RenderSnapshot {
    var snapshot: WorkflowRuntimePersistenceSnapshot
    var loopEvidenceRecorded: Bool
  }

  func parseInspectionOptions(_ arguments: [String]) throws -> ParsedOptions {
    var scope = WorkflowScope.auto
    var workingDirectory = FileManager.default.currentDirectoryPath
    var sessionStore: String?
    var index = 0
    while index < arguments.count {
      let token = arguments[index]
      switch token {
      case "--scope":
        guard index + 1 < arguments.count, let value = WorkflowScope(rawValue: arguments[index + 1]), value != .direct else {
          throw CLIUsageError("invalid --scope value; expected auto, project, or user")
        }
        scope = value
        index += 2
      case "--working-dir", "--working-directory":
        guard index + 1 < arguments.count else {
          throw CLIUsageError("\(token) requires a value")
        }
        workingDirectory = arguments[index + 1]
        index += 2
      case "--session-store":
        guard index + 1 < arguments.count else {
          throw CLIUsageError("--session-store requires a value")
        }
        sessionStore = arguments[index + 1]
        index += 2
      case "--output":
        guard index + 1 < arguments.count else {
          throw CLIUsageError("--output requires a value")
        }
        index += 2
      default:
        if token.hasPrefix("--output=") {
          index += 1
        } else {
          throw CLIUsageError("unsupported loop option '\(token)'")
        }
      }
    }
    return ParsedOptions(scope: scope, workingDirectory: workingDirectory, sessionStore: sessionStore)
  }

  private func parseRecoverOptions(_ options: CLICommandOptions, sessionId: String) throws -> SessionRerunOptions {
    var scope = WorkflowScope.auto
    var workingDirectory = FileManager.default.currentDirectoryPath
    var workflowDefinitionDir: String?
    var mockScenarioPath: String?
    var sessionStore: String?
    var fromStep: String?
    var fromGate: String?
    var nestedSuperviser = false
    var index = 0
    while index < options.arguments.count {
      let token = options.arguments[index]
      switch token {
      case "--from-step":
        fromStep = try readRequiredOption(token, arguments: options.arguments, index: &index)
      case "--from-gate":
        fromGate = try readRequiredOption(token, arguments: options.arguments, index: &index)
      case "--workflow-definition-dir":
        workflowDefinitionDir = try readRequiredOption(token, arguments: options.arguments, index: &index)
      case "--mock-scenario":
        mockScenarioPath = try readRequiredOption(token, arguments: options.arguments, index: &index)
      case "--session-store":
        sessionStore = try readRequiredOption(token, arguments: options.arguments, index: &index)
      case "--working-dir", "--working-directory":
        workingDirectory = try readRequiredOption(token, arguments: options.arguments, index: &index)
      case "--scope":
        let raw = try readRequiredOption(token, arguments: options.arguments, index: &index)
        guard let value = WorkflowScope(rawValue: raw), value != .direct else {
          throw CLIUsageError("invalid --scope value '\(raw)'; expected auto, project, or user")
        }
        scope = value
      case "--output":
        _ = try readRequiredOption(token, arguments: options.arguments, index: &index)
      case "--nested-superviser", "--nested-supervisor":
        nestedSuperviser = true
        index += 1
      default:
        if token.hasPrefix("--output=") {
          index += 1
        } else {
          throw CLIUsageError("unsupported loop recover option '\(token)'")
        }
      }
    }
    if fromStep != nil, fromGate != nil {
      throw CLIUsageError("loop recover accepts only one of --from-step or --from-gate")
    }
    let resolvedStep: String
    if let fromStep, !fromStep.isEmpty {
      resolvedStep = fromStep
    } else if let fromGate, !fromGate.isEmpty {
      resolvedStep = try resolveGateStepId(
        sessionId: sessionId,
        gateId: fromGate,
        scope: scope,
        workflowDefinitionDir: workflowDefinitionDir,
        workingDirectory: workingDirectory,
        sessionStore: sessionStore
      )
    } else {
      throw CLIUsageError("loop recover requires --from-step <step-id> or --from-gate <gate-id>")
    }
    return SessionRerunOptions(
      sessionId: sessionId,
      stepId: resolvedStep,
      output: options.output,
      scope: scope,
      workflowDefinitionDir: workflowDefinitionDir,
      workingDirectory: workingDirectory,
      mockScenarioPath: mockScenarioPath,
      sessionStore: sessionStore,
      nestedSuperviser: nestedSuperviser
    )
  }

  func parseOverviewOptions(_ command: LoopCommand) throws -> ParsedOverviewOptions {
    var scope = WorkflowScope.auto
    var workingDirectory = FileManager.default.currentDirectoryPath
    var sessionStore: String?
    var workflowId = (command.kind == .history || command.kind == .stats) ? command.options.target : nil
    var status: String?
    var gateDecision: String?
    var limit = 50
    var index = 0
    while index < command.options.arguments.count {
      let token = command.options.arguments[index]
      switch token {
      case "--scope":
        let raw = try readRequiredOption(token, arguments: command.options.arguments, index: &index)
        guard let value = WorkflowScope(rawValue: raw), value != .direct else {
          throw CLIUsageError("invalid --scope value '\(raw)'; expected auto, project, or user")
        }
        scope = value
      case "--working-dir", "--working-directory":
        workingDirectory = try readRequiredOption(token, arguments: command.options.arguments, index: &index)
      case "--session-store":
        sessionStore = try readRequiredOption(token, arguments: command.options.arguments, index: &index)
      case "--workflow":
        guard command.kind == .list else {
          throw CLIUsageError("--workflow is only supported for loop list; use 'loop history <workflow>'")
        }
        workflowId = try readRequiredOption(token, arguments: command.options.arguments, index: &index)
      case "--status":
        status = try readStatusOption(token, arguments: command.options.arguments, index: &index)
      case "--gate-decision":
        gateDecision = try readGateDecisionOption(token, arguments: command.options.arguments, index: &index)
      case "--limit":
        let raw = try readRequiredOption(token, arguments: command.options.arguments, index: &index)
        guard let parsedLimit = Int(raw), parsedLimit > 0 else {
          throw CLIUsageError("--limit requires a positive integer")
        }
        limit = parsedLimit
      case "--output":
        _ = try readRequiredOption(token, arguments: command.options.arguments, index: &index)
      default:
        if token.hasPrefix("--output=") {
          index += 1
        } else {
          throw CLIUsageError("unsupported loop \(command.kind.rawValue) option '\(token)'")
        }
      }
    }
    if command.kind == .history || command.kind == .stats, workflowId == nil {
      throw CLIUsageError("loop \(command.kind.rawValue) requires a workflow id")
    }
    return ParsedOverviewOptions(
      scope: scope,
      workingDirectory: workingDirectory,
      sessionStore: sessionStore,
      workflowId: workflowId,
      status: status,
      gateDecision: gateDecision,
      limit: limit
    )
  }

  private func readStatusOption(_ token: String, arguments: [String], index: inout Int) throws -> String {
    let value = try readRequiredOption(token, arguments: arguments, index: &index)
    let supported = ["active", "created", "running", "completed", "failed"]
    guard supported.contains(value) else {
      throw CLIUsageError("invalid --status value '\(value)'; expected active, created, running, completed, or failed")
    }
    return value
  }

  private func readGateDecisionOption(_ token: String, arguments: [String], index: inout Int) throws -> String {
    let value = try readRequiredOption(token, arguments: arguments, index: &index)
    guard LoopGateDecision(rawValue: value) != nil else {
      throw CLIUsageError("invalid --gate-decision value '\(value)'; expected accepted, rejected, needs_work, or skipped")
    }
    return value
  }

  func readRequiredOption(_ token: String, arguments: [String], index: inout Int) throws -> String {
    guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
      throw CLIUsageError("\(token) requires a value")
    }
    index += 2
    return arguments[index - 1]
  }

  func loadOverviews(_ parsed: ParsedOverviewOptions) throws -> [LoopSessionOverview] {
    let filter = SQLiteWorkflowRuntimePersistenceStore.LoopSessionOverviewFilter(
      workflowId: parsed.workflowId,
      sessionStatus: parsed.status,
      lastGateDecision: parsed.gateDecision,
      limit: parsed.limit
    )
    return try overviewStoreRoots(parsed).flatMap { root in
      try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root))
        .loadSessionOverviews(filter)
    }
    .sorted { lhs, rhs in
      if lhs.updatedAt != rhs.updatedAt {
        return lhs.updatedAt > rhs.updatedAt
      }
      return lhs.sessionId < rhs.sessionId
    }
    .prefix(parsed.limit)
    .map { $0 }
  }

  private func overviewStoreRoots(_ parsed: ParsedOverviewOptions) -> [String] {
    let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
    if parsed.sessionStore != nil || environment["RIELA_SESSION_STORE"]?.isEmpty == false {
      return [
        CLIWorkflowSessionStore.resolveRootDirectory(
          sessionStore: parsed.sessionStore,
          scope: parsed.scope,
          workingDirectory: parsed.workingDirectory,
          environment: environment
        )
      ]
    }
    let scopes: [WorkflowScope]
    switch parsed.scope {
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
        workingDirectory: parsed.workingDirectory,
        environment: environment
      )
      guard seen.insert(root).inserted else {
        return nil
      }
      return root
    }
  }

  private func resolveGateStepId(
    sessionId: String,
    gateId: String,
    scope: WorkflowScope,
    workflowDefinitionDir: String?,
    workingDirectory: String,
    sessionStore: String?
  ) throws -> String {
    let loaded = try CLIWorkflowSessionResolution.loadPersistedSession(
      sessionId: sessionId,
      sessionStore: sessionStore,
      scope: scope,
      workingDirectory: workingDirectory
    )
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: loaded.storeRoot))
    let snapshot = try store.load(sessionId: sessionId)
    if let evidenceGate = snapshot.loopEvidence?.gates.first(where: { $0.gateId == gateId }) {
      return evidenceGate.stepId
    }
    let resolution = CLIWorkflowSessionResolution.effectiveResolution(
      persisted: loaded.record,
      scope: scope,
      workflowDefinitionDir: workflowDefinitionDir,
      workingDirectory: workingDirectory
    )
    let bundle = try FileSystemWorkflowBundleResolver().resolve(resolution)
    if let authoredGate = bundle.workflow.loop?.gates.first(where: { $0.id == gateId }) {
      return authoredGate.stepId
    }
    let evidenceIds = snapshot.loopEvidence?.gates.map(\.gateId) ?? []
    let authoredIds = bundle.workflow.loop?.gates.map(\.id) ?? []
    let known = Array(Set(evidenceIds + authoredIds)).sorted()
    let suffix = known.isEmpty ? "no known gate ids" : "known gate ids: \(known.joined(separator: ", "))"
    throw CLIUsageError("unknown loop gate '\(gateId)'; \(suffix)")
  }

  private func render(
    _ kind: LoopCommandKind,
    snapshot: WorkflowRuntimePersistenceSnapshot,
    loopEvidenceRecorded: Bool,
    output: WorkflowOutputFormat
  ) throws -> CLICommandResult {
    switch kind {
    case .status:
      return try renderStatus(snapshot: snapshot, loopEvidenceRecorded: loopEvidenceRecorded, output: output)
    case .evidence:
      return try renderEvidence(snapshot: snapshot, loopEvidenceRecorded: loopEvidenceRecorded, output: output)
    case .gates:
      return try renderGates(snapshot: snapshot, loopEvidenceRecorded: loopEvidenceRecorded, output: output)
    case .recover:
      throw CLIUsageError("loop recover must be handled before rendering")
    case .list, .history, .stats, .diff, .findings, .start, .promote, .baseline, .regress:
      throw CLIUsageError("loop \(kind.rawValue) must be handled before session rendering")
    }
  }

  private func renderOverviews(_ overviews: [LoopSessionOverview], output: WorkflowOutputFormat) throws -> CLICommandResult {
    switch output {
    case .json:
      return CLICommandResult(exitCode: .success, stdout: try jsonString(LoopSessionOverviewCommandResult(sessions: overviews)))
    case .jsonl:
      return CLICommandResult(exitCode: .success, stdout: try overviews.map(jsonString).joined())
    case .text:
      let lines = overviews.map { overview in
        [
          "sessionId: \(overview.sessionId)",
          "workflow: \(overview.workflowId)",
          "status: \(overview.sessionStatus)",
          "lastGateDecision: \(overview.lastGateDecision ?? "none")",
          "blockingFindings: \(overview.blockingFindingCount.map(String.init) ?? "not-recorded")",
          "cost: \(Self.costCell(overview.cost))",
          "updatedAt: \(overview.updatedAt)"
        ].joined(separator: "\n")
      }
      return CLICommandResult(exitCode: .success, stdout: lines.joined(separator: "\n\n") + (lines.isEmpty ? "" : "\n"))
    case .table:
      var lines = ["SESSION\tWORKFLOW\tSTATUS\tLAST_GATE\tBLOCKING\tCOST\tUPDATED\tSTALE"]
      lines.append(contentsOf: overviews.map { overview in
        [
          overview.sessionId,
          overview.workflowId,
          overview.sessionStatus,
          overview.lastGateDecision ?? "-",
          overview.blockingFindingCount.map(String.init) ?? "-",
          Self.costCell(overview.cost),
          String(describing: overview.updatedAt),
          overview.possiblyStale ? "true" : "false"
        ].joined(separator: "\t")
      })
      return CLICommandResult(exitCode: .success, stdout: lines.joined(separator: "\n") + "\n")
    }
  }

  private func runFindings(_ command: LoopCommand) throws -> CLICommandResult {
    guard let sessionId = command.options.target, !sessionId.isEmpty else {
      throw CLIUsageError("loop findings requires a session id")
    }
    var gateId: String?
    var format = "json"
    var scope = WorkflowScope.auto
    var workingDirectory = FileManager.default.currentDirectoryPath
    var sessionStore: String?
    let args = command.options.arguments
    var index = 0
    while index < args.count {
      let token = args[index]
      switch token {
      case "--gate":
        gateId = try readRequiredOption(token, arguments: args, index: &index)
      case "--format":
        let value = try readRequiredOption(token, arguments: args, index: &index)
        guard value == "sarif" || value == "json" else {
          throw CLIUsageError("invalid --format value '\(value)'; expected sarif or json")
        }
        format = value
      case "--scope":
        let raw = try readRequiredOption(token, arguments: args, index: &index)
        guard let value = WorkflowScope(rawValue: raw), value != .direct else {
          throw CLIUsageError("invalid --scope value '\(raw)'; expected auto, project, or user")
        }
        scope = value
      case "--working-dir", "--working-directory":
        workingDirectory = try readRequiredOption(token, arguments: args, index: &index)
      case "--session-store":
        sessionStore = try readRequiredOption(token, arguments: args, index: &index)
      case "--output":
        _ = try readRequiredOption(token, arguments: args, index: &index)
      default:
        throw CLIUsageError("unsupported loop findings option '\(token)'")
      }
    }
    let parsed = ParsedOptions(scope: scope, workingDirectory: workingDirectory, sessionStore: sessionStore)
    let rendered = try snapshotForRendering(kind: .gates, sessionId: sessionId, parsed: parsed)
    guard let manifest = rendered.snapshot.loopEvidence else {
      throw CLIUsageError("session '\(sessionId)' has no loop evidence")
    }
    if format == "sarif" {
      let sarif = LoopFindingsSARIFExporter.sarif(manifest: manifest, gateId: gateId)
      return CLICommandResult(exitCode: .success, stdout: try jsonString(JSONValue.object(sarif)))
    }
    let findings = LoopFindingsSARIFExporter.findings(manifest: manifest, gateId: gateId)
    return CLICommandResult(exitCode: .success, stdout: try jsonString(findings))
  }

  private func runGatesCheck(_ command: LoopCommand, sessionId: String) throws -> CLICommandResult {
    let parsed = try parseInspectionOptions(command.options.arguments.filter { $0 != "--check" })
    let loaded = try CLIWorkflowSessionResolution.loadPersistedSession(
      sessionId: sessionId,
      sessionStore: parsed.sessionStore,
      scope: parsed.scope,
      workingDirectory: parsed.workingDirectory
    )
    let store = SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: loaded.storeRoot)
    )
    let snapshot = try store.load(sessionId: sessionId)
    // "no loop evidence recorded" is evaluated against persisted evidence only —
    // CI must not pass on a projected-on-read manifest.
    guard let manifest = snapshot.loopEvidence else {
      let result = LoopGatesCheckResult(
        sessionId: sessionId,
        verdict: "no-loop-evidence",
        requiredGates: [],
        failingGates: [],
        exitCode: CLIExitCode.noLoopEvidence.rawValue
      )
      return CLICommandResult(exitCode: .noLoopEvidence, stdout: try jsonString(result))
    }
    let resolution = CLIWorkflowSessionResolution.effectiveResolution(
      persisted: loaded.record,
      scope: parsed.scope,
      workflowDefinitionDir: nil,
      workingDirectory: parsed.workingDirectory
    )
    let bundle = try FileSystemWorkflowBundleResolver().resolve(resolution)
    let requiredGateIds = (bundle.workflow.loop?.gates ?? [])
      .filter(\.required)
      .map(\.id)
      .sorted()
    let evaluation = Self.evaluateRequiredGates(requiredGateIds: requiredGateIds, gates: manifest.gates)
    let exitCode: CLIExitCode = evaluation.allAccepted ? .success : .gateCheckFailed
    let result = LoopGatesCheckResult(
      sessionId: sessionId,
      verdict: evaluation.allAccepted ? "accepted" : "failed",
      requiredGates: requiredGateIds,
      failingGates: evaluation.failing,
      exitCode: exitCode.rawValue
    )
    return CLICommandResult(exitCode: exitCode, stdout: try jsonString(result))
  }

  /// Evaluates required gates against the final gate results (latest visit per
  /// gateId). A required gate fails when it is missing, its final decision is
  /// not `accepted`, or it carries blocking findings.
  static func evaluateRequiredGates(
    requiredGateIds: [String],
    gates: [LoopGateResult]
  ) -> (failing: [String], allAccepted: Bool) {
    let latest = Dictionary(gates.map { ($0.gateId, $0) }, uniquingKeysWith: { _, next in next })
    var failing: [String] = []
    for gateId in requiredGateIds {
      guard let gate = latest[gateId] else {
        failing.append(gateId)
        continue
      }
      if gate.decision != .accepted || !gate.blockingFindings.isEmpty {
        failing.append(gateId)
      }
    }
    return (failing.sorted(), failing.isEmpty)
  }

  private func runDiff(_ command: LoopCommand) throws -> CLICommandResult {
    guard let sessionA = command.options.target, !sessionA.isEmpty else {
      throw CLIUsageError("loop diff requires two session ids: loop diff <session-a> <session-b>")
    }
    guard let sessionB = command.options.arguments.first, !sessionB.hasPrefix("--"), !sessionB.isEmpty else {
      throw CLIUsageError("loop diff requires a second session id: loop diff <session-a> <session-b>")
    }
    let parsed = try parseInspectionOptions(Array(command.options.arguments.dropFirst()))
    let base = try loadDiffManifest(sessionId: sessionA, parsed: parsed)
    let target = try loadDiffManifest(sessionId: sessionB, parsed: parsed)
    let diff = LoopEvidenceDiffer.diff(base: base, target: target)
    switch command.options.output {
    case .json, .jsonl:
      return CLICommandResult(exitCode: .success, stdout: try jsonString(diff))
    case .text, .table:
      return CLICommandResult(exitCode: .success, stdout: Self.diffTextLines(diff).joined(separator: "\n") + "\n")
    }
  }

  func loadDiffManifest(sessionId: String, parsed: ParsedOptions) throws -> LoopEvidenceManifest {
    let rendered = try snapshotForRendering(kind: .evidence, sessionId: sessionId, parsed: parsed)
    guard let manifest = rendered.snapshot.loopEvidence else {
      throw CLIUsageError("session '\(sessionId)' has no loop evidence to diff")
    }
    return manifest
  }

  /// Compact human-readable summary of an evidence diff. Counts rather than full
  /// payloads; `--output json` returns the full `LoopEvidenceDiff`.
  static func diffTextLines(_ diff: LoopEvidenceDiff) -> [String] {
    var lines = [
      "base: \(diff.baseSessionId)",
      "target: \(diff.targetSessionId)",
      "sameWorkflow: \(diff.sameWorkflow)",
      "workflowDefinitionDigestChanged: \(diff.workflowDefinitionDigestChanged.map(String.init) ?? "unknown")",
      "gateChanges: \(diff.gateChanges.count)",
      "blockingFindingsAdded: \(diff.blockingFindingsAdded.count)",
      "blockingFindingsResolved: \(diff.blockingFindingsResolved.count)",
      "changedFilesAdded: \(diff.changedFilesAdded.count)",
      "changedFilesRemoved: \(diff.changedFilesRemoved.count)",
      "verificationChanges: \(diff.verificationChanges.count)",
      "residualRisksAdded: \(diff.residualRiskDelta.added.count)",
      "residualRisksResolved: \(diff.residualRiskDelta.resolved.count)"
    ]
    if let cost = diff.costDelta {
      lines.append("costTotalTokensDelta: \(cost.totalTokensDelta.map(String.init) ?? "n/a")")
    }
    for diagnostic in diff.diagnostics {
      lines.append("diagnostic: \(diagnostic)")
    }
    return lines
  }

  private func renderStats(_ stats: LoopWorkflowStats, output: WorkflowOutputFormat) throws -> CLICommandResult {
    switch output {
    case .json, .jsonl:
      return CLICommandResult(exitCode: .success, stdout: try jsonString(stats))
    case .text, .table:
      return CLICommandResult(exitCode: .success, stdout: Self.statsTextLines(stats).joined(separator: "\n") + "\n")
    }
  }

  /// Human-readable stats lines. Absent means/last-accepted render explicitly
  /// rather than as zero.
  static func statsTextLines(_ stats: LoopWorkflowStats) -> [String] {
    var lines = [
      "workflow: \(stats.workflowId)",
      "windowRuns: \(stats.windowRuns)",
      "completedRuns: \(stats.completedRuns)",
      "failedRuns: \(stats.failedRuns)",
      "acceptedRuns: \(stats.acceptedRuns)",
      "rerunCount: \(stats.rerunCount)",
      "meanDurationMs: \(stats.meanDurationMs.map(String.init) ?? "not-recorded")",
      "meanTotalTokens: \(stats.meanTotalTokens.map(String.init) ?? "not-recorded")",
      "lastAcceptedSessionId: \(stats.lastAcceptedSessionId ?? "none")"
    ]
    let gateFailures = stats.gateFailureCounts.sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: " ")
    lines.append("gateFailures: \(gateFailures.isEmpty ? "none" : gateFailures)")
    for diagnostic in stats.diagnostics {
      lines.append("diagnostic: \(diagnostic)")
    }
    return lines
  }

  /// Renders a cost summary for list/history columns. Absent cost renders as
  /// `not-recorded` (never zero); a run that recorded steps but no usage renders
  /// as `no-usage`; partial totals are flagged.
  static func costCell(_ cost: LoopCostSummary?) -> String {
    guard let cost else { return "not-recorded" }
    var parts: [String] = []
    if let total = cost.totalTokens { parts.append("\(total)tok") }
    if let duration = cost.totalDurationMs { parts.append("\(duration)ms") }
    if parts.isEmpty { parts.append("no-usage") }
    return parts.joined(separator: " ") + (cost.isPartial ? " (partial)" : "")
  }

  func snapshotForRendering(
    kind: LoopCommandKind,
    sessionId: String,
    parsed: ParsedOptions
  ) throws -> RenderSnapshot {
    let loaded = try CLIWorkflowSessionResolution.loadPersistedSession(
      sessionId: sessionId,
      sessionStore: parsed.sessionStore,
      scope: parsed.scope,
      workingDirectory: parsed.workingDirectory
    )
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: loaded.storeRoot))
    var snapshot = try store.load(sessionId: sessionId)
    let loopEvidenceRecorded = snapshot.loopEvidence != nil
    guard snapshot.loopEvidence == nil, kind == .evidence || kind == .gates else {
      return RenderSnapshot(snapshot: snapshot, loopEvidenceRecorded: loopEvidenceRecorded)
    }
    let resolution = CLIWorkflowSessionResolution.effectiveResolution(
      persisted: loaded.record,
      scope: parsed.scope,
      workflowDefinitionDir: nil,
      workingDirectory: parsed.workingDirectory
    )
    let bundle = try FileSystemWorkflowBundleResolver().resolve(resolution)
    snapshot.loopEvidence = try DefaultLoopEvidenceProjector().project(
      LoopEvidenceProjectionInput(
        workflow: bundle.workflow,
        session: snapshot.session,
        workflowMessages: snapshot.workflowMessages,
        workflowSource: loopWorkflowSource(from: bundle),
        includeWorkflowWithoutLoopMetadata: true
      )
    )
    return RenderSnapshot(snapshot: snapshot, loopEvidenceRecorded: loopEvidenceRecorded)
  }

  private func loopWorkflowSource(from bundle: ResolvedWorkflowBundle) -> LoopWorkflowSource {
    LoopWorkflowSource(
      scope: bundle.sourceScope.rawValue,
      kind: bundle.packageManifest == nil ? "workflow-directory" : "package",
      workflowDirectory: bundle.workflowDirectory,
      packageName: bundle.packageManifest?.name,
      packageVersion: bundle.packageManifest?.version,
      packageDirectory: bundle.packageDirectory,
      mutable: bundle.packageManifest == nil
    )
  }

  private func renderStatus(
    snapshot: WorkflowRuntimePersistenceSnapshot,
    loopEvidenceRecorded: Bool,
    output: WorkflowOutputFormat
  ) throws -> CLICommandResult {
    let summary = snapshot.loopEvidence.map(LoopEvidenceSummary.init)
    let result = LoopStatusCommandResult(
      sessionId: snapshot.session.sessionId,
      workflowName: snapshot.session.workflowId,
      sessionStatus: snapshot.session.status,
      loopEvidenceRecorded: loopEvidenceRecorded,
      loopEvidence: summary
    )
    switch output {
    case .json, .jsonl:
      return CLICommandResult(exitCode: .success, stdout: try jsonString(result))
    case .text, .table:
      var lines = baseTextLines(snapshot: snapshot, recorded: loopEvidenceRecorded)
      if let summary {
        lines.append("gates: \(summary.gateCount)")
        lines.append("acceptedGates: \(summary.acceptedGateCount)")
        lines.append("blockingFindings: \(summary.blockingFindingCount)")
        lines.append("cost: \(Self.costCell(summary.cost))")
      }
      return CLICommandResult(exitCode: .success, stdout: lines.joined(separator: "\n") + "\n")
    }
  }

  private func renderEvidence(
    snapshot: WorkflowRuntimePersistenceSnapshot,
    loopEvidenceRecorded: Bool,
    output: WorkflowOutputFormat
  ) throws -> CLICommandResult {
    let result = LoopEvidenceCommandResult(
      sessionId: snapshot.session.sessionId,
      workflowName: snapshot.session.workflowId,
      loopEvidenceRecorded: loopEvidenceRecorded,
      loopEvidence: snapshot.loopEvidence
    )
    switch output {
    case .json, .jsonl:
      return CLICommandResult(exitCode: .success, stdout: try jsonString(result))
    case .text, .table:
      var lines = baseTextLines(snapshot: snapshot, recorded: loopEvidenceRecorded)
      if let evidence = snapshot.loopEvidence {
        lines.append("manifestId: \(evidence.manifestId)")
        lines.append("schemaVersion: \(evidence.schemaVersion)")
        lines.append("steps: \(evidence.steps.count)")
        lines.append("gates: \(evidence.gates.count)")
      }
      return CLICommandResult(exitCode: .success, stdout: lines.joined(separator: "\n") + "\n")
    }
  }

  private func renderGates(
    snapshot: WorkflowRuntimePersistenceSnapshot,
    loopEvidenceRecorded: Bool,
    output: WorkflowOutputFormat
  ) throws -> CLICommandResult {
    let result = LoopGatesCommandResult(
      sessionId: snapshot.session.sessionId,
      workflowName: snapshot.session.workflowId,
      loopEvidenceRecorded: loopEvidenceRecorded,
      gates: snapshot.loopEvidence?.gates ?? []
    )
    switch output {
    case .json, .jsonl:
      return CLICommandResult(exitCode: .success, stdout: try jsonString(result))
    case .text, .table:
      var lines = baseTextLines(snapshot: snapshot, recorded: loopEvidenceRecorded)
      lines.append(contentsOf: result.gates.map {
        "\($0.gateId)\t\($0.stepId)\t\($0.decision.rawValue)\tblockingFindings=\($0.blockingFindings.count)"
      })
      return CLICommandResult(exitCode: .success, stdout: lines.joined(separator: "\n") + "\n")
    }
  }

  private func baseTextLines(snapshot: WorkflowRuntimePersistenceSnapshot, recorded: Bool) -> [String] {
    [
      "sessionId: \(snapshot.session.sessionId)",
      "workflow: \(snapshot.session.workflowId)",
      "status: \(snapshot.session.status.rawValue)",
      "loopEvidenceRecorded: \(recorded ? "true" : "false")"
    ]
  }
}
