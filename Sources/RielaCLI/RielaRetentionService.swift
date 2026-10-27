import Foundation
import RielaCore

public enum RielaRetentionTrigger: String, Codable, Sendable {
  case automatic
  case manual
}

public struct RielaRetentionOverrides: Equatable, Sendable {
  public var resultsMaxAgeDays: Int?
  public var resultsMaxTotalBytes: Int64?
  public var messagesMaxAgeDays: Int?
  public var messagesMaxTotalBytes: Int64?
  public var logsMaxAgeDays: Int?
  public var logsMaxTotalBytes: Int64?

  public init(resultsMaxAgeDays: Int? = nil, resultsMaxTotalBytes: Int64? = nil,
              messagesMaxAgeDays: Int? = nil, messagesMaxTotalBytes: Int64? = nil,
              logsMaxAgeDays: Int? = nil, logsMaxTotalBytes: Int64? = nil) {
    self.resultsMaxAgeDays = resultsMaxAgeDays
    self.resultsMaxTotalBytes = resultsMaxTotalBytes
    self.messagesMaxAgeDays = messagesMaxAgeDays
    self.messagesMaxTotalBytes = messagesMaxTotalBytes
    self.logsMaxAgeDays = logsMaxAgeDays
    self.logsMaxTotalBytes = logsMaxTotalBytes
  }

  public var isEmpty: Bool {
    resultsMaxAgeDays == nil && resultsMaxTotalBytes == nil && messagesMaxAgeDays == nil &&
      messagesMaxTotalBytes == nil && logsMaxAgeDays == nil && logsMaxTotalBytes == nil
  }
}

public struct RielaRetentionRequest: Sendable {
  public var trigger: RielaRetentionTrigger
  public var homeDirectory: URL
  public var projectDirectory: URL?
  public var explicitSessionStore: String?
  public var environment: [String: String]
  public var scope: RielaGarbageCollectionScope
  public var overrides: RielaRetentionOverrides
  public var dryRun: Bool

  public init(trigger: RielaRetentionTrigger, homeDirectory: URL, projectDirectory: URL? = nil,
              explicitSessionStore: String? = nil, environment: [String: String] = [:],
              scope: RielaGarbageCollectionScope = .all, overrides: RielaRetentionOverrides = .init(),
              dryRun: Bool = false) {
    self.trigger = trigger
    self.homeDirectory = homeDirectory
    self.projectDirectory = projectDirectory
    self.explicitSessionStore = explicitSessionStore
    self.environment = environment
    self.scope = scope
    self.overrides = overrides
    self.dryRun = dryRun
  }
}

public struct RielaRetentionGeneratedReport: Codable, Equatable, Sendable {
  public var removedEntryCount: Int
  public var removedBytes: Int64
}

public struct RielaRetentionDefinitionReport: Codable, Equatable, Sendable {
  public var keepVersions: Int
  public var workflowCount: Int
  public var removedVersionCount: Int
  public var removedAuditCount: Int
  public var removedBlobCount: Int
  public var removedBlobBytes: Int64
}

public struct RielaRetentionOrphanLockReport: Codable, Equatable, Sendable {
  public var selectedCount: Int
  public var removedCount: Int
  public var skippedBusy: Int
}

public struct RielaRetentionTargetReport: Codable, Equatable, Sendable {
  public var kind: RielaRetentionTargetKind
  public var root: String
  public var status: String
  public var results: RetentionCategoryReport
  public var messages: RetentionCategoryReport
  public var logs: RetentionCategoryReport
  public var generated: RielaRetentionGeneratedReport
  public var orphanLocks: RielaRetentionOrphanLockReport?
  public var definitions: RielaRetentionDefinitionReport?
  public var reclamation: [RielaRetentionReclamationReport]
  public var warnings: [String]
}

public struct RielaRetentionReclamationReport: Codable, Equatable, Sendable {
  public var database: String
  public var autoVacuum: String
  public var action: String
  public var fileBytesBefore: Int64
  public var fileBytesAfter: Int64
  public var reclaimedBytes: Int64
  public var reusableFreeBytes: Int64
  public var warning: String?

  init(_ result: RetentionReclamationResult) {
    database = result.database
    autoVacuum = result.autoVacuum
    action = result.action.rawValue
    fileBytesBefore = result.fileBytesBefore
    fileBytesAfter = result.fileBytesAfter
    reclaimedBytes = result.reclaimedBytes
    reusableFreeBytes = result.reusableFreeBytes
    warning = result.warning
  }
}

