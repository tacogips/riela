import Foundation
import RielaAddons
import RielaCore

/// Shared selection of the definition store used by CLI and file-change writers.
public enum WorkflowDefinitionStoreRoots {
  public static func resolveRootDirectory(
    sessionStore: String?, scope: WorkflowScope, workingDirectory: String,
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
      return URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(environment: environment))
        .appendingPathComponent(".riela/sessions", isDirectory: true).path
    case .auto, .project, .direct:
      return URL(fileURLWithPath: workingDirectory).appendingPathComponent(".riela/sessions", isDirectory: true).path
    }
  }

  public static func normalizedRoot(_ root: String, workingDirectory: String) -> String {
    URL(fileURLWithPath: root, relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true))
      .standardizedFileURL.path
  }

  public static func candidateRoots(
    sessionStore: String?, scope: WorkflowScope, workingDirectory: String,
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
    case .user: scopes = [.user]
    case .project, .direct: scopes = [.project]
    case .auto: scopes = [.project, .user]
    }
    return scopes.map {
      normalizedRoot(resolveRootDirectory(sessionStore: nil, scope: $0, workingDirectory: workingDirectory,
                                          environment: environment), workingDirectory: workingDirectory)
    }.reduce(into: []) { roots, root in
      if !roots.contains(root) { roots.append(root) }
    }
  }

  public static func seedRoot(
    sessionStore: String?, sourceScope: WorkflowScope, workingDirectory: String,
    environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
  ) -> String {
    normalizedRoot(resolveRootDirectory(sessionStore: sessionStore, scope: sourceScope == .user ? .user : .project,
                                        workingDirectory: workingDirectory, environment: environment),
                   workingDirectory: workingDirectory)
  }

  public static func rootWithHead(
    workflowName: String, sessionStore: String?, scope: WorkflowScope, workingDirectory: String,
    environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
  ) throws -> String? {
    for root in candidateRoots(sessionStore: sessionStore, scope: scope, workingDirectory: workingDirectory,
                               environment: environment) {
      let path = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root)
      guard FileManager.default.fileExists(atPath: path) else { continue }
      if try WorkflowDefinitionStore(rootDirectory: root).head(workflowName: workflowName) != nil {
        return root
      }
    }
    return nil
  }
}
