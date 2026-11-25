import Foundation

public struct RielaServerIdentity: Codable, Equatable, Sendable {
  public let serverId: String
  public let name: String

  public init(serverId: String, name: String) {
    self.serverId = serverId
    self.name = name
  }

  public static func loadOrCreate(root: URL, name: String?) throws -> Self {
    let store = RielaAPIKeyStore(root: root)
    return try store.withStoreLock {
      let file = root.appendingPathComponent("server-identity.json")
      let identity: Self
      if let data = try RielaAPIKeyStore.readRegularFile(file) {
        let existing = try JSONDecoder().decode(Self.self, from: data)
        guard let name, name != existing.name else { return existing }
        identity = Self(serverId: existing.serverId, name: name)
      } else {
        identity = Self(serverId: UUID().uuidString.lowercased(), name: name ?? ProcessInfo.processInfo.hostName)
      }
      try RielaAPIKeyStore.persist(try JSONEncoder().encode(identity), to: file)
      return identity
    }
  }
}
