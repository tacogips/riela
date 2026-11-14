import Foundation
import RielaCore
import RielaSQLite
import RielaWorkflowRegistry
import XCTest
@testable import RielaCLI

final class WorkflowDefinitionSourceDriftTests: XCTestCase {
  private let actor = WorkflowDefinitionActor(kind: .api, id: "test-service")

  func testClassificationOrderAndLegacyFallback() {
    func classify(_ file: String?, _ problem: WorkflowDefinitionSourceDriftResult?, _ baseline: String?,
                  _ current: String, _ untouched: Bool, _ operation: WorkflowDefinitionOperation) -> WorkflowDefinitionSourceDriftResult {
      WorkflowDefinitionSourceDrift.classify(fileDigest: file, fileProblem: problem, baselineDigest: baseline,
        currentDigest: current, currentVersionId: untouched ? "v1" : "v2", lastFileVersionId: "v1", currentOperation: operation)
    }
    XCTAssertEqual(classify("same", .sourceInvalid, "same", "same", true, .seed), .sourceInvalid)
    XCTAssertEqual(classify(nil, .sourceUnavailable, nil, "current", true, .seed), .sourceUnavailable)
    XCTAssertEqual(classify("base", nil, "base", "current", false, .update), .inSync)
    XCTAssertEqual(classify("current", nil, "base", "current", false, .update), .inSync)
    XCTAssertEqual(classify("file", nil, "base", "current", true, .seed), .autoSync)
    XCTAssertEqual(classify("file", nil, "base", "current", false, .update), .drift)
    let fileOperations: [WorkflowDefinitionOperation] = [.seed, .import, .forceUpdate]
    for operation in fileOperations {
      XCTAssertEqual(classify("file", nil, nil, "current", true, operation), .autoSync)
      XCTAssertEqual(classify("file", nil, nil, "current", false, operation), .drift)
    }
    XCTAssertEqual(classify("file", nil, nil, "current", true, .update), .drift)
  }

  func testAutoSyncAndRepeatedCall() throws {
    let fixture = try makeFixture()
    try fixture.editTimeout()
    let outcome = try sync(fixture)
    XCTAssertEqual(outcome.report.result, .autoSync)
    let version = try XCTUnwrap(outcome.syncedVersion)
    XCTAssertEqual(version.operation, .import)
    let head = try XCTUnwrap(fixture.store.head(workflowName: "service-flow"))
    XCTAssertEqual(head.currentVersionId, version.versionId)
    XCTAssertEqual(head.lastFileVersionId, version.versionId)
    let document = try fixture.service.show(workflowName: "service-flow", versionId: version.versionId).document
    XCTAssertEqual(document.runtime.workflow.defaults.nodeTimeoutMs, 21600000)
    XCTAssertTrue(try XCTUnwrap(document.authoredFiles["workflow.json"]).contains("21600000"))
    let audit = try XCTUnwrap(outcome.audit)
    XCTAssertEqual(audit.actor, .init(kind: .api, id: "service-auto-sync"))
    XCTAssertTrue(audit.reason.hasPrefix("auto-synced from"))
    XCTAssertFalse(audit.diff.isEmpty)
    XCTAssertEqual(outcome.diagnostics.map(\.path), ["definitionStore.autoSynced"])
    let count = try fixture.history.count
    let again = try sync(fixture)
    XCTAssertEqual(again.report.result, .inSync)
    XCTAssertTrue(again.diagnostics.isEmpty)
    XCTAssertEqual(try fixture.history.count, count)
  }

  func testEditedAndUndoneHeadsAreNotOverwritten() throws {
    let fixture = try makeFixture()
    let first = try fixture.editPrompt("edited one")
    try fixture.editTimeout()
    let before = try fixture.history.count
    let drift = try sync(fixture)
    XCTAssertEqual(drift.report.result, .drift)
    XCTAssertEqual(drift.bundle.definitionSource?.versionId, first.versionId)
    XCTAssertEqual(try fixture.history.count, before)
    let message = try XCTUnwrap(drift.diagnostics.first?.message)
    for command in ["riela workflow definition diff service-flow --file", "riela instance reload",
                    "riela workflow definition import service-flow --force --reason",
                    "riela workflow definition export service-flow --to-source --overwrite"] {
      XCTAssertTrue(message.contains(command), message)
    }
    _ = try fixture.editPrompt("edited two")
    _ = try fixture.service.undo(workflowName: "service-flow", reason: "undo", evidence: [], actor: actor)
    let count = try fixture.history.count
    let undone = try sync(fixture)
    XCTAssertEqual(undone.report.result, .drift)
    XCTAssertEqual(undone.bundle.definitionSource?.versionId, first.versionId)
    XCTAssertEqual(try fixture.history.count, count)
  }

