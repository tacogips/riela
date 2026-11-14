import Foundation
import RielaCore

extension WorkflowMutableRegistry {
  func update(workflowId: String, input: URL) throws -> RegisteredMutableWorkflow {
    let expectedDigest = try withWorkflowPinnedAccess(workflowId: workflowId) { pinned in
      guard let pinned else {
        throw WorkflowRegistryError(
          code: .workflowNotFound,
          message: "mutable workflow '\(workflowId)' was not found",
          workflowId: workflowId
        )
      }
      let destination = root.appendingPathComponent(workflowId, isDirectory: true)
      guard try registryItemExists(destination, pinned: pinned) else {
        throw WorkflowRegistryError(
          code: .workflowNotFound,
          message: "mutable workflow '\(workflowId)' was not found",
          workflowId: workflowId
        )
      }
      return try bundleDigest(at: destination, pinned: pinned)
    }
    try withWorkflowMutationAccess(workflowId: workflowId, expectedDigest: expectedDigest) { _, publish in
      try publish(input.standardizedFileURL)
    }
    return RegisteredMutableWorkflow(
      workflowId: workflowId,
      workflowDirectory: root.appendingPathComponent(workflowId, isDirectory: true).path,
      inputPath: input.path,
      overwritten: true
    )
  }

  func delete(workflowId: String) throws -> URL {
    try validateWorkflowId(workflowId)
    guard let pinned = try existingPinnedRoot() else {
      throw WorkflowRegistryError(
        code: .workflowNotFound,
        message: "mutable workflow '\(workflowId)' was not found",
        workflowId: workflowId
      )
    }
    try validateExistingLayout(pinned: pinned)
    return try withCatalogLock(pinned: pinned, createIfMissing: false) {
      try withWorkflowLock(pinned: pinned, workflowId: workflowId, createIfMissing: true) {
        try recoverLocked(pinned: pinned, workflowId: workflowId)
        let destination = root.appendingPathComponent(workflowId, isDirectory: true)
        guard try realDirectoryExists(
          destination,
          under: root,
          label: "mutable workflow destination",
          pinned: pinned
        ) else {
          throw WorkflowRegistryError(
            code: .workflowNotFound,
            message: "mutable workflow '\(workflowId)' was not found",
            workflowId: workflowId
          )
        }
        let transactionId = UUID().uuidString.lowercased()
        let staging = stagingRoot.appendingPathComponent(transactionId, isDirectory: true)
        let backup = backupsRoot
          .appendingPathComponent(workflowId, isDirectory: true)
          .appendingPathComponent(transactionId, isDirectory: true)
        try createRealDirectory(staging, pinned: pinned)
        try createRealDirectory(backup.deletingLastPathComponent(), pinned: pinned)
        var record = WorkflowMutableRegistryTransaction(
          schemaVersion: 1,
          workflowId: workflowId,
          transactionId: transactionId,
          phase: .prepared,
          hadOriginal: true,
          replacementDigest: try bundleDigest(at: destination, pinned: pinned),
          destinationPath: workflowId,
          stagingPath: relativePath(staging),
          backupPath: relativePath(backup),
          operation: .delete,
          requestedActivationState: nil
        )
        do {
          try publish(record, pinned: pinned)
          try hooks.afterPhase(.prepared)
          record.phase = .movingOriginal
          try publish(record, pinned: pinned)
          try hooks.afterPhase(.movingOriginal)
          try renameDirectory(destination, to: backup, pinned: pinned)
          record.phase = .originalBackedUp
          try publish(record, pinned: pinned)
          try hooks.afterPhase(.originalBackedUp)
          record.phase = .replacementPublished
          try publish(record, pinned: pinned)
          try hooks.afterPhase(.replacementPublished)
          try removeActivationForCommittedDeletion(workflowId: workflowId)
          try finish(record, pinned: pinned)
        } catch {
          let deletionError = error
          do {
            try recoverLocked(pinned: pinned, workflowId: workflowId)
          } catch {
            throw WorkflowMutableRegistryRecoveryFailure(
              publicationError: deletionError,
              recoveryError: error
            )
          }
          throw deletionError
        }
        return destination
      }
    }
  }
}
