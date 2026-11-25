import Foundation
import RielaSQLite

extension BotStore {
  public func listState(botId: String) throws -> [BotListStateKey: BotListState] {
    try read { database in
      let rows = try database.query(
        "SELECT item_kind, item_id, json(state_json) AS state_json FROM bot_list_state WHERE bot_id = ?",
        bindings: [.text(botId)]
      )
      return try rows.reduce(into: [:]) { states, row in
        guard let itemKind = row["item_kind"], let itemId = row["item_id"] else {
          throw BotStoreError(code: "bot_invalid", message: "Bot list state is missing its key")
        }
        states[BotListStateKey(itemKind: itemKind, itemId: itemId)] = try Self.decodeListState(row)
      }
    } ?? [:]
  }

  @discardableResult
  public func setListState(
    botId: String, key: BotListStateKey, _ mutate: (inout BotListState) -> Void
  ) throws -> BotListState {
    try write { database in
      guard try !database.query("SELECT 1 FROM bots WHERE bot_id = ?", bindings: [.text(botId)]).isEmpty else {
        throw BotStoreError(code: "bot_not_found", message: "Bot '\(botId)' was not found")
      }
      let bindings: [SQLiteValue] = [.text(botId), .text(key.itemKind), .text(key.itemId)]
      let predicate = "bot_id = ? AND item_kind = ? AND item_id = ?"
      let current = try database.query(
        "SELECT json(state_json) AS state_json FROM bot_list_state WHERE \(predicate)", bindings: bindings
      ).first
      var state = try current.map(Self.decodeListState) ?? BotListState()
      mutate(&state)
      if state == BotListState() {
        try database.execute("DELETE FROM bot_list_state WHERE \(predicate)", bindings: bindings)
      } else {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let json = String(data: try encoder.encode(state), encoding: .utf8) else {
          throw BotStoreError(code: "bot_invalid", message: "Bot list state could not be encoded as UTF-8 JSON")
        }
        try database.execute(
          """
          INSERT INTO bot_list_state (bot_id, item_kind, item_id, state_json, updated_at)
          VALUES (?, ?, ?, jsonb(?), ?)
          ON CONFLICT(bot_id, item_kind, item_id) DO UPDATE
          SET state_json = excluded.state_json, updated_at = excluded.updated_at
          """,
          bindings: bindings + [.text(json), .text(RoutineStore.timestamp())]
        )
      }
      return state
    }
  }

  private static func decodeListState(_ row: SQLiteRow) throws -> BotListState {
    guard let json = row["state_json"] else {
      throw BotStoreError(code: "bot_invalid", message: "Bot list state is missing its JSON")
    }
    return try JSONDecoder().decode(BotListState.self, from: Data(json.utf8))
  }
}
