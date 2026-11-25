import Foundation
import RielaAppSupport
import RielaCore
import RielaGraphQL
import RielaWorkflowRegistry

struct AskReadProviders: Sendable {
  let sessions: GraphQLRuntimeSnapshotQueryService
  let console: any GraphQLConsoleProviding
  let registry: any WorkflowRegistryGraphQLProviding
  let authoringRegistry: AskLazy<FileWorkflowRegistryGraphQLProvider>
  let definitions: any WorkflowDefinitionGraphQLProviding
  let routines: any RoutineGraphQLProviding
  let bots: any BotsGraphQLProviding
  var sessionLogs: @Sendable (String, String?, Int, String?) throws -> AskReadResult
  let workflowInspect: @Sendable (String) async throws -> (entry: GraphQLWorkflowRegistryEntry, inspection: JSONValue?)
  let workflowValidate: @Sendable (String) async throws -> AskReadResult
  let stepExists: @Sendable (String, String) throws -> Bool
  let permissionRequest: @Sendable (String) throws -> ActivityRequestRecord?
  let environment: [String: String]
  let registryScope: WorkflowRegistryScope

  static func local(
    workingDirectory: String, sessionStore: String?, scope: WorkflowScope, environment: [String: String],
    console: (any GraphQLConsoleProviding)? = nil
  ) -> AskReadProviders {
    let local = AskLocalReadContext(
      workingDirectory: workingDirectory, sessionStore: sessionStore, scope: scope, environment: environment
    )
    let root = local.root
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root))
    let sessions = GraphQLRuntimeSnapshotQueryService(
      loadSnapshot: { try runtime.loadStrictReadOnly(sessionId: $0) },
      loadSnapshots: { try runtime.loadAll() },
      observabilityService: SessionObservabilityComposition.makeService(store: runtime)
    )
    let registry = FileWorkflowRegistryGraphQLProvider(workingDirectory: workingDirectory)
    let authoring = AskLazy { () throws(AskError) -> FileWorkflowRegistryGraphQLProvider in
      try FileWorkflowRegistryGraphQLProvider(
        workingDirectory: workingDirectory, webPrincipalId: "ask",
        retainKey: AskRetainKey.load(storeRoot: root), authoringProjection: true
      )
    }
    let botStore = BotStore(sessionStoreRoot: runtime.rootDirectory)
    return AskReadProviders(
      sessions: sessions, console: console ?? local.console(), registry: registry, authoringRegistry: authoring,
      definitions: WorkflowDefinitionGraphQLProvider(
        workingDirectory: workingDirectory, sessionStoreRoot: root, environment: environment
      ),
      routines: FileRoutineGraphQLProvider(
        workingDirectory: workingDirectory, environment: environment,
        botExists: BotRunLinker.botExists(sessionStoreRoot: root)
      ),
      bots: BotsGraphQLProvider(workingDirectory: workingDirectory, sessionStoreRoot: root, environment: environment),
      sessionLogs: { try local.logs(runtime: runtime, sessionId: $0, stepExecutionId: $1, tail: $2, contains: $3) },
      workflowInspect: { id in
        let entry = try await registry.workflow(target: .init(workflowId: id, scope: local.registryScope))
        if entry.mutable {
          let projected = try await authoring.get().workflow(
            target: .init(workflowId: entry.workflowId, scope: .user, originId: entry.originId)
          )
          return (projected, nil)
        }
        let resolution = local.resolution(for: entry)
        let result = await WorkflowInspectCommand().run(.init(workflowName: entry.workflowId, resolution: resolution, output: .json))
        let projection = try JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8))
        return (entry, projection)
      },
      workflowValidate: { id in
        let entry = try await registry.workflow(target: .init(workflowId: id, scope: local.registryScope))
        let resolution = local.resolution(for: entry)
        let result = await WorkflowValidateCommand().run(.init(workflowName: entry.workflowId, resolution: resolution, output: .json))
        let data = try JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8))
        return (data, [AskRef(kind: .workflow, id: entry.workflowId)])
      },
      stepExists: { try local.stepExists(sessionId: $0, stepId: $1) },
      permissionRequest: { try botStore.askActivityRequest(id: $0) },
      environment: environment, registryScope: local.registryScope
    )
  }
}

private struct AskLocalReadContext {
  let workingDirectory: String
  let sessionStore: String?
  let scope: WorkflowScope
  let environment: [String: String]

  var root: String {
    CLIWorkflowSessionStore.resolveRootDirectory(
      sessionStore: sessionStore, scope: scope, workingDirectory: workingDirectory, environment: environment
    )
  }

