import Foundation
import RielaCore
import RielaMemory
import XCTest
@testable import RielaCLI

final class SnapshotStoreAddonTests: XCTestCase {
  func testTypedSnapshotRoundTripAndRevisionConflict() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])
    let empty = try await resolver.execute(input(root, action: "load"), context: .init())
    XCTAssertEqual(empty.payload["found"], .bool(false))
    let value: JSONValue = .object(["cursor": .string("{{opaque-token}}"), "pending": .array([.string("one")])])
    let saved = try await resolver.execute(input(root, action: "commit", value: value, head: .null), context: .init())
    XCTAssertEqual(saved.payload["value"], value)
    XCTAssertEqual(saved.payload["context"], .string("{{unchanged-context}}"))
    let loaded = try await resolver.execute(input(root, action: "load"), context: .init())
    XCTAssertEqual(loaded.payload["head"], saved.payload["head"])
    XCTAssertEqual(loaded.payload["value"], value)
    _ = try await resolver.execute(input(root, action: "commit", value: .string("updated"), head: saved.payload["head"]), context: .init())
    do {
      _ = try await resolver.execute(input(root, action: "commit", value: .string("stale"), head: saved.payload["head"]), context: .init())
      XCTFail("stale head replaced current snapshot")
    } catch let error as AdapterExecutionError { XCTAssertTrue(error.message.contains("reload")) }
    let final = try await resolver.execute(input(root, action: "load"), context: .init())
    XCTAssertEqual(final.payload["value"], .string("updated"))
  }

  func testExistingMemoryPayloadAndEvolutionVersionArePreserved() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    let old = try store.save(memoryId: "state", workflowId: "snapshot", nodeId: "collect", tags: ["checkpoint"],
      payload: .object(["state": .object(["frozen": .string("original")]), "records": .array([])]))
    let output = try await BuiltinWorkflowAddonResolver(environment: [:]).execute(input(root, action: "load"), context: .init())
    guard case let .object(head)? = output.payload["head"] else { return XCTFail("missing head") }
    XCTAssertEqual(head["recordId"], .integer(old.recordId)); XCTAssertEqual(head["version"], .integer(1))
    guard case let .string(scope)? = head["scope"] else { return XCTFail("unbound head") }
    XCTAssertEqual(scope.count, 64)
    XCTAssertEqual(output.payload["value"], .object(["state": .object(["frozen": .string("original")]), "records": .array([])]))
  }

  func testOutputBudgetRefusalDoesNotMutateExistingSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])
    let saved = try await resolver.execute(input(root, action: "commit", value: .string("before"), head: .null), context: .init())
    var oversized = input(root, action: "commit", value: .string(String(repeating: "x", count: 4_000_000)), head: saved.payload["head"])
    oversized.variables["opaque"] = .string(String(repeating: "x", count: 4_000_000))
    do { _ = try await resolver.execute(oversized, context: .init()); XCTFail("oversized response committed") } catch {}
    let after = try await resolver.execute(input(root, action: "load"), context: .init())
    XCTAssertEqual(after.payload["value"], .string("before"))
    XCTAssertEqual(after.payload["head"], saved.payload["head"])
  }

  func testCLIVariablesAreLiteralSnapshotData() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let config: JSONObject = ["action": .string("commit"), "storage": .object(["memoryId": .string("cli"), "memoryRoot": .string(root.path)]),
      "expectedHead": .null, "value": .string("{{snapshotValue}}"),
      "postprocess": .array([.object(["pick": .string("/value")])])]
    let variables: JSONObject = ["snapshotValue": .object(["cursor": .string("{{literal}}"), "count": .integer(2)])]
    let result = await RielaCLIApplication().run(["node", "run", "riela/snapshot-store", "--config",
      try JSONValue.object(config).compactJSONString(), "--variables", try JSONValue.object(variables).compactJSONString(),
      "--working-dir", root.path, "--output", "json"], environment: ["HOME": root.path, "PATH": ""])
    XCTAssertEqual(result.exitCode, .success, result.stdout + result.stderr)
    let output = try JSONDecoder().decode(NodeRunCommandResult.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(output.payload["value"], variables["snapshotValue"])
    XCTAssertEqual(output.payload["processed"], variables["snapshotValue"])
  }

  func testDeclaredWorkflowReusesNativeSnapshotAcrossRunsWithoutScripts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let definitions = root.appendingPathComponent("definitions/snapshot-fixture")
    try FileManager.default.createDirectory(at: definitions, withIntermediateDirectories: true)
    let storage: JSONObject = ["memoryId": .string("source"), "workflowId": .string("source-poll"),
      "nodeId": .string("collect"), "memoryRoot": .string(root.appendingPathComponent("state").path)]
    func node(_ id: String, commit: Bool = false) -> JSONValue {
      var config: JSONObject = ["action": .string(commit ? "commit" : "load"), "storage": .object(storage)]
      if commit { config["expectedHead"] = .string("{{input.head}}"); config["value"] = .string("{{checkedSnapshot}}") }
      return .object(["id": .string(id), "addon": .object(["name": .string("riela/snapshot-store"), "version": .string("1"), "config": .object(config)])])
    }
    func step(_ id: String, next: String? = nil) -> JSONValue {
      var value: JSONObject = ["id": .string(id), "nodeId": .string(id), "role": .string("worker")]
      if let next { value["transitions"] = .array([.object(["toStepId": .string(next)])]) }
      return .object(value)
    }
    let graph: JSONObject = ["workflowId": .string("snapshot-fixture"), "entryStepId": .string("load"),
      "defaults": .object(["maxLoopIterations": .integer(1), "nodeTimeoutMs": .integer(30000)]),
      "nodes": .array([node("load"), node("commit", commit: true), node("verify")]),
      "steps": .array([step("load", next: "commit"), step("commit", next: "verify"), step("verify")])]
    try JSONEncoder().encode(graph).write(to: definitions.appendingPathComponent("workflow.json"))
    for cursor in ["first", "{{literal-next-cursor}}"] {
      let value: JSONValue = .object(["cursor": .string(cursor), "pending": .array([.string("one")])])
      let result = await RielaCLIApplication().run(["workflow", "run", "snapshot-fixture", "--workflow-definition-dir",
        root.appendingPathComponent("definitions").path, "--working-dir", root.path, "--variables",
        try JSONValue.object(["checkedSnapshot": value]).compactJSONString(), "--output", "json"],
        environment: ["HOME": root.path, "PATH": ""])
      XCTAssertEqual(result.exitCode, .success, result.stdout + result.stderr)
      let output = try JSONDecoder().decode(JSONObject.self, from: Data(result.stdout.utf8))
      guard case let .object(payload)? = output["rootOutput"] else { return XCTFail("missing root output") }
      XCTAssertEqual(payload["value"], value)
    }
  }

  func testRetainedSourceRevisionThroughBuiltinSurvivesNewAcquisitionAndReleasesExactly() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])
    let first = try await resolver.execute(input(root, action: "commit", value: .string("old-work"), head: .null), context: .init())
    func retained(_ action: String, head: JSONValue? = nil) -> WorkflowAddonExecutionInput {
      var request = input(root, action: action, head: head)
      request.addon.config?["label"] = .string("opaque-batch-token")
      return request
    }
    _ = try await resolver.execute(retained("retain", head: first.payload["head"]), context: .init())
    let newer = try await resolver.execute(input(root, action: "commit", value: .string("new-work"), head: first.payload["head"]), context: .init())
    let old = try await resolver.execute(retained("load-retained"), context: .init())
    XCTAssertEqual(old.payload["head"], first.payload["head"])
    XCTAssertEqual(old.payload["value"], .string("old-work"))
    do {
      _ = try await resolver.execute(retained("release", head: newer.payload["head"]), context: .init())
      XCTFail("stale acknowledgement removed another revision")
    } catch {}
    let released = try await resolver.execute(retained("release", head: first.payload["head"]), context: .init())
    XCTAssertEqual(released.payload["released"], .bool(true))
    let missing = try await resolver.execute(retained("load-retained"), context: .init())
    XCTAssertEqual(missing.payload["found"], .bool(false))
    let current = try await resolver.execute(input(root, action: "load"), context: .init())
    XCTAssertEqual(current.payload["head"], newer.payload["head"])
    XCTAssertEqual(current.payload["value"], .string("new-work"))
  }

  private func input(_ root: URL, action: String, value: JSONValue? = nil, head: JSONValue? = nil) -> WorkflowAddonExecutionInput {
    var config: JSONObject = ["action": .string(action), "storage": .object(["memoryId": .string("state"),
      "workflowId": .string("snapshot"), "nodeId": .string("collect"), "memoryRoot": .string(root.path)]),
      "context": .string("{{opaque}}")]
    var variables: JSONObject = ["opaque": .string("{{unchanged-context}}")]
    if let value { config["value"] = .string("{{snapshotValue}}"); variables["snapshotValue"] = value }
    if let head { config["expectedHead"] = head }
    return .init(workflowId: "caller", stepId: "state", nodeId: "state", addon: .init(name: "riela/snapshot-store", version: "1", config: config), variables: variables)
  }
}
