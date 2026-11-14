#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import XCTest
@testable import RielaCLI

extension WorkflowTemporaryRegistrationTests {
  func testHelpDocumentsRegistrationFlags() async {
    let application = RielaCLIApplication()
    let workflowHelp = await application.run(["workflow", "--help"])
    XCTAssertEqual(workflowHelp.exitCode, .success)
    XCTAssertTrue(workflowHelp.stdout.contains("workflow register"))
    XCTAssertTrue(workflowHelp.stdout.contains("--exclude-temporary"))

    let help = await application.run(["workflow", "register", "--help"])
    XCTAssertEqual(help.exitCode, .success)
    for token in ["register", "--mutable", "--temporary", "--overwrite", "--working-dir", "--output"] {
      XCTAssertTrue(help.stdout.contains(token), "missing \(token)")
    }
  }

  func testRegisterRelativeInputUsingWorkingDirectory() async throws {
    let layout = try makeMatrixLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let bundle = try writeMatrixBundle(
      at: layout.inputs,
      workflowId: "relative-working-dir",
      description: "relative"
    )

    let result = await RielaCLIApplication().run([
      "workflow", "register", bundle.lastPathComponent,
      "--temporary", "--working-dir", layout.inputs.path, "--output", "json"
    ], environment: ["HOME": layout.home.path])

    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let registered = try decodeMatrix(MutableWorkflowRegistrationResult.self, result.stdout)
    XCTAssertEqual(registered.workflowId, "relative-working-dir")
    XCTAssertEqual(registered.inputPath, bundle.path)
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: layout.home.appendingPathComponent(
        ".riela/temporary-workflows/relative-working-dir/workflow.json"
      ).path
    ))
  }

  func testRegistryRootSwapAfterLockAcquisitionFailsClosed() async throws {
    let layout = try makeMatrixLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let workflowId = "registry-root-swap"
    let input = try writeMatrixBundle(
      at: layout.inputs,
      workflowId: workflowId,
      description: "must not publish into replacement root"
    )
    let root = matrixRegistryRoot(layout)
    let displaced = layout.base.appendingPathComponent("displaced-registry", isDirectory: true)
    let hooks = WorkflowMutableRegistryHooks(
      beforeLockAcquire: { _ in },
      afterLockAcquire: { lock in
        guard lock == .catalog else { return }
        try FileManager.default.moveItem(at: root, to: displaced)
        try initializeTemporaryRegistryFixtureLayout(home: layout.home)
      }
    )
    let application = RielaCLIApplication(
      workflowMutableRegistrationCommand: WorkflowMutableRegistrationCommand(
        registry: WorkflowMutableRegistry(hooks: hooks)
      )
    )

    let result = await application.run([
      "workflow", "register", input.path, "--temporary", "--output", "json"
    ], environment: ["HOME": layout.home.path])

    XCTAssertNotEqual(result.exitCode, .success)
    XCTAssertTrue((result.stderr + result.stdout).contains("root changed"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(workflowId).path))
    let listed = await RielaCLIApplication().run([
      "workflow", "list", "--scope", "user", "--output", "json"
    ], environment: ["HOME": layout.home.path])
    XCTAssertEqual(listed.exitCode, .success, listed.stderr + listed.stdout)
    XCTAssertEqual(try decodeMatrixCatalog(listed.stdout).workflows, [])
  }

  func testPublicationRejectsAncestorSymlinkSwapWithoutMovingExternalStaging() async throws {
    let layout = try makeMatrixLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let workflowId = "ancestor-swap"
    let input = try writeMatrixBundle(
      at: layout.inputs,
      workflowId: workflowId,
      description: "must remain staged"
    )
    let root = matrixRegistryRoot(layout)
    let stagingRoot = root.appendingPathComponent(".registry-state/staging", isDirectory: true)
    let externalStaging = layout.base.appendingPathComponent("external-staging", isDirectory: true)
    let registry = WorkflowMutableRegistry(hooks: WorkflowMutableRegistryHooks { phase in
      guard phase == .publishingReplacement else { return }
      try FileManager.default.moveItem(at: stagingRoot, to: externalStaging)
      try FileManager.default.createSymbolicLink(at: stagingRoot, withDestinationURL: externalStaging)
    })
    let application = RielaCLIApplication(
      workflowMutableRegistrationCommand: WorkflowMutableRegistrationCommand(registry: registry)
    )

    let result = await application.run([
      "workflow", "register", input.path, "--temporary", "--output", "json"
    ], environment: ["HOME": layout.home.path])

    XCTAssertNotEqual(result.exitCode, .success)
    XCTAssertTrue(result.stdout.contains("registry artifacts were preserved"), result.stdout)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(workflowId).path))
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: stagingRoot.path),
      externalStaging.path
    )
    let stagedTransactions = try FileManager.default.contentsOfDirectory(
      at: externalStaging,
      includingPropertiesForKeys: nil
    )
    XCTAssertEqual(stagedTransactions.count, 1)
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: stagedTransactions[0].appendingPathComponent("workflow.json").path
    ))
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: root.appendingPathComponent(".registry-state/transactions/\(workflowId).json").path
    ))
  }

  func testMissingRegistryStateFailsCatalogAndResolutionClosed() async throws {
    let layout = try makeMatrixLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let workflowId = "missing-state"
    let input = try writeMatrixBundle(
      at: layout.inputs,
      workflowId: workflowId,
      description: "published before state loss"
    )
    let environment = ["HOME": layout.home.path]
    let application = RielaCLIApplication()
    let registered = await application.run([
      "workflow", "register", input.path, "--temporary", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(registered.exitCode, .success, registered.stderr + registered.stdout)
    try FileManager.default.removeItem(
      at: matrixRegistryRoot(layout).appendingPathComponent(".registry-state", isDirectory: true)
    )

    let listed = await application.run([
      "workflow", "list", workflowId, "--scope", "user", "--output", "json"
    ], environment: environment)
    XCTAssertNotEqual(listed.exitCode, .success)
    XCTAssertTrue((listed.stderr + listed.stdout).contains("state layout is incomplete"))

    let validated = await application.run([
      "workflow", "validate", workflowId, "--scope", "user", "--output", "json"
    ], environment: environment)
    XCTAssertNotEqual(validated.exitCode, .success)
    XCTAssertTrue((validated.stderr + validated.stdout).contains("state layout is incomplete"))
  }

  func testTemporaryBundleIgnoresPackageManifestMetadataAcrossCommandsAndMutations() async throws {
    let layout = try makeMatrixLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let workflowId = "package-shaped-temporary"
    let input = try writeMatrixBundle(
      at: layout.inputs,
      workflowId: workflowId,
      description: "temporary authored workflow"
    )
    try matrixPackageManifestJSON(workflowId: workflowId).write(
      to: input.appendingPathComponent("riela-package.json"),
      atomically: true,
      encoding: .utf8
    )
    let environment = ["HOME": layout.home.path]
    let application = RielaCLIApplication()

    let registration = await application.run([
      "workflow", "register", input.path, "--temporary", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(registration.exitCode, .success, registration.stderr + registration.stdout)
    let registered = try decodeMatrix(MutableWorkflowRegistrationResult.self, registration.stdout)
    XCTAssertEqual(registered.sourceKind, .workflow)
    XCTAssertEqual(registered.provenance, .mutable)
    XCTAssertTrue(registered.mutable)

    let listed = await application.run([
      "workflow", "list", workflowId, "--scope", "user", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(listed.exitCode, .success, listed.stderr + listed.stdout)
    let catalogEntry = try XCTUnwrap(decodeMatrixCatalog(listed.stdout).workflows.first)
    assertTemporaryAuthoredProvenance(catalogEntry)

    let validated = await application.run([
      "workflow", "validate", workflowId, "--scope", "user", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(validated.exitCode, .success, validated.stderr + validated.stdout)
    let validation = try decodeMatrix(WorkflowValidationCommandResult.self, validated.stdout)
    XCTAssertEqual(validation.sourceKind, .workflow)
    XCTAssertEqual(validation.provenance, .mutable)
    XCTAssertTrue(validation.mutable)
    XCTAssertNil(validation.packageName)
    XCTAssertNil(validation.packageDirectory)

    let inspected = await application.run([
      "workflow", "inspect", workflowId, "--scope", "user", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(inspected.exitCode, .success, inspected.stderr + inspected.stdout)
    let inspection = try decodeMatrix(WorkflowInspectionSummary.self, inspected.stdout)
    XCTAssertEqual(inspection.sourceKind, .workflow)
    XCTAssertEqual(inspection.provenance, .mutable)
    XCTAssertTrue(inspection.mutable)
    XCTAssertNil(inspection.packageName)
    XCTAssertNil(inspection.packageDirectory)

    let status = await application.run([
      "workflow", "status", workflowId, "--scope", "user", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(status.exitCode, .success, status.stderr + status.stdout)
    let statusEntry = try XCTUnwrap(decodeMatrixCatalog(status.stdout).workflows.first)
    assertTemporaryAuthoredProvenance(statusEntry)

    let snapshotId = try CLIRuntimeEnvironment.$overrides.withValue(environment) {
      let bundle = try FileSystemWorkflowBundleResolver().resolve(WorkflowResolutionOptions(
        workflowName: workflowId,
        scope: .user,
        workingDirectory: layout.base.path
      ))
      XCTAssertEqual(bundle.provenance, .mutable)
      XCTAssertNil(bundle.packageManifest)
      XCTAssertNil(bundle.packageDirectory)
      let target = try WorkflowHistoryIdentityResolver.identity(for: bundle)
      XCTAssertEqual(target.sourceKind, .authoredWorkflow)
      XCTAssertTrue(target.sourceMutable)
      XCTAssertNil(target.packageDirectory)
      let historyRoot = try WorkflowHistoryIdentityResolver.historyRoot(
        for: target,
        workingDirectory: layout.base
      )
      return try WorkflowHistoryStore(root: historyRoot).createSnapshot(
        inventory: WorkflowHistoryIdentityResolver.inventory(for: target)
      ).snapshotId
    }

    let restore = await application.run([
      "workflow", "restore", workflowId, snapshotId,
      "--scope", "user", "--working-dir", layout.base.path, "--output", "json"
    ], environment: environment)
    XCTAssertEqual(restore.exitCode, .success, restore.stderr + restore.stdout)
    let restoreResult = try decodeMatrix(WorkflowRestoreCommandResult.self, restore.stdout)
    XCTAssertTrue(restoreResult.dryRun)
    XCTAssertEqual(restoreResult.workflow.sourceKind, .authoredWorkflow)
    XCTAssertTrue(restoreResult.workflow.sourceMutable)

    let selfImprove = await application.run([
      "workflow", "self-improve", workflowId, "--scope", "user",
      "--working-dir", layout.base.path, "--dry-run", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(selfImprove.exitCode, .success, selfImprove.stderr + selfImprove.stdout)
    XCTAssertTrue(try decodeMatrix(WorkflowSelfImproveCommandResult.self, selfImprove.stdout).dryRun)
  }

  func testRegistrationRejectsSpecialFilesMissingWorkflowJSONAndMissingAssets() async throws {
    let layout = try makeMatrixLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let environment = ["HOME": layout.home.path]
    let application = RielaCLIApplication()

    let missingWorkflow = layout.inputs.appendingPathComponent("missing-workflow", isDirectory: true)
    try FileManager.default.createDirectory(at: missingWorkflow, withIntermediateDirectories: true)

    let fifo = layout.inputs.appendingPathComponent("special-input.json")
    XCTAssertEqual(mkfifo(fifo.path, mode_t(S_IRUSR | S_IWUSR)), 0)

    let specialBundle = try writeMatrixBundle(
      at: layout.inputs,
      workflowId: "special-descendant",
      description: "special descendant"
    )
    let nestedFIFO = specialBundle.appendingPathComponent("special.fifo")
    XCTAssertEqual(mkfifo(nestedFIFO.path, mode_t(S_IRUSR | S_IWUSR)), 0)

    let missingAsset = layout.inputs.appendingPathComponent("missing-asset", isDirectory: true)
    try FileManager.default.createDirectory(at: missingAsset, withIntermediateDirectories: true)
    try matrixWorkflowJSON(
      workflowId: "missing-asset",
      description: "missing asset",
      nodeFile: "nodes/missing.json"
    ).write(to: missingAsset.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)

    for input in [missingWorkflow, fifo, specialBundle, missingAsset] {
      let result = await application.run([
        "workflow", "register", input.path, "--temporary", "--output", "json"
      ], environment: environment)
      XCTAssertNotEqual(result.exitCode, .success, "\(input.path): \(result.stdout) \(result.stderr)")
    }

    let listed = await application.run([
      "workflow", "list", "--scope", "user", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(listed.exitCode, .success, listed.stderr + listed.stdout)
    XCTAssertEqual(try decodeMatrixCatalog(listed.stdout).workflows, [])
  }

  func testCatalogScanWaitsAcrossRecordCreationAndRemovalWithoutOmission() async throws {
    for phase in [WorkflowMutableRegistryPhase.prepared, .replacementPublished] {
      let layout = try makeMatrixLayout()
      defer { try? FileManager.default.removeItem(at: layout.base) }
      let original = try writeMatrixBundle(
        at: layout.inputs.appendingPathComponent("original", isDirectory: true),
        workflowId: "catalog-race",
        description: "old"
      )
      let replacement = try writeMatrixBundle(
        at: layout.inputs.appendingPathComponent("replacement", isDirectory: true),
        workflowId: "catalog-race",
        description: "new"
      )
      let environment = ["HOME": layout.home.path]
      let initial = await RielaCLIApplication().run([
        "workflow", "register", original.path, "--temporary", "--output", "json"
      ], environment: environment)
      XCTAssertEqual(initial.exitCode, .success, initial.stderr + initial.stdout)

      let phaseReached = DispatchSemaphore(value: 0)
      let releaseRegistration = DispatchSemaphore(value: 0)
      let registry = WorkflowMutableRegistry(hooks: WorkflowMutableRegistryHooks { reached in
        if reached == phase {
          phaseReached.signal()
          releaseRegistration.wait()
        }
      })
      let registeringApp = RielaCLIApplication(
        workflowMutableRegistrationCommand: WorkflowMutableRegistrationCommand(registry: registry)
      )
      let overwriteTask = Task {
        await registeringApp.run([
          "workflow", "register", replacement.path, "--temporary", "--overwrite", "--output", "json"
        ], environment: environment)
      }
      XCTAssertEqual(phaseReached.wait(timeout: .now() + 2), .success, phase.rawValue)
      let activeRecord = matrixRegistryRoot(layout)
        .appendingPathComponent(".registry-state/transactions/catalog-race.json")
      XCTAssertTrue(FileManager.default.fileExists(atPath: activeRecord.path), phase.rawValue)

      let lockProbe = TemporaryRegistryLockProbe(lock: .catalog)
      let listingApp = RielaCLIApplication(
        workflowCatalogCommand: WorkflowCatalogCommand(
          mutableRegistry: WorkflowMutableRegistry(hooks: lockProbe.hooks)
        )
      )
      let listTask = Task {
        await listingApp.run([
          "workflow", "list", "catalog-race", "--scope", "user", "--output", "json"
        ], environment: environment)
      }
      lockProbe.assertBlocked()
      releaseRegistration.signal()

      let overwrite = await overwriteTask.value
      let listed = await listTask.value
      XCTAssertEqual(overwrite.exitCode, .success, overwrite.stderr + overwrite.stdout)
      XCTAssertEqual(listed.exitCode, .success, listed.stderr + listed.stdout)
      let entries = try decodeMatrixCatalog(listed.stdout).workflows.filter {
        $0.workflowName == "catalog-race"
      }
      XCTAssertEqual(entries.count, 1, phase.rawValue)
      XCTAssertTrue(try XCTUnwrap(entries.first).valid, phase.rawValue)
      XCTAssertFalse(FileManager.default.fileExists(atPath: activeRecord.path), phase.rawValue)
    }
  }

  func testWorkflowReaderBlocksOverwriteUntilBundleLoadBoundaryReleases() async throws {
    let layout = try makeMatrixLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let original = try writeMatrixBundle(
      at: layout.inputs.appendingPathComponent("reader-original", isDirectory: true),
      workflowId: "reader-race",
      description: "old"
    )
    let replacement = try writeMatrixBundle(
      at: layout.inputs.appendingPathComponent("reader-replacement", isDirectory: true),
      workflowId: "reader-race",
      description: "new"
    )
    let environment = ["HOME": layout.home.path]
    let initial = await RielaCLIApplication().run([
      "workflow", "register", original.path, "--temporary", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(initial.exitCode, .success, initial.stderr + initial.stdout)

    let readerEntered = DispatchSemaphore(value: 0)
    let releaseReader = DispatchSemaphore(value: 0)
    let readerTask = Task {
      try CLIRuntimeEnvironment.$overrides.withValue(environment) {
        try WorkflowMutableRegistry().withWorkflowRead(workflowId: "reader-race") { _ in
          readerEntered.signal()
          releaseReader.wait()
        }
      }
    }
    XCTAssertEqual(readerEntered.wait(timeout: .now() + 2), .success)
    let lockProbe = TemporaryRegistryLockProbe(lock: .workflow("reader-race"))
    let registeringApp = RielaCLIApplication(
      workflowMutableRegistrationCommand: WorkflowMutableRegistrationCommand(
        registry: WorkflowMutableRegistry(hooks: lockProbe.hooks)
      )
    )
    let overwriteTask = Task {
      await registeringApp.run([
        "workflow", "register", replacement.path, "--temporary", "--overwrite", "--output", "json"
      ], environment: environment)
    }
    lockProbe.assertBlocked()
    releaseReader.signal()
    try await readerTask.value
    let overwrite = await overwriteTask.value
    XCTAssertEqual(overwrite.exitCode, .success, overwrite.stderr + overwrite.stdout)
  }

  func testRecoveryTreatsRecordDisappearanceAfterEnumerationAsBenign() throws {
    let layout = try makeMatrixLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let environment = ["HOME": layout.home.path]
    try initializeTemporaryRegistryFixtureLayout(home: layout.home)
    let transactionId = "22222222-2222-2222-2222-222222222222"
    let record = matrixRegistryRoot(layout)
      .appendingPathComponent(".registry-state/transactions/vanishing.json")
    let fixture = MatrixRegistryRecord(
      workflowId: "vanishing",
      transactionId: transactionId,
      phase: .prepared,
      hadOriginal: false,
      destinationPath: "vanishing",
      stagingPath: ".registry-state/staging/\(transactionId)",
      backupPath: nil
    )
    try JSONEncoder().encode(fixture).write(to: record)

    let hooks = WorkflowMutableRegistryHooks(
      afterPhase: { _ in },
      beforeRecordRead: { workflowId in
        if workflowId == "vanishing", FileManager.default.fileExists(atPath: record.path) {
          try FileManager.default.removeItem(at: record)
        }
      }
    )
    let candidates = try CLIRuntimeEnvironment.$overrides.withValue(environment) {
      try WorkflowMutableRegistry(hooks: hooks).snapshotCandidates()
    }
    XCTAssertEqual(candidates, [])
    XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
  }

  func testRegistryRootSwapAfterLockIdentityCheckPreservesRecoveryArtifacts() async throws {
    let layout = try makeMatrixLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let workflowId = "post-check-root-swap"
    let input = try writeMatrixBundle(
      at: layout.inputs,
      workflowId: workflowId,
      description: "must remain recoverable"
    )
    let environment = ["HOME": layout.home.path]
    let interruptedRegistry = WorkflowMutableRegistry(
      hooks: WorkflowMutableRegistryHooks { phase in
        if phase == .prepared { throw MutableRegistryInterruption() }
      }
    )
    let interruptedApp = RielaCLIApplication(
      workflowMutableRegistrationCommand: WorkflowMutableRegistrationCommand(
        registry: interruptedRegistry
      )
    )
    let interrupted = await interruptedApp.run([
      "workflow", "register", input.path, "--temporary", "--output", "json"
    ], environment: environment)
    XCTAssertNotEqual(interrupted.exitCode, .success)

    let root = matrixRegistryRoot(layout)
    let displaced = layout.base.appendingPathComponent("post-check-displaced", isDirectory: true)
    let activeRecord = root.appendingPathComponent(
      ".registry-state/transactions/\(workflowId).json"
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: activeRecord.path))
    let stagedBefore = try FileManager.default.contentsOfDirectory(
      at: root.appendingPathComponent(".registry-state/staging", isDirectory: true),
      includingPropertiesForKeys: nil
    )
    XCTAssertEqual(stagedBefore.count, 1)

    let recoveringRegistry = WorkflowMutableRegistry(hooks: WorkflowMutableRegistryHooks(
      afterPhase: { _ in },
      beforeRecordRead: { id in
        guard id == workflowId else { return }
        try FileManager.default.moveItem(at: root, to: displaced)
        try initializeTemporaryRegistryFixtureLayout(home: layout.home)
      }
    ))
    let listed = await RielaCLIApplication(
      workflowCatalogCommand: WorkflowCatalogCommand(mutableRegistry: recoveringRegistry)
    ).run([
      "workflow", "list", workflowId, "--scope", "user", "--output", "json"
    ], environment: environment)

    XCTAssertNotEqual(listed.exitCode, .success)
    XCTAssertTrue((listed.stderr + listed.stdout).contains("root changed"))
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: displaced.appendingPathComponent(
        ".registry-state/transactions/\(workflowId).json"
      ).path
    ))
    let displacedStaging = try FileManager.default.contentsOfDirectory(
      at: displaced.appendingPathComponent(".registry-state/staging", isDirectory: true),
      includingPropertiesForKeys: nil
    )
    XCTAssertEqual(displacedStaging.count, 1)
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: displacedStaging[0].appendingPathComponent("workflow.json").path
    ))
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: root.appendingPathComponent(workflowId, isDirectory: true).path
    ))
  }

  func testRegistryRootSwapAfterDetachedBundleCaptureCannotRedirectResolution() async throws {
    let layout = try makeMatrixLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let workflowId = "detached-resolution-swap"
    let original = try writeMatrixBundle(
      at: layout.inputs.appendingPathComponent("original", isDirectory: true),
      workflowId: workflowId,
      description: "descriptor captured original"
    )
    let replacement = try writeMatrixBundle(
      at: layout.inputs.appendingPathComponent("replacement", isDirectory: true),
      workflowId: workflowId,
      description: "replacement must remain untouched"
    )
    let environment = ["HOME": layout.home.path]
    let registration = await RielaCLIApplication().run([
      "workflow", "register", original.path, "--temporary", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(registration.exitCode, .success, registration.stderr + registration.stdout)

    let root = matrixRegistryRoot(layout)
    let displaced = layout.base.appendingPathComponent("detached-resolution-displaced", isDirectory: true)
    let swap = MatrixRootSwapOnce {
      try FileManager.default.moveItem(at: root, to: displaced)
      try initializeTemporaryRegistryFixtureLayout(home: layout.home)
      try FileManager.default.copyItem(
        at: replacement,
        to: root.appendingPathComponent(workflowId, isDirectory: true)
      )
    }
    let registry = WorkflowMutableRegistry(hooks: WorkflowMutableRegistryHooks(
      beforeDetachedBundleLoad: { try swap.run() }
    ))
    let resolver = FileSystemWorkflowBundleResolver(
      mutableRegistryHistoryRecoveryHook: {},
      mutableRegistry: registry
    )
    XCTAssertThrowsError(try CLIRuntimeEnvironment.$overrides.withValue(environment) {
      try resolver.resolve(WorkflowResolutionOptions(
        workflowName: workflowId,
        scope: .user,
        workingDirectory: layout.base.path
      ))
    }) { error in
      XCTAssertTrue("\(error)".contains("root changed"), "\(error)")
    }
    let replacementWorkflow = root.appendingPathComponent("\(workflowId)/workflow.json")
    XCTAssertTrue(try String(contentsOf: replacementWorkflow, encoding: .utf8).contains(
      "replacement must remain untouched"
    ))
  }

  func testRegistryRootSwapAfterMutationWorkspaceCaptureCannotRedirectRestore() async throws {
    let layout = try makeMatrixLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let workflowId = "detached-restore-swap"
    let original = try writeMatrixBundle(
      at: layout.inputs.appendingPathComponent("original", isDirectory: true),
      workflowId: workflowId,
      description: "restore source"
    )
    let replacement = try writeMatrixBundle(
      at: layout.inputs.appendingPathComponent("replacement", isDirectory: true),
      workflowId: workflowId,
      description: "replacement must remain untouched"
    )
    let environment = ["HOME": layout.home.path]
    let registration = await RielaCLIApplication().run([
      "workflow", "register", original.path, "--temporary", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(registration.exitCode, .success, registration.stderr + registration.stdout)
    let prepared = try CLIRuntimeEnvironment.$overrides.withValue(environment) {
      let bundle = try FileSystemWorkflowBundleResolver().resolve(WorkflowResolutionOptions(
        workflowName: workflowId,
        scope: .user,
        workingDirectory: layout.base.path
      ))
      let target = try WorkflowHistoryIdentityResolver.identity(for: bundle)
      let historyRoot = try WorkflowHistoryIdentityResolver.historyRoot(
        for: target,
        workingDirectory: layout.base
      )
      let snapshot = try WorkflowHistoryStore(root: historyRoot).createSnapshot(
        inventory: WorkflowHistoryIdentityResolver.inventory(for: target)
      )
      return (bundle, snapshot.snapshotId)
    }

    let root = matrixRegistryRoot(layout)
    let displaced = layout.base.appendingPathComponent("detached-restore-displaced", isDirectory: true)
    let swap = MatrixRootSwapOnce {
      try FileManager.default.moveItem(at: root, to: displaced)
      try initializeTemporaryRegistryFixtureLayout(home: layout.home)
      try FileManager.default.copyItem(
        at: replacement,
        to: root.appendingPathComponent(workflowId, isDirectory: true)
      )
    }
    let registry = WorkflowMutableRegistry(hooks: WorkflowMutableRegistryHooks(
      afterMutationWorkspaceExport: { try swap.run() }
    ))
    let application = RielaCLIApplication(workflowVersionCommand: WorkflowVersionCommand(
      resolver: MatrixFixedWorkflowBundleResolver(bundle: prepared.0),
      mutableRegistry: registry
    ))
    let restored = await application.run([
      "workflow", "restore", workflowId, prepared.1,
      "--scope", "user", "--working-dir", layout.base.path,
      "--yes", "--output", "json"
    ], environment: environment)
    XCTAssertNotEqual(restored.exitCode, .success)
    XCTAssertTrue((restored.stderr + restored.stdout).contains("root changed"))
    let replacementWorkflow = root.appendingPathComponent("\(workflowId)/workflow.json")
    XCTAssertTrue(try String(contentsOf: replacementWorkflow, encoding: .utf8).contains(
      "replacement must remain untouched"
    ))
  }

  func testRegistryRootSwapAfterMutationWorkspaceCaptureCannotRedirectSelfImprove() async throws {
    let layout = try makeMatrixLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let workflowId = "detached-self-improve-swap"
    let original = try writeMatrixBundle(
      at: layout.inputs.appendingPathComponent("original", isDirectory: true),
      workflowId: workflowId,
      description: "self improve source"
    )
    let replacement = try writeMatrixBundle(
      at: layout.inputs.appendingPathComponent("replacement", isDirectory: true),
      workflowId: workflowId,
      description: "replacement must remain untouched"
    )
    let environment = ["HOME": layout.home.path]
    let registration = await RielaCLIApplication().run([
      "workflow", "register", original.path, "--temporary", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(registration.exitCode, .success, registration.stderr + registration.stdout)
    let bundle = try CLIRuntimeEnvironment.$overrides.withValue(environment) {
      try FileSystemWorkflowBundleResolver().resolve(WorkflowResolutionOptions(
        workflowName: workflowId,
        scope: .user,
        workingDirectory: layout.base.path
      ))
    }

    let root = matrixRegistryRoot(layout)
    let displaced = layout.base.appendingPathComponent("detached-self-improve-displaced", isDirectory: true)
    let swap = MatrixRootSwapOnce {
      try FileManager.default.moveItem(at: root, to: displaced)
      try initializeTemporaryRegistryFixtureLayout(home: layout.home)
      try FileManager.default.copyItem(
        at: replacement,
        to: root.appendingPathComponent(workflowId, isDirectory: true)
      )
    }
    let versioning = WorkflowSelfImproveVersioning(mutableRegistry: WorkflowMutableRegistry(
      hooks: WorkflowMutableRegistryHooks(afterMutationWorkspaceExport: { try swap.run() })
    ))
    XCTAssertThrowsError(try CLIRuntimeEnvironment.$overrides.withValue(environment) {
      try versioning.execute(
        workflowName: workflowId,
        bundle: bundle,
        workingDirectory: layout.base,
        dryRun: true,
        approved: false,
        changeSetId: nil,
        expectedDigest: nil,
        sourceSessionId: "detached-root-swap"
      )
    }) { error in
      XCTAssertTrue("\(error)".contains("root changed"), "\(error)")
    }
    let replacementWorkflow = root.appendingPathComponent("\(workflowId)/workflow.json")
    XCTAssertTrue(try String(contentsOf: replacementWorkflow, encoding: .utf8).contains(
      "replacement must remain untouched"
    ))
  }

  func testReadOnlyHomeWithoutRegistryRemainsUnmodifiedForCatalogAndResolution() async throws {
    let layout = try makeMatrixLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let riela = layout.home.appendingPathComponent(".riela", isDirectory: true)
    try FileManager.default.createDirectory(at: riela, withIntermediateDirectories: true)
    XCTAssertEqual(chmod(riela.path, mode_t(S_IRUSR | S_IXUSR)), 0)
    defer { _ = chmod(riela.path, mode_t(S_IRUSR | S_IWUSR | S_IXUSR)) }

    let environment = ["HOME": layout.home.path]
    let listed = await RielaCLIApplication().run([
      "workflow", "list", "--scope", "user", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(listed.exitCode, .success, listed.stderr + listed.stdout)
    XCTAssertEqual(try decodeMatrixCatalog(listed.stdout).workflows, [])

    try CLIRuntimeEnvironment.$overrides.withValue(environment) {
      XCTAssertThrowsError(try FileSystemWorkflowBundleResolver().resolve(WorkflowResolutionOptions(
        workflowName: "missing-temporary",
        scope: .user,
        workingDirectory: layout.base.path
      )))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: matrixRegistryRoot(layout).path))
  }

  func testOrdinaryPublicationRecoveryFailurePreservesRecordAndStaging() async throws {
    let layout = try makeMatrixLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let workflowId = "recovery-preservation"
    let original = try writeMatrixBundle(
      at: layout.inputs.appendingPathComponent("original", isDirectory: true),
      workflowId: workflowId,
      description: "old visible workflow"
    )
    let replacement = try writeMatrixBundle(
      at: layout.inputs.appendingPathComponent("replacement", isDirectory: true),
      workflowId: workflowId,
      description: "validated replacement"
    )
    let environment = ["HOME": layout.home.path]
    let initial = await RielaCLIApplication().run([
      "workflow", "register", original.path, "--temporary", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(initial.exitCode, .success, initial.stderr + initial.stdout)

    let root = matrixRegistryRoot(layout)
    let activeRecord = root.appendingPathComponent(
      ".registry-state/transactions/\(workflowId).json"
    )
    let registry = WorkflowMutableRegistry(hooks: WorkflowMutableRegistryHooks { phase in
      guard phase == .prepared else { return }
      try "{".write(to: activeRecord, atomically: true, encoding: .utf8)
      throw CLIUsageError("injected ordinary publication failure")
    })
    let application = RielaCLIApplication(
      workflowMutableRegistrationCommand: WorkflowMutableRegistrationCommand(registry: registry)
    )
    let failed = await application.run([
      "workflow", "register", replacement.path, "--temporary", "--overwrite", "--output", "json"
    ], environment: environment)
    XCTAssertNotEqual(failed.exitCode, .success)
    XCTAssertTrue(failed.stdout.contains("recovery failed and registry artifacts were preserved"), failed.stdout)
    XCTAssertTrue(FileManager.default.fileExists(atPath: activeRecord.path))

    let stagingRoot = root.appendingPathComponent(".registry-state/staging", isDirectory: true)
    let staged = try FileManager.default.contentsOfDirectory(
      at: stagingRoot,
      includingPropertiesForKeys: nil
    )
    XCTAssertEqual(staged.count, 1)
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: staged[0].appendingPathComponent("workflow.json").path
    ))
    let published = root.appendingPathComponent("\(workflowId)/workflow.json")
    XCTAssertTrue(try String(contentsOf: published, encoding: .utf8).contains("old visible workflow"))
  }
}

private struct MatrixRegistrationLayout {
  var base: URL
  var home: URL
  var inputs: URL
}

private struct MatrixRegistryRecord: Encodable {
  var schemaVersion = 1
  var workflowId: String
  var transactionId: String
  var phase: WorkflowMutableRegistryPhase
  var hadOriginal: Bool
  var replacementDigest = String(repeating: "0", count: 64)
  var destinationPath: String
  var stagingPath: String
  var backupPath: String?
}

private final class MatrixRootSwapOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var completed = false
  private let action: () throws -> Void

  init(action: @escaping () throws -> Void) {
    self.action = action
  }

  func run() throws {
    lock.lock()
    defer { lock.unlock() }
    guard !completed else { return }
    try action()
    completed = true
  }
}

private struct MatrixFixedWorkflowBundleResolver: WorkflowBundleResolving {
  var bundle: ResolvedWorkflowBundle

  func resolve(_ options: WorkflowResolutionOptions) throws -> ResolvedWorkflowBundle {
    bundle
  }
}

private func makeMatrixLayout() throws -> MatrixRegistrationLayout {
  let base = FileManager.default.temporaryDirectory
    .appendingPathComponent("riela-temporary-matrix-\(UUID().uuidString)", isDirectory: true)
  let layout = MatrixRegistrationLayout(
    base: base,
    home: base.appendingPathComponent("home", isDirectory: true),
    inputs: base.appendingPathComponent("inputs", isDirectory: true)
  )
  try FileManager.default.createDirectory(at: layout.home, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: layout.inputs, withIntermediateDirectories: true)
  return layout
}

private func matrixRegistryRoot(_ layout: MatrixRegistrationLayout) -> URL {
  layout.home.appendingPathComponent(".riela/temporary-workflows", isDirectory: true)
}

@discardableResult
private func writeMatrixBundle(
  at parent: URL,
  workflowId: String,
  description: String
) throws -> URL {
  let bundle = parent.appendingPathComponent(workflowId, isDirectory: true)
  try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
  try matrixWorkflowJSON(workflowId: workflowId, description: description)
    .write(to: bundle.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
  return bundle
}

private func matrixWorkflowJSON(
  workflowId: String,
  description: String,
  nodeFile: String? = nil
) -> String {
  let node = nodeFile.map { #"{"id":"worker","nodeFile":"\#($0)"}"# }
    ?? #"{"id":"worker","addon":{"name":"example-addon"}}"#
  return """
  {
    "workflowId": "\(workflowId)",
    "description": "\(description)",
    "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
    "entryStepId": "work",
    "nodes": [\(node)],
    "steps": [{ "id": "work", "nodeId": "worker", "role": "worker" }]
  }
  """
}

private func matrixPackageManifestJSON(workflowId: String) -> String {
  """
  {
    "name": "\(workflowId)",
    "version": "1.0.0",
    "kind": "workflow",
    "description": "package metadata retained as an ordinary bundle file",
    "tags": [],
    "registry": "local",
    "checksum": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "checksumAlgorithm": "md5",
    "workflowDirectory": "."
  }
  """
}

private func assertTemporaryAuthoredProvenance(
  _ entry: WorkflowCatalogEntry,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  XCTAssertEqual(entry.sourceKind, .workflow, file: file, line: line)
  XCTAssertEqual(entry.provenance, .mutable, file: file, line: line)
  XCTAssertTrue(entry.mutable, file: file, line: line)
  XCTAssertNil(entry.packageName, file: file, line: line)
  XCTAssertNil(entry.packageDirectory, file: file, line: line)
}

private func decodeMatrix<Value: Decodable>(_ type: Value.Type, _ output: String) throws -> Value {
  try JSONDecoder().decode(type, from: Data(output.utf8))
}

private func decodeMatrixCatalog(_ output: String) throws -> WorkflowCatalogResult {
  try decodeMatrix(WorkflowCatalogResult.self, output)
}
