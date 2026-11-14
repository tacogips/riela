import Foundation
import XCTest
@testable import RielaCore

final class EventOverlapPolicyTests: XCTestCase {
  func testResolutionPrecedenceAndDefaults() throws {
    XCTAssertEqual(
      try resolveEventOverlapPolicy(binding: nil, workflow: nil),
      EffectiveEventOverlapPolicy(policy: .skip, source: .default)
    )
    XCTAssertEqual(
      try resolveEventOverlapPolicy(binding: nil, workflow: EventOverlapSettings(overlapPolicy: "queue")),
      EffectiveEventOverlapPolicy(policy: .queue, source: .workflow, maxQueuedRuns: 1)
    )
    XCTAssertEqual(
      try resolveEventOverlapPolicy(
        binding: EventOverlapSettings(overlapPolicy: "concurrent", maxConcurrentRuns: 3),
        workflow: EventOverlapSettings(overlapPolicy: "queue", maxQueuedRuns: 5)
      ),
      EffectiveEventOverlapPolicy(policy: .concurrent, source: .binding, maxConcurrentRuns: 3)
    )
    XCTAssertEqual(
      try resolveEventOverlapPolicy(binding: nil, workflow: EventOverlapSettings(overlapPolicy: "cancelRunning")),
      EffectiveEventOverlapPolicy(policy: .cancelRunning, source: .workflow)
    )
  }

  func testResolutionRejectsNonPositiveRunCaps() {
    XCTAssertThrowsError(try resolveEventOverlapPolicy(
      binding: EventOverlapSettings(overlapPolicy: "concurrent", maxConcurrentRuns: 0), workflow: nil
    )) { error in
      XCTAssertEqual(error as? EventOverlapPolicyError, EventOverlapPolicyError("maxConcurrentRuns must be an integer >= 1; got 0"))
    }
    XCTAssertThrowsError(try resolveEventOverlapPolicy(
      binding: nil, workflow: EventOverlapSettings(overlapPolicy: "queue", maxQueuedRuns: -1)
    ))
  }

  func testResolutionRejectsUnknownPolicyWithExactMessage() {
    XCTAssertThrowsError(try resolveEventOverlapPolicy(binding: EventOverlapSettings(overlapPolicy: "bogus"), workflow: nil)) { error in
      XCTAssertEqual(
        error as? EventOverlapPolicyError,
        EventOverlapPolicyError("overlapPolicy must be one of skip, cancelRunning, queue, concurrent; got 'bogus'")
      )
    }
  }

  func testRawTriggerDefaultsValidationAndWorkflowCarryThrough() throws {
    var directDiagnostics: [WorkflowValidationDiagnostic] = []
    validateRawTriggerDefaults(["overlapPolicy": "bogus"], diagnostics: &directDiagnostics)
    XCTAssertEqual(
      directDiagnostics.map(\.message),
      ["must be one of skip, cancelRunning, queue, concurrent"]
    )
    let cases: [([String: Any]?, (String, String))] = [
      (["overlapPolicy": "bogus"], ("workflow.triggerDefaults.overlapPolicy", "must be one of skip, cancelRunning, queue, concurrent")),
      (["overlapPolicy": "skip", "maxQueuedRuns": 2], ("workflow.triggerDefaults.maxQueuedRuns", "requires workflow.triggerDefaults.overlapPolicy queue")),
      (["overlapPolicy": "queue", "maxQueuedRuns": 0], ("workflow.triggerDefaults.maxQueuedRuns", "must be an integer >= 1")),
      (["overlapPolicy": "queue", "maxQueuedRuns": true], ("workflow.triggerDefaults.maxQueuedRuns", "must be an integer >= 1")),
      (["typo": 1], ("workflow.triggerDefaults.typo", "is not a supported triggerDefaults field"))
    ]
    for (defaults, expectation) in cases {
      let (expectedPath, expectedMessage) = expectation
      let diagnostics = try validate(defaults: defaults).diagnostics
      XCTAssertTrue(
        diagnostics.contains { $0.path == expectedPath && $0.message == expectedMessage },
        "Expected \(expectedPath): \(expectedMessage); got \(diagnostics); input=\(defaults ?? [:])"
      )
    }

    let wrongType = try validate(defaults: nil, rawValue: "x").diagnostics
    XCTAssertTrue(wrongType.contains {
      $0.path == "workflow.triggerDefaults" && $0.message == "must be an object when provided"
    })
    XCTAssertFalse(try validate(defaults: nil).diagnostics.contains { $0.path.hasPrefix("workflow.triggerDefaults") })

    let valid = try XCTUnwrap(validate(defaults: ["overlapPolicy": "queue", "maxQueuedRuns": 2]).workflow)
    XCTAssertEqual(valid.triggerDefaults, EventOverlapSettings(overlapPolicy: "queue", maxQueuedRuns: 2))
  }

