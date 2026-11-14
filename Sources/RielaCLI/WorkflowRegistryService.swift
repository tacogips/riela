import Foundation
import RielaCore

public struct WorkflowRegistryMutationResult: Codable, Equatable, Sendable {
  public var accepted: Bool
  public var overwritten: Bool
  public var workflow: WorkflowCatalogEntry?
  public var retiredWorkflows: [WorkflowCatalogEntry]
  public var errors: [WorkflowRegistryError]

  public init(
    accepted: Bool,
    overwritten: Bool = false,
    workflow: WorkflowCatalogEntry? = nil,
    retiredWorkflows: [WorkflowCatalogEntry] = [],
    errors: [WorkflowRegistryError] = []
  ) {
    self.accepted = accepted
    self.overwritten = overwritten
    self.workflow = workflow
    self.retiredWorkflows = retiredWorkflows
    self.errors = errors
  }
}

public struct WorkflowRegistryService: Sendable {
  private let registry: WorkflowMutableRegistry
  private let activationStore: WorkflowActivationStore
  private let coordinator: WorkflowRegistryCoordinator

  public init() {
    registry = WorkflowMutableRegistry()
    activationStore = WorkflowActivationStore()
    coordinator = WorkflowRegistryCoordinator()
  }

  init(
    registry: WorkflowMutableRegistry,
    activationStore: WorkflowActivationStore = WorkflowActivationStore(),
    coordinator: WorkflowRegistryCoordinator = WorkflowRegistryCoordinator()
  ) {
    self.registry = registry
    self.activationStore = activationStore
    self.coordinator = coordinator
  }

  public func list(
    filter: WorkflowRegistryFilter = WorkflowRegistryFilter(),
    workingDirectory: String = FileManager.default.currentDirectoryPath
  ) throws -> [WorkflowCatalogEntry] {
    try withCoordinatedRead(workingDirectory: workingDirectory) {
      try filter.validate()
      let arguments = ["--scope", filter.scope?.rawValue ?? WorkflowRegistryScope.auto.rawValue]
      let entries = try WorkflowCatalogCommand(mutableRegistry: registry).catalogEntries(
        options: CLICommandOptions(
          scope: "workflow",
          command: "list",
          arguments: arguments + ["--working-dir", workingDirectory],
          output: .json
        )
      )
      return entries.filter { entry in
        if let query = filter.query?.lowercased(), !query.isEmpty,
           !entry.workflowName.lowercased().contains(query),
           !entry.workflowId.lowercased().contains(query) {
          return false
        }
        if let description = filter.description?.lowercased(), !description.isEmpty,
           !(entry.description?.lowercased().contains(description) ?? false) {
          return false
        }
        if let sourceKind = filter.sourceKind,
           sourceKind.rawValue != entry.sourceKind.rawValue {
          return false
        }
        if let provenance = filter.provenance, provenance != entry.provenance {
          return false
        }
        if let mutable = filter.mutable, mutable != entry.mutable {
          return false
        }
        if let activationState = filter.activationState, activationState != entry.activationState {
          return false
        }
        return true
      }
    }
  }

  public func fetch(
    target: WorkflowRegistryTarget,
    workingDirectory: String = FileManager.default.currentDirectoryPath
  ) throws -> WorkflowCatalogEntry {
    try withCoordinatedRead(workingDirectory: workingDirectory) {
      let candidates = try list(
      filter: WorkflowRegistryFilter(scope: target.scope),
      workingDirectory: workingDirectory
    ).filter { $0.workflowId == target.workflowId || $0.workflowName == target.workflowId }
      if let originId = target.originId {
      guard let exact = candidates.first(where: { $0.originId == originId }) else {
        throw WorkflowRegistryError(
          code: .invalidOrigin,
          message: "originId does not identify workflow '\(target.workflowId)'",
          workflowId: target.workflowId,
          originId: originId
        )
      }
        return exact
      }
      guard let selected = candidates.min(by: { precedence($0) < precedence($1) }) else {
      throw WorkflowRegistryError(
        code: .workflowNotFound,
        message: "workflow '\(target.workflowId)' was not found",
        workflowId: target.workflowId
      )
      }
      return selected
    }
  }

  public func register(
    input: URL,
    overwrite: Bool,
    activationState: WorkflowActivationState? = nil,
    workingDirectory: String = FileManager.default.currentDirectoryPath
  ) throws -> WorkflowRegistryMutationResult {
    try coordinated(workingDirectory: workingDirectory) {
      let registered = try registry.register(
        input: input,
        overwrite: overwrite,
        activationState: activationState
      )
      let entry = try WorkflowRegistryService(registry: WorkflowMutableRegistry()).mutableEntry(
        workflowId: registered.workflowId,
        workingDirectory: workingDirectory
      )
      return WorkflowRegistryMutationResult(
        accepted: true,
        overwritten: registered.overwritten,
        workflow: entry
      )
    }
  }

