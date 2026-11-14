import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class WorkflowMutableRegistryTests: XCTestCase {
  func testMutableCRUDFilteringAndLegacyRootReadability() async throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.root) }
    let original = try makeBundle(id: "mutable-crud", description: "alpha searchable description", in: layout.inputs)
    let updated = try makeBundle(id: "mutable-crud", description: "beta updated description", in: layout.updates)
    let app = RielaCLIApplication()

    let registration = await app.run([
      "workflow", "register", original.path, "--mutable", "--output", "json"
    ], environment: layout.environment)
    XCTAssertEqual(registration.exitCode, .success, registration.stderr + registration.stdout)
    let registered = try decode(MutableWorkflowRegistrationResult.self, registration.stdout)
    XCTAssertEqual(registered.provenance, .mutable)
    XCTAssertEqual(registered.activationState, .active)
    XCTAssertTrue(registered.workflowDirectory.contains(".riela/temporary-workflows/mutable-crud"))
    XCTAssertFalse(registration.stdout.contains(#""temporary""#))

    let filtered = await app.run([
      "workflow", "list", "searchable", "--scope", "user", "--output", "json"
    ], environment: layout.environment)
    let filteredEntries = try decode(WorkflowCatalogResult.self, filtered.stdout).workflows
    XCTAssertEqual(filteredEntries.map(\.workflowId), ["mutable-crud"])
    XCTAssertEqual(filteredEntries[0].provenance, .mutable)

    let update = await app.run([
      "workflow", "update", "mutable-crud", updated.path, "--scope", "user", "--output", "json"
    ], environment: layout.environment)
    XCTAssertEqual(update.exitCode, .success, update.stderr + update.stdout)
    XCTAssertEqual(try decode(WorkflowRegistryMutationResult.self, update.stdout).workflow?.description, "beta updated description")

    let deletion = await app.run([
      "workflow", "delete", "mutable-crud", "--scope", "user", "--output", "json"
    ], environment: layout.environment)
    XCTAssertEqual(deletion.exitCode, .success, deletion.stderr + deletion.stdout)
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: layout.home.appendingPathComponent(".riela/temporary-workflows/mutable-crud").path
    ))
  }

  func testImmutableMutationRejectionAndActivationExecutionExclusion() async throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.root) }
    let immutableRoot = layout.home.appendingPathComponent(".riela/workflows", isDirectory: true)
    let immutable = try makeBundle(id: "immutable-demo", description: "owned outside registry", in: immutableRoot)
    let updateInput = try makeBundle(id: "immutable-demo", description: "attempted rewrite", in: layout.inputs)
    let app = RielaCLIApplication()

    for command in [
      ["workflow", "update", "immutable-demo", updateInput.path, "--scope", "user", "--output", "json"],
      ["workflow", "delete", "immutable-demo", "--scope", "user", "--output", "json"]
    ] {
      let result = await app.run(command, environment: layout.environment)
      XCTAssertEqual(result.exitCode, .failure, result.stderr + result.stdout)
      let payload = try decode(WorkflowRegistryMutationResult.self, result.stdout)
      XCTAssertEqual(payload.errors.first?.code, .immutableWorkflow)
      XCTAssertTrue(FileManager.default.fileExists(atPath: immutable.appendingPathComponent("workflow.json").path))
    }

    let deactivated = await app.run([
      "workflow", "deactivate", "immutable-demo", "--scope", "user", "--output", "json"
    ], environment: layout.environment)
    XCTAssertEqual(deactivated.exitCode, .success, deactivated.stderr + deactivated.stdout)
    XCTAssertEqual(
      try decode(WorkflowRegistryMutationResult.self, deactivated.stdout).workflow?.activationState,
      .deactivated
    )

    let listed = await app.run([
      "workflow", "list", "immutable-demo", "--scope", "user", "--activation", "deactivated", "--output", "json"
    ], environment: layout.environment)
    XCTAssertEqual(try decode(WorkflowCatalogResult.self, listed.stdout).workflows.count, 1)

    let run = await app.run([
      "workflow", "run", "immutable-demo", "--scope", "user", "--output", "json"
    ], environment: layout.environment)
    XCTAssertEqual(run.exitCode, .failure)
    XCTAssertTrue(run.stdout.contains(WorkflowRegistryErrorCode.workflowDeactivated.rawValue))

    let activated = await app.run([
      "workflow", "activate", "immutable-demo", "--scope", "user", "--output", "json"
    ], environment: layout.environment)
    XCTAssertEqual(activated.exitCode, .success, activated.stderr + activated.stdout)
  }

  func testDeactivatedWorkflowRejectsBeforeNodePayloadMaterialization() async throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.root) }
    let bundle = try makeBundle(
      id: "deactivated-invalid-payload",
      description: "must reject before payload decoding",
      in: layout.inputs
    )
    let app = RielaCLIApplication()
    let registration = await app.run([
      "workflow", "register", bundle.path, "--mutable", "--output", "json"
    ], environment: layout.environment)
    XCTAssertEqual(registration.exitCode, .success, registration.stderr + registration.stdout)

    let deactivation = await app.run([
      "workflow", "deactivate", "deactivated-invalid-payload", "--scope", "user", "--output", "json"
    ], environment: layout.environment)
    XCTAssertEqual(deactivation.exitCode, .success, deactivation.stderr + deactivation.stdout)

    let registeredPayload = layout.home
      .appendingPathComponent(".riela/temporary-workflows/deactivated-invalid-payload", isDirectory: true)
      .appendingPathComponent("nodes/node-main-worker.json")
    try Data("{".utf8).write(to: registeredPayload)

    let run = await app.run([
      "workflow", "run", "deactivated-invalid-payload", "--scope", "user", "--output", "json"
    ], environment: layout.environment)
    XCTAssertEqual(run.exitCode, .failure)
    XCTAssertTrue(run.stdout.contains(WorkflowRegistryErrorCode.workflowDeactivated.rawValue), run.stdout)
    XCTAssertFalse(run.stdout.contains("DecodingError"), run.stdout)
  }

  func testConsolidationValidatesBeforeRetirementAndSupportsBothModes() async throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.root) }
    let app = RielaCLIApplication()
    for id in ["source-a", "source-b", "delete-a", "delete-b"] {
      let bundle = try makeBundle(id: id, description: id, in: layout.inputs)
      let result = await app.run([
        "workflow", "register", bundle.path, "--mutable", "--output", "json"
      ], environment: layout.environment)
      XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    }

    let invalid = layout.inputs.appendingPathComponent("invalid", isDirectory: true)
    try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
    try Data(#"{"workflowId":"invalid"}"#.utf8).write(to: invalid.appendingPathComponent("workflow.json"))
    let rejected = await app.run([
      "workflow", "consolidate", "--source", "source-a", "--source", "source-b",
      "--replacement", invalid.path, "--retire", "deactivate", "--scope", "user", "--output", "json"
    ], environment: layout.environment)
    XCTAssertNotEqual(rejected.exitCode, .success)
    let unchangedResult = await app.run([
      "workflow", "list", "source-", "--scope", "user", "--output", "json"
    ], environment: layout.environment)
    let unchanged = try decode(WorkflowCatalogResult.self, unchangedResult.stdout).workflows
    XCTAssertEqual(Set(unchanged.map(\.activationState)), [.active])

    let replacement = try makeBundle(id: "replacement-deactivate", description: "merged", in: layout.updates)
    let deactivated = await app.run([
      "workflow", "consolidate", "--source", "source-a", "--source", "source-b",
      "--replacement", replacement.path, "--retire", "deactivate", "--scope", "user", "--output", "json"
    ], environment: layout.environment)
    XCTAssertEqual(deactivated.exitCode, .success, deactivated.stderr + deactivated.stdout)
    let deactivatePayload = try decode(WorkflowRegistryMutationResult.self, deactivated.stdout)
    XCTAssertEqual(Set(deactivatePayload.retiredWorkflows.map(\.activationState)), [.deactivated])

    let deleteReplacement = try makeBundle(id: "replacement-delete", description: "merged delete", in: layout.updates)
    let deleted = await app.run([
      "workflow", "consolidate", "--source", "delete-a", "--source", "delete-b",
      "--replacement", deleteReplacement.path, "--retire", "delete", "--scope", "user", "--output", "json"
    ], environment: layout.environment)
    XCTAssertEqual(deleted.exitCode, .success, deleted.stderr + deleted.stdout)
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: layout.home.appendingPathComponent(".riela/temporary-workflows/delete-a").path
    ))
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: layout.home.appendingPathComponent(".riela/temporary-workflows/delete-b").path
    ))
  }

  func testMutableDeletionRecoversAtEveryDurablePhase() async throws {
    for phase in [
      WorkflowMutableRegistryPhase.prepared,
      .movingOriginal,
      .originalBackedUp,
      .replacementPublished
    ] {
      let layout = try makeLayout()
      defer { try? FileManager.default.removeItem(at: layout.root) }
      let bundle = try makeBundle(id: "delete-recovery", description: phase.rawValue, in: layout.inputs)
      try CLIRuntimeEnvironment.$overrides.withValue(layout.environment) {
        _ = try WorkflowMutableRegistry().register(input: bundle, overwrite: false)
        let interrupted = WorkflowMutableRegistry(hooks: WorkflowMutableRegistryHooks(afterPhase: { current in
          if current == phase { throw MutableRegistryInterruption() }
        }))
        XCTAssertThrowsError(try interrupted.delete(workflowId: "delete-recovery"))
        _ = try WorkflowMutableRegistry().snapshotCandidates()
      }
      let destination = layout.home.appendingPathComponent(
        ".riela/temporary-workflows/delete-recovery",
        isDirectory: true
      )
      let shouldRemain = phase != .replacementPublished
      XCTAssertEqual(FileManager.default.fileExists(atPath: destination.path), shouldRemain, phase.rawValue)
    }
  }

  func testRegistrationRecoversRequestedActivationAtPublicationInterruption() async throws {
    for activationState in WorkflowActivationState.allCases {
      let layout = try makeLayout()
      defer { try? FileManager.default.removeItem(at: layout.root) }
      let workflowId = "register-\(activationState.rawValue)"
      let bundle = try makeBundle(id: workflowId, description: activationState.rawValue, in: layout.inputs)
      try CLIRuntimeEnvironment.$overrides.withValue(layout.environment) {
        let interruptedRegistry = WorkflowMutableRegistry(hooks: WorkflowMutableRegistryHooks(afterPhase: { phase in
          if phase == .replacementPublished { throw MutableRegistryInterruption() }
        }))
        let service = WorkflowRegistryService(registry: interruptedRegistry)
        XCTAssertThrowsError(try service.register(
          input: bundle,
          overwrite: false,
          activationState: activationState,
          workingDirectory: layout.root.path
        ))

        let recovered = try WorkflowRegistryService().fetch(
          target: WorkflowRegistryTarget(workflowId: workflowId, scope: .user),
          workingDirectory: layout.root.path
        )
        XCTAssertEqual(recovered.activationState, activationState)
        let resolution = WorkflowResolutionOptions(
          workflowName: workflowId,
          scope: .user,
          workingDirectory: layout.root.path
        )
        if activationState == .active {
          XCTAssertNoThrow(try FileSystemWorkflowBundleResolver().resolve(resolution))
        } else {
          XCTAssertThrowsError(try FileSystemWorkflowBundleResolver().resolve(resolution)) { error in
            XCTAssertEqual((error as? WorkflowRegistryError)?.code, .workflowDeactivated)
          }
        }
      }
    }
  }

  func testContinuationEventAndWorkflowCallExcludeDeactivatedOrigins() async throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.root) }
    let workflowId = "activation-entry-points"
    let bundle = try makeBundle(id: workflowId, description: "entry point matrix", in: layout.inputs)
    let mock = layout.root.appendingPathComponent("mock.json")
    try Data("""
    {
      "main-worker": {
        "provider": "scenario-mock",
        "model": "gpt-5.3-codex-spark",
        "when": {"always": true},
        "payload": {"status": "ready"}
      }
    }
    """.utf8).write(to: mock)
    let app = RielaCLIApplication()
    let registration = await app.run([
      "workflow", "register", bundle.path, "--mutable", "--output", "json"
    ], environment: layout.environment)
    XCTAssertEqual(registration.exitCode, .success, registration.stderr)
    let run = await app.run([
      "workflow", "run", workflowId, "--scope", "user", "--working-dir", layout.root.path,
      "--mock-scenario", mock.path, "--output", "json"
    ], environment: layout.environment)
    XCTAssertEqual(run.exitCode, .success, run.stderr + run.stdout)
    let sessionId = try decode(WorkflowRunResult.self, run.stdout).session.sessionId

    let deactivation = await app.run([
      "workflow", "deactivate", workflowId, "--scope", "user", "--working-dir", layout.root.path,
      "--output", "json"
    ], environment: layout.environment)
    XCTAssertEqual(deactivation.exitCode, .success, deactivation.stderr)

    let continuation = await app.run([
      "session", "continue", sessionId, "--scope", "user", "--working-dir", layout.root.path,
      "--mock-scenario", mock.path, "--output", "json"
    ], environment: layout.environment)
    XCTAssertEqual(continuation.exitCode, .failure)
    XCTAssertTrue(
      (continuation.stdout + continuation.stderr).contains(WorkflowRegistryErrorCode.workflowDeactivated.rawValue),
      continuation.stderr + continuation.stdout
    )

    try await CLIRuntimeEnvironment.$overrides.withValue(layout.environment) {
      let parsed = try ParsedParityOptions([
        "--scope", "user", "--working-dir", layout.root.path, "--mock-scenario", mock.path
      ])
      do {
        _ = try await CLIEventWorkflowRunner().runWorkflow(EventWorkflowRunRequest(
          workflowName: workflowId,
          runtimeVariables: [:],
          parsed: parsed
        ))
        XCTFail("event-triggered execution must reject a deactivated origin")
      } catch {
        XCTAssertTrue("\(error)".contains(WorkflowRegistryErrorCode.workflowDeactivated.rawValue))
      }

      do {
        _ = try await FileSystemWorkflowCalleeResolver(baseResolution: WorkflowResolutionOptions(
          workflowName: "caller",
          scope: .user,
          workingDirectory: layout.root.path
        )).resolveCallee(workflowId: workflowId)
        XCTFail("cross-workflow calls must reject a deactivated origin")
      } catch {
        XCTAssertTrue("\(error)".contains(WorkflowRegistryErrorCode.workflowDeactivated.rawValue))
      }
    }
  }

  func testConsolidationRecoversEveryJournalPhaseForBothRetireModes() async throws {
    for retireMode in WorkflowRetireMode.allCases {
      for phase in WorkflowConsolidationPhase.allCases {
        let layout = try makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let sourceIds = ["source-a", "source-b"]
        let replacementId = "replacement-\(retireMode.rawValue)-\(phase.rawValue)"
        let replacement = try makeBundle(id: replacementId, description: "recovered", in: layout.updates)
        try CLIRuntimeEnvironment.$overrides.withValue(layout.environment) {
          let baseline = WorkflowRegistryService()
          for sourceId in sourceIds {
            let source = try makeBundle(id: sourceId, description: sourceId, in: layout.inputs)
            _ = try baseline.register(input: source, overwrite: false)
          }
          let coordinator = WorkflowRegistryCoordinator(hooks: WorkflowRegistryCoordinatorHooks(afterPhase: { current in
            if current == phase { throw WorkflowConsolidationInterruption() }
          }))
          let interrupted = WorkflowRegistryService(
            registry: WorkflowMutableRegistry(),
            coordinator: coordinator
          )
          XCTAssertThrowsError(try interrupted.consolidate(
            sources: sourceIds.map { WorkflowRegistryTarget(workflowId: $0, scope: .user) },
            replacement: replacement,
            retireMode: retireMode
          ))

          let recovered = try WorkflowRegistryService().list(workingDirectory: layout.root.path)
          let replacementEntry = recovered.first { $0.workflowId == replacementId }
          if phase == .prepared {
            XCTAssertNil(replacementEntry, "prepared interruption must preserve the prior state")
            XCTAssertEqual(
              Set(recovered.filter { sourceIds.contains($0.workflowId) }.map(\.activationState)),
              [.active]
            )
          } else {
            XCTAssertNotNil(replacementEntry, "post-publication interruption must roll forward")
            let sources = recovered.filter { sourceIds.contains($0.workflowId) }
            switch retireMode {
            case .deactivate:
              XCTAssertEqual(Set(sources.map(\.activationState)), [.deactivated])
            case .delete:
              XCTAssertTrue(sources.isEmpty)
            }
          }
          XCTAssertFalse(FileManager.default.fileExists(
            atPath: layout.home.appendingPathComponent(".riela/workflow-state/consolidation.json").path
          ))
        }
      }
    }
  }

  func testCoordinatedCatalogReaderCannotObservePartialConsolidation() async throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.root) }
    let sourceIds = ["snapshot-source-a", "snapshot-source-b"]
    let replacement = try makeBundle(id: "snapshot-replacement", description: "replacement", in: layout.updates)
    try CLIRuntimeEnvironment.$overrides.withValue(layout.environment) {
      for sourceId in sourceIds {
        _ = try WorkflowRegistryService().register(
          input: try makeBundle(id: sourceId, description: sourceId, in: layout.inputs),
          overwrite: false,
          workingDirectory: layout.root.path
        )
      }
    }
    let writerPaused = DispatchSemaphore(value: 0)
    let releaseWriter = DispatchSemaphore(value: 0)
    let coordinator = WorkflowRegistryCoordinator(hooks: WorkflowRegistryCoordinatorHooks(afterPhase: { phase in
      if phase == .replacementPublished {
        writerPaused.signal()
        releaseWriter.wait()
      }
    }))
    let writer = Task {
      try CLIRuntimeEnvironment.$overrides.withValue(layout.environment) {
        try WorkflowRegistryService(
          registry: WorkflowMutableRegistry(),
          coordinator: coordinator
        ).consolidate(
          sources: sourceIds.map { WorkflowRegistryTarget(workflowId: $0, scope: .user) },
          replacement: replacement,
          retireMode: .deactivate,
          workingDirectory: layout.root.path
        )
      }
    }
    XCTAssertEqual(writerPaused.wait(timeout: .now() + 5), .success)

    let readerCompletion = ReaderCompletion()
    let reader = Task {
      let entries = try CLIRuntimeEnvironment.$overrides.withValue(layout.environment) {
        try WorkflowRegistryService().list(workingDirectory: layout.root.path)
      }
      await readerCompletion.markComplete()
      return entries
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    let completedWhileWriterPaused = await readerCompletion.isComplete
    XCTAssertFalse(completedWhileWriterPaused)

    releaseWriter.signal()
    _ = try await writer.value
    let entries = try await reader.value
    XCTAssertNotNil(entries.first { $0.workflowId == "snapshot-replacement" })
    XCTAssertEqual(
      Set(entries.filter { sourceIds.contains($0.workflowId) }.map(\.activationState)),
      [.deactivated]
    )
  }

  func testFilesystemBackedGraphQLCRUDFilteringActivationAndConsolidation() async throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.root) }
    let app = RielaCLIApplication()
    let original = try makeBundle(id: "graphql-a", description: "needle original", in: layout.inputs)
    let second = try makeBundle(id: "graphql-b", description: "needle second", in: layout.inputs)
    let updated = try makeBundle(id: "graphql-a", description: "needle updated", in: layout.updates)
    let replacement = try makeBundle(id: "graphql-merged", description: "merged", in: layout.updates)

    for bundle in [original, second] {
      let result = await runGraphQL(
        "mutation { registerMutableWorkflow(input: {bundle: {kind: LOCAL_PATH, value: \"\(bundle.path)\"}}) "
          + "{ accepted workflow { workflowId provenance activationState } errors { code } } }",
        app: app,
        layout: layout
      )
      let payload = try acceptedGraphQLPayload("registerMutableWorkflow", from: result)
      let workflow = try graphQLObject("workflow", in: payload)
      XCTAssertEqual(workflow["workflowId"] as? String, bundle.lastPathComponent)
      XCTAssertEqual(workflow["provenance"] as? String, "MUTABLE")
      XCTAssertEqual(workflow["activationState"] as? String, "ACTIVE")
    }

    let fetched = await runGraphQL(
      "query { workflow(target: {workflowId: \"graphql-a\", scope: USER}) "
        + "{ workflow { workflowId description provenance activationState } errors { code } } }",
      app: app,
      layout: layout
    )
    let fetchedPayload = try successfulGraphQLPayload("workflow", from: fetched)
    let fetchedWorkflow = try graphQLObject("workflow", in: fetchedPayload)
    XCTAssertEqual(fetchedWorkflow["workflowId"] as? String, "graphql-a")
    XCTAssertEqual(fetchedWorkflow["description"] as? String, "needle original")
    XCTAssertEqual(fetchedWorkflow["provenance"] as? String, "MUTABLE")
    XCTAssertEqual(fetchedWorkflow["activationState"] as? String, "ACTIVE")

    let listedByDescription = await runGraphQL(
      "query { workflows(filter: {description: \"needle\", provenance: MUTABLE, activationState: ACTIVE}) "
        + "{ workflows { workflowId description } errors { code } } }",
      app: app,
      layout: layout
    )
    XCTAssertEqual(
      try graphQLWorkflowIds(from: listedByDescription),
      ["graphql-a", "graphql-b"]
    )

    let listedByPartialNameOrId = await runGraphQL(
      "query { workflows(filter: {query: \"aphql-a\", provenance: MUTABLE, activationState: ACTIVE}) "
        + "{ workflows { workflowId description } errors { code } } }",
      app: app,
      layout: layout
    )
    XCTAssertEqual(try graphQLWorkflowIds(from: listedByPartialNameOrId), ["graphql-a"])

    let noNameOrIdMatch = await runGraphQL(
      "query { workflows(filter: {query: \"absent-id\", provenance: MUTABLE}) "
        + "{ workflows { workflowId } errors { code } } }",
      app: app,
      layout: layout
    )
    XCTAssertEqual(try graphQLWorkflowIds(from: noNameOrIdMatch), [])

    let noDescriptionMatch = await runGraphQL(
      "query { workflows(filter: {description: \"absent-description\", provenance: MUTABLE}) "
        + "{ workflows { workflowId } errors { code } } }",
      app: app,
      layout: layout
    )
    XCTAssertEqual(try graphQLWorkflowIds(from: noDescriptionMatch), [])

    let update = await runGraphQL(
      "mutation { updateMutableWorkflow(input: {target: {workflowId: \"graphql-a\", scope: USER}, "
        + "bundle: {kind: LOCAL_PATH, value: \"\(updated.path)\"}}) "
        + "{ accepted workflow { workflowId description } errors { code } } }",
      app: app,
      layout: layout
    )
    let updatePayload = try acceptedGraphQLPayload("updateMutableWorkflow", from: update)
    XCTAssertEqual(
      try graphQLObject("workflow", in: updatePayload)["description"] as? String,
      "needle updated"
    )

    let deactivated = await runGraphQL(
      "mutation { deactivateWorkflow(input: {target: {workflowId: \"graphql-a\", scope: USER}}) "
        + "{ accepted workflow { workflowId activationState } errors { code } } }",
      app: app,
      layout: layout
    )
    let deactivatedPayload = try acceptedGraphQLPayload("deactivateWorkflow", from: deactivated)
    XCTAssertEqual(
      try graphQLObject("workflow", in: deactivatedPayload)["activationState"] as? String,
      "DEACTIVATED"
    )
    let activated = await runGraphQL(
      "mutation { activateWorkflow(input: {target: {workflowId: \"graphql-a\", scope: USER}}) "
        + "{ accepted workflow { activationState } errors { code } } }",
      app: app,
      layout: layout
    )
    let activatedPayload = try acceptedGraphQLPayload("activateWorkflow", from: activated)
    XCTAssertEqual(
      try graphQLObject("workflow", in: activatedPayload)["activationState"] as? String,
      "ACTIVE"
    )

    let consolidated = await runGraphQL(
      "mutation { consolidateWorkflows(input: {sources: ["
        + "{workflowId: \"graphql-a\", scope: USER}, {workflowId: \"graphql-b\", scope: USER}], "
        + "replacement: {kind: LOCAL_PATH, value: \"\(replacement.path)\"}, retireMode: DELETE}) "
        + "{ accepted workflow { workflowId } retiredWorkflows { workflowId } errors { code } } }",
      app: app,
      layout: layout
    )
    let consolidatedPayload = try acceptedGraphQLPayload("consolidateWorkflows", from: consolidated)
    XCTAssertEqual(
      try graphQLObject("workflow", in: consolidatedPayload)["workflowId"] as? String,
      "graphql-merged"
    )
    let retired = try XCTUnwrap(consolidatedPayload["retiredWorkflows"] as? [[String: Any]])
    XCTAssertEqual(Set(retired.compactMap { $0["workflowId"] as? String }), ["graphql-a", "graphql-b"])

    let deleted = await runGraphQL(
      "mutation { deleteMutableWorkflow(input: {target: {workflowId: \"graphql-merged\", scope: USER}}) "
        + "{ accepted errors { code } } }",
      app: app,
      layout: layout
    )
    _ = try acceptedGraphQLPayload("deleteMutableWorkflow", from: deleted)
  }

  private struct Layout {
    var root: URL
    var home: URL
    var inputs: URL
    var updates: URL
    var environment: [String: String]
  }

  private func makeLayout() throws -> Layout {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-mutable-registry-\(UUID().uuidString)", isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let inputs = root.appendingPathComponent("inputs", isDirectory: true)
    let updates = root.appendingPathComponent("updates", isDirectory: true)
    for directory in [home, inputs, updates] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    return Layout(root: root, home: home, inputs: inputs, updates: updates, environment: ["HOME": home.path])
  }

  private func makeBundle(id: String, description: String, in parent: URL) throws -> URL {
    let destination = parent.appendingPathComponent(id, isDirectory: true)
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.createDirectory(
      at: destination.appendingPathComponent("nodes", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: destination.appendingPathComponent("prompts", isDirectory: true),
      withIntermediateDirectories: true
    )
    let definitionURL = destination.appendingPathComponent("workflow.json")
    let object: [String: Any] = [
      "workflowId": id,
      "description": description,
      "defaults": ["maxLoopIterations": 3, "nodeTimeoutMs": 120_000],
      "prompts": ["workerSystemPromptTemplate": "Return concise JSON."],
      "entryStepId": "main-worker",
      "nodes": [["id": "main-worker", "nodeFile": "nodes/node-main-worker.json"]],
      "steps": [["id": "main-worker", "nodeId": "main-worker", "role": "worker"]]
    ]
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: definitionURL)
    try Data("""
    {
      "id": "main-worker",
      "executionBackend": "codex-agent",
      "model": "gpt-5.3-codex-spark",
      "promptTemplateFile": "prompts/main-worker.md",
      "variables": {}
    }
    """.utf8).write(to: destination.appendingPathComponent("nodes/node-main-worker.json"))
    try Data("Complete {{workflowId}}.".utf8).write(
      to: destination.appendingPathComponent("prompts/main-worker.md")
    )
    return destination
  }

  private func runGraphQL(
    _ query: String,
    app: RielaCLIApplication,
    layout: Layout
  ) async -> CLICommandResult {
    await app.run([
      "graphql", "document", "--query", query, "--working-dir", layout.root.path, "--output", "json"
    ], environment: layout.environment)
  }

  private func acceptedGraphQLPayload(
    _ field: String,
    from result: CLICommandResult,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> [String: Any] {
    let payload = try successfulGraphQLPayload(field, from: result, file: file, line: line)
    XCTAssertEqual(payload["accepted"] as? Bool, true, file: file, line: line)
    return payload
  }

  private func successfulGraphQLPayload(
    _ field: String,
    from result: CLICommandResult,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> [String: Any] {
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout, file: file, line: line)
    let command = try JSONDecoder().decode(
      ScopedParityCommandResult.self,
      from: Data(result.stdout.utf8)
    )
    XCTAssertEqual(command.status, "ok", file: file, line: line)
    XCTAssertEqual(command.records.count, 1, file: file, line: line)
    let body = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(try XCTUnwrap(command.records.first).utf8))
        as? [String: Any],
      file: file,
      line: line
    )
    XCTAssertNil(body["errors"], file: file, line: line)
    let data = try XCTUnwrap(body["data"] as? [String: Any], file: file, line: line)
    let payload = try XCTUnwrap(data[field] as? [String: Any], file: file, line: line)
    let errors = try XCTUnwrap(payload["errors"] as? [[String: Any]], file: file, line: line)
    XCTAssertTrue(errors.isEmpty, file: file, line: line)
    return payload
  }

  private func graphQLObject(
    _ key: String,
    in payload: [String: Any],
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> [String: Any] {
    try XCTUnwrap(payload[key] as? [String: Any], file: file, line: line)
  }

  private func graphQLWorkflowIds(
    from result: CLICommandResult,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> [String] {
    let payload = try successfulGraphQLPayload("workflows", from: result, file: file, line: line)
    let workflows = try XCTUnwrap(
      payload["workflows"] as? [[String: Any]],
      file: file,
      line: line
    )
    return workflows.compactMap { $0["workflowId"] as? String }.sorted()
  }

  private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(text.utf8))
  }
}

