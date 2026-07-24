import Foundation
import RielaCore

extension WorkflowMutableRegistry {
  func register(
    input: URL,
    overwrite: Bool,
    activationState: WorkflowActivationState? = nil
  ) throws -> RegisteredMutableWorkflow {
    let pinned = try pinnedRoot(create: true)
    try ensureLayout(pinned: pinned)
    let transactionId = UUID().uuidString.lowercased()
    let staging = stagingRoot.appendingPathComponent(transactionId, isDirectory: true)
    var preserveStagingForRecovery = false
    do {
      try copyInput(input.standardizedFileURL, to: staging, pinned: pinned)
      try pinned.requireConfiguredPathIdentity()
      let workflowId = try candidateWorkflowId(at: staging, pinned: pinned)
      let destination = root.appendingPathComponent(workflowId, isDirectory: true)
      let backup = backupsRoot
        .appendingPathComponent(workflowId, isDirectory: true)
        .appendingPathComponent(transactionId, isDirectory: true)
      let overwritten = try withCatalogLock(pinned: pinned, createIfMissing: false) {
        try withWorkflowLock(pinned: pinned, workflowId: workflowId, createIfMissing: true) {
          try recoverLocked(pinned: pinned, workflowId: workflowId)
          let candidate = try loadCandidateBundle(
            at: staging,
            expectedWorkflowId: workflowId,
            pinned: pinned
          )
          let bundle = candidate.bundle
          let diagnostics = bundle.diagnostics
            + DefaultWorkflowValidator().validate(bundle.workflow, nodePayloads: bundle.nodePayloads)
          if diagnostics.contains(where: { $0.severity == .error }) {
            throw WorkflowResolutionError.invalidWorkflow(diagnostics)
          }
          let replacementDigest = candidate.registryDigest
          let hadOriginal = try registryItemExists(destination, pinned: pinned)
          if hadOriginal && !overwrite {
            throw CLIUsageError(
              "mutable workflow '\(workflowId)' already exists at \(destination.path); use --overwrite to replace it"
            )
          }
          var record = WorkflowMutableRegistryTransaction(
            schemaVersion: 1,
            workflowId: workflowId,
            transactionId: transactionId,
            phase: .prepared,
            hadOriginal: hadOriginal,
            replacementDigest: replacementDigest,
            destinationPath: workflowId,
            stagingPath: relativePath(staging),
            backupPath: hadOriginal ? relativePath(backup) : nil,
            operation: .replace,
            requestedActivationState: activationState
              ?? (hadOriginal || !WorkflowActivationStore.coordinatorLockHeld ? nil : .active)
          )
          var replacementPublished = false
          do {
            try publish(record, pinned: pinned)
            try hooks.afterPhase(.prepared)
            if hadOriginal {
              try createRealDirectory(backup.deletingLastPathComponent(), pinned: pinned)
              record.phase = .movingOriginal
              try publish(record, pinned: pinned)
              try hooks.afterPhase(.movingOriginal)
              try renameDirectory(destination, to: backup, pinned: pinned)
              record.phase = .originalBackedUp
              try publish(record, pinned: pinned)
              try hooks.afterPhase(.originalBackedUp)
            }
            record.phase = .publishingReplacement
            try publish(record, pinned: pinned)
            try hooks.afterPhase(.publishingReplacement)
            try renameDirectory(staging, to: destination, pinned: pinned)
            guard try bundleDigest(at: destination, pinned: pinned) == replacementDigest else {
              throw CLIUsageError("mutable workflow replacement digest verification failed")
            }
            replacementPublished = true
            record.phase = .replacementPublished
            try publish(record, pinned: pinned)
            try hooks.afterPhase(.replacementPublished)
            try applyRequestedActivation(record)
            try finish(record, pinned: pinned)
            try pinned.requireConfiguredPathIdentity()
            return hadOriginal
          } catch {
            let publicationError = error
            if publicationError is MutableRegistryInterruption {
              throw publicationError
            }
            do {
              try recoverLocked(pinned: pinned, workflowId: workflowId)
            } catch {
              preserveStagingForRecovery = true
              throw WorkflowMutableRegistryRecoveryFailure(
                publicationError: publicationError,
                recoveryError: error
              )
            }
            if replacementPublished {
              try pinned.requireConfiguredPathIdentity()
              return hadOriginal
            }
            throw publicationError
          }
        }
      }
      return RegisteredMutableWorkflow(
        workflowId: workflowId,
        workflowDirectory: destination.path,
        inputPath: input.path,
        overwritten: overwritten
      )
    } catch {
      if error is MutableRegistryInterruption {
        throw error
      }
      if !preserveStagingForRecovery, (try? registryItemExists(staging, pinned: pinned)) == true {
        try? removeArtifact(staging, pinned: pinned)
      }
      throw error
    }
  }
}
