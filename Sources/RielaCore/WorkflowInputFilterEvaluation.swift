import Foundation
import RielaJavaScript

public enum WorkflowInputFilterIssueCode: String, Codable, Equatable, Sendable {
  case unsupportedKind = "unsupported-kind"
  case unsupportedLanguage = "unsupported-language"
  case parseError = "parse-error"
  case evaluationError = "evaluation-error"
}

public struct WorkflowInputFilterIssue: Codable, Equatable, Sendable {
  public var code: WorkflowInputFilterIssueCode
  public var stepId: String
  public var nodeId: String
  public var filterIndex: Int
  public var message: String

  public init(
    code: WorkflowInputFilterIssueCode,
    stepId: String,
    nodeId: String,
    filterIndex: Int,
    message: String
  ) {
    self.code = code
    self.stepId = stepId
    self.nodeId = nodeId
    self.filterIndex = filterIndex
    self.message = message
  }
}

public struct WorkflowInputFilterDecision: Equatable, Sendable {
  public var shouldRun: Bool
  public var matchedFilterIndex: Int?
  public var issues: [WorkflowInputFilterIssue]

  public init(shouldRun: Bool, matchedFilterIndex: Int? = nil, issues: [WorkflowInputFilterIssue] = []) {
    self.shouldRun = shouldRun
    self.matchedFilterIndex = matchedFilterIndex
    self.issues = issues
  }
}

public protocol WorkflowInputFilterLogging: Sendable {
  func log(_ issue: WorkflowInputFilterIssue)
}

public struct StandardErrorWorkflowInputFilterLogger: WorkflowInputFilterLogging {
  public init() {}

  public func log(_ issue: WorkflowInputFilterIssue) {
    let message = "riela input-filter \(issue.code.rawValue) step=\(issue.stepId) node=\(issue.nodeId) filter=\(issue.filterIndex): \(issue.message)\n"
    if let data = message.data(using: .utf8) {
      FileHandle.standardError.write(data)
    }
  }
}

public struct NoopWorkflowInputFilterLogger: WorkflowInputFilterLogging {
  public init() {}

  public func log(_ issue: WorkflowInputFilterIssue) {}
}

public struct WorkflowInputFilterEvaluator: Sendable {
  public init() {}

  public func evaluate(
    filters: [WorkflowInputFilter],
    variables: JSONObject,
    stepId: String,
    nodeId: String
  ) -> WorkflowInputFilterDecision {
    var issues: [WorkflowInputFilterIssue] = []

    for (index, filter) in filters.enumerated() {
      guard filter.language == .javascript else {
        issues.append(issue(.unsupportedLanguage, stepId: stepId, nodeId: nodeId, filterIndex: index, message: "only javascript filters are supported"))
        continue
      }
      let roots: [String: Any]
      do {
        roots = try javascriptRoots(for: filter.kind, variables: variables)
      } catch {
        issues.append(issue(.parseError, stepId: stepId, nodeId: nodeId, filterIndex: index, message: "\(error)"))
        continue
      }
      do {
        if try JavaScriptCoreBooleanEvaluator().evaluateBoolean(expression: filter.expression, variables: roots) {
          return WorkflowInputFilterDecision(shouldRun: true, matchedFilterIndex: index, issues: issues)
        }
      } catch let error as JavaScriptBooleanEvaluationError {
        let code: WorkflowInputFilterIssueCode = switch error {
        case .syntaxError:
          .parseError
        case .contextCreationFailed, .exception, .nonBooleanResult:
          .evaluationError
        }
        issues.append(issue(code, stepId: stepId, nodeId: nodeId, filterIndex: index, message: "\(error)"))
      } catch {
        issues.append(issue(.evaluationError, stepId: stepId, nodeId: nodeId, filterIndex: index, message: "\(error)"))
      }
    }

    return WorkflowInputFilterDecision(shouldRun: false, issues: issues)
  }

  private func issue(
    _ code: WorkflowInputFilterIssueCode,
    stepId: String,
    nodeId: String,
    filterIndex: Int,
    message: String
  ) -> WorkflowInputFilterIssue {
    WorkflowInputFilterIssue(
      code: code,
      stepId: stepId,
      nodeId: nodeId,
      filterIndex: filterIndex,
      message: message
    )
  }

  private func javascriptRoots(for kind: WorkflowInputFilterKind, variables: JSONObject) throws -> [String: Any] {
    let workflowInput = objectValue(variables["workflowInput"]) ?? [:]
    let event = objectValue(variables["event"])
    var roots: [String: Any] = [
      "workflowInput": workflowInput.foundationObject,
      "input": (objectValue(event?["input"]) ?? workflowInput).foundationObject
    ]
    if let event {
      roots["event"] = event.foundationObject
    }

    switch kind {
    case .telegram:
      roots["telegram"] = try telegramRoot(event: event, workflowInput: workflowInput).foundationObject
    case let .custom(kind):
      throw WorkflowInputFilterParseError.unsupportedKind(kind)
    }
    return roots
  }

  private func telegramRoot(event: JSONObject?, workflowInput: JSONObject) throws -> JSONObject {
    let input = objectValue(event?["input"]) ?? workflowInput
    guard stringValue(event?["provider"]) == "telegram" || stringValue(input["provider"]) == "telegram" else {
      throw WorkflowInputFilterParseError.providerMismatch(expected: "telegram")
    }

    let actor = objectValue(event?["actor"]) ?? [:]
    let conversation = objectValue(event?["conversation"]) ?? objectValue(event?["chat"]) ?? [:]
    let chat = objectValue(event?["chat"]) ?? conversation
    let eventMessage = objectValue(event?["message"]) ?? [:]
    var message: JSONObject = [
      "text": input["text"] ?? eventMessage["text"] ?? .string(""),
      "attachments": input["attachments"] ?? eventMessage["attachments"] ?? .array([]),
      "imagePaths": input["imagePaths"] ?? eventMessage["imagePaths"] ?? .array([]),
      "attachmentText": input["attachmentText"] ?? eventMessage["attachmentText"] ?? .string("")
    ]
    if let threadId = conversation["threadId"] {
      message["threadId"] = threadId
    }
    return [
      "sourceId": event?["sourceId"] ?? .string(""),
      "eventId": event?["eventId"] ?? .string(""),
      "actor": .object(actor),
      "conversation": .object(conversation),
      "chat": .object(chat),
      "message": .object(message),
      "input": .object(input)
    ]
  }
}

private enum WorkflowInputFilterParseError: Error, CustomStringConvertible {
  case unsupportedKind(String)
  case providerMismatch(expected: String)

  var description: String {
    switch self {
    case let .unsupportedKind(kind):
      "unsupported input filter kind '\(kind)'"
    case let .providerMismatch(expected):
      "event input is not a \(expected) event"
    }
  }
}

private func objectValue(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object)? = value else {
    return nil
  }
  return object
}

private func stringValue(_ value: JSONValue?) -> String? {
  guard case let .string(string)? = value else {
    return nil
  }
  return string
}

private extension JSONValue {
  var foundationObject: Any {
    switch self {
    case .null:
      NSNull()
    case let .bool(value):
      value
    case let .number(value):
      value
    case let .string(value):
      value
    case let .array(values):
      values.map(\.foundationObject)
    case let .object(object):
      object.foundationObject
    }
  }
}

private extension Dictionary where Key == String, Value == JSONValue {
  var foundationObject: [String: Any] {
    mapValues(\.foundationObject)
  }
}