  func testInvalidAndUnavailableSourcesKeepStoredHead() throws {
    let fixture = try makeFixture()
    let head = try XCTUnwrap(fixture.store.head(workflowName: "service-flow"))
    let count = try fixture.history.count
    let original = try String(contentsOf: fixture.workflowFile, encoding: .utf8)
    for contents in ["{", original.replacingOccurrences(of: "service-flow", with: "other-flow")] {
      try contents.write(to: fixture.workflowFile, atomically: true, encoding: .utf8)
      let result = try sync(fixture)
      XCTAssertEqual(result.report.result, .sourceInvalid)
      XCTAssertEqual(result.diagnostics.first?.path, "definitionStore.sourceInvalid")
      XCTAssertEqual(result.bundle.definitionSource?.versionId, head.currentVersionId)
      XCTAssertEqual(try fixture.history.count, count)
    }
    try FileManager.default.removeItem(at: fixture.workflow)
    let missing = try sync(fixture)
    XCTAssertEqual(missing.report.result, .sourceUnavailable)
    XCTAssertEqual(missing.diagnostics.first?.path, "definitionStore.sourceUnavailable")
    XCTAssertEqual(missing.bundle.definitionSource?.versionId, head.currentVersionId)
    XCTAssertEqual(try fixture.history.count, count)
  }

  func testForceImportThenEditAndNonForceRegression() throws {
    let fixture = try makeFixture()
    try fixture.editTimeout()
    let before = try fixture.history.count
    let differs = try fixture.service.importDefinition(resolution: fixture.options, force: false, reason: nil, evidence: [], actor: actor)
    XCTAssertEqual(differs.outcome, .differs)
    XCTAssertEqual(try fixture.history.count, before)
    _ = try fixture.service.importDefinition(resolution: fixture.options, force: true, reason: "force", evidence: [], actor: actor)
    try fixture.replace("21600000", with: "22000000")
    XCTAssertEqual(try sync(fixture).report.result, .autoSync)
  }

  func testInspectionIsReadOnlyAndExplicitResolverOverridesPreparedResolver() throws {
    let fixture = try makeFixture()
    let stale = try XCTUnwrap(fixture.service.lookup(workflowName: "service-flow"))
    try fixture.editTimeout()
    let before = try fixture.rowCounts()
    let report = try fixture.service.inspectSourceDrift(workflowName: "service-flow", workingDirectory: fixture.root.path,
      fileResolver: FileSystemWorkflowBundleResolver())
    XCTAssertEqual(report?.result, .autoSync)
    XCTAssertEqual(try fixture.rowCounts(), before)
    let prepared = WorkflowDefinitionService(storeRoot: fixture.storeRoot.path, fileResolver: DriftTestResolver { _ in stale })
    let result = try XCTUnwrap(prepared.syncFromSourceIfUntouched(workflowName: "service-flow", workingDirectory: fixture.root.path,
      actor: actor, fileResolver: FileSystemWorkflowBundleResolver()))
    XCTAssertEqual(result.bundle.workflow.defaults.nodeTimeoutMs, 21600000)
    let version = try XCTUnwrap(result.syncedVersion)
    let document = try prepared.show(workflowName: "service-flow", versionId: version.versionId).document
    XCTAssertTrue(try XCTUnwrap(document.authoredFiles["workflow.json"]).contains("21600000"))
  }

  func testConcurrentHeadMoveAndIdenticalSync() throws {
    let fixture = try makeFixture()
    try fixture.editTimeout()
    let concurrent = DriftTestResolver { options in
      let bundle = try FileSystemWorkflowBundleResolver().resolve(options)
      _ = try fixture.editPrompt("concurrent edit")
      return bundle
    }
    let result = try XCTUnwrap(fixture.service.syncFromSourceIfUntouched(workflowName: "service-flow", workingDirectory: fixture.root.path,
      actor: actor, fileResolver: concurrent))
    XCTAssertEqual(result.diagnostics.first?.path, "definitionStore.autoSyncConflict")
    XCTAssertEqual(result.bundle.nodePayloads["worker"]?.promptTemplate, "concurrent edit")
    XCTAssertEqual(result.bundle.definitionSource?.versionId, try fixture.store.head(workflowName: "service-flow")?.currentVersionId)

    let second = try makeFixture()
    try second.editTimeout()
    let identical = DriftTestResolver { options in
      let bundle = try FileSystemWorkflowBundleResolver().resolve(options)
      _ = try second.service.syncFromSourceIfUntouched(workflowName: "service-flow", workingDirectory: second.root.path,
        actor: .init(kind: .api), fileResolver: FileSystemWorkflowBundleResolver())
      return bundle
    }
    let matched = try XCTUnwrap(second.service.syncFromSourceIfUntouched(workflowName: "service-flow", workingDirectory: second.root.path,
      actor: actor, fileResolver: identical))
    XCTAssertTrue(matched.diagnostics.isEmpty)
    XCTAssertEqual(try second.history.filter { $0.operation == .import }.count, 1)
  }

