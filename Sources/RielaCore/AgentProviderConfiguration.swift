import Foundation

public enum AgentProviderConfigurationError: Error, Equatable, LocalizedError, Sendable {
  case invalidName
  case invalidBaseURL
  case invalidAPIKeyEnvironmentName
  case reservedAPIKeyEnvironmentName(String)

  public var errorDescription: String? {
    switch self {
    case .invalidName:
      "provider.name must match [a-z0-9][a-z0-9_-]* and contain at most 64 characters"
    case .invalidBaseURL:
      "provider.baseUrl must be an absolute https URL or a loopback-only http URL without userinfo"
    case .invalidAPIKeyEnvironmentName:
      "provider.apiKeyEnv must be a valid environment variable name"
    case let .reservedAPIKeyEnvironmentName(name):
      "provider.apiKeyEnv '\(name)' is reserved by Riela"
    }
  }
}

public enum AgentProviderProxy: String, Codable, Equatable, Sendable {
  case codex
}

public struct AgentProviderConfiguration: Codable, Equatable, Sendable {
  public let name: String
  public let baseUrl: String
  public let apiKeyEnv: String?

  public init(name: String, baseUrl: String, apiKeyEnv: String? = nil) throws {
    guard name.count <= 64,
      name.range(of: #"^[a-z0-9][a-z0-9_-]*$"#, options: .regularExpression) != nil else {
      throw AgentProviderConfigurationError.invalidName
    }
    guard isValidProviderBaseURL(baseUrl) else {
      throw AgentProviderConfigurationError.invalidBaseURL
    }
    if let apiKeyEnv {
      guard isValidEnvironmentVariableName(apiKeyEnv) else {
        throw AgentProviderConfigurationError.invalidAPIKeyEnvironmentName
      }
      guard !reservedAgentEnvironmentNames.contains(apiKeyEnv) else {
        throw AgentProviderConfigurationError.reservedAPIKeyEnvironmentName(apiKeyEnv)
      }
    }
    self.name = name
    self.baseUrl = baseUrl
    self.apiKeyEnv = apiKeyEnv
  }

  enum CodingKeys: String, CodingKey {
    case name
    case baseUrl
    case apiKeyEnv
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let name = try container.decode(String.self, forKey: .name)
    let baseUrl = try container.decode(String.self, forKey: .baseUrl)
    let apiKeyEnv = try container.decodeIfPresent(String.self, forKey: .apiKeyEnv)
    do {
      try self.init(name: name, baseUrl: baseUrl, apiKeyEnv: apiKeyEnv)
    } catch let error as AgentProviderConfigurationError {
      let key: CodingKeys = switch error {
      case .invalidName: .name
      case .invalidBaseURL: .baseUrl
      case .invalidAPIKeyEnvironmentName, .reservedAPIKeyEnvironmentName: .apiKeyEnv
      }
      throw DecodingError.dataCorruptedError(
        forKey: key,
        in: container,
        debugDescription: error.localizedDescription
      )
    }
  }
}

private func isValidProviderBaseURL(_ value: String) -> Bool {
  guard let components = URLComponents(string: value),
    let scheme = components.scheme?.lowercased(),
    let host = components.host?.lowercased(),
    !host.isEmpty,
    components.user == nil,
    components.password == nil,
    components.query == nil,
    components.fragment == nil else {
    return false
  }
  if scheme == "https" {
    return true
  }
  return scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
}
