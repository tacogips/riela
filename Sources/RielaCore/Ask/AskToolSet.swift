public enum AskToolKind: String, Codable, Equatable, Sendable {
  case read, propose
}

public enum AskToolArgumentType: String, Codable, Equatable, Sendable {
  case string, integer, boolean, object
}

public struct AskToolArgument: Codable, Equatable, Sendable {
  public let name: String
  public let type: AskToolArgumentType
  public let required: Bool
  public let minimum: Int?
  public let maximum: Int?
  public let defaultValue: JSONValue?

  static func text(_ name: String, required: Bool = false) -> Self {
    Self(name: name, type: .string, required: required, minimum: nil, maximum: nil, defaultValue: nil)
  }

  static func integer(_ name: String, minimum: Int = 1, maximum: Int? = nil, required: Bool = false, defaultValue: Int64? = nil) -> Self {
    Self(name: name, type: .integer, required: required, minimum: minimum, maximum: maximum, defaultValue: defaultValue.map(JSONValue.integer))
  }

  static func boolean(_ name: String) -> Self {
    Self(name: name, type: .boolean, required: false, minimum: nil, maximum: nil, defaultValue: nil)
  }

  static func object(_ name: String) -> Self {
    Self(name: name, type: .object, required: true, minimum: nil, maximum: nil, defaultValue: nil)
  }

  fileprivate func accepts(_ value: JSONValue) -> Bool {
    switch (type, value) {
    case (.string, .string), (.boolean, .bool), (.object, .object):
      return true
    case (.integer, .integer), (.integer, .number):
      guard let value = value.asInt64 else { return false }
      return minimum.map { value >= $0 } != false && maximum.map { value <= $0 } != false
    default:
      return false
    }
  }
}

public struct AskToolDescriptor: Codable, Equatable, Sendable {
  public let name: String
  public let kind: AskToolKind
  public let arguments: [AskToolArgument]

  init(_ name: String, _ arguments: [AskToolArgument] = [], kind: AskToolKind = .read) {
    self.name = name
    self.kind = kind
    self.arguments = arguments
  }
}

public enum AskToolSet {
  public static let all: [AskToolDescriptor] = [
    .init("session_list", [.text("workflowName"), .text("status"), .integer("limit", maximum: 50, defaultValue: 20)]),
    .init("session_status", [.text("sessionId", required: true)]),
    .init("session_progress", [.text("sessionId", required: true), .boolean("includeChildren")]),
    .init("session_health", [.text("sessionId", required: true)]),
    .init("session_logs", [
      .text("sessionId", required: true), .text("stepExecutionId"), .integer("tail", maximum: 200, defaultValue: 80), .text("contains")
    ]),
    .init("ops_overview"),
    .init("bot_list"),
    .init("bot_board", [.text("botId", required: true)]),
    .init("bot_activity", [.text("sessionId"), .text("botId"), .integer("afterSequence", minimum: 0), .integer("limit", maximum: 100, required: true)]),
    .init("routine_list", [.text("status")]),
    .init("workflow_list", [.text("query")]),
    .init("workflow_inspect", [.text("workflowId", required: true)]),
    .init("workflow_validate", [.text("workflowId", required: true)]),
    .init("definition_history", [.text("workflowName", required: true), .integer("limit", maximum: 50, required: true)]),
    .init("model_catalog", [.text("providerInstanceId")]),
    .init("remote_list"),
    .init("propose_action", [.text("kind", required: true), .object("target"), .text("reason")], kind: .propose),
    .init("propose_workflow", [.object("definition"), .text("baseWorkflowId")], kind: .propose)
  ]

  public static func validate(name: String, arguments: JSONObject) throws -> JSONObject {
    guard let descriptor = all.first(where: { $0.name == name }) else {
      throw AskError(code: "tool_unknown", message: "Unknown Ask tool")
    }
    var validated: JSONObject = [:]
    for argument in descriptor.arguments {
      if let value = arguments[argument.name] {
        guard argument.accepts(value) else { throw invalidArguments }
        validated[argument.name] = argument.type == .integer ? value.asInt64.map(JSONValue.integer) : value
      } else if let value = argument.defaultValue {
        validated[argument.name] = value
      } else if argument.required {
        throw invalidArguments
      }
    }
    guard Set(arguments.keys).isSubset(of: Set(descriptor.arguments.map(\.name))) else { throw invalidArguments }
    if name == "bot_activity", (validated["sessionId"] == nil) == (validated["botId"] == nil) {
      throw invalidArguments
    }
    return validated
  }

  private static var invalidArguments: AskError {
    AskError(code: "tool_arguments_invalid", message: "Arguments do not match the Ask tool schema")
  }
}

public struct AskToolFailure: Codable, Equatable, Sendable {
  public let code: String
  public let message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }
}

public struct AskToolResult: Codable, Equatable, Sendable {
  public let ok: Bool
  public let data: JSONValue?
  public let error: AskToolFailure?
  public let refs: [AskRef]
  public let truncated: Bool

  public init(ok: Bool, data: JSONValue? = nil, error: AskToolFailure? = nil, refs: [AskRef] = [], truncated: Bool = false) {
    self.ok = ok
    self.data = data
    self.error = error
    self.refs = refs
    self.truncated = truncated
  }
}
