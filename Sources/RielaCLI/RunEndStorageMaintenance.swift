import Foundation
import RielaSQLite

/// Bounded run-end space reclamation. This never deletes application rows.
enum RunEndStorageMaintenance {
  private static let minimumFreePages = 128
  private static let maximumVacuumPages = 128

  static func run(sessionStoreRoots: [String]) -> [String] {
    var warnings: [String] = []
    for root in Set(sessionStoreRoots).sorted() {
      let path = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root)
      guard FileManager.default.fileExists(atPath: path) else { continue }
      do {
        let db = try SQLiteDatabase.open(path: path, mode: .readWriteCreate, options: SQLiteOpenOptions(
          enableWAL: false,
          busyTimeoutMilliseconds: 0,
          requireJSONB: false,
          waitForLocks: false
        ))
        guard try db.query("PRAGMA auto_vacuum").first?["auto_vacuum"] == "2",
              let count = try db.query("PRAGMA freelist_count").first?["freelist_count"].flatMap(Int.init),
              count >= minimumFreePages else { continue }
        _ = try db.query("PRAGMA incremental_vacuum(\(min(count, maximumVacuumPages)))")
        _ = try db.query("PRAGMA wal_checkpoint(PASSIVE)")
      } catch let error as SQLiteError where error.code.map({ $0 & 0xFF == 5 }) == true {
        continue
      } catch {
        warnings.append("riela retention warning: \(error.localizedDescription)")
      }
    }
    return warnings
  }
}
