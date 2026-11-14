import Foundation
import XCTest
@testable import RielaCLI
import RielaCore
import RielaSQLite
import RielaWorkflowRegistry

final class WorkflowDefinitionCommandTests: XCTestCase {
  private final class Clock: @unchecked Sendable { var now: Date; init(_ now: Date) { self.now = now } }

  func testDefinitionImportPromptAuditForceRestoreAndExport() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let app = RielaCLIApplication()

    let seeded = await app.run(fixture.command("import", "w", "--output", "json"))
    XCTAssertEqual(seeded.exitCode, .success, seeded.stdout + seeded.stderr)
    guard seeded.exitCode == .success else { return }
    XCTAssertEqual(try jsonObject(seeded.stdout)["outcome"] as? String, "seeded")
    let seedCounts = try rowCounts(storeRoot: fixture.store)

    let unchanged = await app.run(fixture.command("import", "w", "--output", "json"))
    XCTAssertEqual(unchanged.exitCode, .success, unchanged.stderr)
    XCTAssertEqual(try jsonObject(unchanged.stdout)["outcome"] as? String, "unchanged")

    try "changed file prompt".write(to: fixture.prompt, atomically: true, encoding: .utf8)
    let differs = await app.run(fixture.command("import", "w", "--output", "json"))
    XCTAssertEqual(differs.exitCode, .success, differs.stderr)
    XCTAssertEqual(try jsonObject(differs.stdout)["outcome"] as? String, "differs")
    XCTAssertFalse((try jsonObject(differs.stdout)["diff"] as? [Any] ?? []).isEmpty)
    XCTAssertEqual(try rowCounts(storeRoot: fixture.store), seedCounts)

    let usage = await app.run(fixture.command("import", "w", "--force", "--output", "json"))
    XCTAssertEqual(usage.exitCode, .usage)
    XCTAssertEqual(try errorCode(usage.stdout), "reason_required")
    XCTAssertEqual(try rowCounts(storeRoot: fixture.store), seedCounts)

    let promptUpdate = await app.run(fixture.command(
      "update-prompt", "w", "--node", "worker", "--field", "promptTemplate", "--text", "stored prompt",
      "--reason", "r", "--evidence", "session:s1", "--output", "json"
    ))
    XCTAssertEqual(promptUpdate.exitCode, .success, promptUpdate.stdout + promptUpdate.stderr)
    let updateResult = try jsonObject(promptUpdate.stdout)
    let updatedVersionId = try XCTUnwrap(updateResult["version"].flatMap { ($0 as? [String: Any])?["versionId"] as? String })

    let history = await app.run(fixture.command("history", "w", "--output", "json"))
    XCTAssertEqual(history.exitCode, .success, history.stderr)
    let newest = try XCTUnwrap((try jsonObjectArray(history.stdout)).first { ($0["reason"] as? String) == "r" })
    XCTAssertEqual(newest["operation"] as? String, "updatePrompt")
    XCTAssertEqual((newest["actor"] as? [String: Any])?["kind"] as? String, "cli")
    XCTAssertEqual(((newest["evidence"] as? [[String: Any]])?.first)?["id"] as? String, "s1")

    let force = await app.run(fixture.command("import", "w", "--force", "--reason", "sync", "--output", "json"))
    XCTAssertEqual(force.exitCode, .success, force.stdout + force.stderr)
    XCTAssertEqual(try jsonObject(force.stdout)["outcome"] as? String, "forceUpdated")
    let audit = try XCTUnwrap(try jsonObject(force.stdout)["audit"] as? [String: Any])
    let overwritten = try XCTUnwrap(audit["overwrittenChanges"] as? [String: Any])
    XCTAssertTrue((overwritten["auditIds"] as? [String] ?? []).contains(newest["auditId"] as? String ?? ""))

    let restored = await app.run(fixture.command("restore", "w", "--version", updatedVersionId, "--reason", "back", "--output", "json"))
    XCTAssertEqual(restored.exitCode, .success, restored.stdout + restored.stderr)
    let shown = await app.run(fixture.command("show", "w", "--output", "json"))
    XCTAssertEqual(shown.exitCode, .success, shown.stderr)
    XCTAssertEqual(
      try jsonObject(shown.stdout)["document"].flatMap { ($0 as? [String: Any])?["runtime"] as? [String: Any] }
        .flatMap { $0["nodePayloads"] as? [String: Any] }
        .flatMap { $0["worker"] as? [String: Any] }
        .flatMap { $0["promptTemplate"] as? String },
      "stored prompt"
    )

