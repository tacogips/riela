import Foundation
import RielaCore

struct LoadedPersistedCLIWorkflowSession: Equatable, Sendable {
  var record: PersistedCLIWorkflowSession
  var storeRoot: String
}

enum CLIWorkflowSessionResolution {
  static func resolutionForPersistence(
    resolution: WorkflowResolutionOptions,
    resolvedSourceScope: WorkflowScope
  ) -> WorkflowResolutionOptions {
    var persisted = resolution
    if persisted.workflowDefinitionDir == nil, persisted.scope == .auto {
      persisted.scope = resolvedSourceScope
    }
    return persisted
  }

  static func effectiveResolution(
    persisted: PersistedCLIWorkflowSession,
    scope: WorkflowScope,
    workflowDefinitionDir: String?,
    workingDirectory: String
  ) -> WorkflowResolutionOptions {
    let effectiveScope: WorkflowScope
    if workflowDefinitionDir != nil {
      effectiveScope = .direct
    } else if scope == .auto {
      effectiveScope = persisted.resolution.scope
    } else {
      effectiveScope = scope
    }
    return WorkflowResolutionOptions(
      workflowName: persisted.workflowName,
      scope: effectiveScope,
      workflowDefinitionDir: workflowDefinitionDir ?? persisted.resolution.workflowDefinitionDir,
      workingDirectory: workingDirectory
    )
  }

  static func loadPersistedSession(
    sessionId: String,
    sessionStore: String?,
    scope: WorkflowScope,
    workingDirectory: String,
    strictReadOnly: Bool = false,
    environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
  ) throws -> LoadedPersistedCLIWorkflowSession {
    if usesExplicitSessionStoreRoot(sessionStore: sessionStore, environment: environment) {
      let storeRoot = CLIWorkflowSessionStore.resolveRootDirectory(
        sessionStore: sessionStore,
        scope: scope,
        workingDirectory: workingDirectory,
        environment: environment
      )
      let record = try CLIWorkflowSessionStore(rootDirectory: storeRoot).load(
        sessionId: sessionId,
        strictReadOnly: strictReadOnly
      )
      return LoadedPersistedCLIWorkflowSession(record: record, storeRoot: storeRoot)
    }

    var outcomes: [SessionStoreSearchOutcome] = []
    for searchScope in sessionStoreSearchScopes(for: scope) {
      let storeRoot = CLIWorkflowSessionStore.resolveRootDirectory(
        sessionStore: nil,
        scope: searchScope,
        workingDirectory: workingDirectory,
        environment: environment
      )
      do {
        let record = try CLIWorkflowSessionStore(rootDirectory: storeRoot).load(
          sessionId: sessionId,
          strictReadOnly: strictReadOnly
        )
        return LoadedPersistedCLIWorkflowSession(record: record, storeRoot: storeRoot)
      } catch let error as CLIWorkflowSessionStoreError {
        outcomes.append(SessionStoreSearchOutcome(scope: searchScope, storeRoot: storeRoot, error: error))
        continue
      }
    }
    if outcomes.contains(where: \.isStoreFailure) {
      throw CLIWorkflowSessionStoreError.sqliteFailed(searchFailureMessage(sessionId: sessionId, outcomes: outcomes))
    }
    throw CLIWorkflowSessionStoreError.notFound(searchFailureMessage(sessionId: sessionId, outcomes: outcomes))
  }

  static func saveStoreRoot(
    sessionStore: String?,
    scope: WorkflowScope,
    workingDirectory: String,
    loadedFromStoreRoot: String,
    environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
  ) -> String {
    if usesExplicitSessionStoreRoot(sessionStore: sessionStore, environment: environment) {
      return CLIWorkflowSessionStore.resolveRootDirectory(
        sessionStore: sessionStore,
        scope: scope,
        workingDirectory: workingDirectory,
        environment: environment
      )
    }
    return loadedFromStoreRoot
  }

  private static func usesExplicitSessionStoreRoot(
    sessionStore: String?,
    environment: [String: String]
  ) -> Bool {
    if let sessionStore, !sessionStore.isEmpty {
      return true
    }
    if let envRoot = environment["RIELA_SESSION_STORE"], !envRoot.isEmpty {
      return true
    }
    return false
  }

  private static func sessionStoreSearchScopes(for scope: WorkflowScope) -> [WorkflowScope] {
    switch scope {
    case .auto:
      return [.project, .user]
    case .user:
      return [.user]
    case .project, .direct:
      return [.project]
    }
  }

  private static func searchFailureMessage(sessionId: String, outcomes: [SessionStoreSearchOutcome]) -> String {
    let details = outcomes.map { "\($0.scope.rawValue) store \($0.storeRoot): \($0.errorDescription)" }
      .joined(separator: "; ")
    guard !details.isEmpty else {
      return "session not found: \(sessionId)"
    }
    return "session not found: \(sessionId); searched stores: \(details)"
  }
}

private struct SessionStoreSearchOutcome: Sendable {
  var scope: WorkflowScope
  var storeRoot: String
  var error: CLIWorkflowSessionStoreError

  var isStoreFailure: Bool {
    if case .notFound = error {
      return false
    }
    return true
  }

  var errorDescription: String {
    switch error {
    case let .invalidSessionId(value):
      return "invalid session id: \(value)"
    case let .notFound(message), let .io(message), let .sqliteFailed(message):
      return message
    }
  }
}
