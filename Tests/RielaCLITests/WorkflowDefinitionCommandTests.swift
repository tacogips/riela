import Foundation
import XCTest
@testable import RielaCLI
import RielaCore
import RielaSQLite
import RielaWorkflowRegistry

final class WorkflowDefinitionCommandTests: XCTestCase {
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

  func testDefinitionCLIEnumeratesAllEightOperationsAndRejectsBadGrammar() async throws {
    let expected = ["history", "show", "diff", "update", "update-prompt", "restore", "import", "export"]
    let commands = CLISurfaceEnumerator.commands().map(\.command)
    for operation in expected {
      XCTAssertTrue(commands.contains("workflow definition \(operation)"), operation)
    }
    XCTAssertEqual(commands.filter { $0.hasPrefix("workflow definition ") }.count, 8)

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
    return try ["definition_blobs", "definition_versions", "definition_heads", "definition_change_audit"].map { table in
      Int(try XCTUnwrap(database.query("SELECT COUNT(*) AS count FROM \(table)").first?["count"])) ?? -1
    }
  }
}
