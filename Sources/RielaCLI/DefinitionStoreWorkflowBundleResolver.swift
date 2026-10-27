import Foundation
import RielaCore
import RielaWorkflowRegistry

public struct DefinitionStoreWorkflowBundleResolver: WorkflowBundleResolving {
  public enum Mode: Equatable, Sendable {
    case lookupOrSeed
    case lookupOnly
  }

  public let inner: any WorkflowBundleResolving
  public let sessionStore: String?
  public let environment: [String: String]
  public let actor: WorkflowDefinitionActor
  public let mode: Mode

  public init(
    inner: any WorkflowBundleResolving,
    sessionStore: String?,
    environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment(),
    actor: WorkflowDefinitionActor,
    mode: Mode
  ) {
    self.inner = inner
    self.sessionStore = sessionStore
    self.environment = environment
    self.actor = actor
    self.mode = mode
  }

  public func lookup(_ options: WorkflowResolutionOptions) throws -> ResolvedWorkflowBundle? {
    for root in WorkflowDefinitionStoreSelection.candidateRoots(
      sessionStore: sessionStore,
      scope: options.scope,
      workingDirectory: options.workingDirectory,
      environment: environment
    ) {
      let databasePath = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root)
      guard FileManager.default.fileExists(atPath: databasePath) else { continue }
      let service = WorkflowDefinitionService(storeRoot: root, fileResolver: inner)
      if var bundle = try service.lookup(workflowName: options.workflowName) {
        appendSourceDirectoryWarning(to: &bundle, options: options)
        return bundle
      }
    }
    return nil
  }

  public func seed(
    fileBundle: ResolvedWorkflowBundle,
    options: WorkflowResolutionOptions
  ) throws -> ResolvedWorkflowBundle {
    let root = WorkflowDefinitionStoreSelection.seedRoot(
      sessionStore: sessionStore,
      resolution: options,
      fileBundle: fileBundle,
      environment: environment
    )
    return try makeService(storeRoot: root, projectDirectory: options.workingDirectory)
      .seedIfAbsent(fileBundle: fileBundle, workflowName: options.workflowName, actor: actor)
  }

  public func resolve(_ options: WorkflowResolutionOptions) throws -> ResolvedWorkflowBundle {
    if let stored = try lookup(options) { return stored }
    guard mode == .lookupOrSeed else { return try inner.resolve(options) }
    let fileBundle = try inner.resolve(options)
    if fileBundle.definitionSource?.kind == .store { return fileBundle }
    return try seed(fileBundle: fileBundle, options: options)
  }

  private func appendSourceDirectoryWarning(
    to bundle: inout ResolvedWorkflowBundle,
    options: WorkflowResolutionOptions
  ) {
    guard let requestedPath = options.workflowDefinitionDir,
          let storedPath = bundle.definitionSource?.sourcePath else { return }
    let requested = URL(fileURLWithPath: requestedPath).standardizedFileURL.path
    let stored = URL(fileURLWithPath: storedPath).standardizedFileURL.path
    guard stored != requested, !stored.hasPrefix(requested.hasSuffix("/") ? requested : requested + "/") else { return }
    bundle.diagnostics.append(WorkflowValidationDiagnostic(
      severity: .warning,
      path: "definitionStore.sourceDirectory",
      message: "using stored definition seeded from \(storedPath); request names \(requestedPath)"
    ))
  }

  private func makeService(storeRoot: String, projectDirectory: String) throws -> WorkflowDefinitionService {
    let retention = try WorkflowDefinitionHistoryConfiguration.resolve(
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
      projectDirectory: projectDirectory,
      environment: environment
    )
    return WorkflowDefinitionService(storeRoot: storeRoot, fileResolver: inner, defaultHistoryRetention: retention)
  }
}
