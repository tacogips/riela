import Foundation
import RielaSQLite

enum RetentionReclamationMode: String, Codable, Sendable {
  case automatic
  case manual
}

enum RetentionReclamationAction: String, Codable, Sendable {
  case none
  case incrementalVacuum
  case converted
  case deferredInsufficientSpace
  case deferredAutomaticSizeLimit
  case checkpointPending
  case busy
  case diskFull
  case failed
}

struct RetentionReclamationResult: Codable, Equatable, Sendable {
  var database: String
  var autoVacuum: String
  var action: RetentionReclamationAction
  var fileBytesBefore: Int64
  var fileBytesAfter: Int64
  var reclaimedBytes: Int64
  var reusableFreeBytes: Int64
  var warning: String?
}

struct RetentionSQLiteReclaimer: Sendable {
  var freeSpace: @Sendable (String) -> Int64? = { path in
    guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path) else { return nil }
    return (attributes[.systemFreeSize] as? NSNumber)?.int64Value
  }
  var automaticConversionLimitBytes: Int64 = 64 << 20
  var automaticPageBudget: Int = 65_536
  var statementObserver: (@Sendable (String) -> Void)?

  func reclaim(databasePath: String, mode: RetentionReclamationMode) -> RetentionReclamationResult {
    let before = fileBytes(at: databasePath)
    var result = RetentionReclamationResult(
      database: databasePath,
      autoVacuum: "unknown",
      action: .none,
      fileBytesBefore: before,
      fileBytesAfter: before,
      reclaimedBytes: 0,
      reusableFreeBytes: 0,
      warning: nil
    )
    guard FileManager.default.fileExists(atPath: databasePath) else { return result }

    var database: SQLiteDatabase?
    do {
      database = try SQLiteDatabase.open(
        path: databasePath,
        mode: .readWriteCreate,
        options: SQLiteOpenOptions(
          enableWAL: false,
          busyTimeoutMilliseconds: 250,
          requireJSONB: false,
          waitForLocks: false
        )
      )
      guard let database else { return result }
      _ = try query("PRAGMA journal_size_limit=67108864", database: database)
      let autoVacuum = try pragmaInteger("PRAGMA auto_vacuum", column: "auto_vacuum", database: database)
      result.autoVacuum = autoVacuumName(autoVacuum)
      let pageSize = try pragmaInteger("PRAGMA page_size", column: "page_size", database: database)
      let freelistCount = try pragmaInteger("PRAGMA freelist_count", column: "freelist_count", database: database)

      switch autoVacuum {
      case 2:
        let vacuumSQL = mode == .automatic
          ? "PRAGMA incremental_vacuum(\(max(0, automaticPageBudget)))"
          : "PRAGMA incremental_vacuum"
        _ = try query(vacuumSQL, database: database)
        result.action = try checkpoint(database) ? .checkpointPending : .incrementalVacuum
      case 1:
        result.action = try checkpoint(database) ? .checkpointPending : .none
      default:
        result.action = try convertIfAllowed(
          database: database,
          databasePath: databasePath,
          fileBytes: before,
          mode: mode
        )
      }
      result.reusableFreeBytes = max(0, pageSize) * max(0, freelistCount)
      if result.action == .converted || result.action == .incrementalVacuum || result.action == .checkpointPending {
        let finalPageSize = try? pragmaInteger("PRAGMA page_size", column: "page_size", database: database)
        let finalFreelist = try? pragmaInteger("PRAGMA freelist_count", column: "freelist_count", database: database)
        if let finalPageSize, let finalFreelist {
          result.reusableFreeBytes = max(0, finalPageSize) * max(0, finalFreelist)
        }
      }
    } catch let error as SQLiteError {
      result.action = action(for: error)
      result.warning = error.message
    } catch {
      result.action = .failed
      result.warning = String(describing: error)
    }

    if result.action == .busy || result.action == .diskFull || result.action == .failed {
      result.reusableFreeBytes = reusableFreeBytes(database)
    }
    // Close before measuring: while this connection is open the converted pages are still in
    // the WAL, so the files only settle once the last connection checkpoints on close.
    database = nil
    result.fileBytesAfter = fileBytes(at: databasePath)
    result.reclaimedBytes = max(0, result.fileBytesBefore - result.fileBytesAfter)
    return result
  }

  private func convertIfAllowed(
    database: SQLiteDatabase,
    databasePath: String,
    fileBytes: Int64,
    mode: RetentionReclamationMode
  ) throws -> RetentionReclamationAction {
    if mode == .automatic, fileBytes > automaticConversionLimitBytes {
      return .deferredAutomaticSizeLimit
    }
    let directory = URL(fileURLWithPath: databasePath).deletingLastPathComponent().path
    guard let available = freeSpace(directory),
          let doubledSize = checkedMultiply(fileBytes, 2),
          let required = checkedAdd(doubledSize, 256 << 20),
          available >= required else {
      return .deferredInsufficientSpace
    }
    try execute("PRAGMA auto_vacuum=INCREMENTAL", database: database)
    try execute("VACUUM", database: database)
    _ = try checkpoint(database)
    return .converted
  }

  private func checkpoint(_ database: SQLiteDatabase) throws -> Bool {
    let rows = try query("PRAGMA wal_checkpoint(PASSIVE)", database: database)
    guard let row = rows.first else { return true }
    let busy = Int64(row["busy"] ?? "1") ?? 1
    let log = Int64(row["log"] ?? "-1") ?? -1
    let checkpointed = Int64(row["checkpointed"] ?? "-2") ?? -2
    return busy == 1 || log != checkpointed
  }

  private func pragmaInteger(_ sql: String, column: String, database: SQLiteDatabase) throws -> Int64 {
    guard let value = try query(sql, database: database).first?[column],
          let integer = Int64(value) else {
      throw SQLiteError(operation: .query, code: nil, message: "missing integer result for \(sql)", sql: sql)
    }
    return integer
  }

  private func query(_ sql: String, database: SQLiteDatabase) throws -> [SQLiteRow] {
    statementObserver?(sql)
    return try database.query(sql)
  }

  private func execute(_ sql: String, database: SQLiteDatabase) throws {
    statementObserver?(sql)
    try database.execute(sql)
  }

  private func reusableFreeBytes(_ database: SQLiteDatabase?) -> Int64 {
    guard let database,
          let pageSize = try? pragmaInteger("PRAGMA page_size", column: "page_size", database: database),
          let freelistCount = try? pragmaInteger("PRAGMA freelist_count", column: "freelist_count", database: database) else { return 0 }
    return max(0, pageSize) * max(0, freelistCount)
  }

  private func fileBytes(at databasePath: String) -> Int64 {
    size(at: databasePath) + size(at: databasePath + "-wal")
  }

  private func size(at path: String) -> Int64 {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attributes[.size] as? NSNumber else { return 0 }
    return max(0, size.int64Value)
  }

  private func autoVacuumName(_ value: Int64) -> String {
    switch value {
    case 0: "none"
    case 1: "full"
    case 2: "incremental"
    default: "unknown"
    }
  }

  private func action(for error: SQLiteError) -> RetentionReclamationAction {
    switch error.code {
    case 5, 6: .busy
    case 13: .diskFull
    default: .failed
    }
  }

  private func checkedMultiply(_ lhs: Int64, _ rhs: Int64) -> Int64? {
    let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
    return overflow ? nil : value
  }

  private func checkedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64? {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? nil : value
  }
}