  public func update(
    target: WorkflowRegistryTarget,
    input: URL,
    workingDirectory: String = FileManager.default.currentDirectoryPath
  ) throws -> WorkflowRegistryMutationResult {
    try coordinated(workingDirectory: workingDirectory) {
      let entry = try fetch(target: target, workingDirectory: workingDirectory)
      try requireMutable(entry)
      return try registry.withCoordinatorWorkflowLocks(
        workflowIds: [entry.workflowId],
        originIds: [entry.originId]
      ) {
        _ = try registry.update(workflowId: entry.workflowId, input: input)
        return WorkflowRegistryMutationResult(
          accepted: true,
          workflow: try mutableEntry(workflowId: entry.workflowId, workingDirectory: workingDirectory)
        )
      }
    }
  }

  public func delete(
    target: WorkflowRegistryTarget,
    workingDirectory: String = FileManager.default.currentDirectoryPath
  ) throws -> WorkflowRegistryMutationResult {
    try coordinated(workingDirectory: workingDirectory) {
      let entry = try fetch(target: target, workingDirectory: workingDirectory)
      try requireMutable(entry)
      return try registry.withCoordinatorWorkflowLocks(
        workflowIds: [entry.workflowId],
        originIds: [entry.originId]
      ) {
        _ = try registry.delete(workflowId: entry.workflowId)
        try activationStore.remove(origin: origin(for: entry))
        return WorkflowRegistryMutationResult(accepted: true, retiredWorkflows: [entry])
      }
    }
  }

  public func setActivation(
    _ state: WorkflowActivationState,
    target: WorkflowRegistryTarget,
    workingDirectory: String = FileManager.default.currentDirectoryPath
  ) throws -> WorkflowRegistryMutationResult {
    try coordinated(workingDirectory: workingDirectory) {
      var entry = try fetch(target: target, workingDirectory: workingDirectory)
      return try registry.withCoordinatorWorkflowLocks(
        workflowIds: [entry.workflowId],
        originIds: [entry.originId]
      ) {
        try activationStore.set(state, for: origin(for: entry))
        entry.activationState = state
        return WorkflowRegistryMutationResult(accepted: true, workflow: entry)
      }
    }
  }