public struct RielaRetentionReport: Codable, Equatable, Sendable {
  public var dryRun: Bool
  public var trigger: RielaRetentionTrigger
  public var targets: [RielaRetentionTargetReport]

  public var hasFailure: Bool { targets.contains { $0.status == "failed" || $0.status == "busy" } }
}

public enum RielaRetentionUsageError: Error, Equatable, LocalizedError {
  case keepForeverOverride(category: String)
  case invalidOverride(String)

  public var errorDescription: String? {
    switch self {
    case .keepForeverOverride(let category): "Cannot override \(category): keepForever is enabled"
    case .invalidOverride(let message): message
    }
  }
}

public struct RielaRetentionService: Sendable {
  private let clock: @Sendable () -> Date
  private let freeSpace: (@Sendable (String) -> Int64?)?

  public init(clock: @escaping @Sendable () -> Date = Date.init,
              freeSpace: (@Sendable (String) -> Int64?)? = nil) {
    self.clock = clock
    self.freeSpace = freeSpace
  }

  public func run(_ request: RielaRetentionRequest) throws -> RielaRetentionReport {
    let configuration = try RielaRetentionConfiguration.load(homeDirectory: request.homeDirectory,
      projectDirectory: request.projectDirectory, environment: request.environment)
    let targets = RetentionTargetResolver.resolve(scope: request.scope, homeDirectory: request.homeDirectory,
      projectDirectory: request.projectDirectory, explicitSessionStore: request.explicitSessionStore,
      environment: request.environment)
    let work = try targets.compactMap { target -> (RetentionTarget, RielaRetentionPolicy)? in
      let configured = configuration.policy(for: target.kind)
      if request.trigger == .automatic && (configured == nil || configured?.automatic == false) { return nil }
      var policy = configured ?? RielaRetentionPolicy()
      try apply(request.overrides, to: &policy)
      return (target, policy)
    }
    var reports: [RielaRetentionTargetReport] = []
    for (target, policy) in work {
      if let unsafeReason = target.unsafeReason {
        reports.append(emptyReport(target: target, status: "skippedUnsafePath", warning: unsafeReason))
        continue
      }
      let now = clock()
      if request.trigger == .automatic && RetentionRunStamp.isFresh(
        RetentionRunStamp.read(stateDirectory: target.stateDirectory), now: now,
        minInterval: TimeInterval(policy.minIntervalMinutes * 60)
      ) {
        reports.append(emptyReport(target: target, status: "skippedThrottled"))
        continue
      }
      var lock: RetentionTargetLock?
      do {
        if !request.dryRun {
          lock = try RetentionTargetLock.tryAcquire(stateDirectory: target.stateDirectory)
          if lock == nil {
            reports.append(emptyReport(target: target, status: request.trigger == .automatic ? "skippedBusy" : "busy"))
            continue
          }
          if request.trigger == .automatic && RetentionRunStamp.isFresh(
            RetentionRunStamp.read(stateDirectory: target.stateDirectory), now: now,
            minInterval: TimeInterval(policy.minIntervalMinutes * 60)
          ) {
            reports.append(emptyReport(target: target, status: "skippedThrottled"))
            continue
          }
          try RetentionRunStamp(lastAttemptAt: now, lastCompletedAt: nil, lastStatus: nil)
            .write(stateDirectory: target.stateDirectory)
        }
      } catch {
        var failed = emptyReport(target: target, status: "failed")
        failed.warnings.append(error.localizedDescription)
        reports.append(failed)
        continue
      }
      var report = emptyReport(target: target, status: "completed")
      do {
        try runTarget(target, policy: policy, request: request, now: now, report: &report)
      } catch {
        report.status = "failed"
        report.warnings.append(error.localizedDescription)
      }
      if !request.dryRun {
        if let stamp = RetentionRunStamp.read(stateDirectory: target.stateDirectory) {
          try? RetentionRunStamp(lastAttemptAt: stamp.lastAttemptAt, lastCompletedAt: clock(),
            lastStatus: report.status).write(stateDirectory: target.stateDirectory)
        }
      }
      reports.append(report)
      withExtendedLifetime(lock) {}
    }
    return RielaRetentionReport(dryRun: request.dryRun, trigger: request.trigger, targets: reports)
  }

  private func makeExecutor() -> TerminalRetentionExecutor {
    var executor = TerminalRetentionExecutor(clock: clock)
    if let freeSpace { executor.reclaimer.freeSpace = freeSpace }
    return executor
  }

