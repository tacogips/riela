import Foundation
import RielaSQLite

public protocol NoteDatabaseDriving: Sendable {
  var databasePath: String { get }

  func withDatabase<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T
}

public struct SQLiteNoteDatabaseDriver: NoteDatabaseDriving {
  public var databasePath: String
  public var openOptions: SQLiteOpenOptions
  private let connection: SQLiteNoteDatabaseConnection

  public init(
    noteRoot: String,
    openOptions: SQLiteOpenOptions = SQLiteOpenOptions(requireFTS5: true)
  ) {
    databasePath = Self.defaultDatabasePath(noteRoot: noteRoot)
    self.openOptions = openOptions
    connection = SQLiteNoteDatabaseConnection(databasePath: databasePath, openOptions: openOptions)
  }

  public init(databasePath: String, openOptions: SQLiteOpenOptions = SQLiteOpenOptions(requireFTS5: true)) {
    self.databasePath = databasePath
    self.openOptions = openOptions
    connection = SQLiteNoteDatabaseConnection(databasePath: databasePath, openOptions: openOptions)
  }

  public static func defaultDatabasePath(noteRoot: String) -> String {
    URL(fileURLWithPath: noteRoot, isDirectory: true)
      .appendingPathComponent("note-store.sqlite")
      .path
  }

  public func withDatabase<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T {
    try connection.withDatabase(body)
  }
}

private final class SQLiteNoteDatabaseConnection: @unchecked Sendable {
  private let databasePath: String
  private let openOptions: SQLiteOpenOptions
  private let lock = NSLock()
  private var database: SQLiteDatabase?

  init(databasePath: String, openOptions: SQLiteOpenOptions) {
    self.databasePath = databasePath
    self.openOptions = openOptions
  }

  func withDatabase<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T {
    lock.lock()
    defer {
      lock.unlock()
    }
    let database = try database ?? SQLiteDatabase.open(path: databasePath, options: openOptions)
    self.database = database
    return try body(database)
  }
}