  public func consolidate(
    sources: [WorkflowRegistryTarget],
    replacement: URL,
    retireMode: WorkflowRetireMode,
    activateReplacement: Bool = true,
    workingDirectory: String = FileManager.default.currentDirectoryPath
  ) throws -> WorkflowRegistryMutationResult {
    try coordinated(workingDirectory: workingDirectory) {
      guard sources.count >= 2 else {
        throw WorkflowRegistryError(code: .invalidWorkflow, message: "consolidation requires at least two sources")
      }
      let resolved = try sources.map { try fetch(target: $0, workingDirectory: workingDirectory) }
      guard Set(resolved.map(\.originId)).count == resolved.count else {
        throw WorkflowRegistryError(code: .invalidOrigin, message: "consolidation sources must be unique")
      }
      if retireMode == .delete, let immutable = resolved.first(where: { !$0.mutable }) {
        throw WorkflowRegistryError(
          code: .immutableWorkflow,
          message: "immutable workflow '\(immutable.workflowId)' cannot be deleted",
          workflowId: immutable.workflowId,
          originId: immutable.originId
        )
      }
      let staged = try FileSystemWorkflowBundleResolver().loadBundle(
        at: replacement.standardizedFileURL,
        rootDirectory: replacement.standardizedFileURL,
        scope: .user,
        provenance: .mutable
      )
      let diagnostics = staged.diagnostics
        + DefaultWorkflowValidator().validate(staged.workflow, nodePayloads: staged.nodePayloads)
      guard !diagnostics.contains(where: { $0.severity == .error }) else {
        throw WorkflowRegistryError(
          code: .invalidWorkflow,
          message: "consolidated replacement failed validation",
          workflowId: staged.workflow.workflowId
        )
      }
      let existing = try list(workingDirectory: workingDirectory)
      guard !existing.contains(where: {
        $0.workflowId == staged.workflow.workflowId || $0.workflowName == staged.workflow.workflowId
      }) else {
        throw WorkflowRegistryError(
          code: .duplicateWorkflow,
          message: "consolidated replacement workflowId already exists in the catalog",
          workflowId: staged.workflow.workflowId
        )
      }
      return try registry.withCoordinatorWorkflowLocks(
        workflowIds: resolved.map(\.workflowId) + [staged.workflow.workflowId],
        originIds: resolved.map(\.originId) + [registry.mutableOriginId(staged.workflow.workflowId)]
      ) {
        let transactionId = UUID().uuidString.lowercased()
        var journalSources: [WorkflowConsolidationSource] = []
        for entry in resolved {
          let target = WorkflowRegistryTarget(
            workflowId: entry.workflowId,
            scope: WorkflowRegistryScope(rawValue: entry.scope.rawValue) ?? .auto,
            originId: entry.originId
          )
          let backup = retireMode == .delete
            ? try coordinator.createBackup(
              source: URL(fileURLWithPath: entry.workflowDirectory, isDirectory: true),
              transactionId: transactionId,
              originId: entry.originId
            )
            : nil
          journalSources.append(WorkflowConsolidationSource(
            target: target,
            provenance: entry.provenance,
            activationState: entry.activationState,
            backupPath: backup?.path,
            backupDigest: try backup.map { try coordinator.bundleDigest(at: $0) }
          ))
        }
        var journal = WorkflowConsolidationJournal(
          schemaVersion: 1,
          transactionId: transactionId,
          phase: .prepared,
          sources: journalSources,
          replacementWorkflowId: staged.workflow.workflowId,
          replacementDigest: try coordinator.bundleDigest(at: replacement.standardizedFileURL),
          retireMode: retireMode,
          activateReplacement: activateReplacement
        )
        try coordinator.write(journal)
        try coordinator.hooks.afterPhase(.prepared)
        do {
          let registration = try register(
            input: replacement,
            overwrite: false,
            activationState: activateReplacement ? .active : .deactivated,
            workingDirectory: workingDirectory
          )
          journal.phase = .replacementPublished
          try coordinator.write(journal)
          try coordinator.hooks.afterPhase(.replacementPublished)
          journal.phase = .retiringSources
          try coordinator.write(journal)
          try coordinator.hooks.afterPhase(.retiringSources)
          let retired = try retireSources(journal, workingDirectory: workingDirectory)
          journal.phase = .committed
          try coordinator.write(journal)
          try coordinator.hooks.afterPhase(.committed)
          try coordinator.removeBackups(transactionId: transactionId)
          try coordinator.removeJournal()
          return WorkflowRegistryMutationResult(
            accepted: true,
            workflow: registration.workflow,
            retiredWorkflows: retired
          )
        } catch is WorkflowConsolidationInterruption {
          throw WorkflowConsolidationInterruption()
        } catch {
          let operationError = error
          do {
            try rollbackConsolidation(journal, workingDirectory: workingDirectory)
          } catch {
            throw WorkflowRegistryError(
              code: .registryIOFailure,
              message: "consolidation failed and rollback could not be completed: \(operationError); \(error)"
            )
          }
          throw operationError
        }
      }
    }
  }

  private func coordinated<T>(
    workingDirectory: String,
    _ body: () throws -> T
  ) throws -> T {
    try coordinator.withLock(
      registry: registry,
      activationStore: activationStore,
      recovery: { try recoverConsolidation(workingDirectory: workingDirectory) },
      body: body
    )
  }

  func withCoordinatedRead<T>(
    workingDirectory: String,
    _ body: () throws -> T
  ) throws -> T {
    try coordinator.withReadLock(
      registry: registry,
      activationStore: activationStore,
      recovery: { try recoverConsolidation(workingDirectory: workingDirectory) },
      body: body
    )
  }

  private func recoverConsolidation(workingDirectory: String) throws {
    guard let journal = try coordinator.loadJournal() else { return }
    try registry.withCoordinatorWorkflowLocks(
      workflowIds: journal.sources.map(\.target.workflowId) + [journal.replacementWorkflowId],
      originIds: journal.sources.compactMap(\.target.originId)
        + [registry.mutableOriginId(journal.replacementWorkflowId)]
    ) {
      guard try coordinator.loadJournal() == journal else {
        throw WorkflowRegistryError(code: .registryIOFailure, message: "consolidation journal changed during recovery")
      }
      let replacementTarget = WorkflowRegistryTarget(
        workflowId: journal.replacementWorkflowId,
        scope: .user
      )
      let replacementExists = try existingEntry(
        target: replacementTarget,
        workingDirectory: workingDirectory
      )
      if let replacementExists,
         try coordinator.bundleDigest(at: URL(fileURLWithPath: replacementExists.workflowDirectory, isDirectory: true))
          != journal.replacementDigest {
        throw WorkflowRegistryError(
          code: .registryIOFailure,
          message: "consolidation replacement changed after journal publication"
        )
      }
      if journal.phase == .prepared, replacementExists == nil {
        try coordinator.removeBackups(transactionId: journal.transactionId)
        try coordinator.removeJournal()
        return
      }
      guard replacementExists != nil else {
        try rollbackConsolidation(journal, workingDirectory: workingDirectory)
        return
      }
      _ = try retireSources(journal, workingDirectory: workingDirectory)
      try coordinator.removeBackups(transactionId: journal.transactionId)
      try coordinator.removeJournal()
    }
  }

