import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaCore
@testable import RielaWorkflowRegistry

final class WorkflowDefinitionServiceTests: XCTestCase {
  func testDocumentRoundTripsAndResolvesStoreSource() throws {
    let fixture = try makeFixture()
    let bundle = try fixture.resolver.resolve(fixture.options)
    let document = try WorkflowDefinitionDocument.make(from: bundle)
    let decoded = try WorkflowDefinitionDocument.decode(document.canonicalData())
    XCTAssertEqual(decoded, document)
    let authoredView = try decoded.authoredView()
    guard case let .object(authoredFiles) = authoredView,
          case let .object(workflowFile)? = authoredFiles["workflow.json"] else {
      return XCTFail("workflow.json should be parsed in authored view")
    }
    XCTAssertEqual(workflowFile["workflowId"], .string("service-flow"))
    let store = WorkflowDefinitionStore(rootDirectory: fixture.storeRoot.path)
    let outcome = try store.commit(WorkflowDefinitionWrite(
      workflowName: "service-flow",
      operation: .seed,
      documentData: try document.canonicalData(),
      documentDigest: try document.digest(),
      sourceDirectory: bundle.workflowDirectory,
      sourceScope: bundle.sourceScope.rawValue,
      provenance: bundle.provenance.rawValue,
      actor: WorkflowDefinitionActor(kind: .user),
      reason: "seed"
    ))
    guard case let .created(version, _) = outcome else { return XCTFail("seed should create a version") }
    let resolved = decoded.resolvedBundle(head: try store.head(workflowName: "service-flow"), version: version, storeRoot: fixture.storeRoot.path)
    XCTAssertEqual(resolved.workflow, bundle.workflow)
    XCTAssertEqual(resolved.nodePayloads, bundle.nodePayloads)
    XCTAssertEqual(resolved.definitionSource?.kind, .store)
    XCTAssertEqual(resolved.definitionSource?.storeRoot, fixture.storeRoot.standardizedFileURL.path)
  }

