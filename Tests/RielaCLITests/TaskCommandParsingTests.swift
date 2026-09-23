import Foundation
import XCTest
@testable import RielaCLI

/// P0-6 parsing gate for `riela task`. It lives beside the other task CLI
/// tests rather than in `CommandParsingTests` because that class is already
/// at SwiftLint's type-body ceiling.
final class TaskCommandParsingTests: XCTestCase {
  func testParsesTaskReadCommands() throws {
    let parser = RielaArgumentParser()
    let show = try parser.parse([
      "task", "show", "task-1",
      "--session-store", "./sessions",
      "--output", "json"
    ])
    XCTAssertEqual(
      show,
      .task(TaskCommand(
        kind: .show,
        options: CLICommandOptions(
          scope: "task",
          command: "show",
          target: "task-1",
          arguments: ["--session-store", "./sessions", "--output", "json"],
          output: .json
        )
      ))
    )

    let list = try parser.parse([
      "task", "list",
      "--state", "running",
      "--workflow", "loop-engineer-quality-loop",
      "--limit", "5",
      "--output=jsonl"
    ])
    XCTAssertEqual(
      list,
      .task(TaskCommand(
        kind: .list,
        options: CLICommandOptions(
          scope: "task",
          command: "list",
          target: nil,
          arguments: ["--state", "running", "--workflow", "loop-engineer-quality-loop", "--limit", "5", "--output=jsonl"],
          output: .jsonl
        )
      ))
    )

    // `list` takes no target, so a bare `task list` parses with no arguments.
    XCTAssertEqual(
      try parser.parse(["task", "list"]),
      .task(TaskCommand(kind: .list, options: CLICommandOptions(scope: "task", command: "list")))
    )
  }

  func testTaskCommandRejectsAMissingIdOrAnUnknownSubcommand() {
    let parser = RielaArgumentParser()
    XCTAssertThrowsError(try parser.parse(["task", "show"])) { error in
      XCTAssertEqual((error as? CLIUsageError)?.message, "task show requires a task id")
    }
    XCTAssertThrowsError(try parser.parse(["task", "submit", "task-1"]))
    XCTAssertThrowsError(try parser.parse(["task"]))
  }

  func testParsesRunAndDecideTargets() throws {
    let parser = RielaArgumentParser()
    let run = try parser.parse(["task", "run", "task-1", "--dry-run", "--output", "json"])
    XCTAssertEqual(run, .task(TaskCommand(kind: .run, options: CLICommandOptions(
      scope: "task", command: "run", target: "task-1",
      arguments: ["--dry-run", "--output", "json"], output: .json
    ))))
    let decide = try parser.parse([
      "task", "decide", "task-1", "--rerun", "review",
      "--principal", "operator", "--expected-version", "4", "--decision-id", "decision-1"
    ])
    guard case let .task(command) = decide else {
      return XCTFail("expected task command")
    }
    XCTAssertEqual(command.kind, .decide)
    XCTAssertEqual(command.options.target, "task-1")
    let parsed = try ParsedTaskDecideOptions.resolve(command.options.arguments)
    XCTAssertEqual(parsed.kind, .rerun(fromStepId: "review"))
    XCTAssertEqual(parsed.principal, "operator")
    XCTAssertEqual(parsed.expectedVersion, 4)
    XCTAssertEqual(parsed.decisionId, "decision-1")
  }

  func testDecideRejectsMissingOrMultipleActionsAndAuditFields() throws {
    let common = ["--principal", "operator", "--expected-version", "1", "--decision-id", "decision-1"]
    XCTAssertThrowsError(try ParsedTaskDecideOptions.resolve(common))
    XCTAssertThrowsError(try ParsedTaskDecideOptions.resolve(["--accept", "--cancel"] + common))
    XCTAssertThrowsError(try ParsedTaskDecideOptions.resolve(["--accept", "step"] + common))
    XCTAssertThrowsError(try ParsedTaskDecideOptions.resolve(["--reject", ""] + common))
    XCTAssertThrowsError(try ParsedTaskDecideOptions.resolve(["--cancel", "--expected-version", "1", "--decision-id", "decision-1"]))
    XCTAssertThrowsError(try ParsedTaskDecideOptions.resolve(["--cancel", "--principal", "operator", "--decision-id", "decision-1"]))
    XCTAssertThrowsError(try ParsedTaskDecideOptions.resolve(["--cancel", "--principal", "operator", "--expected-version", "-1"]))
    XCTAssertThrowsError(try ParsedTaskDecideOptions.resolve(["--rerun", "--principal", "operator", "--expected-version", "1"]))
  }
}