  private func reclamationMode(_ request: RielaRetentionRequest) -> RetentionReclamationMode {
    request.trigger == .automatic ? .automatic : .manual
  }

  private func runTarget(
    _ target: RetentionTarget,
    policy: RielaRetentionPolicy,
    request: RielaRetentionRequest,
    now: Date,
    report: inout RielaRetentionTargetReport
  ) throws {
    let results = policy.results
    let messages = policy.messages
    var retentionReport = TerminalRetentionPolicyReport(results: .inactive(results.state),
      messages: .inactive(messages.state), orphanLocks: nil, reclamation: [])
    // The session store (tombstones, orphan locks, reclamation) is only touched when results or messages is active.
    let sessionStoreActive = results.state == .active || messages.state == .active
    report.results = retentionReport.results
    report.messages = retentionReport.messages
    if sessionStoreActive, let sessionRoot = target.sessionStoreRoot {
      do {
        let paths = try TerminalRetentionPaths(sessionRoot: sessionRoot, artifactRoot: nil, memoryRoot: target.memoryRoot)
        let resultPolicy = results.state == .active ? categoryPolicy(results) : nil
        let messageMode: TerminalRetentionMessageMode
        if messages.state == .notConfigured { messageMode = .followResults
        } else if messages.state == .keepForever { messageMode = .keepForever
        } else { messageMode = .independent(categoryPolicy(messages)) }
        retentionReport = try makeExecutor().runPolicy(paths: paths, keepWorkflowIds: Set(results.keepWorkflowIds),
          results: resultPolicy, resultsState: results.state, messages: messageMode,
          messagesState: messages.state, dryRun: request.dryRun, reclamationMode: reclamationMode(request))
        report.results = retentionReport.results
        report.messages = retentionReport.messages
      } catch {
        report.warnings.append(error.localizedDescription)
        report.results = .inactive(results.state)
        report.messages = .inactive(messages.state)
        report.status = "failed"
      }
    }
    if let logsRoot = target.logsRoot {
      let (logReport, warnings) = RetentionLogPruner(now: { now }).run(logsRoot: logsRoot,
        state: policy.logs.state, policy: policy.logs.state == .active ? snapshot(policy.logs) : nil,
        dryRun: request.dryRun)
      var resolvedLogReport = logReport
      if request.dryRun, logReport.state == .active {
        resolvedLogReport.remainingBytes = max(0, logReport.beforeBytes - logReport.selectedBytes)
        resolvedLogReport.capAchieved = logReport.policy?.maxTotalBytes.map {
          resolvedLogReport.remainingBytes <= $0
        }
      }
      report.logs = resolvedLogReport
      report.warnings.append(contentsOf: warnings)
      if !warnings.isEmpty { report.status = "failed" }
    } else {
      report.logs = .inactive(policy.logs.state)
    }
    if results.state == .active, let maxAgeDays = results.maxAgeDays, target.kind != .explicit {
      let scope: RielaGarbageCollectionScope = target.kind == .user ? .user : .project
      let project = request.projectDirectory ?? request.homeDirectory
      let generated = RielaDataGarbageCollector().collect(retentionDays: maxAgeDays, scope: scope,
        homeDirectory: request.homeDirectory, projectDirectory: project, dryRun: request.dryRun, now: now)
      report.generated = RielaRetentionGeneratedReport(removedEntryCount: generated.removedEntryCount,
        removedBytes: generated.reclaimedBytes)
      // The collector always notes that sessions, artifacts and logs are preserved; that is informational, not a failure.
      let diagnostics = generated.diagnostics.filter { !$0.hasPrefix("runtime sessions, artifacts and logs preserved") }
      report.warnings.append(contentsOf: diagnostics)
      if !diagnostics.isEmpty { report.status = "failed" }
    }
    if let sessionRoot = target.sessionStoreRoot {
      do {
        report.definitions = try pruneDefinitions(
          sessionRoot: sessionRoot,
          keepVersions: policy.definitions.keepVersions ?? WorkflowDefinitionStore.defaultHistoryRetention,
          request: request
        )
      } catch {
        report.warnings.append(error.localizedDescription)
        report.status = "failed"
      }
    }
    if sessionStoreActive, let sessionRoot = target.sessionStoreRoot {
      do {
        let paths = try TerminalRetentionPaths(sessionRoot: sessionRoot, artifactRoot: nil, memoryRoot: target.memoryRoot)
        makeExecutor().finalize(paths: paths, report: &retentionReport,
          mode: reclamationMode(request), dryRun: request.dryRun)
        if let orphan = retentionReport.orphanLocks {
          report.orphanLocks = RielaRetentionOrphanLockReport(selectedCount: orphan.selectedCount,
            removedCount: orphan.removedCount, skippedBusy: orphan.skippedBusy)
        }
        let reclamations = retentionReport.reclamation.map(RielaRetentionReclamationReport.init)
        report.reclamation.append(contentsOf: reclamations)
        let reclamationWarnings = reclamations.compactMap(\.warning)
        report.warnings.append(contentsOf: reclamationWarnings)
        // A busy writer is a reportable warning, not a failed pass; other reclamation warnings still fail it.
        if reclamations.contains(where: { $0.warning != nil && $0.action != "busy" }) { report.status = "failed" }
      } catch {
        report.warnings.append(error.localizedDescription)
        report.status = "failed"
      }
    }
  }

