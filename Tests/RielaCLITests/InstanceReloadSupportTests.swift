import Foundation
import XCTest
@testable import RielaCLI
import RielaAppSupport
import RielaCore
import RielaWorkflowRegistry

final class InstanceReloadSupportTests: XCTestCase {
  func testValidationAndImportLifecycle() throws {
    let root = try makeRielaCLITestTemporaryDirectory("reload-support")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("flow")
    let nodes = directory.appendingPathComponent("nodes")
    try FileManager.default.createDirectory(at: nodes, withIntermediateDirectories: true)
    let workflow = directory.appendingPathComponent("workflow.json")
    try """
    {"workflowId":"flow","defaults":{"maxLoopIterations":3,"nodeTimeoutMs":120000},
     "entryStepId":"first","nodeRegistry":[{"id":"worker","nodeFile":"nodes/worker.json"}],
     "steps":[{"id":"first","nodeId":"worker","role":"worker"}],
     "nodes":[{"id":"worker","nodeFile":"nodes/worker.json"}]}
    """.write(to: workflow, atomically: true, encoding: .utf8)
    let node = nodes.appendingPathComponent("worker.json")
    try """
    {"id":"worker","executionBackend":"codex-agent","model":"model","promptTemplate":"first","variables":{}}
    """.write(to: node, atomically: true, encoding: .utf8)
    let store = root.appendingPathComponent("store").path
    let validated = try InstanceReloadSupport.validateCandidate(workflowDirectory: directory.path, eventRoot: nil,
      expectedWorkflowId: "flow", nodePatches: [:], workingDirectory: root.path)
    XCTAssertEqual(validated.bundle.workflow.workflowId, "flow")
    XCTAssertFalse(validated.triggerDefaultsFingerprint.isEmpty)
    XCTAssertFalse(validated.eventRootDigest.isEmpty)
    let patched = try InstanceReloadSupport.validateCandidate(workflowDirectory: directory.path, eventRoot: nil,
      expectedWorkflowId: "flow", nodePatches: ["worker": .init(model: "other")], workingDirectory: root.path)
    XCTAssertEqual(patched.bundle.nodePayloads["worker"]?.model, "other")
    XCTAssertThrowsError(try InstanceReloadSupport.validateCandidate(workflowDirectory: directory.path, eventRoot: nil,
      expectedWorkflowId: "flow", nodePatches: ["missing": .init(model: "other")], workingDirectory: root.path)) { error in
      XCTAssertEqual((error as? RielaAppInstanceReloadError)?.code, .invalidWorkflowDefinition)
    }
    XCTAssertThrowsError(try InstanceReloadSupport.validateCandidate(workflowDirectory: directory.path, eventRoot: nil,
      expectedWorkflowId: "different", nodePatches: [:], workingDirectory: root.path)) { error in
      XCTAssertEqual((error as? RielaAppInstanceReloadError)?.code, .workflowIdMismatch)
    }
    let eventRoot = root.appendingPathComponent("events")
    let bindings = eventRoot.appendingPathComponent("bindings")
    try FileManager.default.createDirectory(at: bindings, withIntermediateDirectories: true)
    try #"{"id":"binding","sourceId":"missing","workflowName":"flow","match":{"eventType":"cron.tick"},"inputMapping":{"mode":"event-input"}}"#
      .write(to: bindings.appendingPathComponent("binding.json"), atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try InstanceReloadSupport.validateCandidate(workflowDirectory: directory.path, eventRoot: eventRoot.path,
      expectedWorkflowId: "flow", nodePatches: [:], workingDirectory: root.path)) { error in
      XCTAssertEqual((error as? RielaAppInstanceReloadError)?.code, .invalidEventBindings)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: store))
    let first = try InstanceReloadSupport.importDefinition(storeRoot: store, workflowDirectory: directory.path,
      workflowId: "flow", reason: "test import", workingDirectory: root.path)
    XCTAssertEqual(first.outcome, "seeded")
    let originalWorkflow = try String(contentsOf: workflow, encoding: .utf8)
    let changedWorkflow = originalWorkflow.replacingOccurrences(of: "\"entryStepId\"", with: "\"triggerDefaults\":{\"overlapPolicy\":\"skip\"},\"entryStepId\"")
    try changedWorkflow.write(to: workflow, atomically: true, encoding: .utf8)
    let changedFingerprint = RielaAppInstanceReloadFingerprint.triggerDefaultsFingerprint(.init(overlapPolicy: "skip"))
    XCTAssertEqual(InstanceReloadSupport.installedTriggerDefaultsFingerprint(storeRoot: store, workflowDirectory: directory.path,
      workflowId: "flow", workingDirectory: root.path), validated.triggerDefaultsFingerprint)
    XCTAssertEqual(InstanceReloadSupport.installedTriggerDefaultsFingerprint(storeRoot: root.appendingPathComponent("fresh").path,
      workflowDirectory: directory.path, workflowId: "flow", workingDirectory: root.path), changedFingerprint)
    let invalidStore = root.appendingPathComponent("not-a-directory")
    try FileManager.default.createDirectory(at: invalidStore, withIntermediateDirectories: true)
    try "not sqlite".write(to: invalidStore.appendingPathComponent("runtime-message-log.sqlite"), atomically: true, encoding: .utf8)
    XCTAssertNil(InstanceReloadSupport.installedTriggerDefaultsFingerprint(storeRoot: invalidStore.path,
      workflowDirectory: directory.path, workflowId: "flow", workingDirectory: root.path))
    try originalWorkflow.write(to: workflow, atomically: true, encoding: .utf8)
    let unchanged = try InstanceReloadSupport.importDefinition(storeRoot: store, workflowDirectory: directory.path,
      workflowId: "flow", reason: "test import", workingDirectory: root.path)
    XCTAssertEqual(unchanged.outcome, "unchanged")
    XCTAssertEqual(first.versionId, unchanged.versionId)
    try """
    {"id":"worker","executionBackend":"codex-agent","model":"model","promptTemplate":"second","variables":{}}
    """.write(to: node, atomically: true, encoding: .utf8)
    let updated = try InstanceReloadSupport.importDefinition(storeRoot: store, workflowDirectory: directory.path,
      workflowId: "flow", reason: "test update", workingDirectory: root.path)
    XCTAssertEqual(updated.outcome, "forceUpdated")
    XCTAssertNotEqual(first.versionId, updated.versionId)
    let service = WorkflowDefinitionService(storeRoot: store, fileResolver: FileSystemWorkflowBundleResolver())
    let history = try service.history(workflowName: "flow", nodeId: nil, limit: nil)
    XCTAssertEqual(history.count, 2)
    XCTAssertEqual(history.first?.operation, .forceUpdate)
    XCTAssertEqual(history.first?.reason, "test update")
    XCTAssertEqual(history.first?.actor.kind, .api)
    XCTAssertEqual(history.first?.actor.id, "instance-reload")
    XCTAssertEqual(InstanceReloadSupport.installedTriggerDefaultsFingerprint(storeRoot: store,
      workflowDirectory: directory.path, workflowId: "flow", workingDirectory: root.path), validated.triggerDefaultsFingerprint)
    let resolution = WorkflowResolutionOptions(workflowName: "flow", workflowDefinitionDir: directory.path, workingDirectory: root.path)
    try #"{"id":"worker","executionBackend":"codex-agent","model":"model","promptTemplate":"third","variables":{}}"#
      .write(to: node, atomically: true, encoding: .utf8)
    var calls: [Bool] = []
    let raced = try InstanceReloadSupport.importDefinition(service: service, workflowId: "flow") { force in
      calls.append(force)
      return try service.importDefinition(resolution: resolution, force: force, reason: "race retry", evidence: [], actor: .init(kind: .api, id: "instance-reload"))
    }
    XCTAssertEqual(calls, [false, true])
    XCTAssertEqual(raced.outcome, "forceUpdated")
    try #"{"id":"worker","executionBackend":"codex-agent","model":"model","promptTemplate":"fourth","variables":{}}"#
      .write(to: node, atomically: true, encoding: .utf8)
    let candidate = try FileSystemWorkflowBundleResolver().resolve(resolution)
    let document = try WorkflowDefinitionDocument.make(from: candidate)
    let data = try document.canonicalData()
    let definitionStore = WorkflowDefinitionStore(rootDirectory: store)
    let beforeConflict = try service.history(workflowName: "flow", nodeId: nil, limit: nil).count
    XCTAssertThrowsError(try InstanceReloadSupport.importDefinition(service: service, workflowId: "flow") { force in
      if force {
        _ = try definitionStore.commit(.init(workflowName: "flow", operation: .forceUpdate, documentData: data,
          documentDigest: JSONCanonical.sha256Hex(data), sourceDirectory: directory.path, sourceScope: "direct",
          provenance: "mutable", actor: .init(kind: .api, id: "instance-reload"), reason: "stale write",
          expectedCurrentVersionId: first.versionId))
        throw WorkflowDefinitionStoreError(code: .storeUnavailable, message: "unexpected successful stale write")
      }
      return try service.importDefinition(resolution: resolution, force: false, reason: "race", evidence: [], actor: .init(kind: .api, id: "instance-reload"))
    }) { error in
      XCTAssertEqual((error as? RielaAppInstanceReloadError)?.code, .definitionConflict)
    }
    XCTAssertEqual(try service.show(workflowName: "flow", versionId: nil).version.versionId, raced.versionId)
    XCTAssertEqual(try service.history(workflowName: "flow", nodeId: nil, limit: nil).count, beforeConflict)
    XCTAssertNotNil(InstanceReloadSupport.startRecord(candidateDirectory: directory.path, eventRoot: nil,
      storeRoot: store, workflowId: "flow", workingDirectory: root.path))
    try "{".write(to: workflow, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try InstanceReloadSupport.validateCandidate(workflowDirectory: directory.path, eventRoot: nil,
      expectedWorkflowId: "flow", nodePatches: [:], workingDirectory: root.path)) { error in
      XCTAssertEqual((error as? RielaAppInstanceReloadError)?.code, .invalidWorkflowDefinition)
    }
    XCTAssertThrowsError(try InstanceReloadSupport.importDefinition(storeRoot: store, workflowDirectory: directory.path,
      workflowId: "flow", reason: "invalid", workingDirectory: root.path)) { error in
      XCTAssertEqual((error as? RielaAppInstanceReloadError)?.code, .invalidWorkflowDefinition)
    }
    XCTAssertEqual(try service.show(workflowName: "flow", versionId: nil).version.versionId, raced.versionId)
  }
}
