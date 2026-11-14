import Foundation
import RielaCore

/// What one terminal attempt contributed to its task's ledger.
public struct WorkProjection: Equatable, Sendable {
  public var evidence: [Evidence]
  public var findings: [Finding]
  /// Decisions recovered from the attempt's own lineage. The plan sketches a
  /// two-value return, but `LoopRecoveryLineage` projects to a `Decision`, so
  /// the projection carries all three (accepted delta).
  public var decisions: [Decision]

  public init(evidence: [Evidence] = [], findings: [Finding] = [], decisions: [Decision] = []) {
    self.evidence = evidence
    self.findings = findings
    self.decisions = decisions
  }

  public func evidence(ofKind kind: EvidenceKind) -> [Evidence] {
    evidence.filter { $0.kind == kind }
  }
}

/// Turns one persisted terminal session snapshot into ledger records
/// (design section 8).
///
/// Identifiers are derived from the attempt and the record's position, never
/// random: projecting the same snapshot twice must upsert the same rows
/// rather than duplicate the ledger.
///
/// **causedBy in P0.** The ledger has no `step` kind, so the only
/// step-anchored records this phase creates are gates. Every edge below is
/// therefore either a gate edge or a record-to-record edge that exists in the
/// source data:
///
/// - a finding points at the gate that reported it (and a review finding at
///   the gate sharing its source step execution, when there is one);
/// - a verification points at the command it ran, when `commandRef` names one;
/// - a changed file and a cost record point at the gate evidence for their
///   producing step execution, when that step is a gate step;
/// - a guard violation points at the last gate visit;
/// - a decision points at the guard violation that caused it, else at the
///   step evidence of its lineage source, else at the last gate visit.
public struct WorkEvidenceProjector: Sendable {
  public init() {}

  /// The attempt outcome a terminal snapshot describes. Callers that only
  /// need the outcome (the completion check, `riela task show`) use this
  /// instead of projecting the whole ledger.
  public static func outcome(from snapshot: WorkflowRuntimePersistenceSnapshot) -> AttemptOutcome {
    AttemptOutcome(
      sessionStatus: snapshot.session.status,
      failureKind: snapshot.session.failureKind,
      gateResults: snapshot.loopEvidence?.gates ?? [],
      costs: snapshot.loopEvidence?.costs ?? []
    )
  }

  public func project(
    snapshot: WorkflowRuntimePersistenceSnapshot,
    task: WorkTask,
    attempt: Attempt
  ) -> WorkProjection {
    var builder = Builder(taskId: task.id, attempt: attempt, snapshot: snapshot)
    builder.projectGates()
    builder.projectFindings()
    builder.projectVerificationAndCommands()
    builder.projectChangedFiles()
    builder.projectCosts()
    builder.projectGuardViolation()
    builder.projectRecoveryLineage()
    return builder.projection
  }

  private struct Builder {
    let taskId: TaskID
    let attempt: Attempt
    let snapshot: WorkflowRuntimePersistenceSnapshot
    var projection = WorkProjection()
    /// Gate evidence keyed by the step execution that produced it.
    var stepEvidence: [String: EvidenceID] = [:]
    /// Gate evidence keyed by gate id (the latest visit wins).
    var gateEvidence: [String: EvidenceID] = [:]
    var lastGateEvidence: EvidenceID?
    var commandEvidence: [String: EvidenceID] = [:]
    var guardViolationEvidence: EvidenceID?

    var manifest: LoopEvidenceManifest? { snapshot.loopEvidence }

    /// Manifest records carry no per-record timestamp, so the manifest's own
    /// `updatedAt` is the ledger time for all of them; a gate uses its
    /// acceptance time when it has one.
    var defaultCreatedAt: Date { manifest?.updatedAt ?? snapshot.session.updatedAt }

