import Foundation

/// Credential-free projection of the runtime's selected Kaiba instance. Credential
/// values travel only through the container environment, never this record.
public struct BuiltinAddonKaibaInstance: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var endpoint: String
  public var credentialEnvironmentVariable: String?
  public var allowInsecureHTTP: Bool
  public var allowRemoteUnauthenticated: Bool

  public init(
    id: String,
    name: String,
    endpoint: String,
    credentialEnvironmentVariable: String?,
    allowInsecureHTTP: Bool,
    allowRemoteUnauthenticated: Bool
  ) {
    self.id = id
    self.name = name
    self.endpoint = endpoint
    self.credentialEnvironmentVariable = credentialEnvironmentVariable
    self.allowInsecureHTTP = allowInsecureHTTP
    self.allowRemoteUnauthenticated = allowRemoteUnauthenticated
  }
}