  func testRoutineCompletionIsMonotonicAndOverlapFieldsRoundTrip() throws {
    let store = temporaryStore()
    let routineId = "routine-overlap"
    let base = makeRecord(routineId: routineId)
    var record = RoutineRecord(
      routineId: base.routineId, name: base.name, task: base.task, schedule: base.schedule,
      workflowName: base.workflowName, status: base.status, createdAt: base.createdAt,
      updatedAt: base.updatedAt, eventRoot: base.eventRoot, sourceId: base.sourceId,
      bindingId: base.bindingId, overlapPolicy: "queue", maxQueuedRuns: 2
    )
    try store.save(record)
    XCTAssertEqual(try store.load(routineId: routineId)?.overlapPolicy, "queue")
    XCTAssertEqual(try store.load(routineId: routineId)?.maxQueuedRuns, 2)

    let later = Date(timeIntervalSince1970: 1_800_000_000)
    let earlier = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try store.recordRunCompletion(routineId: routineId, at: later)
    record = try store.recordRunCompletion(routineId: routineId, at: earlier)
    XCTAssertEqual(record.lastRunAt, RoutineStore.timestamp(later))
    XCTAssertEqual(record.runCount, 2)
  }

  func testRoutineRecordDecodesWithoutNewOverlapKeys() throws {
    let encoded = try JSONEncoder().encode(makeRecord(routineId: "legacy"))
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "overlapPolicy")
    object.removeValue(forKey: "maxQueuedRuns")
    object.removeValue(forKey: "maxConcurrentRuns")
    let decoded = try JSONDecoder().decode(RoutineRecord.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertNil(decoded.overlapPolicy)
    XCTAssertNil(decoded.maxQueuedRuns)
    XCTAssertNil(decoded.maxConcurrentRuns)
  }

  private func validate(defaults: [String: Any]?, rawValue: Any? = nil) throws -> AuthoredWorkflowValidationResult {
    var object: [String: Any] = [
      "workflowId": "sample",
      "defaults": ["nodeTimeoutMs": 120000, "maxLoopIterations": 3],
      "entryStepId": "main",
      "nodes": [["id": "main", "nodeFile": "nodes/main.json"]],
      "steps": [["id": "main", "nodeId": "main", "role": "worker"]]
    ]
    if let defaults {
      object["triggerDefaults"] = defaults
    } else if let rawValue {
      object["triggerDefaults"] = rawValue
    }
    return validateAuthoredWorkflowData(try JSONSerialization.data(withJSONObject: object))
  }

  private func temporaryStore() -> RoutineStore {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-overlap-routine-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return RoutineStore(rootDirectory: root.path)
  }

  private func makeRecord(routineId: String) -> RoutineRecord {
    RoutineRecord(
      routineId: routineId,
      name: "scheduled",
      task: "run",
      schedule: "0 */10 * * * *",
      workflowName: "report",
      createdAt: RoutineStore.timestamp(),
      updatedAt: RoutineStore.timestamp(),
      eventRoot: "/tmp/events",
      sourceId: "cron",
      bindingId: "binding"
    )
  }
}
