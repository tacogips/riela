import Foundation

public struct BotOrigin: Codable, Equatable, Sendable {
  public var remote: String
  public var serverId: String?
  public var serverName: String?
  public var verified: Bool
  public var connection: String
  public var observedAt: Date

  public init(
    remote: String, serverId: String?, serverName: String?, verified: Bool, connection: String, observedAt: Date
  ) {
    self.remote = remote
    self.serverId = serverId
    self.serverName = serverName
    self.verified = verified
    self.connection = connection
    self.observedAt = observedAt
  }

  public static func local(serverId: String?, serverName: String?, at: Date) -> Self {
    Self(remote: "local", serverId: serverId, serverName: serverName, verified: true, connection: "connected", observedAt: at)
  }
}
