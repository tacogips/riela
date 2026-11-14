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

public struct LoopCommandFailureResult: Codable, Equatable, Sendable {
  public var sessionId: String
  public var command: String
  public var error: String
  public var exitCode: Int32
}

public struct LoopCommandRunner: Sendable {
  public var sessionRerunCommand: SessionRerunCommand

  public init(sessionRerunCommand: SessionRerunCommand = SessionRerunCommand()) {
    self.sessionRerunCommand = sessionRerunCommand
  }

  public func run(_ command: LoopCommand) async -> CLICommandResult {
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

  private struct ParsedOptions {
    var scope: WorkflowScope
    var workingDirectory: String
    var sessionStore: String?
  }

  private struct RenderSnapshot {
    var snapshot: WorkflowRuntimePersistenceSnapshot
    var loopEvidenceRecorded: Bool
  }

  private func parseInspectionOptions(_ arguments: [String]) throws -> ParsedOptions {
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
    var nestedSuperviser = false
    var index = 0
    while index < options.arguments.count {
      let token = options.arguments[index]
      switch token {
      case "--from-step":
        fromStep = try readRequiredOption(token, arguments: options.arguments, index: &index)
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
    guard let fromStep, !fromStep.isEmpty else {
      throw CLIUsageError("loop recover requires --from-step <step-id>")
    }
    return SessionRerunOptions(
      sessionId: sessionId,
      stepId: fromStep,
      output: options.output,
      scope: scope,
      workflowDefinitionDir: workflowDefinitionDir,
      workingDirectory: workingDirectory,
      mockScenarioPath: mockScenarioPath,
      sessionStore: sessionStore,
      nestedSuperviser: nestedSuperviser
    )
  }

  private func readRequiredOption(_ token: String, arguments: [String], index: inout Int) throws -> String {
    guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
      throw CLIUsageError("\(token) requires a value")
    }
    index += 2
    return arguments[index - 1]
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
    }
  }

  private func snapshotForRendering(
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
