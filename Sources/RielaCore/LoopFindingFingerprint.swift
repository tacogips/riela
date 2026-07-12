import Foundation

public struct LoopFindingFingerprint: Hashable, Codable, Sendable {
  public var key: String

  public init(key: String) {
    self.key = key
  }

  public static func make(from finding: LoopBlockingFinding) -> LoopFindingFingerprint {
    // LA3's LoopEvidenceDiffer must consume this identity instead of defining a parallel matcher.
    if !finding.id.isEmpty && !finding.id.hasPrefix("gate-policy-") {
      return LoopFindingFingerprint(key: "id:\(finding.id)")
    }
    return LoopFindingFingerprint(
      key: "message:\(finding.filePath ?? "")\u{0}\(collapseWhitespace(finding.message))"
    )
  }

  private static func collapseWhitespace(_ value: String) -> String {
    value
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

struct LoopGatePayloadParser: Sendable {
  var stepGateIdsByStepId: [String: String]
  var gateStepIds: Set<String>
  var requiredGatesById: [String: LoopGateDeclaration]

  func result(from payload: JSONObject, execution: WorkflowStepExecution) -> LoopGateResult {
    let decision = stringValue(payload["decision"]).flatMap(LoopGateDecision.init(rawValue:)) ?? .needsWork
    let result = LoopGateResult(
      gateId: stringValue(payload["gateId"]) ?? stepGateIdsByStepId[execution.stepId] ?? execution.stepId,
      stepId: stringValue(payload["stepId"]) ?? execution.stepId,
      stepExecutionId: stringValue(payload["stepExecutionId"]) ?? execution.executionId,
      decision: decision,
      severityCounts: severityCounts(payload["severityCounts"]),
      blockingFindings: blockingFindings(payload["blockingFindings"]),
      evidenceRefs: stringArray(payload["evidenceRefs"]),
      rerunPolicy: stringValue(payload["rerunPolicy"]),
      residualRisks: residualRiskArray(payload["residualRisks"]),
      acceptedAt: decision == .accepted ? execution.acceptedOutput?.acceptedAt : nil,
      diagnostics: stringArray(payload["diagnostics"])
    )
    return normalized(result)
  }

  func result(from execution: WorkflowStepExecution) -> LoopGateResult? {
    if let output = execution.acceptedOutput?.payload,
       case let .object(loopGate)? = output["loopGate"] {
      return result(from: loopGate, execution: execution)
    }
    guard execution.status == .skipped,
          gateStepIds.contains(execution.stepId) else {
      return nil
    }
    let gateId = stepGateIdsByStepId[execution.stepId] ?? execution.stepId
    return normalized(LoopGateResult(
      gateId: gateId,
      stepId: execution.stepId,
      stepExecutionId: execution.executionId,
      decision: .skipped,
      acceptedAt: execution.acceptedOutput?.acceptedAt,
      diagnostics: ["gate step was skipped"]
    ))
  }

  private func normalized(_ result: LoopGateResult) -> LoopGateResult {
    guard let gate = requiredGatesById[result.gateId] else {
      return result
    }
    let violations = acceptanceViolations(policy: gate.acceptWhen, gate: gate, result: result)
    guard !violations.isEmpty else {
      return result
    }

    var blocked = result
    if blocked.decision == .accepted {
      blocked.decision = .rejected
      blocked.acceptedAt = nil
    }
    blocked.blockingFindings.append(contentsOf: violations.map { violation in
      LoopBlockingFinding(
        id: "gate-policy-\(gate.id)-\(violation.id)",
        severity: violation.severity,
        message: violation.message
      )
    })
    blocked.diagnostics.append(contentsOf: violations.map(\.message))
    return blocked
  }

  private func acceptanceViolations(
    policy: LoopGateAcceptancePolicy,
    gate: LoopGateDeclaration,
    result: LoopGateResult
  ) -> [LoopGateAcceptanceViolation] {
    var violations: [LoopGateAcceptanceViolation] = []
    if let expectedDecision = policy.decision, result.decision != expectedDecision {
      violations.append(LoopGateAcceptanceViolation(
        id: "decision",
        severity: "high",
        message: "required loop gate '\(gate.id)' expected decision \(expectedDecision.rawValue) but got \(result.decision.rawValue)"
      ))
    }
    if let maxHighFindings = policy.maxHighFindings, result.severityCounts.high > maxHighFindings {
      violations.append(LoopGateAcceptanceViolation(
        id: "max-high-findings",
        severity: "high",
        message: "required loop gate '\(gate.id)' has \(result.severityCounts.high) high findings; maximum is \(maxHighFindings)"
      ))
    }
    if let maxMediumFindings = policy.maxMediumFindings, result.severityCounts.medium > maxMediumFindings {
      violations.append(LoopGateAcceptanceViolation(
        id: "max-medium-findings",
        severity: "medium",
        message: "required loop gate '\(gate.id)' has \(result.severityCounts.medium) medium findings; maximum is \(maxMediumFindings)"
      ))
    }
    return violations
  }
}

func loopGateParser(workflow: WorkflowDefinition) -> LoopGatePayloadParser {
  LoopGatePayloadParser(
    stepGateIdsByStepId: Dictionary(uniqueKeysWithValues: workflow.steps.compactMap { step in
      guard let gateId = step.loop?.gateId else {
        return nil
      }
      return (step.id, gateId)
    }),
    gateStepIds: Set(workflow.steps.compactMap { step in
      step.loop?.gateId != nil || step.loop?.role == "gate" ? step.id : nil
    }),
    requiredGatesById: Dictionary(uniqueKeysWithValues: (workflow.loop?.gates ?? []).compactMap { gate in
      gate.required ? (gate.id, gate) : nil
    })
  )
}

private func severityCounts(_ value: JSONValue?) -> LoopFindingSeverityCounts {
  guard case let .object(object)? = value else {
    return LoopFindingSeverityCounts()
  }
  return LoopFindingSeverityCounts(
    high: intValue(object["high"]) ?? 0,
    medium: intValue(object["medium"]) ?? 0,
    low: intValue(object["low"]) ?? 0,
    informational: intValue(object["informational"]) ?? 0
  )
}

private func blockingFindings(_ value: JSONValue?) -> [LoopBlockingFinding] {
  guard case let .array(values)? = value else {
    return []
  }
  return values.compactMap { value in
    guard case let .object(object) = value,
          let severity = stringValue(object["severity"]),
          let message = stringValue(object["message"]) else {
      return nil
    }
    return LoopBlockingFinding(
      id: stringValue(object["id"]) ?? "",
      severity: severity,
      filePath: stringValue(object["filePath"]),
      line: intValue(object["line"]),
      message: message,
      evidenceRefs: stringArray(object["evidenceRefs"])
    )
  }
}

private struct LoopGateAcceptanceViolation {
  var id: String
  var severity: String
  var message: String
}

private func residualRiskArray(_ value: JSONValue?) -> [LoopResidualRisk] {
  guard case let .array(values)? = value else {
    return []
  }
  return values.compactMap { value in
    guard case let .object(object) = value,
          let severity = stringValue(object["severity"]),
          let message = stringValue(object["message"]) else {
      return nil
    }
    return LoopResidualRisk(
      severity: severity,
      message: message,
      evidenceRefs: stringArray(object["evidenceRefs"]),
      owner: stringValue(object["owner"]),
      accepted: boolValue(object["accepted"]) ?? false
    )
  }
}

private func stringArray(_ value: JSONValue?) -> [String] {
  guard case let .array(values)? = value else {
    return []
  }
  return values.compactMap(stringValue)
}

private func stringValue(_ value: JSONValue?) -> String? {
  guard case let .string(value)? = value else {
    return nil
  }
  return value
}

private func intValue(_ value: JSONValue?) -> Int? {
  switch value {
  case .integer(let value):
    return Int(value)
  case .number(let value):
    return Int(value)
  default:
    return nil
  }
}

private func boolValue(_ value: JSONValue?) -> Bool? {
  guard case let .bool(value)? = value else {
    return nil
  }
  return value
}
