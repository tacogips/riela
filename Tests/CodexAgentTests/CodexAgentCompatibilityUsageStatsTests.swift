import Foundation
import XCTest
@testable import CodexAgent
@testable import RielaCore

final class CodexAgentCompatibilityUsageStatsTests: XCTestCase {
  func testUsageStatsAggregatesMessagesToolsTurnCompleteAndTokenCountDeltas() throws {
    let sessionsDir = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: sessionsDir)
    }
    try writeUsageRollout(sessionsDir: sessionsDir, relativePath: "2026/02/18/rollout-aaa.jsonl", lines: [
      usageSessionMetaLine("2026-02-18T10:00:00.000Z", id: "sess-1"),
      usageLine("2026-02-18T10:00:03.000Z", "event_msg", .object(["type": .string("UserMessage"), "message": .string("hello")])),
      usageLine("2026-02-18T10:00:05.000Z", "event_msg", .object(["type": .string("AgentMessage"), "message": .string("world")])),
      usageLine(
        "2026-02-18T10:00:06.000Z",
        "response_item",
        .object([
          "type": .string("message"),
          "role": .string("assistant"),
          "content": .array([
            .object(["type": .string("output_text"), "text": .string("done")])
          ])
        ])
      ),
      usageLine("2026-02-18T10:00:07.000Z", "response_item", .object(["type": .string("function_call"), "name": .string("toolA"), "arguments": .string("{}"), "call_id": .string("call-1")])),
      turnCompleteUsageLine(
        "2026-02-18T10:00:08.000Z",
        model: "gpt-5-mini",
        inputTokens: 10,
        outputTokens: 20,
        cacheReadInputTokens: 3,
        cacheCreationInputTokens: 4,
        totalTokens: 37
      )
    ])
    try writeUsageRollout(sessionsDir: sessionsDir, relativePath: "2026/02/19/rollout-bbb.jsonl", lines: [
      usageSessionMetaLine("2026-02-19T09:00:00.000Z", id: "sess-2"),
      "{broken-json-line",
      usageLine("2026-02-19T09:00:01.000Z", "event_msg", .object(["type": .string("UserMessage"), "message": .string("next")])),
      turnCompleteUsageLine("2026-02-19T09:00:02.000Z", model: "gpt-5", inputTokens: 5, outputTokens: 6, totalTokens: 11),
      turnCompleteUsageLine(
        "2026-02-19T09:00:03.000Z",
        model: "gpt-5-mini",
        inputTokens: 2,
        outputTokens: 1,
        totalTokens: 3,
        useCamelCaseKeys: true
      )
    ])
    try writeUsageRollout(sessionsDir: sessionsDir, relativePath: "2026/02/20/rollout-token-count.jsonl", lines: [
      usageSessionMetaLine("2026-02-20T09:00:00.000Z", id: "sess-3"),
      tokenCountUsageLine("2026-02-20T09:00:01.000Z", input: 50, cached: 10, output: 40, total: 100),
      tokenCountUsageLine("2026-02-20T09:00:02.000Z", input: 70, cached: 10, output: 70, total: 140),
      tokenCountUsageLine(
        "2026-02-20T09:00:03.000Z",
        usageKey: "last_token_usage",
        input: 3,
        cached: 1,
        output: 2,
        total: 6
      ),
      usageLine("2026-02-20T09:00:04.000Z", "event_msg", .object(["type": .string("token_count"), "info": .null])),
      usageLine(
        "2026-02-20T09:00:05.000Z",
        "event_msg",
        .object([
          "type": .string("token_count"),
          "info": .object([
            "total_token_usage": .object(["input_tokens": .number(90), "output_tokens": .number(10), "total_tokens": .number(100)]),
            "rate_limits": .object(["limit_name": .string("GPT-5.3 Codex Spark")])
          ])
        ])
      )
    ])

    let stats = try XCTUnwrap(getCodexUsageStats(options: CodexUsageStatsOptions(codexSessionsDir: sessionsDir.path, recentDays: 3, now: try isoDate("2026-02-20T12:00:00.000Z"))))
    XCTAssertEqual(stats.totalSessions, 3)
    XCTAssertEqual(stats.totalMessages, 4)
    XCTAssertEqual(stats.firstSessionDate, "2026-02-18")
    XCTAssertEqual(stats.lastComputedDate, "2026-02-20")
    XCTAssertEqual(stats.modelUsage["gpt-5-mini"], CodexModelUsageStats(inputTokens: 12, outputTokens: 21, cacheReadInputTokens: 3, cacheCreationInputTokens: 4))
    XCTAssertEqual(stats.modelUsage["gpt-5"], CodexModelUsageStats(inputTokens: 5, outputTokens: 6))
    XCTAssertEqual(stats.modelUsage["gpt-5-codex"], CodexModelUsageStats(inputTokens: 73, outputTokens: 72, cacheReadInputTokens: 11))
    XCTAssertEqual(stats.modelUsage["gpt-5.3-codex-spark"], CodexModelUsageStats(inputTokens: 90, outputTokens: 10))
    XCTAssertEqual(stats.recentDailyActivity[0], CodexDailyActivity(date: "2026-02-18", messageCount: 3, sessionCount: 1, toolCallCount: 1, tokensByModel: ["gpt-5-mini": 37]))
    XCTAssertEqual(stats.recentDailyActivity[1], CodexDailyActivity(date: "2026-02-19", messageCount: 1, sessionCount: 1, tokensByModel: ["gpt-5": 11, "gpt-5-mini": 3]))
    XCTAssertEqual(stats.recentDailyActivity[2], CodexDailyActivity(date: "2026-02-20", sessionCount: 1, tokensByModel: ["gpt-5-codex": 146, "gpt-5.3-codex-spark": 100]))
  }

  func testUsageStatsReturnsNilForMissingSessionsDirAndCachesWithinTTL() throws {
    let sessionsDir = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: sessionsDir)
    }
    XCTAssertNil(getCodexUsageStats(options: CodexUsageStatsOptions(codexSessionsDir: sessionsDir.appendingPathComponent("missing").path, recentDays: 1, now: try isoDate("2026-02-20T12:00:00.000Z"))))
    let rollout = try writeUsageRollout(sessionsDir: sessionsDir, relativePath: "2026/02/20/rollout-cache.jsonl", lines: [
      usageSessionMetaLine("2026-02-20T10:00:00.000Z", id: "sess-cache"),
      turnCompleteUsageLine("2026-02-20T10:00:02.000Z", model: "gpt-5", inputTokens: 1, outputTokens: 1, totalTokens: 2)
    ])
    let first = try XCTUnwrap(getCodexUsageStats(options: CodexUsageStatsOptions(codexSessionsDir: sessionsDir.path, recentDays: 1, now: try isoDate("2026-02-20T12:00:00.000Z"))))
    XCTAssertEqual(first.modelUsage["gpt-5"]?.inputTokens, 1)
    try writeUsageRollout(url: rollout, lines: [
      usageSessionMetaLine("2026-02-20T10:00:00.000Z", id: "sess-cache"),
      turnCompleteUsageLine("2026-02-20T10:00:02.000Z", model: "gpt-5", inputTokens: 99, outputTokens: 1, totalTokens: 100)
    ])
    let cached = try XCTUnwrap(getCodexUsageStats(options: CodexUsageStatsOptions(codexSessionsDir: sessionsDir.path, recentDays: 1, now: try isoDate("2026-02-20T12:00:04.000Z"))))
    XCTAssertEqual(cached.modelUsage["gpt-5"]?.inputTokens, 1)
    let refreshed = try XCTUnwrap(getCodexUsageStats(options: CodexUsageStatsOptions(codexSessionsDir: sessionsDir.path, recentDays: 1, now: try isoDate("2026-02-20T12:00:06.000Z"))))
    XCTAssertEqual(refreshed.modelUsage["gpt-5"]?.inputTokens, 99)
  }
}

