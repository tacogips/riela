import RielaCore
import XCTest
@testable import RielaCLI

final class TimeSignalAddonTests: XCTestCase {
  func testTimeSignalAddonNormalizesOffsetTimestampLikeTypeScriptDate() async throws {
    let output = try await runTimeSignal(scheduledAt: "2026-05-31T10:05:00+09:00")

    XCTAssertEqual(output.payload["scheduledAt"], .string("2026-05-31T01:05:00.000Z"))
    XCTAssertEqual(output.payload["localTime"], .string("2026-05-31 10:05"))
    XCTAssertEqual(output.payload["shouldAnnounce"], .bool(true))
    XCTAssertEqual(output.when["should_announce"], true)
    XCTAssertEqual(output.payload["replyText"], .string("時報です。Asia/Tokyo の現在時刻は 2026-05-31 10:05 です。"))
  }

  func testTimeSignalAddonPreservesFractionalMilliseconds() async throws {
    let output = try await runTimeSignal(scheduledAt: "2026-05-31T10:05:00.123+09:00")

    XCTAssertEqual(output.payload["scheduledAt"], .string("2026-05-31T01:05:00.123Z"))
    XCTAssertEqual(output.payload["localTime"], .string("2026-05-31 10:05"))
  }

  func testTimeSignalAddonRejectsInvalidTimezone() async throws {
    do {
      _ = try await runTimeSignal(scheduledAt: "2026-05-31T10:05:00.000Z", timezone: "Not/AZone")
      XCTFail("expected invalid timezone to be rejected")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("invalid timezone: Not/AZone"))
    }
  }

  private func runTimeSignal(
    scheduledAt: String,
    timezone: String = "Asia/Tokyo"
  ) async throws -> AdapterExecutionOutput {
    try await BuiltinWorkflowAddonResolver(environment: [:]).execute(
      WorkflowAddonExecutionInput(
        workflowId: "telegram-agent-trio-time-signal",
        stepId: "prepare-time-signal",
        nodeId: "prepare-time-signal",
        addon: WorkflowNodeAddonRef(
          name: "riela/time-signal",
          version: "1",
          config: ["intervalMinutes": .number(5)],
          inputs: [
            "scheduledAt": .string(scheduledAt),
            "timezone": .string(timezone)
          ]
        )
      ),
      context: AdapterExecutionContext()
    )
  }
}
