import Foundation
import RielaSQLite

public struct NoteFileMigrationFailure: Equatable, Sendable {
  public var fileId: String
  public var message: String

  public init(fileId: String, message: String) {
    self.fileId = fileId
    self.message = message
  }
}

public struct NoteFileMigrationResult: Equatable, Sendable {
  public var migrated: [FileRecord]
  public var failures: [NoteFileMigrationFailure]
  /// Files that migrated durably to S3 but whose stale local blob could not be
  /// deleted afterward. The migration is a success (the row now points at S3);
  /// these paths are surfaced as cleanup warnings and reclaimed by a later GC pass.
  public var cleanupFailures: [NoteFileMigrationFailure]

  public init(
    migrated: [FileRecord] = [],
    failures: [NoteFileMigrationFailure] = [],
    cleanupFailures: [NoteFileMigrationFailure] = []
  ) {
    self.migrated = migrated
    self.failures = failures
    self.cleanupFailures = cleanupFailures
  }
}

public extension NoteService {
  @discardableResult
  func migrateFileStorage(
    fileId: String,
    to profile: S3StorageProfile,
    httpClient: S3HTTPClient = URLSessionS3HTTPClient(),
    verifyRemoteRead: Bool = false
  ) throws -> FileRecord {
    let localStore = LocalNoteFileStore(noteRoot: noteRootPath())
    let s3Store = S3NoteFileStore(profile: profile, httpClient: httpClient)
    let original = try getFileRecord(fileId: fileId)
    let data = try localStore.read(record: original)
    let stored = try s3Store.store(data: data, fileId: fileId)
    let migratedAt = NoteStoreClock.system.now()
    let pendingRecord = FileRecord(
      fileId: original.fileId,
      storageKind: .s3,
      localPath: nil,
      s3Profile: stored.locator.s3Profile,
      s3Bucket: stored.locator.s3Bucket,
      s3Key: stored.locator.s3Key,
      mediaType: original.mediaType,
      byteSize: stored.byteSize,
      sha256: stored.sha256,
      originalFilename: original.originalFilename,
      createdAt: original.createdAt,
      migratedAt: migratedAt
    )
    if verifyRemoteRead {
      _ = try s3Store.read(record: pendingRecord)
    }

    let migrated = try driver.withDatabase { database in
      try database.transaction { db in
        try db.execute(
          """
          UPDATE files
          SET storage_kind = 's3',
            local_path = NULL,
            s3_profile = ?,
            s3_bucket = ?,
            s3_key = ?,
            byte_size = ?,
            sha256 = ?,
            migrated_at = ?
          WHERE file_id = ?
          """,
          bindings: [
            .optionalText(stored.locator.s3Profile),
            .optionalText(stored.locator.s3Bucket),
            .optionalText(stored.locator.s3Key),
            .int(stored.byteSize),
            .text(stored.sha256),
            .text(migratedAt),
            .text(fileId)
          ]
        )
        return try requireFileRecord(fileId: fileId, in: db)
      }
    }
    try localStore.delete(record: original)
    return migrated
  }

  func migrateAllLocalFiles(
    to profile: S3StorageProfile,
    httpClient: S3HTTPClient = URLSessionS3HTTPClient(),
    verifyRemoteRead: Bool = false
  ) throws -> NoteFileMigrationResult {
    let localFileIds = try driver.withDatabase { database in
      try database.query(
        """
        SELECT file_id
        FROM files
        WHERE storage_kind = 'local'
        ORDER BY created_at, file_id
        """
      ).compactMap { $0["file_id"] }
    }
    var result = NoteFileMigrationResult()
    for fileId in localFileIds {
      do {
        let migrated = try migrateFileStorage(
          fileId: fileId,
          to: profile,
          httpClient: httpClient,
          verifyRemoteRead: verifyRemoteRead
        )
        result.migrated.append(migrated)
      } catch {
        result.failures.append(
          NoteFileMigrationFailure(fileId: fileId, message: String(describing: error))
        )
      }
    }
    return result
  }
}
