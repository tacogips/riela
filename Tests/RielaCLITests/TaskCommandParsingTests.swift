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
}
