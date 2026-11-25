import RielaSQLite

enum AskStoreSchema {
  static func prepare(in database: SQLiteDatabase) throws {
    try database.transaction { db in
      for statement in statements {
        try db.execute(statement)
      }
    }
  }

  private static let statements = [
    """
    CREATE TABLE IF NOT EXISTS ask_conversations (
      conversation_id TEXT PRIMARY KEY,
      record_json BLOB NOT NULL CHECK (json_valid(record_json, 8)),
      updated_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS ask_messages (
      conversation_id TEXT NOT NULL,
      seq INTEGER NOT NULL,
      record_json BLOB NOT NULL CHECK (json_valid(record_json, 8)),
      PRIMARY KEY (conversation_id, seq)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS ask_actions (
      action_id TEXT PRIMARY KEY,
      conversation_id TEXT NOT NULL,
      record_json BLOB NOT NULL CHECK (json_valid(record_json, 8)),
      status TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_ask_actions_conversation ON ask_actions (conversation_id)"
  ]
}
