import AgentRuntimeKit
import Foundation
import XCTest

final class AgentRolloutWatcherTests: XCTestCase {
  func testRolloutWatcherEmitsCompleteAndTrailingLines() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let rollout = root.appendingPathComponent("rollout-test.jsonl")
    try "event:old\n".write(to: rollout, atomically: true, encoding: .utf8)
    let watcher = AgentRolloutWatcher<String> { line in
      line.hasPrefix("event:") ? line : nil
    }
    watcher.watchFile(path: rollout.path)

    try "event:old\nevent:new\n".write(to: rollout, atomically: true, encoding: .utf8)

    XCTAssertEqual(watcher.flush().compactMap(lineValue), ["event:new"])
    XCTAssertEqual(watcher.flush(), [])

    try "event:old\nevent:new\nevent:partial".write(to: rollout, atomically: true, encoding: .utf8)
    XCTAssertEqual(watcher.flush().compactMap(lineValue), ["event:partial"])
  }

  func testRolloutWatcherDiscoversNewRolloutFilesAndStops() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let existing = root.appendingPathComponent("rollout-existing.jsonl")
    try "".write(to: existing, atomically: true, encoding: .utf8)
    let watcher = AgentRolloutWatcher<String> { line in line }
    watcher.watchSessionsDirectory(path: root.path)

    let next = root.appendingPathComponent("nested/rollout-next.jsonl")
    try FileManager.default.createDirectory(at: next.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "".write(to: next, atomically: true, encoding: .utf8)

    XCTAssertEqual(watcher.flush(), [.newSession(path: next.path)])
    watcher.stop()
    XCTAssertTrue(watcher.isClosed)
    XCTAssertEqual(watcher.flush(), [])
  }

  private func temporaryDirectory() throws -> URL {
    let root = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true
    ).appendingPathComponent("tmp/agent-runtime-kit-tests", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func lineValue(_ event: AgentRolloutWatcherEvent<String>) -> String? {
    if case let .line(_, line) = event {
      return line
    }
    return nil
  }
}
