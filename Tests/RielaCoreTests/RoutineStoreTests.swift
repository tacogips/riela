import Foundation
import XCTest
@testable import RielaCore

final class RoutineStoreTests: XCTestCase {
  func testSaveLoadRoundTripsRecord() throws {
    let store = temporaryStore()
    let record = makeRecord(routineId: "routine-a", name: "daily digest")
    try store.save(record)

    let loaded = try store.load(routineId: "routine-a")
    XCTAssertEqual(loaded, record)
    XCTAssertNil(try store.load(routineId: "routine-missing"))
  }

  func testListFiltersByStatusAndWorkflowName() throws {
    let store = temporaryStore()
    try store.save(makeRecord(routineId: "routine-a", name: "a"))
    var disabled = makeRecord(routineId: "routine-b", name: "b")
    disabled.status = .disabled
    try store.save(disabled)
    var otherWorkflow = makeRecord(routineId: "routine-c", name: "c")
    otherWorkflow.workflowName = "other-workflow"
    try store.save(otherWorkflow)

    XCTAssertEqual(
      Set(try store.list(filter: RoutineListFilter(status: .active)).map(\.routineId)),
      ["routine-a", "routine-c"]
    )
    XCTAssertEqual(
      try store.list(filter: RoutineListFilter(status: .disabled)).map(\.routineId),
      ["routine-b"]
    )
    XCTAssertEqual(
      try store.list(filter: RoutineListFilter(workflowName: "other-workflow")).map(\.routineId),
      ["routine-c"]
    )
  }

  func testListOnMissingDatabaseIsEmpty() throws {
    XCTAssertEqual(try temporaryStore().list(), [])
  }

  func testUpdateMutatesRecordAndStampsUpdatedAt() throws {
    let store = temporaryStore()
    try store.save(makeRecord(routineId: "routine-a", name: "a"))

    let updated = try store.update(routineId: "routine-a") { record in
      record.status = .completed
      record.completionNote = "done"
    }
    XCTAssertEqual(updated.status, .completed)
    XCTAssertEqual(updated.completionNote, "done")
    XCTAssertEqual(try store.load(routineId: "routine-a"), updated)

    XCTAssertThrowsError(try store.update(routineId: "routine-missing") { _ in })
  }

  func testRecordRunCompletionIncrementsRunCount() throws {
    let store = temporaryStore()
    try store.save(makeRecord(routineId: "routine-a", name: "a"))

    _ = try store.recordRunCompletion(routineId: "routine-a")
    let record = try store.recordRunCompletion(routineId: "routine-a")
    XCTAssertEqual(record.runCount, 2)
    XCTAssertNotNil(record.lastRunAt)
  }

  func testDeleteRemovesRecord() throws {
    let store = temporaryStore()
    try store.save(makeRecord(routineId: "routine-a", name: "a"))

    XCTAssertTrue(try store.delete(routineId: "routine-a"))
    XCTAssertFalse(try store.delete(routineId: "routine-a"))
    XCTAssertNil(try store.load(routineId: "routine-a"))
  }

  func testResolveRootDirectoryPrecedence() {
    XCTAssertEqual(
      RoutineStore.resolveRootDirectory(explicit: "/explicit", workingDirectory: "/wd", environment: [:]),
      "/explicit"
    )
    XCTAssertEqual(
      RoutineStore.resolveRootDirectory(
        explicit: nil,
        workingDirectory: "/wd",
        environment: [RoutineStore.rootDirectoryEnvironmentKey: "/from-env"]
      ),
      "/from-env"
    )
    XCTAssertEqual(
      RoutineStore.resolveRootDirectory(explicit: nil, workingDirectory: "/wd", environment: [:]),
      "/wd/.riela/routines"
    )
    XCTAssertEqual(
      RoutineStore.resolveRootDirectory(explicit: "custom", workingDirectory: "/wd", environment: [:]),
      "/wd/custom"
    )
    XCTAssertEqual(
      RoutineStore.resolveRootDirectory(
        explicit: nil,
        workingDirectory: "/wd",
        environment: [RoutineStore.rootDirectoryEnvironmentKey: "from-env"]
      ),
      "/wd/from-env"
    )
  }

  func testListRejectsNonPositiveAndExcessiveLimits() throws {
    let store = temporaryStore()
    try store.save(makeRecord(routineId: "routine-a", name: "a"))

    XCTAssertThrowsError(try store.list(filter: RoutineListFilter(limit: 0)))
    XCTAssertThrowsError(try store.list(filter: RoutineListFilter(limit: -1)))
    XCTAssertThrowsError(try store.list(filter: RoutineListFilter(limit: RoutineStore.maximumListLimit + 1)))
    XCTAssertEqual(try store.list(filter: RoutineListFilter(limit: 1)).count, 1)
  }

  func testCronEveryShorthandExpansion() throws {
    XCTAssertEqual(try CronSchedule.expression(every: "30m"), "0 */30 * * * *")
    XCTAssertEqual(try CronSchedule.expression(every: "1m"), "0 * * * * *")
    XCTAssertEqual(try CronSchedule.expression(every: "15s"), "*/15 * * * * *")
    XCTAssertEqual(try CronSchedule.expression(every: "2h"), "0 0 */2 * * *")
    XCTAssertEqual(try CronSchedule.expression(every: "20"), "0 */20 * * * *")
    XCTAssertThrowsError(try CronSchedule.expression(every: "7m"))
    XCTAssertThrowsError(try CronSchedule.expression(every: "0m"))
    XCTAssertThrowsError(try CronSchedule.expression(every: "5d"))
    XCTAssertThrowsError(try CronSchedule.expression(every: ""))
    _ = try CronSchedule.parse(try CronSchedule.expression(every: "30m"))
  }

  private func temporaryStore() -> RoutineStore {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-routine-store-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return RoutineStore(rootDirectory: root.path)
  }

  private func makeRecord(routineId: String, name: String) -> RoutineRecord {
    RoutineRecord(
      routineId: routineId,
      name: name,
      task: "do the thing",
      schedule: "0 */30 * * * *",
      workflowName: "routine-task-runner",
      completionCriteria: "the thing is done",
      createdAt: RoutineStore.timestamp(),
      updatedAt: RoutineStore.timestamp(),
      eventRoot: "/tmp/events",
      sourceId: "\(routineId)-cron",
      bindingId: "\(routineId)-binding"
    )
  }
}
