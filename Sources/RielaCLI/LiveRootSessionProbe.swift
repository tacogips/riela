import Foundation
import RielaCore
import RielaSQLite
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public struct LiveRootSession: Equatable, Sendable {
  public let sessionId: String
  public let createdAt: Date
  public let isManual: Bool
}

public enum LiveRootSessionProbe {
  public static func liveRootSessions(workflowId: String, sessionStoreRoot: String) throws -> [LiveRootSession] {
    let root = canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStoreRoot)
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root)
    let databasePath = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root)
    guard FileManager.default.fileExists(atPath: databasePath) else { return [] }
    let db = try SQLiteDatabase.open(path: databasePath, mode: .strictReadOnlyWithImmutableFallback, options: .readOnlyDefault)
    guard try db.tableExists("workflow_runtime_snapshots") else { return [] }
    let candidates = try db.query(
      "SELECT workflow_execution_id FROM workflow_runtime_snapshots " +
        "WHERE workflow_id = ? AND session_status IN ('created', 'running') " +
        "ORDER BY updated_at DESC, workflow_execution_id LIMIT 200",
      bindings: [.text(workflowId)]
    ).compactMap { $0["workflow_execution_id"] }
    var result: [LiveRootSession] = []
    for candidate in candidates {
      let session: WorkflowSession
      do {
        session = try store.loadStrictReadOnly(sessionId: candidate).session
      } catch WorkflowRuntimePersistenceStoreError.notFound {
        continue
      }
      guard session.parentSessionId == nil, try lockIsHeld(sessionId: session.sessionId, root: root) else { continue }
      let manual = session.instanceKind == WorkflowInstanceKind.named.rawValue ||
        (session.instanceKind == WorkflowInstanceKind.ephemeral.rawValue &&
          session.instanceBaseIdentity != nil && session.instanceBaseIdentity != WorkflowInstanceIdentity.defaultIdentity)
      result.append(LiveRootSession(sessionId: session.sessionId, createdAt: session.createdAt, isManual: manual))
    }
    return result.sorted { $0.createdAt == $1.createdAt ? $0.sessionId < $1.sessionId : $0.createdAt < $1.createdAt }
  }

  private static func lockIsHeld(sessionId: String, root: String) throws -> Bool {
    guard sessionId.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#, options: .regularExpression) != nil else {
      return false
    }
    let path = URL(fileURLWithPath: root).appendingPathComponent("execution-locks")
      .appendingPathComponent(sessionId).appendingPathExtension("lock").path
    let descriptor = open(path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else {
      if errno == ENOENT { return false }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { close(descriptor) }
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      if errno == EINTR { continue }
      if errno == EWOULDBLOCK || errno == EAGAIN { return true }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    _ = flock(descriptor, LOCK_UN)
    return false
  }
}
