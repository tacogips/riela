import Foundation
import XCTest
@testable import RielaCLI

final class WorkflowTemporaryRegistrationTests: XCTestCase {
  private enum InjectedFailure: Error { case phase }

  func testRegisterBundleListsQueriesValidatesAndRunsByName() async throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let bundle = try writeBundle(at: layout.inputs, workflowId: "marker-demo", description: "registered")

    let register = await app.run([
      "workflow", "register", bundle.path, "--temporary", "--output", "json"
    ], environment: ["HOME": layout.home.path])
    XCTAssertEqual(register.exitCode, .success, register.stderr + register.stdout)
    let registered = try decode(TemporaryWorkflowRegistrationResult.self, register.stdout)
    XCTAssertEqual(registered.workflowId, "marker-demo")
    XCTAssertEqual(registered.scope, .user)
    XCTAssertEqual(registered.sourceKind, .workflow)
    XCTAssertTrue(registered.temporary)
    XCTAssertTrue(registered.mutable)
    XCTAssertFalse(registered.overwritten)

    for output in ["jsonl", "json", "text", "table"] {
      let listed = await app.run([
        "workflow", "list", "--scope", "user", "--output", output
      ], environment: ["HOME": layout.home.path])
      XCTAssertEqual(listed.exitCode, .success, listed.stderr + listed.stdout)
      if output == "jsonl" || output == "json" {
        let entry = try XCTUnwrap(decode(WorkflowCatalogResult.self, listed.stdout).workflows.first)
        XCTAssertEqual(entry.workflowName, "marker-demo")
        XCTAssertTrue(entry.temporary, "missing structured marker for \(output): \(listed.stdout)")
      } else {
        let rows = listed.stdout.split(separator: "\n")
        let row = output == "table" ? try XCTUnwrap(rows.dropFirst().first) : try XCTUnwrap(rows.first)
        let columns = row.split(separator: "\t", omittingEmptySubsequences: false)
        XCTAssertGreaterThan(columns.count, 3, listed.stdout)
        XCTAssertEqual(columns[3], "temporary", "missing rendered marker for \(output): \(listed.stdout)")
      }
    }

    let query = await app.run([
      "workflow", "list", "MARKER", "--scope", "user", "--output", "json"
    ], environment: ["HOME": layout.home.path])
    let queried = try decode(WorkflowCatalogResult.self, query.stdout)
    XCTAssertEqual(queried.workflows.map(\.workflowName), ["marker-demo"])
    XCTAssertTrue(queried.workflows[0].temporary)

    let excluded = await app.run([
      "workflow", "list", "marker", "--scope", "user", "--exclude-temporary", "--output", "json"
    ], environment: ["HOME": layout.home.path])
    XCTAssertEqual(try decode(WorkflowCatalogResult.self, excluded.stdout).workflows, [])

    let validated = await app.run([
      "workflow", "validate", "marker-demo", "--scope", "user", "--output", "json"
    ], environment: ["HOME": layout.home.path])
    XCTAssertEqual(validated.exitCode, .success, validated.stderr + validated.stdout)
    let validation = try decode(WorkflowValidationCommandResult.self, validated.stdout)
    XCTAssertTrue(validation.temporary)
    XCTAssertTrue(validation.workflowDirectory.contains("temporary-workflows/marker-demo"))

