import Foundation
import RielaSQLite

extension SpecialistSupervisorStore {
  func openWritable() throws -> SQLiteDatabase {
    try withDatabaseOpenLock {
      let database = try SQLiteDatabase.open(path: databasePath, mode: .readWriteCreate, options: .writableDefault)
      try prepareSchema(database)
      return database
    }
  }

  func openReadOnly() throws -> SQLiteDatabase {
    try withDatabaseOpenLock {
      try SQLiteDatabase.open(path: databasePath, mode: .readOnly, options: .readOnlyDefault)
    }
  }

  private func withDatabaseOpenLock<T>(_ body: () throws -> T) throws -> T {
    let runtimeRoot = URL(fileURLWithPath: databasePath, isDirectory: false).deletingLastPathComponent()
    let lock = try DistributedStoreLock(url: runtimeRoot.appendingPathComponent(".riela/runtime-schema.lock"))
    try lock.acquire()
    defer { lock.release() }
    return try body()
  }
}
