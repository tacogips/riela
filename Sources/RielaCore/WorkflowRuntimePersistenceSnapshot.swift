import Foundation

public struct WorkflowRuntimePersistenceSnapshot: Codable, Equatable, Sendable {
  public var session: WorkflowSession
  public var workflowMessages: [WorkflowMessageRecord]
  public var rootOutput: JSONObject?
  public var diagnostics: [String]

  public init(
    session: WorkflowSession,
    workflowMessages: [WorkflowMessageRecord] = [],
    rootOutput: JSONObject? = nil,
    diagnostics: [String] = []
  ) {
    self.session = session
    self.workflowMessages = workflowMessages
    self.rootOutput = rootOutput
    self.diagnostics = diagnostics
  }
}

public enum WorkflowRuntimePersistenceProjector {
  public static func snapshot(
    session: WorkflowSession,
    workflowMessages: [WorkflowMessageRecord] = []
  ) -> WorkflowRuntimePersistenceSnapshot {
    let rootOutput = session.executions.last(where: { $0.acceptedOutput?.isRootOutput == true })?.acceptedOutput?.payload
    return WorkflowRuntimePersistenceSnapshot(
      session: session,
      workflowMessages: workflowMessages.sorted { $0.createdOrder < $1.createdOrder },
      rootOutput: rootOutput,
      diagnostics: diagnostics(session: session, workflowMessages: workflowMessages)
    )
  }

  private static func diagnostics(session: WorkflowSession, workflowMessages: [WorkflowMessageRecord]) -> [String] {
    var diagnostics: [String] = []
    let executionIds = Set(session.executions.map(\.executionId))
    for message in workflowMessages where !executionIds.contains(message.sourceStepExecutionId) {
      diagnostics.append("workflow message \(message.communicationId) references unknown source step execution \(message.sourceStepExecutionId)")
    }
    if session.status == .completed && session.executions.contains(where: { $0.status == .running }) {
      diagnostics.append("completed session contains running step executions")
    }
    return diagnostics
  }
}

public enum WorkflowRuntimePersistenceStoreError: Error, Equatable, Sendable {
  case invalidSessionId(String)
  case notFound(String)
  case sqliteFailed(String)
}

public struct FileWorkflowRuntimePersistenceStore: Sendable {
  public var rootDirectory: String

  public init(rootDirectory: String) {
    self.rootDirectory = rootDirectory
  }

  public func save(_ snapshot: WorkflowRuntimePersistenceSnapshot) throws {
    guard isSafeId(snapshot.session.sessionId) else {
      throw WorkflowRuntimePersistenceStoreError.invalidSessionId(snapshot.session.sessionId)
    }
    let directory = URL(fileURLWithPath: rootDirectory, isDirectory: true)
      .appendingPathComponent(snapshot.session.sessionId, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(snapshot).write(to: directory.appendingPathComponent("runtime-snapshot.json"), options: .atomic)
    try SQLiteWorkflowMessageLog(databasePath: SQLiteWorkflowMessageLog.defaultDatabasePath(rootDirectory: rootDirectory))
      .replaceMessages(for: snapshot.session.sessionId, with: snapshot.workflowMessages)
  }

  public func load(sessionId: String) throws -> WorkflowRuntimePersistenceSnapshot {
    guard isSafeId(sessionId) else {
      throw WorkflowRuntimePersistenceStoreError.invalidSessionId(sessionId)
    }
    let url = URL(fileURLWithPath: rootDirectory, isDirectory: true)
      .appendingPathComponent(sessionId, isDirectory: true)
      .appendingPathComponent("runtime-snapshot.json")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw WorkflowRuntimePersistenceStoreError.notFound("runtime snapshot not found: \(sessionId)")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(WorkflowRuntimePersistenceSnapshot.self, from: Data(contentsOf: url))
  }

  public func loadAll() throws -> [WorkflowRuntimePersistenceSnapshot] {
    let root = URL(fileURLWithPath: rootDirectory, isDirectory: true)
    guard FileManager.default.fileExists(atPath: root.path) else {
      return []
    }
    let sessionDirectories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
    var snapshots: [WorkflowRuntimePersistenceSnapshot] = []
    for directory in sessionDirectories {
      let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
      guard values.isDirectory == true else {
        continue
      }
      snapshots.append(try load(sessionId: directory.lastPathComponent))
    }
    return snapshots
  }

  private func isSafeId(_ value: String) -> Bool {
    guard !value.isEmpty, !value.contains("/"), !value.contains("..") else {
      return false
    }
    return value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
  }
}
