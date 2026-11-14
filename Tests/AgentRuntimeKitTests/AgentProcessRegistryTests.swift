import AgentRuntimeKit
import XCTest

final class AgentProcessRegistryTests: XCTestCase {
  func testRegistryTracksVirtualLifecycleAndInput() {
    let registry = AgentProcessRegistry<String>()
    let record = registry.createVirtualRunningRecord(
      commandArguments: ["agent", "run"],
      prompt: "hello"
    )

    XCTAssertEqual(record.pid, 10_000)
    XCTAssertEqual(registry.get(id: record.id)?.status, .running)

    let appended = registry.appendInput(id: record.id, text: "more")
    XCTAssertTrue(appended.appended)
    XCTAssertNil(appended.managed)
    XCTAssertEqual(registry.get(id: record.id)?.input, ["more"])

    let finished = registry.finish(id: record.id, exitCode: 3)
    XCTAssertEqual(finished?.status, .exited)
    XCTAssertEqual(registry.get(id: record.id)?.exitCode, 3)
  }

  func testRegistryReturnsManagedProcessesForTermination() {
    let registry = AgentProcessRegistry<String>()
    let first = AgentProcessRegistry<String>.makeRecord(
      id: "first",
      pid: 1,
      commandArguments: ["agent", "one"],
      prompt: "one",
      status: .running
    )
    let second = AgentProcessRegistry<String>.makeRecord(
      id: "second",
      pid: 2,
      commandArguments: ["agent", "two"],
      prompt: "two",
      status: .running
    )
    registry.store(record: first, managed: "managed-one")
    registry.store(record: second)

    let killed = registry.markKilled(id: "first")
    XCTAssertTrue(killed.marked)
    XCTAssertEqual(killed.managed, "managed-one")
    XCTAssertEqual(registry.get(id: "first")?.status, .killed)

    let managed = registry.markAllRunningKilled()
    XCTAssertTrue(managed.isEmpty)
    XCTAssertEqual(registry.get(id: "second")?.status, .killed)
    XCTAssertEqual(registry.prune(), 2)
    XCTAssertTrue(registry.list().isEmpty)
  }
}