    func identifier(_ kind: EvidenceKind, _ index: Int) -> EvidenceID {
      EvidenceID("evidence-\(attempt.id.rawValue)-\(kind.rawValue)-\(index)")
    }

    mutating func append(
      _ kind: EvidenceKind,
      index: Int,
      producedBy: EvidenceProducer,
      causedBy: [EvidenceID],
      payload: JSONObject,
      createdAt: Date? = nil
    ) -> EvidenceID {
      let id = identifier(kind, index)
      projection.evidence.append(Evidence(
        id: id,
        taskId: taskId,
        attemptId: attempt.id,
        kind: kind,
        producedBy: producedBy,
        causedBy: causedBy,
        payloadRef: .inline(payload),
        createdAt: createdAt ?? defaultCreatedAt
      ))
      return id
    }

    mutating func projectGates() {
      guard let manifest else { return }
      for (index, gate) in manifest.gates.enumerated() {
        let id = append(
          .gate,
          index: index,
          producedBy: .stepExecution(gate.stepExecutionId),
          causedBy: [],
          payload: [
            "gateId": .string(gate.gateId),
            "stepId": .string(gate.stepId),
            "stepExecutionId": .string(gate.stepExecutionId),
            "decision": .string(gate.decision.rawValue),
            "blockingFindingCount": .integer(Int64(gate.blockingFindings.count))
          ],
          createdAt: gate.acceptedAt ?? defaultCreatedAt
        )
        stepEvidence[gate.stepExecutionId] = id
        gateEvidence[gate.gateId] = id
        lastGateEvidence = id
      }
    }

    mutating func projectFindings() {
      var collected: [(Finding, EvidenceID?)] = []
      for gate in manifest?.gates ?? [] {
        for blocking in gate.blockingFindings {
          collected.append((
            WorkFindingMerge.finding(
              from: blocking,
              gateId: gate.gateId,
              sourceStepExecutionId: gate.stepExecutionId
            ),
            gateEvidence[gate.gateId]
          ))
        }
      }
      for review in snapshot.session.reviewFindings {
        collected.append((
          WorkFindingMerge.finding(from: review),
          stepEvidence[review.sourceStepExecutionId]
        ))
      }

      let merged = WorkFindingMerge.merge(collected.map(\.0))
      var cause: [LoopFindingFingerprint: EvidenceID] = [:]
      for (finding, gate) in collected where cause[finding.fingerprint] == nil {
        cause[finding.fingerprint] = gate
      }

      projection.findings = merged
      for (index, finding) in merged.enumerated() {
        _ = append(
          .finding,
          index: index,
          producedBy: .stepExecution(finding.sourceStepExecutionId),
          causedBy: [cause[finding.fingerprint]].compactMap { $0 },
          payload: [
            "id": .string(finding.id),
            "fingerprint": .string(finding.fingerprint.key),
            "severity": .string(finding.severity.rawValue),
            "status": .string(finding.status.rawValue),
            "message": .string(finding.message)
          ]
        )
      }
    }

    mutating func projectVerificationAndCommands() {
      guard let manifest else { return }
      for (index, command) in manifest.commands.enumerated() {
        let id = append(
          .command,
          index: index,
          producedBy: .runtime,
          causedBy: [],
          payload: [
            "id": .string(command.id),
            "argvSummary": .string(command.argvSummary),
            "exitCode": command.exitCode.map { .integer(Int64($0)) } ?? .null
          ]
        )
        commandEvidence[command.id] = id
      }
      for (index, verification) in manifest.verification.enumerated() {
        _ = append(
          .verification,
          index: index,
          producedBy: .runtime,
          causedBy: [verification.commandRef.flatMap { commandEvidence[$0] }].compactMap { $0 },
          payload: [
            "id": .string(verification.id),
            "outcome": .string(verification.outcome),
            "commandRef": verification.commandRef.map { .string($0) } ?? .null
          ]
        )
      }
    }

