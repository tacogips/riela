import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class RoutineAddonTests: XCTestCase {
  func testCreateThenGetListCompleteLifecycle() async throws {
    let root = temporaryDirectory()

    let created = try await runRoutineAddon(
      name: "riela/routine-create",
      root: root,
      config: [
        "name": .string("daily digest"),
        "task": .string("summarize inbox"),
        "every": .string("30m"),
        "workflowName": .string("routine-task-runner"),
        "completionCriteria": .string("inbox empty")
      ]
    )
    XCTAssertEqual(created.payload["created"], .bool(true))
    guard case let .string(routineId)? = created.payload["routineId"] else {
      return XCTFail("missing routineId in payload: \(created.payload)")
    }
    XCTAssertTrue(routineId.hasPrefix("routine-daily-digest-"))

    let got = try await runRoutineAddon(
      name: "riela/routine-get",
      root: root,
      config: ["routineId": .string(routineId)]
    )
    guard case let .object(routine)? = got.payload["routine"] else {
      return XCTFail("missing routine in payload: \(got.payload)")
    }
    XCTAssertEqual(routine["schedule"], .string("0 */30 * * * *"))
    XCTAssertEqual(routine["status"], .string("active"))

    let listed = try await runRoutineAddon(
      name: "riela/routine-list",
      root: root,
      config: ["status": .string("active")]
    )
    XCTAssertEqual(listed.payload["count"], .integer(1))

    let notMet = try await runRoutineAddon(
      name: "riela/routine-complete",
      root: root,
      config: ["routineId": .string(routineId)],
      inputs: ["conditionMet": .bool(false)]
    )
    XCTAssertEqual(notMet.payload["completed"], .bool(false))

    let completed = try await runRoutineAddon(
      name: "riela/routine-complete",
      root: root,
      config: ["routineId": .string(routineId), "note": .string("done")],
      inputs: ["conditionMet": .bool(true)]
    )
    XCTAssertEqual(completed.payload["completed"], .bool(true))
    guard case let .object(completedRoutine)? = completed.payload["routine"] else {
      return XCTFail("missing routine in payload: \(completed.payload)")
    }
    XCTAssertEqual(completedRoutine["status"], .string("completed"))
    XCTAssertEqual(completedRoutine["completionNote"], .string("done"))

    let afterComplete = try await runRoutineAddon(
      name: "riela/routine-list",
      root: root,
      config: ["status": .string("active")]
    )
    XCTAssertEqual(afterComplete.payload["count"], .integer(0))
  }

  func testCompleteWithoutRoutineIdIsNoOpWhenConditionNotMet() async throws {
    let output = try await runRoutineAddon(
      name: "riela/routine-complete",
      root: temporaryDirectory(),
      config: [:],
      inputs: ["conditionMet": .bool(false)]
    )
    XCTAssertEqual(output.payload["completed"], .bool(false))
  }

  func testUpdateStatusAndDelete() async throws {
    let root = temporaryDirectory()
    let created = try await runRoutineAddon(
      name: "riela/routine-create",
      root: root,
      config: [
        "name": .string("tick"),
        "task": .string("t"),
        "schedule": .string("0 * * * * *"),
        "workflowName": .string("routine-task-runner")
      ]
    )
    guard case let .string(routineId)? = created.payload["routineId"] else {
      return XCTFail("missing routineId")
    }

    let disabled = try await runRoutineAddon(
      name: "riela/routine-update-status",
      root: root,
      config: ["routineId": .string(routineId), "status": .string("disabled")]
    )
    XCTAssertEqual(disabled.payload["status"], .string("disabled"))

    let deleted = try await runRoutineAddon(
      name: "riela/routine-delete",
      root: root,
      config: ["routineId": .string(routineId)]
    )
    XCTAssertEqual(deleted.payload["deleted"], .bool(true))

    let listed = try await runRoutineAddon(name: "riela/routine-list", root: root, config: [:])
    XCTAssertEqual(listed.payload["count"], .integer(0))
  }

  func testCreateRequiresScheduleOrEvery() async throws {
    do {
      _ = try await runRoutineAddon(
        name: "riela/routine-create",
        root: temporaryDirectory(),
        config: [
          "name": .string("x"),
          "task": .string("y"),
          "workflowName": .string("z")
        ]
      )
      XCTFail("expected routine-create without a schedule to be rejected")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("cron schedule"), error.message)
    }
  }

  private func runRoutineAddon(
    name: String,
    root: URL,
    config: JSONObject,
    inputs: JSONObject = [:],
    workflowId: String = "routine-addon-tests"
  ) async throws -> AdapterExecutionOutput {
    var mergedConfig = config
    mergedConfig["routineStoreRoot"] = .string(root.appendingPathComponent("routines").path)
    mergedConfig["eventRoot"] = .string(root.appendingPathComponent("events").path)
    return try await BuiltinWorkflowAddonResolver(environment: [:], workingDirectory: root).execute(
      WorkflowAddonExecutionInput(
        workflowId: workflowId,
        stepId: "routine-step",
        nodeId: "routine-node",
        addon: WorkflowNodeAddonRef(
          name: name,
          version: "1",
          config: mergedConfig,
          inputs: inputs
        ),
        resolvedInputPayload: [:]
      ),
      context: AdapterExecutionContext()
    )
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-routine-addon-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }
}
