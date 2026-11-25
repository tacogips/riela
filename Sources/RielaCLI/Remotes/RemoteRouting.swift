import Foundation
import RielaCore

enum RemoteRouting {
  enum Target {
    case local
    case remote(RemoteRecord, String)
    case all
  }

  static func resolve(remote: String?, registry: RemoteRegistry, allowsAll: Bool = false) throws -> Target {
    if remote == nil, BotsRequestGrant.current?.targetsLocalByDefault == true { return .local }
    let name = try remote ?? registry.list().active
    switch name {
    case "local":
      return .local
    case "*":
      guard allowsAll else {
        throw BotStoreError(code: "remote_selector_invalid", message: "Select one remote for this operation")
      }
      return .all
    default:
      let credentials = try registry.credentials(name: name)
      return .remote(credentials.record, credentials.token)
    }
  }
}

struct RemoteLastKnown: Codable, Equatable, Sendable {
  struct Bot: Codable, Equatable, Sendable {
    let botId: String
    let name: String
    let counts: BotOverviewCounts
  }

  let observedAt: Date
  let bots: [Bot]
}
