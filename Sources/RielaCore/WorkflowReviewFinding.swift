import Foundation

public enum WorkflowReviewFindingSeverity: String, Codable, Equatable, Sendable {
  case high
  case mid
  case low

  public init?(reviewValue: String) {
    switch reviewValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "high", "blocker", "critical":
      self = .high
    case "mid", "medium", "major":
      self = .mid
    case "low", "minor":
      self = .low
    default:
      return nil
    }
  }

  public var blocksReviewRetry: Bool {
    self == .high || self == .mid
  }
}

public enum WorkflowReviewFindingStatus: String, Codable, Equatable, Sendable {
  case open
  case addressed
  case superseded
}

public struct WorkflowReviewFinding: Codable, Equatable, Sendable {
  public var id: String
  public var issueReference: String?
  public var workflowMode: String?
  public var sourceReviewStepId: String
  public var sourceStepExecutionId: String
  public var sourceExecutionAttempt: Int
  public var targetStepId: String?
  public var filePath: String?
  public var line: Int?
  public var severity: WorkflowReviewFindingSeverity
  public var message: String
  public var feedback: String?
  public var status: WorkflowReviewFindingStatus
  public var originatingSessionId: String
  public var createdAt: Date

  public init(
    id: String,
    issueReference: String? = nil,
    workflowMode: String? = nil,
    sourceReviewStepId: String,
    sourceStepExecutionId: String,
    sourceExecutionAttempt: Int,
    targetStepId: String? = nil,
    filePath: String? = nil,
    line: Int? = nil,
    severity: WorkflowReviewFindingSeverity,
    message: String,
    feedback: String? = nil,
    status: WorkflowReviewFindingStatus = .open,
    originatingSessionId: String,
    createdAt: Date
  ) {
    self.id = id
    self.issueReference = issueReference
    self.workflowMode = workflowMode
    self.sourceReviewStepId = sourceReviewStepId
    self.sourceStepExecutionId = sourceStepExecutionId
    self.sourceExecutionAttempt = sourceExecutionAttempt
    self.targetStepId = targetStepId
    self.filePath = filePath
    self.line = line
    self.severity = severity
    self.message = message
    self.feedback = feedback
    self.status = status
    self.originatingSessionId = originatingSessionId
    self.createdAt = createdAt
  }
}

public enum WorkflowReviewFindingExtractor {
  public static func extract(
    from acceptedOutput: WorkflowAcceptedOutputMetadata,
    sessionId: String,
    execution: WorkflowStepExecution
  ) -> [WorkflowReviewFinding] {
    guard case let .array(values)? = acceptedOutput.payload["findings"] else {
      return []
    }
    return values.enumerated().compactMap { index, value in
      guard case let .object(object) = value else {
        return nil
      }
      return finding(
        from: object,
        index: index,
        rootPayload: acceptedOutput.payload,
        sessionId: sessionId,
        execution: execution,
        createdAt: acceptedOutput.acceptedAt
      )
    }
  }

  private static func finding(
    from object: JSONObject,
    index: Int,
    rootPayload: JSONObject,
    sessionId: String,
    execution: WorkflowStepExecution,
    createdAt: Date
  ) -> WorkflowReviewFinding? {
    guard let severityText = stringValue(object["severity"]),
          let severity = WorkflowReviewFindingSeverity(reviewValue: severityText),
          let message = firstString([
            object["message"],
            object["requiredChange"],
            object["feedback"],
            object["evidence"],
            object["userImpact"]
          ]) else {
      return nil
    }
    return WorkflowReviewFinding(
      id: "\(sessionId)-\(execution.stepId)-attempt-\(execution.attempt)-finding-\(index + 1)",
      issueReference: firstString([object["issueReference"], rootPayload["issueReference"], rootPayload["issue"]]),
      workflowMode: firstString([object["workflowMode"], rootPayload["workflowMode"], rootPayload["mode"]]),
      sourceReviewStepId: execution.stepId,
      sourceStepExecutionId: execution.executionId,
      sourceExecutionAttempt: execution.attempt,
      targetStepId: firstString([object["targetStepId"], object["targetStep"], object["stepId"]]),
      filePath: firstString([object["filePath"], object["file"], object["path"]]),
      line: intValue(object["line"]),
      severity: severity,
      message: message,
      feedback: firstString([object["feedback"], object["requiredChange"], object["userImpact"]]),
      originatingSessionId: sessionId,
      createdAt: createdAt
    )
  }

  private static func firstString(_ values: [JSONValue?]) -> String? {
    for value in values {
      guard let string = stringValue(value), !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        continue
      }
      return string
    }
    return nil
  }

  private static func stringValue(_ value: JSONValue?) -> String? {
    guard case let .string(value)? = value else {
      return nil
    }
    return value
  }

  private static func intValue(_ value: JSONValue?) -> Int? {
    guard let int64 = value?.asInt64 else {
      return nil
    }
    return Int(exactly: int64)
  }
}

public enum WorkflowReviewFindingReplayContext {
  public static func variables(from findings: [WorkflowReviewFinding], targetStepId: String) -> JSONObject {
    let selected = unresolvedBlockingFindings(from: findings, targetStepId: targetStepId)
    guard !selected.isEmpty else {
      return [:]
    }
    return [
      "priorReviewFindings": .array(selected.map(findingJSON)),
      "priorReviewFeedback": .string(feedbackText(from: selected))
    ]
  }

  private static func unresolvedBlockingFindings(
    from findings: [WorkflowReviewFinding],
    targetStepId: String
  ) -> [WorkflowReviewFinding] {
    findings.filter { finding in
      finding.status == .open &&
        finding.severity.blocksReviewRetry &&
        (finding.targetStepId == nil || finding.targetStepId == targetStepId)
    }
  }

  private static func findingJSON(_ finding: WorkflowReviewFinding) -> JSONValue {
    var object: JSONObject = [
      "id": .string(finding.id),
      "severity": .string(finding.severity.rawValue),
      "sourceReviewStepId": .string(finding.sourceReviewStepId),
      "sourceStepExecutionId": .string(finding.sourceStepExecutionId),
      "message": .string(finding.message)
    ]
    if let issueReference = finding.issueReference {
      object["issueReference"] = .string(issueReference)
    }
    if let workflowMode = finding.workflowMode {
      object["workflowMode"] = .string(workflowMode)
    }
    if let targetStepId = finding.targetStepId {
      object["targetStepId"] = .string(targetStepId)
    }
    if let filePath = finding.filePath {
      object["filePath"] = .string(filePath)
    }
    if let line = finding.line {
      object["line"] = .number(Double(line))
    }
    if let feedback = finding.feedback {
      object["feedback"] = .string(feedback)
    }
    return .object(object)
  }

  private static func feedbackText(from findings: [WorkflowReviewFinding]) -> String {
    findings.map { finding in
      let location = [
        finding.filePath,
        finding.line.map(String.init)
      ]
        .compactMap { $0 }
        .joined(separator: ":")
      let locationText = location.isEmpty ? "" : " \(location)"
      let feedback = finding.feedback.map { " Feedback: \($0)" } ?? ""
      return "- [\(finding.severity.rawValue)]\(locationText) \(finding.message)\(feedback)"
    }
    .joined(separator: "\n")
  }
}
