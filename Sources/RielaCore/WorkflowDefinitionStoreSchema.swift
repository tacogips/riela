import Foundation
import RielaSQLite

enum WorkflowDefinitionStoreSchema {
  static func shouldDiscardIncompatibleStore(
    _ database: SQLiteDatabase,
    currentGeneration: Int64,
    migrations: [SQLiteSchemaMigration]
  ) throws -> Bool {
    let version = try SQLiteSchemaMigrator.stampedGeneration(in: database)
    guard version < currentGeneration,
          !SQLiteSchemaMigrator.hasCompletePath(from: version, to: currentGeneration, migrations: migrations) else {
      return false
    }
    let hasHeadTable = try database.tableExists("definition_heads")
    let hasDefinitionHeads: Bool
    if hasHeadTable {
      hasDefinitionHeads = try !database.query("SELECT 1 FROM definition_heads LIMIT 1").isEmpty
    } else {
      hasDefinitionHeads = false
    }
    guard !hasDefinitionHeads else { return false }
    let hasSnapshots = try database.tableExists("workflow_runtime_snapshots")
    let hasCLISessions = try database.tableExists("cli_workflow_sessions")
    let hasMessages = try database.tableExists("workflow_messages")
    return hasSnapshots || hasCLISessions || hasMessages
  }

  static func create(in database: SQLiteDatabase) throws {
    try WorkflowDefinitionHistorySchema.create(in: database)
  }
}
