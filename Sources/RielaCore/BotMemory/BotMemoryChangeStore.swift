import Foundation
import RielaSQLite

extension BotStore {
  public func insertMemoryChange(_ change: BotMemoryChangeSet) throws {
    try write { database in
      try Self.requireMemoryBot(change.botId, in: database)
      try Self.insertMemoryChange(change, in: database)
    }
  }

  public func memoryChanges(botId: String, limit: Int) throws -> [BotMemoryChangeSet] {
    try read { try Self.memoryChanges(botId: botId, limit: limit, in: $0) } ?? []
  }

  public func memoryChange(changeId: String) throws -> BotMemoryChangeSet? {
    try read { try Self.memoryChange(changeId: changeId, in: $0) } ?? nil
  }

  static func requireMemoryBot(_ botId: String, in database: SQLiteDatabase) throws {
    let rows = try database.query("SELECT 1 FROM bots WHERE bot_id = ?", bindings: [.text(botId)])
    guard !rows.isEmpty else {
      throw BotStoreError(code: "bot_not_found", message: "Bot '\(botId)' was not found")
    }
  }

  static func insertMemoryChange(_ change: BotMemoryChangeSet, in database: SQLiteDatabase) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let json = String(data: try encoder.encode(change), encoding: .utf8) else {
      throw BotStoreError(code: "memory_change_invalid", message: "Memory change could not be encoded as UTF-8")
    }
    try database.execute(
      "INSERT INTO bot_memory_changes (change_id, bot_id, record_json, created_at) VALUES (?, ?, jsonb(?), ?)",
      bindings: [.text(change.changeId), .text(change.botId), .text(json), .text(change.createdAt)]
    )
  }

  static func memoryChanges(botId: String, limit: Int, in database: SQLiteDatabase) throws -> [BotMemoryChangeSet] {
    guard limit > 0 else { return [] }
    return try database.query(
      """
      SELECT json(record_json) AS record_json FROM bot_memory_changes
      WHERE bot_id = ? ORDER BY created_at DESC, rowid DESC LIMIT ?
      """,
      bindings: [.text(botId), .int(Int64(limit))]
    ).map(decodeMemoryChange)
  }

  static func memoryChange(changeId: String, in database: SQLiteDatabase) throws -> BotMemoryChangeSet? {
    try database.query(
      "SELECT json(record_json) AS record_json FROM bot_memory_changes WHERE change_id = ?",
      bindings: [.text(changeId)]
    ).first.map(decodeMemoryChange)
  }

  private static func decodeMemoryChange(_ row: SQLiteRow) throws -> BotMemoryChangeSet {
    guard let json = row["record_json"] else {
      throw BotStoreError(code: "memory_change_invalid", message: "Memory change is missing its JSON")
    }
    return try JSONDecoder().decode(BotMemoryChangeSet.self, from: Data(json.utf8))
  }
}
