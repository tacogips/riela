import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public final class RielaAppOwnerStartup: @unchecked Sendable {
  private let run: RielaAppRunDirectory
  private let waitObserver: (@Sendable () -> Void)?
  private let acquire: @Sendable (RielaAppRunDirectory) throws -> RielaAppOwnerLock

  public init(
    run: RielaAppRunDirectory,
    waitObserver: (@Sendable () -> Void)? = nil,
    acquire: @escaping @Sendable (RielaAppRunDirectory) throws -> RielaAppOwnerLock = RielaAppOwnerLock.acquireBlocking
  ) {
    self.run = run
    self.waitObserver = waitObserver
    self.acquire = acquire
  }

  public func start(
    bindChannel: @escaping @Sendable (URL) throws -> Void,
    phaseB: @escaping @MainActor @Sendable (RielaAppOwnerLock) -> Void,
    failed: @escaping @MainActor @Sendable (RielaAppOwnerLockError) -> Void
  ) {
    Thread { [run, waitObserver, acquire] in
      do {
        try run.prepare()
        waitObserver?()
        let lock = try acquire(run)
        Self.unlinkSocketIfOwned(run, lock: lock)
        if run.socketPathFits { try? bindChannel(run.socketURL) }
        Task { @MainActor in phaseB(lock) }
      } catch {
        let ownerError = (error as? RielaAppOwnerLockError) ?? .io(Int32((error as NSError).code))
        Task { @MainActor in failed(ownerError) }
      }
    }.start()
  }

  public static func unlinkSocketIfOwned(_ run: RielaAppRunDirectory, lock: RielaAppOwnerLock) {
    lock.whileOwned { _ = unlink(run.socketURL.path) }
  }
}
