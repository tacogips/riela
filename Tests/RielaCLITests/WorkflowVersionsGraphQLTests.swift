import Foundation
import XCTest
import RielaCore
import RielaGraphQL
import RielaWorkflowRegistry
@testable import RielaCLI

final class WorkflowVersionsGraphQLTests: XCTestCase {
  func testRestoreRejectsDirtyConflictThroughExecutor() async throws {
    let fixture = try await makeMutableWorkflowVersioningFixture(self)
    let script = fixture.workflowDirectory.appendingPathComponent("verify.sh")
    try Data("original".utf8).write(to: script)
    let node = try fixture.registeredURL(for: fixture.created.files[1])
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: node)) as? [String: Any])
    object["promptTemplateFile"] = "verify.sh"
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: node)
    let snapshot = try WorkflowHistoryStore(root: fixture.resolved.historyRoot).createSnapshot(
      inventory: WorkflowHistoryIdentityResolver.inventory(for: fixture.resolved.identity))
    object.removeValue(forKey: "promptTemplateFile")
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: node)
    try Data("local change".utf8).write(to: script)
    let executor = WorkflowDefinitionGraphQLDocumentExecutor(provider: WorkflowDefinitionGraphQLProvider(
      workingDirectory: fixture.root.path, sessionStoreRoot: nil, environment: fixture.environment))
    let response = await CLIRuntimeEnvironment.$overrides.withValue(fixture.environment) {
      await execute(executor, """
        mutation { restoreWorkflowVersion(input: {workflowName: "versioned-flow", scope: "user", snapshotId: "\(snapshot.snapshotId)", apply: true}) { restored } }
        """)
    }
    XCTAssertEqual(errorCode(response), "WORKFLOW_RESTORE_DIRTY_CONFLICTS")
    XCTAssertTrue("\(response.body)".contains("verify.sh"))
    XCTAssertEqual(try Data(contentsOf: script), Data("local change".utf8))
  }

  func testRestoreMapsOverwrittenAuditWarning() async throws {
    let fixture = try await makeMutableWorkflowVersioningFixture(self)
    let snapshot = try WorkflowHistoryStore(root: fixture.resolved.historyRoot).createSnapshot(
      inventory: WorkflowHistoryIdentityResolver.inventory(for: fixture.resolved.identity))
    let url = fixture.workflowDirectory.appendingPathComponent("workflow.json")
    var workflow = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    workflow["description"] = "changed file"
    try JSONSerialization.data(withJSONObject: workflow, options: [.sortedKeys]).write(to: url)
    let root = fixture.root.appendingPathComponent("definition-store")
    let resolver = FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false)
    let recorder = WorkflowDefinitionChangeRecorder(sessionStoreRoot: root.path, workingDirectory: fixture.root.path,
      environment: fixture.environment, fileResolver: resolver)
    let baseline = try recorder.captureBaselineIfAbsent(workflowName: "versioned-flow", liveDirectory: fixture.workflowDirectory,
      sourceScope: .user, transactionId: "baseline-warning", actor: .init(kind: .cli), operation: .snapshotRestore,
      bundleSnapshotBefore: nil)
    guard case let .captured(versionId)? = baseline else { return XCTFail("expected baseline") }
    let nodeId = try XCTUnwrap(fixture.resolved.bundle.nodePayloads.keys.sorted().first)
    let update = try WorkflowDefinitionService(storeRoot: root.path, fileResolver: resolver).updatePrompt(
      workflowName: "versioned-flow", nodeId: nodeId, field: .init(parsing: "promptTemplate"), text: "store-only",
      reason: "update", expectedVersionId: versionId, evidence: [], actor: .init(kind: .cli))
    let executor = WorkflowDefinitionGraphQLDocumentExecutor(provider: WorkflowDefinitionGraphQLProvider(
      workingDirectory: fixture.root.path, sessionStoreRoot: root.path, environment: fixture.environment))
    let response = await CLIRuntimeEnvironment.$overrides.withValue(fixture.environment) {
      await execute(executor, """
        mutation { restoreWorkflowVersion(input: {workflowName: "versioned-flow", scope: "user", snapshotId: "\(snapshot.snapshotId)", apply: true}) { definitionWarnings } }
        """)
    }
    XCTAssertNil(response.body["errors"], "\(response.body)")
    XCTAssertTrue("\(response.body)".contains(update.1.auditId))
  }

  func testVersionsDiffAndRestoreThroughExecutor() async throws {
    let fixture = try await makeMutableWorkflowVersioningFixture(self)
    let store = WorkflowHistoryStore(root: fixture.resolved.historyRoot)
    let first = try store.createSnapshot(inventory: WorkflowHistoryIdentityResolver.inventory(for: fixture.resolved.identity),
      snapshotId: "first", now: Date(timeIntervalSince1970: 4_000_000_000))
    let url = fixture.workflowDirectory.appendingPathComponent("workflow.json")
    let original = try Data(contentsOf: url)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
    object["description"] = "changed"
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    _ = try store.createSnapshot(inventory: WorkflowHistoryIdentityResolver.inventory(for: fixture.resolved.identity),
      snapshotId: "second", now: Date(timeIntervalSince1970: 4_000_000_001))
    object["description"] = "changed again"
    let changed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try changed.write(to: url)
    let root = fixture.root.appendingPathComponent("definition-store")
    let provider = WorkflowDefinitionGraphQLProvider(workingDirectory: fixture.root.path, sessionStoreRoot: root.path, environment: fixture.environment)
    let executor = WorkflowDefinitionGraphQLDocumentExecutor(provider: provider)
    try await CLIRuntimeEnvironment.$overrides.withValue(fixture.environment) {
      let list = await execute(executor, #"{ workflowVersions(workflowName: "versioned-flow", scope: "user") { snapshots { snapshotId parentSnapshotId } } }"#)
      XCTAssertNil(list.body["errors"], "\(list.body)")
      let snapshots = try XCTUnwrap(array(field(list, "workflowVersions", "snapshots")))
      let secondIndex = try XCTUnwrap(snapshots.firstIndex { string(objectValue($0)?["snapshotId"]) == "second" })
      let firstIndex = try XCTUnwrap(snapshots.firstIndex { string(objectValue($0)?["snapshotId"]) == "first" })
      XCTAssertLessThan(secondIndex, firstIndex)
      XCTAssertEqual(string(objectValue(snapshots[secondIndex])?["parentSnapshotId"]), first.snapshotId)
      let diff = await execute(executor, #"""
        { workflowVersionDiff(workflowName: "versioned-flow", scope: "user", from: "first", to: "current", includeContent: true) { differences { relativePath content { unified } } } }
        """#)
      XCTAssertNil(diff.body["errors"], "\(diff.body)")
      XCTAssertTrue("\(diff.body)".contains("changed again"))
      let noContent = await execute(executor, #"{ workflowVersionDiff(workflowName: "versioned-flow", scope: "user", from: "first", to: "current") { differences { content { unified } } } }"#)
      XCTAssertFalse("\(noContent.body)".contains("changed again"))
      let dry = await execute(executor, #"mutation { restoreWorkflowVersion(input: {workflowName: "versioned-flow", scope: "user", snapshotId: "first"}) { dryRun restored } }"#)
      XCTAssertEqual(field(dry, "restoreWorkflowVersion", "dryRun"), .bool(true))
      XCTAssertEqual(try Data(contentsOf: url), changed)
      XCTAssertTrue(try WorkflowDefinitionStore(rootDirectory: root.path).history(workflowName: "versioned-flow").isEmpty)
      let applied = await execute(executor, #"""
        mutation { restoreWorkflowVersion(input: {workflowName: "versioned-flow", scope: "user", snapshotId: "first", apply: true, reason: "r"}) { dryRun restored definitionVersionId definitionWarnings } }
        """#)
      XCTAssertNil(applied.body["errors"], "\(applied.body)")
      XCTAssertEqual(field(applied, "restoreWorkflowVersion", "restored"), .bool(true))
      XCTAssertNotNil(string(field(applied, "restoreWorkflowVersion", "definitionVersionId")))
      XCTAssertEqual(try Data(contentsOf: url), original)
      XCTAssertEqual(try WorkflowDefinitionStore(rootDirectory: root.path).history(workflowName: "versioned-flow").first { $0.operation == .snapshotRestore }?.reason, "r")
      let missing = await execute(executor, #"mutation { restoreWorkflowVersion(input: {workflowName: "versioned-flow", scope: "user", snapshotId: "missing"}) { dryRun } }"#)
      XCTAssertEqual(errorCode(missing), "WORKFLOW_VERSION_NOT_FOUND")
      let invalid = await execute(executor, #"mutation { restoreWorkflowVersion(input: {workflowName: "versioned-flow", scope: "user", snapshotId: "first", actorKind: "system"}) { dryRun } }"#)
      XCTAssertEqual(errorCode(invalid), "INVALID_DEFINITION_INPUT")
    }
  }

  private func execute(_ executor: WorkflowDefinitionGraphQLDocumentExecutor, _ query: String) async -> GraphQLDocumentExecutionResponse {
    await executor.execute(GraphQLDocumentRequest(query: query, variables: [:], operationName: nil,
      environment: [:], isLocallyTrusted: true, localWorkingDirectory: FileManager.default.currentDirectoryPath))
  }
  private func objectValue(_ value: JSONValue?) -> JSONObject? { guard case let .object(value) = value else { return nil }; return value }
  private func array(_ value: JSONValue?) -> [JSONValue]? { guard case let .array(value) = value else { return nil }; return value }
  private func string(_ value: JSONValue?) -> String? { guard case let .string(value) = value else { return nil }; return value }
  private func field(_ response: GraphQLDocumentExecutionResponse, _ operation: String, _ name: String) -> JSONValue? {
    objectValue(objectValue(response.body["data"])?[operation])?[name]
  }
  private func errorCode(_ response: GraphQLDocumentExecutionResponse) -> String? {
    string(objectValue(objectValue(array(response.body["errors"])?.first)?["extensions"])?["code"])
  }
}