  private func sync(_ fixture: DriftFixture) throws -> WorkflowDefinitionSourceSyncOutcome {
    try XCTUnwrap(fixture.service.syncFromSourceIfUntouched(workflowName: "service-flow", workingDirectory: fixture.root.path,
      actor: actor, fileResolver: FileSystemWorkflowBundleResolver()))
  }

  private func makeFixture() throws -> DriftFixture {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(
      "tmp/stale-definition/sdwd-02-source-drift-service/fixture-\(UUID().uuidString)")
    let workflow = root.appendingPathComponent("service-flow")
    try FileManager.default.createDirectory(at: workflow.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    try #"""
      {"workflowId":"service-flow","entryStepId":"work","defaults":{"nodeTimeoutMs":3300000,"maxLoopIterations":1},
      "nodes":[{"id":"worker","nodeFile":"nodes/worker.json"}],"steps":[{"id":"work","nodeId":"worker","role":"worker"}]}
      """#
      .write(to: workflow.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try #"{"id":"worker","executionBackend":"codex-agent","agentSandbox":"read-only","model":"test-model","modelFreeze":false,"promptTemplate":"original","output":{"description":"Return a result."}}"#
      .write(to: workflow.appendingPathComponent("nodes/worker.json"), atomically: true, encoding: .utf8)
    let fixture = DriftFixture(root: root, workflow: workflow, storeRoot: root.appendingPathComponent("store"))
    let bundle = try FileSystemWorkflowBundleResolver().resolve(fixture.options)
    _ = try fixture.service.seedIfAbsent(fileBundle: bundle, workflowName: "service-flow", actor: actor)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return fixture
  }
}

private struct DriftFixture: Sendable {
  let root: URL
  let workflow: URL
  let storeRoot: URL
  var workflowFile: URL { workflow.appendingPathComponent("workflow.json") }
  var options: WorkflowResolutionOptions {
    WorkflowResolutionOptions(workflowName: "service-flow", workflowDefinitionDir: workflow.path, workingDirectory: root.path)
  }
  var store: WorkflowDefinitionStore { WorkflowDefinitionStore(rootDirectory: storeRoot.path) }
  var service: WorkflowDefinitionService {
    WorkflowDefinitionService(storeRoot: storeRoot.path, fileResolver: FileSystemWorkflowBundleResolver())
  }
  var history: [WorkflowDefinitionAuditRecord] { get throws { try store.history(workflowName: "service-flow") } }
  func replace(_ old: String, with new: String) throws {
    let text = try String(contentsOf: workflowFile, encoding: .utf8).replacingOccurrences(of: old, with: new)
    try text.write(to: workflowFile, atomically: true, encoding: .utf8)
  }
  func editTimeout() throws { try replace("3300000", with: "21600000") }
  func editPrompt(_ text: String) throws -> WorkflowDefinitionVersion {
    try service.updatePrompt(workflowName: "service-flow", nodeId: "worker", field: .init(parsing: "promptTemplate"),
      text: text, reason: "test edit", expectedVersionId: nil, evidence: [], actor: .init(kind: .user)).0
  }
  func rowCounts() throws -> [Int] {
    let database = try SQLiteDatabase.open(path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: storeRoot.path),
      mode: .strictReadOnly, options: .readOnlyDefault)
    return try ["definition_history_versions", "definition_versions", "definition_heads", "definition_change_audit"].map { table in
      Int(try XCTUnwrap(database.query("SELECT COUNT(*) AS count FROM \(table)").first?["count"])) ?? -1
    }
  }
}

private struct DriftTestResolver: WorkflowBundleResolving {
  let body: @Sendable (WorkflowResolutionOptions) throws -> ResolvedWorkflowBundle
  func resolve(_ options: WorkflowResolutionOptions) throws -> ResolvedWorkflowBundle { try body(options) }
}
