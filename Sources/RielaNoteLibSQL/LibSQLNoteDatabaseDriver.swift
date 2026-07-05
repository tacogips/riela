import Foundation
import RielaNote
import RielaSQLite

public enum LibSQLNoteDatabaseDriverError: Error, Equatable, Sendable {
  case embeddedReplicaUnavailable(String)
  case syncPolicyRequiresEmbeddedReplica
}

public enum LibSQLNoteDatabaseConfiguration: Equatable, Sendable {
  case local(path: String)
  case embeddedReplica(LibSQLEmbeddedReplicaConfiguration)

  public var path: String {
    switch self {
    case let .local(path):
      path
    case let .embeddedReplica(configuration):
      configuration.path
    }
  }
}

public struct LibSQLEmbeddedReplicaConfiguration: Equatable, Sendable, CustomDebugStringConvertible {
  public var path: String
  public var url: String
  public var authToken: String
  public var readYourWrites: Bool
  public var encryptionKey: String?
  public var syncIntervalMilliseconds: UInt64
  public var withWebpki: Bool

  public init(
    path: String,
    url: String,
    authToken: String,
    readYourWrites: Bool = true,
    encryptionKey: String? = nil,
    syncIntervalMilliseconds: UInt64 = 0,
    withWebpki: Bool = false
  ) {
    self.path = path
    self.url = url
    self.authToken = authToken
    self.readYourWrites = readYourWrites
    self.encryptionKey = encryptionKey
    self.syncIntervalMilliseconds = syncIntervalMilliseconds
    self.withWebpki = withWebpki
  }

  public var debugDescription: String {
    [
      "LibSQLEmbeddedReplicaConfiguration(path: \(path)",
      "url: \(url)",
      "authToken: <redacted>",
      "readYourWrites: \(readYourWrites)",
      "encryptionKey: \(encryptionKey == nil ? "nil" : "<redacted>")",
      "syncIntervalMilliseconds: \(syncIntervalMilliseconds)",
      "withWebpki: \(withWebpki))"
    ].joined(separator: ", ")
  }
}

public struct LibSQLNoteDatabaseSyncPolicy: Equatable, Sendable {
  public var syncBeforeOpen: Bool
  public var syncAfterClose: Bool

  public init(syncBeforeOpen: Bool, syncAfterClose: Bool) {
    self.syncBeforeOpen = syncBeforeOpen
    self.syncAfterClose = syncAfterClose
  }

  public static let disabled = LibSQLNoteDatabaseSyncPolicy(syncBeforeOpen: false, syncAfterClose: false)
  public static let beforeAndAfter = LibSQLNoteDatabaseSyncPolicy(syncBeforeOpen: true, syncAfterClose: true)
}

public struct LibSQLNoteDatabaseDriver: NoteDatabaseDriving {
  public var databasePath: String { configuration.path }
  public var configuration: LibSQLNoteDatabaseConfiguration
  public var openOptions: SQLiteOpenOptions
  public var syncPolicy: LibSQLNoteDatabaseSyncPolicy

  public init(
    noteRoot: String,
    openOptions: SQLiteOpenOptions = SQLiteOpenOptions(requireFTS5: true)
  ) {
    self.init(databasePath: Self.defaultDatabasePath(noteRoot: noteRoot), openOptions: openOptions)
  }

  public init(
    databasePath: String,
    openOptions: SQLiteOpenOptions = SQLiteOpenOptions(requireFTS5: true)
  ) {
    self.init(
      configuration: .local(path: databasePath),
      openOptions: openOptions,
      syncPolicy: .disabled
    )
  }

  public init(
    embeddedReplica configuration: LibSQLEmbeddedReplicaConfiguration,
    openOptions: SQLiteOpenOptions = SQLiteOpenOptions(requireFTS5: true),
    syncPolicy: LibSQLNoteDatabaseSyncPolicy = .beforeAndAfter
  ) {
    self.init(
      configuration: .embeddedReplica(configuration),
      openOptions: openOptions,
      syncPolicy: syncPolicy
    )
  }

  public init(
    configuration: LibSQLNoteDatabaseConfiguration,
    openOptions: SQLiteOpenOptions = SQLiteOpenOptions(requireFTS5: true),
    syncPolicy: LibSQLNoteDatabaseSyncPolicy
  ) {
    self.configuration = configuration
    self.openOptions = openOptions
    self.syncPolicy = syncPolicy
  }

  public static func defaultDatabasePath(noteRoot: String) -> String {
    SQLiteNoteDatabaseDriver.defaultDatabasePath(noteRoot: noteRoot)
  }

  public func withDatabase<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T {
    switch configuration {
    case .local:
      guard syncPolicy == .disabled else {
        throw LibSQLNoteDatabaseDriverError.syncPolicyRequiresEmbeddedReplica
      }
      let database = try SQLiteDatabase.open(path: databasePath, options: openOptions)
      return try body(database)
    case .embeddedReplica:
      throw LibSQLNoteDatabaseDriverError.embeddedReplicaUnavailable(
        "embedded replica mode is disabled until the note database driver can execute SQL through libsql directly"
      )
    }
  }
}
