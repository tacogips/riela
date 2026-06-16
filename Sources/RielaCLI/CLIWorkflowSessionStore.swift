import Foundation
import RielaCore

public struct PersistedCLIWorkflowSession: Codable, Equatable, Sendable {
  public var workflowName: String
  public var session: WorkflowSession
  public var resolution: WorkflowResolutionOptions
  public var mockScenarioPath: String?

  public init(
    workflowName: String,
    session: WorkflowSession,
    resolution: WorkflowResolutionOptions,
    mockScenarioPath: String? = nil
  ) {
    self.workflowName = workflowName
    self.session = session
    self.resolution = resolution
    self.mockScenarioPath = mockScenarioPath
  }
}

public enum CLIWorkflowSessionStoreError: Error, Equatable, Sendable {
  case invalidSessionId(String)
  case notFound(String)
  case io(String)
}

public struct CLIWorkflowSessionStore: Sendable {
  public var rootDirectory: String

  public init(rootDirectory: String) {
    self.rootDirectory = rootDirectory
  }

  public static func resolveRootDirectory(
    sessionStore: String?,
    scope: WorkflowScope,
    workingDirectory: String,
    environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
  ) -> String {
    if let sessionStore, !sessionStore.isEmpty {
      let url = URL(fileURLWithPath: sessionStore, isDirectory: true)
      return url.path.hasPrefix("/") ? url.path : URL(fileURLWithPath: workingDirectory).appendingPathComponent(sessionStore).path
    }
    if let envRoot = environment["RIELA_SESSION_STORE"], !envRoot.isEmpty {
      let url = URL(fileURLWithPath: envRoot, isDirectory: true)
      return url.path.hasPrefix("/") ? url.path : URL(fileURLWithPath: workingDirectory).appendingPathComponent(envRoot).path
    }
    switch scope {
    case .user:
      let homeDirectory = CLIRuntimeEnvironment.homeDirectory(environment: environment)
      return URL(fileURLWithPath: homeDirectory)
        .appendingPathComponent(".riela/sessions", isDirectory: true)
        .path
    case .auto, .project, .direct:
      return URL(fileURLWithPath: workingDirectory)
        .appendingPathComponent(".riela/sessions", isDirectory: true)
        .path
    }
  }

  public func save(_ record: PersistedCLIWorkflowSession) throws {
    guard isSafeSessionId(record.session.sessionId) else {
      throw CLIWorkflowSessionStoreError.invalidSessionId(record.session.sessionId)
    }
    try FileManager.default.createDirectory(atPath: rootDirectory, withIntermediateDirectories: true)
    let path = sessionFilePath(record.session.sessionId)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(record)
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
  }

  public func load(sessionId: String) throws -> PersistedCLIWorkflowSession {
    guard isSafeSessionId(sessionId) else {
      throw CLIWorkflowSessionStoreError.invalidSessionId(sessionId)
    }
    let path = sessionFilePath(sessionId)
    guard FileManager.default.fileExists(atPath: path) else {
      throw CLIWorkflowSessionStoreError.notFound("session not found: \(sessionId)")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(PersistedCLIWorkflowSession.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
  }

  public func loadAll() throws -> [PersistedCLIWorkflowSession] {
    guard FileManager.default.fileExists(atPath: rootDirectory) else {
      return []
    }
    let root = URL(fileURLWithPath: rootDirectory, isDirectory: true)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .map { try decoder.decode(PersistedCLIWorkflowSession.self, from: Data(contentsOf: $0)) }
      .sorted { $0.session.sessionId < $1.session.sessionId }
  }

  private func sessionFilePath(_ sessionId: String) -> String {
    URL(fileURLWithPath: rootDirectory).appendingPathComponent("\(sessionId).json").path
  }

  private func isSafeSessionId(_ sessionId: String) -> Bool {
    guard !sessionId.isEmpty, !sessionId.contains("/"), !sessionId.contains("..") else {
      return false
    }
    return sessionId.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
  }
}

func canonicalRuntimeStoreRoot(sessionStoreRoot: String) -> String {
  URL(fileURLWithPath: sessionStoreRoot, isDirectory: true)
    .appendingPathComponent("runtime-records", isDirectory: true)
    .path
}

func seedRuntimeStoreFromPersistedCLIState(
  _ runtimeStore: InMemoryWorkflowRuntimeStore,
  sessionStoreRoot: String
) async throws {
  let sessionStore = CLIWorkflowSessionStore(rootDirectory: sessionStoreRoot)
  let persistenceStore = FileWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStoreRoot))
  for existing in try sessionStore.loadAll() {
    await runtimeStore.seedSession(existing.session)
    do {
      let snapshot = try persistenceStore.load(sessionId: existing.session.sessionId)
      await runtimeStore.seedWorkflowMessages(snapshot.workflowMessages)
    } catch let error as WorkflowRuntimePersistenceStoreError {
      if case .notFound = error {
        continue
      }
      throw error
    }
  }
}