  func testRestoreRequiresRetainedVersionAndAcceptsRetainedVersion() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let clock = ServiceTestClock(Date())
    let service = WorkflowDefinitionService(storeRoot: fixture.storeRoot.path,
      fileResolver: FileSystemWorkflowBundleResolver(), now: { clock.now })
    _ = try service.importDefinition(resolution: fixture.options, force: false, reason: nil,
      evidence: [], actor: WorkflowDefinitionActor(kind: .user))
    var previousVersionId = try XCTUnwrap(WorkflowDefinitionStore(rootDirectory: fixture.storeRoot.path)
      .head(workflowName: "service-flow")?.currentVersionId)
    var droppedVersionId: String?
    for number in 1...11 {
      clock.advance()
      let result = try service.updatePrompt(workflowName: "service-flow", nodeId: "worker",
        field: WorkflowDefinitionPromptField(parsing: "promptTemplate"), text: "retained-test-\(number)",
        reason: "advance definition window", expectedVersionId: previousVersionId, evidence: [],
        actor: WorkflowDefinitionActor(kind: .user))
      if number == 1 { droppedVersionId = result.0.versionId }
      previousVersionId = result.0.versionId
    }
    let store = WorkflowDefinitionStore(rootDirectory: fixture.storeRoot.path)
    let lastFileVersionId = try XCTUnwrap(store.head(workflowName: "service-flow")?.lastFileVersionId)
    XCTAssertNoThrow(try service.restore(workflowName: "service-flow", versionId: lastFileVersionId,
      reason: "restore retained source", evidence: [], actor: WorkflowDefinitionActor(kind: .user)))
    XCTAssertThrowsError(try service.restore(workflowName: "service-flow", versionId: try XCTUnwrap(droppedVersionId),
      reason: "restore expired version", evidence: [], actor: WorkflowDefinitionActor(kind: .user))) { error in
      XCTAssertEqual((error as? WorkflowDefinitionStoreError)?.code, .versionNotRetained)
      XCTAssertEqual((error as? WorkflowDefinitionStoreError)?.code.rawValue, "definition_version_not_retained")
    }
  }

  func testServiceUndoRedoMovesDefinitionHeadAndRecordsAudits() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let service = fixture.service
    _ = try service.importDefinition(resolution: fixture.options, force: false, reason: nil,
      evidence: [], actor: WorkflowDefinitionActor(kind: .user))
    let initial = try service.show(workflowName: "service-flow", versionId: nil).version
    let update = try service.updatePrompt(workflowName: "service-flow", nodeId: "worker",
      field: WorkflowDefinitionPromptField(parsing: "promptTemplate"), text: "undo-redo-value",
      reason: "update before undo", expectedVersionId: initial.versionId, evidence: [], actor: .init(kind: .user))
    let undone = try service.undo(workflowName: "service-flow", reason: "undo update", evidence: [], actor: .init(kind: .user),
      expectedRevision: 2, expectedVersionId: update.0.versionId)
    XCTAssertEqual(undone.audit.operation, .undo)
    XCTAssertEqual(undone.revision, 3)
    XCTAssertEqual(try service.lookup(workflowName: "service-flow")?.nodePayloads["worker"]?.promptTemplate, "original prompt")
    let redone = try service.redo(workflowName: "service-flow", reason: "redo update", evidence: [], actor: .init(kind: .user),
      expectedRevision: 3, expectedVersionId: initial.versionId)
    XCTAssertEqual(redone.audit.operation, .redo)
    XCTAssertEqual(redone.revision, 4)
    XCTAssertEqual(try service.lookup(workflowName: "service-flow")?.nodePayloads["worker"]?.promptTemplate, "undo-redo-value")
  }

  func testCanonicalNodeDashFilesRoundTripAndStayContained() throws {
    let fixture = try makeFixture()
    let workflowURL = fixture.workflowDirectory.appendingPathComponent("workflow.json")
    let workflowText = try String(contentsOf: workflowURL, encoding: .utf8)
      .replacingOccurrences(of: "nodes/worker.json", with: "nodes/node-worker.json")
      .replacingOccurrences(of: "nodes/inline.json", with: "nodes/node-inline.json")
    try workflowText.write(to: workflowURL, atomically: true, encoding: .utf8)
    for nodeId in ["worker", "inline"] {
      try FileManager.default.moveItem(
        at: fixture.workflowDirectory.appendingPathComponent("nodes/\(nodeId).json"),
        to: fixture.workflowDirectory.appendingPathComponent("nodes/node-\(nodeId).json")
      )
    }

    let service = fixture.service
    let seeded = try service.importDefinition(
      resolution: fixture.options,
      force: false,
      reason: nil,
      evidence: [],
      actor: .init(kind: .cli)
    )
    XCTAssertEqual(seeded.outcome, .seeded)
    let initialDocument = try service.show(workflowName: "service-flow", versionId: nil).document
    XCTAssertNotNil(initialDocument.authoredFiles["nodes/node-worker.json"])
    XCTAssertNotNil(initialDocument.authoredFiles["nodes/node-inline.json"])

    let workerUpdate = try service.updatePrompt(
      workflowName: "service-flow",
      nodeId: "worker",
      field: .init(parsing: "promptTemplate"),
      text: "updated file prompt",
      reason: "canonical node filename regression",
      expectedVersionId: nil,
      evidence: [],
      actor: .init(kind: .cli)
    )
    XCTAssertEqual(workerUpdate.1.operation, .updatePrompt)
    XCTAssertEqual(try service.lookup(workflowName: "service-flow")?.nodePayloads["worker"]?.promptTemplate, "updated file prompt")
    let inlineUpdate = try service.updatePrompt(
      workflowName: "service-flow",
      nodeId: "inline",
      field: .init(parsing: "promptTemplate"),
      text: "updated inline prompt",
      reason: "canonical node filename regression",
      expectedVersionId: nil,
      evidence: [],
      actor: .init(kind: .cli)
    )
    XCTAssertEqual(inlineUpdate.1.operation, .updatePrompt)
    XCTAssertEqual(try service.lookup(workflowName: "service-flow")?.nodePayloads["inline"]?.promptTemplate, "updated inline prompt")
    let patch = JSONValue.array([.object([
      "op": .string("replace"),
      "path": .string("/nodes~1node-inline.json/promptTemplate"),
      "value": .string("patched inline prompt")
    ])])
    let patched = try service.update(
      workflowName: "service-flow",
      source: .patch(patch),
      reason: "canonical node filename patch",
      expectedVersionId: nil,
      evidence: [],
      actor: .init(kind: .cli)
    )
    XCTAssertEqual(patched.outcome, .updated)

    let exportDirectory = fixture.root.appendingPathComponent("canonical-export", isDirectory: true)
    let exported = try service.export(
      workflowName: "service-flow",
      versionId: nil,
      target: .directory(exportDirectory.path)
    )
    let storedFiles = try service.show(workflowName: "service-flow", versionId: nil).document.authoredFiles
    XCTAssertEqual(Dictionary(uniqueKeysWithValues: exported.map { ($0.path, $0.content) }), storedFiles)
    XCTAssertTrue(exported.contains { $0.path == "nodes/node-worker.json" })
    for file in exported {
      let diskBytes = try Data(contentsOf: exportDirectory.appendingPathComponent(file.path))
      XCTAssertEqual(diskBytes, Data(file.content.utf8), "exported bytes should match authored file \(file.path)")
    }
    let exportedBundle = try FileSystemWorkflowBundleResolver().resolve(WorkflowResolutionOptions(
      workflowName: "service-flow",
      scope: .direct,
      workflowDefinitionDir: exportDirectory.path,
      workingDirectory: fixture.root.path
    ))
    XCTAssertEqual(exportedBundle.nodePayloads["inline"]?.promptTemplate, "patched inline prompt")

    let originalBundle = try fixture.resolver.resolve(fixture.options)
    let originalDigest = WorkflowDefinitionDocument.fileDefinitionSource(for: originalBundle, workflowName: "service-flow").digest
    let workerFile = fixture.workflowDirectory.appendingPathComponent("nodes/node-worker.json")
    let workerText = try String(contentsOf: workerFile, encoding: .utf8)
    try (workerText + "\n").write(to: workerFile, atomically: true, encoding: .utf8)
    let changedBundle = try fixture.resolver.resolve(fixture.options)
    let changedDigest = WorkflowDefinitionDocument.fileDefinitionSource(for: changedBundle, workflowName: "service-flow").digest
    XCTAssertNotEqual(changedDigest, originalDigest)

    var invalidBundle = try fixture.resolver.resolve(fixture.options)
    invalidBundle.workflow.nodeRegistry[0].nodeFile = "../outside.json"
    XCTAssertThrowsError(try WorkflowDefinitionDocument.make(from: invalidBundle))
    invalidBundle.workflow.nodeRegistry[0].nodeFile = "/outside.json"
    XCTAssertThrowsError(try WorkflowDefinitionDocument.make(from: invalidBundle))
    let outsideFile = fixture.root.appendingPathComponent("outside.json")
    try "{}".write(to: outsideFile, atomically: true, encoding: .utf8)
    let escapeLink = fixture.workflowDirectory.appendingPathComponent("nodes/node-escape.json")
    try FileManager.default.createSymbolicLink(at: escapeLink, withDestinationURL: outsideFile)
    invalidBundle.workflow.nodeRegistry[0].nodeFile = "nodes/node-escape.json"
    XCTAssertThrowsError(try WorkflowDefinitionDocument.make(from: invalidBundle))

    try FileManager.default.removeItem(at: workerFile)
    try FileManager.default.createSymbolicLink(at: workerFile, withDestinationURL: outsideFile)
    XCTAssertThrowsError(try service.export(workflowName: "service-flow", versionId: nil, target: .source(overwrite: true)))
  }

  func testImportDiffForceOverwriteAndRestore() throws {
    let fixture = try makeFixture()
    let service = fixture.service
    let imported = try service.importDefinition(resolution: fixture.options, force: false, reason: nil, evidence: [], actor: .init(kind: .cli))
    XCTAssertEqual(imported.outcome, .seeded)
    let initialHistory = try service.history(workflowName: "service-flow", nodeId: nil, limit: nil)
    XCTAssertEqual(initialHistory.count, 1)
    XCTAssertEqual(try service.importDefinition(resolution: fixture.options, force: false, reason: nil, evidence: [], actor: .init(kind: .cli)).outcome, .unchanged)

    let promptResult = try service.updatePrompt(
      workflowName: "service-flow", nodeId: "worker", field: .init(parsing: "promptTemplate"), text: "stored prompt",
      reason: "improve prompt", expectedVersionId: nil, evidence: [.init(kind: .session, id: "s1")], actor: .init(kind: .user)
    )
    let shown = try service.show(workflowName: "service-flow", versionId: promptResult.0.versionId)
    XCTAssertEqual(shown.document.runtime.nodePayloads["worker"]?.promptTemplate, "stored prompt")
    XCTAssertTrue(try service.diff(workflowName: "service-flow", fromVersionId: imported.version?.versionId, toVersionId: promptResult.0.versionId, againstFile: nil)
      .contains { $0.path == "/authoredFiles/prompts~1a.md" })
    XCTAssertEqual(try service.history(workflowName: "service-flow", nodeId: "worker", limit: nil).count, 1)
    try "file changed".write(to: fixture.promptFile, atomically: true, encoding: .utf8)
    let beforeImportCount = try service.history(workflowName: "service-flow", nodeId: nil, limit: nil).count
    let differs = try service.importDefinition(resolution: fixture.options, force: false, reason: nil, evidence: [], actor: .init(kind: .cli))
    XCTAssertEqual(differs.outcome, .differs)
    XCTAssertEqual(try service.history(workflowName: "service-flow", nodeId: nil, limit: nil).count, beforeImportCount)

    XCTAssertThrowsError(try service.importDefinition(resolution: fixture.options, force: true, reason: "  ", evidence: [], actor: .init(kind: .cli))) {
      XCTAssertEqual(($0 as? WorkflowDefinitionServiceError)?.code, .reasonRequired)
    }
    XCTAssertEqual(try service.history(workflowName: "service-flow", nodeId: nil, limit: nil).count, beforeImportCount)

    let forced = try service.importDefinition(resolution: fixture.options, force: true, reason: "replace from files", evidence: [], actor: .init(kind: .cli))
    XCTAssertEqual(forced.outcome, .forceUpdated)
    XCTAssertTrue(forced.audit?.overwrittenChanges?.auditIds.contains(promptResult.1.auditId) == true)
    let restored = try service.restore(workflowName: "service-flow", versionId: promptResult.0.versionId, reason: "restore prompt", evidence: [], actor: .init(kind: .user))
    XCTAssertEqual(try service.lookup(workflowName: "service-flow")?.nodePayloads["worker"]?.promptTemplate, "stored prompt")
    XCTAssertEqual(restored.1.operation, .restore)
    let sameHead = try service.restore(workflowName: "service-flow", versionId: restored.0.versionId,
      reason: "restore current bytes", evidence: [], actor: .init(kind: .user))
    XCTAssertEqual(sameHead.1.operation, .restore)
    XCTAssertEqual(try WorkflowDefinitionStore(rootDirectory: fixture.storeRoot.path).history(workflowName: "service-flow").first?.operation, .restore)
  }

  func testUpdateUsesAuthoredOverlayAndRejectsWithoutRows() throws {
    let fixture = try makeFixture()
    _ = try fixture.service.importDefinition(resolution: fixture.options, force: false, reason: nil, evidence: [], actor: .init(kind: .cli))
    let current = try XCTUnwrap(try WorkflowDefinitionStore(rootDirectory: fixture.storeRoot.path).current(workflowName: "service-flow"))
    let patch: JSONValue = .array([.object([
      "op": .string("replace"), "path": .string("/prompts~1a.md"), "value": .string("updated in store")
    ])])
    let result = try fixture.service.update(
      workflowName: "service-flow", source: .patch(patch), reason: "whole workflow edit", expectedVersionId: current.version.versionId,
      evidence: [.init(kind: .session, id: "s1"), .init(kind: .stepExecution, id: "e1")], actor: .init(kind: .cli, id: "tester")
    )
    XCTAssertEqual(result.outcome, .updated)
    XCTAssertEqual(try String(contentsOf: fixture.promptFile, encoding: .utf8), "original prompt")
    XCTAssertEqual(try fixture.service.lookup(workflowName: "service-flow")?.nodePayloads["worker"]?.promptTemplate, "updated in store")
    XCTAssertEqual(result.audit?.evidence, [.init(kind: .session, id: "s1"), .init(kind: .stepExecution, id: "e1")])
    let authored = try fixture.service.authoredView(workflowName: "service-flow", versionId: nil)
    guard case let .object(authoredFiles) = authored.view else { return XCTFail("authored view should be an object") }
    XCTAssertEqual(authoredFiles["prompts/a.md"], .string("updated in store"))

    let noOpPatch: JSONValue = .array([.object([
      "op": .string("replace"), "path": .string("/prompts~1a.md"), "value": .string("updated in store")
    ])])
    let noOp = try fixture.service.update(workflowName: "service-flow", source: .patch(noOpPatch), reason: "no change", expectedVersionId: nil,
                                          evidence: [], actor: .init(kind: .cli))
    XCTAssertEqual(noOp.outcome, .unchanged)
    XCTAssertNil(noOp.audit)

    let count = try fixture.service.history(workflowName: "service-flow", nodeId: nil, limit: nil).count
    XCTAssertThrowsError(try fixture.service.update(
      workflowName: "service-flow", source: .patch(.array([])), reason: "  ", expectedVersionId: nil,
      evidence: [], actor: .init(kind: .cli)
    )) { error in
      XCTAssertEqual((error as? WorkflowDefinitionServiceError)?.code, .reasonRequired)
    }
    XCTAssertEqual(try fixture.service.history(workflowName: "service-flow", nodeId: nil, limit: nil).count, count)

    XCTAssertThrowsError(try fixture.service.update(
      workflowName: "service-flow",
      source: .patch(.array([.object(["op": .string("test"), "path": .string("/prompts~1a.md"), "value": .string("wrong")])])),
      reason: "failed test", expectedVersionId: nil, evidence: [], actor: .init(kind: .cli)
    )) { error in
      XCTAssertEqual((error as? WorkflowDefinitionServiceError)?.code, .invalidPatch)
    }
    XCTAssertThrowsError(try fixture.service.update(
      workflowName: "service-flow", source: .patch(.array([])), reason: "stale", expectedVersionId: current.version.versionId,
      evidence: [], actor: .init(kind: .cli)
    )) { error in
      XCTAssertEqual((error as? WorkflowDefinitionServiceError)?.code, .definitionConflict)
    }
    XCTAssertEqual(try fixture.service.history(workflowName: "service-flow", nodeId: nil, limit: nil).count, count)
  }

  func testExportAndFromDirectoryUpdate() throws {
    let fixture = try makeFixture()
    _ = try fixture.service.importDefinition(resolution: fixture.options, force: false, reason: nil, evidence: [], actor: .init(kind: .cli))
    let exportDirectory = fixture.root.appendingPathComponent("exported-flow", isDirectory: true).path
    let output = try fixture.service.export(workflowName: "service-flow", versionId: nil, target: .directory(exportDirectory))
    XCTAssertTrue(output.contains { $0.path == "workflow.json" })
    let authoredFiles = try fixture.service.show(workflowName: "service-flow", versionId: nil).document.authoredFiles
    XCTAssertEqual(Dictionary(uniqueKeysWithValues: output.map { ($0.path, $0.content) }), authoredFiles)
    let exportedPrompt = URL(fileURLWithPath: exportDirectory).appendingPathComponent("prompts/a.md")
    try "from directory".write(to: exportedPrompt, atomically: true, encoding: .utf8)
    let options = WorkflowResolutionOptions(
      workflowName: "service-flow",
      scope: .direct,
      workflowDefinitionDir: exportDirectory,
      workingDirectory: fixture.root.path
    )
    let result = try fixture.service.update(workflowName: "service-flow", source: .fromDirectory(options), reason: "import exported edit",
                                            expectedVersionId: nil, evidence: [], actor: .init(kind: .cli))
    XCTAssertEqual(result.outcome, .updated)
    XCTAssertEqual(try fixture.service.lookup(workflowName: "service-flow")?.nodePayloads["worker"]?.promptTemplate, "from directory")
    let runnerPath = try XCTUnwrap(
      fixture.service.lookup(workflowName: "service-flow")?.nodePayloads["runner"]?.command?.executable
    )
    XCTAssertEqual(
      URL(fileURLWithPath: runnerPath).standardizedFileURL.path,
      fixture.workflowDirectory.appendingPathComponent("scripts/run.sh").standardizedFileURL.path
    )
    _ = try fixture.service.export(workflowName: "service-flow", versionId: nil, target: .source(overwrite: true))
    XCTAssertEqual(try fixture.service.importDefinition(resolution: fixture.options, force: false, reason: nil, evidence: [], actor: .init(kind: .cli)).outcome, .unchanged)
    XCTAssertThrowsError(try fixture.service.export(workflowName: "service-flow", versionId: nil, target: .directory(exportDirectory)))
  }

  func testAuthoredOverlayNeverFallsBackToDiskAndNormalizesKeys() throws {
    let fixture = try makeFixture()
    let workflow = try String(contentsOf: fixture.workflowDirectory.appendingPathComponent("workflow.json"), encoding: .utf8)
    let nodeFiles = try ["worker", "inline", "runner", "sharer"].reduce(into: [String: String]()) { files, nodeId in
      files["nodes/\(nodeId).json"] = try String(
        contentsOf: fixture.workflowDirectory.appendingPathComponent("nodes/\(nodeId).json"), encoding: .utf8
      )
    }
    var overlayFiles = nodeFiles
    overlayFiles["./workflow.json"] = workflow
    overlayFiles["prompts/shared.md"] = try String(
      contentsOf: fixture.workflowDirectory.appendingPathComponent("prompts/shared.md"), encoding: .utf8
    )
    overlayFiles.removeValue(forKey: "nodes/worker.json")
    overlayFiles["nodes/./worker.json"] = nodeFiles["nodes/worker.json"]
    let overlay = try WorkflowAuthoredFileOverlay(files: overlayFiles)
    XCTAssertEqual(overlay.files["workflow.json"], workflow)
    XCTAssertEqual(overlay.files["nodes/worker.json"], nodeFiles["nodes/worker.json"])
    XCTAssertThrowsError(try WorkflowAuthoredFileOverlay(files: ["a/b": "one", "a/./b": "two"]))
    let options = WorkflowResolutionOptions(
      workflowName: "service-flow",
      scope: .direct,
      workflowDefinitionDir: fixture.options.workflowDefinitionDir,
      workingDirectory: fixture.options.workingDirectory,
      authoredOverlay: overlay
    )
    XCTAssertThrowsError(try fixture.resolver.resolve(options)) { error in
      guard case let WorkflowResolutionError.invalidWorkflow(diagnostics) = error else {
        return XCTFail("expected missing prompt overlay diagnostic, got \(error)")
      }
      XCTAssertTrue(diagnostics.contains {
        $0.path == "node.promptTemplateFile" && $0.message.contains("promptTemplateFile 'prompts/a.md'")
      })
    }
  }

  func testJSONPatchArrayAndPointerOperations() throws {
    let source: JSONValue = .object(["items": .array([.string("a"), .string("c")]), "a/b": .string("old"), "til~de": .integer(1)])
    let patch: JSONValue = .array([
      .object(["op": .string("add"), "path": .string("/items/1"), "value": .string("b")]),
      .object(["op": .string("add"), "path": .string("/items/-"), "value": .string("d")]),
      .object(["op": .string("replace"), "path": .string("/a~1b"), "value": .string("new")]),
      .object(["op": .string("remove"), "path": .string("/til~0de")]),
      .object(["op": .string("test"), "path": .string("/a~1b"), "value": .string("new")])
    ])
    let value = try WorkflowDefinitionJSONPatch.apply(patch, to: source)
    XCTAssertEqual(value, .object(["items": .array([.string("a"), .string("b"), .string("c"), .string("d")]), "a/b": .string("new")]))
    XCTAssertThrowsError(try WorkflowDefinitionJSONPatch.apply(.array([.object([
      "op": .string("test"), "path": .string("/a~1b"), "value": .string("wrong")
    ])]), to: source)) { error in
      XCTAssertEqual((error as? WorkflowDefinitionServiceError)?.code, .invalidPatch)
    }
  }

  func testStructuralAndPromptPatchPreservesFilesAndForceAuditListsUpdate() throws {
    let fixture = try makeFixture()
    _ = try fixture.service.importDefinition(resolution: fixture.options, force: false, reason: nil, evidence: [], actor: .init(kind: .cli))
    let initial = try XCTUnwrap(try fixture.store.current(workflowName: "service-flow"))
    let beforeFiles = try authoredTreeDigests(at: fixture.workflowDirectory)
    let patch: JSONValue = .array([
      .object(["op": .string("replace"), "path": .string("/prompts~1a.md"), "value": .string("combined prompt")]),
      .object(["op": .string("replace"), "path": .string("/workflow.json/steps/0/transitions/0/toStepId"), "value": .string("third")])
    ])
    let update = try fixture.service.update(
      workflowName: "service-flow", source: .patch(patch), reason: "change prompt and route",
      expectedVersionId: initial.version.versionId,
      evidence: [.init(kind: .session, id: "session-1")], actor: .init(kind: .cli, id: "test")
    )
    XCTAssertEqual(update.outcome, .updated)
    XCTAssertEqual(update.audit?.operation, .update)
    XCTAssertTrue(update.audit?.diff.contains { $0.path == "/authoredFiles/prompts~1a.md" } == true)
    XCTAssertTrue(update.audit?.diff.contains {
      $0.path == "/runtime/workflow/steps/0/transitions/0/toStepId"
    } == true)
    let current = try XCTUnwrap(try fixture.store.current(workflowName: "service-flow"))
    XCTAssertEqual(current.head.lastFileVersionId, initial.head.lastFileVersionId)
    XCTAssertEqual(try authoredTreeDigests(at: fixture.workflowDirectory), beforeFiles)
    let bundle = try XCTUnwrap(fixture.service.lookup(workflowName: "service-flow"))
    XCTAssertEqual(bundle.nodePayloads["worker"]?.promptTemplate, "combined prompt")
    XCTAssertEqual(bundle.workflow.steps[0].transitions?.first?.toStepId, "third")

    try "file still original".write(to: fixture.promptFile, atomically: true, encoding: .utf8)
    let forced = try fixture.service.importDefinition(
      resolution: fixture.options, force: true, reason: "reset to files", evidence: [], actor: .init(kind: .cli)
    )
    XCTAssertTrue(forced.audit?.overwrittenChanges?.auditIds.contains(update.audit!.auditId) == true)
  }

  func testRejectedUpdatesWriteNoRows() throws {
    let fixture = try makeFixture()
    _ = try fixture.service.importDefinition(resolution: fixture.options, force: false, reason: nil, evidence: [], actor: .init(kind: .cli))
    try assertRejectedUpdate(
      fixture, source: .patch(.array([.object(["op": .string("remove"), "path": .string("/prompts~1a.md")])])),
      reason: "remove referenced prompt", code: .invalidDefinition
    )
    try assertRejectedUpdate(
      fixture, source: .patch(.array([.object([
        "op": .string("add"), "path": .string("/prompts~1orphan.md"), "value": .string("unused")
      ])])), reason: "add orphan prompt", code: .invalidDefinition
    )
    try assertRejectedUpdate(
      fixture, source: .patch(.array([.object([
        "op": .string("replace"), "path": .string("/workflow.json/entryStepId"), "value": .string("missing-step")
      ])])), reason: "invalid workflow", code: .invalidDefinition
    )
    try assertRejectedUpdate(
      fixture, source: .patch(.array([.object([
        "op": .string("replace"), "path": .string("/workflow.json/notAField"), "value": .string("x")
      ])])), reason: "replace missing member", code: .invalidPatch
    )
    try assertRejectedUpdate(
      fixture, source: .patch(.array([])), reason: "unsupported move",
      code: .invalidPatch, patchOperation: "move"
    )
    try assertRejectedUpdate(
      fixture, workflowName: "unregistered", source: .patch(.array([])),
      reason: "update unregistered workflow", code: .definitionNotRegistered
    )
  }

  func testUpdatePromptInlineSharedAndRejectedTargets() throws {
    let fixture = try makeFixture()
    _ = try fixture.service.importDefinition(resolution: fixture.options, force: false, reason: nil, evidence: [], actor: .init(kind: .cli))
    let promptField = try WorkflowDefinitionPromptField(parsing: "promptTemplate")
    let inline = try fixture.service.updatePrompt(
      workflowName: "service-flow", nodeId: "inline", field: promptField, text: "Y", reason: "edit inline",
      expectedVersionId: nil, evidence: [], actor: .init(kind: .user)
    )
    let inlineDocument = try fixture.service.show(workflowName: "service-flow", versionId: inline.0.versionId).document
    let inlineNode = try XCTUnwrap(inlineDocument.authoredFiles["nodes/inline.json"])
    XCTAssertEqual(try JSONDecoder().decode(AgentNodePayload.self, from: Data(inlineNode.utf8)).promptTemplate, "Y")
    let exportDirectory = fixture.root.appendingPathComponent("inline-export", isDirectory: true)
    _ = try fixture.service.export(workflowName: "service-flow", versionId: inline.0.versionId, target: .directory(exportDirectory.path))
    let reResolved = try fixture.resolver.resolve(WorkflowResolutionOptions(
      workflowName: "service-flow", scope: .direct, workflowDefinitionDir: exportDirectory.path, workingDirectory: fixture.root.path
    ))
    XCTAssertEqual(reResolved.nodePayloads["inline"]?.promptTemplate, "Y")

    let shared = try fixture.service.updatePrompt(
      workflowName: "service-flow", nodeId: "worker", field: .init(parsing: "systemPromptTemplate"), text: "shared update",
      reason: "edit shared prompt", expectedVersionId: nil, evidence: [], actor: .init(kind: .user)
    )
    let updated = try XCTUnwrap(fixture.service.lookup(workflowName: "service-flow"))
    XCTAssertEqual(updated.nodePayloads["worker"]?.systemPromptTemplate, "shared update")
    XCTAssertEqual(updated.nodePayloads["sharer"]?.promptTemplate, "shared update")
    XCTAssertTrue(shared.1.diff.contains { $0.path == "/runtime/nodePayloads/worker/systemPromptTemplate" })
    XCTAssertTrue(shared.1.diff.contains { $0.path == "/runtime/nodePayloads/sharer/promptTemplate" })

    try assertRejectedPrompt(fixture, nodeId: "worker", field: promptField, reason: "  ", code: .reasonRequired)
    try assertRejectedPrompt(fixture, nodeId: "missing-node", field: promptField, reason: "unknown node", code: .invalidDefinition)
    try assertRejectedPrompt(
      fixture, nodeId: "inline", field: .variant(key: "missing", .promptTemplate), reason: "unknown variant", code: .invalidDefinition
    )
    XCTAssertThrowsError(try WorkflowDefinitionPromptField(parsing: "bogus"))
  }

  func testUpdatePromptRejectsNodeRefWithoutRows() throws {
    let fixture = try makeFixture()
    let workflowURL = fixture.workflowDirectory.appendingPathComponent("workflow.json")
    var workflow = try String(contentsOf: workflowURL, encoding: .utf8)
    workflow = workflow.replacingOccurrences(
      of: #"{"id": "sharer", "nodeFile": "nodes/sharer.json"}"#,
      with: #"{"id": "sharer", "nodeFile": "nodes/sharer.json"}, {"id": "shared-ref", "nodeRef": {"workflowId": "shared-flow", "nodeId": "shared-worker"}}"#
    )
    try workflow.write(to: workflowURL, atomically: true, encoding: .utf8)
    let sharedDirectory = fixture.workflowDirectory.appendingPathComponent("shared-flow", isDirectory: true)
    try FileManager.default.createDirectory(at: sharedDirectory.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    try #"""
    {
      "workflowId": "shared-flow",
      "defaults": {"maxLoopIterations": 3, "nodeTimeoutMs": 120000},
      "entryStepId": "shared",
      "nodeRegistry": [{"id": "shared-worker", "nodeFile": "nodes/shared.json"}],
      "steps": [{"id": "shared", "nodeId": "shared-worker", "role": "worker"}],
      "nodes": [{"id": "shared-worker", "nodeFile": "nodes/shared.json"}]
    }
    """#
      .write(to: sharedDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try #"{"id":"shared-worker","executionBackend":"codex-agent","model":"model","promptTemplate":"external shared worker","variables":{}}"#
      .write(to: sharedDirectory.appendingPathComponent("nodes/shared.json"), atomically: true, encoding: .utf8)
    let options = WorkflowResolutionOptions(
      workflowName: "service-flow", scope: .direct, workflowDefinitionDir: fixture.workflowDirectory.path,
      workingDirectory: fixture.root.path
    )
    _ = try fixture.service.importDefinition(resolution: options, force: false, reason: nil, evidence: [], actor: .init(kind: .cli))
    try assertRejectedPrompt(
      fixture, nodeId: "shared-ref", field: try WorkflowDefinitionPromptField(parsing: "promptTemplate"),
      reason: "nodeRef", code: .invalidDefinition
    )
  }

  func testAuthoredFilesUpdateSourceCommitsChangedFiles() throws {
    let fixture = try makeFixture()
    _ = try fixture.service.importDefinition(resolution: fixture.options, force: false, reason: nil, evidence: [], actor: .init(kind: .cli))
    let current = try fixture.service.show(workflowName: "service-flow", versionId: nil).document
    var authoredFiles = current.authoredFiles
    authoredFiles["prompts/a.md"] = "authored files update"
    let result = try fixture.service.update(
      workflowName: "service-flow", source: .authoredFiles(authoredFiles), reason: "replace authored file map",
      expectedVersionId: nil, evidence: [], actor: .init(kind: .api)
    )
    XCTAssertEqual(result.outcome, .updated)
    XCTAssertEqual(try fixture.service.lookup(workflowName: "service-flow")?.nodePayloads["worker"]?.promptTemplate, "authored files update")
  }

  func testExtendsWorkflowWholeUpdateReadsBaseFromDisk() throws {
    let fixture = try makeFixture()
    let baseDirectory = fixture.root.appendingPathComponent("base-flow", isDirectory: true)
    try FileManager.default.createDirectory(at: baseDirectory.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: baseDirectory.appendingPathComponent("prompts"), withIntermediateDirectories: true)
    try """
    {
      "workflowId": "base-flow",
      "defaults": {"maxLoopIterations": 3, "nodeTimeoutMs": 120000},
      "entryStepId": "work",
      "nodeRegistry": [{"id": "worker", "nodeFile": "nodes/worker.json"}],
      "steps": [{"id": "work", "nodeId": "worker", "role": "worker"}],
      "nodes": [{"id": "worker", "nodeFile": "nodes/worker.json"}]
    }
    """.write(to: baseDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try #"{"id":"worker","nodeType":"agent","executionBackend":"codex-agent","agentSandbox":"read-only","model":"base-model","modelFreeze":false,"promptTemplateFile":"prompts/base.md","variables":{}}"#
      .write(to: baseDirectory.appendingPathComponent("nodes/worker.json"), atomically: true, encoding: .utf8)
    try "base prompt".write(
      to: baseDirectory.appendingPathComponent("prompts/base.md"), atomically: true, encoding: .utf8
    )
    let derivedFile = fixture.workflowDirectory.appendingPathComponent("workflow.json")
    let declaration = #"{"workflowId":"service-flow","extends":{"workflowId":"base-flow"}}"#
    try declaration.write(to: derivedFile, atomically: true, encoding: .utf8)

    let seeded = try fixture.service.importDefinition(
      resolution: fixture.options, force: false, reason: nil, evidence: [], actor: .init(kind: .cli)
    )
    XCTAssertEqual(seeded.outcome, .seeded)
    let seededDocument = try fixture.service.show(workflowName: "service-flow", versionId: nil).document
    XCTAssertEqual(Set(seededDocument.authoredFiles.keys), Set(["workflow.json"]))
    XCTAssertEqual(try fixture.service.lookup(workflowName: "service-flow")?.nodePayloads["worker"]?.promptTemplate, "base prompt")

    let patch: JSONValue = .array([.object([
      "op": .string("add"), "path": .string("/workflow.json/description"), "value": .string("patched derived")
    ])])
    let patched = try fixture.service.update(
      workflowName: "service-flow", source: .patch(patch), reason: "edit derived workflow",
      expectedVersionId: nil, evidence: [], actor: .init(kind: .cli)
    )
    XCTAssertEqual(patched.outcome, .updated)
    XCTAssertEqual(patched.audit?.operation, .update)
    XCTAssertEqual(Set(try fixture.service.show(workflowName: "service-flow", versionId: nil).document.authoredFiles.keys),
                   Set(["workflow.json"]))
    XCTAssertEqual(try fixture.service.lookup(workflowName: "service-flow")?.workflow.description, "patched derived")
    XCTAssertEqual(try fixture.service.lookup(workflowName: "service-flow")?.nodePayloads["worker"]?.promptTemplate, "base prompt")

    let fromDirectoryDeclaration = #"{"workflowId":"service-flow","description":"directory derived","extends":{"workflowId":"base-flow"}}"#
    try fromDirectoryDeclaration.write(to: derivedFile, atomically: true, encoding: .utf8)
    let fromDirectory = try fixture.service.update(
      workflowName: "service-flow", source: .fromDirectory(fixture.options), reason: "import derived file edit",
      expectedVersionId: nil, evidence: [], actor: .init(kind: .cli)
    )
    XCTAssertEqual(fromDirectory.outcome, .updated)
    XCTAssertEqual(Set(try fixture.service.show(workflowName: "service-flow", versionId: nil).document.authoredFiles.keys),
                   Set(["workflow.json"]))
    XCTAssertEqual(try fixture.service.lookup(workflowName: "service-flow")?.workflow.description, "directory derived")
    XCTAssertEqual(try fixture.service.lookup(workflowName: "service-flow")?.nodePayloads["worker"]?.promptTemplate, "base prompt")

    let strayFilePatch: JSONValue = .array([.object([
      "op": .string("add"), "path": .string("/prompts~1extra.md"), "value": .string("unreferenced")
    ])])
    let historyBeforeRejection = try fixture.service.history(workflowName: "service-flow", nodeId: nil, limit: nil).count
    let versionBeforeRejection = try fixture.store.current(workflowName: "service-flow")?.version.versionId
    try assertRejectedUpdate(
      fixture, source: .patch(strayFilePatch), reason: "reject stray derived authored file", code: .invalidDefinition
    )
    XCTAssertEqual(try fixture.service.history(workflowName: "service-flow", nodeId: nil, limit: nil).count, historyBeforeRejection)
    XCTAssertEqual(try fixture.store.current(workflowName: "service-flow")?.version.versionId, versionBeforeRejection)
  }

  private struct Fixture {
    var root: URL
    var workflowDirectory: URL
    var storeRoot: URL
    var promptFile: URL
    var options: WorkflowResolutionOptions
    var resolver = FileSystemWorkflowBundleResolver()
    var store: WorkflowDefinitionStore { WorkflowDefinitionStore(rootDirectory: storeRoot.path) }
    var service: WorkflowDefinitionService { WorkflowDefinitionService(storeRoot: storeRoot.path, fileResolver: resolver) }
  }

  private func makeFixture() throws -> Fixture {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/ds179/fixtures/definition-service-\(UUID().uuidString)", isDirectory: true)
    let workflowDir = root.appendingPathComponent("service-flow", isDirectory: true)
    let nodeDir = workflowDir.appendingPathComponent("nodes", isDirectory: true)
    let promptDir = workflowDir.appendingPathComponent("prompts", isDirectory: true)
    let scriptsDir = workflowDir.appendingPathComponent("scripts", isDirectory: true)
    let sharedDir = root.appendingPathComponent("shared-flow", isDirectory: true)
    let storeRoot = root.appendingPathComponent("store", isDirectory: true)
    try FileManager.default.createDirectory(at: nodeDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: promptDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sharedDir.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let workflow = """
    {
      "workflowId": "service-flow",
      "description": "",
      "defaults": {"maxLoopIterations": 3, "nodeTimeoutMs": 120000},
      "entryStepId": "first",
      "nodeRegistry": [
        {"id": "worker", "nodeFile": "nodes/worker.json"},
        {"id": "inline", "nodeFile": "nodes/inline.json"},
        {"id": "runner", "nodeFile": "nodes/runner.json"},
        {"id": "sharer", "nodeFile": "nodes/sharer.json"}
      ],
      "steps": [
        {"id": "first", "nodeId": "worker", "role": "worker", "transitions": [{"toStepId": "second"}]},
        {"id": "second", "nodeId": "inline", "role": "worker", "transitions": [{"toStepId": "third"}]},
        {"id": "third", "nodeId": "runner", "role": "worker", "transitions": [{"toStepId": "fourth"}]},
        {"id": "fourth", "nodeId": "sharer", "role": "worker"}
      ],
      "nodes": [
        {"id": "worker", "nodeFile": "nodes/worker.json"},
        {"id": "inline", "nodeFile": "nodes/inline.json"},
        {"id": "runner", "nodeFile": "nodes/runner.json"},
        {"id": "sharer", "nodeFile": "nodes/sharer.json"}
      ]
    }
    """
    try workflow.write(to: workflowDir.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {"id":"worker","executionBackend":"codex-agent","model":"model","promptTemplateFile":"prompts/a.md","systemPromptTemplateFile":"prompts/shared.md","variables":{}}
    """.write(to: nodeDir.appendingPathComponent("worker.json"), atomically: true, encoding: .utf8)
    try """
    {"id":"inline","executionBackend":"codex-agent","model":"model","promptTemplate":"inline original","variables":{}}
    """.write(to: nodeDir.appendingPathComponent("inline.json"), atomically: true, encoding: .utf8)
    try """
    {"id":"runner","nodeType":"command","model":"","modelFreeze":false,"command":{"executable":"scripts/run.sh","arguments":[]},"variables":{}}
    """.write(to: nodeDir.appendingPathComponent("runner.json"), atomically: true, encoding: .utf8)
    try """
    {"id":"sharer","executionBackend":"codex-agent","model":"model","promptTemplateFile":"prompts/shared.md","variables":{}}
    """.write(to: nodeDir.appendingPathComponent("sharer.json"), atomically: true, encoding: .utf8)
    try """
    {
      "workflowId": "shared-flow",
      "defaults": {"maxLoopIterations": 3, "nodeTimeoutMs": 120000},
      "entryStepId": "shared",
      "nodeRegistry": [{"id": "shared-worker", "nodeFile": "nodes/shared.json"}],
      "steps": [{"id": "shared", "nodeId": "shared-worker", "role": "worker"}],
      "nodes": [{"id": "shared-worker", "nodeFile": "nodes/shared.json"}]
    }
    """.write(to: sharedDir.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {"id":"shared-worker","executionBackend":"codex-agent","model":"model","promptTemplate":"external shared worker","variables":{}}
    """.write(to: sharedDir.appendingPathComponent("nodes/shared.json"), atomically: true, encoding: .utf8)
    try "#!/bin/sh\nexit 0\n".write(to: scriptsDir.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
    let promptFile = promptDir.appendingPathComponent("a.md")
    try "original prompt".write(to: promptFile, atomically: true, encoding: .utf8)
    try "original shared prompt".write(to: promptDir.appendingPathComponent("shared.md"), atomically: true, encoding: .utf8)
    return Fixture(
      root: root,
      workflowDirectory: workflowDir,
      storeRoot: storeRoot,
      promptFile: promptFile,
      options: WorkflowResolutionOptions(workflowName: "service-flow", scope: .direct, workflowDefinitionDir: root.path, workingDirectory: root.path)
    )
  }

  private func assertRejectedUpdate(
    _ fixture: Fixture,
    workflowName: String = "service-flow",
    source: WorkflowDefinitionUpdateSource,
    reason: String,
    code: WorkflowDefinitionServiceError.Code,
    patchOperation: String? = nil
  ) throws {
    let source = patchOperation.map { operation -> WorkflowDefinitionUpdateSource in
      .patch(.array([.object(["op": .string(operation), "path": .string("/prompts~1a.md")])]))
    } ?? source
    let beforeHistory = try fixture.service.history(workflowName: workflowName, nodeId: nil, limit: nil).count
    let beforeVersion = try fixture.store.current(workflowName: workflowName)?.version.versionId
    XCTAssertThrowsError(try fixture.service.update(
      workflowName: workflowName, source: source, reason: reason, expectedVersionId: nil, evidence: [], actor: .init(kind: .cli)
    )) { error in
      XCTAssertEqual((error as? WorkflowDefinitionServiceError)?.code, code)
    }
    XCTAssertEqual(try fixture.service.history(workflowName: workflowName, nodeId: nil, limit: nil).count, beforeHistory)
    XCTAssertEqual(try fixture.store.current(workflowName: workflowName)?.version.versionId, beforeVersion)
  }

  private func assertRejectedPrompt(
    _ fixture: Fixture,
    nodeId: String,
    field: WorkflowDefinitionPromptField,
    reason: String,
    code: WorkflowDefinitionServiceError.Code
  ) throws {
    let beforeHistory = try fixture.service.history(workflowName: "service-flow", nodeId: nil, limit: nil).count
    let beforeVersion = try fixture.store.current(workflowName: "service-flow")?.version.versionId
    XCTAssertThrowsError(try fixture.service.updatePrompt(
      workflowName: "service-flow", nodeId: nodeId, field: field, text: "rejected", reason: reason,
      expectedVersionId: nil, evidence: [], actor: .init(kind: .user)
    )) { error in
      XCTAssertEqual((error as? WorkflowDefinitionServiceError)?.code, code)
    }
    XCTAssertEqual(try fixture.service.history(workflowName: "service-flow", nodeId: nil, limit: nil).count, beforeHistory)
    XCTAssertEqual(try fixture.store.current(workflowName: "service-flow")?.version.versionId, beforeVersion)
  }

  private func authoredTreeDigests(at root: URL) throws -> [String: String] {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
      throw CocoaError(.fileReadUnknown)
    }
    var digests: [String: String] = [:]
    for case let fileURL as URL in enumerator {
      guard try fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
      let relativePath = String(fileURL.path.dropFirst(root.path.count + 1))
      digests[relativePath] = JSONCanonical.sha256Hex(try Data(contentsOf: fileURL))
    }
    return digests
  }
}

private final class ServiceTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date
  init(_ value: Date) { self.value = value }
  var now: Date { lock.lock(); defer { lock.unlock() }; return value }
  func advance() { lock.lock(); value = value.addingTimeInterval(25 * 60 * 60); lock.unlock() }
}