private func usageSessionMetaLine(_ timestamp: String, id: String) -> String {
  usageLine(
    timestamp,
    "session_meta",
    .object(["meta": .object(["id": .string(id), "timestamp": .string(timestamp), "cwd": .string("/tmp/work")])])
  )
}

private func turnCompleteUsageLine(
  _ timestamp: String,
  model: String,
  inputTokens: Double,
  outputTokens: Double,
  cacheReadInputTokens: Double? = nil,
  cacheCreationInputTokens: Double? = nil,
  totalTokens: Double,
  useCamelCaseKeys: Bool = false
) -> String {
  var usage: JSONObject = [
    "model": .string(model),
    useCamelCaseKeys ? "inputTokens" : "input_tokens": .number(inputTokens),
    useCamelCaseKeys ? "outputTokens" : "output_tokens": .number(outputTokens),
    useCamelCaseKeys ? "totalTokens" : "total_tokens": .number(totalTokens)
  ]
  if let cacheReadInputTokens {
    usage["cache_read_input_tokens"] = .number(cacheReadInputTokens)
  }
  if let cacheCreationInputTokens {
    usage["cache_creation_input_tokens"] = .number(cacheCreationInputTokens)
  }
  return usageLine(timestamp, "event_msg", .object(["type": .string("TurnComplete"), "usage": .object(usage)]))
}

private func tokenCountUsageLine(
  _ timestamp: String,
  usageKey: String = "total_token_usage",
  input: Double,
  cached: Double,
  output: Double,
  total: Double
) -> String {
  usageLine(
    timestamp,
    "event_msg",
    .object([
      "type": .string("token_count"),
      "info": .object([
        "model": .string("gpt-5-codex"),
        usageKey: .object([
          "input_tokens": .number(input),
          "cached_input_tokens": .number(cached),
          "output_tokens": .number(output),
          "total_tokens": .number(total)
        ])
      ])
    ])
  )
}