    let authored = await app.run(fixture.command("show", "w", "--authored", "--output", "json"))
    XCTAssertEqual(authored.exitCode, .success, authored.stderr)
    XCTAssertNotNil(try jsonObject(authored.stdout)["workflow.json"])

    let exportDirectory = fixture.root.appendingPathComponent("export", isDirectory: true)
    let exported = await app.run(fixture.command("export", "w", "--to", exportDirectory.path, "--output", "json"))
    XCTAssertEqual(exported.exitCode, .success, exported.stdout + exported.stderr)
    XCTAssertTrue(try jsonObject(exported.stdout)["paths"] as? [String] == ["nodes/worker.json", "prompts/a.md", "workflow.json"])
    XCTAssertTrue(FileManager.default.fileExists(atPath: exportDirectory.appendingPathComponent("workflow.json").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: exportDirectory.appendingPathComponent("prompts/a.md").path))
    let sourceWithoutOverwrite = await app.run(fixture.command("export", "w", "--to-source", "--output", "json"))
    XCTAssertEqual(sourceWithoutOverwrite.exitCode, .usage)
    let sourceExport = await app.run(fixture.command("export", "w", "--to-source", "--overwrite", "--output", "json"))
    XCTAssertEqual(sourceExport.exitCode, .success, sourceExport.stdout + sourceExport.stderr)
    let afterSourceExport = await app.run(fixture.command("import", "w", "--output", "json"))
    XCTAssertEqual(afterSourceExport.exitCode, .success, afterSourceExport.stdout + afterSourceExport.stderr)
    XCTAssertEqual(try jsonObject(afterSourceExport.stdout)["outcome"] as? String, "unchanged")
  }

  func testUpdatePatchUsageErrorsConflictsAndUnregisteredShape() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let app = RielaCLIApplication()
    let seeded = await app.run(fixture.command("import", "w", "--output", "json"))
    XCTAssertEqual(seeded.exitCode, .success, seeded.stdout + seeded.stderr)
    guard seeded.exitCode == .success else { return }
    let before = try rowCounts(storeRoot: fixture.store)
    let patchFile = fixture.root.appendingPathComponent("patch.json")
    try #"[{"op":"replace","path":"/prompts~1a.md","value":"patched"}]"#.write(to: patchFile, atomically: true, encoding: .utf8)

    let missingReason = await app.run(fixture.command("update", "w", "--patch", patchFile.path, "--output", "json"))
    XCTAssertEqual(missingReason.exitCode, .usage)
    XCTAssertEqual(try errorCode(missingReason.stdout), "reason_required")
    XCTAssertEqual(try rowCounts(storeRoot: fixture.store), before)

    let blankReason = await app.run(fixture.command("update", "w", "--patch", patchFile.path, "--reason", "  ", "--output", "json"))
    XCTAssertEqual(blankReason.exitCode, .usage)
    XCTAssertEqual(try errorCode(blankReason.stdout), "reason_required")
    let noSource = await app.run(fixture.command("update", "w", "--reason", "r", "--output", "json"))
    XCTAssertEqual(noSource.exitCode, .usage)
    XCTAssertEqual(try rowCounts(storeRoot: fixture.store), before)

    let invalidPromptField = await app.run(fixture.command(
      "update-prompt", "w", "--node", "worker", "--field", "bogus", "--text", "x", "--reason", "r", "--output", "json"
    ))
    XCTAssertEqual(invalidPromptField.exitCode, .failure)
    XCTAssertEqual(try errorCode(invalidPromptField.stdout), "invalid_definition")
    XCTAssertEqual(try rowCounts(storeRoot: fixture.store), before)
    let unknownVersion = await app.run(fixture.command("show", "w", "--version", "defv-unknown", "--output", "json"))
    XCTAssertEqual(unknownVersion.exitCode, .failure)
    XCTAssertEqual(try rowCounts(storeRoot: fixture.store), before)

    let bothSources = await app.run(fixture.command(
      "update", "w", "--patch", patchFile.path, "--from-file", fixture.workflow.path, "--reason", "r", "--output", "json"
    ))
    XCTAssertEqual(bothSources.exitCode, .usage)
    XCTAssertEqual(try rowCounts(storeRoot: fixture.store), before)

    let forceWithPatch = await app.run(fixture.command(
      "update", "w", "--patch", patchFile.path, "--force", "--reason", "r", "--output", "json"
    ))
    XCTAssertEqual(forceWithPatch.exitCode, .usage)

    let stale = await app.run(fixture.command(
      "update", "w", "--patch", patchFile.path, "--reason", "r", "--expected-version", "defv-stale", "--output", "json"
    ))
    XCTAssertEqual(stale.exitCode, .failure)
    XCTAssertEqual(try errorCode(stale.stdout), "definition_conflict")
    XCTAssertEqual(try rowCounts(storeRoot: fixture.store), before)

    let disallowed = await app.run(fixture.command(
      "update", "w", "--patch", patchFile.path, "--reason", "r", "--actor-kind", "api", "--output", "json"
    ))
    XCTAssertEqual(disallowed.exitCode, .usage)
    XCTAssertEqual(try rowCounts(storeRoot: fixture.store), before)

    let success = await app.run(fixture.command(
      "update", "w", "--patch", patchFile.path, "--reason", "tighten", "--evidence", "session:s1",
      "--evidence", "stepExecution:e1", "--actor", "bot", "--actor-kind", "improvementNode", "--output", "json"
    ))
    XCTAssertEqual(success.exitCode, .success, success.stdout + success.stderr)
    let updateJSON = try jsonObject(success.stdout)
    XCTAssertEqual(Set(updateJSON.keys), Set(["accepted", "outcome", "versionId", "digest", "auditId", "diff"]))
    XCTAssertEqual(updateJSON["accepted"] as? Bool, true)
    XCTAssertEqual(updateJSON["outcome"] as? String, "updated")
    XCTAssertNotNil(updateJSON["auditId"] as? String)
    let updateHistory = await app.run(fixture.command("history", "w", "--output", "json"))
    let updateAudit = try XCTUnwrap(try jsonObjectArray(updateHistory.stdout).first)
    XCTAssertEqual(updateAudit["operation"] as? String, "update")
    XCTAssertEqual((updateAudit["actor"] as? [String: Any])?["kind"] as? String, "improvementNode")
    XCTAssertEqual((updateAudit["actor"] as? [String: Any])?["id"] as? String, "bot")
    XCTAssertEqual((updateAudit["evidence"] as? [[String: Any]])?.count, 2)
    let seedVersion = try XCTUnwrap(jsonObject(seeded.stdout)["version"].flatMap { ($0 as? [String: Any])?["versionId"] as? String })
    let updatedVersion = try XCTUnwrap(jsonObject(success.stdout)["versionId"] as? String)
    let patchDiff = await app.run(fixture.command("diff", "w", "--from", seedVersion, "--to", updatedVersion, "--output", "json"))
    XCTAssertEqual(patchDiff.exitCode, .success, patchDiff.stdout + patchDiff.stderr)
    XCTAssertTrue(try jsonObjectArray(patchDiff.stdout).contains { $0["path"] as? String == "/authoredFiles/prompts~1a.md" })

    let replacement = fixture.root.appendingPathComponent("replacement", isDirectory: true)
    try FileManager.default.copyItem(at: fixture.workflow.deletingLastPathComponent(), to: replacement)
    try "replacement prompt".write(to: replacement.appendingPathComponent("prompts/a.md"), atomically: true, encoding: .utf8)
    let fromFile = await app.run(fixture.command(
      "update", "w", "--from-file", replacement.appendingPathComponent("workflow.json").path, "--reason", "replace files", "--output", "json"
    ))
    XCTAssertEqual(fromFile.exitCode, .success, fromFile.stdout + fromFile.stderr)
    let fromFileHistory = await app.run(fixture.command("history", "w", "--output", "json"))
    XCTAssertEqual(fromFileHistory.exitCode, .success, fromFileHistory.stderr)
    XCTAssertEqual(try jsonObjectArray(fromFileHistory.stdout).first?["operation"] as? String, "update")
    let forceFromFile = await app.run(fixture.command(
      "update", "w", "--from-file", replacement.path, "--force", "--reason", "sync from file", "--output", "json"
    ))
    XCTAssertEqual(forceFromFile.exitCode, .success, forceFromFile.stdout + forceFromFile.stderr)
    XCTAssertEqual(try jsonObject(forceFromFile.stdout)["outcome"] as? String, "forceUpdated")

    let unregistered = await app.run(fixture.command("update", "missing", "--patch", patchFile.path, "--reason", "r", "--output", "json"))
    XCTAssertEqual(unregistered.exitCode, .failure)
    XCTAssertEqual(try errorCode(unregistered.stdout), "definition_not_registered")
  }

  func testUndoRedoRetentionAuditAndTextDiff() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let app = RielaCLIApplication()
    let seed = await app.run(fixture.command("import", "w", "--output", "json"))
    XCTAssertEqual(seed.exitCode, .success, seed.stdout + seed.stderr)
    let firstVersion = try XCTUnwrap((try jsonObject(seed.stdout))["version"].flatMap { ($0 as? [String: Any])?["versionId"] as? String })

    var writtenVersionIds = [firstVersion]
    for prompt in ["second", "third", "fourth"] {
      let update = await app.run(fixture.command("update-prompt", "w", "--node", "worker", "--field", "promptTemplate",
        "--text", prompt, "--reason", "edit", "--output", "json"))
      XCTAssertEqual(update.exitCode, .success, update.stdout + update.stderr)
      writtenVersionIds.append(try XCTUnwrap((try jsonObject(update.stdout))["version"].flatMap { ($0 as? [String: Any])?["versionId"] as? String }))
    }
    let historyResult = await app.run(fixture.command("history", "w", "--output", "json"))
    let beforeUndo = try XCTUnwrap(try jsonObjectArray(historyResult.stdout).first)
    XCTAssertNotNil(beforeUndo["retained"] as? Bool)

    let undone = await app.run(fixture.command("undo", "w", "--reason", "back", "--output", "json"))
    XCTAssertEqual(undone.exitCode, .success, undone.stdout + undone.stderr)
    let undoVersion = try XCTUnwrap((try jsonObject(undone.stdout))["version"].flatMap { ($0 as? [String: Any])?["versionId"] as? String })
    let redone = await app.run(fixture.command("redo", "w", "--reason", "forward", "--output", "json"))
    XCTAssertEqual(redone.exitCode, .success, redone.stdout + redone.stderr)
    let redoVersion = try XCTUnwrap((try jsonObject(redone.stdout))["version"].flatMap { ($0 as? [String: Any])?["versionId"] as? String })
    XCTAssertEqual(undoVersion, writtenVersionIds[2])
    XCTAssertEqual(redoVersion, writtenVersionIds[3])

    let diff = await app.run(fixture.command("diff", "w", "--from", firstVersion, "--to", redoVersion))
    XCTAssertEqual(diff.exitCode, .success, diff.stdout + diff.stderr)
    XCTAssertTrue(diff.stdout.contains("before:"), diff.stdout)
    XCTAssertTrue(diff.stdout.contains("after:"), diff.stdout)

    let atOldest = await app.run(fixture.command("undo", "w", "--reason", "oldest", "--output", "json"))
    XCTAssertEqual(atOldest.exitCode, .success, atOldest.stdout + atOldest.stderr)
    _ = await app.run(fixture.command("undo", "w", "--reason", "oldest", "--output", "json"))
    _ = await app.run(fixture.command("undo", "w", "--reason", "oldest", "--output", "json"))
    let exhausted = await app.run(fixture.command("undo", "w", "--reason", "oldest", "--output", "json"))
    XCTAssertEqual(exhausted.exitCode, .failure)
    XCTAssertEqual(try errorCode(exhausted.stdout), "nothing_to_undo")

    let branchWrite = await app.run(fixture.command("update-prompt", "w", "--node", "worker", "--field", "promptTemplate",
      "--text", "branch", "--reason", "branch", "--output", "json"))
    XCTAssertEqual(branchWrite.exitCode, .success, branchWrite.stdout + branchWrite.stderr)
    let droppedRedo = await app.run(fixture.command("redo", "w", "--reason", "redo", "--output", "json"))
    XCTAssertEqual(droppedRedo.exitCode, .failure)
    XCTAssertEqual(try errorCode(droppedRedo.stdout), "nothing_to_redo")

    let staleRevision = await app.run(fixture.command("undo", "w", "--reason", "stale", "--expected-revision", "1", "--output", "json"))
    XCTAssertEqual(try errorCode(staleRevision.stdout), "stale_revision")
    let staleVersion = await app.run(fixture.command("undo", "w", "--reason", "stale", "--expected-version", "wrong", "--output", "json"))
    XCTAssertEqual(try errorCode(staleVersion.stdout), "definition_conflict")
  }

  func testDefinitionTextDiffRendersAddedObjectDeterministically() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let app = RielaCLIApplication()
    let seed = await app.run(fixture.command("import", "w", "--output", "json"))
    XCTAssertEqual(seed.exitCode, .success, seed.stdout + seed.stderr)
    let seedVersionId = try XCTUnwrap((try jsonObject(seed.stdout))["version"].flatMap { ($0 as? [String: Any])?["versionId"] as? String })
    let service = WorkflowDefinitionService(storeRoot: fixture.store.path, fileResolver: FileSystemWorkflowBundleResolver())
    var document = try service.show(workflowName: "w", versionId: seedVersionId).document
    document.runtime.nodePayloads["added"] = AgentNodePayload(id: "added", model: "test-model")
    let documentData = try document.canonicalData()
    let store = WorkflowDefinitionStore(rootDirectory: fixture.store.path)
    guard case let .created(version, _) = try store.commit(WorkflowDefinitionWrite(workflowName: "w", operation: .update,
      documentData: documentData, documentDigest: JSONCanonical.sha256Hex(documentData), sourceDirectory: fixture.workflow.path,
      sourceScope: "direct", provenance: "test", actor: WorkflowDefinitionActor(kind: .user), reason: "add object node",
      expectedCurrentVersionId: seedVersionId)) else { return XCTFail("expected definition update") }
    let updatedVersionId = version.versionId
    let diff = await app.run(fixture.command("diff", "w", "--from", seedVersionId, "--to", updatedVersionId))
    XCTAssertEqual(diff.exitCode, .success, diff.stdout + diff.stderr)
    XCTAssertTrue(diff.stdout.contains("add /runtime/nodePayloads/added\nbefore: <absent>\nafter: {\"agentEnvironment\":{},\"id\":\"added\",\"model\":\"test-model\",\"modelFreeze\":false,\"variables\":{}}"), diff.stdout)
    XCTAssertFalse(diff.stdout.contains("\\/"), diff.stdout)
  }

  func testHistoryRetentionCLIAndConfigurationResolution() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let home = fixture.root.appendingPathComponent("home", isDirectory: true)
    let projectConfig = fixture.root.appendingPathComponent(".riela/config.json")
    let userConfig = home.appendingPathComponent(".riela/config.json")
    try FileManager.default.createDirectory(at: projectConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: userConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #"{"workflowDefinitions":{"historyRetention":4}}"#.write(to: userConfig, atomically: true, encoding: .utf8)
    try #"{"workflowDefinitions":{"historyRetention":3}}"#.write(to: projectConfig, atomically: true, encoding: .utf8)
    XCTAssertEqual(try WorkflowDefinitionHistoryConfiguration.resolve(homeDirectory: home.path, projectDirectory: fixture.root.path, environment: [:]), 3)
    try #"{"workflowDefinitions":{"historyRetention":3},"retention":{"definitions":{"keepVersions":4}}}"#.write(to: projectConfig, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try WorkflowDefinitionHistoryConfiguration.resolve(homeDirectory: home.path, projectDirectory: fixture.root.path, environment: [:]))
    try #"{"retention":{"definitions":{"keepVersions":3}}}"#.write(to: projectConfig, atomically: true, encoding: .utf8)
    XCTAssertEqual(try WorkflowDefinitionHistoryConfiguration.resolve(homeDirectory: home.path, projectDirectory: fixture.root.path, environment: [:]), 3)
    try #"{"retention":{"definitions":{"keepVersions":0}}}"#.write(to: projectConfig, atomically: true, encoding: .utf8)
    XCTAssertEqual(try WorkflowDefinitionHistoryConfiguration.resolve(homeDirectory: home.path, projectDirectory: fixture.root.path, environment: [:]), 0)
    try #"{"workflowDefinitions":{"historyRetention":3}}"#.write(to: projectConfig, atomically: true, encoding: .utf8)
    try #"{"workflowDefinitions":{"unexpected":1}}"#.write(to: userConfig, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try WorkflowDefinitionHistoryConfiguration.resolve(homeDirectory: home.path, projectDirectory: fixture.root.path, environment: [:]))
    try #"{"workflowDefinitions":{"historyRetention":4}}"#.write(to: userConfig, atomically: true, encoding: .utf8)
    try #"{"workflowDefinitions":{"historyRetention":10001}}"#.write(to: projectConfig, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try WorkflowDefinitionHistoryConfiguration.resolve(homeDirectory: home.path, projectDirectory: fixture.root.path, environment: [:]))
    try #"{"workflowDefinitions":{"unexpected":1}}"#.write(to: projectConfig, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try WorkflowDefinitionHistoryConfiguration.resolve(homeDirectory: home.path, projectDirectory: fixture.root.path, environment: [:]))
    try FileManager.default.removeItem(at: projectConfig)
    XCTAssertEqual(try WorkflowDefinitionHistoryConfiguration.resolve(homeDirectory: home.path, projectDirectory: fixture.root.path, environment: [:]), 4)
    try FileManager.default.removeItem(at: userConfig)
    XCTAssertEqual(try WorkflowDefinitionHistoryConfiguration.resolve(homeDirectory: home.path, projectDirectory: fixture.root.path, environment: [:]), 10)

    let service = WorkflowDefinitionService(storeRoot: fixture.store.path, fileResolver: FileSystemWorkflowBundleResolver())
    _ = try service.importDefinition(resolution: WorkflowResolutionOptions(workflowName: "w", scope: .direct,
      workflowDefinitionDir: fixture.workflowRoot.path, workingDirectory: fixture.root.path), force: false, reason: nil,
      evidence: [], actor: WorkflowDefinitionActor(kind: .cli))
    try FileManager.default.createDirectory(at: projectConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #"{"workflowDefinitions":{"historyRetention":10001}}"#.write(to: projectConfig, atomically: true, encoding: .utf8)
    let readWithBadConfig = await RielaCLIApplication().run(fixture.command("show", "w", "--output", "json"))
    XCTAssertEqual(readWithBadConfig.exitCode, .success, readWithBadConfig.stdout + readWithBadConfig.stderr)
    let configFailure = await RielaCLIApplication().run(fixture.command("import", "w", "--output", "json"))
    XCTAssertEqual(configFailure.exitCode, .usage)
    XCTAssertEqual(try errorCode(configFailure.stdout), "invalid_configuration")
  }

  func testHistoryRetentionExpiresOldVersionAfterFormerHeadWindow() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let clock = Clock(Date(timeIntervalSinceNow: -30 * 24 * 60 * 60))
    let service = WorkflowDefinitionService(storeRoot: fixture.store.path, fileResolver: FileSystemWorkflowBundleResolver(), now: { clock.now })
    let resolution = WorkflowResolutionOptions(workflowName: "w", scope: .direct, workflowDefinitionDir: fixture.workflowRoot.path, workingDirectory: fixture.root.path)
    let imported = try service.importDefinition(resolution: resolution, force: false, reason: nil, evidence: [], actor: WorkflowDefinitionActor(kind: .cli))
    var ids = [try XCTUnwrap(imported.version?.versionId)]
    for value in ["two", "three", "four"] {
      clock.now = clock.now.addingTimeInterval(25 * 60 * 60)
      ids.append(try service.updatePrompt(workflowName: "w", nodeId: "worker", field: .node(.promptTemplate), text: value,
        reason: "edit", expectedVersionId: nil, evidence: [], actor: WorkflowDefinitionActor(kind: .cli)).0.versionId)
    }
    let finalUpdate = await RielaCLIApplication().run(fixture.command("update-prompt", "w", "--node", "worker", "--field", "promptTemplate",
      "--text", "five", "--reason", "edit", "--history-retention", "2", "--output", "json"))
    XCTAssertEqual(finalUpdate.exitCode, .success, finalUpdate.stdout + finalUpdate.stderr)
    let dropped = await RielaCLIApplication().run(fixture.command("show", "w", "--version", ids[1], "--output", "json"))
    XCTAssertEqual(dropped.exitCode, .failure)
    XCTAssertEqual(try errorCode(dropped.stdout), "definition_version_not_retained")
    let retainedError = try XCTUnwrap((try jsonObject(dropped.stdout))["error"] as? [String: Any])
    XCTAssertEqual(retainedError["retainedGenerations"] as? Int, 2)
    let latestHistory = await RielaCLIApplication().run(fixture.command("history", "w", "--output", "json"))
    let newHead = try XCTUnwrap(try jsonObjectArray(latestHistory.stdout).first?["versionId"] as? String)
    XCTAssertEqual(Set(retainedError["retainedVersionIds"] as? [String] ?? []), Set([ids[0], ids[3], newHead]))
    let historyRows = try jsonObjectArray(latestHistory.stdout)
    XCTAssertTrue(historyRows.contains { $0["retained"] as? Bool == false })
    let textHistory = await RielaCLIApplication().run(fixture.command("history", "w"))
    XCTAssertTrue(textHistory.stdout.contains("retained="), textHistory.stdout)
    XCTAssertTrue(textHistory.stdout.contains("older versions dropped by retention"), textHistory.stdout)
  }

  func testDefinitionPruneAndPurgeCommandsRespectRecentHeadProtection() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let app = RielaCLIApplication()
    let imported = await app.run(fixture.command("import", "w", "--output", "json"))
    XCTAssertEqual(imported.exitCode, .success, imported.stdout + imported.stderr)
    for value in ["two", "three", "four"] {
      let update = await app.run(fixture.command("update-prompt", "w", "--node", "worker", "--field", "promptTemplate",
        "--text", value, "--reason", "edit", "--output", "json"))
      XCTAssertEqual(update.exitCode, .success, update.stdout + update.stderr)
    }

    let preview = await app.run(fixture.command("prune", "w", "--keep", "1", "--dry-run", "--output", "json"))
    XCTAssertEqual(preview.exitCode, .success, preview.stdout + preview.stderr)
    XCTAssertEqual(try jsonObject(preview.stdout)["removedVersionIds"] as? [String], [],
      "the current head, last import, and former heads from the last 24 hours remain protected")
    let pruned = await app.run(fixture.command("prune", "w", "--keep", "1", "--reason", "trim", "--output", "json"))
    XCTAssertEqual(pruned.exitCode, .success, pruned.stdout + pruned.stderr)
    XCTAssertNil(try jsonObject(pruned.stdout)["audit"], "no removal means no prune audit")

    let unconfirmed = await app.run(fixture.command("purge-history", "w", "--reason", "reset", "--output", "json"))
    XCTAssertEqual(unconfirmed.exitCode, .usage)
    let purged = await app.run(fixture.command("purge-history", "w", "--reason", "reset", "--yes", "--output", "json"))
    XCTAssertEqual(purged.exitCode, .success, purged.stdout + purged.stderr)
    let history = try jsonObjectArray(await app.run(fixture.command("history", "w", "--output", "json")).stdout)
    XCTAssertEqual(history.map { $0["operation"] as? String }, ["purgeHistory"])
    let shown = await app.run(fixture.command("show", "w", "--output", "json"))
    XCTAssertEqual(shown.exitCode, .success, shown.stderr)

    let all = await app.run(fixture.command("prune", "--all-workflows", "--keep", "1", "--reason", "sweep", "--output", "json"))
    XCTAssertEqual(all.exitCode, .success, all.stdout + all.stderr)
    XCTAssertEqual(try jsonObjectArray(all.stdout).map { $0["workflowName"] as? String }, ["w"])
  }

  func testDefinitionCLIEnumeratesAllOperationsAndRejectsBadGrammar() async throws {
    let expected = ["history", "show", "diff", "update", "update-prompt", "restore", "undo", "redo", "import", "export", "prune", "purge-history"]
    let commands = CLISurfaceEnumerator.commands().map(\.command)
    for operation in expected {
      XCTAssertTrue(commands.contains("workflow definition \(operation)"), operation)
    }
    XCTAssertEqual(commands.filter { $0.hasPrefix("workflow definition ") }.count, expected.count)

    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let app = RielaCLIApplication()
    let both = await app.run(fixture.command("update", "w", "--patch", "p", "--from-file", "f", "--reason", "r", "--output", "json"))
    XCTAssertEqual(both.exitCode, .usage)
    XCTAssertEqual(try errorCode(both.stdout), "usage_error")
    let sourceExport = await app.run(fixture.command("export", "w", "--to-source", "--output", "json"))
    XCTAssertEqual(sourceExport.exitCode, .usage)
    let actorKind = await app.run(fixture.command(
      "update-prompt", "w", "--node", "worker", "--field", "promptTemplate", "--text", "x", "--reason", "r", "--actor-kind", "user", "--output", "json"
    ))
    XCTAssertEqual(actorKind.exitCode, .usage)
  }

  private struct Fixture {
    var root: URL
    var workflowRoot: URL
    var workflow: URL
    var prompt: URL
    var store: URL

    func command(_ tokens: String...) -> [String] {
      var arguments = ["workflow", "definition"] + tokens
      if tokens.first == "import" {
        arguments += ["--workflow-definition-dir", workflowRoot.path]
      }
      arguments += ["--session-store", store.path, "--working-dir", root.path]
      return arguments
    }
  }

  private func makeFixture() throws -> Fixture {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/ds179/cli-definition-\(UUID().uuidString)", isDirectory: true)
    let workflowRoot = root.appendingPathComponent("workflows", isDirectory: true)
    let workflowDir = workflowRoot.appendingPathComponent("w", isDirectory: true)
    let nodeDir = workflowDir.appendingPathComponent("nodes", isDirectory: true)
    let promptDir = workflowDir.appendingPathComponent("prompts", isDirectory: true)
    let store = root.appendingPathComponent("store", isDirectory: true)
    try FileManager.default.createDirectory(at: nodeDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: promptDir, withIntermediateDirectories: true)
    let workflow = #"""
      {
        "workflowId": "w",
        "defaults": {"maxLoopIterations": 1, "nodeTimeoutMs": 30000},
        "entryStepId": "work",
        "nodeRegistry": [{"id": "worker", "nodeFile": "nodes/worker.json"}],
        "steps": [{"id": "work", "nodeId": "worker", "role": "worker"}],
        "nodes": [{"id": "worker", "nodeFile": "nodes/worker.json"}]
      }
      """#
    try workflow.write(to: workflowDir.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    let node = #"{"id":"worker","executionBackend":"codex-agent","model":"test-model","promptTemplateFile":"prompts/a.md","variables":{}}"#
    try node.write(to: nodeDir.appendingPathComponent("worker.json"), atomically: true, encoding: .utf8)
    let prompt = promptDir.appendingPathComponent("a.md")
    try "original prompt".write(to: prompt, atomically: true, encoding: .utf8)
    return Fixture(root: root, workflowRoot: workflowRoot, workflow: workflowDir.appendingPathComponent("workflow.json"), prompt: prompt, store: store)
  }

  private func jsonObject(_ text: String) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
  }

  private func jsonObjectArray(_ text: String) throws -> [[String: Any]] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
  }

  private func errorCode(_ text: String) throws -> String? {
    try jsonObject(text)["error"].flatMap { ($0 as? [String: Any])?["code"] as? String }
  }

  private func rowCounts(storeRoot: URL) throws -> [Int] {
    let database = try SQLiteDatabase.open(
      path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: storeRoot.path),
      mode: .strictReadOnly,
      options: .readOnlyDefault
    )
    return try ["definition_history_versions", "definition_versions", "definition_heads", "definition_change_audit"].map { table in
      Int(try XCTUnwrap(database.query("SELECT COUNT(*) AS count FROM \(table)").first?["count"])) ?? -1
    }
  }
}
