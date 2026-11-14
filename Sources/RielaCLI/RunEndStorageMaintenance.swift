import Foundation
import RielaSQLite

/// Bounded run-end space reclamation. This never deletes application rows.
enum RunEndStorageMaintenance {
  private static let minimumFreePages = 128

  static func run(targets: [RetentionTarget], profile: StorageMaintenanceProfile,
                  now: @escaping () -> Date = Date.init) -> [String] {
    var warnings: [String] = []
    for target in targets {
      guard target.unsafeReason == nil, let root = target.sessionStoreRoot else { continue }
      let path = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root)
      guard FileManager.default.fileExists(atPath: path) else { continue }
      do {
        guard let lock = try RetentionTargetLock.tryAcquire(stateDirectory: target.stateDirectory) else { continue }
        defer { withExtendedLifetime(lock) {} }
        warnings += StorageMaintenanceConversion.run(sessionStoreRoot: root, stateDirectory: target.stateDirectory,
          profile: profile, now: now)
        let db = try SQLiteDatabase.open(path: path, mode: .readWriteCreate, options: SQLiteOpenOptions(
          enableWAL: false,
          busyTimeoutMilliseconds: 0,
          requireJSONB: false,
          waitForLocks: false
        ))
        guard try db.query("PRAGMA auto_vacuum").first?["auto_vacuum"] == "2",
              let count = try db.query("PRAGMA freelist_count").first?["freelist_count"].flatMap(Int.init),
              count >= minimumFreePages else { continue }
        _ = try db.query("PRAGMA incremental_vacuum(\(min(count, profile.vacuumPageCap)))")
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
