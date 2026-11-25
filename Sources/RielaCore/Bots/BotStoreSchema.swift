import RielaSQLite

enum BotStoreSchema {
  static func prepare(in db: SQLiteDatabase) throws {
    try db.requireJSONBAvailable()
    try SQLiteWorkflowRuntimePersistenceStore.requireCompatibleSchemaGeneration(in: db)
    try db.transaction { try createTables(in: $0) }
  }

  static func createTables(in db: SQLiteDatabase) throws {
    for statement in statements {
      try db.execute(statement)
    }
  }

  private static let statements = [
    """
    CREATE TABLE IF NOT EXISTS bots (
      bot_id TEXT PRIMARY KEY,
      record_json BLOB NOT NULL CHECK (json_valid(record_json, 8)),
      name TEXT GENERATED ALWAYS AS (json_extract(record_json, '$.name')) STORED,
      paused INTEGER GENERATED ALWAYS AS (json_extract(record_json, '$.paused')) STORED,
      updated_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS bot_session_links (
      session_id TEXT PRIMARY KEY,
      bot_id TEXT NOT NULL,
      source TEXT NOT NULL,
      source_ref TEXT,
      linked_at TEXT NOT NULL
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_bot_session_links_bot ON bot_session_links (bot_id, linked_at)",
    """
    CREATE TABLE IF NOT EXISTS bot_list_state (
      bot_id TEXT NOT NULL,
      item_kind TEXT NOT NULL,
      item_id TEXT NOT NULL,
      state_json BLOB NOT NULL,
      updated_at TEXT NOT NULL,
      PRIMARY KEY (bot_id, item_kind, item_id)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS bot_suggestions (
      suggestion_id TEXT PRIMARY KEY,
      bot_id TEXT NOT NULL,
      record_json BLOB NOT NULL,
      status TEXT GENERATED ALWAYS AS (json_extract(record_json, '$.status')) STORED,
      created_at TEXT NOT NULL
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_bot_suggestions_bot ON bot_suggestions (bot_id, status)",
    """
    CREATE TABLE IF NOT EXISTS bot_job_runs (
      bot_id TEXT NOT NULL,
      job TEXT NOT NULL,
      period_key TEXT NOT NULL,
      status TEXT NOT NULL,
      session_id TEXT,
      detail TEXT,
      started_at TEXT NOT NULL,
      finished_at TEXT,
      PRIMARY KEY (bot_id, job, period_key)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS bot_memory_changes (
      change_id TEXT PRIMARY KEY,
      bot_id TEXT NOT NULL,
      record_json BLOB NOT NULL,
      created_at TEXT NOT NULL
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_bot_memory_changes_bot ON bot_memory_changes (bot_id, created_at)",
    """
    CREATE TABLE IF NOT EXISTS activity_events (
      session_id TEXT NOT NULL,
      seq INTEGER NOT NULL,
      execution_id TEXT,
      at TEXT NOT NULL,
      kind TEXT NOT NULL,
      payload_json BLOB NOT NULL,
      PRIMARY KEY (session_id, seq)
    ) WITHOUT ROWID
    """,
    """
    CREATE TABLE IF NOT EXISTS activity_state (
      session_id TEXT PRIMARY KEY,
      state_json BLOB NOT NULL,
      last_seq INTEGER NOT NULL,
      first_retained_seq INTEGER NOT NULL,
      source TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS activity_requests (
      request_id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL,
      execution_id TEXT,
      tool_call_id TEXT,
      title TEXT,
      options_json BLOB NOT NULL,
      status TEXT NOT NULL,
      outcome_option_id TEXT,
      resolved_by TEXT,
      created_at TEXT NOT NULL,
      expires_at TEXT NOT NULL,
      resolved_at TEXT
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_activity_requests_session ON activity_requests (session_id, status)",
    """
    CREATE TABLE IF NOT EXISTS provider_instances (
      instance_id TEXT PRIMARY KEY,
      record_json BLOB NOT NULL,
      updated_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS provider_reports (
      instance_id TEXT PRIMARY KEY,
      report_json BLOB NOT NULL,
      observed_at TEXT NOT NULL
    )
    """
  ]
}