  private func retireSources(
    _ journal: WorkflowConsolidationJournal,
    workingDirectory: String
  ) throws -> [WorkflowCatalogEntry] {
    var retired: [WorkflowCatalogEntry] = []
    for source in journal.sources {
      guard let entry = try existingEntry(target: source.target, workingDirectory: workingDirectory) else {
        if journal.retireMode == .delete { continue }
        throw WorkflowRegistryError(
          code: .workflowNotFound,
          message: "consolidation source disappeared during retirement",
          workflowId: source.target.workflowId,
          originId: source.target.originId
        )
      }
      switch journal.retireMode {
      case .deactivate:
        let result = try setActivation(.deactivated, target: source.target, workingDirectory: workingDirectory)
        if let workflow = result.workflow { retired.append(workflow) }
      case .delete:
        _ = try delete(target: source.target, workingDirectory: workingDirectory)
        retired.append(entry)
      }
    }
    return retired
  }

  private func rollbackConsolidation(
    _ journal: WorkflowConsolidationJournal,
    workingDirectory: String
  ) throws {
    if let replacement = try existingEntry(
      target: WorkflowRegistryTarget(workflowId: journal.replacementWorkflowId, scope: .user),
      workingDirectory: workingDirectory
    ) {
      _ = try delete(
        target: WorkflowRegistryTarget(
          workflowId: replacement.workflowId,
          scope: .user,
          originId: replacement.originId
        ),
        workingDirectory: workingDirectory
      )
    }
    for source in journal.sources {
      if journal.retireMode == .delete,
         try existingEntry(target: source.target, workingDirectory: workingDirectory) == nil {
        guard let backupPath = source.backupPath else {
          throw WorkflowRegistryError(code: .registryIOFailure, message: "consolidation source backup is missing")
        }
        guard let expectedDigest = source.backupDigest else {
          throw WorkflowRegistryError(code: .registryIOFailure, message: "consolidation source backup digest is missing")
        }
        _ = try coordinator.withValidatedBackupSnapshot(
          path: backupPath,
          transactionId: journal.transactionId,
          originId: source.target.originId ?? "",
          expectedDigest: expectedDigest
        ) { backup in
          try register(
            input: backup,
            overwrite: false,
            activationState: source.activationState,
            workingDirectory: workingDirectory
          )
        }
      } else if try existingEntry(target: source.target, workingDirectory: workingDirectory) != nil {
        _ = try setActivation(
          source.activationState,
          target: source.target,
          workingDirectory: workingDirectory
        )
      }
    }
    try coordinator.removeBackups(transactionId: journal.transactionId)
    try coordinator.removeJournal()
  }

  private func existingEntry(
    target: WorkflowRegistryTarget,
    workingDirectory: String
  ) throws -> WorkflowCatalogEntry? {
    do {
      return try fetch(target: target, workingDirectory: workingDirectory)
    } catch let error as WorkflowRegistryError
      where error.code == .workflowNotFound || error.code == .invalidOrigin {
      return nil
    }
  }

  private func mutableEntry(workflowId: String, workingDirectory: String) throws -> WorkflowCatalogEntry {
    guard let entry = try list(workingDirectory: workingDirectory).first(where: {
      $0.workflowId == workflowId && $0.provenance == .mutable
    }) else {
      throw WorkflowRegistryError(
        code: .workflowNotFound,
        message: "mutable workflow '\(workflowId)' was not found after mutation",
        workflowId: workflowId
      )
    }
    return entry
  }

  private func requireMutable(_ entry: WorkflowCatalogEntry) throws {
    guard entry.provenance == .mutable else {
      throw WorkflowRegistryError(
        code: .immutableWorkflow,
        message: "immutable workflow '\(entry.workflowId)' cannot be modified; register a mutable copy",
        workflowId: entry.workflowId,
        originId: entry.originId
      )
    }
  }

  private func origin(for entry: WorkflowCatalogEntry) -> WorkflowOriginIdentity {
    workflowOriginIdentity(
      name: entry.workflowName,
      workflowId: entry.workflowId,
      scope: entry.scope,
      sourceKind: entry.sourceKind,
      provenance: entry.provenance,
      locator: entry.workflowDirectory
    )
  }

  private func precedence(_ entry: WorkflowCatalogEntry) -> Int {
    switch (entry.scope, entry.sourceKind, entry.provenance) {
    case (.project, .workflow, _): 0
    case (.user, .workflow, .immutable): 1
    case (.project, .package, _): 2
    case (.user, .package, _): 3
    case (.user, .workflow, .mutable): 4
    default: 5
    }
  }
}
