import Foundation
import RielaCore
import RielaWorkflowRegistry

enum WorkflowDefinitionStoreSelection {
  static func rootWithHead(
    workflowName: String,
    sessionStore: String?,
    scope: WorkflowScope,
    workingDirectory: String,
    environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
  ) throws -> String? {
    for root in candidateRoots(
      sessionStore: sessionStore,
      scope: scope,
      workingDirectory: workingDirectory,
      environment: environment
    ) {
      let databasePath = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root)
      guard FileManager.default.fileExists(atPath: databasePath) else { continue }
      if try WorkflowDefinitionService(storeRoot: root, fileResolver: FileSystemWorkflowBundleResolver())
        .lookup(workflowName: workflowName) != nil {
        return root
      }
    }
    return nil
  }

  static func candidateRoots(
    sessionStore: String?,
    scope: WorkflowScope,
    workingDirectory: String,
    environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
  ) -> [String] {
    if let sessionStore, !sessionStore.isEmpty {
      return [normalizedRoot(sessionStore, workingDirectory: workingDirectory)]
    }
    if let envRoot = environment["RIELA_SESSION_STORE"], !envRoot.isEmpty {
      return [normalizedRoot(envRoot, workingDirectory: workingDirectory)]
    }
    let scopes: [WorkflowScope]
    switch scope {
    case .user:
      scopes = [.user]
    case .project, .direct:
      scopes = [.project]
    case .auto:
      scopes = [.project, .user]
    }
    return scopes.map {
      normalizedRoot(
        CLIWorkflowSessionStore.resolveRootDirectory(
          sessionStore: nil,
          scope: $0,
          workingDirectory: workingDirectory,
          environment: environment
        ),
        workingDirectory: workingDirectory
      )
    }.reduce(into: []) { roots, root in
      if !roots.contains(root) { roots.append(root) }
    }
  }

  static func seedRoot(
    sessionStore: String?,
    resolution: WorkflowResolutionOptions,
    fileBundle: ResolvedWorkflowBundle,
    environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
  ) -> String {
    let persisted = CLIWorkflowSessionResolution.resolutionForPersistence(
      resolution: resolution,
      resolvedSourceScope: fileBundle.sourceScope
    )
    return normalizedRoot(
      CLIWorkflowSessionStore.resolveRootDirectory(
        sessionStore: sessionStore,
        scope: persisted.scope,
        workingDirectory: resolution.workingDirectory,
        environment: environment
      ),
      workingDirectory: resolution.workingDirectory
    )
  }

  private static func normalizedRoot(_ root: String, workingDirectory: String) -> String {
    URL(fileURLWithPath: root, relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true))
      .standardizedFileURL.path
  }
}
