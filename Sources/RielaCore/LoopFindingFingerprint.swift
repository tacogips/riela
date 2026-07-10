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

  func result(from payload: JSONObject, execution: WorkflowStepExecution) -> LoopGateResult {
    let decision = stringValue(payload["decision"]).flatMap(LoopGateDecision.init(rawValue:)) ?? .needsWork
    return LoopGateResult(
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
  }
}

func loopGateParser(workflow: WorkflowDefinition) -> LoopGatePayloadParser {
  LoopGatePayloadParser(stepGateIdsByStepId: Dictionary(uniqueKeysWithValues: workflow.steps.compactMap { step in
    guard let gateId = step.loop?.gateId else {
      return nil
    }
    return (step.id, gateId)
  }))
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
          let id = stringValue(object["id"]),
          let severity = stringValue(object["severity"]),
          let message = stringValue(object["message"]) else {
      return nil
    }
    return LoopBlockingFinding(
      id: id,
      severity: severity,
      filePath: stringValue(object["filePath"]),
      line: intValue(object["line"]),
      message: message,
      evidenceRefs: stringArray(object["evidenceRefs"])
    )
  }
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
