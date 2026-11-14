import Foundation

/// One in-place schema upgrade step: brings a database stamped
/// `fromGeneration` to `fromGeneration + 1`. The step body only changes the
/// schema/data; the migrator wraps it in a transaction and stamps the new
/// `user_version` itself.
public struct SQLiteSchemaMigration: Sendable {
  public var fromGeneration: Int64
  public var migrate: @Sendable (SQLiteDatabase) throws -> Void

  public init(fromGeneration: Int64, migrate: @escaping @Sendable (SQLiteDatabase) throws -> Void) {
    self.fromGeneration = fromGeneration
    self.migrate = migrate
  }
}

/// Shared `user_version`-based schema lifecycle for riela SQLite stores.
///
/// Policy:
/// - `user_version == currentGeneration`: no-op.
/// - `user_version > currentGeneration`: throws — the database was written by
///   a newer build and this build must not touch it.
/// - `0 < user_version < currentGeneration`: applies the registered
///   migrations one generation at a time, each inside its own transaction,
///   stamping `user_version` after every step. A gap in the migration chain
///   throws `MissingMigrationPathError` so the store can apply its own
///   fallback policy (discard for regenerable data, hard error for data that
///   is not regenerable).
/// - `user_version == 0`: a fresh database is stamped `currentGeneration`; a
///   database whose tables predate generation stamping (per
///   `preGenerationProbe`) cannot be migrated and throws the same
///   missing-path error.
public enum SQLiteSchemaMigrator {
  /// Thrown when the database is older than `currentGeneration` and no
  /// complete migration chain exists from its stamped generation.
  public struct MissingMigrationPathError: Error, Equatable, Sendable {
    public var storeDescription: String
    public var stampedGeneration: Int64
    public var currentGeneration: Int64

    public init(storeDescription: String, stampedGeneration: Int64, currentGeneration: Int64) {
      self.storeDescription = storeDescription
      self.stampedGeneration = stampedGeneration
      self.currentGeneration = currentGeneration
    }
  }

  /// Thrown when the database was stamped by a newer build.
  public struct NewerGenerationError: Error, Equatable, Sendable {
    public var storeDescription: String
    public var stampedGeneration: Int64
    public var currentGeneration: Int64

    public init(storeDescription: String, stampedGeneration: Int64, currentGeneration: Int64) {
      self.storeDescription = storeDescription
      self.stampedGeneration = stampedGeneration
      self.currentGeneration = currentGeneration
    }
  }

  /// Thrown in `.verify` mode when the database is older than
  /// `currentGeneration` and a migration path exists: the caller must reopen
  /// writable (which migrates) before reading.
  public struct MigrationPendingError: Error, Equatable, Sendable {
    public var storeDescription: String
    public var stampedGeneration: Int64
    public var currentGeneration: Int64

    public init(storeDescription: String, stampedGeneration: Int64, currentGeneration: Int64) {
      self.storeDescription = storeDescription
      self.stampedGeneration = stampedGeneration
      self.currentGeneration = currentGeneration
    }
  }

  public enum Mode: Sendable {
    /// Writable connection: stamp fresh databases and apply migrations.
    case migrate
    /// Read-only connection: never writes. A fresh unstamped database passes;
    /// an older migratable database throws `MigrationPendingError`.
    case verify
  }

  public static func stampedGeneration(in db: SQLiteDatabase) throws -> Int64 {
    try db.query("PRAGMA user_version").first?["user_version"].flatMap(Int64.init) ?? 0
  }

  /// True when `migrations` contains an unbroken `from → from+1` chain
  /// covering `stampedGeneration ..< currentGeneration`.
  public static func hasCompletePath(
    from stampedGeneration: Int64,
    to currentGeneration: Int64,
    migrations: [SQLiteSchemaMigration]
  ) -> Bool {
    guard stampedGeneration > 0 else { return stampedGeneration == currentGeneration }
    let covered = Set(migrations.map(\.fromGeneration))
    return (stampedGeneration..<currentGeneration).allSatisfy(covered.contains)
  }

  public static func migrateIfNeeded(
    in db: SQLiteDatabase,
    currentGeneration: Int64,
    migrations: [SQLiteSchemaMigration],
    preGenerationProbe: (SQLiteDatabase) throws -> Bool,
    storeDescription: String,
    mode: Mode = .migrate
  ) throws {
    let version = try stampedGeneration(in: db)
    if version == currentGeneration { return }
    if version > currentGeneration {
      throw NewerGenerationError(
        storeDescription: storeDescription,
        stampedGeneration: version,
        currentGeneration: currentGeneration
      )
    }
    if version == 0 {
      guard try !preGenerationProbe(db) else {
        throw MissingMigrationPathError(
          storeDescription: storeDescription,
          stampedGeneration: version,
          currentGeneration: currentGeneration
        )
      }
      if mode == .migrate {
        try db.execute("PRAGMA user_version = \(currentGeneration)")
      }
      return
    }
    guard hasCompletePath(from: version, to: currentGeneration, migrations: migrations) else {
      throw MissingMigrationPathError(
        storeDescription: storeDescription,
        stampedGeneration: version,
        currentGeneration: currentGeneration
      )
    }
    guard mode == .migrate else {
      throw MigrationPendingError(
        storeDescription: storeDescription,
        stampedGeneration: version,
        currentGeneration: currentGeneration
      )
    }
    let steps = migrations
      .filter { (version..<currentGeneration).contains($0.fromGeneration) }
      .sorted { $0.fromGeneration < $1.fromGeneration }
    for step in steps {
      try db.transaction { db in
        try step.migrate(db)
        try db.execute("PRAGMA user_version = \(step.fromGeneration + 1)")
      }
    }
  }
}
