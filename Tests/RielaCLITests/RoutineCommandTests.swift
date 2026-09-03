import Foundation
import RielaCore
import RielaEvents
import RielaWorkflowRegistry
import XCTest
@testable import RielaCLI

final class RoutineCommandTests: XCTestCase {
  func testParsesRoutineCommands() throws {
    XCTAssertEqual(
      try RielaArgumentParser().parse([
        "routine", "create", "--name", "daily digest", "--task", "summarize", "--every", "30m",
        "--workflow", "routine-task-runner"
      ]),
      .scoped(ScopedCommand(
        kind: .routine,
        options: CLICommandOptions(
          scope: "routine",
          command: "create",
          target: nil,
          arguments: [
            "--name", "daily digest", "--task", "summarize", "--every", "30m",
            "--workflow", "routine-task-runner"
          ],
          output: .jsonl
        )
      ))
    )
    XCTAssertEqual(
      try RielaArgumentParser().parse(["routine", "complete", "routine-a", "--note", "done"]),
      .scoped(ScopedCommand(
        kind: .routine,
        options: CLICommandOptions(
          scope: "routine",
          command: "complete",
          target: "routine-a",
          arguments: ["--note", "done"],
          output: .jsonl
        )
      ))
    )
  }

  func testRoutineCreateListCompleteLifecycleThroughRunner() async throws {
    let workingDirectory = temporaryDirectory()
    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    let runner = ScopedParityCommandRunner()

    let createResult = await runner.run(ScopedCommand(
      kind: .routine,
      options: CLICommandOptions(
        scope: "routine",
        command: "create",
        arguments: [
          "--name", "daily digest", "--task", "summarize inbox", "--every", "30m",
          "--workflow", "routine-task-runner", "--completion-criteria", "inbox empty",
          "--working-dir", workingDirectory.path
        ],
        output: .text
      )
    ))
    XCTAssertEqual(createResult.exitCode, .success, createResult.stderr)
    XCTAssertTrue(createResult.stdout.contains("status=active"), createResult.stdout)
    guard let routineId = createResult.stdout
      .split(separator: " ")
      .first(where: { $0.hasPrefix("routine=") })?
      .dropFirst("routine=".count)
    else {
      return XCTFail("routine id missing from create output: \(createResult.stdout)")
    }

    let service = RoutineService(workingDirectory: workingDirectory.path, environment: [:])
    let record = try service.get(routineId: String(routineId))
    XCTAssertEqual(record.schedule, "0 */30 * * * *")
    XCTAssertEqual(record.workflowName, "routine-task-runner")
    XCTAssertTrue(FileManager.default.fileExists(atPath: service.sourceFileURL(for: record).path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: service.bindingFileURL(for: record).path))

    let completeResult = await runner.run(ScopedCommand(
      kind: .routine,
      options: CLICommandOptions(
        scope: "routine",
        command: "complete",
        target: String(routineId),
        arguments: ["--note", "all clear", "--working-dir", workingDirectory.path],
        output: .text
      )
    ))
    XCTAssertEqual(completeResult.exitCode, .success, completeResult.stderr)
    XCTAssertTrue(completeResult.stdout.contains("status=completed"), completeResult.stdout)

    let completed = try service.get(routineId: String(routineId))
    XCTAssertEqual(completed.status, .completed)
    XCTAssertEqual(completed.completionNote, "all clear")

    let bindingData = try Data(contentsOf: service.bindingFileURL(for: completed))
    let binding = try JSONDecoder().decode(EventBindingContract.self, from: bindingData)
    XCTAssertFalse(binding.enabled)
  }

  func testRoutineCreateRejectsConflictingScheduleInputs() async throws {
    let workingDirectory = temporaryDirectory()
    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    let result = await ScopedParityCommandRunner().run(ScopedCommand(
      kind: .routine,
      options: CLICommandOptions(
        scope: "routine",
        command: "create",
        arguments: [
          "--name", "x", "--task", "y", "--workflow", "z",
          "--schedule", "0 * * * * *", "--every", "30m",
          "--working-dir", workingDirectory.path
        ],
        output: .text
      )
    ))
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.contains("exactly one of schedule or every"), result.stderr)
  }

  func testGraphQLExecutePreservesWorkflowAndRoutineRoots() async throws {
    let workingDirectory = temporaryDirectory()
    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    let parsed = try ParsedParityOptions([
      "--query", "{ workflows { workflows { workflowId } } routines { routines { routineId } } }",
      "--working-dir", workingDirectory.path
    ])

    let output = try await ScopedParityCommandRunner().graphQLDocumentRecord(
      options: CLICommandOptions(scope: "graphql", command: "execute"),
      parsed: parsed,
      action: "execute"
    )
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
    )
    let data = try XCTUnwrap(object["data"] as? [String: Any])
    XCTAssertNotNil(data["workflows"])
    XCTAssertNotNil(data["routines"])
  }

  func testRoutineCreateRollsBackSourceWhenBindingWriteFails() throws {
    let workingDirectory = temporaryDirectory()
    let eventRoot = workingDirectory.appendingPathComponent("events", isDirectory: true)
    try FileManager.default.createDirectory(at: eventRoot, withIntermediateDirectories: true)
    try Data("not a directory".utf8).write(to: eventRoot.appendingPathComponent("bindings"))
    let service = RoutineService(workingDirectory: workingDirectory.path, environment: [:])

    XCTAssertThrowsError(try service.create(RoutineCreateRequest(
      name: "rollback",
      task: "test cleanup",
      every: "30m",
      workflowName: "routine-task-runner",
      eventRoot: eventRoot.path
    )))

    XCTAssertEqual(try service.list(), [])
    let sourceDirectory = eventRoot.appendingPathComponent("sources", isDirectory: true)
    let sourceFiles = try FileManager.default.contentsOfDirectory(atPath: sourceDirectory.path)
    XCTAssertEqual(sourceFiles, [])
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-routine-command-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }
}
