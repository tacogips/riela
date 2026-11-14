import Foundation
import RielaCore

struct WorkflowMutableRegistryTransaction: Codable, Equatable, Sendable {
  enum Operation: String, Codable, Sendable {
    case replace
    case delete
  }

  var schemaVersion: Int
  var workflowId: String
  var transactionId: String
  var phase: WorkflowMutableRegistryPhase
  var hadOriginal: Bool
  var replacementDigest: String
  var destinationPath: String
  var stagingPath: String
  var backupPath: String?
  var operation: Operation?
  var requestedActivationState: WorkflowActivationState?
  var deletionActivationRemoved: Bool?
}

struct WorkflowMutableRegistryRecoveryFailure: Error, CustomStringConvertible {
  var publicationError: Error
  var recoveryError: Error

  var description: String {
    "mutable workflow publication failed: \(publicationError); "
      + "recovery failed and registry artifacts were preserved: \(recoveryError)"
  }
}

public enum WorkflowMutableRegistryPhase: String, Codable, CaseIterable, Sendable {
  case prepared
  case movingOriginal
  case originalBackedUp
  case publishingReplacement
  case replacementPublished
}

enum WorkflowMutableRegistryLock: Equatable, Sendable {
  case catalog
  case workflow(String)
}

public struct WorkflowMutableRegistryHooks: Sendable {
  public var afterPhase: @Sendable (WorkflowMutableRegistryPhase) throws -> Void
  var beforeRecordRead: @Sendable (String) throws -> Void
  var beforeLockAcquire: @Sendable (WorkflowMutableRegistryLock) throws -> Void
  var afterLockAcquire: @Sendable (WorkflowMutableRegistryLock) throws -> Void
  var beforeDetachedBundleLoad: @Sendable () throws -> Void
  var afterMutationWorkspaceExport: @Sendable () throws -> Void
  var beforeDeletionActivationRemoval: @Sendable () throws -> Void
  var beforeDeletionFinalization: @Sendable () throws -> Void

  public init(afterPhase: @escaping @Sendable (WorkflowMutableRegistryPhase) throws -> Void = { _ in }) {
    self.afterPhase = afterPhase
    beforeRecordRead = { _ in }
    beforeLockAcquire = { _ in }
    afterLockAcquire = { _ in }
    beforeDetachedBundleLoad = {}
    afterMutationWorkspaceExport = {}
    beforeDeletionActivationRemoval = {}
    beforeDeletionFinalization = {}
  }

  init(
    afterPhase: @escaping @Sendable (WorkflowMutableRegistryPhase) throws -> Void,
    beforeRecordRead: @escaping @Sendable (String) throws -> Void
  ) {
    self.afterPhase = afterPhase
    self.beforeRecordRead = beforeRecordRead
    beforeLockAcquire = { _ in }
    afterLockAcquire = { _ in }
    beforeDetachedBundleLoad = {}
    afterMutationWorkspaceExport = {}
    beforeDeletionActivationRemoval = {}
    beforeDeletionFinalization = {}
  }

  init(
    beforeLockAcquire: @escaping @Sendable (WorkflowMutableRegistryLock) throws -> Void,
    afterLockAcquire: @escaping @Sendable (WorkflowMutableRegistryLock) throws -> Void
  ) {
    afterPhase = { _ in }
    beforeRecordRead = { _ in }
    self.beforeLockAcquire = beforeLockAcquire
    self.afterLockAcquire = afterLockAcquire
    beforeDetachedBundleLoad = {}
    afterMutationWorkspaceExport = {}
    beforeDeletionActivationRemoval = {}
    beforeDeletionFinalization = {}
  }

  init(
    beforeDetachedBundleLoad: @escaping @Sendable () throws -> Void = {},
    afterMutationWorkspaceExport: @escaping @Sendable () throws -> Void = {}
  ) {
    afterPhase = { _ in }
    beforeRecordRead = { _ in }
    beforeLockAcquire = { _ in }
    afterLockAcquire = { _ in }
    self.beforeDetachedBundleLoad = beforeDetachedBundleLoad
    self.afterMutationWorkspaceExport = afterMutationWorkspaceExport
    beforeDeletionActivationRemoval = {}
    beforeDeletionFinalization = {}
  }

  init(beforeDeletionActivationRemoval: @escaping @Sendable () throws -> Void) {
    afterPhase = { _ in }
    beforeRecordRead = { _ in }
    beforeLockAcquire = { _ in }
    afterLockAcquire = { _ in }
    beforeDetachedBundleLoad = {}
    afterMutationWorkspaceExport = {}
    self.beforeDeletionActivationRemoval = beforeDeletionActivationRemoval
    beforeDeletionFinalization = {}
  }

  init(beforeDeletionFinalization: @escaping @Sendable () throws -> Void) {
    afterPhase = { _ in }
    beforeRecordRead = { _ in }
    beforeLockAcquire = { _ in }
    afterLockAcquire = { _ in }
    beforeDetachedBundleLoad = {}
    afterMutationWorkspaceExport = {}
    beforeDeletionActivationRemoval = {}
    self.beforeDeletionFinalization = beforeDeletionFinalization
  }

  init(
    beforeRecordRead: @escaping @Sendable (String) throws -> Void,
    beforeDeletionFinalization: @escaping @Sendable () throws -> Void
  ) {
    afterPhase = { _ in }
    self.beforeRecordRead = beforeRecordRead
    beforeLockAcquire = { _ in }
    afterLockAcquire = { _ in }
    beforeDetachedBundleLoad = {}
    afterMutationWorkspaceExport = {}
    beforeDeletionActivationRemoval = {}
    self.beforeDeletionFinalization = beforeDeletionFinalization
  }
}

struct MutableRegistryInterruption: Error, Sendable {}

struct RegisteredMutableWorkflow: Equatable, Sendable {
  var workflowId: String
  var workflowDirectory: String
  var inputPath: String
  var overwritten: Bool
}