    mutating func projectChangedFiles() {
      guard let manifest else { return }
      for (index, file) in manifest.changedFiles.enumerated() {
        _ = append(
          .changedFile,
          index: index,
          producedBy: file.producerStepExecutionId.map { EvidenceProducer.stepExecution($0) } ?? .runtime,
          causedBy: [file.producerStepExecutionId.flatMap { stepEvidence[$0] }].compactMap { $0 },
          payload: [
            "path": .string(file.path),
            "changeKind": .string(file.changeKind),
            "digest": file.digest.map { .string($0) } ?? .null
          ]
        )
      }
    }

    mutating func projectCosts() {
      guard let manifest else { return }
      for (index, cost) in manifest.costs.enumerated() {
        _ = append(
          .cost,
          index: index,
          producedBy: .stepExecution(cost.stepExecutionId),
          causedBy: [stepEvidence[cost.stepExecutionId]].compactMap { $0 },
          payload: [
            "stepExecutionId": .string(cost.stepExecutionId),
            "backend": cost.backend.map { .string($0) } ?? .null,
            "model": cost.model.map { .string($0) } ?? .null,
            "totalTokens": cost.totalTokens.map { .integer(Int64($0)) } ?? .null,
            "durationMs": cost.durationMs.map { .integer(Int64($0)) } ?? .null
          ]
        )
      }
    }

    mutating func projectGuardViolation() {
      guard let convergence = manifest?.convergence, convergence.stallDetected else {
        return
      }
      var payload: JSONObject = [
        "detector": .string("convergence"),
        "stallDetected": .bool(true)
      ]
      if let gateId = convergence.stalledGateId {
        payload["gateId"] = .string(gateId)
      }
      if let rounds = convergence.repeatedRounds {
        payload["repeatedRounds"] = .integer(Int64(rounds))
      }
      if let action = convergence.action {
        payload["action"] = .string(action)
      }
      guardViolationEvidence = append(
        .guardViolation,
        index: 0,
        producedBy: .runtime,
        causedBy: [convergence.stalledGateId.flatMap { gateEvidence[$0] } ?? lastGateEvidence].compactMap { $0 },
        payload: payload
      )
    }

    /// A recovery lineage is a decision some earlier driver already made.
    /// Importing it as a `policy("legacy-import")` decision keeps the task's
    /// history complete without pretending a director produced it. Lineages
    /// that only record a plain run or resume carry no redirection and
    /// project to nothing.
    mutating func projectRecoveryLineage() {
      guard let lineage = manifest?.recovery else { return }
      let kind: DecisionKind
      switch lineage.entryMode {
      case .retry, .rerun, .replay:
        if let gate = manifest?.gates.first(where: { $0.stepId == lineage.sourceStepId }) {
          kind = .recover(fromGateId: gate.gateId)
        } else {
          kind = .rerun(fromStepId: lineage.sourceStepId)
        }
      case .run, .resume:
        return
      }
      let causedBy = [
        guardViolationEvidence
          ?? lineage.sourceStepExecutionId.flatMap { stepEvidence[$0] }
          ?? lastGateEvidence
      ].compactMap { $0 }
      let decision = Decision(
        id: DecisionID("decision-\(attempt.id.rawValue)-lineage"),
        taskId: taskId,
        attemptId: attempt.id,
        producer: .policy(rule: "legacy-import"),
        kind: kind,
        reason: lineage.reason ?? "imported from loop recovery lineage (\(lineage.entryMode.rawValue))",
        causedBy: causedBy,
        createdAt: defaultCreatedAt
      )
      projection.decisions.append(decision)
      _ = append(
        .decision,
        index: 0,
        producedBy: .runtime,
        causedBy: causedBy,
        payload: [
          "decisionId": .string(decision.id.rawValue),
          "kind": .string(decision.kind.kindName),
          "entryMode": .string(lineage.entryMode.rawValue)
        ]
      )
    }
  }
}
