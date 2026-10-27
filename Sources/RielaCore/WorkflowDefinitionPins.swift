import Foundation
import RielaSQLite

public enum WorkflowDefinitionPins {
  private struct Target {
    var root: String
    var path: String
    var localPath: String
    var localRoot: String
    var sessionId: String
    var workflowName: String
    var versionId: String
    var createdAt: Date
    var terminal: Bool
    var foreign: Bool { path != localPath }
  }

  static func recordPinIfNeeded(
    _ db: SQLiteDatabase,
    snapshot: WorkflowRuntimePersistenceSnapshot,
    sessionStoreRoot: String
  ) throws {
    guard let target = target(snapshot: snapshot, sessionStoreRoot: sessionStoreRoot), !target.foreign else { return }
    guard let number = try versionNumber(target.versionId, db: db) else {
      if target.terminal { return }
      throw WorkflowDefinitionStoreError(code: .versionNotRetained,
        message: "definition version \(target.versionId) is not retained")
    }
    try insertPin(target, number: number, database: db)
  }

  public static func recordForeignPinIfNeeded(
    snapshot: WorkflowRuntimePersistenceSnapshot,
    sessionStoreRoot: String
  ) throws {
    guard let target = target(snapshot: snapshot, sessionStoreRoot: sessionStoreRoot), target.foreign else { return }
    if ForeignPinRegistry.shared.contains(path: target.path, sessionId: target.sessionId) { return }
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: target.root)
    let db = try persistence.openDatabase()
    try persistence.prepareSchema(in: db)
    try db.transaction { transaction in
      guard let number = try versionNumber(target.versionId, db: transaction) else {
        if target.terminal { return }
        throw WorkflowDefinitionStoreError(code: .versionNotRetained,
          message: "definition version \(target.versionId) is not retained")
      }
      try insertPin(target, number: number, database: transaction)
    }
    ForeignPinRegistry.shared.insert(path: target.path, sessionId: target.sessionId)
  }

  static func normalizedDatabasePath(rootDirectory: String) -> String {
    let path = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: rootDirectory)
    return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
  }

  static func normalizedStoreRoot(rootDirectory: String) -> String {
    URL(fileURLWithPath: rootDirectory, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
  }

  private static func target(
    snapshot: WorkflowRuntimePersistenceSnapshot,
    sessionStoreRoot: String
  ) -> Target? {
    guard let source = snapshot.session.definitionSource, source.kind == .store,
          let versionId = source.versionId else { return nil }
    let localPath = normalizedDatabasePath(rootDirectory: sessionStoreRoot)
    let localRoot = normalizedStoreRoot(rootDirectory: sessionStoreRoot)
    let root = source.storeRoot ?? sessionStoreRoot
    return Target(root: root, path: normalizedDatabasePath(rootDirectory: root), localPath: localPath,
      localRoot: localRoot, sessionId: snapshot.session.sessionId, workflowName: source.workflowName, versionId: versionId,
      createdAt: snapshot.session.updatedAt,
      terminal: snapshot.session.status.isTerminal)
  }

  private static func versionNumber(_ versionId: String, db: SQLiteDatabase) throws -> Int64? {
    try db.query("SELECT history_version FROM definition_versions WHERE version_id = ?", bindings: [.text(versionId)])
      .first?["history_version"].flatMap(Int64.init)
  }

  private static func insertPin(_ target: Target, number: Int64, database: SQLiteDatabase) throws {
    try database.execute("""
      INSERT OR IGNORE INTO definition_version_pins(
        workflow_name, history_version, session_store_root, session_id, created_at
      ) VALUES (?, ?, ?, ?, ?)
      """, bindings: [.text(target.workflowName), .int(number), .text(target.localRoot),
                       .text(target.sessionId), .text(canonicalDate(target.createdAt))])
  }

  private static func canonicalDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}

private final class ForeignPinRegistry: @unchecked Sendable {
  static let shared = ForeignPinRegistry()
  private let lock = NSLock()
  private var pins: Set<String> = []

  func contains(path: String, sessionId: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return pins.contains("\(path)\u{0}\(sessionId)")
  }

  func insert(path: String, sessionId: String) {
    lock.lock()
    defer { lock.unlock() }
    pins.insert("\(path)\u{0}\(sessionId)")
  }
}