  /// Prunes every workflow in an existing store; a missing database is never created.
  private func pruneDefinitions(
    sessionRoot: String,
    keepVersions: Int,
    request: RielaRetentionRequest
  ) throws -> RielaRetentionDefinitionReport {
    var report = RielaRetentionDefinitionReport(keepVersions: keepVersions, workflowCount: 0, removedVersionCount: 0,
      removedAuditCount: 0, removedBlobCount: 0, removedBlobBytes: 0)
    guard FileManager.default.fileExists(atPath: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: sessionRoot)) else {
      return report
    }
    let store = WorkflowDefinitionStore(rootDirectory: sessionRoot)
    let reason = "\(request.trigger.rawValue) retention policy: keep newest \(keepVersions) definition versions"
    for workflowName in try store.workflowNames() {
      let result = try store.prune(workflowName: workflowName, keepVersions: keepVersions, reason: reason,
        actor: WorkflowDefinitionActor(kind: .cli, id: "riela-retention"), dryRun: request.dryRun)
      report.workflowCount += 1
      report.removedVersionCount += result.removedVersionIds.count
      report.removedAuditCount += result.removedAuditCount
      report.removedBlobCount += result.removedBlobCount
      report.removedBlobBytes += result.removedBlobBytes
    }
    return report
  }

  private func apply(_ overrides: RielaRetentionOverrides, to policy: inout RielaRetentionPolicy) throws {
    try apply(overrides.resultsMaxAgeDays, overrides.resultsMaxTotalBytes, category: &policy.results, name: "results")
    try apply(overrides.messagesMaxAgeDays, overrides.messagesMaxTotalBytes, category: &policy.messages, name: "messages")
    try apply(overrides.logsMaxAgeDays, overrides.logsMaxTotalBytes, category: &policy.logs, name: "logs")
  }

  private func apply(_ age: Int?, _ bytes: Int64?, category: inout RielaRetentionCategory, name: String) throws {
    guard age != nil || bytes != nil else { return }
    if category.keepForever { throw RielaRetentionUsageError.keepForeverOverride(category: name) }
    if let age, !(1...36_500).contains(age) { throw RielaRetentionUsageError.invalidOverride("\(name) max age must be between 1 and 36500 days") }
    if let bytes, !(1...(Int64(1) << 50)).contains(bytes) { throw RielaRetentionUsageError.invalidOverride("\(name) max total bytes must be between 1 and 2^50") }
    if let age { category.maxAgeDays = age }
    if let bytes { category.maxTotalBytes = bytes }
  }

  private func categoryPolicy(_ category: RielaRetentionCategory) -> TerminalRetentionCategoryPolicy {
    TerminalRetentionCategoryPolicy(maxAge: category.maxAgeDays.map { TimeInterval($0) * 86_400 }, maxBytes: category.maxTotalBytes)
  }

  private func snapshot(_ category: RielaRetentionCategory) -> RetentionPolicySnapshot {
    RetentionPolicySnapshot(maxAgeDays: category.maxAgeDays, maxTotalBytes: category.maxTotalBytes)
  }

  private func emptyReport(target: RetentionTarget, status: String, warning: String? = nil) -> RielaRetentionTargetReport {
    RielaRetentionTargetReport(kind: target.kind, root: target.root, status: status,
      results: .inactive(.notConfigured), messages: .inactive(.notConfigured), logs: .inactive(.notConfigured),
      generated: RielaRetentionGeneratedReport(removedEntryCount: 0, removedBytes: 0), orphanLocks: nil,
      definitions: nil, reclamation: [], warnings: warning.map { [$0] } ?? [])
  }
}