    let inspected = await app.run([
      "workflow", "inspect", "marker-demo", "--scope", "user", "--output", "json"
    ], environment: ["HOME": layout.home.path])
    XCTAssertEqual(inspected.exitCode, .success, inspected.stderr + inspected.stdout)
    XCTAssertTrue(try decode(WorkflowInspectionSummary.self, inspected.stdout).temporary)
    var legacyInspection = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(inspected.stdout.utf8)) as? [String: Any]
    )
    legacyInspection.removeValue(forKey: "temporary")
    let legacyInspectionData = try JSONSerialization.data(withJSONObject: legacyInspection)
    XCTAssertFalse(try JSONDecoder().decode(WorkflowInspectionSummary.self, from: legacyInspectionData).temporary)

    let run = await app.run([
      "workflow", "run", "marker-demo", "--scope", "user",
      "--mock-scenario", bundle.appendingPathComponent("scenario.json").path,
      "--session-store", layout.base.appendingPathComponent("sessions").path,
      "--output", "json"
    ], environment: ["HOME": layout.home.path])
    XCTAssertEqual(run.exitCode, .success, run.stderr + run.stdout)
  }

  func testRegistrationRendersAllOutputFormats() async throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let environment = ["HOME": layout.home.path]

    for output in ["jsonl", "json", "text", "table"] {
      let workflowId = "render-\(output)"
      let bundle = try writeBundle(
        at: layout.inputs.appendingPathComponent(output, isDirectory: true),
        workflowId: workflowId,
        description: output
      )
      let result = await app.run([
        "workflow", "register", bundle.path, "--temporary", "--output", output
      ], environment: environment)
      XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
      if output == "jsonl" || output == "json" {
        let rendered = try decode(TemporaryWorkflowRegistrationResult.self, result.stdout)
        XCTAssertEqual(rendered.workflowId, workflowId)
        XCTAssertTrue(rendered.temporary)
      } else if output == "text" {
        XCTAssertTrue(result.stdout.hasPrefix("registered temporary workflow \(workflowId) at "))
      } else {
        let rows = result.stdout.split(separator: "\n")
        XCTAssertEqual(rows.first, "WORKFLOW\tSCOPE\tSOURCE\tPROVENANCE\tMUTABLE\tOVERWRITTEN\tDIRECTORY")
        let columns = try XCTUnwrap(rows.dropFirst().first)
          .split(separator: "\t", omittingEmptySubsequences: false)
        XCTAssertEqual(columns[0], Substring(workflowId))
        XCTAssertEqual(columns[3], "temporary")
      }
    }
  }

  func testRegisterJSONFileAndRejectDuplicateWithoutMutation() async throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let file = layout.inputs.appendingPathComponent("file-demo.json")
    try """
    {
      "workflowId": "file-demo",
      "description": "original",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "work",
      "nodes": [{ "id": "worker", "addon": { "name": "example-addon" } }],
      "steps": [{ "id": "work", "nodeId": "worker", "role": "worker" }]
    }
    """.write(to: file, atomically: true, encoding: .utf8)

    let first = await app.run([
      "workflow", "register", file.path, "--temporary", "--output", "json"
    ], environment: ["HOME": layout.home.path])
    XCTAssertEqual(first.exitCode, .success, first.stderr + first.stdout)

    let second = await app.run([
      "workflow", "register", file.path, "--temporary", "--output", "json"
    ], environment: ["HOME": layout.home.path])
    XCTAssertEqual(second.exitCode, .usage)
    XCTAssertTrue(second.stdout.contains("--overwrite"))

    let destination = layout.home.appendingPathComponent(
      ".riela/temporary-workflows/file-demo/workflow.json"
    )
    XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), try String(contentsOf: file, encoding: .utf8))
  }

  func testInvalidJSONAndSymlinkInputsDoNotMutateCatalog() async throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let invalid = layout.inputs.appendingPathComponent("invalid.json")
    try #"{"workflowId":"invalid""#.write(to: invalid, atomically: true, encoding: .utf8)

    let failed = await app.run([
      "workflow", "register", invalid.path, "--temporary", "--output", "json"
    ], environment: ["HOME": layout.home.path])
    XCTAssertEqual(failed.exitCode, .failure)
    let failure = try decode(TemporaryWorkflowRegistrationFailure.self, failed.stdout)
    XCTAssertFalse(failure.registered)

    let link = layout.inputs.appendingPathComponent("linked.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: invalid)
    let linked = await app.run([
      "workflow", "register", link.path, "--temporary", "--output", "json"
    ], environment: ["HOME": layout.home.path])
    XCTAssertNotEqual(linked.exitCode, .success)

    let listed = await app.run([
      "workflow", "list", "--scope", "user", "--output", "json"
    ], environment: ["HOME": layout.home.path])
    XCTAssertEqual(try decode(WorkflowCatalogResult.self, listed.stdout).workflows, [])
  }

  func testUnsafeIdentifiersEscapingAssetsAndLinkedRecoveryRecordsFailClosed() async throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let environment = ["HOME": layout.home.path]

    let reserved = try writeBundle(
      at: layout.inputs.appendingPathComponent("reserved"),
      workflowId: ".registry-state",
      description: "reserved"
    )
    let reservedResult = await app.run([
      "workflow", "register", reserved.path, "--temporary", "--output", "json"
    ], environment: environment)
    XCTAssertNotEqual(reservedResult.exitCode, .success)

    let escaping = layout.inputs.appendingPathComponent("escaping", isDirectory: true)
    try FileManager.default.createDirectory(at: escaping, withIntermediateDirectories: true)
    try """
    {
      "workflowId": "escaping-demo",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "work",
      "nodes": [{ "id": "worker", "nodeFile": "../outside.json" }],
      "steps": [{ "id": "work", "nodeId": "worker", "role": "worker" }]
    }
    """.write(to: escaping.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try #"{"id":"worker","executionBackend":"codex-agent","model":"gpt-5.5"}"#
      .write(to: layout.inputs.appendingPathComponent("outside.json"), atomically: true, encoding: .utf8)
    let escapingResult = await app.run([
      "workflow", "register", escaping.path, "--temporary", "--output", "json"
    ], environment: environment)
    XCTAssertNotEqual(escapingResult.exitCode, .success)

    let valid = try writeBundle(at: layout.inputs, workflowId: "valid-demo", description: "valid")
    let validRegistration = await app.run([
      "workflow", "register", valid.path, "--temporary", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(validRegistration.exitCode, .success)
    let external = layout.base.appendingPathComponent("external-record.json")
    try Data("{}".utf8).write(to: external)
    let linkedRecord = layout.home.appendingPathComponent(
      ".riela/temporary-workflows/.registry-state/transactions/orphan.json"
    )
    try FileManager.default.createSymbolicLink(at: linkedRecord, withDestinationURL: external)
    let catalog = await app.run([
      "workflow", "list", "--scope", "user", "--output", "json"
    ], environment: environment)
    XCTAssertNotEqual(catalog.exitCode, .success)
    XCTAssertTrue(catalog.stderr.contains("linked or malformed"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: linkedRecord.path))

    let missingFlag = await app.run([
      "workflow", "register", valid.path, "--output", "json"
    ], environment: environment)
    XCTAssertEqual(missingFlag.exitCode, .usage)
  }

  func testRecoveryRejectsTraversalTransactionIdWithoutAliasingRegistryArtifact() async throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    try initializeTemporaryRegistryFixtureLayout(home: layout.home)
    let registryRoot = temporaryRegistryRoot(layout)
    let aliased = try writeBundle(
      at: registryRoot,
      workflowId: "alias-source",
      description: "must remain in place"
    )
    let transactionId = "../../../alias-source"
    let record = try writeRegistryRecord(
      layout,
      workflowId: "path-victim",
      transactionId: transactionId,
      phase: .originalBackedUp,
      hadOriginal: true
    )

    let listed = await app.run([
      "workflow", "list", "--scope", "user", "--output", "json"
    ], environment: ["HOME": layout.home.path])

    XCTAssertNotEqual(listed.exitCode, .success)
    XCTAssertTrue(FileManager.default.fileExists(atPath: aliased.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: registryRoot.appendingPathComponent("path-victim").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: record.path))
  }

  func testRecoveryRejectsLinkedDestinationStagingAndBackupArtifacts() async throws {
    for linkedArtifact in LinkedRegistryArtifact.allCases {
      let layout = try makeLayout()
      defer { try? FileManager.default.removeItem(at: layout.base) }
      try initializeTemporaryRegistryFixtureLayout(home: layout.home)
      let workflowId = "linked-\(linkedArtifact.rawValue)"
      let transactionId = "11111111-1111-1111-1111-111111111111"
      let paths = registryArtifactPaths(layout, workflowId: workflowId, transactionId: transactionId)
      let linkedPath = linkedArtifact.url(in: paths)
      try FileManager.default.createDirectory(
        at: linkedPath.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let external = layout.base.appendingPathComponent("external-\(linkedArtifact.rawValue)", isDirectory: true)
      try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(at: linkedPath, withDestinationURL: external)
      let record = try writeRegistryRecord(
        layout,
        workflowId: workflowId,
        transactionId: transactionId,
        phase: linkedArtifact == .backup ? .originalBackedUp : .publishingReplacement,
        hadOriginal: linkedArtifact == .backup
      )

      let listed = await app.run([
        "workflow", "list", "--scope", "user", "--output", "json"
      ], environment: ["HOME": layout.home.path])

      XCTAssertNotEqual(listed.exitCode, .success, linkedArtifact.rawValue)
      XCTAssertEqual(
        try FileManager.default.destinationOfSymbolicLink(atPath: linkedPath.path),
        external.path,
        linkedArtifact.rawValue
      )
      XCTAssertTrue(FileManager.default.fileExists(atPath: record.path), linkedArtifact.rawValue)
    }
  }

  func testOverwriteRecoveryAtEveryDurablePhase() async throws {
    for phase in WorkflowTemporaryRegistryPhase.allCases {
      let layout = try makeLayout()
      defer { try? FileManager.default.removeItem(at: layout.base) }
      let original = try writeBundle(
        at: layout.inputs.appendingPathComponent("original"),
        workflowId: "phase-demo",
        description: "old"
      )
      let replacement = try writeBundle(
        at: layout.inputs.appendingPathComponent("replacement"),
        workflowId: "phase-demo",
        description: "new"
      )
      let environment = ["HOME": layout.home.path]
      let initialRegistration = await app.run([
        "workflow", "register", original.path, "--temporary", "--output", "json"
      ], environment: environment)
      XCTAssertEqual(
        initialRegistration.exitCode,
        .success,
        "phase \(phase.rawValue): \(initialRegistration.stderr) \(initialRegistration.stdout)"
      )

      let registry = WorkflowTemporaryRegistry(hooks: WorkflowTemporaryRegistryHooks { reached in
        if reached == phase { throw InjectedFailure.phase }
      })
      let failingApp = RielaCLIApplication(
        workflowTemporaryRegistrationCommand: WorkflowTemporaryRegistrationCommand(registry: registry)
      )
      let overwrite = await failingApp.run([
        "workflow", "register", replacement.path, "--temporary", "--overwrite", "--output", "json"
      ], environment: environment)
      if phase == .replacementPublished {
        XCTAssertEqual(overwrite.exitCode, .success, overwrite.stderr + overwrite.stdout)
      } else {
        XCTAssertNotEqual(overwrite.exitCode, .success, "phase \(phase.rawValue)")
      }

      let listed = await app.run([
        "workflow", "list", "phase-demo", "--scope", "user", "--output", "json"
      ], environment: environment)
      guard listed.exitCode == .success else {
        XCTFail("phase \(phase.rawValue): \(listed.stderr) \(listed.stdout)")
        continue
      }
      let catalog = try decode(WorkflowCatalogResult.self, listed.stdout)
      XCTAssertEqual(catalog.workflows.count, 1, "phase \(phase.rawValue)")
      let entry = try XCTUnwrap(catalog.workflows.first, "phase \(phase.rawValue): \(listed.stdout) \(listed.stderr)")
      XCTAssertTrue(entry.valid, "phase \(phase.rawValue)")
      let published = layout.home.appendingPathComponent(
        ".riela/temporary-workflows/phase-demo/workflow.json"
      )
      let bytes = try String(contentsOf: published, encoding: .utf8)
      if phase == .replacementPublished {
        XCTAssertTrue(bytes.contains("new"))
      } else {
        XCTAssertTrue(bytes.contains("old"))
      }
    }
  }

  func testInterruptedOverwriteRecoversOnNextInvocationAtEveryDurablePhase() async throws {
    for phase in WorkflowTemporaryRegistryPhase.allCases {
      let layout = try makeLayout()
      defer { try? FileManager.default.removeItem(at: layout.base) }
      let original = try writeBundle(
        at: layout.inputs.appendingPathComponent("interrupted-original"),
        workflowId: "interrupted-phase-demo",
        description: "old"
      )
      let replacement = try writeBundle(
        at: layout.inputs.appendingPathComponent("interrupted-replacement"),
        workflowId: "interrupted-phase-demo",
        description: "new"
      )
      let environment = ["HOME": layout.home.path]
      let initialRegistration = await app.run([
        "workflow", "register", original.path, "--temporary", "--output", "json"
      ], environment: environment)
      XCTAssertEqual(initialRegistration.exitCode, .success, phase.rawValue)

      let registry = WorkflowTemporaryRegistry(hooks: WorkflowTemporaryRegistryHooks { reached in
        if reached == phase { throw TemporaryRegistryInterruption() }
      })
      let interruptedApp = RielaCLIApplication(
        workflowTemporaryRegistrationCommand: WorkflowTemporaryRegistrationCommand(registry: registry)
      )
      let overwrite = await interruptedApp.run([
        "workflow", "register", replacement.path, "--temporary", "--overwrite", "--output", "json"
      ], environment: environment)
      XCTAssertNotEqual(overwrite.exitCode, .success, phase.rawValue)

      let transaction = temporaryRegistryRoot(layout)
        .appendingPathComponent(".registry-state/transactions/interrupted-phase-demo.json")
      XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.path), phase.rawValue)

      let recoveryApp = RielaCLIApplication()
      let listed = await recoveryApp.run([
        "workflow", "list", "interrupted-phase-demo", "--scope", "user", "--output", "json"
      ], environment: environment)
      XCTAssertEqual(listed.exitCode, .success, "\(phase.rawValue): \(listed.stderr) \(listed.stdout)")
      let catalog = try decode(WorkflowCatalogResult.self, listed.stdout)
      XCTAssertEqual(catalog.workflows.count, 1, phase.rawValue)
      XCTAssertTrue(try XCTUnwrap(catalog.workflows.first).valid, phase.rawValue)
      XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.path), phase.rawValue)

      let published = temporaryRegistryRoot(layout)
        .appendingPathComponent("interrupted-phase-demo/workflow.json")
      let bytes = try String(contentsOf: published, encoding: .utf8)
      if phase == .replacementPublished {
        XCTAssertTrue(bytes.contains("new"), phase.rawValue)
      } else {
        XCTAssertTrue(bytes.contains("old"), phase.rawValue)
      }
    }
  }

  func testRegistryKeyMismatchFailsCatalogResolutionAndMutationClosed() async throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let bundle = try writeBundle(
      at: layout.inputs,
      workflowId: "registry-key",
      description: "registered"
    )
    let environment = ["HOME": layout.home.path]
    let registration = await app.run([
      "workflow", "register", bundle.path, "--temporary", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(registration.exitCode, .success, registration.stderr + registration.stdout)

    let published = temporaryRegistryRoot(layout)
      .appendingPathComponent("registry-key/workflow.json")
    let originalBytes = try String(contentsOf: published, encoding: .utf8)
    let mismatchedBytes = originalBytes.replacingOccurrences(
      of: #""workflowId": "registry-key""#,
      with: #""workflowId": "decoded-other""#
    )
    XCTAssertNotEqual(originalBytes, mismatchedBytes)
    try mismatchedBytes.write(to: published, atomically: true, encoding: .utf8)

    let listed = await app.run([
      "workflow", "list", "registry-key", "--scope", "user", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(listed.exitCode, .success, listed.stderr + listed.stdout)
    let catalog = try decode(WorkflowCatalogResult.self, listed.stdout)
    let entry = try XCTUnwrap(catalog.workflows.first)
    XCTAssertEqual(entry.workflowName, "registry-key")
    XCTAssertTrue(entry.temporary)
    XCTAssertFalse(entry.valid)
    XCTAssertTrue(entry.diagnostics.contains { $0.message.contains("does not match decoded workflowId") })

    let validated = await app.run([
      "workflow", "validate", "registry-key", "--scope", "user", "--output", "json"
    ], environment: environment)
    XCTAssertNotEqual(validated.exitCode, .success)
    XCTAssertTrue((validated.stderr + validated.stdout).contains("does not match decoded workflowId"))

    let run = await app.run([
      "workflow", "run", "registry-key", "--scope", "user",
      "--mock-scenario", bundle.appendingPathComponent("scenario.json").path,
      "--session-store", layout.base.appendingPathComponent("sessions").path,
      "--output", "json"
    ], environment: environment)
    XCTAssertNotEqual(run.exitCode, .success)
    XCTAssertTrue((run.stderr + run.stdout).contains("does not match decoded workflowId"))

    let restore = await app.run([
      "workflow", "restore", "registry-key", "missing-snapshot",
      "--scope", "user", "--working-dir", layout.project.path,
      "--yes", "--output", "json"
    ], environment: environment)
    XCTAssertNotEqual(restore.exitCode, .success)
    let decodedLock = temporaryRegistryRoot(layout)
      .appendingPathComponent(".registry-state/locks/decoded-other.lock")
    XCTAssertFalse(FileManager.default.fileExists(atPath: decodedLock.path))
    XCTAssertEqual(try String(contentsOf: published, encoding: .utf8), mismatchedBytes)
  }

  func testTemporaryIsLowestPrecedenceAndProjectScopeExcludesIt() async throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let temporary = try writeBundle(at: layout.inputs, workflowId: "precedence-demo", description: "temporary")
    let temporaryRegistration = await app.run([
      "workflow", "register", temporary.path, "--temporary", "--output", "json"
    ], environment: ["HOME": layout.home.path])
    XCTAssertEqual(temporaryRegistration.exitCode, .success)

    let projectRoot = layout.project.appendingPathComponent(".riela/workflows", isDirectory: true)
    _ = try writeBundle(at: projectRoot, workflowId: "precedence-demo", description: "project")
    let automatic = await app.run([
      "workflow", "inspect", "precedence-demo", "--working-dir", layout.project.path, "--output", "json"
    ], environment: ["HOME": layout.home.path])
    let summary = try decode(WorkflowInspectionSummary.self, automatic.stdout)
    XCTAssertEqual(summary.sourceScope, .project)
    XCTAssertFalse(summary.temporary)

    let temporaryOnly = try writeBundle(
      at: layout.inputs.appendingPathComponent("only"),
      workflowId: "temporary-only",
      description: "temporary only"
    )
    let temporaryOnlyRegistration = await app.run([
      "workflow", "register", temporaryOnly.path, "--temporary", "--output", "json"
    ], environment: ["HOME": layout.home.path])
    XCTAssertEqual(temporaryOnlyRegistration.exitCode, .success)
    let projectOnlyMissing = await app.run([
      "workflow", "validate", "temporary-only", "--scope", "project",
      "--working-dir", layout.project.path, "--output", "json"
    ], environment: ["HOME": layout.home.path])
    XCTAssertNotEqual(projectOnlyMissing.exitCode, .success)
  }

  func testRestoreAndRegistrationUseOneDeadlockFreeLockOrder() async throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let original = try writeBundle(
      at: layout.inputs.appendingPathComponent("restore-original"),
      workflowId: "restore-race",
      description: "old"
    )
    let replacement = try writeBundle(
      at: layout.inputs.appendingPathComponent("restore-replacement"),
      workflowId: "restore-race",
      description: "new"
    )
    let environment = ["HOME": layout.home.path]
    let registration = await app.run([
      "workflow", "register", original.path, "--temporary", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(registration.exitCode, .success, registration.stderr + registration.stdout)

    let prepared = try CLIRuntimeEnvironment.$overrides.withValue(environment) {
      let bundle = try FileSystemWorkflowBundleResolver().resolve(WorkflowResolutionOptions(
        workflowName: "restore-race",
        scope: .user,
        workingDirectory: layout.project.path
      ))
      let target = try WorkflowHistoryIdentityResolver.identity(for: bundle)
      let historyRoot = try WorkflowHistoryIdentityResolver.historyRoot(
        for: target,
        workingDirectory: layout.project
      )
      let snapshotId = try WorkflowHistoryStore(root: historyRoot).createSnapshot(
        inventory: WorkflowHistoryIdentityResolver.inventory(for: target)
      ).snapshotId
      return (bundle, snapshotId)
    }
    let bundle = prepared.0
    let snapshotId = prepared.1

    let phaseReached = DispatchSemaphore(value: 0)
    let releaseRegistration = DispatchSemaphore(value: 0)
    let registry = WorkflowTemporaryRegistry(hooks: WorkflowTemporaryRegistryHooks { phase in
      if phase == .prepared {
        phaseReached.signal()
        releaseRegistration.wait()
      }
    })
    let registeringApp = RielaCLIApplication(
      workflowTemporaryRegistrationCommand: WorkflowTemporaryRegistrationCommand(registry: registry)
    )
    let lockProbe = TemporaryRegistryLockProbe(lock: .catalog)
    let restoringApp = RielaCLIApplication(
      workflowVersionCommand: WorkflowVersionCommand(
        resolver: FixedWorkflowBundleResolver(bundle: bundle),
        temporaryRegistry: WorkflowTemporaryRegistry(hooks: lockProbe.hooks)
      )
    )
    let projectPath = layout.project.path
    let overwriteTask = Task {
      await registeringApp.run([
        "workflow", "register", replacement.path, "--temporary", "--overwrite", "--output", "json"
      ], environment: environment)
    }
    XCTAssertEqual(phaseReached.wait(timeout: .now() + 2), .success)

    let restoreTask = Task {
      await restoringApp.run([
        "workflow", "restore", "restore-race", snapshotId,
        "--scope", "user", "--working-dir", projectPath,
        "--yes", "--output", "json"
      ], environment: environment)
    }
    lockProbe.assertBlocked()
    releaseRegistration.signal()

    let overwrite = await overwriteTask.value
    let restore = await restoreTask.value
    XCTAssertEqual(overwrite.exitCode, .success, overwrite.stderr + overwrite.stdout)
    XCTAssertNotEqual(restore.exitCode, .success, restore.stderr + restore.stdout)
    XCTAssertTrue((restore.stderr + restore.stdout).contains("changed before mutation"))
    let published = layout.home.appendingPathComponent(
      ".riela/temporary-workflows/restore-race/workflow.json"
    )
    XCTAssertTrue(try String(contentsOf: published, encoding: .utf8).contains("new"))
  }

  func testSelfImproveAndRegistrationUseOneDeadlockFreeLockOrder() async throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let original = try writeBundle(
      at: layout.inputs.appendingPathComponent("self-improve-original"),
      workflowId: "self-improve-race",
      description: "old"
    )
    let replacement = try writeBundle(
      at: layout.inputs.appendingPathComponent("self-improve-replacement"),
      workflowId: "self-improve-race",
      description: "new"
    )
    let environment = ["HOME": layout.home.path]
    let registration = await app.run([
      "workflow", "register", original.path, "--temporary", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(registration.exitCode, .success, registration.stderr + registration.stdout)
    let bundle = try CLIRuntimeEnvironment.$overrides.withValue(environment) {
      try FileSystemWorkflowBundleResolver().resolve(WorkflowResolutionOptions(
        workflowName: "self-improve-race",
        scope: .user,
        workingDirectory: layout.project.path
      ))
    }

    let phaseReached = DispatchSemaphore(value: 0)
    let releaseRegistration = DispatchSemaphore(value: 0)
    let registry = WorkflowTemporaryRegistry(hooks: WorkflowTemporaryRegistryHooks { phase in
      if phase == .prepared {
        phaseReached.signal()
        releaseRegistration.wait()
      }
    })
    let registeringApp = RielaCLIApplication(
      workflowTemporaryRegistrationCommand: WorkflowTemporaryRegistrationCommand(registry: registry)
    )
    let lockProbe = TemporaryRegistryLockProbe(lock: .catalog)
    let versioning = WorkflowSelfImproveVersioning(
      temporaryRegistry: WorkflowTemporaryRegistry(hooks: lockProbe.hooks)
    )
    let projectPath = layout.project.path
    let overwriteTask = Task {
      await registeringApp.run([
        "workflow", "register", replacement.path, "--temporary", "--overwrite", "--output", "json"
      ], environment: environment)
    }
    XCTAssertEqual(phaseReached.wait(timeout: .now() + 2), .success)

    let improveTask = Task { () -> Result<WorkflowSelfImproveCommandResult, Error> in
      do {
        return .success(try CLIRuntimeEnvironment.$overrides.withValue(environment) {
          try versioning.execute(
            workflowName: "self-improve-race",
            bundle: bundle,
            workingDirectory: URL(fileURLWithPath: projectPath, isDirectory: true),
            dryRun: true,
            approved: false,
            changeSetId: nil,
            expectedDigest: nil,
            sourceSessionId: "temporary-race"
          )
        })
      } catch {
        return .failure(error)
      }
    }
    lockProbe.assertBlocked()
    releaseRegistration.signal()

    let overwrite = await overwriteTask.value
    let improve = await improveTask.value
    XCTAssertEqual(overwrite.exitCode, .success, overwrite.stderr + overwrite.stdout)
    guard case let .failure(error) = improve else {
      return XCTFail("stale self-improvement unexpectedly succeeded")
    }
    XCTAssertTrue("\(error)".contains("changed before mutation"))
  }

  func testResolverHistoryRecoveryAndRegistrationUseOneDeadlockFreeLockOrder() async throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let original = try writeBundle(
      at: layout.inputs.appendingPathComponent("resolver-original"),
      workflowId: "resolver-race",
      description: "old"
    )
    let replacement = try writeBundle(
      at: layout.inputs.appendingPathComponent("resolver-replacement"),
      workflowId: "resolver-race",
      description: "new"
    )
    let environment = ["HOME": layout.home.path]
    let registration = await app.run([
      "workflow", "register", original.path, "--temporary", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(registration.exitCode, .success, registration.stderr + registration.stdout)

    let recoveryReached = DispatchSemaphore(value: 0)
    let releaseRecovery = DispatchSemaphore(value: 0)
    let resolver = FileSystemWorkflowBundleResolver(temporaryHistoryRecoveryHook: {
      recoveryReached.signal()
      releaseRecovery.wait()
    })
    let validatingApp = RielaCLIApplication(
      validateCommand: WorkflowValidateCommand(resolver: resolver)
    )
    let lockProbe = TemporaryRegistryLockProbe(lock: .catalog)
    let registeringApp = RielaCLIApplication(
      workflowTemporaryRegistrationCommand: WorkflowTemporaryRegistrationCommand(
        registry: WorkflowTemporaryRegistry(hooks: lockProbe.hooks)
      )
    )
    let validationTask = Task {
      await validatingApp.run([
        "workflow", "validate", "resolver-race", "--scope", "user", "--output", "json"
      ], environment: environment)
    }
    XCTAssertEqual(recoveryReached.wait(timeout: .now() + 2), .success)

    let overwriteTask = Task {
      await registeringApp.run([
        "workflow", "register", replacement.path, "--temporary", "--overwrite", "--output", "json"
      ], environment: environment)
    }
    lockProbe.assertBlocked()
    releaseRecovery.signal()

    let validation = await validationTask.value
    let overwrite = await overwriteTask.value
    XCTAssertEqual(validation.exitCode, .success, validation.stderr + validation.stdout)
    XCTAssertEqual(overwrite.exitCode, .success, overwrite.stderr + overwrite.stdout)
    let published = temporaryRegistryRoot(layout)
      .appendingPathComponent("resolver-race/workflow.json")
    XCTAssertTrue(try String(contentsOf: published, encoding: .utf8).contains("new"))
  }

  func testOlderCodablePayloadsDefaultTemporaryToFalse() throws {
    let catalogJSON = #"{"diagnostics":[],"mutable":true,"scope":"user","sourceKind":"workflow","valid":true,"workflowDirectory":"/tmp/demo","workflowName":"demo"}"#
    let catalog = try decode(WorkflowCatalogEntry.self, catalogJSON)
    XCTAssertFalse(catalog.temporary)
    let validationJSON = """
    {"diagnostics":[],"mutable":true,"nodeValidationResults":[],
    "sourceKind":"workflow","sourceScope":"user","valid":true,
    "workflowDirectory":"/tmp/demo","workflowId":"demo"}
    """
    let validation = try decode(WorkflowValidationCommandResult.self, validationJSON)
    XCTAssertFalse(validation.temporary)
  }

  private var app: RielaCLIApplication { RielaCLIApplication() }

  private struct Layout {
    var base: URL
    var home: URL
    var project: URL
    var inputs: URL
  }

  private enum LinkedRegistryArtifact: String, CaseIterable {
    case destination
    case staging
    case backup

    func url(in paths: RegistryArtifactPaths) -> URL {
      switch self {
      case .destination: return paths.destination
      case .staging: return paths.staging
      case .backup: return paths.backup
      }
    }
  }

  private struct RegistryArtifactPaths {
    var destination: URL
    var staging: URL
    var backup: URL
  }

  private struct TemporaryRegistryRecordFixture: Encodable {
    var schemaVersion = 1
    var workflowId: String
    var transactionId: String
    var phase: WorkflowTemporaryRegistryPhase
    var hadOriginal: Bool
    var replacementDigest = String(repeating: "0", count: 64)
    var destinationPath: String
    var stagingPath: String
    var backupPath: String?
  }

  private func makeLayout() throws -> Layout {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-temporary-registration-\(UUID().uuidString)", isDirectory: true)
    let layout = Layout(
      base: base,
      home: base.appendingPathComponent("home", isDirectory: true),
      project: base.appendingPathComponent("project", isDirectory: true),
      inputs: base.appendingPathComponent("inputs", isDirectory: true)
    )
    for directory in [layout.home, layout.project, layout.inputs] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    return layout
  }

  private func temporaryRegistryRoot(_ layout: Layout) -> URL {
    layout.home.appendingPathComponent(".riela/temporary-workflows", isDirectory: true)
  }

  private func registryArtifactPaths(
    _ layout: Layout,
    workflowId: String,
    transactionId: String
  ) -> RegistryArtifactPaths {
    let root = temporaryRegistryRoot(layout)
    let state = root.appendingPathComponent(".registry-state", isDirectory: true)
    return RegistryArtifactPaths(
      destination: root.appendingPathComponent(workflowId, isDirectory: true),
      staging: state.appendingPathComponent("staging/\(transactionId)", isDirectory: true),
      backup: state.appendingPathComponent("backups/\(workflowId)/\(transactionId)", isDirectory: true)
    )
  }

  @discardableResult
  private func writeRegistryRecord(
    _ layout: Layout,
    workflowId: String,
    transactionId: String,
    phase: WorkflowTemporaryRegistryPhase,
    hadOriginal: Bool
  ) throws -> URL {
    let root = temporaryRegistryRoot(layout)
    let transactions = root.appendingPathComponent(".registry-state/transactions", isDirectory: true)
    let record = transactions.appendingPathComponent("\(workflowId).json")
    let fixture = TemporaryRegistryRecordFixture(
      workflowId: workflowId,
      transactionId: transactionId,
      phase: phase,
      hadOriginal: hadOriginal,
      destinationPath: workflowId,
      stagingPath: ".registry-state/staging/\(transactionId)",
      backupPath: hadOriginal ? ".registry-state/backups/\(workflowId)/\(transactionId)" : nil
    )
    try JSONEncoder().encode(fixture).write(to: record)
    return record
  }

  @discardableResult
  private func writeBundle(at parent: URL, workflowId: String, description: String) throws -> URL {
    let bundle = parent.appendingPathComponent(workflowId, isDirectory: true)
    let nodes = bundle.appendingPathComponent("nodes", isDirectory: true)
    try FileManager.default.createDirectory(at: nodes, withIntermediateDirectories: true)
    try """
    {
      "workflowId": "\(workflowId)",
      "description": "\(description)",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "work",
      "nodes": [{ "id": "worker", "nodeFile": "nodes/worker.json" }],
      "steps": [{ "id": "work", "nodeId": "worker", "role": "worker" }]
    }
    """.write(to: bundle.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try #"{"id":"worker","executionBackend":"codex-agent","model":"gpt-5.5","modelFreeze":false,"variables":{}}"#
      .write(to: nodes.appendingPathComponent("worker.json"), atomically: true, encoding: .utf8)
    try #"{"work":{"provider":"scenario-mock","model":"gpt-5.5","when":{"always":true},"payload":{"ok":true}}}"#
      .write(to: bundle.appendingPathComponent("scenario.json"), atomically: true, encoding: .utf8)
    return bundle
  }

  private func decode<T: Decodable>(_ type: T.Type, _ string: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(string.utf8))
  }
}

func initializeTemporaryRegistryFixtureLayout(home: URL) throws {
  let root = home.appendingPathComponent(".riela/temporary-workflows", isDirectory: true)
  let state = root.appendingPathComponent(".registry-state", isDirectory: true)
  for directory in [
    root,
    state,
    state.appendingPathComponent("locks", isDirectory: true),
    state.appendingPathComponent("transactions", isDirectory: true),
    state.appendingPathComponent("record-staging", isDirectory: true),
    state.appendingPathComponent("staging", isDirectory: true),
    state.appendingPathComponent("backups", isDirectory: true)
  ] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  try Data().write(to: state.appendingPathComponent("catalog.lock"))
}

private struct FixedWorkflowBundleResolver: WorkflowBundleResolving {
  var bundle: ResolvedWorkflowBundle

  func resolve(_ options: WorkflowResolutionOptions) throws -> ResolvedWorkflowBundle {
    bundle
  }
}

final class TemporaryRegistryLockProbe: @unchecked Sendable {
  private let lock: WorkflowTemporaryRegistryLock
  private let attempted = DispatchSemaphore(value: 0)
  private let permitAttempt = DispatchSemaphore(value: 0)
  private let acquired = DispatchSemaphore(value: 0)

  init(lock: WorkflowTemporaryRegistryLock) {
    self.lock = lock
  }

  var hooks: WorkflowTemporaryRegistryHooks {
    WorkflowTemporaryRegistryHooks(
      beforeLockAcquire: { [self] candidate in
        guard candidate == lock else { return }
        attempted.signal()
        permitAttempt.wait()
      },
      afterLockAcquire: { [self] candidate in
        if candidate == lock {
          acquired.signal()
        }
      }
    )
  }

  func assertBlocked(file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(attempted.wait(timeout: .now() + 2), .success, file: file, line: line)
    permitAttempt.signal()
    XCTAssertEqual(acquired.wait(timeout: .now() + 1), .timedOut, file: file, line: line)
  }
}
