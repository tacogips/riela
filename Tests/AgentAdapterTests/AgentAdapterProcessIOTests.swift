import Foundation
import XCTest
@testable import RielaAdapters

extension AgentAdapterTests {
  func testFoundationRunnerWritesLargeStdinInChunks() async throws {
    let runner = FoundationLocalAgentProcessRunner()
    let prompt = String(repeating: "x", count: 256 * 1024)

    let result = try await runner.run(
      configuration: LocalAgentProcessConfiguration(executableURL: URL(fileURLWithPath: "/usr/bin/wc"), arguments: ["-c"]),
      stdin: prompt,
      deadline: Date(timeIntervalSinceNow: 3)
    )

    XCTAssertEqual(result.terminationStatus, 0)
    XCTAssertTrue(result.stdout.contains("262144"), result.stdout)
  }

  func testFoundationRunnerTreatsClosedStdinPipeAsBenign() async throws {
    let runner = FoundationLocalAgentProcessRunner()
    let prompt = String(repeating: "x", count: 512 * 1024)

    let start = ContinuousClock.now
    let result = try await runner.run(
      configuration: LocalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "exit 0"]
      ),
      stdin: prompt,
      deadline: Date(timeIntervalSinceNow: 3)
    )
    let elapsed = start.duration(to: ContinuousClock.now)

    XCTAssertEqual(result.terminationStatus, 0)
    XCTAssertLessThan(elapsed, .seconds(1))
  }
}
