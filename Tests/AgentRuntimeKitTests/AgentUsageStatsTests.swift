import AgentRuntimeKit
import Foundation
import RielaCore
import XCTest

final class AgentUsageStatsTests: XCTestCase {
  func testCollectAggregatesRolloutUsageAndCachesBySessionDirectory() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let rollout = root.appendingPathComponent("rollout-shared.jsonl")
    try "present\n".write(to: rollout, atomically: true, encoding: .utf8)

    var reads = 0
    let cache = AgentUsageStatsCache()
    let now = try XCTUnwrap(isoDate("2026-02-20T12:00:00.000Z"))
    let stats = AgentUsageStatsCollector.collect(
      sessionsDir: root.path,
      recentDays: 2,
      now: now,
      cache: cache
    ) { path in
      reads += 1
      XCTAssertEqual(path, rollout.path)
      return [
        line("2026-02-19T09:00:00.000Z", "session_meta", .object(["timestamp": .string("2026-02-19T09:00:00.000Z")])),
        line("2026-02-19T09:00:01.000Z", "event_msg", .object(["type": .string("UserMessage"), "message": .string("hi")])),
        line("2026-02-19T09:00:02.000Z", "event_msg", .object(["type": .string("ExecCommandBegin")])),
        line("2026-02-19T09:00:03.000Z", "event_msg", .object([
          "type": .string("TurnComplete"),
          "usage": .object([
            "model": .string("gpt-5"),
            "input_tokens": .integer(2),
            "output_tokens": .integer(3)
          ])
        ]))
      ]
    }

    XCTAssertEqual(reads, 1)
    XCTAssertEqual(stats?.totalSessions, 1)
    XCTAssertEqual(stats?.totalMessages, 1)
    XCTAssertEqual(stats?.modelUsage["gpt-5"], AgentModelUsageStats(inputTokens: 2, outputTokens: 3))
    XCTAssertEqual(stats?.recentDailyActivity.first?.messageCount, 1)
    XCTAssertEqual(stats?.recentDailyActivity.first?.toolCallCount, 1)

    let cached = AgentUsageStatsCollector.collect(
      sessionsDir: root.path,
      recentDays: 2,
      now: now.addingTimeInterval(1),
      cache: cache
    ) { _ -> [Line] in
      reads += 1
      return []
    }
    XCTAssertEqual(cached, stats)
    XCTAssertEqual(reads, 1)
  }

  private struct Line: AgentUsageStatsRolloutLine {
    var timestamp: String
    var type: String
    var payload: JSONValue
  }

  private func line(_ timestamp: String, _ type: String, _ payload: JSONValue) -> Line {
    Line(timestamp: timestamp, type: type, payload: payload)
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

  private func isoDate(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text)
  }
}
