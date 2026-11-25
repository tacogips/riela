import Foundation
import RielaCore

func botBoardActivitySessionId(in groups: [[BotBoardItem]], botId: String) throws -> String {
  for group in groups {
    let newest = group.filter { $0.sessionId != nil }.max {
      let lhs = $0.bumpedAt ?? $0.lastActivityAt ?? .distantPast
      let rhs = $1.bumpedAt ?? $1.lastActivityAt ?? .distantPast
      return lhs == rhs ? $0.itemId > $1.itemId : lhs < rhs
    }
    if let sessionId = newest?.sessionId { return sessionId }
  }
  throw BotStoreError(code: "bot_no_activity", message: "Bot '\(botId)' has no session activity")
}