private actor ReaderCompletion {
  private(set) var isComplete = false

  func markComplete() {
    isComplete = true
  }
}

final class WorkflowActivationTests: XCTestCase {
  func testActivationStateDefaultsActive() throws {
    let origin = WorkflowOriginIdentity(
      scope: .user,
      sourceKind: .workflow,
      provenance: .mutable,
      name: "demo",
      workflowId: "demo",
      canonicalLocator: "/tmp/demo"
    )
    XCTAssertTrue(origin.originId.hasPrefix("wfo_"))
    XCTAssertEqual(origin.originId.count, 68)
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-activation-default-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let environment = ["HOME": root.path]
    let state = try CLIRuntimeEnvironment.$overrides.withValue(environment) {
      try WorkflowActivationStore().state(for: origin)
    }
    XCTAssertEqual(state, .active)
  }

  func testActivationMutationFailsClosedWhenPinnedStateRootIsReplaced() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-activation-root-swap-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let stateRoot = root.appendingPathComponent(".riela/workflow-state", isDirectory: true)
    let displacedRoot = root.appendingPathComponent(".riela/workflow-state-displaced", isDirectory: true)
    let decoy = Data(#"{"schemaVersion":1,"deactivated":{}}"#.utf8)
    let origin = WorkflowOriginIdentity(
      scope: .user,
      sourceKind: .workflow,
      provenance: .mutable,
      name: "root-swap",
      workflowId: "root-swap",
      canonicalLocator: "/tmp/root-swap"
    )
    let store = WorkflowActivationStore(hooks: WorkflowActivationStoreHooks(afterStateRootPin: {
      try FileManager.default.moveItem(at: stateRoot, to: displacedRoot)
      try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: false)
      try decoy.write(to: stateRoot.appendingPathComponent("activation.json"))
    }))