  var registryScope: WorkflowRegistryScope {
    WorkflowRegistryScope(rawValue: scope.rawValue) ?? .auto
  }

  func resolution(for entry: GraphQLWorkflowRegistryEntry) -> WorkflowResolutionOptions {
    WorkflowResolutionOptions(
      workflowName: entry.workflowId,
      scope: WorkflowScope(rawValue: entry.scope.lowercased()) ?? scope,
      workingDirectory: workingDirectory, includeDeactivated: true
    )
  }

  func console() -> RielaConsoleGraphQLProviderAdapter {
    RielaConsoleGraphQLProviderAdapter { await localConsole() }
  }

  @MainActor
  private func localConsole() -> RielaConsoleGraphQLProvider {
    let home = URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(environment: environment), isDirectory: true)
    let directory = URL(fileURLWithPath: workingDirectory, isDirectory: true)
    let appRoot = RielaAppProfileStore.defaultAppRootURL(homeDirectory: home)
    let profile = RielaAppProfileStore(appRootURL: appRoot).loadActiveProfileName()
    let read = RielaAppDaemonWorkflowStore(profileName: profile, homeDirectory: home).loadReadOnlyResult()
    let state = read.state ?? RielaAppDaemonWorkflowState()
    let sources = RielaAppDaemonWorkflowDiscovery(projectRoot: directory).discoverUserDaemonWorkflows(
      appWorkflowRoot: RielaAppProfileStore.workflowRootURL(
        appRootURL: appRoot, profileName: profile, storageDirectory: state.workflowStorageDirectory
      ),
      appPackageRoot: RielaAppProfileStore.packageRootURL(
        appRootURL: appRoot, profileName: profile, storageDirectory: state.workflowStorageDirectory
      ),
      projectDirectories: state.projectDirectories,
      additionalWorkflowDirectories: state.workflowDirectories
    )
    return RielaConsoleGraphQLProvider(
      profile: profile, state: state, instances: state.workflowInstances(from: sources), sources: sources,
      revision: 1, sessionStoreRoot: root,
      runtimeSnapshot: { _ in .init(status: .stopped, detail: "No local daemon runtime") },
      environment: { _ in environment }
    )
  }

  func logs(
    runtime: SQLiteWorkflowRuntimePersistenceStore, sessionId: String, stepExecutionId: String?, tail: Int, contains: String?
  ) throws -> AskReadResult {
    let session = try runtime.loadStrictReadOnly(sessionId: sessionId).session
    let executions = session.executions.filter { stepExecutionId == nil || $0.executionId == stepExecutionId }
    guard stepExecutionId == nil || !executions.isEmpty else {
      throw AskError(code: "not_found", message: "Step execution not found")
    }
    // SessionInspectionCommand reads persisted step failure diagnostics for logs.
    let entries = executions.lazy.filter { execution in
      guard let reason = execution.failureReason else { return false }
      return contains.map { reason.contains($0) } ?? true
    }.suffix(tail)
    let rows = entries.map { item -> JSONValue in
      .object([
        "executionId": .string(item.executionId), "stepId": .string(item.stepId),
        "text": .string(item.failureReason ?? "")
      ])
    }
    let refs = [AskRef(kind: .session, id: session.sessionId)] + entries.map {
      AskRef(kind: .step, id: $0.stepId, sessionId: session.sessionId)
    }
    return (.array(Array(rows)), refs)
  }

  func stepExists(sessionId: String, stepId: String) throws -> Bool {
    let loaded = try CLIWorkflowSessionResolution.loadPersistedSession(
      sessionId: sessionId, sessionStore: root, scope: scope, workingDirectory: workingDirectory,
      strictReadOnly: true, environment: environment
    )
    let resolver = FileSystemWorkflowBundleResolver()
    let persisted = loaded.record
    let bundle: ResolvedWorkflowBundle
    if let source = persisted.session.definitionSource, source.kind == .store, let versionId = source.versionId {
      bundle = try WorkflowDefinitionService(storeRoot: source.storeRoot ?? loaded.storeRoot, fileResolver: resolver)
        .loadPinned(versionId: versionId)
    } else {
      bundle = try resolver.resolve(CLIWorkflowSessionResolution.effectiveResolution(
        persisted: persisted, scope: scope, workflowDefinitionDir: nil, workingDirectory: workingDirectory
      ))
    }
    return bundle.workflow.steps.contains { $0.id == stepId }
  }
}
