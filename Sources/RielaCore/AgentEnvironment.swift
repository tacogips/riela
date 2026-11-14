import Foundation

public struct AgentEnvironmentBinding: Codable, Equatable, Sendable {
  public var value: String?
  public var fromEnv: String?
  public var required: Bool

  public init(value: String) {
    self.value = value
    self.fromEnv = nil
    self.required = false
  }

  public init(fromEnv: String, required: Bool = false) {
    self.value = nil
    self.fromEnv = fromEnv
    self.required = required
  }

  enum CodingKeys: String, CodingKey {
    case value
    case fromEnv
    case required
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.value = try container.decodeIfPresent(String.self, forKey: .value)
    self.fromEnv = try container.decodeIfPresent(String.self, forKey: .fromEnv)
    self.required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false

    let sourceCount = [value != nil, fromEnv != nil].filter { $0 }.count
    guard sourceCount == 1 else {
      throw DecodingError.dataCorruptedError(
        forKey: .value,
        in: container,
        debugDescription: "agentEnvironment binding must specify exactly one of value or fromEnv"
      )
    }
    if value != nil, required {
      throw DecodingError.dataCorruptedError(
        forKey: .required,
        in: container,
        debugDescription: "agentEnvironment required is only valid with fromEnv"
      )
    }
    if let fromEnv, !isValidEnvironmentVariableName(fromEnv) {
      throw DecodingError.dataCorruptedError(
        forKey: .fromEnv,
        in: container,
        debugDescription: "agentEnvironment fromEnv must be a valid environment variable name"
      )
    }
  }
}

public enum AgentEnvironmentResolutionError: Error, Equatable, Sendable {
  case invalidTargetName(String)
  case reservedTargetName(String)
  case missingRequiredSource(targetName: String, sourceName: String)
}

extension AgentEnvironmentResolutionError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .invalidTargetName(name):
      return "agentEnvironment target '\(name)' must be a valid environment variable name"
    case let .reservedTargetName(name):
      return "agentEnvironment target '\(name)' is reserved by Riela"
    case let .missingRequiredSource(targetName, sourceName):
      return "agentEnvironment target '\(targetName)' requires runtime environment '\(sourceName)'"
    }
  }
}

public let reservedAgentEnvironmentNames: Set<String> = [
  "RIELA_AGENT_BACKEND",
  "RIELA_WORKFLOW_ID",
  "RIELA_SESSION_ID",
  "RIELA_STEP_ID",
  "RIELA_NODE_ID",
  "RIELA_EXECUTION_INDEX"
]

public func isValidEnvironmentVariableName(_ name: String) -> Bool {
  guard let first = name.unicodeScalars.first else {
    return false
  }
  guard first == "_" || CharacterSet.letters.contains(first) else {
    return false
  }
  return name.unicodeScalars.allSatisfy { scalar in
    scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
  }
}

public func resolveAgentEnvironment(
  _ bindings: [String: AgentEnvironmentBinding],
  variables: JSONObject,
  runtimeEnvironment: [String: String] = ProcessInfo.processInfo.environment
) throws -> [String: String] {
  var resolved: [String: String] = [:]
  for key in bindings.keys.sorted() {
    guard isValidEnvironmentVariableName(key) else {
      throw AgentEnvironmentResolutionError.invalidTargetName(key)
    }
    guard !reservedAgentEnvironmentNames.contains(key) else {
      throw AgentEnvironmentResolutionError.reservedTargetName(key)
    }
    guard let binding = bindings[key] else {
      continue
    }
    if let value = binding.value {
      resolved[key] = renderPromptTemplate(value, variables: variables)
      continue
    }
    guard let sourceName = binding.fromEnv else {
      continue
    }
    if let sourceValue = runtimeEnvironment[sourceName], !sourceValue.isEmpty {
      resolved[key] = sourceValue
    } else if binding.required {
      throw AgentEnvironmentResolutionError.missingRequiredSource(targetName: key, sourceName: sourceName)
    }
  }
  return resolved
}
