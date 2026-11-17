#if os(macOS)
import Foundation
import RielaCLI
import RielaCore
import RielaObservability

func rielaAppRetentionRequest(
  homeDirectory: URL,
  projectRoot: URL?,
  environment: [String: String]
) -> RielaRetentionRequest {
  RielaRetentionRequest(
    trigger: .automatic,
    homeDirectory: homeDirectory,
    projectDirectory: projectRoot,
    explicitSessionStore: nil,
    environment: environment,
    scope: .all,
    overrides: RielaRetentionOverrides(),
    dryRun: false
  )
}

/// Thread-safe holder for the active profile's session store, read by the
/// off-main maintenance pass.
final class RielaAppMaintenanceTarget: @unchecked Sendable {
  private let lock = NSLock()
  private var root: String?
  var sessionStoreRoot: String? {
    get { lock.lock(); defer { lock.unlock() }; return root }
    set { lock.lock(); root = newValue; lock.unlock() }
  }
}

final class RielaAppMaintenancePassCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func next() -> Int { lock.lock(); defer { count += 1; lock.unlock() }; return count }
}

/// Sessions whose runner died recently are left alone for this long so a run
/// that has persisted `running` but not yet taken its execution lock is never
/// mistaken for an orphan.
let rielaAppOrphanReconcileMinimumIdle: TimeInterval = 15 * 60

func rielaAppReconcileOrphanedSessions(sessionStoreRoot: String, minimumIdle: TimeInterval) {
  let key = BoundedSessionStoreIO.key(sessionStoreRoot: sessionStoreRoot)
  do {
    let summary = try BoundedSessionStoreIO.runBlocking(key: key, timeout: 120) {
      try SessionOrphanReconciliation.reconcileOrphanedRoots(sessionStoreRoot: sessionStoreRoot, minimumIdle: minimumIdle)
    }
    if !summary.reconciledSessionIds.isEmpty || summary.skipped > 0 {
      RielaStandardStreams.writeError("RielaApp session reconcile: cancelled \(summary.reconciledSessionIds.count) orphaned " +
        "session(s) whose runner process is gone \(summary.reconciledSessionIds); skipped \(summary.skipped)\n")
    }
  } catch {
    RielaStandardStreams.writeError("RielaApp session reconcile warning: \(error)\n")
  }
}

extension RielaApp {
  func startRetention() {
    let request = rielaAppRetentionRequest(
      homeDirectory: appHomeDirectory,
      projectRoot: launchOptions.projectRoot,
      environment: launchOptions.environment
    )
    let target = maintenanceTarget
    target.sessionStoreRoot = daemonSessionStoreRoot(profileName: daemonProfileName)
    // An App restart means every in-process run of the previous App process
    // is gone, so the first pass reconciles them almost right away (still
    // lock-checked); later passes use the longer idle guard.
    let passCounter = RielaAppMaintenancePassCounter()
    retentionScheduler = RielaRetentionScheduler(runImmediately: true) {
      if let root = target.sessionStoreRoot {
        rielaAppReconcileOrphanedSessions(sessionStoreRoot: root,
          minimumIdle: passCounter.next() == 0 ? 60 : rielaAppOrphanReconcileMinimumIdle)
      }
      for warning in RielaAutomaticStoragePass.runScheduled(request) {
        let prefix = "riela retention warning: "
        let detail = warning.hasPrefix(prefix) ? String(warning.dropFirst(prefix.count)) : warning
        RielaStandardStreams.writeError("RielaApp retention warning: \(detail)\n")
      }
    }
    retentionScheduler?.start()
  }
}
#endif
