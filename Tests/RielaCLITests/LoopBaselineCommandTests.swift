import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class LoopBaselineCommandTests: XCTestCase {
  // MARK: - Parsing

  func testBaselineSetParsesActionWorkflowAndSession() throws {
    let command = try RielaArgumentParser().parse([
      "loop", "baseline", "set", "demo-workflow", "session-1", "--note", "good run", "--force"
    ])
    guard case let .loop(loopCommand) = command else {
      return XCTFail("expected loop command")
    }
    XCTAssertEqual(loopCommand.kind, .baseline)
    XCTAssertEqual(loopCommand.options.target, "demo-workflow")
    XCTAssertEqual(loopCommand.options.arguments.first, "set")
    XCTAssertTrue(loopCommand.options.arguments.contains("session-1"))
    XCTAssertTrue(loopCommand.options.arguments.contains("--force"))
  }

  func testBaselineRejectsUnknownAction() {
    XCTAssertThrowsError(try RielaArgumentParser().parse(["loop", "baseline", "promote", "demo"])) { error in
      XCTAssertTrue(((error as? CLIUsageError)?.message ?? "").contains("set|show|clear"))
    }
  }

  func testRegressParsesWorkflowTarget() throws {
    let command = try RielaArgumentParser().parse(["loop", "regress", "demo-workflow", "--session", "s9"])
    guard case let .loop(loopCommand) = command else {
      return XCTFail("expected loop command")
    }
    XCTAssertEqual(loopCommand.kind, .regress)
    XCTAssertEqual(loopCommand.options.target, "demo-workflow")
  }

  func testRegressWithoutWorkflowIsUsageError() {
    XCTAssertThrowsError(try RielaArgumentParser().parse(["loop", "regress"])) { error in
      XCTAssertEqual((error as? CLIUsageError)?.message, "loop regress requires a workflow id")
    }
  }

  func testDiffBaselineSugarParsesWorkflowTarget() throws {
    let command = try RielaArgumentParser().parse(["loop", "diff", "--baseline", "demo-workflow", "--session", "s9"])
    guard case let .loop(loopCommand) = command else {
      return XCTFail("expected loop command")
    }
    XCTAssertEqual(loopCommand.kind, .diff)
    XCTAssertEqual(loopCommand.options.target, "demo-workflow")
    XCTAssertEqual(loopCommand.options.arguments.first, "--baseline")
  }

  func testDiffWithTwoSessionsStillParses() throws {
    let command = try RielaArgumentParser().parse(["loop", "diff", "s1", "s2"])
    guard case let .loop(loopCommand) = command else {
      return XCTFail("expected loop command")
    }
    XCTAssertEqual(loopCommand.kind, .diff)
    XCTAssertEqual(loopCommand.options.target, "s1")
    XCTAssertEqual(loopCommand.options.arguments.first, "s2")
  }

  func testParsedBaselineOptionsCollectsPositionalSessionAndFlags() throws {
    let parsed = try LoopCommandRunner().parseBaselineOptions(
      ["session-1", "--note", "n", "--force", "--session-store", "/tmp/store"]
    )
    XCTAssertEqual(parsed.sessionId, "session-1")
    XCTAssertEqual(parsed.note, "n")
    XCTAssertTrue(parsed.force)
    XCTAssertEqual(parsed.sessionStore, "/tmp/store")
  }

  func testParsedBaselineOptionsSessionFlagOnlyRejectsPositional() {
    XCTAssertThrowsError(
      try LoopCommandRunner().parseBaselineOptions(["session-1"], sessionViaFlagOnly: true)
    )
    XCTAssertEqual(
      try LoopCommandRunner().parseBaselineOptions(["--session", "s2"], sessionViaFlagOnly: true).sessionId,
      "s2"
    )
  }

  // MARK: - Exit-code contract (S10: 0 / 3 / 4 / 1)

  func testRegressExitCodesArePinned() {
    XCTAssertEqual(CLIExitCode.success.rawValue, 0)
    XCTAssertEqual(CLIExitCode.gateCheckFailed.rawValue, 3, "regression detected must exit 3")
    XCTAssertEqual(CLIExitCode.noLoopEvidence.rawValue, 4, "missing baseline/evidence must exit 4")
    XCTAssertEqual(CLIExitCode.failure.rawValue, 1, "operational error must exit 1")
  }

  func testMissingBaselineProducesNoLoopEvidenceExit() {
    let runner = LoopCommandRunner()
    let root = NSTemporaryDirectory() + "loop-baseline-cli-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: root) }
    let command = LoopCommand(
      kind: .regress,
      options: CLICommandOptions(
        scope: "loop",
        command: "regress",
        target: "absent-workflow",
        arguments: ["--session-store", root],
        output: .json
      )
    )
    let result = runner.runRegress(command)
    XCTAssertEqual(result.exitCode, .noLoopEvidence)
    XCTAssertTrue(result.stdout.contains("no-baseline"))
  }
}
