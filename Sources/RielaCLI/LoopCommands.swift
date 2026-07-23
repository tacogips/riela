import Foundation
import ArgumentParser
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
        let baseline = try ParsedLoopBaselineMarker.parseCLI(command.options.arguments).baseline
        if command.kind == .diff, baseline {
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

  private struct InspectionArguments: RielaClientFamilyArguments {
    @Option var scope = "auto"
    @Option(name: [.customLong("working-dir"), .customLong("working-directory")])
    var workingDirectory = FileManager.default.currentDirectoryPath
    @Option var sessionStore: String?
    @Option var output: String?
    @Flag var check = false
  }

  private struct RecoverArguments: RielaClientFamilyArguments {
    @Option var fromStep: String?
    @Option var fromGate: String?
    @Option var workflowDefinitionDir: String?
    @Option var mockScenario: String?
    @Option var sessionStore: String?
    @Option(name: [.customLong("working-dir"), .customLong("working-directory")])
    var workingDirectory = FileManager.default.currentDirectoryPath
    @Option var scope = "auto"
    @Option var output: String?
    @Flag(name: [.customLong("nested-superviser"), .customLong("nested-supervisor")])
    var nestedSuperviser = false
  }

  private struct OverviewArguments: RielaClientFamilyArguments {
    @Option var scope = "auto"
    @Option(name: [.customLong("working-dir"), .customLong("working-directory")])
    var workingDirectory = FileManager.default.currentDirectoryPath
    @Option var sessionStore: String?
    @Option var workflow: String?
    @Option var status: String?
    @Option var gateDecision: String?
    @Option var limit = 50
    @Option var output: String?
  }

  private struct FindingsArguments: RielaClientFamilyArguments {
    @Option var gate: String?
    @Option var format = "json"
    @Option var scope = "auto"
    @Option(name: [.customLong("working-dir"), .customLong("working-directory")])
    var workingDirectory = FileManager.default.currentDirectoryPath
    @Option var sessionStore: String?
    @Option var output: String?
  }

  private struct DiffArguments: RielaClientFamilyArguments {
    @Argument var sessionId: String
    @Option var scope = "auto"
    @Option(name: [.customLong("working-dir"), .customLong("working-directory")])
    var workingDirectory = FileManager.default.currentDirectoryPath
    @Option var sessionStore: String?
    @Option var output: String?
  }

  struct RenderSnapshot {
    var snapshot: WorkflowRuntimePersistenceSnapshot
    var loopEvidenceRecorded: Bool
  }

  func parseInspectionOptions(_ arguments: [String]) throws -> ParsedOptions {
    let parsed = try InspectionArguments.parseCLI(arguments)
    guard let scope = WorkflowScope(rawValue: parsed.scope), scope != .direct else {
      throw CLIUsageError("invalid --scope value; expected auto, project, or user")
    }
    return ParsedOptions(
      scope: scope,
      workingDirectory: parsed.workingDirectory,
      sessionStore: parsed.sessionStore
    )
  }

  private func parseRecoverOptions(_ options: CLICommandOptions, sessionId: String) throws -> SessionRerunOptions {
    let parsed = try RecoverArguments.parseCLI(options.arguments)
    guard let scope = WorkflowScope(rawValue: parsed.scope), scope != .direct else {
      throw CLIUsageError("invalid --scope value '\(parsed.scope)'; expected auto, project, or user")
    }
    if parsed.fromStep != nil, parsed.fromGate != nil {
      throw CLIUsageError("loop recover accepts only one of --from-step or --from-gate")
    }
    let resolvedStep: String
    if let fromStep = parsed.fromStep, !fromStep.isEmpty {
      resolvedStep = fromStep
    } else if let fromGate = parsed.fromGate, !fromGate.isEmpty {
      resolvedStep = try resolveGateStepId(
        sessionId: sessionId,
        gateId: fromGate,
        scope: scope,
        workflowDefinitionDir: parsed.workflowDefinitionDir,
        workingDirectory: parsed.workingDirectory,
        sessionStore: parsed.sessionStore
      )
    } else {
      throw CLIUsageError("loop recover requires --from-step <step-id> or --from-gate <gate-id>")
    }
    return SessionRerunOptions(
      sessionId: sessionId,
      stepId: resolvedStep,
      output: options.output,
      scope: scope,
      workflowDefinitionDir: parsed.workflowDefinitionDir,
      workingDirectory: parsed.workingDirectory,
      mockScenarioPath: parsed.mockScenario,
      sessionStore: parsed.sessionStore,
      nestedSuperviser: parsed.nestedSuperviser
    )
  }

  func parseOverviewOptions(_ command: LoopCommand) throws -> ParsedOverviewOptions {
    let parsed = try OverviewArguments.parseCLI(command.options.arguments)
    guard let scope = WorkflowScope(rawValue: parsed.scope), scope != .direct else {
      throw CLIUsageError("invalid --scope value '\(parsed.scope)'; expected auto, project, or user")
    }
    guard parsed.limit > 0 else {
      throw CLIUsageError("--limit requires a positive integer")
    }
    if command.kind != .list, parsed.workflow != nil {
      throw CLIUsageError("--workflow is only supported for loop list; use 'loop history <workflow>'")
    }
    if let status = parsed.status {
      let supported = ["active", "created", "running", "completed", "failed"]
      guard supported.contains(status) else {
        throw CLIUsageError(
          "invalid --status value '\(status)'; expected active, created, running, completed, or failed"
        )
      }
    }
    if let gateDecision = parsed.gateDecision, LoopGateDecision(rawValue: gateDecision) == nil {
      throw CLIUsageError(
        "invalid --gate-decision value '\(gateDecision)'; expected accepted, rejected, needs_work, or skipped"
      )
    }
    let workflowId = command.kind == .list ? parsed.workflow : command.options.target
    if command.kind == .history || command.kind == .stats, workflowId == nil {
      throw CLIUsageError("loop \(command.kind.rawValue) requires a workflow id")
    }
    return ParsedOverviewOptions(
      scope: scope,
      workingDirectory: parsed.workingDirectory,
      sessionStore: parsed.sessionStore,
      workflowId: workflowId,
      status: parsed.status,
      gateDecision: parsed.gateDecision,
      limit: parsed.limit
    )
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
    let arguments = try FindingsArguments.parseCLI(command.options.arguments)
    guard arguments.format == "sarif" || arguments.format == "json" else {
      throw CLIUsageError("invalid --format value '\(arguments.format)'; expected sarif or json")
    }
    guard let scope = WorkflowScope(rawValue: arguments.scope), scope != .direct else {
      throw CLIUsageError("invalid --scope value '\(arguments.scope)'; expected auto, project, or user")
    }
    let parsed = ParsedOptions(
      scope: scope,
      workingDirectory: arguments.workingDirectory,
      sessionStore: arguments.sessionStore
    )
    let rendered = try snapshotForRendering(kind: .gates, sessionId: sessionId, parsed: parsed)
    guard let manifest = rendered.snapshot.loopEvidence else {
      throw CLIUsageError("session '\(sessionId)' has no loop evidence")
    }
    if arguments.format == "sarif" {
      let sarif = LoopFindingsSARIFExporter.sarif(manifest: manifest, gateId: arguments.gate)
      return CLICommandResult(exitCode: .success, stdout: try jsonString(JSONValue.object(sarif)))
    }
    let findings = LoopFindingsSARIFExporter.findings(manifest: manifest, gateId: arguments.gate)
    return CLICommandResult(exitCode: .success, stdout: try jsonString(findings))
  }

  private func runGatesCheck(_ command: LoopCommand, sessionId: String) throws -> CLICommandResult {
    let parsed = try parseInspectionOptions(command.options.arguments)
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
    let arguments = try DiffArguments.parseCLI(command.options.arguments)
    let sessionB = arguments.sessionId
    guard let scope = WorkflowScope(rawValue: arguments.scope), scope != .direct else {
      throw CLIUsageError("invalid --scope value '\(arguments.scope)'; expected auto, project, or user")
    }
    let parsed = ParsedOptions(
      scope: scope,
      workingDirectory: arguments.workingDirectory,
      sessionStore: arguments.sessionStore
    )
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
      mutable: bundle.provenance == .mutable
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