    XCTAssertThrowsError(try CLIRuntimeEnvironment.$overrides.withValue(["HOME": root.path]) {
      try store.set(.deactivated, for: origin)
    })
    XCTAssertEqual(try Data(contentsOf: stateRoot.appendingPathComponent("activation.json")), decoy)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: displacedRoot.appendingPathComponent("activation.json").path)
    )
  }
}

final class WorkflowConsolidationTests: XCTestCase {
  func testRetireModesAreClosedTypedValues() {
    XCTAssertEqual(WorkflowRetireMode.allCases, [.deactivate, .delete])
  }

  func testConsolidationJournalWriteCannotFollowReplacedStateRoot() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-consolidation-root-swap-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let stateRoot = root.appendingPathComponent(".riela/workflow-state", isDirectory: true)
    let displacedRoot = root.appendingPathComponent(".riela/workflow-state-displaced", isDirectory: true)
    let decoy = Data("do-not-replace".utf8)
    let transactionId = UUID().uuidString.lowercased()
    let journal = WorkflowConsolidationJournal(
      schemaVersion: 1,
      transactionId: transactionId,
      phase: .prepared,
      sources: [],
      replacementWorkflowId: "replacement",
      replacementDigest: "digest",
      retireMode: .deactivate,
      activateReplacement: true
    )

    XCTAssertThrowsError(try CLIRuntimeEnvironment.$overrides.withValue(["HOME": root.path]) {
      try WorkflowActivationStore().withCoordinatorLock {
        try FileManager.default.moveItem(at: stateRoot, to: displacedRoot)
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: false)
        try decoy.write(to: stateRoot.appendingPathComponent("consolidation.json"))
        try WorkflowRegistryCoordinator().write(journal)
      }
    })
    XCTAssertEqual(try Data(contentsOf: stateRoot.appendingPathComponent("consolidation.json")), decoy)
    let displacedJournal = displacedRoot.appendingPathComponent("consolidation.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: displacedJournal.path))
    XCTAssertEqual(
      try JSONDecoder().decode(WorkflowConsolidationJournal.self, from: Data(contentsOf: displacedJournal)),
      journal
    )
  }
}
