import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class BuiltinStatefulContainerIntegrationTests: XCTestCase {
  func testKeyValueLifecycleAcrossIndependentGuests() async throws {
    let guest = try StatefulContainerFixture(testCase: self)
    let value = JSONValue.object(["sequence": .integer(3), "accepted": .bool(true)])
    _ = try await guest.call("riela/kv-set", config: ["key": .string("fixture"), "value": value])
    let loaded = try await guest.call("riela/kv-get", config: ["key": .string("fixture")])
    XCTAssertEqual(loaded.payload["value"], value)
    let listed = try await guest.call("riela/kv-list")
    XCTAssertEqual(listed.payload["keys"], .array([.string("fixture")]))
    let deleted = try await guest.call("riela/kv-delete", config: ["key": .string("fixture")])
    XCTAssertEqual(deleted.payload["deleted"], .bool(true))
  }

  func testAllMemoryOperationsPersistAcrossGuests() async throws {
    let guest = try StatefulContainerFixture(testCase: self)
    let saved = try await guest.call("riela/memory-save", config: ["payload": .object(["text": .string("initial")])])
    let record = try object(saved.payload["record"])
    let identifier = try XCTUnwrap(record["recordId"])
    let updated = try await guest.call("riela/memory-update", config: ["recordId": identifier,
      "payload": .object(["text": .string("updated fixture")])])
    XCTAssertEqual(updated.payload["updated"], .bool(true))
    for name in ["riela/memory-load", "riela/memory-search"] {
      let loaded = try await guest.call(name, config: name.hasSuffix("search") ? ["match": .string("updated")] : [:])
      guard case let .array(records)? = loaded.payload["records"] else { return XCTFail("missing records") }
      XCTAssertEqual(records.count, 1)
      XCTAssertEqual(try object(records.first)["payload"], .object(["text": .string("updated fixture")]))
    }
  }

  func testRoutineLifecycleAcrossGuests() async throws {
    let guest = try StatefulContainerFixture(testCase: self)
    let shared: JSONObject = ["routineStoreRoot": .string(guest.root.appendingPathComponent("routines").path),
      "eventRoot": .string(guest.root.appendingPathComponent("events").path)]
    func run(_ name: String, _ config: JSONObject = [:]) async throws -> AdapterExecutionOutput {
      try await guest.call(name, config: shared.merging(config) { _, value in value })
    }
    let created = try await run("riela/routine-create", ["name": .string("fixture"), "task": .string("fixture task"),
      "every": .string("30m"), "workflowName": .string("fixture-workflow")])
    let identifier = try XCTUnwrap(created.payload["routineId"])
    let got = try await run("riela/routine-get", ["routineId": identifier])
    XCTAssertEqual(got.payload["routineId"], identifier)
    let listed = try await run("riela/routine-list")
    XCTAssertEqual(listed.payload["count"], .integer(1))
    let disabled = try await run("riela/routine-update-status", ["routineId": identifier, "status": .string("disabled")])
    XCTAssertEqual(disabled.payload["status"], .string("disabled"))
    let completed = try await run("riela/routine-complete", ["routineId": identifier])
    XCTAssertEqual(completed.payload["completed"], .bool(true))
    let deleted = try await run("riela/routine-delete", ["routineId": identifier])
    XCTAssertEqual(deleted.payload["deleted"], .bool(true))
  }

  func testPersonaMemoryRoutingReplyAndHandoverOutputs() async throws {
    let guest = try StatefulContainerFixture(testCase: self)
    let memory: JSONObject = ["personaId": .string("fixture"), "personaName": .string("Fixture")]
    _ = try await guest.call("riela/chat-persona-memory-write", config: memory, payload: ["replyText": .string("reply"),
      "memoryEntries": .array([.object(["kind": .string("note"), "importance": .string("normal"), "content": .string("remember fixture")])])])
    let read = try await guest.call("riela/chat-persona-memory-read", config: memory)
    XCTAssertEqual(read.payload["memoryRecordCount"], .integer(1))
    let routed = try await guest.call("riela/chat-persona-router", config: ["personas": .array([
      .object(["id": .string("fixture"), "name": .string("Fixture")])])], payload: ["request": .string("Fixture please")])
    XCTAssertEqual(routed.payload["target"], .string("fixture"))
    let reply = try await guest.call("riela/chat-reply-worker", config: ["textTemplate": .string("guest reply")])
    XCTAssertEqual(reply.payload["replyText"], .string("guest reply"))
    let handover = try await guest.call("riela/handover-request", payload: ["reason": .string("userInputRequired"),
      "question": .object(["id": .string("q"), "text": .string("Choose"), "options": .array([])]),
      "resumeStepId": .string("resume")], variables: ["rielaTask": .object([:])])
    XCTAssertEqual(handover.payload["status"], .string("handover-requested"))
  }

  func testDigestReadStateUsesGuestWorkspace() async throws {
    let guest = try StatefulContainerFixture(testCase: self)
    for name in ["riela/x-digest", "riela/gmail-digest"] {
      let result = try await guest.call(name, config: ["operation": .string("read-state")])
      XCTAssertEqual(result.payload["status"], .string("ok"))
      XCTAssertEqual(result.payload["stateBackend"], .string("file"))
    }
  }

  private func object(_ value: JSONValue?) throws -> JSONObject {
    guard case let .object(object)? = value else { throw XCTUnwrapError() }
    return object
  }
}

private struct XCTUnwrapError: Error {}

private struct StatefulContainerFixture {
  let root: URL
  let resolver: BuiltinAddonContainerResolver
  let image: String

  init(testCase: XCTestCase) throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["RIELA_TEST_LIVE_BUILTIN_IMAGE"] == "1", "opt-in real guest stateful tests")
    root = try makeRielaCLITestTemporaryDirectory("stateful-guest")
    let cleanup = root
    testCase.addTeardownBlock { try? FileManager.default.removeItem(at: cleanup) }
    image = ProcessInfo.processInfo.environment["RIELA_TEST_BUILTIN_IMAGE"] ?? WorkflowAddonContainerExecution.defaultImage
    resolver = .init(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: testCase),
      primary: BuiltinWorkflowAddonResolver(environment: [:], workingDirectory: root), environment: [:], workingDirectory: root)
  }

  func call(_ name: String, config: JSONObject = [:], payload: JSONObject = [:], variables: JSONObject = [:]) async throws -> AdapterExecutionOutput {
    try await resolver.execute(.init(workflowId: "stateful-fixture", stepId: "step", nodeId: "node",
      addon: .init(name: name, version: "1", config: config,
        container: .init(image: image, runtime: .appleContainer, networkPolicy: .denied)),
      variables: variables, resolvedInputPayload: payload), context: .init(deadline: Date().addingTimeInterval(120)))
  }
}
